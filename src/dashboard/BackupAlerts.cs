using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Drawing = System.Drawing;
using Drawing2D = System.Drawing.Drawing2D;
using DrawingImaging = System.Drawing.Imaging;

// Backup alerts: when backups are overdue, paused, or keep failing, Rewindle says so once with a Windows notification and marks its
// icon in the notification area until the problem is put right. Everything here runs with the dashboard's standard rights and only
// reads: the run history, the freshness of the last verified backup, what Task Scheduler recorded for the task's last run, and
// whether someone is at the PC. The only thing it writes is alerts.json in the dashboard's own per-user settings folder (the
// notification switch and which problems were already told). Nothing here names an engine or depends on the engine profile, except
// the reinstall advice, which comes from EngineProfile.
namespace ResticBackuper.Dashboard
{
    internal enum BackupAlertLevel
    {
        None = 0,
        // Amber: something needs attention (overdue, paused, the clock, a schedule that can't be read).
        Attention = 1,
        // Red: backups keep failing.
        Failing = 2
    }

    internal enum BackupAlertReason
    {
        None = 0,
        Overdue = 1,
        Paused = 2,
        Failing = 3,
        Clock = 4,
        Schedule = 5
    }

    // Why a scheduled backup did not happen. Unknown is the plain "it didn't happen" when nothing more can be said.
    internal enum MissedRunKind
    {
        None = 0,
        Unknown,
        DriveMissing,
        RepairPending,
        RanAndFailed,
        Cancelled,
        Busy,
        ProgramProblem,
        CouldNotStart,
        WaitingForPower,
        NoCatchUp,
        PcOff
    }

    internal enum MissedRunTone
    {
        Warning = 0,
        Danger = 1
    }

    internal static class BackupAlertPolicy
    {
        // How many failed backups in a row turn the mark red. One failure is often a locked file or an unplugged drive, two can be
        // a coincidence; three in a row will not fix itself. An overdue backup is amber long before that.
        internal const int FailingRunThreshold = 3;
        // How many told problems alerts.json remembers, so one that comes back (paused, resumed, still overdue) is not told twice.
        internal const int RememberedEpisodes = 8;
        // An amber problem is told only once it has lasted this long while Rewindle was running: the minutes after a sign-in or a
        // wake, when Windows starts a missed backup and the schedule is read again, are left alone.
        internal static readonly TimeSpan AttentionSettle = TimeSpan.FromMinutes(15);
        // A schedule that can't be read for this long, without a break, is an alert of its own: backups may have stopped.
        internal static readonly TimeSpan ScheduleUnreadableLimit = TimeSpan.FromMinutes(60);
        // No keyboard or mouse input for this long means nobody is at the PC, and a notification waits for them.
        internal static readonly TimeSpan PresenceIdleLimit = TimeSpan.FromMinutes(2);
        // A run that started this much before a slot still counts as the attempt for it (Windows can start a little early).
        internal static readonly TimeSpan AttemptTolerance = TimeSpan.FromMinutes(2);
        internal static readonly TimeSpan EpisodeMemory = TimeSpan.FromDays(30);

        // The task launcher's own exit codes (src/task_launcher/Program.cs). 64, 65 and 66 mean the program itself is not as
        // installed (arguments, location, missing files); the others mean it could not start or watch the backup. 75 is the busy
        // code, which backup.py also returns (another protected job holds the run, or a folder change has not finished).
        internal static readonly int[] LauncherProgramCodes = { 64, 65, 66 };
        internal static readonly int[] LauncherStartCodes = { 67, 68, 69, 70, 71, 72, 73, 74, 76, 77, 78 };
        internal const int BusyCode = 75;

        // Task Scheduler's own results for the last run.
        internal const int TaskStillRunning = 0x00041301;
        internal const int TaskHasNotRun = 0x00041303;
        internal static readonly int[] BusyResults =
        {
            BusyCode,
            unchecked((int)0x8004131F), // An instance of the task is already running.
            unchecked((int)0x80070420)  // An instance is already running.
        };
        internal static readonly int ConditionsNotMet = unchecked((int)0x800710E0);
        internal static readonly int[] StoppedResults =
        {
            unchecked((int)0xC000013A), // Ended by a shutdown or a sign-out.
            0x00041306,                 // Terminated.
            unchecked((int)0x8007042B), // The process ended unexpectedly.
            unchecked((int)0x800704C7)  // Cancelled.
        };
        // The task runs only while its user is signed in; around a sign-out Windows records this. It is the same as not started.
        internal static readonly int NotSignedIn = unchecked((int)0x800704DD);
    }

    internal static class AlertWording
    {
        // A moment as a sentence says it: "today at 02:00", "yesterday at 2:00 AM", "on Wednesday at 02:00", "on 12 Sep at 02:00".
        // For the page the clock is a 24-hour HH:mm, which the page writes in the viewer's own clock; for a notification it is
        // the regional short time. Day and month names follow the regional format.
        internal static string FormatMoment(DateTime utc, DateTime nowUtc, TimeZoneInfo zone, bool forPage)
        {
            TimeZoneInfo timeZone = zone ?? TimeZoneInfo.Local;
            DateTime local = TimeZoneInfo.ConvertTimeFromUtc(ToUtc(utc), timeZone);
            DateTime localNow = TimeZoneInfo.ConvertTimeFromUtc(ToUtc(nowUtc), timeZone);
            string clock = forPage
                ? local.ToString("HH:mm", CultureInfo.InvariantCulture)
                : local.ToString("t", CultureInfo.CurrentCulture);
            int days = (localNow.Date - local.Date).Days;
            if (days == 0)
            {
                return "today at " + clock;
            }
            if (days == 1)
            {
                return "yesterday at " + clock;
            }
            if (days >= 2 && days <= 6)
            {
                return "on " + local.ToString("dddd", CultureInfo.CurrentCulture) + " at " + clock;
            }
            return "on " + local.ToString("d MMM", CultureInfo.CurrentCulture) + " at " + clock;
        }

        // "code 66" for an exit code, "error 0x800710E0" for one of Windows' own results.
        internal static string FormatCode(int value)
        {
            return TaskSchedule.DescribeTaskResult(value);
        }

        // The drive letter a backup location is on ("D:"), or "" for a network share or a path that names none.
        internal static string DriveOf(string path)
        {
            if (string.IsNullOrEmpty(path) || path.Length < 2 || path[1] != ':')
            {
                return string.Empty;
            }
            char letter = path[0];
            bool isLetter = (letter >= 'A' && letter <= 'Z') || (letter >= 'a' && letter <= 'z');
            return isLetter ? char.ToUpperInvariant(letter).ToString() + ":" : string.Empty;
        }

        // The last verified backup as a problem's key: one problem lasts until a new verified backup lands.
        internal static string VerifiedKey(DateTime? verifiedUtc)
        {
            return verifiedUtc.HasValue ? FormatUtc(verifiedUtc.Value) : "none";
        }

        internal static string FormatUtc(DateTime value)
        {
            return ToUtc(value).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        }

        internal static DateTime ToUtc(DateTime value)
        {
            return value.Kind == DateTimeKind.Local
                ? value.ToUniversalTime()
                : DateTime.SpecifyKind(value, DateTimeKind.Utc);
        }

