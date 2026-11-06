"""The backup service's record of how many backups the Restore list offers, and how far back they go.

backup.py writes it into status.json (and so into last-success.json) from the listing it already reads after
every backup. It is display-only: these tests pin that it counts what the Restore list would offer, that a
problem counting never fails a backup, and that restore.py stays free of Rewindle imports (the recovery kit
copies it alone).
"""

from __future__ import annotations

import argparse
import ast
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))

import backup  # noqa: E402
import restore  # noqa: E402


TEST_PLAN_ID = "30000000-0000-4000-8000-000000000003"
OTHER_PLAN_ID = "30000000-0000-4000-8000-000000000004"
PLAN_TAG = "restic-backuper-plan:" + TEST_PLAN_ID
HOST = "INVENTORY-TEST"
SOURCE_PATH = r"C:\Users\you\Documents"


def snapshot_id(number: int) -> str:
    return f"{number:064x}"


def snapshot(number: int, time: str, tags: list[str], *, host: str = HOST, paths: list[str] | None = None) -> dict:
    return {
        "id": snapshot_id(number),
        "short_id": snapshot_id(number)[:8],
        "time": time,
        "hostname": host,
        "tags": tags,
        "paths": paths if paths is not None else [SOURCE_PATH],
    }


def inventory_config(generation: int = 2) -> dict:
    return {
        "plan_id": TEST_PLAN_ID,
        "config_generation": generation,
        "scheduled_tag": "scheduled",
        "hostname": HOST,
        "sources": [SOURCE_PATH],
    }


def mixed_listing() -> list[dict]:
    """Four backups the Restore list offers, and three it does not."""
    generation_1 = "restic-backuper-generation:1"
    generation_2 = "restic-backuper-generation:2"
    return [
        # This plan, its current generation: two backups (one with Restic's nine fraction digits and an offset).
        snapshot(1, "2026-11-06T02:00:03.123456789+01:00", ["scheduled", PLAN_TAG, generation_2]),
        snapshot(2, "2026-11-05T01:00:07Z", ["scheduled", PLAN_TAG, generation_2]),
        # This plan, an earlier generation (before a folder was added): still restorable.
        snapshot(3, "2025-06-01T12:00:00Z", ["scheduled", PLAN_TAG, generation_1]),
        # An earlier backup from before plans had tags, matching this computer, its tag and its folders exactly.
        snapshot(4, "2025-03-03T13:00:04.5+01:00", ["scheduled"]),
        # Not offered: another plan, another computer without plan tags, a malformed generation tag.
        snapshot(5, "2024-01-01T00:00:00Z", ["scheduled", "restic-backuper-plan:" + OTHER_PLAN_ID, generation_1]),
        snapshot(6, "2023-01-01T00:00:00Z", ["scheduled"], host="OTHER-PC"),
        snapshot(7, "2022-01-01T00:00:00Z", ["scheduled", PLAN_TAG, "restic-backuper-generation:x"]),
    ]


