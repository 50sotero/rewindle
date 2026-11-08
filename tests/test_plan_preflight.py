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
    FILE_ATTRIBUTE_REPARSE_POINT,
    GENERATION_TAG_PREFIX,
    IO_REPARSE_TAG_LX_BLK,
    IO_REPARSE_TAG_LX_CHR,
    IO_REPARSE_TAG_LX_FIFO,
    IO_REPARSE_TAG_LX_SYMLINK,
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
                self.name = path.rsplit("\\", 1)[-1]
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
            name = "transient"

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
            name = "private"

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


FILE_ATTRIBUTE_ARCHIVE = 0x20
REPARSE_FILE = FILE_ATTRIBUTE_ARCHIVE | FILE_ATTRIBUTE_REPARSE_POINT
REPARSE_DIRECTORY = FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT
NO_TAG = object()


class FakeEntry:
    """A DirEntry whose stat carries what CPython fills in from a Windows folder listing."""

    def __init__(self, directory: str, name: str, attributes: int, tag: object = 0):
        self.name = name
        self.path = directory + "\\" + name
        self._stat = SimpleNamespace(st_file_attributes=attributes)
        if tag is not NO_TAG:
            self._stat.st_reparse_tag = tag

    def is_dir(self, *, follow_symlinks: bool) -> bool:
        if follow_symlinks:
            raise AssertionError("scanner followed a link")
        return bool(self._stat.st_file_attributes & FILE_ATTRIBUTE_DIRECTORY)

    def stat(self, *, follow_symlinks: bool) -> SimpleNamespace:
        if follow_symlinks:
            raise AssertionError("scanner followed a link")
        return self._stat


def scan_fake_tree(
    tree: dict[str, list[tuple[str, int, object]]], **options: object
) -> dict[str, object]:
    """Run the real scanner over folders given as {relative folder: [(name, attributes, tag)]}."""
    root = r"\\?\E:\Projects"

    class Listing:
        def __init__(self, entries: list[FakeEntry]):
            self.entries = entries

        def __enter__(self):
            return iter(self.entries)

        def __exit__(self, *_args):
            return False

    def fake_scandir(path):
        text = str(path)
        if text.casefold() == root.casefold():
            relative = ""
        elif text.casefold().startswith(root.casefold() + "\\"):
            relative = text[len(root) + 1 :]
        else:
            raise AssertionError(f"listed a folder outside the source: {text}")
        if relative not in tree:
            raise AssertionError(f"walked into a folder it must not enter: {relative}")
        return Listing(
            [FakeEntry(text, name, attributes, tag) for name, attributes, tag in tree[relative]]
        )

    with (
        mock.patch.object(
            restic_common.os,
            "stat",
            return_value=SimpleNamespace(st_file_attributes=FILE_ATTRIBUTE_DIRECTORY),
        ),
        mock.patch.object(restic_common.os, "scandir", side_effect=fake_scandir),
    ):
        return scan_cloud_placeholders(Path(r"E:\Projects"), **options)


def scanner_links(
    configured: str, candidates: list[dict[str, str]], **not_left_out: int
) -> dict[str, object]:
    """What the scanner hands preflight_sources for one source."""
    return {
        "found": len(candidates) + sum(not_left_out.values()),
        "candidate_count": len(candidates),
        "candidates": candidates,
        "not_left_out_reasons": dict(not_left_out),
        "not_left_out_samples": [
            {"relative_path": f"{reason}-{index}", "tag": "lx_symlink", "reason": reason}
            for reason, count in not_left_out.items()
            for index in range(count)
        ],
    }