        // The names the page reads. One switch each, so a renamed enum value can never reach the page.
        internal static string LevelName(BackupAlertLevel level)
        {
            switch (level)
            {
                case BackupAlertLevel.Attention:
                    return "attention";
                case BackupAlertLevel.Failing:
                    return "failing";
                default:
                    return "none";
            }
        }

        internal static string ReasonName(BackupAlertReason reason)
        {
            switch (reason)
            {
                case BackupAlertReason.Overdue:
                    return "overdue";
                case BackupAlertReason.Paused:
                    return "paused";
                case BackupAlertReason.Failing:
                    return "failing";
                case BackupAlertReason.Clock:
                    return "clock";
                case BackupAlertReason.Schedule:
                    return "schedule";
                default:
                    return string.Empty;
            }
        }

        internal static string KindName(MissedRunKind kind)
        {
            switch (kind)
            {
                case MissedRunKind.DriveMissing:
                    return "driveMissing";
                case MissedRunKind.RepairPending:
                    return "repairPending";
                case MissedRunKind.RanAndFailed:
                    return "ranAndFailed";
                case MissedRunKind.Cancelled:
                    return "cancelled";
                case MissedRunKind.Busy:
                    return "busy";
                case MissedRunKind.ProgramProblem:
                    return "programProblem";
                case MissedRunKind.CouldNotStart:
                    return "couldNotStart";
                case MissedRunKind.WaitingForPower:
                    return "waitingForPower";
                case MissedRunKind.NoCatchUp:
                    return "noCatchUp";
                case MissedRunKind.PcOff:
                    return "pcOff";
                default:
                    return "unknown";
            }
        }

        internal static string ToneName(MissedRunTone tone)
        {
            return tone == MissedRunTone.Danger ? "danger" : "warning";
        }
    }

    // What is known when a backup is overdue, for MissedRunExplainer. Plain values: the explainer reads no clock, file, COM object
    // or window, so a test can build every case.
    internal sealed class MissedRunFacts
    {
        public BackupFreshnessState FreshnessState { get; set; }
        // The slot that was missed (the freshness check's latest due run), in UTC.
        public DateTime? LatestDueUtc { get; set; }
        public DateTime NowUtc { get; set; }
        // The zone Task Scheduler's last run time is in (the PC's own).
        public TimeZoneInfo Zone { get; set; }
        // The installed schedule with its last run, or null when it could not be read.
        public TaskSchedule Schedule { get; set; }
        public IList<RunMetricView> History { get; set; }
        public bool RunActive { get; set; }
        public bool? OnBattery { get; set; }
        // True when Rewindle saw the PC on and awake at the slot; null when that is not known.
        public bool? AwakeAtSlot { get; set; }
        public bool BackupDriveMissing { get; set; }
        public string BackupDrive { get; set; }
        public bool RepairNeeded { get; set; }
        // The record of an unfinished move exists but can't be repaired (the repair banner then asks for a problem report).
        public bool RepairBlocked { get; set; }
        // Whether the latest failed run has details the hero can open ("See what happened").
        public bool FailedRunHasDetails { get; set; }
    }

    internal sealed class MissedRunExplanation
    {
        internal static readonly MissedRunExplanation None =
            new MissedRunExplanation(MissedRunKind.None, MissedRunTone.Warning, null, null, null, false, false);

        internal MissedRunExplanation(
            MissedRunKind kind,
            MissedRunTone tone,
            DateTime? atUtc,
            int? resultCode,
            string backupDrive,
            bool repairBlocked,
            bool failedRunHasDetails)
        {
            Kind = kind;
            Tone = tone;
            AtUtc = atUtc.HasValue ? AlertWording.ToUtc(atUtc.Value) : (DateTime?)null;
            ResultCode = resultCode;
            Code = resultCode.HasValue ? AlertWording.FormatCode(resultCode.Value) : string.Empty;
            BackupDrive = backupDrive ?? string.Empty;
            RepairBlocked = repairBlocked;
            FailedRunHasDetails = failedRunHasDetails;
        }

        public MissedRunKind Kind { get; private set; }
        public MissedRunTone Tone { get; private set; }
        // The moment the sentence is about: the slot, or when Windows or the backup started.
        public DateTime? AtUtc { get; private set; }
        public int? ResultCode { get; private set; }
        public string Code { get; private set; }
        public string BackupDrive { get; private set; }
        public bool RepairBlocked { get; private set; }
        public bool FailedRunHasDetails { get; private set; }

        // Why the backup did not happen, in one sentence. The words never claim more than Windows records: it does not say whether
        // the PC was off or asleep, so neither does this.
        public string Reason(bool forPage, DateTime nowUtc, TimeZoneInfo zone)
        {
            // " today at 02:00", or nothing when the moment is not known; every sentence reads right either way.
            string at = AtUtc.HasValue
                ? " " + AlertWording.FormatMoment(AtUtc.Value, nowUtc, zone, forPage)
                : string.Empty;
            string drive = BackupDrive.Length > 0 ? " (" + BackupDrive + ")" : string.Empty;
            switch (Kind)
            {
                case MissedRunKind.DriveMissing:
                    return "The backup drive" + drive + " isn’t connected, so the " +
                        (at.Length > 0 ? "backup due" + at : "scheduled backup") + " couldn’t run.";
                case MissedRunKind.RepairPending:
                    return "Backups can’t run until the unfinished move of your backup location is repaired.";
                case MissedRunKind.RanAndFailed:
                    return at.Length > 0
                        ? "The backup that started" + at + " didn’t finish."
                        : "The latest backup didn’t finish.";
                case MissedRunKind.Cancelled:
                    return at.Length > 0
                        ? "The backup that started" + at + " was stopped before it finished."
                        : "The latest backup was stopped before it finished.";
                case MissedRunKind.Busy:
                    return "Windows started the backup" + at + ", but Rewindle was busy with another job, or a change it was " +
                        "making hadn’t finished.";
                case MissedRunKind.ProgramProblem:
                    return "Windows couldn’t start the backup program" + at + (Code.Length > 0 ? " (" + Code + ")" : string.Empty) + ".";
                case MissedRunKind.CouldNotStart:
                    return "Windows tried to run the backup" + at +
                        (Code.Length > 0 ? ", but it stopped with " + Code + "." : ", but it didn’t start.");
                case MissedRunKind.WaitingForPower:
                    return "This PC is on battery, and the backup is set to wait for AC power.";
                case MissedRunKind.NoCatchUp:
                    return "The PC was off, asleep or signed out" + at + ", and the schedule waits for the next time " +
                        "instead of catching up.";
                case MissedRunKind.PcOff:
                    return "The PC was off, asleep or signed out" + at + ", and Windows hasn’t run the missed backup yet.";
                case MissedRunKind.Unknown:
                    return at.Length > 0
                        ? "The backup due" + at + " didn’t happen."
                        : "A scheduled backup didn’t happen.";
                default:
                    return string.Empty;
            }
        }

