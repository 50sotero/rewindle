"""What each backup did, and how far back the backups go, as the dashboard host reads them.

Compiles Telemetry.cs (with the few files it needs, as test_dashboard_eta_fallback.py does) and
tests/fixtures/RunCountsHarness.cs, which drives the telemetry reader on fixtures in a temporary folder and
prints what it found. Every engine path points into that folder; nothing real is read or written.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
HARNESS = PROJECT / "tests" / "fixtures" / "RunCountsHarness.cs"
PLAN_ID = "4e1b8c0a-5f27-4d3a-9b61-0c7d2a9e5f31"


@unittest.skipUnless(os.name == "nt", "the dashboard host is Windows-only")
class DashboardRunCountsTests(unittest.TestCase):
    result: dict
    root: Path

    @classmethod
    def setUpClass(cls) -> None:
        framework = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "Microsoft.NET" / "Framework64" / "v4.0.30319"
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            raise unittest.SkipTest("The .NET Framework C# compiler is unavailable.")
        cls.temp_directory = tempfile.TemporaryDirectory(prefix="rewindle-run-counts-")
        temp = Path(cls.temp_directory.name)
        executable = temp / "RunCountsHarness.exe"
        compiled = subprocess.run(
            [
                str(compiler), "/nologo", "/target:exe", "/warn:4", f"/out:{executable}",
                f"/reference:{framework / 'System.dll'}",
                f"/reference:{framework / 'System.Core.dll'}",
                f"/reference:{framework / 'System.Web.Extensions.dll'}",
                str(DASHBOARD / "EngineProfile.cs"),
                str(DASHBOARD / "AtomicFile.cs"),
                str(DASHBOARD / "ElevatedRequestSecurity.cs"),
                str(DASHBOARD / "SourceConfiguration.cs"),
                str(DASHBOARD / "ProcessLiveness.cs"),
                str(DASHBOARD / "Telemetry.cs"),
                str(HARNESS),
            ],
            capture_output=True, text=True, timeout=120, check=False,
        )
        if compiled.returncode != 0:
            raise AssertionError("run-counts harness failed to compile:\n" + compiled.stdout + compiled.stderr)
        cls.root = temp / "fixture"
        cls.root.mkdir()
        completed = subprocess.run(
            [str(executable), str(cls.root)], capture_output=True, text=True, timeout=120, check=False,
        )
        if completed.returncode != 0:
            raise AssertionError("run-counts harness failed:\n" + completed.stdout + completed.stderr)
        cls.result = json.loads(completed.stdout)
        cls.repository = str(cls.root / "backups" / "Rewindle")

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "temp_directory"):
            cls.temp_directory.cleanup()

    @staticmethod
    def counts(new: int, changed: int, unmodified: int) -> dict:
        return {"new": new, "changed": changed, "unmodified": unmodified, "known": True}

    UNKNOWN = {"new": -1, "changed": -1, "unmodified": -1, "known": False}

    def test_a_backup_keeps_restics_new_changed_and_unchanged_counts(self) -> None:
        self.assertEqual(self.result["backup"], self.counts(312, 41, 12040))
        self.assertEqual(self.result["backupDisplay"], "312 new, 41 changed, 12,040 unchanged")
        # All three parts, in that order, even when a part is zero.
        self.assertEqual(self.result["zeroDisplay"], "0 new, 0 changed, 12,040 unchanged")
        # A run that failed after the backup step finished still has what that step found.
        self.assertEqual(self.result["failedAfterBackup"], self.counts(5, 0, 7))

    def test_unknown_counts_are_never_shown_as_zero(self) -> None:
        self.assertEqual(self.result["unknownDisplay"], "")
        self.assertFalse(self.result["unknownView"])
        # A check-only run's figures are what a backup would do; they are not a backup's.
        self.assertEqual(self.result["dryRun"], self.UNKNOWN)
        for name in ("missing", "negative", "string", "bool", "fraction", "noSummary"):
            with self.subTest(name=name):
                self.assertEqual(self.result["odd"][name], self.UNKNOWN)

    def test_the_run_history_keeps_the_counts_only_when_known(self) -> None:
        written = self.result["serializedWith"]
        self.assertEqual((written["files_new"], written["files_changed"], written["files_unmodified"]), (312, 41, 12040))
        self.assertNotIn("files_new", self.result["serializedWithoutKeys"])
        self.assertNotIn("files_changed", self.result["serializedWithoutKeys"])
        self.assertNotIn("files_unmodified", self.result["serializedWithoutKeys"])
        self.assertEqual(
            self.result["parsed"],
            {
                "backup:run-1:with": self.counts(312, 41, 12040),
                # A record written before this version has no counts: read back as not known.
                "backup:run-10:without": self.UNKNOWN,
                # A check-only record never carries them, even when its file says so.
                "dry_run:dry-1:without": self.UNKNOWN,
            },
        )

    def test_a_record_without_counts_is_replaced_by_one_with_them(self) -> None:
        # This is how the latest run gains its counts after an upgrade: the old record differs, so it is rewritten once.
        self.assertFalse(self.result["equalWithAndWithout"])
        self.assertTrue(self.result["equalSame"])

    def test_a_loaded_run_shows_its_counts_and_the_history_stays_schema_1(self) -> None:
        self.assertEqual(self.result["loadedDisplay"], "2 new, 1 changed, 2 unchanged")
        history = self.result["historyFile"]
        self.assertIsNotNone(history)
        # Additive keys: an older build still reads and rewrites the file.
        self.assertEqual(history["schema_version"], 1)
        run = history["runs"][0]
        self.assertEqual((run["files_new"], run["files_changed"], run["files_unmodified"]), (2, 1, 2))

    def test_the_backup_services_count_comes_from_a_verified_backup(self) -> None:
        engine = self.result["engine"]
        self.assertEqual(engine["source"], "backup")
        self.assertEqual(engine["count"], 412)
        self.assertEqual(engine["plan"], PLAN_ID)
        self.assertEqual(engine["repository"].casefold(), self.repository.casefold())
        self.assertEqual(engine["oldest"], "2025-03-03T12:00:04.0000000Z")
        self.assertEqual(engine["newest"], "2026-11-06T01:00:03.0000000Z")
        self.assertTrue(engine["counted"].startswith("2026-11-06T01:02:41.512") and engine["counted"].endswith("Z"))

    def test_anything_but_an_exact_engine_record_is_not_shown(self) -> None:
        for name, value in self.result["engineRefused"].items():
            with self.subTest(name=name):
                self.assertIsNone(value)
        self.assertEqual(
            set(self.result["engineRefused"]),
            {
                "failed", "unverified", "countZero", "countText", "countFraction", "countTooLarge", "schema2", "otherRule",
                "oldestAfterNewest", "countedUnreadable", "noRepository", "planNotCanonical", "noInventory", "statusOnly",
            },
        )

    def test_the_count_shown_belongs_to_the_plan_and_backup_location_in_use(self) -> None:
        choose = self.result["choose"]
        self.assertEqual(choose["engineOnly"]["count"], 412)
        self.assertIsNone(choose["otherPlan"])
        self.assertEqual(choose["caseAndSeparator"]["count"], 412)
        self.assertIsNone(choose["otherLocation"])
        self.assertIsNone(choose["noLocation"])
        self.assertEqual((choose["listedLater"]["source"], choose["listedLater"]["count"]), ("restore", 413))
        self.assertEqual((choose["listedEarlier"]["source"], choose["listedEarlier"]["count"]), ("backup", 412))
        self.assertEqual(choose["tie"]["source"], "backup")
        # A newer Restore list that found nothing hides the older count instead of contradicting it.
        self.assertIsNone(choose["listedEmptyLater"])
        self.assertEqual(choose["listedEmptyEarlier"]["source"], "backup")
        self.assertEqual(choose["listedOnly"]["count"], 400)
        self.assertIsNone(choose["neither"])

    def test_the_restore_lists_count_is_written_off_the_windows_thread(self) -> None:
        # Recording does no file work (it runs on the window's thread); the next Load writes it.
        self.assertFalse(self.result["fileBeforeLoad"])
        listed = self.result["listedInMemory"]
        self.assertEqual((listed["source"], listed["count"]), ("restore", 14))
        written = self.result["fileAfterLoad"]
        self.assertEqual(written["schema_version"], 1)
        self.assertEqual(written["source"], "restore")
        self.assertEqual(written["plan_id"], PLAN_ID)
        self.assertEqual(written["count"], 14)
        self.assertEqual(written["oldest_utc"], "2026-10-01T02:00:00.0000000Z")
        self.assertEqual(written["newest_utc"], "2026-11-05T02:00:00.0000000Z")
        back = self.result["listedReadBack"]
        self.assertEqual((back["source"], back["count"], back["oldest"]), ("restore", 14, "2026-10-01T02:00:00.0000000Z"))
        self.assertEqual(back["counted"], listed["counted"])

    def test_an_empty_list_is_a_count_that_shows_nothing(self) -> None:
        self.assertEqual(self.result["emptyFile"]["count"], 0)
        self.assertNotIn("oldest_utc", self.result["emptyFile"])
        self.assertEqual(self.result["emptyReadBack"]["count"], 0)
        self.assertIsNone(self.result["emptyChosen"])

    def test_a_damaged_count_file_is_ignored_and_left_alone(self) -> None:
        self.assertIsNone(self.result["malformedReadBack"])
        self.assertEqual(self.result["malformedKept"], '{"schema_version":1,"source":"restore","count":"x"}')

    def test_without_persistence_the_count_stays_in_memory(self) -> None:
        self.assertEqual(self.result["noPersistenceInMemory"]["count"], 3)
        self.assertFalse(self.result["noPersistenceFile"])

    def test_a_count_out_of_range_is_not_recorded(self) -> None:
        for name, value in self.result["recordRefused"].items():
            with self.subTest(name=name):
                self.assertIsNone(value)

    def test_the_earlier_personal_edition(self) -> None:
        legacy = self.result["legacy"]
        # Its backup.py keeps the same Restic summary, so its runs get the counts too.
        self.assertEqual(legacy["display"], "2 new, 1 changed, 2 unchanged")
        # Its last-success.json has no count of its own (its prior_matching_snapshot_count is not one: it is never used).
        self.assertIsNone(legacy["engineRange"])
        # The Restore list is where it gets one, kept in that edition's own folder.
        self.assertEqual((legacy["chosen"]["source"], legacy["chosen"]["count"]), ("restore", 5))
        self.assertEqual(legacy["folder"], "ResticPersonalBackupDashboard")
        self.assertTrue(legacy["fileWritten"])
        self.assertFalse(legacy["rewindleFileWritten"])


if __name__ == "__main__":
    unittest.main()