class SummarizeRestorableSnapshotsTests(unittest.TestCase):
    def test_counts_what_the_restore_list_offers(self) -> None:
        listing = mixed_listing()
        config = inventory_config()
        record = backup.summarize_restorable_snapshots(config, listing, "2026-11-06T09:00:00.5Z")
        self.assertEqual(
            record,
            {
                "schema_version": 1,
                "count": 4,
                "oldest_utc": "2025-03-03T12:00:04Z",
                "newest_utc": "2026-11-06T01:00:03Z",
                "counted_utc": "2026-11-06T09:00:00.5Z",
                "rule": "restore_browse",
            },
        )
        # The Restore list itself: restore.py's browse listing over the same Restic output, so a rule added to
        # that listing later (a filter, a refusal) shows up here as a difference.
        with mock.patch.object(restore, "run_restic_capture", return_value=json.dumps(listing)) as capture:
            offered = restore.query_snapshots(["restic"], {}, False, config, binding="browse")
        capture.assert_called_once()
        self.assertEqual(record["count"], len(offered))
        times = [backup._snapshot_time_utc(item["time"]) for item in offered]
        self.assertEqual(record["oldest_utc"], backup._utc_text(min(times).replace(microsecond=0)))
        self.assertEqual(record["newest_utc"], backup._utc_text(max(times).replace(microsecond=0)))

    def test_times_are_utc_and_unreadable_times_are_skipped(self) -> None:
        tags = ["scheduled", PLAN_TAG, "restic-backuper-generation:2"]
        listing = [
            snapshot(1, "2026-02-01T23:30:00.999999999-03:00", tags),
            snapshot(2, "not a time", tags),
            snapshot(3, "2026-01-15T10:00:00", tags),  # no offset: not a moment
            snapshot(4, "2026-01-20T08:00:00+00:00", tags),
        ]
        record = backup.summarize_restorable_snapshots(inventory_config(), listing, "now")
        self.assertEqual(record["count"], 4)
        self.assertEqual(record["oldest_utc"], "2026-01-20T08:00:00Z")
        self.assertEqual(record["newest_utc"], "2026-02-02T02:30:00Z")
        unreadable = [snapshot(1, "", tags), snapshot(2, "2026-13-40T00:00:00Z", tags), {**snapshot(3, "", tags), "time": 5}]
        self.assertIsNone(backup.summarize_restorable_snapshots(inventory_config(), unreadable, "now"))

    def test_nothing_is_recorded_for_no_match_or_odd_input(self) -> None:
        config = inventory_config()
        for value in ([], None, {}, "[]", [None], ["text"], [1], [snapshot(6, "2023-01-01T00:00:00Z", ["scheduled"], host="OTHER-PC")]):
            with self.subTest(value=value):
                self.assertIsNone(backup.summarize_restorable_snapshots(config, value, "now"))

    def test_a_listing_the_restore_list_would_refuse_is_not_described(self) -> None:
        # The Restore list refuses the whole listing when one entry has no exact 64-character ID.
        listing = mixed_listing()
        listing.append({**snapshot(8, "2026-01-01T00:00:00Z", ["scheduled", PLAN_TAG, "restic-backuper-generation:2"]), "id": "short"})
        self.assertIsNone(backup.summarize_restorable_snapshots(inventory_config(), listing, "now"))
        with mock.patch.object(restore, "run_restic_capture", return_value=json.dumps(listing)):
            with self.assertRaises(ValueError):
                restore.query_snapshots(["restic"], {}, False, inventory_config(), binding="browse")

    def test_the_lazy_import_resolves_the_way_the_task_launcher_runs_python(self) -> None:
        # The launcher runs Python with -I -S -B, so neither the working folder nor the script's folder is searched
        # unless backup.py puts its own folder first. Run from a folder that has no restore.py.
        driver = (
            "import importlib.util, json, sys\n"
            "spec = importlib.util.spec_from_file_location('backup', sys.argv[1])\n"
            "module = importlib.util.module_from_spec(spec)\n"
            "sys.modules['backup'] = module\n"
            "spec.loader.exec_module(module)\n"
            "record = module.summarize_restorable_snapshots(json.loads(sys.argv[2]), json.loads(sys.argv[3]), 'counted')\n"
            "print(json.dumps({'record': record, 'restore': sys.modules['restore'].__file__}))\n"
        )
        with tempfile.TemporaryDirectory(prefix="inventory-driver-") as folder:
            completed = subprocess.run(
                [sys.executable, "-I", "-S", "-B", "-c", driver, str(SOURCE / "backup.py"),
                 json.dumps(inventory_config()), json.dumps(mixed_listing())],
                cwd=folder, capture_output=True, text=True, timeout=60, check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["record"]["count"], 4)
        self.assertEqual(Path(result["restore"]).resolve(), (SOURCE / "restore.py").resolve())

    def test_restore_py_never_imports_rewindle_modules(self) -> None:
        # The recovery kit holds restore.py without restic_common.py or backup.py, so it must start on its own.
        tree = ast.parse((SOURCE / "restore.py").read_text(encoding="utf-8"))
        imported: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.add(node.module.split(".")[0])
        self.assertFalse(imported & {"restic_common", "backup", "dry_run"}, imported)


