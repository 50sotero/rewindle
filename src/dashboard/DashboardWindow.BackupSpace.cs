using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace ResticBackuper.Dashboard
{
    // Backup drive space: what the Backup location card says about how full the backup location is (state.repository.space). The free
    // space and the drive's size are read with the volume probe, off the window's thread, from the drive root only (never a listing of
    // the backup folder); what the backups take comes from the engine's last-success.json; the reserve from the plan; the forecast from
    // the run history the dashboard already keeps. BackupSpaceEvaluator decides the level, and the page only words it.
    public partial class DashboardWindow
    {
        // What the last probe of the backup location's drive read, besides its text and readiness (DashboardWindow.cs). -1 is unknown.
        // `repositoryVolumeRead` is true once a probe of the current location has finished, so the card can say it is still checking.
        private long repositoryVolumeFreeBytes = -1;
        private long repositoryVolumeTotalBytes = -1;
        private bool repositoryVolumeRead;
        // The person's Low space warning, in weeks (4, 8 or 12), read once at start-up and kept by DashboardSpaceWarningStore.
        private int spaceWarningWeeks = BackupSpaceEvaluator.DefaultWarnWeeks;
        // What the last answer worked out while no backup was running was based on, and the location it was for (see
        // BackupSpaceEvaluator.HoldDuringRun). The facts are kept rather than the answer, so a Low space warning chosen during a run
        // is used at once. Each call builds new facts, so nothing else holds these.
        private BackupSpaceFacts idleSpaceFacts;
        private string idleSpacePath;

        private sealed class RepositoryVolumeProbe
        {
            public RepositoryVolumeProbe(string text, bool ready, long freeBytes, long totalBytes)
            {
                Text = text;
                Ready = ready;
                FreeBytes = freeBytes;
                TotalBytes = totalBytes;
            }

            public string Text { get; private set; }
            public bool Ready { get; private set; }
            public long FreeBytes { get; private set; }
            public long TotalBytes { get; private set; }
        }

        // The free space and size of the drive a path is on, as the backup service sees them: TotalFreeSpace is what the engine's own
        // check (shutil.disk_usage) compares with the reserve, not the space this account may use. Only the drive root is asked; nothing
        // is listed or opened. False for anything Windows will not say, or a reading that makes no sense.
        internal static bool TryReadDriveSpace(string path, out long freeBytes, out long totalBytes)
        {
            freeBytes = -1;
            totalBytes = -1;
            try
            {
                string root = Path.GetPathRoot(path ?? string.Empty);
                if (string.IsNullOrWhiteSpace(root))
                {
                    return false;
                }
                DriveInfo drive = new DriveInfo(root);
                if (!drive.IsReady)
                {
                    return false;
                }
                long free = drive.TotalFreeSpace;
                long total = drive.TotalSize;
                if (free < 0 || total <= 0 || free > total)
                {
                    return false;
                }
                freeBytes = free;
                totalBytes = total;
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }

        // The probe of the drive runs again at the next refresh instead of up to a minute later: after Refresh (F5 or Try again), so a
        // "too full" clears as soon as someone frees space and asks, and when a backup ends, so the figures move with the run that changed
        // them. The deadline is a Stopwatch value like the rest of the window's timers; 0 has passed.
        private void ProbeRepositorySpaceSooner()
        {
            repositoryVolumeNextProbeAt = 0;
        }

        private void LoadSpaceWarningPreference()
        {
            int weeks;
            DashboardSpaceWarningStore.TryLoad(out weeks);
            spaceWarningWeeks = weeks;
        }

        // "4", "8" or "12", exactly, and nothing else.
        internal static bool TryParseSpaceWarningWeeks(IDictionary<string, object> payload, out int weeks)
        {
            weeks = BackupSpaceEvaluator.DefaultWarnWeeks;
            string value = WebReadString(payload, "weeks", 8);
            int parsed;
            if ((value != "4" && value != "8" && value != "12") ||
                !int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) ||
                !BackupSpaceEvaluator.IsAllowedWarnWeeks(parsed))
            {
                return false;
            }
            weeks = parsed;
            return true;
        }

        // Settings > Backup location > Low space warning. Only changes when the page warns, never what a backup does, so like the theme it
        // is not a protected action: it needs no Windows permission and works while a backup runs. The answer is the notice the page shows.
        private bool ExecuteSpaceWarningCommand(IDictionary<string, object> payload, out string message)
        {
            int weeks;
            if (!TryParseSpaceWarningWeeks(payload, out weeks))
            {
                message = "Choose 4, 8 or 12 weeks.";
                return false;
            }
            spaceWarningWeeks = weeks;
            DashboardSpaceWarningStore.TrySave(weeks);
            SourceConfiguration configuration = currentSourceConfiguration;
            message = SpaceWarningAnswer(
                weeks,
                configuration != null && IsGoogleDriveStorage(configuration.RepositoryStorageMode));
            PublishWebPresentationState();
            return true;
        }

        internal static string SpaceWarningAnswer(int weeks, bool googleDrive)
        {
            return "Rewindle will warn you " + weeks.ToString(CultureInfo.InvariantCulture) + " weeks before " +
                (googleDrive ? "your Google storage is full." : "the backup drive is full.");
        }

        private static bool IsGoogleDriveStorage(string storageMode)
        {
            return string.Equals(storageMode, "google_drivefs_stream", StringComparison.Ordinal);
        }

        // "D:" for a path on a drive letter, otherwise empty.
        internal static string DriveLetterOf(string path)
        {
            try
            {
                string root = Path.GetPathRoot(path ?? string.Empty);
                if (root != null && root.Length >= 2 && root[1] == ':' && char.IsLetter(root[0]))
                {
                    return char.ToUpperInvariant(root[0]).ToString() + ":";
                }
            }
            catch (ArgumentException)
            {
            }
            return string.Empty;
        }

        // state.repository.space, or null with no backup plan in use.
        private Dictionary<string, object> BuildWebSpaceState()
        {
            SourceConfiguration configuration = currentSourceConfiguration;
            if (configuration == null)
            {
                return null;
            }
            TelemetrySnapshot snapshot = lastSnapshot;
            bool readable = snapshot != null && string.IsNullOrEmpty(webTelemetryError);
            string path = configuration.RepositoryPath ?? string.Empty;
            bool probed = repositoryVolumeRead &&
                string.Equals(path, repositoryVolumePath, StringComparison.OrdinalIgnoreCase);
            bool valid = repositoryVolumeFreeBytes >= 0 && repositoryVolumeTotalBytes > 0 &&
                repositoryVolumeFreeBytes <= repositoryVolumeTotalBytes;

            BackupSpaceFacts facts = new BackupSpaceFacts();
            facts.Kind = IsGoogleDriveStorage(configuration.RepositoryStorageMode) ? "googleDrive" : "drive";
            facts.Drive = DriveLetterOf(path);
            facts.Reading = !probed ? "checking" : repositoryVolumeReady && valid ? "ready" : "unknown";
            facts.FreeBytes = facts.Reading == "ready" ? repositoryVolumeFreeBytes : -1;
            facts.TotalBytes = facts.Reading == "ready" ? repositoryVolumeTotalBytes : -1;
            facts.ReserveBytes = configuration.MinimumFreeBytes;
            facts.BackupsBytes = readable ? snapshot.BackupsBytes : -1;
            facts.BackupsEstimated = readable && snapshot.BackupsBytesEstimated;
            // The forecast takes away what clean-up of old backups freed; until that is known there is none.
            IList<BackupSpaceCleanUp> cleanUps;
            bool cleanUpsKnown = TryGetRetentionSpaceChanges(out cleanUps);
            facts.HistoryReadable = readable && cleanUpsKnown;
            facts.CleanUps = cleanUps;
            facts.ForecastAvailable = EngineProfile.Current.ForecastsBackupSpace;
            facts.Samples = readable && snapshot.History != null
                ? snapshot.History
                    .Where(run => run != null && run.Success && string.Equals(run.TypeKey, "backup", StringComparison.Ordinal))
                    .Select(run => new BackupSpaceSample(run.FinishedUtc, run.StoredBytes))
                    .ToList()
                : new List<BackupSpaceSample>();
            facts.WarnWeeks = spaceWarningWeeks;
            facts.RunStoppedForSpace = readable && snapshot.IsFailure &&
                string.Equals(snapshot.FailureCode, "repository_low_space", StringComparison.Ordinal);

            BackupSpaceResult result;
            bool runActive = previewEnabled || (readable && snapshot.IsActive);
            if (runActive)
            {
                BackupSpaceResult beforeRun = null;
                if (idleSpaceFacts != null && string.Equals(idleSpacePath, path, StringComparison.OrdinalIgnoreCase))
                {
                    // Judged again with the Low space warning in use now, so a choice made during the run shows at once.
                    idleSpaceFacts.WarnWeeks = spaceWarningWeeks;
                    beforeRun = BackupSpaceEvaluator.Evaluate(idleSpaceFacts);
                }
                result = BackupSpaceEvaluator.HoldDuringRun(beforeRun, facts);
            }
            else
            {
                result = BackupSpaceEvaluator.Evaluate(facts);
                if (facts.Reading != "checking")
                {
                    idleSpaceFacts = facts;
                    idleSpacePath = path;
                }
            }
            return SerializeWebSpaceState(facts, result);
        }

        // The page's shape (native-types.ts BackupSpaceState). Static, so the regressions can call it on the built dashboard. A byte count
        // that is unknown is -1 with an empty display.
        internal static Dictionary<string, object> SerializeWebSpaceState(BackupSpaceFacts facts, BackupSpaceResult result)
        {
            BackupSpaceFacts known = facts ?? new BackupSpaceFacts();
            BackupSpaceResult judged = result ?? new BackupSpaceResult();
            Dictionary<string, object> space = new Dictionary<string, object>();
            space["kind"] = known.Kind == "googleDrive" ? "googleDrive" : "drive";
            space["reading"] = known.Reading == "ready" || known.Reading == "unknown" ? known.Reading : "checking";
            space["drive"] = known.Drive ?? string.Empty;
            AddWebBytes(space, "free", known.FreeBytes);
            AddWebBytes(space, "total", known.TotalBytes);
            AddWebBytes(space, "backups", known.BackupsBytes);
            space["backupsEstimated"] = known.BackupsBytes >= 0 && known.BackupsEstimated;
            AddWebBytes(space, "reserve", known.ReserveBytes);
            Dictionary<string, object> forecast = new Dictionary<string, object>();
            forecast["state"] = ForecastStateName(judged.ForecastState);
            forecast["weeksLeft"] = judged.WeeksLeft.HasValue ? (object)judged.WeeksLeft.Value : null;
            forecast["weeksRounded"] = judged.WeeksRounded.HasValue ? (object)judged.WeeksRounded.Value : null;
            AddWebBytes(forecast, "weekly", judged.WeeklyBytes);
            // "counted": what clean-up of old backups freed was taken away; "unmeasured": it freed space nobody measured, so there is
            // no forecast yet; empty otherwise.
            forecast["cleanUp"] = CleanUpEffectName(judged.CleanUp);
            space["forecast"] = forecast;
            space["level"] = LevelName(judged.Level);
            space["reason"] = ReasonName(judged.Reason);
            space["warnWeeks"] = BackupSpaceEvaluator.IsAllowedWarnWeeks(known.WarnWeeks)
                ? known.WarnWeeks
                : BackupSpaceEvaluator.DefaultWarnWeeks;
            space["runStoppedForSpace"] = known.RunStoppedForSpace;
            return space;
        }

        private static void AddWebBytes(Dictionary<string, object> target, string name, long bytes)
        {
            long value = bytes < 0 ? -1 : bytes;
            target[name + "Bytes"] = value;
            target[name + "Display"] = value < 0 ? string.Empty : TelemetryFormat.FormatBytes(value);
        }

        private static string LevelName(BackupSpaceLevel level)
        {
            switch (level)
            {
                case BackupSpaceLevel.Ok: return "ok";
                case BackupSpaceLevel.Low: return "low";
                case BackupSpaceLevel.Full: return "full";
                default: return "unknown";
            }
        }

        private static string ReasonName(BackupSpaceReason reason)
        {
            switch (reason)
            {
                case BackupSpaceReason.Forecast: return "forecast";
                case BackupSpaceReason.Percent: return "percent";
                case BackupSpaceReason.Reserve: return "reserve";
                default: return string.Empty;
            }
        }

        private static string CleanUpEffectName(BackupSpaceCleanUpEffect effect)
        {
            switch (effect)
            {
                case BackupSpaceCleanUpEffect.Counted: return "counted";
                case BackupSpaceCleanUpEffect.Unmeasured: return "unmeasured";
                default: return string.Empty;
            }
        }

        private static string ForecastStateName(BackupSpaceForecastState state)
        {
            switch (state)
            {
                case BackupSpaceForecastState.Learning: return "learning";
                case BackupSpaceForecastState.Flat: return "flat";
                case BackupSpaceForecastState.Growing: return "growing";
                case BackupSpaceForecastState.Unavailable: return "unavailable";
                default: return "unknown";
            }
        }
    }
}