        // What to do, on the page. Empty when it is Back up now: the hero already offers that, and says so.
        public string PageNextStep()
        {
            switch (Kind)
            {
                case MissedRunKind.DriveMissing:
                    return "Plug it back in, then choose Back up now.";
                case MissedRunKind.RepairPending:
                    return RepairBlocked
                        ? "Choose Save problem report in Settings."
                        : "Choose Repair interrupted move.";
                case MissedRunKind.RanAndFailed:
                    return FailedRunHasDetails
                        ? "Choose See what happened."
                        : "Open Activity and choose the failed backup.";
                case MissedRunKind.Busy:
                case MissedRunKind.CouldNotStart:
                    return "If it happens again, save a problem report in Settings.";
                case MissedRunKind.ProgramProblem:
                    return EngineProfile.Current.ReinstallAdvice();
                case MissedRunKind.WaitingForPower:
                    return "Plug the PC in, or choose “" + ScheduleOptionText.StartOnBattery + "” in Edit schedule.";
                case MissedRunKind.NoCatchUp:
                    return "To catch up by itself next time, turn on “" + ScheduleOptionText.RunMissed +
                        "” in Edit schedule.";
                default:
                    return string.Empty;
            }
        }

        // What to do, in a notification: open Rewindle and press one button, or the one thing to do when there is no button.
        public string NotificationNextStep()
        {
            switch (Kind)
            {
                case MissedRunKind.DriveMissing:
                    return "Plug it back in, then open Rewindle and choose Back up now.";
                case MissedRunKind.RepairPending:
                    return RepairBlocked
                        ? "Open Rewindle and choose Save problem report in Settings."
                        : "Open Rewindle and choose Repair interrupted move.";
                case MissedRunKind.RanAndFailed:
                    return FailedRunHasDetails
                        ? "Open Rewindle and choose See what happened."
                        : "Open Rewindle and choose the failed backup in Activity.";
                case MissedRunKind.ProgramProblem:
                    return EngineProfile.Current.ReinstallAdvice();
                case MissedRunKind.WaitingForPower:
                    return "Plug the PC in, or open Rewindle and choose Edit schedule to let backups start on battery.";
                default:
                    return "Open Rewindle and choose Back up now.";
            }
        }
    }

    internal static class MissedRunExplainer
    {
        // Why the latest slot was missed, from what Rewindle and Task Scheduler recorded. Only while the backup is overdue; the
        // first rule that fits wins. A run record beats Task Scheduler's result: it says more, and it has details to open.
        internal static MissedRunExplanation Explain(MissedRunFacts facts)
        {
            if (facts == null || facts.FreshnessState != BackupFreshnessState.Overdue || !facts.LatestDueUtc.HasValue)
            {
                return MissedRunExplanation.None;
            }
            TaskSchedule schedule = facts.Schedule;
            if (facts.RunActive || (schedule != null && schedule.State == BackupTaskState.Running))
            {
                return MissedRunExplanation.None;
            }
            DateTime slot = AlertWording.ToUtc(facts.LatestDueUtc.Value);
            DateTime attemptFrom = slot - BackupAlertPolicy.AttemptTolerance;
            string drive = facts.BackupDrive ?? string.Empty;
            if (facts.BackupDriveMissing)
            {
                return Make(MissedRunKind.DriveMissing, MissedRunTone.Danger, slot, null, drive, facts);
            }
            if (facts.RepairNeeded || facts.RepairBlocked)
            {
                return Make(MissedRunKind.RepairPending, MissedRunTone.Danger, null, null, drive, facts);
            }
            RunMetricView run = NewestBackupSince(facts.History, attemptFrom);
            if (run != null)
            {
                string state = run.StateKey ?? string.Empty;
                if (state == "failed" || state == "partial")
                {
                    return Make(MissedRunKind.RanAndFailed, MissedRunTone.Danger, FailedBackupCounter.StartedUtc(run), null, drive, facts);
                }
                if (state == "cancelled" || state == "cancel_failed")
                {
                    return Make(MissedRunKind.Cancelled, MissedRunTone.Warning, FailedBackupCounter.StartedUtc(run), null, drive, facts);
                }
            }
            if (schedule == null || !schedule.LastRunKnown)
            {
                return Make(MissedRunKind.Unknown, MissedRunTone.Warning, slot, null, drive, facts);
            }
            DateTime? lastRunUtc = null;
            if (schedule.LastRunTime.HasValue)
            {
                // A local time; in the hour that repeats when the clocks go back it is the later of its two moments, as the
                // freshness check takes it.
                DateTime resolved;
                DateTime ignored;
                if (!BackupFreshnessEvaluator.TryResolveLocalToUtc(
                    DateTime.SpecifyKind(schedule.LastRunTime.Value, DateTimeKind.Unspecified),
                    facts.Zone ?? TimeZoneInfo.Local,
                    true,
                    out resolved,
                    out ignored))
                {
                    return Make(MissedRunKind.Unknown, MissedRunTone.Warning, slot, null, drive, facts);
                }
                // A start more than a day ahead of the clock is not believed.
                if (resolved > AlertWording.ToUtc(facts.NowUtc).AddDays(1))
                {
                    return Make(MissedRunKind.Unknown, MissedRunTone.Warning, slot, null, drive, facts);
                }
                lastRunUtc = resolved;
            }
            int? result = schedule.LastTaskResult;
            bool attempted = lastRunUtc.HasValue && lastRunUtc.Value >= attemptFrom &&
                !(result.HasValue && result.Value == BackupAlertPolicy.NotSignedIn);
            if (attempted)
            {
                return ExplainAttempt(facts, schedule, lastRunUtc.Value, result, slot, drive);
            }
            // Windows has not started the backup since the slot.
            if (!schedule.AllowStartOnBatteries && facts.OnBattery == true)
            {
                return Make(MissedRunKind.WaitingForPower, MissedRunTone.Warning, null, null, drive, facts);
            }
            if (facts.AwakeAtSlot == true)
            {
                // The PC was on, so "off, asleep or signed out" would be wrong; nothing more is known.
                return Make(MissedRunKind.Unknown, MissedRunTone.Warning, slot, null, drive, facts);
            }
            if (!schedule.StartWhenAvailable)
            {
                return Make(MissedRunKind.NoCatchUp, MissedRunTone.Warning, slot, null, drive, facts);
            }
            return Make(MissedRunKind.PcOff, MissedRunTone.Warning, slot, null, drive, facts);
        }

        private static MissedRunExplanation ExplainAttempt(
            MissedRunFacts facts,
            TaskSchedule schedule,
            DateTime lastRunUtc,
            int? result,
            DateTime slot,
            string drive)
        {
            if (!result.HasValue ||
                result.Value == 0 ||
                result.Value == BackupAlertPolicy.TaskStillRunning ||
                result.Value == BackupAlertPolicy.TaskHasNotRun)
            {
                return Make(MissedRunKind.Unknown, MissedRunTone.Warning, slot, null, drive, facts);
            }
            int code = result.Value;
            if (BackupAlertPolicy.BusyResults.Contains(code))
            {
                return Make(MissedRunKind.Busy, MissedRunTone.Warning, lastRunUtc, code, drive, facts);
            }
            if (BackupAlertPolicy.StoppedResults.Contains(code))
            {
                return Make(MissedRunKind.Cancelled, MissedRunTone.Warning, lastRunUtc, code, drive, facts);
            }
            if (code == BackupAlertPolicy.ConditionsNotMet)
            {
                // One of the task's run conditions held it back; on battery with "Wait for AC power" is the one that can be named.
                if (!schedule.AllowStartOnBatteries && facts.OnBattery == true)
                {
                    return Make(MissedRunKind.WaitingForPower, MissedRunTone.Warning, null, null, drive, facts);
                }
                return Make(MissedRunKind.CouldNotStart, MissedRunTone.Warning, lastRunUtc, code, drive, facts);
            }
            if (BackupAlertPolicy.LauncherProgramCodes.Contains(code))
            {
                return Make(MissedRunKind.ProgramProblem, MissedRunTone.Danger, lastRunUtc, code, drive, facts);
            }
            return Make(MissedRunKind.CouldNotStart, MissedRunTone.Warning, lastRunUtc, code, drive, facts);
        }

