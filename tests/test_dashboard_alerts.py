from __future__ import annotations

import re
import unittest
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
WEB = DASHBOARD / "web"

# Words the interface never uses (CONTRIBUTING: plain language). "Rewindle" is the product; these are the parts inside it.
INTERNAL_WORDS = ("repository", "snapshot", "engine", "canary", "restic", "protected task")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def string_literals(csharp: str) -> list[str]:
    """The ordinary C# string literals in a source file (comments left out)."""
    without_comments = re.sub(r"//[^\n]*", "", csharp)
    return [match.group(1) for match in re.finditer(r'(?<!@)"((?:[^"\\\n]|\\.)*)"', without_comments)]


def block(source: str, start_marker: str) -> str:
    """The text of the brace block that opens after start_marker."""
    start = source.index(start_marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"unbalanced block after {start_marker}")


def function_source(source: str, name: str) -> str:
    start = source.index(f"function {name}(")
    following = re.search(r"\n(?:function |export default function |const [A-Z_]+[:=]|// What )", source[start + 10:])
    return source[start:start + 10 + following.start()] if following else source[start:]


class BackupAlertsSourceTests(unittest.TestCase):
    """Backup alerts: the dashboard reads what Windows and the run history say and tells the person, without new rights."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.alerts = read(DASHBOARD / "BackupAlerts.cs")
        cls.glue = read(DASHBOARD / "DashboardWindow.Alerts.cs")
        cls.window = read(DASHBOARD / "DashboardWindow.cs")
        cls.web_host = read(DASHBOARD / "DashboardWindow.Web.cs")
        cls.schedule = read(DASHBOARD / "TaskSchedule.cs")
        cls.telemetry = read(DASHBOARD / "Telemetry.cs")
        cls.diagnostics = read(DASHBOARD / "DiagnosticExporter.cs")
        cls.program = read(DASHBOARD / "Program.cs")
        cls.build = read(DASHBOARD / "build.ps1")
        cls.launcher = read(PROJECT / "src" / "task_launcher" / "Program.cs")
        cls.types = read(WEB / "src" / "native-types.ts")
        cls.one_shot = read(WEB / "src" / "oneShot.ts")
        cls.app = read(WEB / "src" / "App.tsx")
        cls.tone = read(WEB / "src" / "protectionTone.ts")

    def test_the_alert_sources_are_built_into_the_dashboard(self) -> None:
        self.assertIn("(Join-Path $project 'BackupAlerts.cs')", self.build)
        self.assertIn("(Join-Path $project 'DashboardWindow.Alerts.cs')", self.build)

    def test_alerts_never_elevate_start_anything_or_touch_protected_paths(self) -> None:
        for name, text in (("BackupAlerts.cs", self.alerts), ("DashboardWindow.Alerts.cs", self.glue)):
            for forbidden in ("Process.Start", "runas", "Verb =", "schtasks", "ManagerPath(", "StateDirectory(", "InstallRoot(",
                              "TaskScheduleReader", "File.Delete(path", "Directory.Delete"):
                with self.subTest(file=name, forbidden=forbidden):
                    self.assertNotIn(forbidden, text)

    def test_alerts_name_no_engine(self) -> None:
        # EngineProfile owns every engine name; the alert code only asks it for the reinstall advice.
        for name, text in (("BackupAlerts.cs", self.alerts), ("DashboardWindow.Alerts.cs", self.glue)):
            for literal in string_literals(text):
                with self.subTest(file=name, literal=literal):
                    self.assertNotRegex(literal, r"(?i)restic|personalbackup")
            self.assertNotIn("EngineProfile.Legacy", text)
            self.assertNotIn("EngineProfile.Rewindle", text)
        self.assertIn("EngineProfile.Current.ReinstallAdvice()", self.alerts)

    def test_every_launcher_exit_code_is_explained(self) -> None:
        main = block(self.launcher, "private static int Main(")
        codes = {int(code) for code in re.findall(r"return (\d+);", main) if code != "0"}
        self.assertGreaterEqual(len(codes), 10, "the launcher no longer returns the codes this test reads")

        def listed(name: str) -> set[int]:
            match = re.search(name + r"\s*=\s*\{([^}]*)\}", self.alerts)
            self.assertIsNotNone(match, name)
            return {int(value) for value in re.findall(r"\d+", match.group(1))}

        program, start = listed("LauncherProgramCodes"), listed("LauncherStartCodes")
        self.assertFalse(program & start)
        self.assertIn("internal const int BusyCode = 75;", self.alerts)
        for code in sorted(codes):
            with self.subTest(code=code):
                self.assertTrue(code in program or code in start or code == 75, f"launcher code {code} has no explanation")
        self.assertEqual({64, 65, 66}, program)

    def test_the_last_run_is_read_on_its_own_and_never_fails_the_schedule(self) -> None:
        reader = block(self.schedule, "internal static void ReadLastRun(")
        self.assertEqual(2, reader.count("catch (Exception)"), "the time and the result are each read on their own")
        self.assertIn('"LastRunTime"', reader)
        self.assertIn('"LastTaskResult"', reader)
        runtime = block(self.schedule, "private static bool TryReadRuntimeInfo(")
        self.assertIn("ReadLastRun(task, out lastRunTime, out lastRunKnown, out lastTaskResult);", runtime)
        self.assertIn("internal static string DescribeTaskResult(int value)", self.schedule)

    def test_shared_sources_do_not_depend_on_the_alert_code(self) -> None:
        # Other suites compile TaskSchedule.cs, Telemetry.cs and DiagnosticExporter.cs without BackupAlerts.cs.
        for name, text in (("TaskSchedule.cs", self.schedule), ("Telemetry.cs", self.telemetry), ("DiagnosticExporter.cs", self.diagnostics)):
            for alert_type in ("AlertWording", "BackupAlert", "MissedRun", "FailedBackupCounter", "TrayBadge"):
                with self.subTest(file=name, type=alert_type):
                    self.assertNotIn(alert_type, text)

    def test_a_problem_report_carries_the_last_run(self) -> None:
        for key in ('value["last_run_known"]', 'value["last_run_time"]', 'value["last_task_result"]'):
            self.assertIn(key, self.diagnostics)

    def test_the_window_feeds_the_alerts_before_the_per_run_balloon(self) -> None:
        refresh = self.window[self.window.index("private void ApplyTelemetryRefresh("):]
        self.assertLess(refresh.index("UpdateBackupAlerts(snapshot);"), refresh.index("HandleStateTransition(snapshot);"))
        self.assertIn("UpdateBackupAlerts(null);", refresh[:refresh.index("HandleStateTransition(snapshot);")])
        self.assertIn("else if (snapshot.IsFailure && !alertToastShownThisRefresh)", self.window)
        self.assertIn("trayIcon = BuildTrayIcon();\n            InitializeBackupAlerts();", self.window)
        self.assertIn("NoteBackupAlertScheduleSaved(requested);", self.window)
        self.assertIn("DisposeBackupAlerts();", self.window)

    def test_session_switch_is_followed_on_the_ui_thread_and_released(self) -> None:
        self.assertIn("SystemEvents.PowerModeChanged += OnPowerModeChanged;\n            SystemEvents.SessionSwitch += OnSessionSwitch;", self.window)
        self.assertIn("SystemEvents.PowerModeChanged -= OnPowerModeChanged;\n            SystemEvents.SessionSwitch -= OnSessionSwitch;", self.window)
        handler = self.glue[self.glue.index("private void OnSessionSwitch("):self.glue.index("private void ApplyTrayBadge(")]
        self.assertIn("Dispatcher.BeginInvoke(", handler)

    def test_the_tray_mark_owns_its_icon_handles(self) -> None:
        self.assertIn("bitmap.GetHicon()", self.alerts)
        self.assertIn("private static extern bool DestroyIcon(IntPtr handle);", self.alerts)
        self.assertIn("trayIcon.BalloonTipClicked += OnTrayBalloonClicked;", self.glue)

    def test_only_an_alert_balloon_opens_protection_and_never_over_a_restore(self) -> None:
        opens = block(self.glue, "private bool AlertBalloonOpensProtection(")
        for guard in ("alertBalloon", "!restoreFlowOpen", "webRunDetails == null", "!sourcePickerOpen"):
            self.assertIn(guard, opens)
        # Each balloon gets a number and the alert keeps its own, so only a later balloon takes the alert's click away. Windows'
        # "balloon closed" can come for the balloon an alert replaced after the alert is up, so it is not used.
        self.assertIn("trayBalloonsShown = ", block(self.window, "private void ShowTrayMessage("))
        self.assertIn("trayAlertBalloon = trayBalloonsShown;", self.glue)
        self.assertIn("bool alert = NewestBalloonIsAlert();", block(self.glue, "private void OnTrayBalloonClicked("))
        self.assertNotIn("BalloonTipClosed", self.glue)
        self.assertNotIn("BalloonTipClosed", self.window)

    def test_the_page_is_told_and_the_switch_takes_only_on_or_off(self) -> None:
        self.assertIn('state["alerts"] = BuildWebAlertsState();', self.web_host)
        self.assertIn('if (string.Equals(command, "setAlerts", StringComparison.Ordinal))', self.web_host)
        command = block(self.glue, "private bool ExecuteAlertsCommand(")
        self.assertIn('WebReadString(payload, "notify", 8)', command)
        self.assertIn('value != "on" && value != "off"', command)
        self.assertIn('"The requested alert setting is not valid."', command)

    def test_the_switch_is_a_preference_not_a_protected_or_one_shot_command(self) -> None:
        self.assertIn("| 'setAlerts'", self.types)
        protected = self.types[self.types.index("export const PROTECTED_COMMANDS"):]
        protected = protected[:protected.index("]);")]
        self.assertNotIn("setAlerts", protected)
        one_shot = self.one_shot[self.one_shot.index("export const ONE_SHOT_COMMANDS"):]
        self.assertNotIn("setAlerts", one_shot[:one_shot.index("]);")])
        self.assertIn("alerts?: AlertsState;", self.types)

    def test_alerts_json_lives_beside_the_theme_settings_and_only_the_installed_dashboard_tells(self) -> None:
        self.assertIn('internal const string FileName = "alerts.json";', self.alerts)
        self.assertIn("DashboardThemeManager.SettingsPath", self.glue)
        self.assertIn("bool tells = options != null && !options.UseIsolatedPresentationStore && !options.UsesOtherStateDirectory;", self.glue)
        self.assertIn("new BackupAlertMonitor(new BackupAlertStore(directory), tells)", self.glue)
        # The logon task passes the engine's own state folder with --state-dir, so only another folder turns the telling off.
        engine = block(self.program, "internal void UseEngine(")
        self.assertIn("UsesOtherStateDirectory = !TaskScheduleReader.SamePath(StateDirectory, engineStateDirectory);", engine)

    def test_the_freshness_check_is_the_one_the_page_uses(self) -> None:
        evaluate = self.glue[self.glue.index("BackupFreshnessEvaluator.EvaluateNow("):]
        evaluate = evaluate[:evaluate.index(");") + 2]
        self.assertIn("scheduleCoveredThroughUtc", evaluate)
        self.assertIn("AvailableSinceUtc()", evaluate)

    def test_the_monitor_times_with_a_monotonic_clock(self) -> None:
        self.assertIn("Stopwatch.GetTimestamp", self.alerts)
        self.assertNotIn("DateTime.Now", self.alerts)
        self.assertNotIn("DateTime.Now", self.glue)

    def test_alert_words_are_plain(self) -> None:
        texts = string_literals(self.alerts) + string_literals(self.glue)
        texts.append(function_source(self.app, "AlertsSetting"))
        texts.append(self.tone[self.tone.index("export function alertConcern("):])
        for text in texts:
            for word in INTERNAL_WORDS:
                with self.subTest(text=text[:60], word=word):
                    self.assertNotIn(word, text.lower())

    def test_ci_runs_the_alert_and_task_schedule_suites(self) -> None:
        # Most of the alert behaviour is checked by these two PowerShell suites, so a later change can't break it unseen.
        ci = read(PROJECT / ".github" / "workflows" / "ci.yml")
        self.assertIn(".\\tests\\Test-BackupAlerts.ps1", ci)
        self.assertIn(".\\tests\\Test-TaskSchedule.ps1", ci)

    def test_a_pause_made_in_rewindle_is_kept_apart_from_the_told_problems(self) -> None:
        note = block(self.alerts, "internal void NoteUserPausedSchedule(")
        self.assertIn("store.SetUserPaused(true);", note)
        self.assertNotIn("RememberTold", note)
        self.assertIn('document["user_paused"] = userPaused;', self.alerts)

    def test_the_schedule_card_names_no_start_windows_did_not_make(self) -> None:
        card = block(self.glue, "private static Dictionary<string, object> BuildWebLastRunState(")
        self.assertIn("MissedRunExplainer.LastStartUtc(schedule, DateTime.UtcNow, TimeZoneInfo.Local)", card)
        start = block(self.alerts, "internal static DateTime? LastStartUtc(")
        self.assertIn("BackupAlertPolicy.NotSignedIn", start)

    def test_the_schedule_card_says_on_before_an_old_start(self) -> None:
        # formatWhenAgo gives a plain date for a start more than two weeks old; in this sentence it needs its "on".
        self.assertIn("Windows last started the backup {formatWhenAgoInSentence(lastStartedAt(state), locale)}.", self.app)

    def test_the_sample_data_shows_the_alerts(self) -> None:
        demo = read(WEB / "src" / "demo" / "demoState.ts")
        bridge = read(WEB / "src" / "demo" / "mockBridge.ts")
        self.assertIn("alerts: {", demo)
        self.assertIn("case 'setAlerts':", bridge)
        self.assertIn("applyAlertsScenario(state);", bridge)


if __name__ == "__main__":
    unittest.main()
