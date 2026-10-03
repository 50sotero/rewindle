from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))

from refresh_recovery_tools import (  # noqa: E402
    MANIFEST_NAME,
    PAYLOAD_NAMES,
    journal_path_for,
    json_bytes,
    refresh,
    sha256_file,
    validate_bundle,
    validate_storage_config,
    write_journal,
)


PLAN_ID = "7f51ea2a-a888-4c46-83a6-d572bf234847"


def identity_map(sources: list[str], serial: str = "2CFA222D") -> dict[str, object]:
    return {
        source: {"expected_volume_serial": serial}
        for source in sources
    }


def plan_config(
    sources: list[str],
    *,
    generation: int = 1,
    use_vss: bool = False,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "plan_id": PLAN_ID,
        "config_generation": generation,
        "repository": r"D:\Backups\Repository",
        "repository_volume_serial": "A1B2C3D4",
        "restic_executable": r"D:\Backups\RecoveryTools\restic.exe",
        "python_executable": r"C:\PortablePython\python.exe",
        "state_directory": r"C:\RecoveryState",
        "secret_file": r"C:\RecoveryState\repository-password.dpapi.json",
        "recovery_key_file": r"F:\Offline\RecoveryKey.txt",
        "exclude_file": r"C:\RecoveryState\excludes.txt",
        "canary_file": r"C:\RecoveryState\backup-canary.txt",
        "recovery_tools_directory": r"D:\Backups\RecoveryTools",
        "hostname": "EXAMPLE-PC",
        "scheduled_tag": "scheduled",
        "minimum_free_gib": 50,
        "cloud_placeholder_policy": "strict",
        "source_identities": identity_map(sources),
        "use_vss": use_vss,
        "sources": sources,
    }


def create_bundle(bundle: Path, config: dict[str, object]) -> None:
    bundle.mkdir()
    for name in PAYLOAD_NAMES:
        if name == "backup-config.json":
            (bundle / name).write_bytes(json_bytes(config))
        else:
            (bundle / name).write_bytes(f"test payload: {name}\n".encode())
    manifest = {
        "schema_version": 1,
        "created_utc": "2026-01-01T00:00:00Z",
        "repository": config["repository"],
        "files": [
            {
                "name": name,
                "bytes": (bundle / name).stat().st_size,
                "sha256": sha256_file(bundle / name),
            }
            for name in PAYLOAD_NAMES
        ],
        "note": "The repository password is intentionally not stored in this bundle.",
        "standalone_marker": {"keep": True},
    }
    (bundle / MANIFEST_NAME).write_bytes(json_bytes(manifest))


