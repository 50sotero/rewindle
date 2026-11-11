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


import refresh_recovery_tools as refresher  # noqa: E402
import restic_common  # noqa: E402


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


class RepositoryAccessTests(unittest.TestCase):
    """Whether the backups have a password (repository_access): carried by the bundle, never silently changed."""

    UNSUPPORTED = ("No_Password", "PASSWORD", "", None, 5, True, ["no_password"], {"mode": "no_password"})

    def config_with(self, access: object = None, **changes: object) -> dict[str, object]:
        config = plan_config([r"E:\Projects"], **changes)
        if access is not None:
            config["repository_access"] = access
        return config

    def make_bundle(self, root: Path, config: dict[str, object], manifest_access: object = None) -> Path:
        bundle = root / "RecoveryTools"
        create_bundle(bundle, config)
        if manifest_access is not None:
            manifest = json.loads((bundle / MANIFEST_NAME).read_text(encoding="utf-8"))
            manifest["repository_access"] = manifest_access
            (bundle / MANIFEST_NAME).write_bytes(json_bytes(manifest))
        return bundle

    def snapshot(self, bundle: Path) -> dict[str, bytes]:
        return {item.name: item.read_bytes() for item in sorted(bundle.parent.iterdir()) if item.is_file()} | {
            item.name: item.read_bytes() for item in sorted(bundle.iterdir()) if item.is_file()
        }

    def test_the_rule_is_the_one_restic_common_has(self) -> None:
        self.assertEqual(restic_common.REPOSITORY_ACCESS_VALUES, refresher.REPOSITORY_ACCESS_VALUES)
        self.assertEqual(restic_common.DEFAULT_REPOSITORY_ACCESS, refresher.DEFAULT_REPOSITORY_ACCESS)
        for config in ({}, {"repository_access": "password"}, {"repository_access": "no_password"}):
            with self.subTest(config=config):
                self.assertEqual(restic_common.repository_access(config), refresher.repository_access(config))
        for value in self.UNSUPPORTED:
            with self.subTest(value=value):
                with self.assertRaises(ValueError) as ours:
                    refresher.repository_access({"repository_access": value})
                with self.assertRaises(ValueError) as theirs:
                    restic_common.repository_access({"repository_access": value})
                self.assertEqual("unsupported repository_access", str(ours.exception))
                self.assertEqual(str(theirs.exception), str(ours.exception))

    def test_the_mode_is_not_a_recovery_local_field(self) -> None:
        # A local field is kept from the bundle when the live configuration is merged over it; the mode must come from the
        # live configuration (and a difference is refused first).
        self.assertNotIn("repository_access", refresher.RECOVERY_LOCAL_FIELDS)

    def test_an_older_bundle_without_the_key_refreshes_as_a_bundle_with_a_password(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-access-old-") as root_text:
            root = Path(root_text)
            source_path = root / "source-config.json"
            source_path.write_bytes(json_bytes(self.config_with(generation=2, use_vss=True)))
            bundle = self.make_bundle(root, self.config_with())

            result = refresh(source_path, bundle)

            self.assertEqual("refreshed", result["state"])
            self.assertNotIn("repository_access", result["changed_fields"])
            final = validate_bundle(bundle)
            self.assertNotIn("repository_access", final["config"])
            self.assertEqual("password", final["manifest"]["repository_access"])

    def test_a_current_older_bundle_is_left_byte_for_byte_alone(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-access-current-") as root_text:
            root = Path(root_text)
            source_path = root / "source-config.json"
            source_path.write_bytes(json_bytes(self.config_with()))
            bundle = self.make_bundle(root, self.config_with())
            before = self.snapshot(bundle)

            self.assertEqual("already_current", refresh(source_path, bundle)["state"])

            self.assertEqual(before, self.snapshot(bundle))
            self.assertNotIn("repository_access", json.loads((bundle / MANIFEST_NAME).read_text(encoding="utf-8")))

    def test_a_bundle_without_a_password_keeps_its_mode_through_a_refresh(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-refresh-access-none-") as root_text:
            root = Path(root_text)
            source_path = root / "source-config.json"
            source_path.write_bytes(json_bytes(self.config_with("no_password", generation=2, use_vss=True)))
            bundle = self.make_bundle(root, self.config_with("no_password"), manifest_access="no_password")

            result = refresh(source_path, bundle)

            self.assertEqual("refreshed", result["state"])
            final = validate_bundle(bundle)
            self.assertEqual("no_password", final["config"]["repository_access"])
            self.assertEqual("no_password", final["manifest"]["repository_access"])
            self.assertEqual({"keep": True}, final["manifest"]["standalone_marker"])

    def test_a_difference_between_the_live_configuration_and_the_bundle_is_refused_before_anything_is_merged(self) -> None:
        cases = (
            ("no_password", None),
            (None, "no_password"),
            ("password", "no_password"),
            ("no_password", "password"),
        )
        for live, recorded in cases:
            with self.subTest(live=live, bundle=recorded):
                with tempfile.TemporaryDirectory(prefix="recovery-refresh-access-differ-") as root_text:
                    root = Path(root_text)
                    source_path = root / "source-config.json"
                    source_path.write_bytes(json_bytes(self.config_with(live, generation=2, use_vss=True)))
                    bundle = self.make_bundle(root, self.config_with(recorded), manifest_access=recorded)
                    before = self.snapshot(bundle)

                    with mock.patch.object(refresher, "merge_config", side_effect=AssertionError("merged")):
                        with self.assertRaisesRegex(RuntimeError, "different repository_access"):
                            refresh(source_path, bundle)

                    self.assertEqual(before, self.snapshot(bundle))
                    self.assertFalse(journal_path_for(bundle.resolve()).exists())

    def test_a_missing_key_and_the_word_password_are_the_same_mode(self) -> None:
        for live, recorded in ((None, "password"), ("password", None)):
            with self.subTest(live=live, bundle=recorded):
                with tempfile.TemporaryDirectory(prefix="recovery-refresh-access-same-") as root_text:
                    root = Path(root_text)
                    source_path = root / "source-config.json"
                    source_path.write_bytes(json_bytes(self.config_with(live, generation=2)))
                    bundle = self.make_bundle(root, self.config_with(recorded), manifest_access=recorded)

                    self.assertEqual("refreshed", refresh(source_path, bundle)["state"])

                    self.assertEqual("password", validate_bundle(bundle)["manifest"]["repository_access"])

    def test_an_unsupported_value_is_refused_on_either_side_and_nothing_changes(self) -> None:
        for value in self.UNSUPPORTED:
            for side in ("live", "bundle"):
                with self.subTest(value=value, side=side):
                    with tempfile.TemporaryDirectory(prefix="recovery-refresh-access-bad-") as root_text:
                        root = Path(root_text)
                        source_path = root / "source-config.json"
                        live_config = self.config_with(generation=2)
                        bundle_config = self.config_with()
                        (live_config if side == "live" else bundle_config)["repository_access"] = value
                        source_path.write_bytes(json_bytes(live_config))
                        bundle = self.make_bundle(root, bundle_config)
                        before = self.snapshot(bundle)

                        with self.assertRaisesRegex(RuntimeError, "repository_access is invalid"):
                            refresh(source_path, bundle)

                        self.assertEqual(before, self.snapshot(bundle))

    def test_a_manifest_that_disagrees_with_its_configuration_is_not_a_valid_bundle(self) -> None:
        cases = (
            ("the configuration has none, the manifest says no_password", None, "no_password"),
            ("the configuration says password, the manifest says no_password", "password", "no_password"),
            ("the configuration says no_password, the manifest has none", "no_password", None),
            ("the configuration says no_password, the manifest says password", "no_password", "password"),
        )
        for label, configured, recorded in cases:
            with self.subTest(label):
                with tempfile.TemporaryDirectory(prefix="recovery-refresh-access-bundle-") as root_text:
                    bundle = self.make_bundle(Path(root_text), self.config_with(configured), manifest_access=recorded)
                    with self.assertRaisesRegex(RuntimeError, "recovery manifest and configuration repository_access mismatch"):
                        validate_bundle(bundle)

    def test_an_unsupported_manifest_value_is_not_a_valid_bundle(self) -> None:
        for value in self.UNSUPPORTED:
            if value is None:
                continue  # the helper leaves the key out for None
            with self.subTest(value=value):
                with tempfile.TemporaryDirectory(prefix="recovery-refresh-access-manifest-bad-") as root_text:
                    bundle = self.make_bundle(Path(root_text), self.config_with(), manifest_access=value)
                    with self.assertRaisesRegex(RuntimeError, "recovery manifest repository_access is invalid"):
                        validate_bundle(bundle)

    def test_bundles_that_agree_on_either_mode_are_valid(self) -> None:
        for access in (None, "password", "no_password"):
            with self.subTest(access=access):
                with tempfile.TemporaryDirectory(prefix="recovery-refresh-access-valid-") as root_text:
                    bundle = self.make_bundle(Path(root_text), self.config_with(access), manifest_access=access)
                    validate_bundle(bundle)


if __name__ == "__main__":
    unittest.main()