class BackupRunInventoryTests(unittest.TestCase):
    """Drives backup._run_locked with a fake Restic, in the style of test_cancellation.py."""

    def run_backup(self, *, unchanged: bool = False, binding_error: bool = False) -> tuple[int, dict, dict | None]:
        with tempfile.TemporaryDirectory(prefix="inventory-run-") as root_text:
            root = Path(root_text)
            source = root / "source"
            source.mkdir()
            repository = root / "repository"
            repository.mkdir()
            state = root / "state"
            excludes = root / "excludes.txt"
            excludes.write_text("**/__pycache__\n", encoding="utf-8", newline="\n")
            restic = root / "restic.exe"
            restic.write_bytes(b"fixture")
            canary = source / "canary.txt"
            canary.write_text("canary\n", encoding="utf-8", newline="\n")
            tags = ["scheduled", PLAN_TAG, "restic-backuper-generation:1"]
            earlier = [
                snapshot(1, "2026-01-10T02:00:00Z", tags, paths=[str(source)]),
                snapshot(2, "2026-02-10T02:00:00Z", tags, paths=[str(source)]),
            ]
            new = snapshot(3, "2026-03-10T02:00:00Z", tags, paths=[str(source)])
            listings = [earlier, earlier if unchanged else earlier + [new]]

            def fake_capture(command, **_kwargs):
                if command[1] == "cat":
                    return subprocess.CompletedProcess(["restic"], 0, json.dumps({"id": "f" * 64, "version": 2}), "")
                return subprocess.CompletedProcess(["restic"], 0, json.dumps(listings.pop(0)), "")

            def fake_stream(command, _log, on_line=None, **_kwargs):
                if command[1] == "backup":
                    summary = {
                        "message_type": "summary", "files_new": 3, "files_changed": 1, "files_unmodified": 9,
                        "total_files_processed": 13, "total_bytes_processed": 1300,
                    }
                    if not unchanged:
                        summary["snapshot_id"] = new["id"]
                    on_line(json.dumps(summary))
                return 0

            config = {
                "plan_id": TEST_PLAN_ID,
                "config_generation": 1,
                "scheduled_tag": "scheduled",
                "state_directory": str(state),
                "repository": str(repository),
                "repository_volume_serial": "A1B2C3D4",
                "hostname": HOST,
                "sources": [str(source)],
                "exclude_file": str(excludes),
                "restic_executable": str(restic),
                "canary_file": str(canary),
                "use_vss": False,
                "read_concurrency": 2,
                "structural_check_after_backup": True,
                "read_data_subset_parts": 0,
                "source_identities": {str(source): {"expected_volume_serial": "A1B2C3D4"}},
                "cloud_placeholder_policy": "strict",
            }
            preflight = {
                "schema_version": 1, "policy": "strict", "status": "ready", "failures": [],
                "sources": [{
                    "canonical_path": str(source.resolve()), "readiness": "ready", "expected_volume_serial": "A1B2C3D4",
                    "observed_volume_serial": "A1B2C3D4", "volume_identity": "match", "overall_status": "ready",
                }],
            }
            patches = [
                mock.patch.object(backup, "validate_repository_volume"),
                mock.patch.object(backup, "ensure_free_space", return_value=1),
                mock.patch.object(backup, "preflight_sources", return_value=preflight),
                mock.patch.object(backup, "restic_base", return_value=["restic"]),
                mock.patch.object(backup, "run_capture", side_effect=fake_capture),
                mock.patch.object(backup, "stream_command", side_effect=fake_stream),
                mock.patch.object(backup, "verify_canary", return_value={"verified": True}),
                mock.patch.object(backup, "process_start_filetime", return_value="133744444444444444"),
            ]
            if binding_error:
                patches.append(mock.patch.object(restore, "snapshot_binding_state", side_effect=RuntimeError("boom")))
            for patch in patches:
                patch.start()
            try:
                result = backup._run_locked(argparse.Namespace(tag=None, scheduled=False), config, None)
            finally:
                for patch in reversed(patches):
                    patch.stop()
            status = json.loads((state / "status.json").read_text(encoding="utf-8"))
            success_path = state / "last-success.json"
            success = json.loads(success_path.read_text(encoding="utf-8")) if success_path.is_file() else None
            return result, status, success

    def test_a_verified_backup_records_the_inventory(self) -> None:
        result, status, success = self.run_backup()
        self.assertEqual(result, 0)
        self.assertEqual(success["state"], "success")
        inventory = success["snapshot_inventory"]
        self.assertEqual(inventory["count"], 3)
        self.assertEqual(inventory["oldest_utc"], "2026-01-10T02:00:00Z")
        self.assertEqual(inventory["newest_utc"], "2026-03-10T02:00:00Z")
        self.assertEqual(inventory["rule"], "restore_browse")
        self.assertEqual(status["snapshot_inventory"], inventory)
        # The per-run counts the dashboard shows are Restic's own summary, kept whole as before.
        self.assertEqual(
            {key: success["summary"][key] for key in ("files_new", "files_changed", "files_unmodified")},
            {"files_new": 3, "files_changed": 1, "files_unmodified": 9},
        )

    def test_an_unchanged_backup_records_the_inventory_too(self) -> None:
        result, _status, success = self.run_backup(unchanged=True)
        self.assertEqual(result, 0)
        self.assertEqual(success["state"], "success_unchanged")
        self.assertEqual(success["snapshot_inventory"]["count"], 2)
        self.assertEqual(success["snapshot_inventory"]["newest_utc"], "2026-02-10T02:00:00Z")

    def test_a_counting_problem_never_fails_the_backup(self) -> None:
        result, status, success = self.run_backup(binding_error=True)
        self.assertEqual(result, 0)
        self.assertEqual(status["state"], "success")
        self.assertEqual(success["state"], "success")
        self.assertIn("snapshot_inventory", success)
        self.assertIsNone(success["snapshot_inventory"])


if __name__ == "__main__":
    unittest.main()