class RecoveryRefreshTests(unittest.TestCase):
    def test_storage_config_rejects_nested_state_and_recovery_roles(self) -> None:
        config = plan_config([r"E:\Projects"])
        config["state_directory"] = r"C:\ProgramData\ResticBackuper"
        config["recovery_tools_directory"] = (
            r"C:\ProgramData\ResticBackuper\RecoveryTools"
        )
        with self.assertRaisesRegex(RuntimeError, "protected roles overlap"):
            validate_storage_config(config, "test")

    def test_drivefs_refresh_preserves_standalone_recovery_paths_off_drivefs(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-drivefs-") as root_text:
            root = Path(root_text)
            bundle = root / "RecoveryTools"
            source_path = root / "source-config.json"
            sources = [r"E:\Projects"]
            recovery_config = plan_config(sources)
            source_config = plan_config(sources, generation=2)
            for config in (recovery_config, source_config):
                config.update(
                    {
                        "repository": r"G:\My Drive\ResticBackups\Personal",
                        "repository_storage_mode": "google_drivefs_stream",
                        "drivefs_my_drive_root": r"G:\My Drive",
                        "drivefs_cache_directory": (
                            r"C:\Users\you\AppData\Local\Google\DriveFS"
                        ),
                    }
                )
            recovery_config.update(
                {
                    "restic_executable": r"X:\Standalone\restic.exe",
                    "python_executable": r"X:\Standalone\python.exe",
                    "state_directory": r"X:\Standalone\state",
                    "secret_file": r"X:\Standalone\state\secret.json",
                    "recovery_key_file": r"X:\Standalone\RecoveryKey.txt",
                    "exclude_file": r"X:\Standalone\excludes.txt",
                    "recovery_tools_directory": r"X:\Standalone\RecoveryTools",
                }
            )
            source_config.update(
                {
                    "restic_executable": (
                        r"C:\Program Files\ResticBackuper\restic.exe"
                    ),
                    "python_executable": (
                        r"C:\Program Files\ResticBackuper\Python\python.exe"
                    ),
                    "state_directory": r"C:\ProgramData\ResticBackuper",
                    "secret_file": (
                        r"C:\ProgramData\ResticBackuper"
                        r"\repository-password.dpapi.json"
                    ),
                    "recovery_key_file": (
                        r"C:\Users\you\ResticBackuper-RecoveryKey.txt"
                    ),
                    "exclude_file": (
                        r"C:\Program Files\ResticBackuper\excludes.txt"
                    ),
                    "recovery_tools_directory": (
                        r"C:\ProgramData\ResticBackuperRecoveryTools"
                    ),
                }
            )
            source_path.write_bytes(json_bytes(source_config))
            create_bundle(bundle, recovery_config)

            result = refresh(source_path, bundle)
            published = json.loads(
                (bundle / "backup-config.json").read_text(encoding="utf-8")
            )

            self.assertEqual("refreshed", result["state"])
            self.assertEqual(
                r"X:\Standalone\RecoveryTools",
                published["recovery_tools_directory"],
            )
            self.assertEqual(
                "google_drivefs_stream",
                published["repository_storage_mode"],
            )
            self.assertEqual(r"G:\My Drive", published["drivefs_my_drive_root"])
            self.assertFalse(
                published["recovery_tools_directory"].casefold().startswith(
                    published["drivefs_my_drive_root"].casefold()
                )
            )

    def test_drivefs_refresh_rejects_recovery_material_inside_my_drive(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-drivefs-bad-") as root_text:
            root = Path(root_text)
            bundle = root / "RecoveryTools"
            source_path = root / "source-config.json"
            source_config = plan_config([r"E:\Projects"])
            recovery_config = plan_config([r"E:\Projects"])
            for config in (source_config, recovery_config):
                config.update(
                    {
                        "repository": r"G:\My Drive\ResticBackups\Personal",
                        "repository_storage_mode": "google_drivefs_stream",
                        "drivefs_my_drive_root": r"G:\My Drive",
                        "drivefs_cache_directory": (
                            r"C:\Users\you\AppData\Local\Google\DriveFS"
                        ),
                    }
                )
            source_config["recovery_tools_directory"] = (
                r"C:\ProgramData\ResticBackuperRecoveryTools"
            )
            recovery_config["recovery_tools_directory"] = (
                r"G:\My Drive\ResticBackups\RecoveryTools"
            )
            source_path.write_bytes(json_bytes(source_config))
            create_bundle(bundle, recovery_config)
            before = {
                path.name: path.read_bytes()
                for path in bundle.iterdir()
                if path.is_file()
            }

            with self.assertRaisesRegex(
                RuntimeError,
                "recovery_tools_directory must remain outside",
            ):
                refresh(source_path, bundle)

            self.assertEqual(
                before,
                {
                    path.name: path.read_bytes()
                    for path in bundle.iterdir()
                    if path.is_file()
                },
            )

    def test_refresh_syncs_plan_policy_and_payload_but_preserves_recovery_local_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-test-") as root_text:
            root = Path(root_text)
            bundle = root / "RecoveryTools"
            source_path = root / "source-config.json"
            restore_source = root / "new-restore.py"
            old_sources = [r"E:\Projects", r"C:\Users\you\Desktop"]
            new_sources = [
                r"E:\Projects",
                r"C:\Users\you\Pictures",
                r"C:\Users\you\Desktop",
            ]
            recovery_config = plan_config(old_sources)
            source_config = plan_config(new_sources, generation=2, use_vss=True)
            source_config.update(
                {
                    "restic_executable": r"C:\Program Files\ResticBackuper\restic.exe",
                    "python_executable": r"C:\Program Files\ResticBackuper\Python\python.exe",
                    "state_directory": r"C:\ProgramData\ResticBackuper",
                    "secret_file": r"C:\ProgramData\ResticBackuper\repository-password.dpapi.json",
                    "minimum_free_gib": 75,
                    "cloud_placeholder_policy": "allow",
                    "topology_paths": {"cloud_mirror": r"G:\My Drive\ResticMirror"},
                }
            )
            source_path.write_bytes(json_bytes(source_config))
            restore_source.write_text("# current restore payload\n", encoding="utf-8")
            create_bundle(bundle, recovery_config)

            result = refresh(
                source_path,
                bundle,
                {"restore.py": restore_source},
            )

            self.assertEqual("refreshed", result["state"])
            self.assertEqual(["restore.py"], result["changed_payloads"])
            self.assertEqual(3, result["source_count"])
            self.assertEqual(2, result["config_generation"])
            final = validate_bundle(bundle)
            expected = dict(source_config)
            for field in (
                "restic_executable",
                "python_executable",
                "state_directory",
                "secret_file",
                "recovery_key_file",
                "exclude_file",
                "canary_file",
            ):
                expected[field] = recovery_config[field]
            self.assertEqual(expected, final["config"])
            self.assertEqual(restore_source.read_bytes(), (bundle / "restore.py").read_bytes())
            self.assertEqual({"keep": True}, final["manifest"]["standalone_marker"])
            self.assertFalse(journal_path_for(bundle).exists())
            self.assertEqual(
                set((*PAYLOAD_NAMES, MANIFEST_NAME)),
                {item.name for item in bundle.iterdir()},
            )

    def test_refresh_rolls_back_config_payload_and_manifest_if_publish_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-rollback-") as root_text:
            root = Path(root_text)
            bundle = root / "RecoveryTools"
            source_path = root / "source-config.json"
            restore_source = root / "new-restore.py"
            recovery_config = plan_config([r"E:\Projects"])
            source_config = plan_config(
                [r"E:\Projects", r"C:\Users\you\Documents"],
                generation=2,
                use_vss=True,
            )
            source_path.write_bytes(json_bytes(source_config))
            restore_source.write_text("# replacement\n", encoding="utf-8")
            create_bundle(bundle, recovery_config)
            originals = {
                name: (bundle / name).read_bytes()
                for name in ("restore.py", "backup-config.json", MANIFEST_NAME)
            }
            real_replace = os.replace
            failure_injected = False

            def flaky_replace(source: os.PathLike[str], destination: os.PathLike[str]) -> None:
                nonlocal failure_injected
                if Path(destination).name == MANIFEST_NAME and not failure_injected:
                    failure_injected = True
                    raise OSError("injected manifest publish failure")
                real_replace(source, destination)

            with mock.patch("refresh_recovery_tools.os.replace", side_effect=flaky_replace):
                with self.assertRaisesRegex(OSError, "injected manifest publish failure"):
                    refresh(source_path, bundle, {"restore.py": restore_source})

            for name, original in originals.items():
                self.assertEqual(original, (bundle / name).read_bytes())
            self.assertFalse(journal_path_for(bundle).exists())
            validate_bundle(bundle)

    def test_next_refresh_recovers_an_interrupted_publish_before_validation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-recover-") as root_text:
            root = Path(root_text)
            bundle = root / "RecoveryTools"
            source_path = root / "source-config.json"
            config = plan_config([r"E:\Projects"])
            source_path.write_bytes(json_bytes(config))
            create_bundle(bundle, config)
            originals = {
                "restore.py": (bundle / "restore.py").read_bytes(),
                MANIFEST_NAME: (bundle / MANIFEST_NAME).read_bytes(),
            }
            write_journal(bundle.resolve(), originals)
            (bundle / "restore.py").write_text("interrupted replacement\n", encoding="utf-8")

            result = refresh(source_path, bundle)

            self.assertEqual("already_current", result["state"])
            self.assertTrue(result["recovered_interruption"])
            self.assertEqual(originals["restore.py"], (bundle / "restore.py").read_bytes())
            self.assertFalse(journal_path_for(bundle.resolve()).exists())
            validate_bundle(bundle)

    def test_rejects_generation_rollback_duplicate_or_nested_roots(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-invalid-") as root_text:
            root = Path(root_text)
            bundle = root / "RecoveryTools"
            source_path = root / "source-config.json"
            recovery_config = plan_config([r"E:\Projects"], generation=2)
            create_bundle(bundle, recovery_config)

            rollback = plan_config([r"E:\Projects"], generation=1)
            source_path.write_bytes(json_bytes(rollback))
            with self.assertRaisesRegex(RuntimeError, "roll back"):
                refresh(source_path, bundle)

            for sources in (
                [r"E:\Projects", r"e:\PROJECTS"],
                [r"E:\Projects", r"E:\Projects\project"],
            ):
                invalid = plan_config(sources, generation=2)
                source_path.write_bytes(json_bytes(invalid))
                with self.assertRaisesRegex(RuntimeError, "duplicate|nested"):
                    refresh(source_path, bundle)

    def test_rejects_tampered_interruption_journal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-journal-") as root_text:
            root = Path(root_text)
            bundle = root / "RecoveryTools"
            source_path = root / "source-config.json"
            config = plan_config([r"E:\Projects"])
            source_path.write_bytes(json_bytes(config))
            create_bundle(bundle, config)
            journal = journal_path_for(bundle.resolve())
            journal.write_text(json.dumps({"schema": "forged"}), encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "journal header"):
                refresh(source_path, bundle)
            validate_bundle(bundle)


if __name__ == "__main__":
    unittest.main()
