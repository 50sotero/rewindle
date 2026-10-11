from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
import unittest


PROJECT = Path(__file__).resolve().parents[1]
WEB = PROJECT / "src" / "dashboard" / "web"
TONE = WEB / "src" / "protectionTone.ts"
WHEN = WEB / "src" / "when.ts"

# Runs protectionTone.ts and when.ts as they are (Node strips their types): the colour and the one concern sentence the Protection hero
# shows for each state, and the way a moment's age is worded. Only the fields these functions read are in a state.
RUNNER = """
const tone = await import(process.argv[1]);
const when = await import(process.argv[2]);
const { states, moments } = JSON.parse(process.argv[3]);
// A moment is given as local wall-clock parts [year, month0, day, hour, minute], so no result depends on the machine's time zone.
const local = parts => new Date(parts[0], parts[1], parts[2], parts[3], parts[4]);
const report = { states: {}, moments: {} };
for (const [name, state] of Object.entries(states)) {
  report.states[name] = { tone: tone.heroTone(state), concern: tone.heroConcern(state) };
}
for (const [name, moment] of Object.entries(moments)) {
  const iso = local(moment.at).toISOString();
  report.moments[name] = {
    ago: when.formatWhenAgo(iso, 'en-US', 'unknown', local(moment.now)),
    plain: when.formatWhen(iso, 'en-US', 'unknown'),
  };
}
report.invalid = when.formatWhenAgo('not a date', 'en-US', 'unknown', local([2026, 9, 11, 18, 0]));
report.clocks = { us: when.localClocks('Daily at 02:00, and at 14:30', 'en-US'), gb: when.localClocks('Daily at 02:00', 'en-GB'), none: when.localClocks('Every 6 hours', 'en-US') };
report.drives = {
  letter: tone.driveOf('D:\\\\Backups\\\\Rewindle'),
  share: tone.driveOf('\\\\\\\\server\\\\share\\\\Backups'),
  none: tone.driveOf('Backups'),
  missing: tone.driveOf(undefined),
};
console.log(JSON.stringify(report));
"""


def source(path: str = "C:\\Users\\you\\Documents", *, exists: bool = True) -> dict:
    return {"path": path, "name": path.rsplit("\\", 1)[-1], "isCanary": False, "exists": exists, "canRemove": True, "detail": ""}


def state(
    *,
    success: bool = True,
    failure: bool = False,
    cancelled: bool = False,
    active: bool = False,
    unavailable: bool = False,
    freshness: str = "Healthy",
    sources: list[dict] | None = None,
    volume_ready: bool | None = None,
    repository: str = "D:\\Backups\\Rewindle",
    repair_needed: bool = False,
    repair_busy: bool = False,
    review: bool = False,
    setup_problem: str = "",
    data_error: str = "",
) -> dict:
    return {
        "status": {"active": active, "success": success, "failure": failure, "cancelled": cancelled, "unavailable": unavailable},
        "recovery": {"repairNeeded": repair_needed, "repairBusy": repair_busy},
        "repository": {"path": repository, "volume": "", **({} if volume_ready is None else {"volumeReady": volume_ready})},
        "sources": [source()] if sources is None else sources,
        "freshness": {"state": freshness},
        "actions": {"reviewChanges": {"visible": review, "enabled": True, "label": "Review changes", "help": ""}},
        "setup": {"problem": setup_problem},
        "dataError": data_error,
    }


def moment(at: tuple[int, ...], now: tuple[int, ...] = (2026, 9, 11, 18, 0)) -> dict:
    # Local wall-clock parts: year, month (0-based like JavaScript's Date), day, hour, minute.
    return {"at": at, "now": now}


