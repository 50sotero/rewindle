"""The deeper data check runs about once a week, whatever the weekday."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
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


TEST_PLAN_ID = "20000000-0000-4000-8000-000000000002"
TEST_PLAN_TAG = "restic-backuper-plan:" + TEST_PLAN_ID
TEST_GENERATION_TAG = "restic-backuper-generation:1"
REPOSITORY_ID = "d" * 64
OTHER_REPOSITORY_ID = "e" * 64
SUBSET_PREFIX = "--read-data-subset="


def utc_text(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def local_moment(year: int, month: int, day: int, hour: int, minute: int = 0) -> datetime:
    """A wall-clock time on this PC, as an aware UTC datetime."""
    return datetime(year, month, day, hour, minute).astimezone().astimezone(timezone.utc)


def record_document(
    checked: datetime,
    *,
    subset: int = 5,
    subset_parts: int = 30,
    repository_id: str = REPOSITORY_ID,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "last_data_subset_check_utc": utc_text(checked),
        "subset": subset,
        "subset_parts": subset_parts,
        "repository_id": repository_id,
        "run_id": "20260101T000000-00000000",
    }


class Fixture:
    def __init__(self, root: Path, *, prior_success: bool = True) -> None:
        self.root = root
        self.source = root / "source"
        self.source.mkdir()
        self.repository = root / "repository"
        self.repository.mkdir()
        self.state = root / "state"
        self.state.mkdir()
        excludes = root / "excludes.txt"
        excludes.write_text("**/__pycache__\n", encoding="utf-8")
        restic = root / "restic.exe"
        restic.write_bytes(b"fixture")
        canary = self.source / "canary.txt"
        canary.write_text("canary\n", encoding="utf-8")
        if prior_success:
            (self.state / "last-success.json").write_text(
                json.dumps({"state": "success", "snapshot_id": "old"}),
                encoding="utf-8",
            )
        self.config: dict[str, object] = {
            "plan_id": TEST_PLAN_ID,
            "config_generation": 1,
            "scheduled_tag": "scheduled",
            "state_directory": str(self.state),
            "repository": str(self.repository),
            "repository_volume_serial": "A1B2C3D4",
            "hostname": "SUBSET-TEST",
            "sources": [str(self.source)],
            "exclude_file": str(excludes),
            "restic_executable": str(restic),
            "canary_file": str(canary),
            "use_vss": False,
            "read_concurrency": 2,
            "structural_check_after_backup": True,
            # What the installer writes. The weekday no longer decides anything.
            "read_data_subset_weekday": "Sunday",
            "read_data_subset_parts": 30,
            "source_identities": {
                str(self.source): {"expected_volume_serial": "A1B2C3D4"}
            },
            "cloud_placeholder_policy": "strict",
        }

    @property
    def record_path(self) -> Path:
        # The name recovery_health.py reads too.
        return self.state / "data-check.json"

    def write_record(self, document: object) -> bytes:
        data = (
            document
            if isinstance(document, bytes)
            else json.dumps(document).encode("utf-8")
        )
        self.record_path.write_bytes(data)
        return data

    def status(self) -> dict[str, object]:
        return json.loads((self.state / "status.json").read_text(encoding="utf-8"))

    def last_success(self) -> dict[str, object]:
        return json.loads(
            (self.state / "last-success.json").read_text(encoding="utf-8")
        )

    def run(self, *, subset_exit: int = 0, scheduled: bool = True) -> tuple[int, list[str]]:
        """Run one backup with fake Restic; return the exit and the subset checks."""
        subset_checks: list[str] = []
        snapshot_calls = 0
        source = self.source

        def fake_capture(command, **_kwargs):
            nonlocal snapshot_calls
            if command[1] == "cat":
                return subprocess.CompletedProcess(
                    ["restic"], 0, json.dumps({"id": REPOSITORY_ID, "version": 2}), ""
                )
            snapshot_calls += 1
            payload = []
            if snapshot_calls > 1:
                payload = [
                    {
                        "id": "new-snapshot",
                        "hostname": "SUBSET-TEST",
                        "tags": ["scheduled", TEST_PLAN_TAG, TEST_GENERATION_TAG],
                        "paths": [str(source)],
                        "time": "2026-11-09T02:00:00Z",
                    }
                ]
            return subprocess.CompletedProcess(["restic"], 0, json.dumps(payload), "")

        def fake_stream(command, _log, on_line=None, **_kwargs):
            if command[1] == "backup":
                on_line(
                    json.dumps(
                        {
                            "message_type": "summary",
                            "snapshot_id": "new-snapshot",
                            "total_files_processed": 1,
                            "total_bytes_processed": 1,
                            "files_new": 1,
                            "files_changed": 0,
                            "data_added": 1,
                        }
                    )
                )
                return 0
            if command[1] == "check":
                subsets = [item for item in command if item.startswith(SUBSET_PREFIX)]
                if subsets:
                    subset_checks.extend(item[len(SUBSET_PREFIX):] for item in subsets)
                    return subset_exit
                return 0
            raise AssertionError(f"unexpected fake Restic verb: {command[1]}")

        ready = {
            "schema_version": 1,
            "policy": "strict",
            "status": "ready",
            "sources": [
                {
                    "canonical_path": str(source),
                    "readiness": "ready",
                    "volume_identity": "match",
                    "overall_status": "ready",
                }
            ],
            "failures": [],
        }
        args = argparse.Namespace(tag=None, scheduled=scheduled)
        with (
            mock.patch.object(backup, "validate_repository_volume"),
            mock.patch.object(backup, "ensure_free_space", return_value=1),
            mock.patch.object(backup, "preflight_sources", return_value=ready),
            mock.patch.object(backup, "restic_base", return_value=["restic"]),
            mock.patch.object(backup, "run_capture", side_effect=fake_capture),
            mock.patch.object(backup, "stream_command", side_effect=fake_stream),
            mock.patch.object(
                backup, "verify_canary", return_value={"verified": True}
            ),
            mock.patch.object(
                backup, "process_start_filetime", return_value="133733333333333333"
            ),
        ):
            result = backup._run_locked(args, self.config)
        return result, subset_checks


class DataSubsetScheduleTests(unittest.TestCase):
    def test_first_due_run_reads_a_subset_on_any_weekday_and_records_it(self) -> None:
        # A PC that was off on Sunday, or a schedule without Sunday, must still
        # get the deeper check: nothing is recorded yet, so this run is due.
        with tempfile.TemporaryDirectory(prefix="subset-first-") as root_text:
            fixture = Fixture(Path(root_text))
            before = datetime.now(timezone.utc)
            result, subset_checks = fixture.run()
            after = datetime.now(timezone.utc)

            self.assertEqual(0, result)
            self.assertEqual(1, len(subset_checks), subset_checks)
            subset, parts = (int(item) for item in subset_checks[0].split("/"))
            self.assertEqual(30, parts)
            self.assertTrue(1 <= subset <= 30)

            self.assertTrue(fixture.record_path.is_file())
            record = json.loads(fixture.record_path.read_text(encoding="utf-8"))
            self.assertEqual(1, record["schema_version"])
            self.assertEqual(REPOSITORY_ID, record["repository_id"])
            self.assertEqual(subset, record["subset"])
            self.assertEqual(30, record["subset_parts"])
            checked = datetime.fromisoformat(
                record["last_data_subset_check_utc"].replace("Z", "+00:00")
            )
            self.assertTrue(before <= checked <= after)

            status = fixture.status()
            self.assertEqual("success", status["state"])
            self.assertEqual(f"{subset}/30", status["verification"]["data_subset"])
            self.assertEqual(
                record["last_data_subset_check_utc"],
                status["verification"]["data_subset_checked_utc"],
            )
            self.assertEqual(
                record["last_data_subset_check_utc"],
                status["last_data_subset_check_utc"],
            )
            self.assertEqual(
                record["last_data_subset_check_utc"],
                fixture.last_success()["last_data_subset_check_utc"],
            )

    def test_a_recent_check_is_not_repeated_and_is_carried_forward(self) -> None:
        with tempfile.TemporaryDirectory(prefix="subset-recent-") as root_text:
            fixture = Fixture(Path(root_text))
            checked = datetime.now(timezone.utc) - timedelta(days=3)
            original = fixture.write_record(record_document(checked))

            result, subset_checks = fixture.run()

            self.assertEqual(0, result)
            self.assertEqual([], subset_checks)
            self.assertEqual(original, fixture.record_path.read_bytes())
            status = fixture.status()
            self.assertNotIn("data_subset", status["verification"])
            self.assertEqual(utc_text(checked), status["last_data_subset_check_utc"])
            self.assertEqual(
                utc_text(checked), fixture.last_success()["last_data_subset_check_utc"]
            )

    def test_an_old_future_unreadable_or_foreign_record_makes_the_check_due(self) -> None:
        now = datetime.now(timezone.utc)
        valid_old = record_document(now - timedelta(days=8))
        cases = {
            "eight days old": valid_old,
            "later than the clock": record_document(now + timedelta(days=1)),
            "not JSON": b"{not json",
            "unsupported schema": {**valid_old, "schema_version": 2},
            "another backup": record_document(
                now - timedelta(days=1), repository_id=OTHER_REPOSITORY_ID
            ),
            "another number of parts": record_document(
                now - timedelta(days=1), subset_parts=10
            ),
        }
        for name, document in cases.items():
            with self.subTest(record=name):
                with tempfile.TemporaryDirectory(prefix="subset-due-") as root_text:
                    fixture = Fixture(Path(root_text))
                    fixture.write_record(document)

                    result, subset_checks = fixture.run()

                    self.assertEqual(0, result)
                    self.assertEqual(1, len(subset_checks), subset_checks)
                    record = json.loads(
                        fixture.record_path.read_text(encoding="utf-8")
                    )
                    self.assertEqual(REPOSITORY_ID, record["repository_id"])
                    self.assertEqual(30, record["subset_parts"])
                    self.assertEqual(
                        record["last_data_subset_check_utc"],
                        fixture.status()["verification"]["data_subset_checked_utc"],
                    )

    def test_a_failed_check_fails_the_run_and_keeps_the_old_record(self) -> None:
        with tempfile.TemporaryDirectory(prefix="subset-failed-") as root_text:
            fixture = Fixture(Path(root_text))
            original = fixture.write_record(
                record_document(datetime.now(timezone.utc) - timedelta(days=9))
            )

            result, subset_checks = fixture.run(subset_exit=1)

            self.assertEqual(1, result)
            self.assertEqual(1, len(subset_checks))
            status = fixture.status()
            self.assertEqual("failed", status["state"])
            self.assertEqual("repository_data_check", status["failure_phase"])
            self.assertEqual("repository_data_check_failed", status["failure_code"])
            self.assertNotIn("data_subset_checked_utc", status["verification"])
            self.assertEqual(original, fixture.record_path.read_bytes())

    def test_successive_checks_take_the_parts_in_turn(self) -> None:
        with tempfile.TemporaryDirectory(prefix="subset-rotate-") as root_text:
            fixture = Fixture(Path(root_text))
            fixture.write_record(
                record_document(
                    datetime.now(timezone.utc) - timedelta(days=8), subset=30
                )
            )
            seen: list[str] = []
            for _ in range(2):
                result, subset_checks = fixture.run()
                self.assertEqual(0, result)
                seen.extend(subset_checks)
                # Age the record a week so the next run is due again.
                record = json.loads(fixture.record_path.read_text(encoding="utf-8"))
                record["last_data_subset_check_utc"] = utc_text(
                    datetime.now(timezone.utc) - timedelta(days=8)
                )
                fixture.write_record(record)

            self.assertEqual(["1/30", "2/30"], seen)

    def test_no_check_without_a_previous_backup_or_outside_the_task(self) -> None:
        for name, prior_success, scheduled in (
            ("first backup of a new location", False, True),
            ("not started by the backup task", True, False),
        ):
            with self.subTest(case=name):
                with tempfile.TemporaryDirectory(prefix="subset-skip-") as root_text:
                    fixture = Fixture(Path(root_text), prior_success=prior_success)

                    result, subset_checks = fixture.run(scheduled=scheduled)

                    self.assertEqual(0, result)
                    self.assertEqual([], subset_checks)
                    self.assertFalse(fixture.record_path.exists())
                    self.assertIsNone(fixture.status()["last_data_subset_check_utc"])


class DataSubsetRuleTests(unittest.TestCase):
    def test_due_on_the_seventh_calendar_day_even_if_the_run_starts_earlier(self) -> None:
        checked = local_moment(2026, 11, 2, 9, 0)
        record = record_document(checked)
        due = backup.data_subset_check_due
        # Six days later is too soon, whatever the time of day.
        self.assertFalse(due(record, local_moment(2026, 11, 8, 23, 0), REPOSITORY_ID, 30))
        self.assertFalse(due(record, local_moment(2026, 11, 5, 9, 0), REPOSITORY_ID, 30))
        # Exactly a week, and a run on the seventh day that starts a little
        # earlier than last week's, are both due, so a daily backup keeps its weekday.
        self.assertTrue(due(record, checked + timedelta(days=7), REPOSITORY_ID, 30))
        self.assertTrue(due(record, local_moment(2026, 11, 9, 8, 30), REPOSITORY_ID, 30))
        self.assertTrue(due(record, local_moment(2026, 11, 20, 9, 0), REPOSITORY_ID, 30))

    def test_missing_foreign_or_future_records_are_due(self) -> None:
        now = local_moment(2026, 11, 9, 9, 0)
        recent = record_document(now - timedelta(days=1))
        due = backup.data_subset_check_due
        self.assertFalse(due(recent, now, REPOSITORY_ID, 30))
        self.assertTrue(due(None, now, REPOSITORY_ID, 30))
        self.assertTrue(due(recent, now, OTHER_REPOSITORY_ID, 30))
        self.assertTrue(due(recent, now, REPOSITORY_ID, 10))
        self.assertTrue(due(record_document(now + timedelta(minutes=5)), now, REPOSITORY_ID, 30))

    def test_parts_rotate_and_wrap(self) -> None:
        now = local_moment(2026, 11, 9, 9, 0)
        rotate = backup.next_data_subset
        self.assertEqual(5, rotate(record_document(now, subset=4), now, REPOSITORY_ID, 30))
        self.assertEqual(1, rotate(record_document(now, subset=30), now, REPOSITORY_ID, 30))
        fresh = now.timetuple().tm_yday % 30 + 1
        self.assertEqual(fresh, rotate(None, now, REPOSITORY_ID, 30))
        self.assertEqual(
            fresh,
            rotate(record_document(now, subset=4), now, OTHER_REPOSITORY_ID, 30),
        )

    def test_only_a_well_formed_record_is_trusted(self) -> None:
        now = datetime.now(timezone.utc)
        valid = record_document(now - timedelta(days=1))
        broken = {
            "boolean schema": {**valid, "schema_version": True},
            "schema 2": {**valid, "schema_version": 2},
            "no time": {key: value for key, value in valid.items() if key != "last_data_subset_check_utc"},
            "local time": {**valid, "last_data_subset_check_utc": "2026-11-09T02:00:00"},
            "not a time": {**valid, "last_data_subset_check_utc": "last Sunday"},
            "short ID": {**valid, "repository_id": "d" * 63},
            "upper-case ID": {**valid, "repository_id": "D" * 64},
            "part zero": {**valid, "subset": 0},
            "part past the end": {**valid, "subset": 31},
            "boolean part": {**valid, "subset": True},
            "text parts": {**valid, "subset_parts": "30"},
            "a list": [valid],
        }
        with tempfile.TemporaryDirectory(prefix="subset-record-") as root_text:
            path = Path(root_text) / "data-check.json"
            self.assertIsNone(backup.load_data_check_state(path))
            path.write_text(json.dumps(valid), encoding="utf-8")
            self.assertEqual(valid, backup.load_data_check_state(path))
            for name, document in broken.items():
                with self.subTest(record=name):
                    path.write_text(json.dumps(document), encoding="utf-8")
                    self.assertIsNone(backup.load_data_check_state(path))
            path.write_bytes(b" " * (backup.MAX_DATA_CHECK_STATE_BYTES + 1))
            self.assertIsNone(backup.load_data_check_state(path))


if __name__ == "__main__":
    unittest.main()
