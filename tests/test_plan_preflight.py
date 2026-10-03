from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))

import backup  # noqa: E402
import restic_common  # noqa: E402
from restic_common import (  # noqa: E402
    FILE_ATTRIBUTE_DIRECTORY,
    FILE_ATTRIBUTE_OFFLINE,
    GENERATION_TAG_PREFIX,
    MAX_CONFIG_GENERATION,
    PLAN_TAG_PREFIX,
    _cloud_attribute_classification,
    backup_plan_tags,
    canonical_windows_path,
    load_config,
    preflight_sources,
    scan_cloud_placeholders,
    validate_and_record_plan_state,
    validate_backup_topology,
)


PLAN_ID = "11111111-2222-4333-8444-555555555555"


def clear_cloud_scan(_source: Path) -> dict[str, object]:
    return {
        "status": "clear",
        "entries_scanned": 3,
        "cloud_only_count": 0,
        "inaccessible_count": 0,
        "unknown_count": 0,
        "reparse_points_skipped": 0,
        "samples": [],
    }


def identity_config(source: Path, serial: str = "A1B2C3D4") -> dict[str, object]:
    source_text = canonical_windows_path(source)
    return {
        "plan_id": PLAN_ID,
        "config_generation": 1,
        "sources": [source_text],
        "source_identities": {
            source_text: {"expected_volume_serial": serial}
        },
        "cloud_placeholder_policy": "strict",
    }