        private static MissedRunExplanation Make(
            MissedRunKind kind,
            MissedRunTone tone,
            DateTime? atUtc,
            int? code,
            string drive,
            MissedRunFacts facts)
        {
            return new MissedRunExplanation(
                kind,
                tone,
                atUtc,
                code,
                kind == MissedRunKind.DriveMissing ? drive : string.Empty,
                facts.RepairBlocked && !facts.RepairNeeded,
                facts.FailedRunHasDetails);
        }

        private static RunMetricView NewestBackupSince(IList<RunMetricView> history, DateTime fromUtc)
        {
            if (history == null)
            {
                return null;
            }
            RunMetricView newest = null;
            foreach (RunMetricView run in history)
            {
                if (run == null || !string.Equals(run.TypeKey, "backup", StringComparison.Ordinal))
                {
                    continue;
                }
                DateTime started = FailedBackupCounter.StartedUtc(run);
                if (started < fromUtc)
                {
                    continue;
                }
                if (newest == null || started > FailedBackupCounter.StartedUtc(newest))
                {
                    newest = run;
                }
            }
            return newest;
        }
    }

    internal static class FailedBackupCounter
    {
        // Failed backups in a row since the last verified one, newest first, as far as the run history shows (it keeps the runs
        // Rewindle saw, so this is a lower bound). Dry runs are not backups. A backup the person stopped is not the backup failing,
        // so it is stepped over. A verified backup, a run from before the last verified one, and a state this build does not know
        // end the count: an unknown state never makes the mark red.
        internal static int CountInARow(IList<RunMetricView> history, DateTime? lastVerifiedUtc)
        {
            if (history == null)
            {
                return 0;
            }
            List<RunMetricView> backups = history
                .Where(run => run != null && string.Equals(run.TypeKey, "backup", StringComparison.Ordinal))
                .OrderByDescending(run => StartedUtc(run))
                .ToList();
            DateTime? verified = lastVerifiedUtc.HasValue ? AlertWording.ToUtc(lastVerifiedUtc.Value) : (DateTime?)null;
            int count = 0;
            foreach (RunMetricView run in backups)
            {
                if (verified.HasValue && StartedUtc(run) < verified.Value)
                {
                    break;
                }
                string state = run.StateKey ?? string.Empty;
                if (state == "cancelled" || state == "cancel_failed")
                {
                    continue;
                }
                if (state == "failed" || state == "partial")
                {
                    count++;
                    continue;
                }
                break;
            }
            return count;
        }

        internal static DateTime StartedUtc(RunMetricView run)
        {
            if (run.StartedUtc != default(DateTime))
            {
                return AlertWording.ToUtc(run.StartedUtc);
            }
            return DateTime.SpecifyKind(run.StartedLocal, DateTimeKind.Local).ToUniversalTime();
        }
    }

    internal sealed class BackupAlertInputs
    {
        // False when no status could be read: then nothing changes (an unknown is no news).
        public bool StatusReadable { get; set; }
        public bool ScheduleReadable { get; set; }
        public BackupFreshnessResult Freshness { get; set; }
        public DateTime? LastVerifiedUtc { get; set; }
        // A backup is running, being stopped, or the backup location is being moved: nothing changes until it ends.
        public bool RunActive { get; set; }
        public int FailedInARow { get; set; }
        public bool FailedRunHasDetails { get; set; }
        public MissedRunExplanation Explanation { get; set; }
    }

    internal sealed class BackupAlertNotification
    {
        internal BackupAlertNotification(string title, string text, bool failing)
        {
            Title = title ?? string.Empty;
            Text = text ?? string.Empty;
            Failing = failing;
        }

        public string Title { get; private set; }
        public string Text { get; private set; }
        public bool Failing { get; private set; }
    }

    internal sealed class BackupAlert
    {
        internal static readonly BackupAlert Quiet = new BackupAlert(
            BackupAlertLevel.None,
            BackupAlertReason.None,
            string.Empty,
            0,
            null,
            MissedRunExplanation.None,
            false);

        internal BackupAlert(
            BackupAlertLevel level,
            BackupAlertReason reason,
            string episodeKey,
            int failedInARow,
            DateTime? lastVerifiedUtc,
            MissedRunExplanation explanation,
            bool failedRunHasDetails)
        {
            Level = level;
            Reason = reason;
            EpisodeKey = episodeKey ?? string.Empty;
            FailedInARow = failedInARow;
            LastVerifiedUtc = lastVerifiedUtc;
            Explanation = explanation ?? MissedRunExplanation.None;
            FailedRunHasDetails = failedRunHasDetails;
        }

        public BackupAlertLevel Level { get; private set; }
        public BackupAlertReason Reason { get; private set; }
        // One problem: the reason and the last verified backup. A new verified backup ends it.
        public string EpisodeKey { get; private set; }
        public int FailedInARow { get; private set; }
        public DateTime? LastVerifiedUtc { get; private set; }
        public MissedRunExplanation Explanation { get; private set; }
        public bool FailedRunHasDetails { get; private set; }

        public string NotificationTitle()
        {
            switch (Reason)
            {
                case BackupAlertReason.Overdue:
                    return "Backup overdue";
                case BackupAlertReason.Failing:
                    return "Backups keep failing";
                case BackupAlertReason.Paused:
                    return "Automatic backups are paused";
                case BackupAlertReason.Clock:
                    return "Check your PC’s clock";
                case BackupAlertReason.Schedule:
                    return "Rewindle can’t read the backup schedule";
                default:
                    return string.Empty;
            }
        }