class ProtectionUiTests(unittest.TestCase):
    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        node = shutil.which("node")
        if not node:
            raise unittest.SkipTest("Node.js is unavailable")
        states = {
            "healthy": state(),
            "unplugged": state(volume_ready=False),
            "unplugged_share": state(volume_ready=False, repository="\\\\nas\\backups\\pc"),
            "unplugged_and_missing": state(volume_ready=False, sources=[source(exists=False)]),
            "one_missing": state(sources=[source(), source("C:\\Users\\you\\Pictures", exists=False)]),
            "two_missing": state(sources=[source(exists=False), source("C:\\Users\\you\\Pictures", exists=False)]),
            "no_folders": state(sources=[]),
            "no_folders_unread": state(sources=[], setup_problem="The backup configuration could not be read just now."),
            "no_folders_data_error": state(sources=[], data_error="Rewindle is trying again automatically."),
            "schedule_unreadable": state(freshness="Unavailable"),
            "schedule_unreadable_data_error": state(freshness="Unavailable", data_error="Rewindle is trying again automatically."),
            "schedule_unreadable_status_unavailable": state(freshness="Unavailable", unavailable=True, success=False),
            "running": state(active=True, success=False),
            "failed": state(failure=True, success=False),
            "overdue": state(freshness="Overdue"),
            "clock": state(freshness="ClockAnomaly"),
            "paused": state(freshness="Paused"),
            "review": state(review=True),
            "repair_needed": state(repair_needed=True, volume_ready=False),
            "repair_busy": state(repair_busy=True),
            "stopped_on_time": state(cancelled=True, success=False),
            "stopped_overdue": state(cancelled=True, success=False, freshness="Overdue"),
            "stopped_paused": state(cancelled=True, success=False, freshness="Paused"),
            "stopped_unplugged": state(cancelled=True, success=False, volume_ready=False),
            "stopped_review": state(cancelled=True, success=False, review=True),
            "no_run_yet": state(success=False, freshness="NoVerifiedBackup"),
        }
        moments = {
            "today": moment((2026, 9, 11, 14, 5)),
            "yesterday": moment((2026, 9, 10, 2, 3)),
            "three_days": moment((2026, 9, 8, 2, 3)),
            "two_weeks": moment((2026, 8, 27, 2, 3)),
            "three_weeks": moment((2026, 8, 20, 2, 3)),
            "tomorrow": moment((2026, 9, 12, 9, 0)),
            # Six minutes earlier, but on the day before.
            "late_last_night": moment((2026, 9, 10, 23, 59), (2026, 9, 11, 0, 5)),
        }
        completed = subprocess.run(
            [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", RUNNER,
             TONE.as_uri(), WHEN.as_uri(), json.dumps({"states": states, "moments": moments})],
            capture_output=True, encoding="utf-8", timeout=60, check=False,
        )
        if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
            raise unittest.SkipTest("this Node.js cannot run TypeScript files")
        if completed.returncode != 0:
            raise AssertionError(completed.stderr)
        cls.report = json.loads(completed.stdout)

    def tone(self, name: str) -> str:
        return self.report["states"][name]["tone"]

    def concern(self, name: str) -> dict | None:
        return self.report["states"][name]["concern"]

    @staticmethod
    def plain(text: str) -> str:
        # Newer ICU data writes a narrow no-break space before AM/PM; compare as an ordinary space.
        return re.sub(r"\s+", " ", text)

    def test_a_healthy_plan_is_green_and_has_nothing_to_add(self) -> None:
        self.assertEqual(self.tone("healthy"), "success")
        self.assertIsNone(self.concern("healthy"))

    def test_an_unplugged_backup_drive_is_named_by_its_drive(self) -> None:
        concern = self.concern("unplugged")
        self.assertEqual(concern["tone"], "danger")
        self.assertIn("(D:)", concern["text"])
        self.assertIn("Plug it back in", concern["text"])
        self.assertEqual(self.tone("unplugged"), "danger")
        self.assertIn("(\\\\nas\\backups)", self.concern("unplugged_share")["text"])
        # The drive is the first thing to put right, ahead of a folder that is gone.
        self.assertIn("backup drive", self.concern("unplugged_and_missing")["text"])

    def test_a_missing_protected_folder_is_counted(self) -> None:
        one = self.concern("one_missing")
        self.assertEqual(one["tone"], "danger")
        self.assertTrue(one["text"].startswith("A protected folder can"))
        self.assertIn("it is reconnected or removed", one["text"])
        two = self.concern("two_missing")
        self.assertTrue(two["text"].startswith("2 protected folders can"))
        self.assertIn("they are reconnected or removed", two["text"])
        self.assertEqual(self.tone("one_missing"), "danger")

    def test_an_empty_plan_is_a_warning_unless_the_host_could_not_read_it(self) -> None:
        concern = self.concern("no_folders")
        self.assertEqual(concern["tone"], "warning")
        self.assertIn("No folders are being backed up yet", concern["text"])
        self.assertEqual(self.tone("no_folders"), "warning")
        # A configuration that could not be read is not a plan with nothing in it, and neither is a status the page lost.
        self.assertIsNone(self.concern("no_folders_unread"))
        self.assertIsNone(self.concern("no_folders_data_error"))

    def test_an_unreadable_schedule_is_a_warning_with_its_own_sentence(self) -> None:
        concern = self.concern("schedule_unreadable")
        self.assertEqual(concern["tone"], "warning")
        self.assertIn("can’t read the Windows backup schedule", concern["text"])
        self.assertEqual(self.tone("schedule_unreadable"), "warning")
        # When the status itself cannot be read, that is the thing to say, not a second concern about the schedule.
        self.assertIsNone(self.concern("schedule_unreadable_data_error"))
        self.assertIsNone(self.concern("schedule_unreadable_status_unavailable"))

    def test_a_run_or_a_repair_in_progress_has_no_concern(self) -> None:
        self.assertEqual(self.tone("running"), "active")
        self.assertIsNone(self.concern("running"))
        self.assertEqual(self.tone("repair_busy"), "active")
        # A repair that is needed is red whatever else is true, and the repair banner says why, so there is no second sentence.
        self.assertEqual(self.tone("repair_needed"), "danger")
        self.assertIsNone(self.concern("repair_needed"))

    def test_the_colour_is_never_louder_or_quieter_than_the_words(self) -> None:
        self.assertEqual(self.tone("failed"), "danger")
        self.assertEqual(self.tone("overdue"), "danger")
        self.assertEqual(self.tone("clock"), "danger")
        self.assertEqual(self.tone("paused"), "warning")
        self.assertEqual(self.tone("review"), "warning")
        self.assertEqual(self.tone("no_run_yet"), "warning")

    def test_a_backup_the_person_stopped_asks_for_nothing_when_nothing_else_is_wrong(self) -> None:
        self.assertEqual(self.tone("stopped_on_time"), "neutral")
        self.assertEqual(self.tone("stopped_overdue"), "danger")
        self.assertEqual(self.tone("stopped_paused"), "warning")
        self.assertEqual(self.tone("stopped_review"), "warning")
        self.assertEqual(self.tone("stopped_unplugged"), "danger")

    def test_drives_are_read_from_a_path(self) -> None:
        drives = self.report["drives"]
        self.assertEqual(drives["letter"], "D:")
        self.assertEqual(drives["share"], "\\\\server\\share")
        self.assertEqual(drives["none"], "")
        self.assertEqual(drives["missing"], "")

    def test_a_moment_is_worded_by_its_age(self) -> None:
        moments = self.report["moments"]
        self.assertRegex(self.plain(moments["today"]["ago"]), r"^today at 2:05 PM$")
        self.assertRegex(self.plain(moments["yesterday"]["ago"]), r"^yesterday at 2:03 AM$")
        self.assertEqual(self.plain(moments["three_days"]["ago"]), f"3 days ago ({self.plain(moments['three_days']['plain'])})")
        self.assertEqual(self.plain(moments["two_weeks"]["ago"]), f"14 days ago ({self.plain(moments['two_weeks']['plain'])})")
        self.assertEqual(self.report["invalid"], "unknown")

    def test_an_old_or_future_moment_is_just_the_date(self) -> None:
        moments = self.report["moments"]
        self.assertEqual(moments["three_weeks"]["ago"], moments["three_weeks"]["plain"])
        self.assertEqual(moments["tomorrow"]["ago"], moments["tomorrow"]["plain"])

    def test_the_host_schedule_sentence_is_written_in_the_viewers_clock(self) -> None:
        clocks = self.report["clocks"]
        self.assertEqual(self.plain(clocks["us"]), "Daily at 2:00 AM, and at 2:30 PM")
        self.assertEqual(clocks["gb"], "Daily at 02:00")
        self.assertEqual(clocks["none"], "Every 6 hours")

    def test_yesterday_is_a_calendar_day_not_twenty_four_hours(self) -> None:
        self.assertRegex(self.plain(self.report["moments"]["late_last_night"]["ago"]), r"^yesterday at 11:59 PM$")