class PlanAndPreflightTests(unittest.TestCase):
    def test_exact_plan_tag_contract(self) -> None:
        self.assertEqual(
            (
                PLAN_TAG_PREFIX + PLAN_ID,
                GENERATION_TAG_PREFIX + "7",
            ),
            backup_plan_tags({"plan_id": PLAN_ID, "config_generation": 7}),
        )
        self.assertEqual(
            GENERATION_TAG_PREFIX + str(MAX_CONFIG_GENERATION),
            backup_plan_tags(
                {"plan_id": PLAN_ID, "config_generation": MAX_CONFIG_GENERATION}
            )[1],
        )
        with self.assertRaisesRegex(ValueError, "supported range"):
            backup_plan_tags(
                {"plan_id": PLAN_ID, "config_generation": MAX_CONFIG_GENERATION + 1}
            )

    def test_snapshot_match_requires_user_plan_and_generation_tags(self) -> None:
        config = {
            "plan_id": PLAN_ID,
            "config_generation": 7,
            "hostname": "TESTHOST",
            "sources": [r"C:\Data"],
        }
        required = [
            "scheduled",
            PLAN_TAG_PREFIX + PLAN_ID,
            GENERATION_TAG_PREFIX + "7",
        ]
        snapshot = {
            "hostname": "testhost",
            "paths": [r"c:\DATA"],
            "tags": required,
        }
        self.assertTrue(backup.snapshot_matches(config, "scheduled", snapshot))
        for missing in required:
            candidate = dict(snapshot)
            candidate["tags"] = [tag for tag in required if tag != missing]
            with self.subTest(missing=missing):
                self.assertFalse(
                    backup.snapshot_matches(config, "scheduled", candidate)
                )
        for extra in (
            PLAN_TAG_PREFIX + "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            GENERATION_TAG_PREFIX + "8",
        ):
            candidate = dict(snapshot)
            candidate["tags"] = required + [extra]
            with self.subTest(extra=extra):
                self.assertFalse(
                    backup.snapshot_matches(config, "scheduled", candidate)
                )
        overflow = dict(snapshot)
        overflow["tags"] = [
            "scheduled",
            PLAN_TAG_PREFIX + PLAN_ID,
            GENERATION_TAG_PREFIX + str(MAX_CONFIG_GENERATION + 1),
        ]
        self.assertFalse(backup.snapshot_matches(config, "scheduled", overflow))

    def test_authenticated_repository_id_accepts_exact_actual_and_rejects_drift(self) -> None:
        actual = "a" * 64
        completed = subprocess.CompletedProcess(
            ["restic", "cat", "config"],
            0,
            json.dumps({"id": actual, "version": 2}),
            "",
        )
        with (
            mock.patch.object(backup, "restic_base", return_value=["restic"]),
            mock.patch.object(backup, "run_capture", return_value=completed) as capture,
        ):
            self.assertEqual(
                actual,
                backup.authenticate_repository_id(
                    {"repository": r"D:\Repository"}, None
                ),
            )
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                backup.authenticate_repository_id(
                    {"repository": r"D:\Repository"}, "b" * 64
                )
        self.assertEqual(2, capture.call_count)
        for call in capture.call_args_list:
            self.assertIn("cat", call.args[0])
            self.assertIn("config", call.args[0])
            self.assertIn("cancellation", call.kwargs)
            self.assertIn("on_cancellation", call.kwargs)

    def test_authenticated_repository_id_rejects_malformed_fake_restic_output(self) -> None:
        malformed = (
            "not-json",
            json.dumps({}),
            json.dumps({"id": "A" * 64}),
            json.dumps({"id": "a" * 63}),
            json.dumps({"id": "g" * 64}),
        )
        with mock.patch.object(backup, "restic_base", return_value=["restic"]):
            for stdout in malformed:
                with self.subTest(stdout=stdout[:20]):
                    completed = subprocess.CompletedProcess(
                        ["restic", "cat", "config"], 0, stdout, ""
                    )
                    with mock.patch.object(
                        backup, "run_capture", return_value=completed
                    ):
                        with self.assertRaisesRegex(
                            RuntimeError, "valid JSON|canonical 64-hex"
                        ):
                            backup.authenticate_repository_id(
                                {"repository": r"D:\Repository"}, None
                            )

    def test_topology_rejects_nested_sources_and_every_protected_overlap(self) -> None:
        with self.assertRaisesRegex(ValueError, "source roots overlap"):
            validate_backup_topology(
                [r"C:\Data", r"c:\data\child"],
                {"repository": r"D:\Repository"},
            )
        for role in (
            "repository",
            "recovery_tools_directory",
            "state_directory",
            "install",
            "restore",
            "offsite",
            "diagnostic",
            "maintenance",
        ):
            with self.subTest(role=role):
                with self.assertRaisesRegex(ValueError, "overlap"):
                    validate_backup_topology(
                        [r"C:\Data"],
                        {role: r"C:\Data\unsafe"},
                    )

    def test_topology_rejects_overlapping_protected_roles(self) -> None:
        with self.assertRaisesRegex(ValueError, "repository and offsite overlap"):
            validate_backup_topology(
                [r"C:\Data"],
                {
                    "repository": r"D:\Backup",
                    "offsite": r"D:\Backup\CloudCopy",
                },
            )

    def test_topology_allows_disjoint_roles(self) -> None:
        validate_backup_topology(
            [r"C:\Data", r"E:\Projects"],
            {
                "repository": r"D:\Backup\Repository",
                "recovery": r"D:\Backup\RecoveryTools",
                "state": r"C:\ProgramData\ResticBackuper",
                "restore": r"F:\Restored",
            },
        )

    def test_source_preflight_records_ready_identity_before_backup(self) -> None:
        with tempfile.TemporaryDirectory(prefix="source-preflight-ready-") as root:
            source = Path(root) / "source"
            source.mkdir()
            config = identity_config(source)
            result = preflight_sources(
                config,
                volume_serial_reader=lambda _path: "a1b2c3d4",
                placeholder_scanner=clear_cloud_scan,
            )
        self.assertEqual("ready", result["status"])
        record = result["sources"][0]
        self.assertEqual(canonical_windows_path(source), record["canonical_path"])
        self.assertEqual("ready", record["readiness"])
        self.assertEqual("A1B2C3D4", record["expected_volume_serial"])
        self.assertEqual("A1B2C3D4", record["observed_volume_serial"])
        self.assertEqual("match", record["volume_identity"])
        self.assertEqual("ready", record["overall_status"])

    def test_source_preflight_fails_closed_for_missing_source(self) -> None:
        with tempfile.TemporaryDirectory(prefix="source-preflight-missing-") as root:
            source = Path(root) / "missing"
            result = preflight_sources(
                identity_config(source),
                volume_serial_reader=lambda _path: "A1B2C3D4",
                placeholder_scanner=clear_cloud_scan,
            )
        self.assertEqual("failed", result["status"])
        self.assertEqual("missing", result["sources"][0]["readiness"])
        self.assertIsNone(result["sources"][0]["observed_volume_serial"])

    def test_source_preflight_fails_closed_on_volume_mismatch_without_cloud_scan(self) -> None:
        with tempfile.TemporaryDirectory(prefix="source-preflight-volume-") as root:
            source = Path(root) / "source"
            source.mkdir()
            scanner = mock.Mock(side_effect=AssertionError("must not scan"))
            result = preflight_sources(
                identity_config(source),
                volume_serial_reader=lambda _path: "DEADBEEF",
                placeholder_scanner=scanner,
            )
        scanner.assert_not_called()
        record = result["sources"][0]
        self.assertEqual("ready", record["readiness"])
        self.assertEqual("mismatch", record["volume_identity"])
        self.assertEqual("volume_mismatch", record["overall_status"])
        self.assertEqual("failed", result["status"])

    def test_strict_cloud_policy_fails_but_allow_means_hydrate_and_read(self) -> None:
        cloud_scan = {
            "status": "cloud_only",
            "entries_scanned": 2,
            "cloud_only_count": 1,
            "inaccessible_count": 0,
            "unknown_count": 0,
            "reparse_points_skipped": 0,
            "samples": [],
        }
        with tempfile.TemporaryDirectory(prefix="source-preflight-cloud-") as root:
            source = Path(root) / "source"
            source.mkdir()
            strict = identity_config(source)
            strict_result = preflight_sources(
                strict,
                volume_serial_reader=lambda _path: "A1B2C3D4",
                placeholder_scanner=lambda _path: dict(cloud_scan),
            )
            allowed = identity_config(source)
            allowed["cloud_placeholder_policy"] = "allow"
            allow_result = preflight_sources(
                allowed,
                volume_serial_reader=lambda _path: "A1B2C3D4",
                placeholder_scanner=lambda _path: dict(cloud_scan),
            )
        self.assertEqual("failed", strict_result["status"])
        self.assertEqual("cloud_only", strict_result["sources"][0]["overall_status"])
        self.assertEqual("ready", allow_result["status"])
        self.assertEqual("ready", allow_result["sources"][0]["overall_status"])
        self.assertEqual(1, allow_result["sources"][0]["cloud_scan"]["cloud_only_count"])

    def test_unknown_or_inaccessible_cloud_classification_always_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="source-preflight-unknown-") as root:
            source = Path(root) / "source"
            source.mkdir()
            for status in ("unknown", "inaccessible"):
                with self.subTest(status=status):
                    config = identity_config(source)
                    config["cloud_placeholder_policy"] = "allow"
                    result = preflight_sources(
                        config,
                        volume_serial_reader=lambda _path: "A1B2C3D4",
                        placeholder_scanner=lambda _path, value=status: {
                            "status": value,
                            "entries_scanned": 1,
                            "cloud_only_count": 0,
                            "inaccessible_count": int(value == "inaccessible"),
                            "unknown_count": int(value == "unknown"),
                            "reparse_points_skipped": 0,
                            "samples": [],
                        },
                    )
                    self.assertEqual("failed", result["status"])
                    self.assertEqual("inaccessible", result["sources"][0]["readiness"])

    def test_windows_attribute_classifier_is_explicit(self) -> None:
        self.assertEqual("local", _cloud_attribute_classification(0x20))
        for value in (0x1000, 0x40000, 0x400000, 0x401020):
            with self.subTest(attributes=value):
                self.assertEqual("cloud_only", _cloud_attribute_classification(value))
        self.assertEqual("unknown", _cloud_attribute_classification(None))

    def test_cloud_scanner_uses_extended_windows_paths(self) -> None:
        source = Path(r"E:\Projects")

        class EmptyScandir:
            def __enter__(self):
                return iter(())

            def __exit__(self, *_args):
                return False

        root_stat = SimpleNamespace(st_file_attributes=FILE_ATTRIBUTE_DIRECTORY)
        with (
            mock.patch.object(restic_common.os, "stat", return_value=root_stat) as stat_call,
            mock.patch.object(
                restic_common.os, "scandir", return_value=EmptyScandir()
            ) as scandir_call,
        ):
            result = scan_cloud_placeholders(source)
        expected_prefix = "\\\\?\\" if os.name == "nt" else ""
        self.assertTrue(str(stat_call.call_args.args[0]).startswith(expected_prefix))
        self.assertTrue(str(scandir_call.call_args.args[0]).startswith(expected_prefix))
        self.assertEqual("clear", result["status"])

    def test_cloud_scanner_prunes_only_definite_directory_exclusions(self) -> None:
        source = Path(r"E:\Projects")
        excluded = r"\\?\E:\Projects\project\node_modules"
        included = r"\\?\E:\Projects\project\source"
        cloud_file = included + r"\cloud.txt"

        class Entry:
            def __init__(self, path: str, attributes: int):
                self.path = path
                self._attributes = attributes

            def is_dir(self, *, follow_symlinks: bool):
                self.assert_no_follow(follow_symlinks)
                return bool(self._attributes & FILE_ATTRIBUTE_DIRECTORY)

            def stat(self, *, follow_symlinks: bool):
                self.assert_no_follow(follow_symlinks)
                return SimpleNamespace(st_file_attributes=self._attributes)

            @staticmethod
            def assert_no_follow(value: bool) -> None:
                if value:
                    raise AssertionError("scanner followed a link")

        class Scandir:
            def __init__(self, entries):
                self.entries = entries

            def __enter__(self):
                return iter(self.entries)

            def __exit__(self, *_args):
                return False

        def fake_scandir(path):
            display = str(path).casefold()
            if display == r"\\?\e:\projects":
                return Scandir(
                    [
                        Entry(excluded, FILE_ATTRIBUTE_DIRECTORY),
                        Entry(included, FILE_ATTRIBUTE_DIRECTORY),
                    ]
                )
            if display == included.casefold():
                return Scandir([Entry(cloud_file, FILE_ATTRIBUTE_OFFLINE)])
            raise AssertionError(f"excluded or unexpected tree was traversed: {path}")

        with tempfile.TemporaryDirectory(prefix="cloud-exclusions-") as root:
            excludes = Path(root) / "excludes.txt"
            excludes.write_text("**/node_modules\n**/*.tmp\n", encoding="utf-8")
            with (
                mock.patch.object(
                    restic_common.os,
                    "stat",
                    return_value=SimpleNamespace(
                        st_file_attributes=FILE_ATTRIBUTE_DIRECTORY
                    ),
                ),
                mock.patch.object(restic_common.os, "scandir", side_effect=fake_scandir),
            ):
                result = scan_cloud_placeholders(source, exclude_file=excludes)
        self.assertEqual("cloud_only", result["status"])
        self.assertEqual(1, result["excluded_directories_skipped"])
        self.assertEqual(1, result["cloud_only_count"])

    def test_cloud_scanner_ignores_vanished_descendant(self) -> None:
        source = Path(r"E:\Projects")

        class VanishedEntry:
            path = r"\\?\E:\Projects\transient"

            @staticmethod
            def is_dir(*, follow_symlinks: bool):
                return False

            @staticmethod
            def stat(*, follow_symlinks: bool):
                raise FileNotFoundError(2, "gone")

        class Scandir:
            def __enter__(self):
                return iter([VanishedEntry()])

            def __exit__(self, *_args):
                return False

        with (
            mock.patch.object(
                restic_common.os,
                "stat",
                return_value=SimpleNamespace(
                    st_file_attributes=FILE_ATTRIBUTE_DIRECTORY
                ),
            ),
            mock.patch.object(restic_common.os, "scandir", return_value=Scandir()),
        ):
            result = scan_cloud_placeholders(source)
        self.assertEqual("clear", result["status"])
        self.assertEqual(1, result["vanished_entries_skipped"])
        self.assertEqual(0, result["inaccessible_count"])

    def test_cloud_scanner_keeps_included_access_errors_fail_closed(self) -> None:
        source = Path(r"E:\Projects")

        class DeniedEntry:
            path = r"\\?\E:\Projects\private"

            @staticmethod
            def is_dir(*, follow_symlinks: bool):
                return False

            @staticmethod
            def stat(*, follow_symlinks: bool):
                raise PermissionError(13, "denied")

        class Scandir:
            def __enter__(self):
                return iter([DeniedEntry()])

            def __exit__(self, *_args):
                return False

        with (
            mock.patch.object(
                restic_common.os,
                "stat",
                return_value=SimpleNamespace(
                    st_file_attributes=FILE_ATTRIBUTE_DIRECTORY
                ),
            ),
            mock.patch.object(restic_common.os, "scandir", return_value=Scandir()),
        ):
            result = scan_cloud_placeholders(source)
        self.assertEqual("inaccessible", result["status"])
        self.assertEqual(1, result["inaccessible_count"])
        self.assertFalse(result["samples"][0]["path"].startswith("\\\\?\\"))

    def test_plan_state_accepts_increase_and_rejects_rollback_or_plan_change(self) -> None:
        with tempfile.TemporaryDirectory(prefix="plan-state-") as root:
            state = Path(root)
            config = {"plan_id": PLAN_ID, "config_generation": 1}
            first = validate_and_record_plan_state(config, state)
            self.assertEqual(1, first["config_generation"])
            config["config_generation"] = 3
            third = validate_and_record_plan_state(config, state)
            self.assertEqual(3, third["config_generation"])
            config["config_generation"] = 2
            with self.assertRaisesRegex(RuntimeError, "rollback"):
                validate_and_record_plan_state(config, state)
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                validate_and_record_plan_state(
                    {
                        "plan_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                        "config_generation": 4,
                    },
                    state,
                )

    def test_load_config_requires_plan_generation_identities_and_policy_but_not_ready_source(self) -> None:
        with tempfile.TemporaryDirectory(prefix="plan-config-") as root_text:
            root = Path(root_text)
            repository = root / "repository"
            repository.mkdir()
            (repository / "config").write_text("fixture", encoding="utf-8")
            recovery = root / "recovery"
            state = root / "state"
            excludes = root / "excludes.txt"
            excludes.write_text("**/__pycache__\n", encoding="utf-8")
            canary = root / "canary.txt"
            canary.write_text("canary\n", encoding="utf-8")
            restic = root / "restic.exe"
            restic.write_bytes(b"fixture")
            missing_source = root / "missing-source"
            config = {
                "schema_version": 1,
                "repository": str(repository),
                "repository_volume_serial": "A1B2C3D4",
                "restic_executable": str(restic),
                "recovery_tools_directory": str(recovery),
                "python_executable": sys.executable,
                "state_directory": str(state),
                "secret_file": str(root / "secret.json"),
                "recovery_key_file": str(root / "recovery.txt"),
                "exclude_file": str(excludes),
                "canary_file": str(canary),
                "hostname": "TESTHOST",
                "scheduled_tag": "scheduled",
                **identity_config(missing_source),
            }
            config_path = root / "backup-config.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            loaded = load_config(config_path)
            self.assertEqual([canonical_windows_path(missing_source)], loaded["sources"])
            for missing_key in (
                "plan_id",
                "config_generation",
                "source_identities",
                "cloud_placeholder_policy",
            ):
                candidate = dict(config)
                candidate.pop(missing_key)
                config_path.write_text(json.dumps(candidate), encoding="utf-8")
                with self.subTest(missing=missing_key):
                    with self.assertRaisesRegex(ValueError, "missing keys"):
                        load_config(config_path)

    def test_load_config_rejects_noncanonical_plan_nonpositive_generation_and_identity_drift(self) -> None:
        with tempfile.TemporaryDirectory(prefix="plan-schema-invalid-") as root_text:
            root = Path(root_text)
            repository = root / "repository"
            repository.mkdir()
            (repository / "config").write_text("fixture", encoding="utf-8")
            exclusions = root / "excludes.txt"
            exclusions.write_text("**/__pycache__\n", encoding="utf-8")
            canary = root / "canary.txt"
            canary.write_text("canary", encoding="utf-8")
            restic = root / "restic.exe"
            restic.write_bytes(b"fixture")
            source = root / "source"
            base = {
                "schema_version": 1,
                "repository": str(repository),
                "repository_volume_serial": "A1B2C3D4",
                "restic_executable": str(restic),
                "recovery_tools_directory": str(root / "recovery"),
                "python_executable": sys.executable,
                "state_directory": str(root / "state"),
                "secret_file": str(root / "secret"),
                "recovery_key_file": str(root / "key"),
                "exclude_file": str(exclusions),
                "canary_file": str(canary),
                "hostname": "TESTHOST",
                "scheduled_tag": "scheduled",
                **identity_config(source),
            }
            path = root / "config.json"
            invalid = (
                (
                    "plan_id",
                    "AAAAAAAA-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                    "lowercase canonical",
                ),
                ("config_generation", 0, "integer from"),
                ("config_generation", True, "integer from"),
                (
                    "config_generation",
                    MAX_CONFIG_GENERATION + 1,
                    "integer from",
                ),
                ("cloud_placeholder_policy", "exclude", "must be one of"),
                ("source_identities", {}, "does not exactly match"),
            )
            for key, value, error in invalid:
                candidate = dict(base)
                candidate[key] = value
                path.write_text(json.dumps(candidate), encoding="utf-8")
                with self.subTest(key=key, value=value):
                    with self.assertRaisesRegex(ValueError, error):
                        load_config(path)

            invalid_anomaly_policies = (
                ("not-an-object", "must be an object"),
                ({"enabled": "yes"}, "enabled must be"),
                ({"deletion_ratio": float("nan")}, "finite number"),
                ({"file_change_ratio": -0.1}, "finite number"),
                ({"minimum_changed_files": 0}, "must be an integer"),
                ({"unexpected": 1}, "unknown keys"),
            )
            for value, error in invalid_anomaly_policies:
                candidate = dict(base)
                candidate["change_anomaly"] = value
                path.write_text(json.dumps(candidate), encoding="utf-8")
                with self.subTest(change_anomaly=value):
                    with self.assertRaisesRegex(ValueError, error):
                        load_config(path)

    def test_failed_preflight_is_persisted_and_no_restic_command_runs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="preflight-before-restic-") as root_text:
            root = Path(root_text)
            state = root / "state"
            source = root / "source"
            source.mkdir()
            excludes = root / "excludes.txt"
            excludes.write_text("**/__pycache__\n", encoding="utf-8")
            restic = root / "restic.exe"
            restic.write_bytes(b"fixture")
            canary = source / "canary.txt"
            canary.write_text("canary", encoding="utf-8")
            config = {
                "scheduled_tag": "scheduled",
                "state_directory": str(state),
                "repository": str(root / "repository"),
                "repository_volume_serial": "A1B2C3D4",
                "hostname": "TESTHOST",
                "exclude_file": str(excludes),
                "restic_executable": str(restic),
                "canary_file": str(canary),
                **identity_config(source),
            }
            failed = {
                "schema_version": 1,
                "policy": "strict",
                "status": "failed",
                "sources": [{"canonical_path": str(source), "readiness": "missing"}],
                "failures": ["source is missing"],
            }
            with (
                mock.patch.object(backup, "process_start_filetime", return_value="123"),
                mock.patch.object(backup, "validate_repository_volume"),
                mock.patch.object(backup, "ensure_free_space", return_value=100),
                mock.patch.object(backup, "preflight_sources", return_value=failed),
                mock.patch.object(backup, "run_capture") as restic_capture,
                mock.patch.object(backup, "stream_command") as restic_stream,
            ):
                result = backup._run_locked(
                    argparse.Namespace(tag=None, scheduled=False), config
                )
            self.assertEqual(1, result)
            restic_capture.assert_not_called()
            restic_stream.assert_not_called()
            status = json.loads((state / "status.json").read_text(encoding="utf-8"))
            self.assertEqual("failed", status["state"])
            self.assertEqual(failed, status["source_preflight"])


if __name__ == "__main__":
    unittest.main()