        // What the notification says: why, and the one thing to do. No path, folder or account name: Windows can show it on the
        // lock screen. Kept well under the 220 characters a balloon keeps.
        public string NotificationText(DateTime nowUtc, TimeZoneInfo zone)
        {
            switch (Reason)
            {
                case BackupAlertReason.Overdue:
                    MissedRunExplanation explanation = Explanation.Kind == MissedRunKind.None
                        ? new MissedRunExplanation(MissedRunKind.Unknown, MissedRunTone.Warning, null, null, null, false, false)
                        : Explanation;
                    return explanation.Reason(false, nowUtc, zone) + " " + explanation.NotificationNextStep();
                case BackupAlertReason.Failing:
                    string count = FailedInARow.ToString(CultureInfo.CurrentCulture);
                    string next = FailedRunHasDetails
                        ? "Open Rewindle and choose See what happened."
                        : "Open Rewindle and choose the latest failed backup in Activity.";
                    return LastVerifiedUtc.HasValue
                        ? "The last " + count + " backups didn’t finish. " + next
                        : "The last " + count + " backups didn’t finish, so your files aren’t backed up yet. " + next;
                case BackupAlertReason.Paused:
                    return "Rewindle won’t back up on its own until the schedule is turned back on. " +
                        "Open Rewindle and choose Edit schedule.";
                case BackupAlertReason.Clock:
                    return "Your PC’s clock looks wrong, so Rewindle can’t tell how old your backups are. " +
                        "Set the date and time in Windows Settings > Time & language.";
                case BackupAlertReason.Schedule:
                    return "Rewindle can’t read the Windows backup schedule, so it can’t tell whether backups run. " +
                        "Open Rewindle and choose Try again.";
                default:
                    return string.Empty;
            }
        }

        internal BackupAlertNotification ToNotification(DateTime nowUtc, TimeZoneInfo zone)
        {
            return new BackupAlertNotification(
                NotificationTitle(),
                NotificationText(nowUtc, zone),
                Level == BackupAlertLevel.Failing);
        }
    }

    internal static class BackupAlertEvaluator
    {
        // The alert for this refresh. The first row that fits wins:
        //   a status that can't be read, or a run in progress: the previous alert is kept, unchanged;
        //   a schedule that can't be read: only the failing count is judged (it needs no schedule), the reasons that come from the
        //     schedule are kept as they were, and after an hour without a break the unreadable schedule is an alert of its own;
        //   paused (nothing runs until it is turned back on, so it is the first thing to do);
        //   failed backups in a row at the threshold (red);
        //   overdue; the clock;
        //   anything else, Catching up and "No verified backup yet" included: no alert.
        internal static BackupAlert Evaluate(BackupAlertInputs inputs, BackupAlert previous, bool scheduleUnreadableTooLong)
        {
            BackupAlert held = previous ?? BackupAlert.Quiet;
            if (inputs == null || !inputs.StatusReadable || inputs.RunActive)
            {
                return held;
            }
            string verified = AlertWording.VerifiedKey(inputs.LastVerifiedUtc);
            bool failing = inputs.FailedInARow >= BackupAlertPolicy.FailingRunThreshold;
            BackupFreshnessResult freshness = inputs.Freshness;
            bool scheduleReadable = inputs.ScheduleReadable &&
                freshness != null &&
                freshness.State != BackupFreshnessState.Unavailable;
            if (!scheduleReadable)
            {
                if (failing)
                {
                    return Make(BackupAlertLevel.Failing, BackupAlertReason.Failing, verified, inputs);
                }
                if (scheduleUnreadableTooLong)
                {
                    return Make(BackupAlertLevel.Attention, BackupAlertReason.Schedule, verified, inputs);
                }
                if (held.Reason == BackupAlertReason.Paused ||
                    held.Reason == BackupAlertReason.Overdue ||
                    held.Reason == BackupAlertReason.Clock)
                {
                    return held;
                }
                return BackupAlert.Quiet;
            }
            if (freshness.State == BackupFreshnessState.Paused)
            {
                return Make(BackupAlertLevel.Attention, BackupAlertReason.Paused, verified, inputs);
            }
            if (failing)
            {
                return Make(BackupAlertLevel.Failing, BackupAlertReason.Failing, verified, inputs);
            }
            if (freshness.State == BackupFreshnessState.Overdue)
            {
                return Make(BackupAlertLevel.Attention, BackupAlertReason.Overdue, verified, inputs);
            }
            if (freshness.State == BackupFreshnessState.ClockAnomaly)
            {
                return Make(BackupAlertLevel.Attention, BackupAlertReason.Clock, verified, inputs);
            }
            return BackupAlert.Quiet;
        }

        private static BackupAlert Make(
            BackupAlertLevel level,
            BackupAlertReason reason,
            string verifiedKey,
            BackupAlertInputs inputs)
        {
            return new BackupAlert(
                level,
                reason,
                AlertWording.ReasonName(reason) + "|" + verifiedKey,
                Math.Max(0, inputs.FailedInARow),
                inputs.LastVerifiedUtc,
                reason == BackupAlertReason.Overdue ? inputs.Explanation : MissedRunExplanation.None,
                inputs.FailedRunHasDetails);
        }
    }

    internal sealed class BackupAlertPresence
    {
        // Someone is at the PC: the session is not locked and there was keyboard or mouse input lately.
        public bool UserActive { get; set; }
        // Rewindle's window is open and in front, so the person is already looking at it.
        public bool WindowInFront { get; set; }
        // The animation preview is on (a screenshot mode): nothing is told.
        public bool Quiet { get; set; }
    }

    // Decides, refresh by refresh, what the tray mark shows and whether to show a notification now. One notification per problem:
    // a problem told once (remembered in alerts.json) is never told again, an amber one waits until it has lasted 15 minutes, and
    // one that comes while nobody is at the PC waits for them. A pause made in Rewindle's own Edit schedule is never told while it
    // lasts (alerts.json keeps it until a schedule read shows backups on again). UI thread only; the clocks are passed in so a
    // test can drive them.
    internal sealed class BackupAlertMonitor
    {
        private readonly BackupAlertStore store;
        private readonly Func<long> monotonicTicks;
        private readonly long ticksPerSecond;
        private readonly Func<DateTime> utcNow;
        private readonly bool notificationsAllowed;
        private BackupAlert current = BackupAlert.Quiet;
        private MissedRunExplanation lastExplanation = MissedRunExplanation.None;
        private int lastFailedInARow;
        private string episodeKey = string.Empty;
        private long episodeStartedAt;
        private bool scheduleUnreadable;
        private long scheduleUnreadableSince;

        internal BackupAlertMonitor(BackupAlertStore store, bool notificationsAllowed)
            : this(
                store,
                Stopwatch.GetTimestamp,
                Stopwatch.Frequency,
                delegate { return DateTime.UtcNow; },
                notificationsAllowed)
        {
        }

        // notificationsAllowed is false for a second dashboard (an isolated presentation store, or another state folder): it
        // shows the mark but never notifies and never writes a told problem, so the installed dashboard is the only one that tells.
        internal BackupAlertMonitor(
            BackupAlertStore store,
            Func<long> monotonicTicks,
            long ticksPerSecond,
            Func<DateTime> utcNow,
            bool notificationsAllowed)
        {
            if (monotonicTicks == null)
            {
                throw new ArgumentNullException("monotonicTicks");
            }
            if (utcNow == null)
            {
                throw new ArgumentNullException("utcNow");
            }
            this.store = store ?? new BackupAlertStore(string.Empty);
            this.monotonicTicks = monotonicTicks;
            this.ticksPerSecond = Math.Max(1, ticksPerSecond);
            this.utcNow = utcNow;
            this.notificationsAllowed = notificationsAllowed;
        }

        internal BackupAlert Current
        {
            get { return current; }
        }

        // Why the latest scheduled backup was missed, from the latest readable refresh (None while not overdue).
        internal MissedRunExplanation LastExplanation
        {
            get { return lastExplanation; }
        }