class FailureWordingTests(unittest.TestCase):
    """The hero's sentence for a failed run comes from the engine's failure_code, so every code the engine can write has one."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.engine = (PROJECT / "src" / "backup.py").read_text(encoding="utf-8")
        cls.telemetry = (PROJECT / "src" / "dashboard" / "Telemetry.cs").read_text(encoding="utf-8")

    def test_every_failure_code_the_engine_publishes_has_a_plain_sentence(self) -> None:
        start = self.engine.index("def classify_failure(")
        codes = set(re.findall(r'code = "([a-z_]+)"', self.engine[start:self.engine.index("def authenticate_repository_id(")]))
        self.assertGreaterEqual(len(codes), 10, "classify_failure no longer assigns the codes this test reads")
        wording = self.telemetry[self.telemetry.index("private static string DescribeFailureCode("):]
        wording = wording[:wording.index("default:")]
        for code in sorted(codes):
            with self.subTest(code=code):
                self.assertIn(f'case "{code}":', wording)

    def test_the_status_detail_never_shows_the_engines_own_failure_text(self) -> None:
        detail = self.telemetry[self.telemetry.index("private string BuildStatusDetail("):]
        detail = detail[:detail.index("private static string DescribeFailureCode(")]
        self.assertNotIn('GetString(document, "failure"', detail)


if __name__ == "__main__":
    unittest.main()
