$ErrorActionPreference = 'Stop'

# Backup alerts (src/dashboard/BackupAlerts.cs): why a scheduled backup was missed, how many backups in a row failed, which
# alert a refresh raises, when a notification is shown, alerts.json, and the tray mark. Fixtures only: no task is queried,
# nothing is started, and every file is under a fresh folder in TEMP that is removed at the end.
$project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function Read-DashboardSource { param([string]$Name) return Get-Content -LiteralPath (Join-Path $project ('src\dashboard\' + $Name)) -Raw -Encoding UTF8 }

$harness = @'
namespace ResticBackuper.Dashboard
{
    using System;
    using System.Collections.Generic;
    using System.Globalization;
    using System.Linq;
    using System.Runtime.InteropServices;
    using System.Threading;

    public static class BackupAlertsFixtureHarness
    {
        // A fixture is "key=value;key=value". Missing keys take the defaults below.
        internal static Dictionary<string, string> Spec(string spec)
        {
            Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
            if (string.IsNullOrEmpty(spec))
            {
                return values;
            }
            foreach (string part in spec.Split(';'))
            {
                if (part.Length == 0)
                {
                    continue;
                }
                int equals = part.IndexOf('=');
                if (equals <= 0)
                {
                    throw new ArgumentException("Bad fixture part: " + part);
                }
                values[part.Substring(0, equals)] = part.Substring(equals + 1);
            }
            return values;
        }

        private static string Get(Dictionary<string, string> values, string key, string fallback)
        {
            string value;
            return values.TryGetValue(key, out value) ? value : fallback;
        }

        private static bool Flag(Dictionary<string, string> values, string key, bool fallback)
        {
            string value;
            if (!values.TryGetValue(key, out value))
            {
                return fallback;
            }
            if (value == "1")
            {
                return true;
            }
            if (value == "0")
            {
                return false;
            }
            throw new ArgumentException("Bad flag " + key + "=" + value);
        }

        private static bool? Maybe(Dictionary<string, string> values, string key)
        {
            if (!values.ContainsKey(key))
            {
                return null;
            }
            return Flag(values, key, false);
        }

        internal static DateTime Utc(string value)
        {
            return DateTime.SpecifyKind(
                DateTime.Parse(value.TrimEnd('Z'), CultureInfo.InvariantCulture),
                DateTimeKind.Utc);
        }

        private static int Code(string value)
        {
            if (value.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            {
                return unchecked((int)uint.Parse(value.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
            }
            return int.Parse(value, CultureInfo.InvariantCulture);
        }

        private static TimeZoneInfo Zone(string id)
        {
            return string.IsNullOrEmpty(id) ? TimeZoneInfo.Utc : TimeZoneInfo.FindSystemTimeZoneById(id);
        }

        // A daily 02:00 schedule. last=<local time>|never|unknown; result=<code>; catchup (run when next available) and battery
        // (may start on battery) default on; state=Ready|Running|Disabled; schedule=none for a schedule that could not be read.
        private static TaskSchedule Schedule(Dictionary<string, string> values)
        {
            if (Get(values, "schedule", string.Empty) == "none")
            {
                return null;
            }
            string last = Get(values, "last", "unknown");
            DateTime? lastRun = null;
            bool known = false;
            if (last == "never")
            {
                known = true;
            }
            else if (last != "unknown")
            {
                lastRun = DateTime.SpecifyKind(DateTime.Parse(last, CultureInfo.InvariantCulture), DateTimeKind.Unspecified);
                known = true;
            }
            string result = Get(values, "result", string.Empty);
            BackupTaskState state = (BackupTaskState)Enum.Parse(typeof(BackupTaskState), Get(values, "state", "Ready"));
            return new TaskSchedule(
                BackupScheduleCadence.Daily,
                new TimeSpan(2, 0, 0),
                null,
                new DayOfWeek[0],
                state != BackupTaskState.Disabled,
                Flag(values, "catchup", true),
                true,
                Flag(values, "battery", true),
                false,
                true,
                "FixtureTask",
                "fixture-user",
                "launcher.exe",
                "C:\\FixtureInstall",
                state,
                null,
                lastRun,
                known,
                result.Length == 0 ? (int?)null : Code(result),
                "fixture");
        }

        // "failed@2026-07-21T02:01,cancelled@...,dry:failed@...": a backup (or, with dry:, a dry run) in that end state,
        // started at that UTC time. An empty state is a record that names none.
        internal static List<RunMetricView> History(string value)
        {
            List<RunMetricView> runs = new List<RunMetricView>();
            if (string.IsNullOrEmpty(value))
            {
                return runs;
            }
            int index = 0;
            foreach (string item in value.Split(','))
            {
                int at = item.IndexOf('@');
                string state = item.Substring(0, at);
                string type = "backup";
                if (state.StartsWith("dry:", StringComparison.Ordinal))
                {
                    type = "dry_run";
                    state = state.Substring(4);
                }
                DateTime started = Utc(item.Substring(at + 1));
                RunMetricView run = new RunMetricView();
                run.RunId = "run-" + (index++).ToString(CultureInfo.InvariantCulture);
                run.TypeKey = type;
                run.StateKey = state;
                run.StartedUtc = started;
                run.StartedLocal = started;
                run.Success = state.StartsWith("success", StringComparison.Ordinal);
                runs.Add(run);
            }
            return runs;
        }

        private static MissedRunFacts Facts(Dictionary<string, string> values)
        {
            MissedRunFacts facts = new MissedRunFacts();
            facts.FreshnessState = (BackupFreshnessState)Enum.Parse(typeof(BackupFreshnessState), Get(values, "freshness", "Overdue"));
            string slot = Get(values, "slot", "2026-07-21T02:00:00Z");
            facts.LatestDueUtc = slot == "none" ? (DateTime?)null : Utc(slot);
            facts.NowUtc = Utc(Get(values, "now", "2026-07-21T09:00:00Z"));
            facts.Zone = Zone(Get(values, "zone", string.Empty));
            facts.Schedule = Schedule(values);
            facts.History = History(Get(values, "history", string.Empty));
            facts.RunActive = Flag(values, "active", false);
            facts.OnBattery = Maybe(values, "onbattery");
            facts.AwakeAtSlot = Maybe(values, "awake");
            facts.BackupDriveMissing = Flag(values, "drivemissing", false);
            facts.BackupDrive = Get(values, "drive", string.Empty);
            facts.RepairNeeded = Flag(values, "repair", false);
            facts.RepairBlocked = Flag(values, "blocked", false);
            facts.FailedRunHasDetails = Flag(values, "details", false);
            return facts;
        }

        // kind|tone|the moment the sentence is about (UTC)|the code, or "none".
        public static string Explain(string spec)
        {
            MissedRunExplanation explanation = MissedRunExplainer.Explain(Facts(Spec(spec)));
            if (explanation.Kind == MissedRunKind.None)
            {
                return "none";
            }
            return AlertWording.KindName(explanation.Kind) + "|" +
                AlertWording.ToneName(explanation.Tone) + "|" +
                (explanation.AtUtc.HasValue ? AlertWording.FormatUtc(explanation.AtUtc.Value) : string.Empty) + "|" +
                explanation.Code;
        }

        // The page's words: the reason, " / ", the next step (empty when it is the hero's own Back up now).
        public static string PageWords(string spec)
        {
            MissedRunFacts facts = Facts(Spec(spec));
            MissedRunExplanation explanation = MissedRunExplainer.Explain(facts);
            return explanation.Reason(true, facts.NowUtc, facts.Zone) + " / " + explanation.PageNextStep();
        }

        public static string NotificationWords(string spec, string culture)
        {
            CultureInfo saved = Thread.CurrentThread.CurrentCulture;
            try
            {
                Thread.CurrentThread.CurrentCulture = new CultureInfo(culture, false);
                MissedRunFacts facts = Facts(Spec(spec));
                MissedRunExplanation explanation = MissedRunExplainer.Explain(facts);
                return explanation.Reason(false, facts.NowUtc, facts.Zone) + " / " + explanation.NotificationNextStep();
            }
            finally
            {
                Thread.CurrentThread.CurrentCulture = saved;
            }
        }

        public static string Moment(string atUtc, string nowUtc, string culture, bool forPage, string zone)
        {
            CultureInfo saved = Thread.CurrentThread.CurrentCulture;
            try
            {
                Thread.CurrentThread.CurrentCulture = new CultureInfo(culture, false);
                return AlertWording.FormatMoment(Utc(atUtc), Utc(nowUtc), Zone(zone), forPage);
            }
            finally
            {
                Thread.CurrentThread.CurrentCulture = saved;
            }
        }

        public static string FormatCode(string code)
        {
            return AlertWording.FormatCode(Code(code));
        }

        public static string DriveOf(string path)
        {
            return AlertWording.DriveOf(path);
        }

        public static int CountFailed(string history, string verifiedUtc)
        {
            return FailedBackupCounter.CountInARow(
                History(history),
                string.IsNullOrEmpty(verifiedUtc) ? (DateTime?)null : Utc(verifiedUtc));
        }

        public static int[] LauncherCodes(bool program)
        {
            return (int[])(program ? BackupAlertPolicy.LauncherProgramCodes : BackupAlertPolicy.LauncherStartCodes).Clone();
        }

        public static int FailingRunThreshold()
        {
            return BackupAlertPolicy.FailingRunThreshold;
        }

        // Switches the engine profile for a wording check; Rewindle is put back by UseProfile("rewindle").
        public static void UseProfile(string id)
        {
            EngineProfile.Activate(EngineProfile.FromId(id));
        }

        public static string ProfileId()
        {
            return EngineProfile.Current.Id;
        }

        internal static MissedRunKind ParseKind(string name)
        {
            foreach (MissedRunKind kind in Enum.GetValues(typeof(MissedRunKind)))
            {
                if (kind != MissedRunKind.None && AlertWording.KindName(kind) == name)
                {
                    return kind;
                }
            }
            throw new ArgumentException("Unknown kind " + name);
        }

        public static string[] KindNames()
        {
            return Enum.GetValues(typeof(MissedRunKind))
                .Cast<MissedRunKind>()
                .Where(kind => kind != MissedRunKind.None)
                .Select(kind => AlertWording.KindName(kind))
                .ToArray();
        }

        private static readonly string[] MomentsBack =
        {
            "2026-07-21T02:00:00Z", "2026-07-20T23:59:00Z", "2026-07-19T12:00:00Z", "2026-07-18T12:00:00Z",
            "2026-07-17T12:00:00Z", "2026-07-16T12:00:00Z", "2026-07-15T23:00:00Z", "2026-07-10T22:30:00Z",
            "2025-09-30T23:30:00Z", "2025-12-24T13:45:00Z"
        };

        private static IEnumerable<MissedRunExplanation> Explanations(string at)
        {
            foreach (MissedRunKind kind in Enum.GetValues(typeof(MissedRunKind)))
            {
                if (kind == MissedRunKind.None)
                {
                    continue;
                }
                foreach (int? code in new int?[] { null, 66, unchecked((int)0x800710E0) })
                {
                    foreach (bool flag in new[] { false, true })
                    {
                        yield return new MissedRunExplanation(
                            kind,
                            MissedRunTone.Warning,
                            at == null ? (DateTime?)null : Utc(at),
                            code,
                            "D:",
                            flag,
                            flag);
                    }
                }
            }
        }

        // Every notification text the alerts can show, in this culture: each reason, each kind of missed run, each kind of
        // moment, with and without a verified backup or run details.
        public static string[] AllNotificationTexts(string culture)
        {
            CultureInfo saved = Thread.CurrentThread.CurrentCulture;
            List<string> texts = new List<string>();
            try
            {
                Thread.CurrentThread.CurrentCulture = new CultureInfo(culture, false);
                DateTime now = Utc("2026-07-21T09:00:00Z");
                foreach (string at in MomentsBack.Concat(new string[] { null }))
                {
                    foreach (MissedRunExplanation explanation in Explanations(at))
                    {
                        BackupAlert alert = new BackupAlert(
                            BackupAlertLevel.Attention, BackupAlertReason.Overdue, "overdue|none", 0, null, explanation, false);
                        texts.Add(alert.NotificationTitle() + "\n" + alert.NotificationText(now, TimeZoneInfo.Utc));
                    }
                }
                foreach (BackupAlertReason reason in Enum.GetValues(typeof(BackupAlertReason)))
                {
                    if (reason == BackupAlertReason.None)
                    {
                        continue;
                    }
                    foreach (int failed in new[] { 3, 12, 999 })
                    {
                        foreach (bool verified in new[] { false, true })
                        {
                            foreach (bool details in new[] { false, true })
                            {
                                BackupAlert alert = new BackupAlert(
                                    reason == BackupAlertReason.Failing ? BackupAlertLevel.Failing : BackupAlertLevel.Attention,
                                    reason,
                                    AlertWording.ReasonName(reason) + "|none",
                                    failed,
                                    verified ? (DateTime?)Utc("2026-07-19T02:30:00Z") : null,
                                    MissedRunExplanation.None,
                                    details);
                                texts.Add(alert.NotificationTitle() + "\n" + alert.NotificationText(now, TimeZoneInfo.Utc));
                            }
                        }
                    }
                }
            }
            finally
            {
                Thread.CurrentThread.CurrentCulture = saved;
            }
            return texts.ToArray();
        }

        // Every sentence the page can show for a missed run, each followed by its next step (which may be empty).
        public static string[] AllPageTexts()
        {
            List<string> texts = new List<string>();
            DateTime now = Utc("2026-07-21T09:00:00Z");
            foreach (string at in MomentsBack.Concat(new string[] { null }))
            {
                foreach (MissedRunExplanation explanation in Explanations(at))
                {
                    texts.Add(explanation.Reason(true, now, TimeZoneInfo.Utc) + "\n" + explanation.PageNextStep());
                }
            }
            return texts.ToArray();
        }

        // status (readable), schedule (readable), freshness, verified (UTC or none), slot, failed, active, details, kind.
        internal static BackupAlertInputs Inputs(Dictionary<string, string> values)
        {
            BackupAlertInputs inputs = new BackupAlertInputs();
            inputs.StatusReadable = Flag(values, "status", true);
            inputs.ScheduleReadable = Flag(values, "schedule", true);
            string freshness = Get(values, "freshness", "Healthy");
            string verified = Get(values, "verified", "2026-07-20T02:30:00Z");
            DateTime? verifiedUtc = verified == "none" ? (DateTime?)null : Utc(verified);
            DateTime slot = Utc(Get(values, "slot", "2026-07-21T02:00:00Z"));
            inputs.Freshness = freshness == "null"
                ? null
                : new BackupFreshnessResult(
                    (BackupFreshnessState)Enum.Parse(typeof(BackupFreshnessState), freshness),
                    verifiedUtc,
                    null,
                    slot,
                    slot,
                    null,
                    freshness,
                    string.Empty);
            inputs.LastVerifiedUtc = verifiedUtc;
            inputs.RunActive = Flag(values, "active", false);
            inputs.FailedInARow = int.Parse(Get(values, "failed", "0"), CultureInfo.InvariantCulture);
            inputs.FailedRunHasDetails = Flag(values, "details", false);
            string kind = Get(values, "kind", string.Empty);
            inputs.Explanation = kind.Length == 0
                ? MissedRunExplanation.None
                : new MissedRunExplanation(ParseKind(kind), MissedRunTone.Warning, slot, null, string.Empty, false, false);
            return inputs;
        }

        // level|reason|episode key, after the previous refresh's alert (empty: none yet).
        public static string Evaluate(string previousSpec, string spec, bool scheduleUnreadableTooLong)
        {
            BackupAlert previous = null;
            if (!string.IsNullOrEmpty(previousSpec))
            {
                previous = BackupAlertEvaluator.Evaluate(Inputs(Spec(previousSpec)), null, false);
            }
            BackupAlert alert = BackupAlertEvaluator.Evaluate(Inputs(Spec(spec)), previous, scheduleUnreadableTooLong);
            return AlertWording.LevelName(alert.Level) + "|" + AlertWording.ReasonName(alert.Reason) + "|" + alert.EpisodeKey;
        }

        // The freshness check and the explainer together, as the dashboard runs them: a daily 02:00 schedule in UTC, verified
        // at 02:30 the day before, Task Scheduler's last run and result, and the moment the PC came back.
        public static string Integrated(string lastRunLocal, string result, string availableSinceUtc, string nowUtc, int failed)
        {
            Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
            values["last"] = string.IsNullOrEmpty(lastRunLocal) ? "never" : lastRunLocal;
            if (!string.IsNullOrEmpty(result))
            {
                values["result"] = result;
            }
            TaskSchedule schedule = Schedule(values);
            DateTime now = Utc(nowUtc);
            DateTime verified = Utc("2026-07-20T02:30:00Z");
            BackupFreshnessResult freshness = BackupFreshnessEvaluator.Evaluate(
                schedule,
                verified,
                DateTime.SpecifyKind(now, DateTimeKind.Unspecified),
                now,
                TimeZoneInfo.Utc,
                BackupFreshnessEvaluator.DefaultGracePeriod,
                null,
                string.IsNullOrEmpty(availableSinceUtc) ? (DateTime?)null : Utc(availableSinceUtc),
                BackupFreshnessEvaluator.DefaultCatchUpWindow);
            MissedRunFacts facts = new MissedRunFacts();
            facts.FreshnessState = freshness.State;
            facts.LatestDueUtc = freshness.LatestDueUtc;
            facts.NowUtc = now;
            facts.Zone = TimeZoneInfo.Utc;
            facts.Schedule = schedule;
            facts.History = new List<RunMetricView>();
            MissedRunExplanation explanation = MissedRunExplainer.Explain(facts);
            BackupAlertInputs inputs = new BackupAlertInputs();
            inputs.StatusReadable = true;
            inputs.ScheduleReadable = true;
            inputs.Freshness = freshness;
            inputs.LastVerifiedUtc = verified;
            inputs.FailedInARow = failed;
            inputs.Explanation = explanation;
            BackupAlert alert = BackupAlertEvaluator.Evaluate(inputs, null, false);
            return freshness.State.ToString() + "|" +
                (explanation.Kind == MissedRunKind.None ? "none" : AlertWording.KindName(explanation.Kind)) + "|" +
                AlertWording.LevelName(alert.Level) + "|" + AlertWording.ReasonName(alert.Reason);
        }
    }

    // Drives a BackupAlertMonitor with fake clocks (one tick a millisecond) and a store in a fixture folder.
    public sealed class AlertMonitorDriver
    {
        private long ticks;
        private DateTime utc = BackupAlertsFixtureHarness.Utc("2026-07-21T09:00:00Z");
        private readonly BackupAlertStore store;
        private readonly BackupAlertMonitor monitor;

        public AlertMonitorDriver(string directory, bool notificationsAllowed)
        {
            store = new BackupAlertStore(directory, delegate { return utc; });
            monitor = new BackupAlertMonitor(store, delegate { return ticks; }, 1000, delegate { return utc; }, notificationsAllowed);
        }

        public void Advance(double minutes)
        {
            ticks += (long)(minutes * 60 * 1000);
            utc = utc.AddMinutes(minutes);
        }

        // presence: present, away (no input lately or locked), front (Rewindle in front), quiet (preview), none (unknown).
        // Returns "" or the notification's "title|text".
        public string Update(string spec, string presence)
        {
            BackupAlertPresence seen = null;
            if (presence != "none")
            {
                seen = new BackupAlertPresence();
                seen.UserActive = presence == "present" || presence == "front";
                seen.WindowInFront = presence == "front";
                seen.Quiet = presence == "quiet";
            }
            BackupAlertNotification notification = monitor.Update(
                BackupAlertsFixtureHarness.Inputs(BackupAlertsFixtureHarness.Spec(spec)),
                seen);
            return notification == null ? string.Empty : notification.Title + "|" + notification.Text;
        }

        public string Mark
        {
            get
            {
                return AlertWording.LevelName(monitor.Current.Level) + "|" + AlertWording.ReasonName(monitor.Current.Reason);
            }
        }

        public int LastFailedInARow
        {
            get { return monitor.LastFailedInARow; }
        }

        public string LastExplanation
        {
            get { return AlertWording.KindName(monitor.LastExplanation.Kind); }
        }

        public bool NotificationsOn
        {
            get { return monitor.NotificationsOn; }
        }

        public bool WasTold(string key)
        {
            return store.WasTold(key);
        }

        public void NoteUserPausedSchedule()
        {
            monitor.NoteUserPausedSchedule();
        }

        public bool UserPausedSchedule
        {
            get { return monitor.UserPausedSchedule; }
        }

        public bool SetNotifications(bool on)
        {
            return monitor.SetNotifications(on);
        }
    }

    public sealed class AlertStoreProbe
    {
        private readonly BackupAlertStore store;

        public AlertStoreProbe(string directory, string nowUtc)
        {
            DateTime now = BackupAlertsFixtureHarness.Utc(nowUtc);
            store = new BackupAlertStore(directory, delegate { return now; });
        }

        public bool Notify
        {
            get { return store.Notify; }
        }

        public bool Persists
        {
            get { return store.Persists; }
        }

        public string FilePath
        {
            get { return store.FilePath; }
        }

        public bool WasTold(string key)
        {
            return store.WasTold(key);
        }

        public void Remember(string key, string atUtc)
        {
            store.Remember(key, BackupAlertsFixtureHarness.Utc(atUtc));
        }

        public bool SetNotify(bool on)
        {
            return store.TrySetNotify(on);
        }

        public bool UserPaused
        {
            get { return store.UserPaused; }
        }

        public void SetUserPaused(bool paused)
        {
            store.SetUserPaused(paused);
        }

        public static bool IsValidKey(string key)
        {
            return BackupAlertStore.IsValidKey(key);
        }
    }

    // Draws the tray mark on a plain blue icon and counts what is in the mark's corner.
    public static class TrayBadgeProbe
    {
        private static readonly System.Drawing.Color BaseColor = System.Drawing.Color.FromArgb(255, 0x20, 0x60, 0xC0);

        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr handle);

        private static bool Near(System.Drawing.Color actual, System.Drawing.Color expected, int tolerance)
        {
            return actual.A == 255 &&
                Math.Abs(actual.R - expected.R) <= tolerance &&
                Math.Abs(actual.G - expected.G) <= tolerance &&
                Math.Abs(actual.B - expected.B) <= tolerance;
        }

        private static IntPtr MakeBase(out System.Drawing.Icon icon)
        {
            using (System.Drawing.Bitmap plain = new System.Drawing.Bitmap(32, 32, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
            {
                using (System.Drawing.Graphics graphics = System.Drawing.Graphics.FromImage(plain))
                {
                    graphics.Clear(BaseColor);
                }
                IntPtr handle = plain.GetHicon();
                icon = System.Drawing.Icon.FromHandle(handle);
                return handle;
            }
        }

        private static BackupAlertLevel Level(string level)
        {
            return level == "failing"
                ? BackupAlertLevel.Failing
                : level == "attention" ? BackupAlertLevel.Attention : BackupAlertLevel.None;
        }

        // "null", or counts in the mark's square: amber fill, red fill, halo, the amber and red marks' "!", and whether the
        // top-left of the icon is still the plain blue.
        public static string Describe(string level, int size)
        {
            System.Drawing.Icon baseIcon;
            IntPtr handle = MakeBase(out baseIcon);
            try
            {
                using (System.Drawing.Bitmap bitmap = TrayBadgeRenderer.Draw(baseIcon, Level(level), size))
                {
                    if (bitmap == null)
                    {
                        return "null";
                    }
                    int badge = TrayBadgeRenderer.BadgeSize(bitmap.Width);
                    int amber = 0;
                    int red = 0;
                    int halo = 0;
                    int amberMark = 0;
                    int redMark = 0;
                    for (int y = bitmap.Height - badge; y < bitmap.Height; y++)
                    {
                        for (int x = bitmap.Width - badge; x < bitmap.Width; x++)
                        {
                            System.Drawing.Color pixel = bitmap.GetPixel(x, y);
                            if (Near(pixel, TrayBadgeRenderer.AttentionFill, 3)) { amber++; }
                            if (Near(pixel, TrayBadgeRenderer.FailingFill, 3)) { red++; }
                            if (Near(pixel, TrayBadgeRenderer.Halo, 16)) { halo++; }
                            if (Near(pixel, TrayBadgeRenderer.AttentionMark, 0)) { amberMark++; }
                            if (Near(pixel, TrayBadgeRenderer.FailingMark, 0)) { redMark++; }
                        }
                    }
                    int corner = bitmap.Width / 4;
                    bool baseKept = Near(bitmap.GetPixel(corner, corner), BaseColor, 4);
                    return "size=" + bitmap.Width.ToString(CultureInfo.InvariantCulture) +
                        ";amber=" + amber.ToString(CultureInfo.InvariantCulture) +
                        ";red=" + red.ToString(CultureInfo.InvariantCulture) +
                        ";halo=" + halo.ToString(CultureInfo.InvariantCulture) +
                        ";amberMark=" + amberMark.ToString(CultureInfo.InvariantCulture) +
                        ";redMark=" + redMark.ToString(CultureInfo.InvariantCulture) +
                        ";base=" + (baseKept ? "1" : "0");
                }
            }
            finally
            {
                baseIcon.Dispose();
                DestroyIcon(handle);
            }
        }

        // Builds the icon the tray shows, disposes it twice, and returns its width (0 for no mark).
        public static int ComposeAndDisposeTwice(string level, int size)
        {
            System.Drawing.Icon baseIcon;
            IntPtr handle = MakeBase(out baseIcon);
            try
            {
                TrayBadgeIcon icon = TrayBadgeRenderer.Compose(baseIcon, Level(level), size);
                if (icon == null)
                {
                    return 0;
                }
                int width = icon.Icon.Width;
                icon.Dispose();
                icon.Dispose();
                return width;
            }
            finally
            {
                baseIcon.Dispose();
                DestroyIcon(handle);
            }
        }
    }
}
'@

$sourceParts = @(
    (Read-DashboardSource 'EngineProfile.cs'),
    (Read-DashboardSource 'AtomicFile.cs'),
    (Read-DashboardSource 'ElevatedRequestSecurity.cs'),
    (Read-DashboardSource 'SourceConfiguration.cs'),
    (Read-DashboardSource 'ProcessLiveness.cs'),
    (Read-DashboardSource 'Telemetry.cs'),
    (Read-DashboardSource 'TaskSchedule.cs'),
    (Read-DashboardSource 'BackupFreshness.cs'),
    (Read-DashboardSource 'BackupAlerts.cs')
)
$usingPattern = '(?m)^using\s+[^;]+;\s*\r?\n'
$allUsings = @($sourceParts | ForEach-Object {
    [regex]::Matches($_, $usingPattern) | ForEach-Object { $_.Value.Trim() }
} | Sort-Object -Unique)
$sourceBodies = @($sourceParts | ForEach-Object { [regex]::Replace($_, $usingPattern, '') })
$combinedSource = ($allUsings -join [Environment]::NewLine) +
    [Environment]::NewLine + ($sourceBodies -join [Environment]::NewLine) +
    [Environment]::NewLine + $harness

Add-Type -TypeDefinition $combinedSource -ReferencedAssemblies @(
    'System.dll',
    'System.Core.dll',
    'System.Xml.dll',
    'System.Web.Extensions.dll',
    'System.Drawing.dll'
)

$script:tests = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $script:tests++
    if ($Expected -cne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:tests++
    if (-not $Condition) {
        throw $Message
    }
}

$H = [ResticBackuper.Dashboard.BackupAlertsFixtureHarness]
$q = [string][char]0x2019
$lq = [string][char]0x201C
$rq = [string][char]0x201D
function Explain { param([string]$Spec) return $H::Explain($Spec) }

# --- Why the latest scheduled backup was missed -------------------------------------------------------------------------
# The fixtures are a daily 02:00 backup in UTC, missed on Tuesday 2026-07-21, looked at at 09:00.
$slot = '2026-07-21T02:00:00Z'
Assert-Equal 'none' (Explain 'freshness=Healthy;last=2026-07-21T02:00;result=66') 'Nothing is explained while backups are on time.'
Assert-Equal 'none' (Explain 'freshness=CatchingUp;last=2026-07-20T02:00;result=0') 'Catching up is never explained as a missed backup.'
Assert-Equal 'none' (Explain 'freshness=NoVerifiedBackup;last=2026-07-21T02:00;result=66') 'Only an overdue backup is explained.'
Assert-Equal 'none' (Explain 'slot=none;last=2026-07-21T02:00;result=66') 'Without a missed slot there is nothing to explain.'
Assert-Equal 'none' (Explain 'active=1;last=2026-07-21T02:00;result=66') 'Nothing is explained while a backup runs.'
Assert-Equal 'none' (Explain 'state=Running;last=2026-07-21T02:00;result=66') 'Nothing is explained while Windows runs the task.'

# A missing backup drive comes first, even over a run record; it names the drive and is red.
Assert-Equal "driveMissing|danger|$slot|" (Explain 'drivemissing=1;drive=D:;history=failed@2026-07-21T02:01;last=2026-07-21T02:00;result=1') 'An unplugged backup drive must win.'
Assert-Equal "The backup drive (D:) isn${q}t connected, so the backup due today at 02:00 couldn${q}t run. / Plug it back in, then choose Back up now." (
    $H::PageWords('drivemissing=1;drive=D:')) 'The drive sentence must name the drive and the next step.'
Assert-Equal 'D:' ($H::DriveOf('d:\Backups\Plan')) 'The drive letter must be read from the backup location.'
Assert-Equal '' ($H::DriveOf('\\server\share\Backups')) 'A network share names no drive.'

# An unfinished move of the backup location: repair it, or (when it can't be repaired) save a problem report.
Assert-Equal 'repairPending|danger||' (Explain 'repair=1;history=failed@2026-07-21T02:01') 'A move to repair must come before a run record.'
$repair = $H::PageWords('repair=1')
Assert-True ($repair.EndsWith('/ Choose Repair interrupted move.')) "A move that can be repaired must name the repair button. Got '$repair'."
$blocked = $H::PageWords('blocked=1')
Assert-True ($blocked.EndsWith('/ Choose Save problem report in Settings.')) "A move that can't be repaired must ask for a problem report. Got '$blocked'."
Assert-True (-not $blocked.Contains('Repair interrupted move')) 'A move that cannot be repaired must not name the repair button.'
Assert-True ($H::NotificationWords('blocked=1', 'en-GB').EndsWith('Open Rewindle and choose Save problem report in Settings.')) 'The notification must say the same.'

# A run record says more than Task Scheduler's result, and has details to open.
Assert-Equal 'ranAndFailed|danger|2026-07-21T02:01:00Z|' (Explain 'history=failed@2026-07-21T02:01;last=2026-07-21T02:00;result=0x800710E0') 'A failed run must beat the result Windows recorded.'
Assert-Equal 'ranAndFailed|danger|2026-07-21T02:01:00Z|' (Explain 'history=partial@2026-07-21T02:01') 'A backup that missed some files must count as failed.'
Assert-Equal 'cancelled|warning|2026-07-21T02:03:00Z|' (Explain 'history=cancelled@2026-07-21T02:03') 'A stopped run must say it was stopped.'
Assert-Equal 'cancelled|warning|2026-07-21T02:03:00Z|' (Explain 'history=cancel_failed@2026-07-21T02:03') 'A run whose stop did not finish cleanly was still stopped.'
Assert-Equal 'ranAndFailed|danger|2026-07-21T01:59:00Z|' (Explain 'history=failed@2026-07-21T01:59') 'A run that started a minute early is the attempt for the slot.'
Assert-Equal 'unknown|warning|2026-07-21T02:00:00Z|' (Explain 'history=failed@2026-07-21T01:57') 'A run three minutes before the slot is not the attempt for it.'
Assert-Equal 'unknown|warning|2026-07-21T02:00:00Z|' (Explain 'history=dry:failed@2026-07-21T02:01') 'A dry run is not a backup.'
Assert-Equal 'ranAndFailed|danger|2026-07-21T05:00:00Z|' (Explain 'history=failed@2026-07-21T02:01,failed@2026-07-21T05:00') 'The newest run since the slot is the one explained.'
Assert-Equal "The backup that started today at 02:01 didn${q}t finish. / Choose See what happened." ($H::PageWords('details=1;history=failed@2026-07-21T02:01')) 'A failed run with details must point to them.'
Assert-Equal "The backup that started today at 02:01 didn${q}t finish. / Open Activity and choose the failed backup." ($H::PageWords('history=failed@2026-07-21T02:01')) 'A failed run without details must point to Activity.'

# Without a schedule, or a last run Windows would not report, nothing more than "it didn't happen" is said.
Assert-Equal "unknown|warning|$slot|" (Explain 'schedule=none') 'A schedule that could not be read must explain nothing more.'
Assert-Equal "unknown|warning|$slot|" (Explain 'last=unknown;result=66') 'An unread last run must explain nothing more.'
Assert-Equal "The backup due today at 02:00 didn${q}t happen. / " ($H::PageWords('schedule=none')) 'The plain sentence must name the slot and leave the hero its Back up now.'

# Windows started the backup at the slot: what it recorded.
foreach ($result in @('0', '0x00041301', '0x00041303')) {
    Assert-Equal "unknown|warning|$slot|" (Explain "last=2026-07-21T02:00;result=$result") "A start that recorded $result must explain nothing more."
}
Assert-Equal "unknown|warning|$slot|" (Explain 'last=2026-07-21T02:00') 'A start with no result must explain nothing more.'
foreach ($busy in @(@('75', 'code 75'), @('0x8004131F', 'error 0x8004131F'), @('0x80070420', 'error 0x80070420'))) {
    Assert-Equal ("busy|warning|$slot|" + $busy[1]) (Explain ('last=2026-07-21T02:00;result=' + $busy[0])) "Result $($busy[0]) must read as busy."
}
Assert-Equal "Windows started the backup today at 02:00, but Rewindle was busy with another job, or a change it was making hadn${q}t finished. / If it happens again, save a problem report in Settings." (
    $H::PageWords('last=2026-07-21T02:00;result=75')) 'Busy must be hedged: it can be another job or an unfinished change.'
foreach ($stopped in @('0xC000013A', '0x00041306', '0x8007042B', '0x800704C7')) {
    Assert-Equal "cancelled|warning|$slot|error $stopped" (Explain "last=2026-07-21T02:00;result=$stopped") "Result $stopped must read as stopped."
}
Assert-Equal 'waitingForPower|warning||' (Explain 'last=2026-07-21T02:00;result=0x800710E0;battery=0;onbattery=1') 'Conditions not met on battery with Wait for AC power must say so.'
Assert-Equal "couldNotStart|warning|$slot|error 0x800710E0" (Explain 'last=2026-07-21T02:00;result=0x800710E0;battery=0;onbattery=0') 'Conditions not met on AC power must give the code.'
Assert-Equal "couldNotStart|warning|$slot|error 0x800710E0" (Explain 'last=2026-07-21T02:00;result=0x800710E0;battery=1;onbattery=1') 'A schedule that may start on battery is not waiting for power.'
foreach ($code in $H::LauncherCodes($true)) {
    Assert-Equal "programProblem|danger|$slot|code $code" (Explain "last=2026-07-21T02:00;result=$code") "Launcher code $code means the program is not as installed."
}
foreach ($code in $H::LauncherCodes($false)) {
    Assert-Equal "couldNotStart|warning|$slot|code $code" (Explain "last=2026-07-21T02:00;result=$code") "Launcher code $code means it could not start."
}
Assert-Equal "couldNotStart|warning|$slot|code 1" (Explain 'last=2026-07-21T02:00;result=1') 'Any other code means it could not start.'
Assert-Equal "couldNotStart|warning|$slot|error 0x80070002" (Explain 'last=2026-07-21T02:00;result=0x80070002') 'A Windows error means it could not start.'
Assert-Equal "Windows tried to run the backup today at 02:00, but it stopped with error 0x80070002. / If it happens again, save a problem report in Settings." (
    $H::PageWords('last=2026-07-21T02:00;result=0x80070002')) 'The could-not-start sentence must carry the code.'
Assert-Equal "programProblem|danger|2026-07-21T01:59:00Z|code 66" (Explain 'last=2026-07-21T01:59;result=66') 'A start a minute before the slot is the attempt.'
Assert-Equal "pcOff|warning|$slot|" (Explain 'last=2026-07-21T01:57;result=66') 'A start three minutes before the slot is the run before.'
Assert-Equal "programProblem|danger|$slot|code 66" (Explain 'zone=W. Europe Standard Time;last=2026-07-21T04:00;result=66') 'The last run is a local time and must be converted with the PC zone.'
Assert-Equal "unknown|warning|$slot|" (Explain 'last=2026-07-23T09:00;result=66') 'A last run two days ahead of the clock must not be believed.'

# Windows has not started the backup since the slot.
Assert-Equal "pcOff|warning|$slot|" (Explain 'last=2026-07-20T02:00;result=0') 'A slot passed with no start, catch-up on: the PC was off, asleep or signed out.'
Assert-Equal "pcOff|warning|$slot|" (Explain 'last=never') 'A task that never ran was not started either.'
Assert-Equal "pcOff|warning|$slot|" (Explain 'last=2026-07-21T02:00;result=0x800704DD') 'Not signed in counts as not started.'
Assert-Equal "noCatchUp|warning|$slot|" (Explain 'last=2026-07-20T02:00;result=0;catchup=0') 'Without catch-up, the next slot is waited for.'
Assert-Equal 'waitingForPower|warning||' (Explain 'last=2026-07-20T02:00;result=0;battery=0;onbattery=1') 'On battery with Wait for AC power, it waits for power.'
Assert-Equal "pcOff|warning|$slot|" (Explain 'last=2026-07-20T02:00;result=0;battery=1;onbattery=1') 'On battery is not a reason when it may start on battery.'
Assert-Equal "pcOff|warning|$slot|" (Explain 'last=2026-07-20T02:00;result=0;battery=0') 'An unknown power source is not a reason.'
Assert-Equal "unknown|warning|$slot|" (Explain 'last=2026-07-20T02:00;result=0;awake=1') 'A PC seen awake at the slot must not be called off or asleep.'
Assert-Equal "The PC was off, asleep or signed out today at 02:00, and Windows hasn${q}t run the missed backup yet. / " (
    $H::PageWords('last=2026-07-20T02:00;result=0')) 'The off-or-asleep sentence must not claim which it was.'
Assert-Equal "The PC was off, asleep or signed out today at 02:00, and the schedule waits for the next time instead of catching up. / To catch up by itself next time, turn on ${lq}Run when the PC is next available${rq} in Edit schedule." (
    $H::PageWords('last=2026-07-20T02:00;result=0;catchup=0')) 'No catch-up must name the schedule option.'
Assert-Equal "This PC is on battery, and the backup is set to wait for AC power. / Plug the PC in, or choose ${lq}May start on battery${rq} in Edit schedule." (
    $H::PageWords('last=2026-07-20T02:00;result=0;battery=0;onbattery=1')) 'Waiting for power must name the plug and the option.'

# The freshness check and the explainer together: Catching up is never an alert; once the catch-up time is over it is overdue.
Assert-Equal 'CatchingUp|none|none|' ($H::Integrated('2026-07-20T02:00:00', '0', '2026-07-21T08:50:00Z', '2026-07-21T09:00:00Z', 0)) 'Catching up must give no explanation and no alert.'
Assert-Equal 'Overdue|pcOff|attention|overdue' ($H::Integrated('2026-07-20T02:00:00', '0', '2026-07-21T08:00:00Z', '2026-07-21T09:00:00Z', 0)) 'After the catch-up time the backup is overdue.'
Assert-Equal 'Overdue|programProblem|attention|overdue' ($H::Integrated('2026-07-21T02:00:00', '66', '', '2026-07-21T09:00:00Z', 0)) 'An overdue slot with a launcher code must explain it.'
Assert-Equal 'CatchingUp|none|failing|failing' ($H::Integrated('2026-07-20T02:00:00', '0', '2026-07-21T08:50:00Z', '2026-07-21T09:00:00Z', 3)) 'Three failures in a row are red even while catching up.'

# --- Codes and moments ------------------------------------------------------------------------------------------------
Assert-Equal 'code 66' ($H::FormatCode('66')) 'An exit code must read as a code.'
Assert-Equal 'error 0x800710E0' ($H::FormatCode('0x800710E0')) 'A Windows result must read as an error in hex.'
Assert-Equal 'error 0x00041306' ($H::FormatCode('0x00041306')) 'A large positive result must read as hex too.'
Assert-Equal 'today at 2:00 AM' ($H::Moment('2026-07-21T02:00:00Z', '2026-07-21T05:00:00Z', 'en-US', $false, '')) 'A notification uses the regional clock.'
Assert-Equal 'today at 02:00' ($H::Moment('2026-07-21T02:00:00Z', '2026-07-21T05:00:00Z', 'en-GB', $false, '')) 'A notification uses the regional clock (24-hour).'
Assert-Equal 'today at 02:00' ($H::Moment('2026-07-21T02:00:00Z', '2026-07-21T05:00:00Z', 'en-US', $true, '')) 'The page gets a 24-hour time to put in the viewer clock.'
Assert-Equal 'yesterday at 23:30' ($H::Moment('2026-07-20T23:30:00Z', '2026-07-21T05:00:00Z', 'en-US', $true, '')) 'The day before reads as yesterday.'
Assert-Equal 'on Saturday at 02:00' ($H::Moment('2026-07-18T02:00:00Z', '2026-07-21T05:00:00Z', 'en-GB', $true, '')) 'Within the week the day is named.'
Assert-Equal 'on 10 Jul at 02:00' ($H::Moment('2026-07-10T02:00:00Z', '2026-07-21T05:00:00Z', 'en-GB', $true, '')) 'Older moments read as a date.'
Assert-Equal 'today at 01:30' ($H::Moment('2026-07-20T23:30:00Z', '2026-07-21T05:00:00Z', 'en-GB', $true, 'W. Europe Standard Time')) 'The day is the day in the PC zone.'

# --- Every sentence: one reason and one next step, short, plain, no internal words --------------------------------------
# Each check below runs over every sentence and counts as one test; the first sentence that breaks it is named.
$banned = @('repository', 'snapshot', 'engine', 'canary', 'restic', 'protected task')
function Find-Internal {
    param([string]$Text)
    foreach ($word in $banned) {
        if ($Text.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $word }
    }
    return ''
}
function Assert-NoProblem {
    param([System.Collections.Generic.List[string]]$Problems, [string]$Message)
    Assert-True ($Problems.Count -eq 0) ("$Message " + $(if ($Problems.Count -gt 0) { $Problems[0] } else { '' }))
}
$cultures = @('en-US', 'en-GB', 'pt-BR', 'de-DE', 'fr-FR', 'es-ES', 'nl-NL')
$longest = 0
foreach ($profile in @('rewindle', 'legacy')) {
    $H::UseProfile($profile)
    try {
        $empty = New-Object 'System.Collections.Generic.List[string]'
        $tooLong = New-Object 'System.Collections.Generic.List[string]'
        $unfinished = New-Object 'System.Collections.Generic.List[string]'
        $pathLike = New-Object 'System.Collections.Generic.List[string]'
        $internal = New-Object 'System.Collections.Generic.List[string]'
        $count = 0
        foreach ($culture in $cultures) {
            foreach ($entry in $H::AllNotificationTexts($culture)) {
                $count++
                $parts = $entry.Split("`n")
                $title = $parts[0]
                $text = $parts[1]
                if ($title.Length -eq 0 -or $text.Length -eq 0) { $empty.Add("($culture) '$entry'") }
                if ($text.Length -gt 220) { $tooLong.Add("($culture, $($text.Length)) '$text'") }
                if (-not $text.EndsWith('.')) { $unfinished.Add("($culture) '$text'") }
                if ($text.Contains('\') -or $text.Contains('  ') -or $text.Contains('()')) { $pathLike.Add("($culture) '$text'") }
                $word = Find-Internal $entry
                if ($word) { $internal.Add("($culture, '$word') '$entry'") }
                if ($text.Length -gt $longest) { $longest = $text.Length }
            }
        }
        Assert-True ($count -gt 1000) "Every reason, kind and moment must be checked ($profile, $count)."
        Assert-NoProblem $empty "Every notification needs a title and text ($profile)."
        Assert-NoProblem $tooLong "A notification must fit the 220 characters Windows keeps ($profile)."
        Assert-NoProblem $unfinished "A notification must end with a full stop ($profile)."
        Assert-NoProblem $pathLike "A notification must hold no path, gap or empty code ($profile)."
        Assert-NoProblem $internal "A notification must not use an internal word ($profile)."

        $unfinished = New-Object 'System.Collections.Generic.List[string]'
        $internal = New-Object 'System.Collections.Generic.List[string]'
        foreach ($entry in $H::AllPageTexts()) {
            $parts = $entry.Split("`n")
            if ($parts[0].Length -eq 0 -or -not $parts[0].EndsWith('.') -or $parts[0].Contains('  ') -or $parts[0].Contains('()')) { $unfinished.Add("reason '$($parts[0])'") }
            if ($parts[1].Length -gt 0 -and -not $parts[1].EndsWith('.')) { $unfinished.Add("next step '$($parts[1])'") }
            $word = Find-Internal $entry
            if ($word) { $internal.Add("('$word') '$entry'") }
        }
        Assert-NoProblem $unfinished "Every page reason and next step must be a full sentence ($profile)."
        Assert-NoProblem $internal "A page sentence must not use an internal word ($profile)."
    }
    finally {
        $H::UseProfile('rewindle')
    }
}
Assert-Equal 'rewindle' ($H::ProfileId()) 'The default profile must be put back.'

# The reinstall advice follows the engine profile; the legacy edition is told to reinstall its own program.
$H::UseProfile('legacy')
try {
    $legacyNext = $H::NotificationWords('last=2026-07-21T02:00;result=66', 'en-GB')
    Assert-True ($legacyNext.EndsWith("/ Reinstall the backup program (Rewindle Setup doesn't change the earlier personal edition).")) "The legacy edition must get its own reinstall advice. Got '$legacyNext'."
    Assert-Equal "programProblem|danger|$slot|code 66" (Explain 'last=2026-07-21T02:00;result=66') 'The legacy launcher codes mean the same.'
}
finally {
    $H::UseProfile('rewindle')
}
$rewindleNext = $H::NotificationWords('last=2026-07-21T02:00;result=66', 'en-GB')
Assert-Equal "Windows couldn${q}t start the backup program today at 02:00 (code 66). / Open Rewindle Setup and choose Reinstall or repair." $rewindleNext 'Rewindle must point to Setup.'
Assert-Equal "The PC was off, asleep or signed out today at 2:00 AM, and Windows hasn${q}t run the missed backup yet. / Open Rewindle and choose Back up now." (
    $H::NotificationWords('last=2026-07-20T02:00;result=0', 'en-US')) 'A notification ends with the one thing to do.'

# --- Failed backups in a row --------------------------------------------------------------------------------------------
$verified = '2026-07-18T02:30:00Z'
Assert-Equal 3 ($H::CountFailed('failed@2026-07-21T02:00,failed@2026-07-20T02:00,failed@2026-07-19T02:00,success@2026-07-18T02:00', $verified)) 'Three failed backups after the verified one count three.'
Assert-Equal 2 ($H::CountFailed('failed@2026-07-21T02:00,cancelled@2026-07-20T12:00,failed@2026-07-20T02:00', $verified)) 'A backup the person stopped is stepped over.'
Assert-Equal 3 ($H::CountFailed('cancelled@2026-07-21T03:00,failed@2026-07-21T02:00,failed@2026-07-20T02:00,failed@2026-07-19T02:00', $verified)) 'A stop on top of three failures leaves them red.'
Assert-Equal 2 ($H::CountFailed('partial@2026-07-21T02:00,failed@2026-07-20T02:00', $verified)) 'A backup that missed files counts as failed.'
Assert-Equal 1 ($H::CountFailed('failed@2026-07-21T02:00,success_unchanged@2026-07-20T02:00,failed@2026-07-19T02:00', $verified)) 'A success ends the count.'
Assert-Equal 1 ($H::CountFailed('failed@2026-07-21T02:00,failed@2026-07-18T01:00', $verified)) 'A run from before the last verified backup ends the count.'
Assert-Equal 2 ($H::CountFailed('failed@2026-07-21T02:00,dry:success@2026-07-20T12:00,failed@2026-07-20T02:00', $verified)) 'Dry runs are not backups.'
Assert-Equal 1 ($H::CountFailed('failed@2026-07-21T02:00,mystery@2026-07-20T02:00,failed@2026-07-19T02:00', $verified)) 'A state this build does not know ends the count.'
Assert-Equal 0 ($H::CountFailed('@2026-07-21T02:00,@2026-07-20T02:00,@2026-07-19T02:00', $verified)) 'Records that name no state never make the mark red.'
Assert-Equal 0 ($H::CountFailed('', $verified)) 'No history counts nothing.'
Assert-Equal 4 ($H::CountFailed('failed@2026-07-19T02:00,failed@2026-07-21T02:00,failed@2026-07-18T02:00,failed@2026-07-20T02:00', '')) 'Without a verified backup the whole history counts, newest first.'
Assert-Equal 3 ($H::FailingRunThreshold()) 'Three failures in a row turn the mark red.'

# --- Which alert a refresh raises -----------------------------------------------------------------------------------------
$key = '2026-07-20T02:30:00Z'
Assert-Equal 'none||' ($H::Evaluate('', 'freshness=Healthy', $false)) 'Healthy raises nothing.'
Assert-Equal 'none||' ($H::Evaluate('', 'freshness=CatchingUp', $false)) 'Catching up never raises an alert.'
Assert-Equal 'none||' ($H::Evaluate('', 'freshness=NoVerifiedBackup;verified=none;failed=2', $false)) 'A first backup still on its way is not an alert.'
Assert-Equal 'failing|failing|failing|none' ($H::Evaluate('', 'freshness=NoVerifiedBackup;verified=none;failed=3', $false)) 'Three failures before any verified backup are red.'
Assert-Equal "attention|overdue|overdue|$key" ($H::Evaluate('', 'freshness=Overdue;kind=pcOff', $false)) 'Overdue is amber.'
Assert-Equal "attention|overdue|overdue|$key" ($H::Evaluate('', 'freshness=Overdue;failed=2', $false)) 'Two failures leave it amber.'
Assert-Equal "failing|failing|failing|$key" ($H::Evaluate('', 'freshness=Overdue;failed=3', $false)) 'Failing beats overdue.'
Assert-Equal "attention|paused|paused|$key" ($H::Evaluate('', 'freshness=Paused;failed=5', $false)) 'Paused beats failing: nothing runs until it is turned back on.'
Assert-Equal "attention|clock|clock|$key" ($H::Evaluate('', 'freshness=ClockAnomaly', $false)) 'A wrong clock is amber.'
Assert-Equal "failing|failing|failing|$key" ($H::Evaluate('', 'freshness=ClockAnomaly;failed=4', $false)) 'Failing beats the clock.'
# An unknown is no news: unreadable status or a run in progress hold the previous alert.
Assert-Equal "attention|overdue|overdue|$key" ($H::Evaluate('freshness=Overdue', 'status=0;freshness=Healthy', $false)) 'An unreadable status holds the alert.'
Assert-Equal 'none||' ($H::Evaluate('', 'status=0;freshness=Overdue', $false)) 'An unreadable status raises nothing new.'
Assert-Equal "failing|failing|failing|$key" ($H::Evaluate('freshness=Overdue;failed=3', 'active=1;freshness=Healthy', $false)) 'A run in progress holds the alert.'
Assert-Equal 'none||' ($H::Evaluate('', 'active=1;freshness=Overdue;failed=3', $false)) 'A run in progress raises nothing new.'
# A schedule that can't be read: failing is still judged, the schedule's own reasons are held, and after an hour it is an alert.
Assert-Equal "failing|failing|failing|$key" ($H::Evaluate('', 'schedule=0;freshness=Unavailable;failed=3', $false)) 'Failing needs no schedule.'
Assert-Equal "attention|overdue|overdue|$key" ($H::Evaluate('freshness=Overdue', 'schedule=0;freshness=Unavailable', $false)) 'Overdue is held while the schedule is unreadable.'
Assert-Equal "attention|paused|paused|$key" ($H::Evaluate('freshness=Paused', 'freshness=Unavailable', $false)) 'An unavailable freshness holds paused.'
Assert-Equal 'none||' ($H::Evaluate('freshness=Overdue;failed=3', 'schedule=0;freshness=Unavailable;failed=0', $false)) 'Failing ends when the failures end, schedule or not.'
Assert-Equal 'none||' ($H::Evaluate('', 'schedule=0;freshness=Unavailable', $false)) 'A schedule unreadable for a moment raises nothing.'
Assert-Equal "attention|schedule|schedule|$key" ($H::Evaluate('', 'schedule=0;freshness=Unavailable', $true)) 'A schedule unreadable for an hour is an alert.'
Assert-Equal 'attention|schedule|schedule|none' ($H::Evaluate('freshness=Overdue', 'schedule=0;freshness=null;verified=none', $true)) 'The schedule alert replaces a held one after an hour.'

# --- When a notification is shown -----------------------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('rewindle-alerts-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
function New-Driver { param([string]$Name, [bool]$Allowed = $true) return New-Object ResticBackuper.Dashboard.AlertMonitorDriver((Join-Path $fixtureRoot $Name), $Allowed) }
$overdue = 'freshness=Overdue;kind=pcOff'
$failing = 'freshness=Overdue;failed=3;details=1'
$healthy = 'freshness=Healthy;verified=2026-07-21T09:30:00Z'
try {
    # Amber waits 15 minutes, then is told once.
    $d = New-Driver 'settle'
    Assert-Equal '' ($d.Update($overdue, 'present')) 'An amber alert is not told at once.'
    Assert-Equal 'attention|overdue' $d.Mark 'The mark shows at once.'
    Assert-Equal 'pcOff' $d.LastExplanation 'The explanation is kept for the page.'
    $d.Advance(14)
    Assert-Equal '' ($d.Update($overdue, 'present')) 'An amber alert waits 15 minutes.'
    $d.Advance(2)
    $told = $d.Update($overdue, 'present')
    Assert-True ($told.StartsWith('Backup overdue|The PC was off, asleep or signed out ')) "After 15 minutes it is told. Got '$told'."
    Assert-True ($told.EndsWith('Open Rewindle and choose Back up now.')) 'The notification ends with its next step.'
    $d.Advance(30)
    Assert-Equal '' ($d.Update($overdue, 'present')) 'A problem is told once.'
    # Red is told at once, even right after the amber one.
    $told = $d.Update($failing, 'present')
    Assert-Equal "Backups keep failing|The last 3 backups didn${q}t finish. Open Rewindle and choose See what happened." $told 'Failing is told at once.'
    Assert-Equal 3 $d.LastFailedInARow 'The failing count is kept for the page.'
    Assert-Equal '' ($d.Update('freshness=Overdue;failed=4;details=1', 'present')) 'A fourth failure is the same problem.'
    # Put right, then the same problem again (same last verified backup): not told twice, even by a new dashboard.
    Assert-Equal '' ($d.Update($healthy, 'present')) 'A verified backup tells nothing.'
    Assert-Equal 'none|' $d.Mark 'A verified backup clears the mark.'
    $again = New-Driver 'settle'
    Assert-Equal '' ($again.Update($overdue, 'present')) 'Amber waits after a restart too.'
    $again.Advance(20)
    Assert-Equal '' ($again.Update($overdue, 'present')) 'A problem already told is remembered in alerts.json.'
    Assert-True ($again.WasTold("overdue|$key") -and $again.WasTold("failing|$key")) 'Both problems are remembered.'
    # A new verified backup makes a new problem.
    $again.Advance(1)
    Assert-Equal '' ($again.Update('freshness=Overdue;verified=2026-07-21T02:30:00Z', 'present')) 'A new problem waits 15 minutes too.'
    $again.Advance(16)
    Assert-True ($again.Update('freshness=Overdue;verified=2026-07-21T02:30:00Z', 'present').StartsWith('Backup overdue|')) 'A new problem after a verified backup is told.'

    # Rewindle in front: the person sees it already. It is remembered, not shown, and not shown later either.
    $d = New-Driver 'front'
    Assert-Equal '' ($d.Update($failing, 'front')) 'Nothing is shown over Rewindle itself.'
    Assert-Equal '' ($d.Update($failing, 'present')) 'A problem seen in Rewindle is not told later.'
    Assert-Equal 'failing|failing' $d.Mark 'The mark still shows.'

    # Notifications off: remembered, not shown; turning them on later shows nothing for it.
    $d = New-Driver 'off'
    Assert-True ($d.SetNotifications($false)) 'The choice is saved.'
    Assert-True (-not $d.NotificationsOn) 'Notifications are off.'
    Assert-Equal '' ($d.Update($failing, 'present')) 'Nothing is shown while notifications are off.'
    Assert-Equal 'failing|failing' $d.Mark 'The mark stays when notifications are off.'
    Assert-True ($d.SetNotifications($true)) 'The choice is saved.'
    Assert-Equal '' ($d.Update($failing, 'present')) 'Turning notifications on does not show an old problem.'
    $d = New-Driver 'on-later'
    Assert-Equal '' ($d.Update($overdue, 'present'))
    Assert-True ($d.SetNotifications($true)) 'The choice is saved.'
    $d.Advance(20)
    Assert-Equal '' ($d.Update($overdue, 'present')) 'Choosing On in Settings counts the problem on screen as told.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $fixtureRoot 'on-later\alerts.json') -Raw).Contains('"notify":true')) 'On is saved.'

    # Nobody at the PC: held, shown when they are back, dropped when put right first.
    $d = New-Driver 'away'
    Assert-Equal '' ($d.Update($failing, 'away')) 'Nothing is shown to an empty room.'
    Assert-Equal '' ($d.Update($failing, 'none')) 'Nothing is shown when presence is unknown.'
    Assert-True ($d.Update($failing, 'present').StartsWith('Backups keep failing|')) 'It is shown when someone is back.'
    $d = New-Driver 'away-resolved'
    Assert-Equal '' ($d.Update($failing, 'away'))
    Assert-Equal '' ($d.Update($healthy, 'away'))
    Assert-Equal '' ($d.Update($healthy, 'present')) 'A problem put right while nobody was there is not shown.'
    Assert-True (-not $d.WasTold("failing|$key")) 'It is not remembered as told.'

    # The preview (screenshot mode) shows nothing; a run in progress or an unreadable status shows nothing.
    $d = New-Driver 'quiet'
    Assert-Equal '' ($d.Update($failing, 'quiet')) 'The preview shows nothing.'
    Assert-Equal '' ($d.Update('freshness=Overdue;failed=3;active=1', 'present')) 'Nothing is shown while a backup runs.'
    Assert-Equal '' ($d.Update('status=0', 'present')) 'Nothing is shown while the status cannot be read.'
    Assert-True ($d.Update($failing, 'present').StartsWith('Backups keep failing|')) 'It is shown once things are settled.'

    # A pause made in Rewindle is not news while it lasts: not when it is made, not after a backup made by hand meanwhile (a new
    # last verified backup, so a new problem key), not after a restart. A read with the schedule on ends it, and a later pause
    # made elsewhere is told.
    $d = New-Driver 'paused'
    $pausedFile = Join-Path $fixtureRoot 'paused\alerts.json'
    $d.NoteUserPausedSchedule()
    Assert-Equal '' ($d.Update('freshness=Paused', 'present'))
    $d.Advance(60)
    Assert-Equal '' ($d.Update('freshness=Paused', 'present')) 'A pause the person made is never told.'
    Assert-Equal 'attention|paused' $d.Mark 'The amber mark stays for a pause.'
    Assert-True ((Get-Content -LiteralPath $pausedFile -Raw).Contains('"user_paused":true')) 'The pause made in Rewindle is kept in alerts.json.'
    $byHand = 'freshness=Paused;verified=2026-07-21T09:30:00Z'
    Assert-Equal '' ($d.Update($byHand, 'present'))
    $d.Advance(16)
    Assert-Equal '' ($d.Update($byHand, 'present')) 'A pause the person made is not told after a backup made by hand.'
    Assert-Equal 'attention|paused' $d.Mark 'The amber mark stays after a backup made by hand.'
    $byHandAgain = 'freshness=Paused;verified=2026-07-21T10:45:00Z'
    $d.Advance(60)
    Assert-Equal '' ($d.Update($byHandAgain, 'present'))
    $d.Advance(16)
    Assert-Equal '' ($d.Update($byHandAgain, 'present')) 'Nor after the next one.'
    Assert-Equal '' ($d.Update('active=1;freshness=Paused', 'present'))
    Assert-Equal '' ($d.Update('schedule=0;freshness=Unavailable', 'present'))
    Assert-True $d.UserPausedSchedule 'A run or a schedule that cannot be read does not end the pause made in Rewindle.'
    Assert-True (-not $d.WasTold("paused|$key") -and -not $d.WasTold('paused|2026-07-21T09:30:00Z')) 'The pause made in Rewindle takes no place among the problems told.'
    $again = New-Driver 'paused'
    Assert-True $again.UserPausedSchedule 'A restart reads the pause made in Rewindle back.'
    Assert-Equal '' ($again.Update($byHandAgain, 'present'))
    $again.Advance(16)
    Assert-Equal '' ($again.Update($byHandAgain, 'present')) 'A pause the person made is not told after a restart.'
    Assert-Equal '' ($again.Update('freshness=Healthy;verified=2026-07-21T10:45:00Z', 'present'))
    Assert-True (-not $again.UserPausedSchedule) 'A read with the schedule on ends the pause made in Rewindle.'
    Assert-True ((Get-Content -LiteralPath $pausedFile -Raw).Contains('"user_paused":false')) 'The end of the pause made in Rewindle is saved.'
    Assert-Equal '' ($again.Update($byHandAgain, 'present'))
    $again.Advance(16)
    Assert-True ($again.Update($byHandAgain, 'present').StartsWith('Automatic backups are paused|')) 'A later pause made elsewhere is told.'
    $d = New-Driver 'paused-elsewhere'
    Assert-Equal '' ($d.Update('freshness=Paused', 'present'))
    $d.Advance(16)
    $told = $d.Update('freshness=Paused', 'present')
    Assert-Equal "Automatic backups are paused|Rewindle won${q}t back up on its own until the schedule is turned back on. Open Rewindle and choose Edit schedule." $told 'A pause made elsewhere is told.'

    # A schedule that can't be read for an hour is told; failing is told without one.
    $d = New-Driver 'schedule'
    Assert-Equal '' ($d.Update('schedule=0;freshness=Unavailable', 'present'))
    $d.Advance(59)
    Assert-Equal '' ($d.Update('schedule=0;freshness=Unavailable', 'present')) 'Less than an hour is not an alert.'
    Assert-Equal 'none|' $d.Mark 'No mark before an hour.'
    $d.Advance(2)
    Assert-Equal '' ($d.Update('schedule=0;freshness=Unavailable', 'present'))
    Assert-Equal 'attention|schedule' $d.Mark 'After an hour the mark shows.'
    $d.Advance(16)
    Assert-True ($d.Update('schedule=0;freshness=Unavailable', 'present').StartsWith("Rewindle can${q}t read the backup schedule|")) 'And then it is told.'
    $d = New-Driver 'schedule-failing'
    Assert-True ($d.Update('schedule=0;freshness=Unavailable;failed=3', 'present').StartsWith('Backups keep failing|')) 'Failing is told while the schedule cannot be read.'
    $d = New-Driver 'schedule-back'
    Assert-Equal '' ($d.Update('schedule=0;freshness=Unavailable', 'present'))
    $d.Advance(50)
    Assert-Equal '' ($d.Update($healthy, 'present'))
    $d.Advance(20)
    Assert-Equal '' ($d.Update('schedule=0;freshness=Unavailable', 'present'))
    Assert-Equal 'none|' $d.Mark 'The hour starts again after the schedule was read.'

    # A second dashboard (isolated presentation, another state folder) shows the mark but never tells or writes.
    $d = New-Driver 'isolated' $false
    Assert-Equal '' ($d.Update($failing, 'present')) 'An isolated dashboard never notifies.'
    Assert-Equal 'failing|failing' $d.Mark 'An isolated dashboard still shows the mark.'
    Assert-True (-not $d.WasTold("failing|$key")) 'An isolated dashboard remembers nothing as told.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'isolated\alerts.json'))) 'An isolated dashboard writes no told problem.'

    # --- alerts.json ----------------------------------------------------------------------------------------------------------
    $now = '2026-07-21T09:00:00Z'
    function New-Store { param([string]$Directory) return New-Object ResticBackuper.Dashboard.AlertStoreProbe($Directory, $now) }
    function Write-AlertsFile { param([string]$Directory, [string]$Text) New-Item -ItemType Directory -Force -Path $Directory | Out-Null; [IO.File]::WriteAllText((Join-Path $Directory 'alerts.json'), $Text, (New-Object Text.UTF8Encoding($false))) }
    function Read-AlertsFile { param([string]$Directory) return [IO.File]::ReadAllText((Join-Path $Directory 'alerts.json')) }

    $s = New-Store ''
    Assert-True ($s.Notify -and -not $s.Persists) 'No folder keeps the choices in memory, notifications on.'
    $dir = Join-Path $fixtureRoot 'store\missing'
    $s = New-Store $dir
    Assert-True ($s.Notify -and $s.Persists) 'A missing file means on, and it may be written.'
    Assert-True ($s.SetNotify($false)) 'Off is saved.'
    $s.Remember("overdue|$key", '2026-07-21T08:00:00Z')
    $text = Read-AlertsFile $dir
    Assert-True ($text.Contains('"schema_version":1') -and $text.Contains('"notify":false') -and $text.Contains("overdue|$key")) "The file holds the choice and the told problem. Got '$text'."
    $s = New-Store $dir
    Assert-True ((-not $s.Notify) -and $s.WasTold("overdue|$key")) 'The choice and the told problem are read back.'
    Assert-True (-not $s.UserPaused) 'Nothing is paused by the person until they pause in Rewindle.'
    $s.SetUserPaused($true)
    Assert-True ((Read-AlertsFile $dir).Contains('"user_paused":true')) 'A pause made in Rewindle is saved.'
    $s = New-Store $dir
    Assert-True ($s.UserPaused -and (-not $s.Notify) -and $s.WasTold("overdue|$key")) 'A pause made in Rewindle is read back beside the choice and the told problem.'
    $dir = Join-Path $fixtureRoot 'store\no-user-paused'
    Write-AlertsFile $dir '{"schema_version":1,"notify":false,"told":[]}'
    $s = New-Store $dir
    Assert-True ((-not $s.UserPaused) -and (-not $s.Notify) -and $s.Persists) 'A file without user_paused is read as not paused, with its choice.'

    foreach ($case in @(
        @('garbage', 'not json at all'),
        @('array', '[1,2,3]'),
        @('no-notify', '{"schema_version":1,"told":[]}'),
        @('string-notify', '{"schema_version":1,"notify":"no","told":[]}'),
        @('old-schema', '{"schema_version":0,"notify":false,"told":[]}'),
        @('bad-told', '{"schema_version":1,"notify":false,"told":"overdue|x"}'),
        @('string-user-paused', '{"schema_version":1,"notify":false,"user_paused":"yes","told":[]}')
    )) {
        $dir = Join-Path $fixtureRoot ('store\' + $case[0])
        Write-AlertsFile $dir $case[1]
        $s = New-Store $dir
        Assert-True ($s.Notify -and $s.Persists -and -not $s.UserPaused) "A damaged file ($($case[0])) gives the defaults and may be written again."
    }
    $dir = Join-Path $fixtureRoot 'store\bad-utf8'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dir 'alerts.json'), [byte[]](0x7B, 0xFF, 0xFE, 0x7D))
    Assert-True ((New-Store $dir).Notify) 'Bytes that are not UTF-8 give the defaults.'
    $dir = Join-Path $fixtureRoot 'store\big'
    Write-AlertsFile $dir ('{"schema_version":1,"notify":false,"told":[],"pad":"' + ('x' * (17 * 1024)) + '"}')
    $s = New-Store $dir
    Assert-True ($s.Notify -and $s.Persists) 'A 17 KiB file is not ours: defaults.'

    $dir = Join-Path $fixtureRoot 'store\entries'
    Write-AlertsFile $dir ('{"schema_version":1,"notify":false,"told":[' +
        '{"key":"overdue|2026-07-20T02:30:00Z","at_utc":"2026-07-21T08:00:00Z"},' +
        '{"key":"overdue|C:\\Users","at_utc":"2026-07-21T08:00:00Z"},' +
        '{"key":"deleted|2026-07-20T02:30:00Z","at_utc":"2026-07-21T08:00:00Z"},' +
        '{"key":"paused|2026-06-01T02:30:00Z","at_utc":"2026-06-11T08:00:00Z"},' +
        '{"key":"clock|2026-07-20T02:30:00Z","at_utc":"2026-07-28T08:00:00Z"},' +
        '{"key":"failing|none","at_utc":"21 July"},' +
        '{"key":"schedule|none"}]}')
    $s = New-Store $dir
    Assert-True (-not $s.Notify) 'A good file keeps Off.'
    Assert-True ($s.WasTold("overdue|$key")) 'A good entry is kept.'
    Assert-True (-not $s.WasTold('overdue|C:\Users')) 'A key that is not ours is dropped.'
    Assert-True (-not $s.WasTold("deleted|$key")) 'An unknown reason is dropped.'
    Assert-True (-not $s.WasTold('paused|2026-06-01T02:30:00Z')) 'An entry 40 days old is forgotten.'
    Assert-True (-not $s.WasTold("clock|$key")) 'An entry a week ahead is forgotten.'
    Assert-True (-not $s.WasTold('failing|none')) 'An entry with a bad time is dropped.'
    Assert-True (-not $s.WasTold('schedule|none')) 'An entry without a time is dropped.'
    Assert-True ([ResticBackuper.Dashboard.AlertStoreProbe]::IsValidKey('failing|none')) 'A key without a verified backup is valid.'
    Assert-True (-not [ResticBackuper.Dashboard.AlertStoreProbe]::IsValidKey('failing|' + ('1' * 65))) 'A long key is refused.'

    # Eight problems are remembered; the oldest goes first.
    $dir = Join-Path $fixtureRoot 'store\eight'
    $s = New-Store $dir
    for ($i = 1; $i -le 9; $i++) { $s.Remember(('overdue|2026-07-{0:00}T02:30:00Z' -f $i), ('2026-07-21T0{0}:00:00Z' -f ($i - 1))) }
    $s = New-Store $dir
    Assert-True (-not $s.WasTold('overdue|2026-07-01T02:30:00Z')) 'The oldest of nine is forgotten.'
    Assert-True ($s.WasTold('overdue|2026-07-02T02:30:00Z') -and $s.WasTold('overdue|2026-07-09T02:30:00Z')) 'The newest eight are kept.'

    # A newer Rewindle's file is left alone: defaults in memory only.
    $dir = Join-Path $fixtureRoot 'store\newer'
    $newer = '{"schema_version":2,"notify":false,"told":[],"more":true}'
    Write-AlertsFile $dir $newer
    $s = New-Store $dir
    Assert-True ($s.Notify -and -not $s.Persists) 'A newer file gives in-memory defaults.'
    Assert-True (-not $s.SetNotify($false)) 'Nothing is saved over a newer file.'
    $s.Remember("overdue|$key", $now)
    $s.SetUserPaused($true)
    Assert-Equal $newer (Read-AlertsFile $dir) 'A newer file is never rewritten.'

    # A file another program holds open: this run keeps defaults in memory, and the saved Off survives.
    $dir = Join-Path $fixtureRoot 'store\locked'
    Write-AlertsFile $dir '{"schema_version":1,"notify":false,"told":[]}'
    $lock = [IO.File]::Open((Join-Path $dir 'alerts.json'), 'Open', 'ReadWrite', 'None')
    try {
        $s = New-Store $dir
        Assert-True ($s.Notify -and -not $s.Persists) 'A locked file gives in-memory defaults.'
        Assert-True (-not $s.SetNotify($true)) 'Nothing is saved while the file is locked.'
        $s.Remember("overdue|$key", $now)
    }
    finally {
        $lock.Dispose()
    }
    Assert-True ((Read-AlertsFile $dir).Contains('"notify":false')) 'The saved Off survives a locked file.'
    Assert-True (-not (New-Store $dir).Notify) 'The next start reads Off again.'

    # A folder named alerts.json, and a settings folder that is a junction: not read and not written.
    $dir = Join-Path $fixtureRoot 'store\folder'
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'alerts.json') | Out-Null
    $s = New-Store $dir
    Assert-True ($s.Notify -and -not $s.Persists) 'A folder in place of the file is left alone.'
    Assert-True (-not $s.SetNotify($false)) 'Nothing is saved over a folder.'
    $target = Join-Path $fixtureRoot 'store\junction-target'
    Write-AlertsFile $target '{"schema_version":1,"notify":false,"told":[]}'
    $link = Join-Path $fixtureRoot 'store\junction'
    & cmd.exe /d /c mklink /J "$link" "$target" | Out-Null
    Assert-True ((Get-Item -LiteralPath $link -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'The fixture junction must exist.'
    $s = New-Store $link
    Assert-True ($s.Notify -and -not $s.Persists) 'A junction is not read.'
    Assert-True (-not $s.SetNotify($true)) 'A junction is not written.'
    Assert-Equal '{"schema_version":1,"notify":false,"told":[]}' (Read-AlertsFile $target) 'The junction target is untouched.'
    [IO.Directory]::Delete($link)

    $left = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -Force -Filter '.alerts.*.tmp')
    Assert-Equal 0 $left.Count 'A save never leaves a temporary file behind.'
}
finally {
    $junction = Join-Path $fixtureRoot 'store\junction'
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}

# --- The tray mark ----------------------------------------------------------------------------------------------------------
$P = [ResticBackuper.Dashboard.TrayBadgeProbe]
function Read-Counts { param([string]$Text) $values = @{}; foreach ($part in $Text.Split(';')) { $pair = $part.Split('='); $values[$pair[0]] = [int]$pair[1] }; return $values }
foreach ($size in @(16, 20, 24, 32)) {
    Assert-Equal 'null' ($P::Describe('none', $size)) "No alert draws no mark ($size px)."
    Assert-Equal 0 ($P::ComposeAndDisposeTwice('none', $size)) "No alert makes no icon ($size px)."
    $amber = Read-Counts ($P::Describe('attention', $size))
    $red = Read-Counts ($P::Describe('failing', $size))
    Assert-Equal $size $amber['size'] "The mark is drawn at the tray size ($size px)."
    Assert-True ($amber['amber'] -ge 3 -and $amber['red'] -eq 0) "Attention is amber ($size px): $($P::Describe('attention', $size))."
    Assert-True ($red['red'] -ge 3 -and $red['amber'] -eq 0) "Failing is red ($size px): $($P::Describe('failing', $size))."
    Assert-True ($amber['halo'] -ge 1 -and $red['halo'] -ge 1) "The mark has a dark ring ($size px)."
    Assert-True ($amber['base'] -eq 1 -and $red['base'] -eq 1) "The icon itself is kept ($size px)."
    if ($size -ge 24) {
        Assert-True ($amber['amberMark'] -ge 2 -and $red['redMark'] -ge 2) "From 24 px the mark carries a '!' ($size px)."
    }
    else {
        Assert-True ($amber['amberMark'] -eq 0 -and $red['redMark'] -eq 0) "Below 24 px the mark has no '!' ($size px)."
    }
    Assert-Equal $size ($P::ComposeAndDisposeTwice('failing', $size)) "The tray icon is built at its size and can be disposed twice ($size px)."
}

# --- What the alert code may not do -----------------------------------------------------------------------------------------
$alertsCode = Read-DashboardSource 'BackupAlerts.cs'
foreach ($forbidden in @('Process.Start', 'runas', 'schtasks', 'ManagerPath(', 'StateDirectory(', 'InstallRoot(', 'TaskScheduleReader')) {
    Assert-True (-not $alertsCode.Contains($forbidden)) "The alert code must not use $forbidden."
}
Assert-True (-not $alertsCode.Contains('DateTime.Now')) 'The alert code reads no local clock of its own.'

[pscustomobject]@{
    ok = $true
    tests = $script:tests
    longest_notification = $longest
    fixture_only = $true
    live_task_queried = $false
    production_task_started = $false
    protected_state_written = $false
} | ConvertTo-Json
