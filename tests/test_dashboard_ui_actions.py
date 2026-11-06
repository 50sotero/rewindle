from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
WEB = DASHBOARD / "web"
TONE = WEB / "src" / "protectionTone.ts"
ONE_SHOT = WEB / "src" / "oneShot.ts"
RANGE = WEB / "src" / "activityRange.ts"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def run_node(runner: str, *arguments: str) -> dict:
    """Runs `runner` as an ES module with Node, which strips the types of the .ts files it imports, and returns what it printed."""
    node = shutil.which("node")
    if not node:
        raise unittest.SkipTest("Node.js is unavailable")
    completed = subprocess.run(
        [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", runner, *arguments],
        capture_output=True, encoding="utf-8", timeout=60, check=False,
    )
    if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
        raise unittest.SkipTest("this Node.js cannot run TypeScript files")
    if completed.returncode != 0:
        raise AssertionError(completed.stderr)
    return json.loads(completed.stdout)


# What the Protection hero and its Local backup card decide about a failed run and about the time of the last verified backup.
TONE_RUNNER = """
const tone = await import(process.argv[1]);
const states = JSON.parse(process.argv[2]);
const report = {};
for (const [name, state] of Object.entries(states)) {
  report[name] = {
    offers: tone.heroOffersRunDetails(state),
    open: tone.canOpenRunDetails(state, state.status.runId, true),
    openOffline: tone.canOpenRunDetails(state, state.status.runId, false),
    inHistory: tone.runInHistory(state, state.status.runId),
    verifiedKnown: tone.verifiedTimeKnown(state),
  };
}
console.log(JSON.stringify(report));
"""


def state(
    *,
    failure: bool = True,
    active: bool = False,
    run_id: str = "run-1",
    history: tuple[str, ...] = ("run-1",),
    details: dict | None = None,
    unavailable: bool = False,
    data_error: str = "",
    freshness: str = "Healthy",
) -> dict:
    # The host's own Open details is off until a run is selected in its table, which nothing does when Rewindle starts.
    action = {"enabled": False, "visible": True, "label": "Open details", "help": "Select a backup run first."} if details is None else details
    return {
        "status": {"failure": failure, "active": active, "success": not failure, "runId": run_id, "unavailable": unavailable},
        "history": [{"id": run} for run in history],
        "actions": {} if action == {} else {"viewRunDetails": action},
        "freshness": {"state": freshness, "verifiedAt": ""},
        "dataError": data_error,
    }


class RunDetailsFromTheHeroTests(unittest.TestCase):
    """"See what happened" works from the moment Rewindle starts, without selecting the run in Activity first."""

    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        cls.report = run_node(TONE_RUNNER, TONE.as_uri(), json.dumps({
            "start_up": state(),
            "selected": state(details={"enabled": True, "visible": True, "label": "Open details", "help": ""}),
            "not_in_history": state(run_id="run-9"),
            "no_run_id": state(run_id=""),
            "no_action": state(details={}),
            "hidden_action": state(details={"enabled": False, "visible": False, "label": "", "help": ""}),
            "running": state(active=True),
            "succeeded": state(failure=False),
            "status_unreadable": state(failure=False, unavailable=True, freshness="NoVerifiedBackup"),
            "data_error": state(failure=False, data_error="The status file could not be read.", freshness="NoVerifiedBackup"),
            "clock": state(failure=False, freshness="ClockAnomaly"),
            "first_backup_due": state(failure=False, freshness="NoVerifiedBackup"),
        }))

    def test_a_failed_run_opens_at_start_up_although_nothing_is_selected(self) -> None:
        start = self.report["start_up"]
        self.assertTrue(start["offers"])
        self.assertTrue(start["open"])
        self.assertTrue(self.report["selected"]["open"])

    def test_it_waits_for_the_link_to_the_host(self) -> None:
        self.assertFalse(self.report["start_up"]["openOffline"])

    def test_a_run_that_never_reached_the_history_is_not_offered(self) -> None:
        # The host would answer "The requested backup run is unavailable."; the Local backup card points to Activity instead.
        for name in ("not_in_history", "no_run_id"):
            with self.subTest(name):
                self.assertFalse(self.report[name]["inHistory"])
                self.assertFalse(self.report[name]["offers"])
                self.assertFalse(self.report[name]["open"])

    def test_nothing_is_offered_without_run_details_or_a_failed_run(self) -> None:
        for name in ("no_action", "hidden_action", "running", "succeeded"):
            with self.subTest(name):
                self.assertFalse(self.report[name]["offers"])
        self.assertFalse(self.report["no_action"]["open"])
        self.assertFalse(self.report["hidden_action"]["open"])

    def test_the_last_verified_time_is_not_guessed_when_the_status_cannot_be_read(self) -> None:
        # "No verified backup yet" under "Backup status unavailable" contradicted the title; the Local backup card already said nothing.
        self.assertFalse(self.report["status_unreadable"]["verifiedKnown"])
        self.assertFalse(self.report["data_error"]["verifiedKnown"])
        self.assertFalse(self.report["clock"]["verifiedKnown"])
        self.assertTrue(self.report["first_backup_due"]["verifiedKnown"])
        self.assertTrue(self.report["succeeded"]["verifiedKnown"])


# A fake host that records what was posted and keeps each answer to give later.
ONE_SHOT_RUNNER = """
const once = await import(process.argv[1]);
const report = {};
const posts = [], answers = [];
const host = (command, payload, onResult) => { posts.push(command); answers.push(onResult); };
const flight = once.createInFlight();
let changes = 0;
const send = once.sendOnceAtATime(host, flight, () => { changes++; });

send('restoreFlowStart', { legacyConfirmed: false });
send('restoreFlowStart', { legacyConfirmed: false });
report.doubleClick = { posts: posts.length, waiting: flight.has('restoreFlowStart'), changes };
answers[0](true);
report.answered = { waiting: flight.has('restoreFlowStart'), changes };
send('restoreFlowStart', { legacyConfirmed: false });
report.afterAnswer = posts.length;
answers[1](false);

let heard = null;
send('removeSource', { path: 'C:\\\\Users\\\\you\\\\Pictures' }, ok => { heard = ok; });
send('removeSource', { path: 'C:\\\\Users\\\\you\\\\Pictures' }, ok => { heard = ok; });
const removals = posts.filter(command => command === 'removeSource').length;
answers[answers.length - 1](false);
report.refusal = { removals, heard, waiting: flight.has('removeSource') };

// Commands that legitimately repeat are posted every time, with the caller's own answer handler.
const repeated = posts.length;
const ticked = [];
send('restoreFlowSelectPaths', { paths: 'a' }, ok => ticked.push(ok));
send('restoreFlowSelectPaths', { paths: 'b' }, ok => ticked.push(ok));
send('refresh');
send('refresh');
report.repeats = { posted: posts.length - repeated, waiting: flight.has('restoreFlowSelectPaths') };
answers[answers.length - 4](true);
report.repeats.ticked = ticked;

// A page that cannot send answers at once (no host, or a stale link); the button must not stay off.
const refused = [];
const offline = once.sendOnceAtATime((command, payload, onResult) => { refused.push(command); onResult?.(false); }, once.createInFlight(), () => {});
offline('backupNow');
offline('backupNow');
report.offline = refused.length;

const lone = once.createInFlight();
report.begin = [lone.begin('backupNow'), lone.begin('backupNow'), lone.has('backupNow')];
lone.clear();
report.cleared = [lone.has('backupNow'), lone.begin('backupNow')];
report.oneShot = Object.fromEntries(['backupNow', 'cancelBackup', 'addSource', 'removeSource', 'editSchedule', 'changeRepository',
  'repairRepository', 'reviewChanges', 'openRestore', 'checkReadiness', 'exportDiagnostics', 'confirmSourcePicker', 'viewRunDetails',
  'restoreFlowReview', 'restoreFlowStart', 'restoreFlowRetry', 'restoreFlowSelectPaths', 'restoreFlowClose', 'restoreFlowNavigate',
  'validateSourcePath', 'browseSourcePicker', 'restoreFlowBrowseFiles', 'selectRun', 'navigate', 'refresh', 'setZoom', 'closeRunDetails',
  'copyRunSummary', 'togglePreview'].map(command => [command, once.ONE_SHOT_COMMANDS.has(command)]));
console.log(JSON.stringify(report));
"""


class OnePressOneRequestTests(unittest.TestCase):
    """A double-click on a button that asks the host for something sends one request, and the button stays off until it is answered."""

    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        cls.report = run_node(ONE_SHOT_RUNNER, ONE_SHOT.as_uri())

    def test_a_double_click_posts_once_and_waits_for_the_answer(self) -> None:
        self.assertEqual(self.report["doubleClick"]["posts"], 1)
        self.assertTrue(self.report["doubleClick"]["waiting"])
        self.assertEqual(self.report["doubleClick"]["changes"], 1)
        self.assertFalse(self.report["answered"]["waiting"])
        self.assertEqual(self.report["answered"]["changes"], 2)
        self.assertEqual(self.report["afterAnswer"], 2)

    def test_a_refusal_frees_the_button_and_reaches_the_caller(self) -> None:
        refusal = self.report["refusal"]
        self.assertEqual(refusal["removals"], 1)
        self.assertIs(refusal["heard"], False)
        self.assertFalse(refusal["waiting"])
        self.assertEqual(self.report["offline"], 2)

    def test_commands_that_repeat_are_never_held_back(self) -> None:
        repeats = self.report["repeats"]
        self.assertEqual(repeats["posted"], 4)
        self.assertFalse(repeats["waiting"])
        self.assertEqual(repeats["ticked"], [True])

    def test_the_in_flight_set(self) -> None:
        self.assertEqual(self.report["begin"], [True, False, True])
        self.assertEqual(self.report["cleared"], [False, True])

    def test_which_commands_are_one_shot(self) -> None:
        one_shot = self.report["oneShot"]
        for command in ("backupNow", "cancelBackup", "addSource", "removeSource", "editSchedule", "changeRepository",
                        "repairRepository", "reviewChanges", "openRestore", "checkReadiness", "exportDiagnostics",
                        "confirmSourcePicker", "viewRunDetails", "restoreFlowReview", "restoreFlowStart", "restoreFlowRetry"):
            with self.subTest(command):
                self.assertTrue(one_shot[command])
        for command in ("restoreFlowSelectPaths", "restoreFlowClose", "restoreFlowNavigate", "validateSourcePath",
                        "browseSourcePicker", "restoreFlowBrowseFiles", "selectRun", "navigate", "refresh", "setZoom",
                        "closeRunDetails", "copyRunSummary", "togglePreview"):
            with self.subTest(command):
                self.assertFalse(one_shot[command])


# The Activity date menu at moments given as local wall-clock parts [year, month0, day, hour, minute], so no result depends on the
# machine's time zone.
RANGE_RUNNER = """
const range = await import(process.argv[1]);
const local = parts => new Date(parts[0], parts[1], parts[2], parts[3], parts[4]);
const lateEvening = local([2026, 10, 6, 23, 50]), nextMorning = local([2026, 10, 7, 0, 10]), newYear = local([2027, 0, 2, 9, 0]);
const week = { from: '', to: '', preset: '7' };
const typed = { from: '2026-10-01', to: '2026-10-15', preset: '' };
const report = {
  week: [range.effectiveFrom(week, lateEvening), range.effectiveFrom(week, nextMorning), range.rangeMenuValue(week)],
  month: [range.presetStart('30', lateEvening), range.presetStart('30', nextMorning)],
  year: [range.presetStart('365', lateEvening), range.presetStart('365', nextMorning)],
  acrossNewYear: range.presetStart('7', newYear),
  typed: [range.effectiveFrom(typed, lateEvening), range.effectiveFrom(typed, nextMorning), range.rangeMenuValue(typed)],
  fromOnly: range.rangeMenuValue({ from: '2026-10-01', to: '', preset: '' }),
  any: [range.rangeMenuValue({ from: '', to: '', preset: '' }), range.effectiveFrom({ from: '', to: '', preset: '' }, lateEvening)],
  none: range.presetStart('', lateEvening),
};
console.log(JSON.stringify(report));
"""


class RollingDateRangeTests(unittest.TestCase):
    """"Last 7 days" keeps meaning the last seven days after midnight, in a window that stays open for days."""

    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        cls.report = run_node(RANGE_RUNNER, RANGE.as_uri())

    def test_a_preset_moves_on_at_midnight_and_stays_the_menu_choice(self) -> None:
        self.assertEqual(self.report["week"], ["2026-10-31", "2026-11-01", "7"])
        self.assertEqual(self.report["month"], ["2026-10-08", "2026-10-09"])
        self.assertEqual(self.report["year"], ["2025-11-07", "2025-11-08"])
        self.assertEqual(self.report["acrossNewYear"], "2026-12-27")

    def test_dates_typed_in_stay_as_typed(self) -> None:
        self.assertEqual(self.report["typed"], ["2026-10-01", "2026-10-01", "custom"])
        self.assertEqual(self.report["fromOnly"], "custom")

    def test_no_range_is_any_time(self) -> None:
        self.assertEqual(self.report["any"], ["any", ""])
        self.assertEqual(self.report["none"], "")


class ButtonsAndListsSourceTests(unittest.TestCase):
    """The page and the host use the helpers above where the buttons are drawn and where a folder change starts."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.app = read(WEB / "src" / "App.tsx")
        cls.health = read(WEB / "components" / "primitives" / "ProtectionHealth.tsx")
        cls.folders = read(WEB / "components" / "primitives" / "ProtectedFolders.tsx")
        cls.picker = read(WEB / "components" / "primitives" / "FolderPickerModal.tsx")
        cls.restore = read(WEB / "components" / "primitives" / "RestoreFlowModal.tsx")
        cls.window = read(DASHBOARD / "DashboardWindow.cs")

    def assertHas(self, text: str, needle: str) -> None:
        # Names only what is missing; assertIn would print the whole source file.
        self.assertTrue(needle in text, f"missing: {needle}")

    def assertLacks(self, text: str, needle: str) -> None:
        self.assertFalse(needle in text, f"still present: {needle}")

    @staticmethod
    def body(source: str, declaration: str) -> str:
        """The whole body of one C# method, found by its declaration and matched braces."""
        if declaration not in source:
            raise AssertionError(f"missing: {declaration}")
        start = source.index(declaration)
        brace = source.index("{", start)
        depth = 0
        for index in range(brace, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    return source[brace:index + 1]
        raise AssertionError(declaration)

    def test_see_what_happened_does_not_wait_for_a_selected_run(self) -> None:
        self.assertLacks(self.app, "disabled={!state.actions.viewRunDetails?.enabled}")
        self.assertHas(self.app, "canOpenRunDetails(state, s.runId, !stale)")
        self.assertHas(self.app, "{offersRun && <Button")
        self.assertHas(self.health, "const heroOffersRun = here && heroOffersRunDetails(state);")

    def test_the_verified_tag_follows_the_local_backup_card(self) -> None:
        self.assertHas(self.app, "const verifiedKnown = verifiedTimeKnown(state);")

    def test_the_date_menu_keeps_the_preset(self) -> None:
        self.assertLacks(self.app, "DATE_RANGES.find(([days]) => from === dayKey(")
        self.assertHas(self.app, "const from = effectiveFrom(view, new Date());")
        self.assertHas(self.app, "const rangeValue = rangeMenuValue(view);")
        self.assertHas(self.app, "preset: ''")

    def test_every_button_sends_through_the_in_flight_lock(self) -> None:
        self.assertHas(self.app, "send: post")
        self.assertHas(self.app, "sendOnceAtATime(post, inFlight,")
        self.assertHas(self.app, "<PendingCommands.Provider value={pending}>")
        # An answer lost with the link must not leave a button off.
        self.assertHas(self.app, "if (connected && !wasConnected.current) { inFlight.clear();")
        self.assertHas(self.app, "disabled={!action?.enabled || pending(command)}")
        self.assertHas(self.health, "disabled={!!reason || pending(action.command)}")
        self.assertHas(self.folders, "disabled={!source.canRemove || pending('removeSource')}")
        self.assertHas(self.picker, "pending('confirmSourcePicker')")
        start = self.restore[self.restore.index("const startRestore = () => {"):]
        start = start[:start.index("};")]
        self.assertHas(start, "pending('restoreFlowStart')) return;")
        self.assertHas(self.restore, "busy || pending('restoreFlowStart')} onClick={startRestore}")
        review = self.restore[self.restore.index("const goReview = () => {"):]
        review = review[:review.index("};")]
        self.assertHas(review, "pending('restoreFlowReview')) return;")
        self.assertHas(self.restore, "busy || pending('restoreFlowReview')} onClick={goReview}")

    def test_the_host_never_starts_a_second_folder_change(self) -> None:
        reason = self.body(self.window, "private string SourceChangeBlockedReason()")
        self.assertLess(reason.index("sourceOperationInProgress"), reason.index("BackupBlocksSourceChanges()"))
        apply = self.body(self.window, "private async Task ApplySourceChange(")
        self.assertTrue(re.search(r"^\{\s*(//[^\n]*\n\s*)*string blocked = SourceChangeBlockedReason\(\);", apply), apply[:300])
        remove = self.body(self.window, "private async void OnRemoveSourceClick(")
        after_dialog = remove[remove.index("ConfirmSourceRemoval(selected)"):]
        self.assertHas(after_dialog[:after_dialog.index('await ApplySourceChange("Remove"')], "SourceChangeBlockedReason()")


if __name__ == "__main__":
    unittest.main()