        internal int LastFailedInARow
        {
            get { return lastFailedInARow; }
        }

        internal bool NotificationsOn
        {
            get { return store.Notify; }
        }

        internal bool NotificationsAllowed
        {
            get { return notificationsAllowed; }
        }

        internal BackupAlertNotification Update(BackupAlertInputs inputs, BackupAlertPresence presence)
        {
            long now = monotonicTicks();
            bool scheduleReadable = inputs != null && inputs.ScheduleReadable;
            if (scheduleReadable)
            {
                scheduleUnreadable = false;
            }
            else if (!scheduleUnreadable)
            {
                scheduleUnreadable = true;
                scheduleUnreadableSince = now;
            }
            bool tooLong = scheduleUnreadable && Elapsed(scheduleUnreadableSince, now) >= BackupAlertPolicy.ScheduleUnreadableLimit;
            current = BackupAlertEvaluator.Evaluate(inputs, current, tooLong);
            bool readable = inputs != null && inputs.StatusReadable;
            if (readable)
            {
                lastExplanation = inputs.Explanation ?? MissedRunExplanation.None;
                lastFailedInARow = Math.Max(0, inputs.FailedInARow);
            }
            if (scheduleReadable &&
                inputs.Freshness != null &&
                inputs.Freshness.State != BackupFreshnessState.Paused &&
                inputs.Freshness.State != BackupFreshnessState.Unavailable)
            {
                // The schedule reads as on: a pause the person made in Rewindle has ended, and a later pause, made anywhere, is news.
                store.SetUserPaused(false);
            }
            if (current.Level == BackupAlertLevel.None)
            {
                episodeKey = string.Empty;
                return null;
            }
            if (!string.Equals(episodeKey, current.EpisodeKey, StringComparison.Ordinal))
            {
                episodeKey = current.EpisodeKey;
                episodeStartedAt = now;
            }
            // Held while a run is going or the status can't be read: nothing is told about a state that may be changing.
            if (!notificationsAllowed || !readable || inputs.RunActive || store.WasTold(current.EpisodeKey))
            {
                return null;
            }
            if (current.Reason == BackupAlertReason.Paused && store.UserPaused)
            {
                // The person turned the schedule off in Rewindle: not news to them, however long it lasts and however many backups
                // they make by hand meanwhile (each one is a new problem key). The amber mark stays as the reminder.
                return null;
            }
            if (current.Level == BackupAlertLevel.Attention &&
                Elapsed(episodeStartedAt, now) < BackupAlertPolicy.AttentionSettle)
            {
                return null;
            }
            if (presence == null || presence.Quiet)
            {
                return null;
            }
            if (presence.WindowInFront || !store.Notify)
            {
                // Looking at Rewindle already, or notifications are off: told, so it does not come up later.
                RememberTold(current.EpisodeKey);
                return null;
            }
            if (!presence.UserActive)
            {
                return null;
            }
            RememberTold(current.EpisodeKey);
            return current.ToNotification(utcNow(), TimeZoneInfo.Local);
        }

        // Edit schedule just saved, and read back, the schedule turned off. The pause is the person's own until a schedule read
        // shows it on again. It is kept in alerts.json beside the told problems, not among them, so neither a restart, nor a
        // backup made by hand while paused, nor the end of the told list brings it up.
        internal void NoteUserPausedSchedule()
        {
            store.SetUserPaused(true);
        }

        internal bool UserPausedSchedule
        {
            get { return store.UserPaused; }
        }

        // Turns notifications on or off; true when the choice was saved for next time. Turning them on counts the problem shown
        // now as told: the person is in Settings, one click from Protection.
        internal bool SetNotifications(bool on)
        {
            bool saved = store.TrySetNotify(on);
            if (on && current.Level != BackupAlertLevel.None)
            {
                RememberTold(current.EpisodeKey);
            }
            return saved;
        }

        private void RememberTold(string key)
        {
            if (notificationsAllowed && !string.IsNullOrEmpty(key))
            {
                store.Remember(key, utcNow());
            }
        }

        private TimeSpan Elapsed(long since, long now)
        {
            long ticks = now - since;
            if (ticks <= 0)
            {
                return TimeSpan.Zero;
            }
            return TimeSpan.FromSeconds((double)ticks / ticksPerSecond);
        }
    }

    // alerts.json beside the dashboard's other preferences: whether notifications are on, the problems already told, and whether
    // the schedule is paused by the person's own choice in Rewindle (user_paused, optional, false when absent). Small, strict and
    // written atomically. A file that is missing or damaged gives the defaults (on, nothing told), so a damaged
    // preference fails toward telling the person about a backup problem. A file that can't be read just now (in use, refused) or
    // that a newer Rewindle wrote is left alone: this run keeps its choices in memory only, so the person's saved choice survives.
    internal sealed class BackupAlertStore
    {
        internal const string FileName = "alerts.json";
        internal const int SchemaVersion = 1;
        internal const int MaximumBytes = 16 * 1024;
        private const string TimeFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'";
        private static readonly Regex KeyPattern = new Regex(
            @"^(overdue|paused|failing|clock|schedule)\|[0-9A-Za-z:.\-]{1,64}$",
            RegexOptions.CultureInvariant);

        private enum LoadOutcome
        {
            Read,
            Malformed,
            Newer
        }

        private sealed class ToldEpisode
        {
            public string Key;
            public DateTime AtUtc;
        }

        private readonly string directory;
        private readonly Func<DateTime> utcNow;
        private List<ToldEpisode> told = new List<ToldEpisode>();
        private bool notify = true;
        private bool userPaused;
        private bool fileWritable;

        // directory "" keeps everything in memory.
        internal BackupAlertStore(string directory)
            : this(directory, delegate { return DateTime.UtcNow; })
        {
        }

        internal BackupAlertStore(string directory, Func<DateTime> utcNow)
        {
            this.utcNow = utcNow ?? new Func<DateTime>(delegate { return DateTime.UtcNow; });
            this.directory = NormalizeDirectory(directory);
            Load();
        }

        internal bool Notify
        {
            get { return notify; }
        }

        // The person turned the schedule off in Rewindle's Edit schedule, and no read since has shown it on.
        internal bool UserPaused
        {
            get { return userPaused; }
        }

        // Whether choices reach the file (false: memory only for this run).
        internal bool Persists
        {
            get { return fileWritable; }
        }

        internal string FilePath
        {
            get { return directory.Length == 0 ? string.Empty : Path.Combine(directory, FileName); }
        }

        internal static bool IsValidKey(string key)
        {
            return !string.IsNullOrEmpty(key) && key.Length <= 120 && KeyPattern.IsMatch(key);
        }

        internal bool WasTold(string key)
        {
            return !string.IsNullOrEmpty(key) &&
                told.Any(item => string.Equals(item.Key, key, StringComparison.Ordinal));
        }

        internal void Remember(string key, DateTime atUtc)
        {
            if (!IsValidKey(key) || WasTold(key))
            {
                return;
            }
            told.Add(new ToldEpisode { Key = key, AtUtc = AlertWording.ToUtc(atUtc) });
            Trim();
            TrySave();
        }

