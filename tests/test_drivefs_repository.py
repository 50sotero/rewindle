from __future__ import annotations

import argparse
from dataclasses import replace
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

import backup
import restic_common


class DriveFsRepositoryTests(unittest.TestCase):
    def _config_document(self, root: Path) -> dict[str, object]:
        source = root / "source"
        source.mkdir(exist_ok=True)
        restic = root / "restic.exe"
        restic.write_bytes(b"test fixture")
        excludes = root / "excludes.txt"
        excludes.write_text("**/__pycache__\n", encoding="utf-8")
        canary = source / "canary.txt"
        canary.write_text("canary\n", encoding="utf-8")
        return {
            "schema_version": 1,
            "plan_id": "11111111-1111-4111-8111-111111111111",
            "config_generation": 1,
            "repository": str(root / "repository"),
            "repository_volume_serial": "A1B2C3D4",
            "restic_executable": str(restic),
            "recovery_tools_directory": str(root / "recovery-tools"),
            "python_executable": sys.executable,
            "state_directory": str(root / "state"),
            "secret_file": str(root / "state" / "password.dpapi.json"),
            "recovery_key_file": str(root / "recovery-key.txt"),
            "exclude_file": str(excludes),
            "canary_file": str(canary),
            "hostname": "DRIVEFS-TEST",
            "scheduled_tag": "scheduled",
            "cloud_placeholder_policy": "strict",
            "sources": [str(source)],
            "source_identities": {
                str(source): {"expected_volume_serial": "A1B2C3D4"}
            },
        }

    def _load_document(
        self,
        root: Path,
        document: dict[str, object],
    ) -> dict[str, object]:
        path = root / "backup-config.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return restic_common.load_config(path, require_repository=False)

    def test_legacy_config_defaults_to_local_ntfs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="drivefs-legacy-") as root_text:
            root = Path(root_text)
            loaded = self._load_document(root, self._config_document(root))

        self.assertEqual("local_ntfs", loaded["repository_storage_mode"])
        self.assertNotIn("repository_drivefs_root", loaded)

    def test_g_drive_requires_explicit_drivefs_mode(self) -> None:
        with tempfile.TemporaryDirectory(prefix="drivefs-explicit-") as root_text:
            root = Path(root_text)
            document = self._config_document(root)
            document["repository"] = r"G:\My Drive\ResticBackups\Personal"
            with self.assertRaisesRegex(
                ValueError,
                "requires explicit google_drivefs_stream",
            ):
                self._load_document(root, document)

    def test_installer_style_protected_canary_is_the_only_state_overlap(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="drivefs-canary-") as root_text:
            root = Path(root_text)
            document = self._config_document(root)
            canary_source = root / "state" / "Canary"
            canary_source.mkdir(parents=True)
            canary = canary_source / "backup-canary.txt"
            canary.write_text("canary\n", encoding="utf-8")
            user_source = Path(document["sources"][0])
            document["canary_file"] = str(canary)
            document["sources"] = [str(user_source), str(canary_source)]
            document["source_identities"] = {
                str(user_source): {"expected_volume_serial": "A1B2C3D4"},
                str(canary_source): {"expected_volume_serial": "A1B2C3D4"},
            }

            loaded = self._load_document(root, document)
            self.assertEqual(str(canary.resolve()), loaded["canary_file"])

            document["sources"] = [str(user_source), str(root / "state")]
            document["source_identities"] = {
                str(user_source): {"expected_volume_serial": "A1B2C3D4"},
                str(root / "state"): {"expected_volume_serial": "A1B2C3D4"},
            }
            with self.assertRaisesRegex(
                ValueError,
                "exact protected canary directory",
            ):
                self._load_document(root, document)

    def test_installer_and_examples_emit_only_canonical_drivefs_contract(
        self,
    ) -> None:
        installer = (
            PROJECT / "installer" / "Install-ResticBackuper.ps1"
        ).read_text(encoding="utf-8")
        manager = (SOURCE / "Manage-Repository.ps1").read_text(encoding="utf-8")
        initializer = (SOURCE / "initialize_repository.py").read_text(
            encoding="utf-8"
        )
        example = json.loads(
            (SOURCE / "backup-config.drivefs.example.json").read_text(
                encoding="utf-8"
            )
        )

        self.assertIn(
            "[ValidateSet('local_ntfs', 'google_drivefs_stream')]",
            installer,
        )
        self.assertIn(
            "repository_storage_mode = $RepositoryStorageMode",
            installer,
        )
        self.assertIn(
            "$configuration['drivefs_my_drive_root']",
            installer,
        )
        self.assertIn(
            "$configuration['drivefs_cache_directory']",
            installer,
        )
        self.assertIn(
            "if ($RepositoryStorageMode -eq 'local_ntfs') {\n"
            "        Set-ProtectedDirectory -Path $repositoryPath",
            installer,
        )
        self.assertIn("Assert-NtfsProtectedPath", installer)
        self.assertIn("Assert-NtfsProtectedPath", manager)
        self.assertIn("New-RepositoryStagingDirectory", manager)
        self.assertIn("repository_manifest_sha256", manager)
        self.assertIn(
            'if storage_mode == "local_ntfs":\n'
            "                secure_directory(repository)",
            initializer,
        )
        self.assertEqual(
            "google_drivefs_stream",
            example["repository_storage_mode"],
        )
        self.assertEqual(r"G:\My Drive", example["drivefs_my_drive_root"])
        self.assertIn("drivefs_cache_directory", example)
        self.assertNotIn("repository_drivefs_root", example)
        self.assertFalse(
            example["recovery_tools_directory"].casefold().startswith(
                example["drivefs_my_drive_root"].casefold()
            )
        )

    def test_drivefs_schema_requires_an_explicit_bounded_root(self) -> None:
        with tempfile.TemporaryDirectory(prefix="drivefs-schema-") as root_text:
            root = Path(root_text)
            base = self._config_document(root)
            drivefs_root = root / "My Drive"
            drivefs_root.mkdir()
            cache = root / "Google" / "DriveFS"
            cache.mkdir(parents=True)

            invalid_documents = (
                (
                    {
                        **base,
                        "repository_storage_mode": {},
                    },
                    "repository_storage_mode must be",
                ),
                (
                    {
                        **base,
                        "repository_storage_mode": "google_drivefs_stream",
                    },
                    "drivefs_my_drive_root",
                ),
                (
                    {
                        **base,
                        "repository_storage_mode": "local_ntfs",
                        "repository_drivefs_root": str(drivefs_root),
                    },
                    "only valid",
                ),
                (
                    {
                        **base,
                        "repository_storage_mode": "google_drivefs_stream",
                        "drivefs_my_drive_root": str(drivefs_root),
                        "drivefs_cache_directory": str(cache),
                    },
                    "strictly beneath",
                ),
                (
                    {
                        **base,
                        "repository": str(drivefs_root / "ResticBackups" / "Personal"),
                        "repository_storage_mode": "google_drivefs_stream",
                        "drivefs_my_drive_root": str(drivefs_root),
                        "drivefs_cache_directory": str(cache),
                        "secret_file": str(drivefs_root / "secret.dpapi.json"),
                    },
                    "secret_file must remain outside",
                ),
            )
            for index, (document, message) in enumerate(invalid_documents):
                with self.subTest(index=index):
                    with self.assertRaisesRegex(ValueError, message):
                        self._load_document(root, document)

            valid = {
                **base,
                "repository": str(drivefs_root / "ResticBackups" / "Personal"),
                "repository_storage_mode": "google_drivefs_stream",
                "drivefs_my_drive_root": str(drivefs_root),
                "drivefs_cache_directory": str(cache),
            }
            loaded = self._load_document(root, valid)

        self.assertEqual(
            "google_drivefs_stream",
            loaded["repository_storage_mode"],
        )
        self.assertEqual(
            str(drivefs_root.resolve()),
            loaded["drivefs_my_drive_root"],
        )
        self.assertEqual(str(cache.resolve()), loaded["drivefs_cache_directory"])
        self.assertNotIn("repository_drivefs_root", loaded)

    def test_legacy_drivefs_root_alias_is_read_but_not_reemitted(self) -> None:
        with tempfile.TemporaryDirectory(prefix="drivefs-alias-") as root_text:
            root = Path(root_text)
            drivefs_root = root / "My Drive"
            drivefs_root.mkdir()
            cache = root / "Google" / "DriveFS"
            cache.mkdir(parents=True)
            document = {
                **self._config_document(root),
                "repository": str(
                    drivefs_root / "ResticBackups" / "Personal"
                ),
                "repository_storage_mode": "google_drivefs_stream",
                "repository_drivefs_root": str(drivefs_root),
            }
            with mock.patch.dict(os.environ, {"LOCALAPPDATA": str(root)}):
                loaded = self._load_document(root, document)

        self.assertEqual(
            str(drivefs_root.resolve()),
            loaded["drivefs_my_drive_root"],
        )
        self.assertEqual(str(cache.resolve()), loaded["drivefs_cache_directory"])
        self.assertNotIn("repository_drivefs_root", loaded)

    def test_drivefs_volume_validation_is_provider_specific(self) -> None:
        with tempfile.TemporaryDirectory(prefix="drivefs-volume-") as root_text:
            root = Path(root_text)
            drivefs_root = root / "My Drive"
            repository = drivefs_root / "ResticBackups" / "Personal"
            repository.mkdir(parents=True)
            config = {
                "repository": str(repository),
                "repository_storage_mode": "google_drivefs_stream",
                "drivefs_my_drive_root": str(drivefs_root),
                "drivefs_cache_directory": str(root / "Google" / "DriveFS"),
                "repository_volume_serial": "A1B2C3D4",
            }
            ready = restic_common.WindowsVolumeMetadata(
                root=str(root.anchor),
                serial="A1B2C3D4",
                filesystem="FAT32",
                label="Google Drive",
                drive_type=restic_common.DRIVE_FIXED,
                flags=restic_common.FILE_SUPPORTS_REMOTE_STORAGE,
                maximum_component_length=256,
            )
            with mock.patch.object(
                restic_common,
                "windows_volume_metadata",
                return_value=ready,
            ):
                restic_common.validate_repository_volume(config)

            failures = (
                (replace(ready, serial="DEADBEEF"), "volume mismatch"),
                (replace(ready, filesystem="NTFS"), "filesystem is unsupported"),
                (replace(ready, drive_type=2), "not on a fixed"),
                (replace(ready, flags=0), "lacks remote-storage"),
                (
                    replace(ready, maximum_component_length=32),
                    "cannot represent Restic object names",
                ),
            )
            for metadata, message in failures:
                with (
                    self.subTest(message=message),
                    mock.patch.object(
                        restic_common,
                        "windows_volume_metadata",
                        return_value=metadata,
                    ),
                ):
                    with self.assertRaisesRegex(RuntimeError, message):
                        restic_common.validate_repository_volume(config)

    def test_drivefs_readiness_proves_atomic_write_and_cleans_probe(self) -> None:
        with tempfile.TemporaryDirectory(prefix="drivefs-ready-") as root_text:
            root = Path(root_text)
            drivefs_root = root / "My Drive"
            repository = drivefs_root / "ResticBackups" / "Personal"
            repository.mkdir(parents=True)
            (repository / "config").write_text("{}", encoding="utf-8")
            cache = root / "Google" / "DriveFS"
            cache.mkdir(parents=True)
            state = root / "state"
            recovery_tools = root / "recovery-tools"
            state.mkdir()
            recovery_tools.mkdir()
            config = {
                "repository": str(repository),
                "repository_storage_mode": "google_drivefs_stream",
                "drivefs_my_drive_root": str(drivefs_root),
                "drivefs_cache_directory": str(cache),
                "state_directory": str(state),
                "recovery_tools_directory": str(recovery_tools),
                "repository_volume_serial": "A1B2C3D4",
            }
            with (
                mock.patch.object(restic_common, "validate_repository_volume"),
                mock.patch.object(
                    restic_common,
                    "EXPECTED_DRIVEFS_MY_DRIVE_ROOT",
                    str(drivefs_root),
                ),
                mock.patch.object(
                    restic_common,
                    "_running_drivefs_process_names",
                    return_value=frozenset({"googledrivefs.exe"}),
                ),
                mock.patch.dict(os.environ, {"LOCALAPPDATA": str(root)}),
            ):
                result = restic_common.validate_repository_storage_readiness(
                    config
                )

            self.assertEqual("ready", result["status"])
            self.assertEqual("passed", result["atomic_write_probe"])
            self.assertEqual("GoogleDriveFS.exe", result["provider_process"])
            self.assertEqual(1, result["file_count"])
            self.assertEqual(
                [],
                list(repository.glob(".resticbackuper-readiness-*")),
            )

    def test_drivefs_readiness_rejects_provider_and_oversized_objects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="drivefs-gates-") as root_text:
            root = Path(root_text)
            drivefs_root = root / "My Drive"
            repository = drivefs_root / "ResticBackups" / "Personal"
            repository.mkdir(parents=True)
            (repository / "config").write_bytes(b"x")
            cache = root / "Google" / "DriveFS"
            cache.mkdir(parents=True)
            state = root / "state"
            recovery_tools = root / "recovery-tools"
            state.mkdir()
            recovery_tools.mkdir()
            config = {
                "repository": str(repository),
                "repository_storage_mode": "google_drivefs_stream",
                "drivefs_my_drive_root": str(drivefs_root),
                "drivefs_cache_directory": str(cache),
                "state_directory": str(state),
                "recovery_tools_directory": str(recovery_tools),
                "repository_volume_serial": "A1B2C3D4",
            }
            with (
                mock.patch.object(restic_common, "validate_repository_volume"),
                mock.patch.object(
                    restic_common,
                    "EXPECTED_DRIVEFS_MY_DRIVE_ROOT",
                    str(drivefs_root),
                ),
                mock.patch.object(
                    restic_common,
                    "_running_drivefs_process_names",
                    return_value=frozenset(),
                ),
                mock.patch.dict(os.environ, {"LOCALAPPDATA": str(root)}),
            ):
                with self.assertRaisesRegex(RuntimeError, "process is not running"):
                    restic_common.validate_repository_storage_readiness(config)

            with (
                mock.patch.object(restic_common, "validate_repository_volume"),
                mock.patch.object(
                    restic_common,
                    "EXPECTED_DRIVEFS_MY_DRIVE_ROOT",
                    str(drivefs_root),
                ),
                mock.patch.object(
                    restic_common,
                    "_running_drivefs_process_names",
                    return_value=frozenset({"googledrivefs.exe"}),
                ),
                mock.patch.object(
                    restic_common.shutil,
                    "disk_usage",
                    return_value=mock.Mock(free=1),
                ),
                mock.patch.dict(os.environ, {"LOCALAPPDATA": str(root)}),
            ):
                with self.assertRaisesRegex(RuntimeError, "cache free space"):
                    restic_common.validate_repository_storage_readiness(config)

            with (
                mock.patch.object(restic_common, "validate_repository_volume"),
                mock.patch.object(
                    restic_common,
                    "EXPECTED_DRIVEFS_MY_DRIVE_ROOT",
                    str(drivefs_root),
                ),
                mock.patch.object(
                    restic_common,
                    "_running_drivefs_process_names",
                    return_value=frozenset({"googledrivefs.exe"}),
                ),
                mock.patch.object(
                    restic_common,
                    "MAX_DRIVEFS_OBJECT_BYTES",
                    1,
                ),
                mock.patch.dict(os.environ, {"LOCALAPPDATA": str(root)}),
            ):
                with self.assertRaisesRegex(RuntimeError, "smaller than 4 GiB"):
                    restic_common.validate_repository_storage_readiness(config)

    def test_drivefs_readiness_fails_closed_before_backup_commands(self) -> None:
        with tempfile.TemporaryDirectory(prefix="drivefs-runtime-") as root_text:
            root = Path(root_text)
            document = self._config_document(root)
            document.update(
                {
                    "repository_storage_mode": "google_drivefs_stream",
                    "drivefs_my_drive_root": str(root / "My Drive"),
                    "drivefs_cache_directory": str(
                        root / "Google" / "DriveFS"
                    ),
                }
            )
            args = argparse.Namespace(tag=None, scheduled=False)
            with (
                mock.patch.object(backup, "process_start_filetime", return_value="1"),
                mock.patch.object(backup, "validate_and_record_plan_state"),
                mock.patch.object(backup, "validate_repository_volume"),
                mock.patch.object(
                    backup,
                    "validate_repository_storage_readiness",
                    side_effect=RuntimeError("DriveFS is unavailable"),
                ),
                mock.patch.object(backup, "ensure_free_space") as free_space,
                mock.patch.object(backup, "run_capture") as restic_command,
            ):
                result = backup._run_locked(args, document)

            self.assertEqual(1, result)
            free_space.assert_not_called()
            restic_command.assert_not_called()
            status = json.loads(
                (Path(document["state_directory"]) / "status.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual("failed", status["state"])
            self.assertIn("DriveFS is unavailable", status["failure"])
            self.assertEqual("repository_storage", status["failure_phase"])
            self.assertEqual(
                "repository_storage_unavailable",
                status["failure_code"],
            )


if __name__ == "__main__":
    unittest.main()
