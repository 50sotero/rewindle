using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ResticBackuper.Dashboard
{
    // The window's side of the backup alerts (the logic is in BackupAlerts.cs): what each refresh feeds the monitor, the mark on
    // the tray icon, the notification, the Settings switch and what the page is told. It only reads, with the dashboard's own
    // rights; the one file it writes is alerts.json in the per-user settings folder. An alert never breaks a refresh.
    public sealed partial class DashboardWindow
    {
        private BackupAlertMonitor backupAlerts;
        private TrayBadgeIcon trayBadgeAttention;
        private TrayBadgeIcon trayBadgeFailing;
        private BackupAlertLevel trayBadgeShown;
        private bool sessionLocked;
        // Set when this refresh showed an alert, so the per-run "Backup didn't finish" balloon does not land on top of it.
        private bool alertToastShownThisRefresh;
        // Whether the newest balloon is an alert: only selecting an alert opens Protection (ShowTrayMessage clears it).
        private bool trayBalloonIsAlert;
        private bool alertFailureLogged;
        private DateTime? alertProcessStartUtc;

        // Called once the tray icon exists. A second dashboard (an isolated presentation store, or a --state-dir other than the
        // engine's own) reads the same backup task, so it shows the mark but never notifies and never writes alerts.json: the
        // installed one tells. The logon task passes the engine's own state folder, so the installed dashboard does.
        private void InitializeBackupAlerts()
        {
            bool tells = options != null && !options.UseIsolatedPresentationStore && !options.UsesOtherStateDirectory;
            string directory = string.Empty;
            if (tells)
            {
                try
                {
                    string settings = DashboardThemeManager.SettingsPath;
                    directory = string.IsNullOrEmpty(settings)
                        ? string.Empty
                        : Path.GetDirectoryName(Path.GetFullPath(settings));
                }
                catch (Exception)
                {
                    directory = string.Empty;
                }
            }
            backupAlerts = new BackupAlertMonitor(new BackupAlertStore(directory), tells);
            try
            {
                using (Process current = Process.GetCurrentProcess())
                {
                    alertProcessStartUtc = current.StartTime.ToUniversalTime();
                }
            }
            catch (Exception)
            {
                alertProcessStartUtc = null;
            }
            if (trayIcon != null)
            {
                trayIcon.BalloonTipClicked += OnTrayBalloonClicked;
                trayIcon.BalloonTipClosed += OnTrayBalloonClosed;
            }
        }

        // Each telemetry refresh, before HandleStateTransition. A null snapshot is a status that could not be read: nothing changes.
        private void UpdateBackupAlerts(TelemetrySnapshot snapshot)
        {
            ApplyBackupAlerts(snapshot, ReadAlertPresence());
        }

        private void ApplyBackupAlerts(TelemetrySnapshot snapshot, BackupAlertPresence presence)
        {
            alertToastShownThisRefresh = false;
            if (backupAlerts == null)
            {
                return;
            }
            try
            {
                BackupAlertNotification toast = backupAlerts.Update(BuildBackupAlertInputs(snapshot), presence);
                ApplyTrayBadge(backupAlerts.Current.Level);
                if (toast != null && trayIcon != null)
                {
                    ShowTrayMessage(
                        toast.Title,
                        toast.Text,
                        toast.Failing ? Forms.ToolTipIcon.Error : Forms.ToolTipIcon.Warning);
                    trayBalloonIsAlert = true;
                    alertToastShownThisRefresh = true;
                }
            }
            catch (Exception error)
            {
                if (!alertFailureLogged)
                {
                    alertFailureLogged = true;
                    CrashLog.Write("Backup alerts", error);
                }
            }
        }

        private BackupAlertInputs BuildBackupAlertInputs(TelemetrySnapshot snapshot)
        {
            TaskSchedule schedule = currentTaskSchedule;
            DateTime? verified = snapshot == null ? null : snapshot.LastVerifiedFinishedUtc;
            BackupFreshnessResult freshness = BackupFreshnessEvaluator.EvaluateNow(
                schedule,
                verified,
                scheduleCoveredThroughUtc,
                AvailableSinceUtc());
            IList<RunMetricView> history = snapshot == null ? null : snapshot.History;
            bool runActive =
                (snapshot != null &&
                    (snapshot.IsActive ||
                        string.Equals(snapshot.StateKey, "cancelling", StringComparison.OrdinalIgnoreCase))) ||
                (schedule != null && schedule.State == BackupTaskState.Running) ||
                RepositoryMoveRunning();
            // The hero offers "See what happened" for the latest run when it failed and is in the history.
            bool failedRunHasDetails = snapshot != null && snapshot.IsFailure && !snapshot.IsActive &&
                history != null && !string.IsNullOrEmpty(snapshot.RunId) &&
                history.Any(run => run != null && string.Equals(run.RunId, snapshot.RunId, StringComparison.Ordinal));
            RepositoryRecoveryStatus recovery = repositoryRecoveryStatus;
            bool unfinishedMove = recovery != null && recovery.Exists && !recovery.IsMoveRunning;

            MissedRunFacts facts = new MissedRunFacts();
            facts.FreshnessState = freshness.State;
            facts.LatestDueUtc = freshness.LatestDueUtc;
            facts.NowUtc = DateTime.UtcNow;
            facts.Zone = TimeZoneInfo.Local;
            facts.Schedule = schedule;
            facts.History = history;
            facts.RunActive = runActive;
            facts.OnBattery = ReadOnBattery();
            facts.AwakeAtSlot = AwakeAtSlot(freshness.LatestDueUtc);
            facts.BackupDriveMissing = !repositoryVolumeReady;
            facts.BackupDrive = AlertWording.DriveOf(
                currentSourceConfiguration == null ? string.Empty : currentSourceConfiguration.RepositoryPath);
            facts.RepairNeeded = unfinishedMove && recovery.IsRecoverable;
            facts.RepairBlocked = unfinishedMove && !recovery.IsRecoverable;
            facts.FailedRunHasDetails = failedRunHasDetails;

            BackupAlertInputs inputs = new BackupAlertInputs();
            inputs.StatusReadable = snapshot != null && !snapshot.IsStatusUnavailable;
            inputs.ScheduleReadable = schedule != null && freshness.State != BackupFreshnessState.Unavailable;
            inputs.Freshness = freshness;
            inputs.LastVerifiedUtc = verified;
            inputs.RunActive = runActive;
            inputs.FailedInARow = FailedBackupCounter.CountInARow(history, verified);
            inputs.FailedRunHasDetails = failedRunHasDetails;
            inputs.Explanation = MissedRunExplainer.Explain(facts);
            return inputs;
        }

        // The PC was seen awake at the slot: this app was already running, and the PC has not come back (a sign-in or a wake)
        // since. Then "off, asleep or signed out" would be wrong. Null when that can't be said.
        private bool? AwakeAtSlot(DateTime? slotUtc)
        {
            DateTime? available = AvailableSinceUtc();
            if (!slotUtc.HasValue || !alertProcessStartUtc.HasValue || !available.HasValue)
            {
                return null;
            }
            return alertProcessStartUtc.Value < slotUtc.Value && available.Value <= slotUtc.Value
                ? true
                : (bool?)null;
        }

        private static bool? ReadOnBattery()
        {
            try
            {
                switch (Forms.SystemInformation.PowerStatus.PowerLineStatus)
                {
                    case Forms.PowerLineStatus.Offline:
                        return true;
                    case Forms.PowerLineStatus.Online:
                        return false;
                    default:
                        return null;
                }
            }
            catch (Exception)
            {
                return null;
            }
        }

        // Whether someone is at the PC and whether they are already looking at Rewindle.
        private BackupAlertPresence ReadAlertPresence()
        {
            BackupAlertPresence presence = new BackupAlertPresence();
            presence.Quiet = previewEnabled;
            try
            {
                presence.WindowInFront = !hideAtLoad && !startupPlacementPending &&
                    IsVisible && IsActive && WindowState != WindowState.Minimized;
            }
            catch (Exception)
            {
                presence.WindowInFront = false;
            }
            TimeSpan? idle = UserPresence.IdleTime();
            presence.UserActive = !sessionLocked &&
                (!idle.HasValue || idle.Value < BackupAlertPolicy.PresenceIdleLimit);
            return presence;
        }

        // A locked or disconnected session has nobody to tell. SystemEvents raises this on its own thread.
        private void OnSessionSwitch(object sender, SessionSwitchEventArgs args)
        {
            bool locked;
            switch (args.Reason)
            {
                case SessionSwitchReason.SessionLock:
                case SessionSwitchReason.ConsoleDisconnect:
                case SessionSwitchReason.RemoteDisconnect:
                    locked = true;
                    break;
                case SessionSwitchReason.SessionUnlock:
                case SessionSwitchReason.ConsoleConnect:
                case SessionSwitchReason.RemoteConnect:
                case SessionSwitchReason.SessionLogon:
                    locked = false;
                    break;
                default:
                    return;
            }
            if (Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
            {
                return;
            }
            Dispatcher.BeginInvoke(
                new Action(delegate { sessionLocked = locked; }),
                DispatcherPriority.Background);
        }

        // The tray icon carries a mark while the level is not None, and is the very same app icon again as soon as it is. It is
        // changed only when the level changes, and each marked icon is drawn once and kept until Rewindle closes.
        private void ApplyTrayBadge(BackupAlertLevel level)
        {
            if (trayIcon == null || level == trayBadgeShown)
            {
                return;
            }
            Drawing.Icon baseIcon = trayApplicationIcon ?? Drawing.SystemIcons.Shield;
            Drawing.Icon next = baseIcon;
            if (level != BackupAlertLevel.None)
            {
                TrayBadgeIcon badge = level == BackupAlertLevel.Failing ? trayBadgeFailing : trayBadgeAttention;
                if (badge == null)
                {
                    badge = TrayBadgeRenderer.Compose(baseIcon, level, Forms.SystemInformation.SmallIconSize.Width);
                    if (level == BackupAlertLevel.Failing)
                    {
                        trayBadgeFailing = badge;
                    }
                    else
                    {
                        trayBadgeAttention = badge;
                    }
                }
                if (badge != null)
                {
                    next = badge.Icon;
                }
            }
            trayIcon.Icon = next;
            trayBadgeShown = level;
        }

        // OnClosed, after the tray icon has been disposed (it no longer uses the marked icons).
        private void DisposeBackupAlerts()
        {
            if (trayBadgeAttention != null)
            {
                trayBadgeAttention.Dispose();
                trayBadgeAttention = null;
            }
            if (trayBadgeFailing != null)
            {
                trayBadgeFailing.Dispose();
                trayBadgeFailing = null;
            }
            trayBadgeShown = BackupAlertLevel.None;
        }

        // Selecting a balloon opens Rewindle. An alert also opens Protection, where it is explained, unless a restore, run details or
        // the folder chooser is open: those keep the page they are on.
        private void OnTrayBalloonClicked(object sender, EventArgs args)
        {
            bool alert = trayBalloonIsAlert;
            trayBalloonIsAlert = false;
            Dispatcher.BeginInvoke(new Action(delegate
            {
                ShowDashboard();
                if (AlertBalloonOpensProtection(alert))
                {
                    ShowDashboardPage("Protection");
                    PublishWebPresentationState();
                }
            }));
        }

        private bool AlertBalloonOpensProtection(bool alertBalloon)
        {
            return alertBalloon && !restoreFlowOpen && webRunDetails == null && !sourcePickerOpen;
        }

        private void OnTrayBalloonClosed(object sender, EventArgs args)
        {
            trayBalloonIsAlert = false;
        }

        // Edit schedule saved the schedule turned off: the pause is the person's own and is not announced while it lasts.
        private void NoteBackupAlertScheduleSaved(ScheduleChangeRequest requested)
        {
            if (backupAlerts != null && requested != null && !requested.Enabled)
            {
                backupAlerts.NoteUserPausedSchedule();
            }
        }

        // The hover text while backups keep failing ("3 backups in a row didn't finish"), or empty.
        private string DescribeFailingStreak()
        {
            BackupAlert alert = backupAlerts == null ? null : backupAlerts.Current;
            if (alert == null || alert.Level != BackupAlertLevel.Failing)
            {
                return string.Empty;
            }
            return alert.FailedInARow.ToString(CultureInfo.CurrentCulture) + " backups in a row didn’t finish";
        }

        // What the page is told: the switch, the mark, the failing count and threshold, when Windows last started the backup, and
        // why the latest scheduled backup was missed while it is overdue. Null without alerts (the page then draws no switch).
        private Dictionary<string, object> BuildWebAlertsState()
        {
            if (backupAlerts == null)
            {
                return null;
            }
            BackupAlert alert = backupAlerts.Current;
            Dictionary<string, object> alerts = new Dictionary<string, object>();
            alerts["notify"] = backupAlerts.NotificationsOn;
            alerts["level"] = AlertWording.LevelName(alert.Level);
            alerts["reason"] = AlertWording.ReasonName(alert.Reason);
            alerts["failedRuns"] = alert.Level == BackupAlertLevel.Failing ? alert.FailedInARow : backupAlerts.LastFailedInARow;
            alerts["failingAfter"] = BackupAlertPolicy.FailingRunThreshold;
            alerts["lastRun"] = BuildWebLastRunState(currentTaskSchedule);
            alerts["missedRun"] = BuildWebMissedRunState(backupAlerts.LastExplanation);
            return alerts;
        }

        // Left out when Windows recorded no start the card may name: none, one that can't be placed, or "not signed in" (which the
        // missed-run sentence counts as not started, so the card must not say the backup started then).
        private static Dictionary<string, object> BuildWebLastRunState(TaskSchedule schedule)
        {
            DateTime? started = MissedRunExplainer.LastStartUtc(schedule, DateTime.UtcNow, TimeZoneInfo.Local);
            if (!started.HasValue)
            {
                return null;
            }
            Dictionary<string, object> lastRun = new Dictionary<string, object>();
            lastRun["at"] = AlertWording.FormatUtc(started.Value);
            lastRun["ok"] = schedule.LastTaskResult.HasValue && schedule.LastTaskResult.Value == 0;
            lastRun["code"] = schedule.LastTaskResult.HasValue
                ? AlertWording.FormatCode(schedule.LastTaskResult.Value)
                : string.Empty;
            return lastRun;
        }

        // Worded at every publish, so "today" stays true; the clock is 24-hour for the page to put in the viewer's own.
        private static Dictionary<string, object> BuildWebMissedRunState(MissedRunExplanation explanation)
        {
            if (explanation == null || explanation.Kind == MissedRunKind.None)
            {
                return null;
            }
            Dictionary<string, object> missed = new Dictionary<string, object>();
            missed["kind"] = AlertWording.KindName(explanation.Kind);
            missed["at"] = explanation.AtUtc.HasValue ? AlertWording.FormatUtc(explanation.AtUtc.Value) : string.Empty;
            missed["text"] = explanation.Reason(true, DateTime.UtcNow, TimeZoneInfo.Local);
            missed["nextStep"] = explanation.PageNextStep();
            missed["code"] = explanation.Code;
            missed["tone"] = AlertWording.ToneName(explanation.Tone);
            return missed;
        }

        // Settings > Backup alerts. A per-user preference like the theme: not a protected command, and it works during a backup.
        private bool ExecuteAlertsCommand(IDictionary<string, object> payload, out string message)
        {
            string value = WebReadString(payload, "notify", 8);
            if (value != "on" && value != "off")
            {
                message = "The requested alert setting is not valid.";
                return false;
            }
            if (backupAlerts == null)
            {
                message = "Backup alerts are still starting. Try again in a moment.";
                return false;
            }
            bool on = value == "on";
            bool saved = backupAlerts.SetNotifications(on);
            if (!saved)
            {
                message = "Backup alerts are " + value + " until Rewindle closes. Rewindle couldn’t save this choice for " +
                    "next time, so choose it again later.";
            }
            else
            {
                message = on
                    ? "Backup alerts are on."
                    : "Backup alerts are off. The icon in the notification area still shows when backups need attention.";
            }
            PublishWebPresentationState();
            return true;
        }
    }
}