class UnarchivableLinkScanTests(unittest.TestCase):
    """The source walk finds the WSL links and special files the pinned Restic cannot store."""

    def test_the_four_wsl_tags_are_recorded_relative_to_the_source(self) -> None:
        result = scan_fake_tree(
            {
                "": [
                    ("readme.txt", FILE_ATTRIBUTE_ARCHIVE, 0),
                    ("lx-link", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                    ("app", FILE_ATTRIBUTE_DIRECTORY, 0),
                ],
                "app": [
                    ("fifo", REPARSE_FILE, IO_REPARSE_TAG_LX_FIFO),
                    ("tty", REPARSE_FILE, IO_REPARSE_TAG_LX_CHR),
                    # A special file Windows lists as a folder: recorded, never entered.
                    ("disk", REPARSE_DIRECTORY, IO_REPARSE_TAG_LX_BLK),
                    ("src", FILE_ATTRIBUTE_DIRECTORY, 0),
                ],
                "app\\src": [
                    ("deep link", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                ],
            }
        )
        self.assertEqual("clear", result["status"])
        links = result["unarchivable_links"]
        self.assertEqual(
            [
                {"relative_path": "app\\disk", "tag": "lx_blk"},
                {"relative_path": "app\\fifo", "tag": "lx_fifo"},
                {"relative_path": "app\\src\\deep link", "tag": "lx_symlink"},
                {"relative_path": "app\\tty", "tag": "lx_chr"},
                {"relative_path": "lx-link", "tag": "lx_symlink"},
            ],
            sorted(links["candidates"], key=lambda item: item["relative_path"]),
        )
        self.assertEqual(5, links["found"])
        self.assertEqual({}, links["not_left_out_reasons"])

    def test_links_restic_stores_and_other_tags_are_not_recorded(self) -> None:
        result = scan_fake_tree(
            {
                "": [
                    ("junction", REPARSE_DIRECTORY, 0xA0000003),
                    ("symlink", REPARSE_FILE, 0xA000000C),
                    ("folder symlink", REPARSE_DIRECTORY, 0xA000000C),
                    ("socket", REPARSE_FILE, 0x80000023),
                    ("deduplicated", REPARSE_FILE, 0x80000013),
                    ("onedrive", REPARSE_FILE, 0x9000001A),
                    ("unknown tag", REPARSE_FILE, 0x12345678),
                    # A stat without st_reparse_tag, and a tag without the reparse attribute.
                    ("no tag", REPARSE_FILE, NO_TAG),
                    ("tag only", FILE_ATTRIBUTE_ARCHIVE, IO_REPARSE_TAG_LX_SYMLINK),
                ],
            }
        )
        links = result["unarchivable_links"]
        self.assertEqual([], links["candidates"])
        self.assertEqual(0, links["found"])
        self.assertEqual(2, result["reparse_points_skipped"])

    def test_case_twins_and_names_that_cannot_be_written_are_not_left_out(self) -> None:
        result = scan_fake_tree(
            {
                "": [
                    # The twin is listed after the link, so the whole folder must be read first.
                    ("Link", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                    ("link", FILE_ATTRIBUTE_ARCHIVE, 0),
                    # Go lower-cases U+0130 to a plain "i".
                    ("\u0130nfo", REPARSE_FILE, IO_REPARSE_TAG_LX_FIFO),
                    ("info", FILE_ATTRIBUTE_ARCHIVE, 0),
                    ("line\nbreak", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                    ("tab\t", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                    ("lone\udc80", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                    ("Build", FILE_ATTRIBUTE_DIRECTORY, 0),
                    ("build", FILE_ATTRIBUTE_DIRECTORY, 0),
                    ("bad\x01folder", FILE_ATTRIBUTE_DIRECTORY, 0),
                    # Windows drops dots and spaces at the end of a name before
                    # Restic matches it: "pkg." is "pkg" to Restic, and "solo "
                    # or "..." cannot be named by any line.
                    ("pkg", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                    ("pkg.", FILE_ATTRIBUTE_ARCHIVE, 0),
                    ("solo ", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                    ("...", REPARSE_FILE, IO_REPARSE_TAG_LX_FIFO),
                    ("dir ", FILE_ATTRIBUTE_DIRECTORY, 0),
                    # The same for a name that is not all ASCII.
                    ("caf\xe9", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                    ("caf\xe9.", FILE_ATTRIBUTE_ARCHIVE, 0),
                    ("ok", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                ],
                # Below a twin folder, at any depth, a line would also match the
                # same path in the other one.
                "Build": [
                    ("current", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK),
                    ("sub", FILE_ATTRIBUTE_DIRECTORY, 0),
                ],
                "Build\\sub": [("deeper", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK)],
                "build": [("plain.txt", FILE_ATTRIBUTE_ARCHIVE, 0)],
                "bad\x01folder": [("inside", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK)],
                "dir ": [("inside", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK)],
            }
        )
        links = result["unarchivable_links"]
        self.assertEqual([{"relative_path": "ok", "tag": "lx_symlink"}], links["candidates"])
        self.assertEqual(14, links["found"])
        self.assertEqual(
            {
                "case_twin": 6,
                "control_character": 3,
                "invalid_unicode": 1,
                "trailing_dot_or_space": 3,
            },
            links["not_left_out_reasons"],
        )
        self.assertEqual(
            {
                ("Link", "case_twin"),
                ("\u0130nfo", "case_twin"),
                ("Build\\current", "case_twin"),
                ("Build\\sub\\deeper", "case_twin"),
                ("pkg", "case_twin"),
                ("caf\xe9", "case_twin"),
                ("line\nbreak", "control_character"),
                ("tab\t", "control_character"),
                ("bad\x01folder\\inside", "control_character"),
                ("lone\udc80", "invalid_unicode"),
                ("solo ", "trailing_dot_or_space"),
                ("...", "trailing_dot_or_space"),
                ("dir \\inside", "trailing_dot_or_space"),
            },
            {
                (sample["relative_path"], sample["reason"])
                for sample in links["not_left_out_samples"]
            },
        )

    def test_the_walk_keeps_at_most_one_more_than_the_limit(self) -> None:
        result = scan_fake_tree(
            {
                "": [
                    (f"link-{index}", REPARSE_FILE, IO_REPARSE_TAG_LX_SYMLINK)
                    for index in range(5)
                ]
            },
            unarchivable_limit=2,
        )
        links = result["unarchivable_links"]
        self.assertEqual(5, links["found"])
        self.assertEqual(5, links["candidate_count"])
        self.assertEqual(3, len(links["candidates"]))

    def test_preflight_hands_over_entries_per_source_and_stays_ready(self) -> None:
        with tempfile.TemporaryDirectory(prefix="source-preflight-links-") as root:
            first = Path(root) / "first"
            second = Path(root) / "second"
            first.mkdir()
            second.mkdir()
            config = identity_config(first)
            config["sources"].append(canonical_windows_path(second))
            config["source_identities"][canonical_windows_path(second)] = {
                "expected_volume_serial": "A1B2C3D4"
            }
            found = {
                canonical_windows_path(first): scanner_links(
                    canonical_windows_path(first),
                    [{"relative_path": "repo\\link", "tag": "lx_symlink"}],
                    case_twin=1,
                ),
                canonical_windows_path(second): scanner_links(
                    canonical_windows_path(second), []
                ),
            }

            def scanner(path: Path) -> dict[str, object]:
                scan = clear_cloud_scan(path)
                scan["unarchivable_links"] = found[str(path)]
                return scan

            result = preflight_sources(
                config,
                volume_serial_reader=lambda _path: "A1B2C3D4",
                placeholder_scanner=scanner,
            )
        self.assertEqual("ready", result["status"])
        self.assertEqual([], result["failures"])
        for record in result["sources"]:
            self.assertEqual("ready", record["overall_status"])
            self.assertNotIn("unarchivable_links", record["cloud_scan"])
        # A source where nothing was found is not listed.
        self.assertEqual(
            [
                {
                    "configured_path": canonical_windows_path(first),
                    "entries": [{"relative_path": "repo\\link", "tag": "lx_symlink"}],
                    "not_left_out": {
                        "count": 1,
                        "reasons": {"case_twin": 1},
                        "samples": [
                            {
                                "relative_path": "case_twin-0",
                                "tag": "lx_symlink",
                                "reason": "case_twin",
                            }
                        ],
                    },
                }
            ],
            result["unarchivable_links"],
        )

    def test_over_the_limit_across_sources_nothing_is_left_out(self) -> None:
        def entries(prefix: str, count: int) -> list[dict[str, str]]:
            return [
                {"relative_path": f"{prefix}\\link-{index}", "tag": "lx_symlink"}
                for index in range(count)
            ]

        # 500 + 500 found: at the limit, all are left out.
        at_limit = restic_common._unarchivable_links_per_source(
            [
                (r"C:\Data", scanner_links(r"C:\Data", entries("a", 499), case_twin=1)),
                (r"E:\Projects", scanner_links(r"E:\Projects", entries("b", 500))),
            ]
        )
        self.assertEqual([499, 500], [len(item["entries"]) for item in at_limit])

        # 500 + 501 found (one of them a case twin): none is left out.
        over = restic_common._unarchivable_links_per_source(
            [
                (r"C:\Data", scanner_links(r"C:\Data", entries("a", 499), case_twin=1)),
                (r"E:\Projects", scanner_links(r"E:\Projects", entries("b", 501))),
            ]
        )
        self.assertEqual([[], []], [item["entries"] for item in over])
        self.assertEqual(
            [
                {"count": 500, "reasons": {"case_twin": 1, "over_limit": 499}},
                {"count": 501, "reasons": {"over_limit": 501}},
            ],
            [
                {
                    "count": item["not_left_out"]["count"],
                    "reasons": item["not_left_out"]["reasons"],
                }
                for item in over
            ],
        )
        self.assertEqual(
            [20, 20], [len(item["not_left_out"]["samples"]) for item in over]
        )
        self.assertEqual(
            {"case_twin", "over_limit"},
            {sample["reason"] for sample in over[0]["not_left_out"]["samples"]},
        )


if __name__ == "__main__":
    unittest.main()