        internal bool TrySetNotify(bool on)
        {
            notify = on;
            return TrySave();
        }

        // Written only when it changes: every refresh with the schedule on asks to clear it.
        internal void SetUserPaused(bool paused)
        {
            if (userPaused == paused)
            {
                return;
            }
            userPaused = paused;
            TrySave();
        }

        private void Trim()
        {
            if (told.Count > BackupAlertPolicy.RememberedEpisodes)
            {
                told = told
                    .OrderByDescending(item => item.AtUtc)
                    .Take(BackupAlertPolicy.RememberedEpisodes)
                    .ToList();
            }
        }

        private void Load()
        {
            fileWritable = false;
            if (directory.Length == 0)
            {
                return;
            }
            string path = FilePath;
            try
            {
                if (Directory.Exists(directory) && IsReparsePoint(directory))
                {
                    return;
                }
                if (Directory.Exists(path))
                {
                    return;
                }
                if (!File.Exists(path))
                {
                    fileWritable = true;
                    return;
                }
                if (IsReparsePoint(path))
                {
                    return;
                }
                byte[] bytes;
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    if (stream.Length > MaximumBytes)
                    {
                        // Too big to be ours: damaged, so it may be written again from the defaults.
                        fileWritable = true;
                        return;
                    }
                    bytes = new byte[(int)stream.Length];
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        int read = stream.Read(bytes, offset, bytes.Length - offset);
                        if (read <= 0)
                        {
                            break;
                        }
                        offset += read;
                    }
                }
                LoadOutcome outcome = Parse(bytes);
                fileWritable = outcome != LoadOutcome.Newer;
            }
            catch (Exception error)
            {
                if (IsFatal(error))
                {
                    throw;
                }
                notify = true;
                told = new List<ToldEpisode>();
                userPaused = false;
                fileWritable = false;
            }
        }

        private LoadOutcome Parse(byte[] bytes)
        {
            IDictionary<string, object> document;
            try
            {
                string text = new UTF8Encoding(false, true).GetString(bytes);
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = MaximumBytes;
                serializer.RecursionLimit = 8;
                document = serializer.DeserializeObject(text) as IDictionary<string, object>;
            }
            catch (ArgumentException)
            {
                return LoadOutcome.Malformed;
            }
            catch (InvalidOperationException)
            {
                return LoadOutcome.Malformed;
            }
            object rawVersion;
            if (document == null || !document.TryGetValue("schema_version", out rawVersion) || !(rawVersion is int))
            {
                return LoadOutcome.Malformed;
            }
            int version = (int)rawVersion;
            if (version > SchemaVersion)
            {
                return LoadOutcome.Newer;
            }
            object rawNotify;
            if (version != SchemaVersion || !document.TryGetValue("notify", out rawNotify) || !(rawNotify is bool))
            {
                return LoadOutcome.Malformed;
            }
            bool loadedUserPaused = false;
            object rawUserPaused;
            if (document.TryGetValue("user_paused", out rawUserPaused))
            {
                if (!(rawUserPaused is bool))
                {
                    return LoadOutcome.Malformed;
                }
                loadedUserPaused = (bool)rawUserPaused;
            }
            List<ToldEpisode> loaded = new List<ToldEpisode>();
            object rawTold;
            if (document.TryGetValue("told", out rawTold) && rawTold != null)
            {
                object[] items = rawTold as object[];
                if (items == null)
                {
                    return LoadOutcome.Malformed;
                }
                DateTime now = AlertWording.ToUtc(utcNow());
                foreach (object item in items)
                {
                    IDictionary<string, object> entry = item as IDictionary<string, object>;
                    object rawKey;
                    object rawAt;
                    if (entry == null ||
                        !entry.TryGetValue("key", out rawKey) || !(rawKey is string) ||
                        !entry.TryGetValue("at_utc", out rawAt) || !(rawAt is string))
                    {
                        continue;
                    }
                    string key = (string)rawKey;
                    DateTime at;
                    if (!IsValidKey(key) ||
                        !DateTime.TryParseExact(
                            (string)rawAt,
                            TimeFormat,
                            CultureInfo.InvariantCulture,
                            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                            out at))
                    {
                        continue;
                    }
                    at = DateTime.SpecifyKind(at, DateTimeKind.Utc);
                    // Long ago, or told "in the future" by a clock that was wrong: forgotten.
                    if (at < now - BackupAlertPolicy.EpisodeMemory || at > now.AddDays(1))
                    {
                        continue;
                    }
                    if (loaded.Any(existing => string.Equals(existing.Key, key, StringComparison.Ordinal)))
                    {
                        continue;
                    }
                    loaded.Add(new ToldEpisode { Key = key, AtUtc = at });
                }
            }
            notify = (bool)rawNotify;
            userPaused = loadedUserPaused;
            told = loaded;
            Trim();
            return LoadOutcome.Read;
        }

        private string Serialize()
        {
            List<Dictionary<string, object>> entries = new List<Dictionary<string, object>>();
            foreach (ToldEpisode item in told.OrderBy(entry => entry.AtUtc))
            {
                Dictionary<string, object> entry = new Dictionary<string, object>();
                entry["key"] = item.Key;
                entry["at_utc"] = item.AtUtc.ToString(TimeFormat, CultureInfo.InvariantCulture);
                entries.Add(entry);
            }
            Dictionary<string, object> document = new Dictionary<string, object>();
            document["schema_version"] = SchemaVersion;
            document["notify"] = notify;
            document["user_paused"] = userPaused;
            document["told"] = entries;
            return new JavaScriptSerializer().Serialize(document);
        }

        private bool TrySave()
        {
            if (!fileWritable || directory.Length == 0)
            {
                return false;
            }
            string temporaryPath = null;
            try
            {
                Directory.CreateDirectory(directory);
                string path = FilePath;
                if (IsReparsePoint(directory) || Directory.Exists(path) || (File.Exists(path) && IsReparsePoint(path)))
                {
                    return false;
                }
                byte[] bytes = new UTF8Encoding(false, true).GetBytes(Serialize());
                if (bytes.Length > MaximumBytes)
                {
                    return false;
                }
                temporaryPath = Path.Combine(directory, ".alerts." + Guid.NewGuid().ToString("N") + ".tmp");
                using (FileStream stream = new FileStream(
                    temporaryPath,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    4096,
                    FileOptions.WriteThrough))
                {
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush(true);
                }
                if (File.Exists(path))
                {
                    AtomicFile.ReplaceExisting(temporaryPath, path);
                }
                else
                {
                    File.Move(temporaryPath, path);
                }
                temporaryPath = null;
                return true;
            }
            catch (Exception error)
            {
                if (IsFatal(error))
                {
                    throw;
                }
                return false;
            }
            finally
            {
                if (!string.IsNullOrEmpty(temporaryPath))
                {
                    try
                    {
                        File.Delete(temporaryPath);
                    }
                    catch (Exception error)
                    {
                        if (IsFatal(error))
                        {
                            throw;
                        }
                    }
                }
            }
        }

        private static string NormalizeDirectory(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return string.Empty;
            }
            try
            {
                return Path.GetFullPath(value).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            }
            catch (Exception error)
            {
                if (IsFatal(error))
                {
                    throw;
                }
                return string.Empty;
            }
        }

        private static bool IsReparsePoint(string path)
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }

        private static bool IsFatal(Exception error)
        {
            return error is OutOfMemoryException ||
                error is StackOverflowException ||
                error is System.Threading.ThreadAbortException ||
                error is AccessViolationException;
        }
    }

    // A tray icon with a mark, holding the icon handle it owns (Bitmap.GetHicon makes one the caller must destroy).
    internal sealed class TrayBadgeIcon : IDisposable
    {
        private IntPtr handle;
        private Drawing.Icon icon;

        internal TrayBadgeIcon(IntPtr handle)
        {
            this.handle = handle;
            try
            {
                icon = Drawing.Icon.FromHandle(handle);
            }
            catch
            {
                DestroyIcon(handle);
                this.handle = IntPtr.Zero;
                throw;
            }
        }

        public Drawing.Icon Icon
        {
            get { return icon; }
        }

        public void Dispose()
        {
            if (icon != null)
            {
                icon.Dispose();
                icon = null;
            }
            if (handle != IntPtr.Zero)
            {
                DestroyIcon(handle);
                handle = IntPtr.Zero;
            }
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool DestroyIcon(IntPtr handle);
    }

    // The app icon with a mark in its bottom-right corner: an amber triangle while something needs attention, a red disc while
    // backups keep failing. The shape says it as well as the colour, as on the page. A dark ring around the mark keeps it apart
    // from the icon and readable on a light or a dark taskbar. From 24 pixels the shape carries a "!".
    internal static class TrayBadgeRenderer
    {
        internal static readonly Drawing.Color AttentionFill = Drawing.Color.FromArgb(255, 0xFF, 0xB0, 0x20);
        internal static readonly Drawing.Color FailingFill = Drawing.Color.FromArgb(255, 0xFF, 0x4D, 0x5E);
        internal static readonly Drawing.Color Halo = Drawing.Color.FromArgb(255, 0x20, 0x20, 0x20);
        internal static readonly Drawing.Color AttentionMark = Drawing.Color.FromArgb(255, 0x3A, 0x24, 0x00);
        internal static readonly Drawing.Color FailingMark = Drawing.Color.FromArgb(255, 0xFF, 0xFF, 0xFF);

        internal static int BadgeSize(int size)
        {
            return Math.Max(7, (int)Math.Round(size * 0.55, MidpointRounding.AwayFromZero));
        }

        // The marked icon as a bitmap (for the icon, and for tests to look at), or null for no mark.
        internal static Drawing.Bitmap Draw(Drawing.Icon baseIcon, BackupAlertLevel level, int size)
        {
            if (level == BackupAlertLevel.None || baseIcon == null)
            {
                return null;
            }
            int pixels = Math.Max(16, Math.Min(256, size));
            Drawing.Bitmap bitmap = new Drawing.Bitmap(pixels, pixels, DrawingImaging.PixelFormat.Format32bppArgb);
            try
            {
                using (Drawing.Graphics graphics = Drawing.Graphics.FromImage(bitmap))
                {
                    graphics.Clear(Drawing.Color.Transparent);
                    graphics.InterpolationMode = Drawing2D.InterpolationMode.HighQualityBicubic;
                    graphics.PixelOffsetMode = Drawing2D.PixelOffsetMode.HighQuality;
                    // The exe's icon arrives at 32 pixels; it is drawn at the tray's own size.
                    using (Drawing.Bitmap source = baseIcon.ToBitmap())
                    {
                        graphics.DrawImage(source, new Drawing.Rectangle(0, 0, pixels, pixels));
                    }
                    graphics.SmoothingMode = Drawing2D.SmoothingMode.AntiAlias;
                    int badge = BadgeSize(pixels);
                    float x = pixels - badge;
                    float y = pixels - badge;
                    bool failing = level == BackupAlertLevel.Failing;
                    using (Drawing.SolidBrush halo = new Drawing.SolidBrush(Halo))
                    using (Drawing.SolidBrush fill = new Drawing.SolidBrush(failing ? FailingFill : AttentionFill))
                    {
                        if (failing)
                        {
                            graphics.FillEllipse(halo, x, y, badge, badge);
                            graphics.FillEllipse(fill, x + 1, y + 1, badge - 2, badge - 2);
                        }
                        else
                        {
                            graphics.FillPolygon(halo, new[]
                            {
                                new Drawing.PointF(x + badge / 2f, y),
                                new Drawing.PointF(x + badge, y + badge),
                                new Drawing.PointF(x, y + badge)
                            });
                            graphics.FillPolygon(fill, new[]
                            {
                                new Drawing.PointF(x + badge / 2f, y + 2.2f),
                                new Drawing.PointF(x + badge - 1.6f, y + badge - 1),
                                new Drawing.PointF(x + 1.6f, y + badge - 1)
                            });
                        }
                    }
                    if (pixels >= 24)
                    {
                        graphics.SmoothingMode = Drawing2D.SmoothingMode.None;
                        graphics.PixelOffsetMode = Drawing2D.PixelOffsetMode.Half;
                        int left = (int)x;
                        int top = (int)y;
                        int bar = Math.Max(2, (int)Math.Round(badge / 7.0, MidpointRounding.AwayFromZero));
                        int barLeft = left + (badge - bar) / 2;
                        int barTop = top + (int)(badge * (failing ? 0.22 : 0.36));
                        int barBottom = top + (int)(badge * (failing ? 0.58 : 0.68));
                        int dotTop = top + (int)(badge * (failing ? 0.68 : 0.75));
                        using (Drawing.SolidBrush mark = new Drawing.SolidBrush(failing ? FailingMark : AttentionMark))
                        {
                            graphics.FillRectangle(mark, barLeft, barTop, bar, Math.Max(1, barBottom - barTop));
                            graphics.FillRectangle(mark, barLeft, dotTop, bar, bar);
                        }
                    }
                }
                return bitmap;
            }
            catch
            {
                bitmap.Dispose();
                throw;
            }
        }

        internal static TrayBadgeIcon Compose(Drawing.Icon baseIcon, BackupAlertLevel level, int size)
        {
            using (Drawing.Bitmap bitmap = Draw(baseIcon, level, size))
            {
                if (bitmap == null)
                {
                    return null;
                }
                return new TrayBadgeIcon(bitmap.GetHicon());
            }
        }
    }

    // How long since the last keyboard or mouse input in this session. GetLastInputInfo and GetTickCount count the same 32-bit
    // milliseconds, so the difference is right across their wrap.
    internal static class UserPresence
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct LastInputInfo
        {
            public uint Size;
            public uint Time;
        }

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LastInputInfo info);

        [DllImport("kernel32.dll")]
        private static extern uint GetTickCount();

        internal static TimeSpan? IdleTime()
        {
            try
            {
                LastInputInfo info = new LastInputInfo();
                info.Size = (uint)Marshal.SizeOf(typeof(LastInputInfo));
                if (!GetLastInputInfo(ref info))
                {
                    return null;
                }
                uint idle = unchecked(GetTickCount() - info.Time);
                return TimeSpan.FromMilliseconds(idle);
            }
            catch (Exception)
            {
                return null;
            }
        }
    }
}
