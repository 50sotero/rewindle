using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    public static class TelemetryFormat
    {
        public static string FormatBytes(long bytes)
        {
            if (bytes < 0)
            {
                return "\u2014";
            }

            string[] units = new string[] { "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
            double value = bytes;
            int unit = 0;
            while (value >= 1024.0 && unit < units.Length - 1)
            {
                value /= 1024.0;
                unit++;
            }

            if (unit == 0)
            {
                return bytes.ToString("N0", CultureInfo.CurrentCulture) + " " + units[unit];
            }

            string format = value >= 100.0 ? "0" : (value >= 10.0 ? "0.0" : "0.00");
            return value.ToString(format, CultureInfo.CurrentCulture) + " " + units[unit];
        }

        public static string FormatDuration(TimeSpan duration)
        {
            if (duration < TimeSpan.Zero)
            {
                return "\u2014";
            }
            if (duration.TotalDays >= 1.0)
            {
                return ((int)duration.TotalDays).ToString(CultureInfo.CurrentCulture)
                    + "d " + duration.Hours.ToString(CultureInfo.CurrentCulture) + "h";
            }
            if (duration.TotalHours >= 1.0)
            {
                return ((int)duration.TotalHours).ToString(CultureInfo.CurrentCulture)
                    + "h " + duration.Minutes.ToString("00", CultureInfo.CurrentCulture) + "m";
            }
            if (duration.TotalMinutes >= 1.0)
            {
                return ((int)duration.TotalMinutes).ToString(CultureInfo.CurrentCulture)
                    + "m " + duration.Seconds.ToString("00", CultureInfo.CurrentCulture) + "s";
            }
            return Math.Max(0, (int)Math.Round(duration.TotalSeconds))
                .ToString(CultureInfo.CurrentCulture) + "s";
        }

        public static string FormatCount(long count)
        {
            return count < 0 ? "\u2014" : count.ToString("N0", CultureInfo.CurrentCulture);
        }
    }

    public sealed class RunMetricView
    {
        public DateTime StartedLocal { get; set; }
        public string RunId { get; set; }
        public string TypeLabel { get; set; }
        public string StateLabel { get; set; }
        public bool Success { get; set; }
        public double DurationSeconds { get; set; }
        public long Files { get; set; }
        public long ProcessedBytes { get; set; }
        public long StoredBytes { get; set; }
        public string SnapshotShort { get; set; }

        // The year appears once a run is from an earlier year, so a history that spans years stays
        // unambiguous without lengthening every recent date.
        public string StartedDisplay
        {
            get
            {
                string pattern = StartedLocal.Year == DateTime.Now.Year
                    ? "ddd, d MMM HH:mm"
                    : "ddd, d MMM yyyy HH:mm";
                return StartedLocal.ToString(pattern, CultureInfo.CurrentCulture);
            }
        }

        public string DurationDisplay
        {
            get { return TelemetryFormat.FormatDuration(TimeSpan.FromSeconds(Math.Max(0, DurationSeconds))); }
        }

        public string FilesDisplay
        {
            get { return TelemetryFormat.FormatCount(Files); }
        }

        public string ProcessedBytesDisplay
        {
            get { return TelemetryFormat.FormatBytes(ProcessedBytes); }
        }

        public string ProcessedDisplay
        {
            get { return ProcessedBytesDisplay; }
        }

        public string StoredBytesDisplay
        {
            get { return TelemetryFormat.FormatBytes(StoredBytes); }
        }

        public string SnapshotDisplay
        {
            get { return string.IsNullOrEmpty(SnapshotShort) ? "\u2014" : SnapshotShort; }
        }

        public string OutcomeDisplay
        {
            get { return Success ? "Successful" : "Needs attention"; }
        }

        public string SummaryDisplay
        {
            get
            {
                return TelemetryFormat.FormatCount(Files) + " files \u2022 "
                    + TelemetryFormat.FormatBytes(ProcessedBytes) + " \u2022 "
                    + DurationDisplay;
            }
        }
    }

    public sealed class TelemetrySnapshot
    {
        public string StateKey { get; set; }
        public string StatusLabel { get; set; }
        public string StatusDetail { get; set; }
        public bool IsActive { get; set; }
        public bool IsFailure { get; set; }
        // There is no readable status to describe: the state folder is missing or refuses access, or status.json cannot be used
        // right now (see TelemetryReader.BuildTelemetryError). That says nothing about a backup, so it is not a failure and not a
        // success either. Whatever would take "not running, not failed, not verified" for a plan that is ready checks this first.
        public bool IsStatusUnavailable { get; set; }
        public bool IsSuccess { get; set; }
        public bool IsCancelled { get; set; }
        public bool HasMaintenanceHold { get; set; }
        public bool AnomalyReviewAcknowledged { get; set; }
        public bool NeedsAnomalyReview
        {
            get { return HasMaintenanceHold && !AnomalyReviewAcknowledged; }
        }
        public string MaintenanceHoldDetail { get; set; }
        public string CancelOutcome { get; set; }
        public double Percent { get; set; }
        public bool ProgressIsEstimated { get; set; }
        public string ConfidenceLabel { get; set; }
        public long FilesDone { get; set; }
        public long EstimatedFiles { get; set; }
        public long BytesDone { get; set; }
        public long EstimatedBytes { get; set; }
        public long StoredBytes { get; set; }
        public double TransferRateBytesPerSecond { get; set; }
        public TimeSpan Elapsed { get; set; }
        public TimeSpan? Eta { get; set; }
        public DateTime? EstimatedCompletion { get; set; }
        public int ErrorCount { get; set; }
        public int PhaseIndex { get; set; }
        public string PhaseLabel { get; set; }
        public DateTime LastUpdatedLocal { get; set; }
        public DateTime? LastVerifiedFinishedUtc { get; set; }
        public string RunId { get; set; }
        public string SnapshotId { get; set; }
        public OffsiteStatusView OffsiteStatus { get; set; }
        public IList<RunMetricView> History { get; set; }
        // The local history file is intentionally bounded for predictable load
        // time. Surface whether that bound actually discarded older entries so
        // the dashboard can explain the visible window without implying that a
        // small history is incomplete.
        public bool HistoryTruncated { get; set; }

        public TelemetrySnapshot()
        {
            StateKey = "unknown";
            StatusLabel = "Checking backup status";
            StatusDetail = "Waiting for telemetry.";
            ConfidenceLabel = "Waiting for data";
            PhaseIndex = -1;
            PhaseLabel = "Waiting";
            RunId = string.Empty;
            SnapshotId = string.Empty;
            CancelOutcome = string.Empty;
            MaintenanceHoldDetail = string.Empty;
            OffsiteStatus = new OffsiteStatusView();
            History = new List<RunMetricView>();
            HistoryTruncated = false;
        }
    }

    public enum OffsiteStatusKind
    {
        NotConfigured,
        StatusUnavailable,
        Failed,
        InProgress,
        LocalVerifiedProviderPending,
        ProviderConfirmed,
        RestoreVerified
    }

    public sealed class OffsiteStatusView
    {
        public OffsiteStatusKind Kind { get; internal set; }
        public string StatusLabel { get; internal set; }
        public string StatusDetail { get; internal set; }
        public string PlanId { get; internal set; }
        public long ConfigGeneration { get; internal set; }
        public string RepositoryId { get; internal set; }
        public string RepositoryPath { get; internal set; }
        public string SnapshotId { get; internal set; }
        public string InventoryFingerprintSha256 { get; internal set; }
        public long FileCount { get; internal set; }
        public long ByteCount { get; internal set; }
        public DateTime? LastUpdatedLocal { get; internal set; }
        public bool ProviderUploadConfirmed { get; internal set; }
        public bool RestoreVerified { get; internal set; }
        // The provider the off-site evidence comes from ("Google Drive" for a direct My Drive proof), or empty when no
        // evidence names one. The page names a provider only when this does.
        public string ProviderLabel { get; internal set; }

        public string SnapshotShort
        {
            get
            {
                return string.IsNullOrEmpty(SnapshotId)
                    ? string.Empty
                    : SnapshotId.Substring(0, Math.Min(8, SnapshotId.Length));
            }
        }

        public OffsiteStatusView()
        {
            Kind = OffsiteStatusKind.NotConfigured;
            StatusLabel = "Cloud verification not configured";
            // Said for every backup, so it names no provider: most have no cloud copy at all, and one that does says which
            // it is in its own evidence.
            StatusDetail = "No cloud verification has been recorded for this backup.";
            PlanId = string.Empty;
            ConfigGeneration = -1;
            RepositoryId = string.Empty;
            RepositoryPath = string.Empty;
            SnapshotId = string.Empty;
            InventoryFingerprintSha256 = string.Empty;
            FileCount = -1;
            ByteCount = -1;
            ProviderLabel = string.Empty;
        }
    }

    public sealed class TelemetryReader
    {
        private const int MaximumJsonLength = 32 * 1024 * 1024;
        private const int MaximumOffsiteJsonLength = 1024 * 1024;
        private const int MaximumHistoryRuns = 400;
        // How many runs the history keeps, read-only, for the page to name (the dashboard sends it with the state).
        public const int HistoryLimit = MaximumHistoryRuns;
        private const double MaximumEtaSeconds = 14.0 * 24.0 * 60.0 * 60.0;
        private const double MissingProcessGraceSeconds = 120.0;
        private const double MaximumActiveStatusAgeSeconds = 24.0 * 60.0 * 60.0;
        private const string DirectCloudProofKind =
            "direct_my_drive_cloud_repository_verification";
        private const string DirectCloudVerificationMode =
            "google_drive_api_readonly_rclone_backend";
        private const string PostActivationVerificationPhase = "post_activation";
        private const string DriveFsStorageMode = "google_drivefs_stream";
        private const string BinaryStreamCaptureMode = "binary_stream_copy";
        // The provider a direct My Drive proof is evidence from: the DriveFS stream is Google Drive for desktop.
        private const string DriveFsProviderLabel = "Google Drive";
        // How long the last good reading of status.json may stand in for a read that cannot be used (see KeepStatusThroughGlitch).
        private const double StatusGlitchGraceSeconds = 10.0;
        // How many refreshes a run history that exists but cannot be read is given before it is set aside (see
        // EnsureLocalCacheLoaded). The dashboard refreshes about once a second.
        private const int MaximumHistoryLoadAttempts = 6;
        private const string LegacyEvidenceRetiredDetail =
            "Legacy local-mirror evidence is retired and cannot prove the streamed Google Drive repository is available in the cloud.";

        private readonly string stateDirectory;
        private readonly string statusPath;
        private readonly string dryRunLatestPath;
        private readonly string lastSuccessPath;
        private readonly string anomalyAcknowledgementPath;
        private readonly string protectedOffsiteStatusPath;
        private readonly string directCloudVerificationPath;
        private readonly string legacyLocalOffsiteStatusPath;
        private readonly bool allowPersistence;
        private readonly string dashboardDirectory;
        private readonly string historyPath;
        private readonly JavaScriptSerializer serializer;
        private readonly object syncRoot = new object();

        private bool persistenceReady;
        private bool localCacheLoaded;
        private bool historyTruncated;
        private List<RunMetricRecord> historyRecords = new List<RunMetricRecord>();
        // run-history.json exists but could not be read yet. Nothing is written over it until that is settled; a write that was held
        // back for that reason is made as soon as it is.
        private bool historyLoadPending;
        private bool historyWriteDeferred;
        private int historyLoadAttempts;
        // run-history.json is not this build's to rewrite (a newer build wrote it, or it could not be set aside): it is read,
        // never written, for as long as this process runs.
        private bool historyReadOnly;
        // Records of kinds this build does not draw (a newer build's, say), exactly as they were read. They are written back
        // unchanged, so rewriting the history does not delete them, and they are never shown.
        private List<IDictionary<string, object>> preservedHistoryRecords = new List<IDictionary<string, object>>();
        // The last status.json that was read and understood, and when (a monotonic clock, so that a change of the system clock
        // cannot stretch or shorten the grace it is kept for).
        private JsonReadResult lastGoodStatus;
        private long lastGoodStatusTimestamp;

        public TelemetryReader(string stateDirectory, bool allowPersistence)
            : this(stateDirectory, allowPersistence, null)
        {
        }

        internal TelemetryReader(
            string stateDirectory,
            bool allowPersistence,
            string localOffsiteStatusPathOverride)
        {
            if (string.IsNullOrWhiteSpace(stateDirectory))
            {
                throw new ArgumentException("A protected state directory is required.", "stateDirectory");
            }
            if (!Path.IsPathRooted(stateDirectory))
            {
                throw new ArgumentException("The protected state directory must be absolute.", "stateDirectory");
            }

            this.stateDirectory = TrimTrailingSeparators(Path.GetFullPath(stateDirectory));
            this.statusPath = Path.Combine(this.stateDirectory, "status.json");
            this.dryRunLatestPath = Path.Combine(this.stateDirectory, "dry-run-latest.json");
            this.lastSuccessPath = Path.Combine(this.stateDirectory, "last-success.json");
            this.anomalyAcknowledgementPath = Path.Combine(
                this.stateDirectory,
                "anomaly-acknowledgement.json");
            this.protectedOffsiteStatusPath = Path.Combine(
                this.stateDirectory,
                "google-drive-sync-status.json");
            this.allowPersistence = allowPersistence;

            if (!string.IsNullOrWhiteSpace(localOffsiteStatusPathOverride)
                && !Path.IsPathRooted(localOffsiteStatusPathOverride))
            {
                throw new ArgumentException(
                    "The off-site status override must be absolute.",
                    "localOffsiteStatusPathOverride");
            }
            // The active engine's protected direct-cloud proof, its retired per-user mirror status and the
            // dashboard's own folder (each empty when its Windows folder cannot be located).
            this.directCloudVerificationPath =
                !string.IsNullOrWhiteSpace(localOffsiteStatusPathOverride)
                    ? Path.GetFullPath(localOffsiteStatusPathOverride)
                    : EngineProfile.Current.CloudVerificationProofPath();
            this.legacyLocalOffsiteStatusPath = EngineProfile.Current.LegacyLocalSyncStatusPath();
            this.dashboardDirectory = EngineProfile.Current.DashboardDataDirectory();
            this.historyPath = string.IsNullOrEmpty(this.dashboardDirectory)
                ? string.Empty
                : Path.Combine(this.dashboardDirectory, "run-history.json");

            this.serializer = new JavaScriptSerializer();
            this.serializer.MaxJsonLength = MaximumJsonLength;
            this.serializer.RecursionLimit = 100;

            if (allowPersistence)
            {
                InitializePersistenceDirectory();
            }
        }

        public TelemetrySnapshot Load()
        {
            lock (syncRoot)
            {
                EnsureLocalCacheLoaded();

                JsonReadResult statusRead = KeepStatusThroughGlitch(ReadJsonObject(statusPath));
                JsonReadResult dryRunRead = ReadJsonObject(dryRunLatestPath);
                JsonReadResult lastSuccessRead = ReadJsonObject(lastSuccessPath);
                JsonReadResult anomalyAcknowledgementRead = ReadJsonObject(
                    anomalyAcknowledgementPath);
                JsonReadResult offsiteStatusRead = ReadPreferredOffsiteStatus();
                bool historyChanged = false;

                if (dryRunRead.Document != null)
                {
                    RunMetricRecord dryMetric = CreateDryRunMetric(dryRunRead.Document);
                    if (dryMetric != null)
                    {
                        historyChanged |= UpsertMetric(dryMetric);
                    }
                }
                if (statusRead.Document != null)
                {
                    RunMetricRecord backupMetric = CreateBackupMetric(statusRead.Document);
                    if (backupMetric != null)
                    {
                        historyChanged |= UpsertMetric(backupMetric);
                    }
                }

                TelemetrySnapshot snapshot = BuildSnapshot(statusRead, dryRunRead);
                snapshot.OffsiteStatus = BuildOffsiteStatus(
                    offsiteStatusRead,
                    statusRead.Document,
                    lastSuccessRead.Document);
                ApplyAnomalyAcknowledgement(
                    snapshot,
                    statusRead.Document,
                    lastSuccessRead,
                    anomalyAcknowledgementRead.Document);
                DateTime lastVerifiedFinishedUtc;
                snapshot.LastVerifiedFinishedUtc = TryReadLastVerifiedFinishedUtc(
                    lastSuccessRead.Document,
                    out lastVerifiedFinishedUtc)
                    ? lastVerifiedFinishedUtc
                    : (DateTime?)null;
                snapshot.History = BuildHistoryViews();
                snapshot.HistoryTruncated = historyTruncated;

                if (historyChanged || historyWriteDeferred)
                {
                    TryPersistHistory();
                }

                return snapshot;
            }
        }

        public string SelfTestJson()
        {
            lock (syncRoot)
            {
                JsonReadResult statusRead = ReadJsonObject(statusPath);
                JsonReadResult dryRunRead = ReadJsonObject(dryRunLatestPath);
                JsonReadResult lastSuccessRead = ReadJsonObject(lastSuccessPath);
                JsonReadResult anomalyAcknowledgementRead = ReadJsonObject(
                    anomalyAcknowledgementPath);
                JsonReadResult offsiteStatusRead = ReadPreferredOffsiteStatus();
                JsonReadResult historyRead = string.IsNullOrEmpty(historyPath)
                    ? JsonReadResult.Missing()
                    : ReadJsonObject(historyPath);

                bool protectedTelemetryAvailable = statusRead.Document != null
                    || dryRunRead.Document != null
                    || lastSuccessRead.Document != null;
                DateTime lastVerifiedFinishedUtc;
                bool lastSuccessSemanticallyValid = TryReadLastVerifiedFinishedUtc(
                    lastSuccessRead.Document,
                    out lastVerifiedFinishedUtc);
                bool protectedTelemetryValid = (!statusRead.Exists || statusRead.Document != null)
                    && (!dryRunRead.Exists || dryRunRead.Document != null)
                    && (!lastSuccessRead.Exists || lastSuccessSemanticallyValid);

                Dictionary<string, object> result = new Dictionary<string, object>();
                result["schema_version"] = 2;
                result["ok"] = Directory.Exists(stateDirectory)
                    && protectedTelemetryAvailable
                    && protectedTelemetryValid;
                result["checked_utc"] = FormatUtc(DateTime.UtcNow);
                result["state_directory"] = stateDirectory;
                result["state_directory_exists"] = Directory.Exists(stateDirectory);
                result["allowed_protected_files"] = new string[] {
                    "status.json", "dry-run-latest.json", "last-success.json",
                    "anomaly-acknowledgement.json", "google-drive-sync-status.json"
                };
                result["status"] = SelfTestFileResult(statusRead);
                result["dry_run_latest"] = SelfTestFileResult(dryRunRead);
                Dictionary<string, object> lastSuccessResult = SelfTestFileResult(lastSuccessRead);
                lastSuccessResult["verified_success_record"] = lastSuccessSemanticallyValid;
                lastSuccessResult["verified_finished_utc"] = lastSuccessSemanticallyValid
                    ? FormatUtc(lastVerifiedFinishedUtc)
                    : null;
                result["last_success"] = lastSuccessResult;
                result["anomaly_acknowledgement"] = SelfTestFileResult(
                    anomalyAcknowledgementRead);
                result["offsite_status"] = SelfTestFileResult(offsiteStatusRead);
                OffsiteStatusView offsite = BuildOffsiteStatus(
                    offsiteStatusRead,
                    statusRead.Document,
                    lastSuccessRead.Document);
                result["offsite_model"] = new Dictionary<string, object>
                {
                    { "kind", offsite.Kind.ToString() },
                    { "provider_upload_confirmed", offsite.ProviderUploadConfirmed },
                    { "restore_verified", offsite.RestoreVerified },
                    { "plan_id", offsite.PlanId },
                    { "config_generation", offsite.ConfigGeneration },
                    { "repository_id", offsite.RepositoryId },
                    { "repository_path", offsite.RepositoryPath },
                    { "snapshot_id", offsite.SnapshotId },
                    { "inventory_fingerprint_sha256", offsite.InventoryFingerprintSha256 },
                    { "files", offsite.FileCount },
                    { "bytes", offsite.ByteCount }
                };
                result["local_history"] = SelfTestFileResult(historyRead);
                result["persistence_configured"] = allowPersistence;
                result["self_test_write_operations"] = 0;
                result["restic_invocations"] = 0;
                result["secret_reads"] = 0;
                return serializer.Serialize(result);
            }
        }

        private Dictionary<string, object> SelfTestFileResult(JsonReadResult read)
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["exists"] = read.Exists;
            result["valid_json_object"] = read.Document != null;
            result["bytes"] = read.Length;
            result["error"] = string.IsNullOrEmpty(read.Error) ? null : read.Error;
            return result;
        }

        private void InitializePersistenceDirectory()
        {
            persistenceReady = false;
            if (string.IsNullOrEmpty(dashboardDirectory))
            {
                return;
            }
            if (PathsOverlap(dashboardDirectory, stateDirectory))
            {
                return;
            }

            try
            {
                Directory.CreateDirectory(dashboardDirectory);
                FileAttributes attributes = File.GetAttributes(dashboardDirectory);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    return;
                }
                persistenceReady = true;
            }
            catch (Exception error)
            {
                if (!IsExpectedIoException(error))
                {
                    throw;
                }
            }
        }

        private void EnsureLocalCacheLoaded()
        {
            if (localCacheLoaded)
            {
                return;
            }
            localCacheLoaded = true;

            if (string.IsNullOrEmpty(dashboardDirectory) || !Directory.Exists(dashboardDirectory))
            {
                return;
            }
            try
            {
                if ((File.GetAttributes(dashboardDirectory) & FileAttributes.ReparsePoint) != 0)
                {
                    return;
                }
            }
            catch (Exception error)
            {
                if (IsExpectedIoException(error))
                {
                    return;
                }
                throw;
            }

            JsonReadResult historyRead = ReadJsonObject(historyPath);
            if (historyRead.Exists && historyRead.Document == null)
            {
                // A history is there but cannot be read just now: another program holds it for longer than a read waits, or a
                // writer left it cut short. Starting over would replace what it holds, so nothing is written until this is
                // settled. It is read again on the next refreshes, and only a file that stays unreadable is set aside.
                historyLoadAttempts++;
                if (historyLoadAttempts < MaximumHistoryLoadAttempts)
                {
                    historyLoadPending = true;
                    localCacheLoaded = false;
                    return;
                }
                historyLoadPending = false;
                historyReadOnly = !TrySetUnreadableHistoryAside();
            }
            else
            {
                historyLoadPending = false;
                if (historyRead.Document != null)
                {
                    historyRecords = ParseHistory(historyRead.Document);
                    // Only a history this build wrote (schema 1) is rewritten. A newer build's is read for what it can tell
                    // and left exactly as it is.
                    historyReadOnly = GetLong(historyRead.Document, "schema_version", -1) != 1;
                }
            }

            TryRemoveRetiredLiveSamples();
        }

        // A history that stays unreadable is kept, not overwritten: it is moved, under a name nothing else has, beside where the
        // new one will be written. Only a plain file in the dashboard's own folder is moved (never a link, and never over
        // anything, since File.Move refuses an existing target). True when nothing is in the way any more; false when it could
        // not be moved, and then nothing is written for as long as this process runs.
        private bool TrySetUnreadableHistoryAside()
        {
            if (!persistenceReady || string.IsNullOrEmpty(historyPath))
            {
                return false;
            }
            try
            {
                string parent = TrimTrailingSeparators(Path.GetDirectoryName(Path.GetFullPath(historyPath)));
                if (!string.Equals(parent, TrimTrailingSeparators(dashboardDirectory), StringComparison.OrdinalIgnoreCase)
                    || (File.GetAttributes(dashboardDirectory) & FileAttributes.ReparsePoint) != 0)
                {
                    return false;
                }
                FileAttributes attributes = File.GetAttributes(historyPath);
                if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                {
                    return false;
                }
                File.Move(
                    historyPath,
                    historyPath + ".corrupt-"
                        + DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture)
                        + "-" + Guid.NewGuid().ToString("N"));
                return true;
            }
            catch (FileNotFoundException)
            {
                return true;
            }
            catch (DirectoryNotFoundException)
            {
                return true;
            }
            catch (Exception error)
            {
                if (!IsExpectedIoException(error))
                {
                    throw;
                }
                return false;
            }
        }

        // status.json is replaced by every run, and a read can land on a moment when it cannot be used: the writer has it open, a
        // scanner holds it, a half-written copy is still being swapped for the real one. The last good reading stands in for such a
        // gap for a few seconds, so a one-second glitch is neither shown nor announced as a problem. It never outlives the gap: every
        // good read replaces it (a new run is never described by an old run's reading), a file that is gone clears it, and what a
        // gap of any length is reported as is BuildSnapshot's to say. Refusals (a link, a size limit, a permission) are not glitches.
        private JsonReadResult KeepStatusThroughGlitch(JsonReadResult read)
        {
            long now = Stopwatch.GetTimestamp();
            if (read.Document != null)
            {
                lastGoodStatus = read;
                lastGoodStatusTimestamp = now;
                return read;
            }
            if (!read.Exists)
            {
                lastGoodStatus = null;
                return read;
            }
            if (lastGoodStatus != null
                && read.IsTransient
                && (now - lastGoodStatusTimestamp) < (long)(StatusGlitchGraceSeconds * Stopwatch.Frequency))
            {
                return lastGoodStatus;
            }
            return read;
        }

        // Earlier versions kept a sample of every run in live-samples.json, rewritten and flushed to disk every ten
        // seconds while a backup ran, and nothing ever read it back. What they left behind (up to a few megabytes) is
        // removed here, once per start. Only that one name in the dashboard's own folder, and only a plain file: never
        // a link, a folder, or anything outside it. Without persistence nothing on disk is touched.
        private void TryRemoveRetiredLiveSamples()
        {
            if (!persistenceReady)
            {
                return;
            }
            try
            {
                string path = Path.Combine(dashboardDirectory, "live-samples.json");
                FileAttributes attributes = File.GetAttributes(path);
                if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                {
                    return;
                }
                File.Delete(path);
            }
            catch (Exception error)
            {
                // Not there is the usual answer; a file that is in use or cannot be deleted is left for the next start.
                if (!IsExpectedIoException(error))
                {
                    throw;
                }
            }
        }

        private TelemetrySnapshot BuildSnapshot(
            JsonReadResult statusRead,
            JsonReadResult dryRunRead)
        {
            if (statusRead.Document != null)
            {
                return BuildBackupSnapshot(statusRead.Document, statusRead.LastWriteUtc);
            }
            if (statusRead.Exists)
            {
                return BuildUnreadableSnapshot("status.json", statusRead);
            }
            if (dryRunRead.Document != null)
            {
                return BuildDryRunSnapshot(dryRunRead.Document, dryRunRead.LastWriteUtc);
            }
            if (dryRunRead.Exists)
            {
                return BuildUnreadableSnapshot("dry-run-latest.json", dryRunRead);
            }
            if (StateFolderMissing())
            {
                // Neither file is there because the folder they belong in is not: nothing is installed to report on, which is
                // not the same as an installation that has not made its first backup yet.
                return BuildTelemetryError(
                    "not_installed",
                    "Engine not installed",
                    "Rewindle reads backup status from " + stateDirectory + ", and that folder does not exist. Install or "
                        + "repair the backup engine, or start Rewindle with --state-dir to read another folder (see "
                        + "Requirements in the README).",
                    DateTime.MinValue);
            }

            TelemetrySnapshot waiting = new TelemetrySnapshot();
            waiting.StateKey = "waiting";
            waiting.StatusLabel = "Waiting for the first backup";
            waiting.StatusDetail = "No backup status or verified dry-run baseline exists yet.";
            waiting.PhaseLabel = "Ready";
            waiting.LastUpdatedLocal = DateTime.Now;
            waiting.ProgressIsEstimated = true;
            return waiting;
        }

        // True when the state folder itself is not there. Asked of the folder, not with Directory.Exists, which says false for a
        // folder it may not look at as well: a folder that refuses access shows up as a refused file (see BuildUnreadableSnapshot),
        // and only a folder that is really missing means nothing is installed. Read-only, and nothing is created.
        private bool StateFolderMissing()
        {
            try
            {
                return (File.GetAttributes(stateDirectory) & FileAttributes.Directory) == 0;
            }
            catch (FileNotFoundException)
            {
                return true;
            }
            catch (DirectoryNotFoundException)
            {
                return true;
            }
            catch (Exception error)
            {
                if (!IsExpectedIoException(error))
                {
                    throw;
                }
                return false;
            }
        }

        // A protected file that is there and cannot be used: a state of its own, not a backup that failed. A refusal by Windows
        // gets its own key, because it is fixed by changing who may read the folder and not by waiting.
        private TelemetrySnapshot BuildUnreadableSnapshot(string fileName, JsonReadResult read)
        {
            bool denied = string.Equals(read.Reason, JsonReadResult.ReasonAccessDenied, StringComparison.Ordinal);
            return BuildTelemetryError(
                denied ? "access_denied" : "telemetry_error",
                "Backup status unavailable",
                DescribeUnreadable(fileName, read),
                read.LastWriteUtc);
        }

        // Why a file could not be read, as one fixed sentence. It names the file and never the exception's own words, which can
        // quote a path or a fragment of the file.
        private static string DescribeUnreadable(string fileName, JsonReadResult read)
        {
            switch (read.Reason)
            {
                case JsonReadResult.ReasonLocked:
                    return fileName + " is in use by another program, so Rewindle cannot read it yet. It tries again every second.";
                case JsonReadResult.ReasonChanging:
                    return fileName + " was still being written when Rewindle read it. It tries again every second.";
                case JsonReadResult.ReasonInvalid:
                    return fileName + " is not valid JSON, so Rewindle cannot read it. The next run rewrites it.";
                case JsonReadResult.ReasonTooLarge:
                    return fileName + " is larger than Rewindle's size limit, so it was not read.";
                case JsonReadResult.ReasonLink:
                    return fileName + " is a link, which Rewindle does not follow, so it was not read.";
                case JsonReadResult.ReasonAccessDenied:
                    return "Windows did not let Rewindle read " + fileName + " (access denied). Check that your Windows "
                        + "account can read the backup's state folder.";
                default:
                    return fileName + " could not be read right now. Rewindle tries again every second.";
            }
        }

        private JsonReadResult ReadPreferredOffsiteStatus()
        {
            JsonReadResult directCloudProof = ReadJsonObject(
                directCloudVerificationPath,
                MaximumOffsiteJsonLength);
            if (directCloudProof.Exists)
            {
                return directCloudProof;
            }

            JsonReadResult protectedStatus = ReadJsonObject(
                protectedOffsiteStatusPath,
                MaximumOffsiteJsonLength);
            if (protectedStatus.Exists)
            {
                return protectedStatus;
            }
            // The old local-mirror status file lives under the user's own profile, where anything running as this user can write
            // it, and the values a proof is checked against (plan, generation, repository, snapshot) are all readable by the
            // same user. It is retired evidence and no longer stands for protection: it is noticed, never interpreted, so a
            // file left over from an old build (or put there by something else) reads as "needs a direct verification" and can
            // not turn the Off-site copy card green.
            if (PlainFileExists(legacyLocalOffsiteStatusPath))
            {
                return JsonReadResult.Invalid(
                    true,
                    0,
                    DateTime.MinValue,
                    LegacyEvidenceRetiredDetail,
                    JsonReadResult.ReasonRetired);
            }
            return JsonReadResult.Missing();
        }

        // Whether there is something at the path, without opening it. Read-only.
        private static bool PlainFileExists(string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                return false;
            }
            try
            {
                return (File.GetAttributes(path) & FileAttributes.Directory) == 0;
            }
            catch (FileNotFoundException)
            {
                return false;
            }
            catch (DirectoryNotFoundException)
            {
                return false;
            }
            catch (Exception error)
            {
                if (!IsExpectedIoException(error))
                {
                    throw;
                }
                // Something is there that cannot be looked at: it is still not a place proof is taken from.
                return error is UnauthorizedAccessException;
            }
        }

        private OffsiteStatusView BuildOffsiteStatus(
            JsonReadResult read,
            IDictionary<string, object> currentStatus,
            IDictionary<string, object> lastSuccess)
        {
            OffsiteStatusView result = new OffsiteStatusView();
            if (!read.Exists)
            {
                return result;
            }
            if (read.Document == null)
            {
                result.Kind = OffsiteStatusKind.StatusUnavailable;
                if (string.Equals(read.Reason, JsonReadResult.ReasonRetired, StringComparison.Ordinal))
                {
                    // The words an old-format proof has always been given (below), now for the retired local file as well.
                    result.StatusLabel = "Direct cloud verification required";
                    result.StatusDetail = LegacyEvidenceRetiredDetail;
                    return result;
                }
                result.StatusLabel = "Off-site status unavailable";
                result.StatusDetail = CleanOffsiteDetail(read.Error);
                return result;
            }

            IDictionary<string, object> document = read.Document;
            long schemaVersion = GetLong(document, "schema_version", -1);
            string proofKind = GetString(document, "proof_kind", string.Empty);
            if (schemaVersion != 2
                || !string.Equals(
                    proofKind,
                    DirectCloudProofKind,
                    StringComparison.Ordinal))
            {
                result.Kind = OffsiteStatusKind.StatusUnavailable;
                result.StatusLabel = "Direct cloud verification required";
                result.StatusDetail = LegacyEvidenceRetiredDetail;
                return result;
            }
            // From here on the evidence is a direct My Drive proof, whatever it goes on to say, so its provider is known.
            result.ProviderLabel = DriveFsProviderLabel;
            if (!string.Equals(
                    GetString(document, "verification_phase", string.Empty),
                    PostActivationVerificationPhase,
                    StringComparison.Ordinal))
            {
                result.Kind = OffsiteStatusKind.StatusUnavailable;
                result.StatusLabel = "Post-activation cloud verification required";
                result.StatusDetail =
                    "Pre-activation migration evidence is not current off-site protection status.";
                return result;
            }

            string state = GetString(document, "state", string.Empty)
                .Trim()
                .ToLowerInvariant();

            DateTime updatedUtc;
            if (TryGetUtc(document, "verified_utc", out updatedUtc))
            {
                result.LastUpdatedLocal = updatedUtc.ToLocalTime();
            }
            else if (read.LastWriteUtc != DateTime.MinValue)
            {
                result.LastUpdatedLocal = read.LastWriteUtc.ToLocalTime();
            }

            string statusMessage = GetString(document, "message", string.Empty);
            string errorMessage = GetString(document, "error", string.Empty);
            if (state == "failed")
            {
                result.Kind = OffsiteStatusKind.Failed;
                result.StatusLabel = "Direct cloud verification failed";
                result.StatusDetail = CleanOffsiteDetail(
                    string.IsNullOrWhiteSpace(errorMessage)
                        ? statusMessage
                        : errorMessage);
                return result;
            }

            if (state == "starting" || state == "waiting" || state == "copying"
                || state == "verifying" || state == "uploading"
                || state == "committing" || state == "restoring")
            {
                result.Kind = OffsiteStatusKind.InProgress;
                result.StatusLabel = state == "restoring"
                    ? "Direct cloud restore verification in progress"
                    : "Google Drive repository verification in progress";
                result.StatusDetail = CleanOffsiteDetail(statusMessage);
                return result;
            }

            if (state != "verified")
            {
                result.Kind = OffsiteStatusKind.StatusUnavailable;
                result.StatusLabel = "Off-site status unavailable";
                result.StatusDetail =
                    "The direct-cloud proof contains an unrecognized state.";
                return result;
            }

            string verificationMode = GetString(
                document,
                "verification_mode",
                string.Empty);
            string storageMode = GetString(
                document,
                "repository_storage_mode",
                string.Empty);
            string localRepository = CanonicalWindowsPath(
                GetString(document, "local_repository", string.Empty));
            string myDriveRoot = CanonicalWindowsPath(
                GetString(document, "my_drive_root", string.Empty));
            string cloudRootFolderId = GetString(
                document,
                "cloud_root_folder_id",
                string.Empty);
            string cloudRepositoryPath = GetString(
                document,
                "cloud_repository_path",
                string.Empty);
            string planId = CanonicalPlanId(
                GetString(document, "plan_id", string.Empty));
            long configGeneration = -1;
            string repositoryId = CanonicalSnapshotId(
                GetString(document, "repository_id", string.Empty));
            string localRepositoryId = CanonicalSnapshotId(
                GetString(document, "local_repository_id", string.Empty));
            string cloudRepositoryId = CanonicalSnapshotId(
                GetString(document, "cloud_repository_id", string.Empty));
            string snapshotId = CanonicalSnapshotId(
                GetString(document, "snapshot_id", string.Empty));
            string inventoryFingerprint = CanonicalSnapshotId(
                GetString(
                    document,
                    "inventory_fingerprint_sha256",
                    string.Empty));
            string cloudInventoryHash = CanonicalSnapshotId(
                GetString(
                    document,
                    "cloud_inventory_document_sha256",
                    string.Empty));
            string backupConfigHash = CanonicalSnapshotId(
                GetString(document, "backup_config_sha256", string.Empty));
            string canaryHash = CanonicalSnapshotId(
                GetString(document, "canary_sha256", string.Empty));
            string immutableProofHash = CanonicalSnapshotId(
                GetString(document, "immutable_proof_sha256", string.Empty));
            string cloudAssetsManifestHash = CanonicalSnapshotId(
                GetString(
                    document,
                    "cloud_verification_assets_manifest_sha256",
                    string.Empty));
            long files = -1;
            long bytes = -1;
            long missingFiles = -1;
            long extraFiles = -1;
            long mismatchedFiles = -1;
            long cloudObjectsWithIds = -1;
            long canaryBytes = -1;
            bool typedInventory =
                TryGetJsonInteger(document, "config_generation", 1, out configGeneration)
                && TryGetJsonInteger(document, "files", 1, out files)
                && TryGetJsonInteger(document, "bytes", 1, out bytes)
                && TryGetJsonInteger(document, "missing_files", 0, out missingFiles)
                && TryGetJsonInteger(document, "extra_files", 0, out extraFiles)
                && TryGetJsonInteger(document, "mismatched_files", 0, out mismatchedFiles)
                && TryGetJsonInteger(
                    document,
                    "cloud_objects_with_ids",
                    1,
                    out cloudObjectsWithIds)
                && TryGetJsonInteger(document, "canary_bytes", 0, out canaryBytes);
            // The paths are bound to the protected plan, for both engines: the proof's repository must be the repository
            // of the installed backup configuration, the My Drive root it names must be an ancestor of that repository,
            // and the cloud path must be that repository's own path below the root. No drive letter or repository name
            // is assumed. The repository is bound to the backup telemetry further down as well.
            string configuredRepository = CanonicalWindowsPath(ReadConfiguredRepository());
            bool planRepositoryBound =
                !string.IsNullOrEmpty(configuredRepository)
                && string.Equals(
                    localRepository,
                    configuredRepository,
                    StringComparison.OrdinalIgnoreCase);
            string expectedCloudPath = planRepositoryBound
                ? CloudPathForLocalRepository(configuredRepository, myDriveRoot)
                : string.Empty;
            bool exactPathBinding =
                !string.IsNullOrEmpty(expectedCloudPath)
                && string.Equals(
                    cloudRootFolderId,
                    "root",
                    StringComparison.Ordinal)
                && string.Equals(
                    cloudRepositoryPath,
                    expectedCloudPath,
                    StringComparison.Ordinal);
            // The Rewindle verifier also binds each proof to its immutable evidence copy, the verification asset
            // manifest and the binary-stream capture it used; a proof without them is incomplete.
            bool assetBinding =
                !EngineProfile.Current.CloudProofRequiresAssetBinding
                || (!string.IsNullOrEmpty(immutableProofHash)
                    && !string.IsNullOrEmpty(cloudAssetsManifestHash)
                    && string.Equals(
                        GetString(document, "native_capture_mode", string.Empty),
                        BinaryStreamCaptureMode,
                        StringComparison.Ordinal));
            bool identityBinding =
                !string.IsNullOrEmpty(repositoryId)
                && repositoryId == localRepositoryId
                && repositoryId == cloudRepositoryId;
            bool inventoryBinding =
                typedInventory
                && files > 0
                && bytes > 0
                && missingFiles == 0
                && extraFiles == 0
                && mismatchedFiles == 0
                && cloudObjectsWithIds == files
                && GetBool(document, "repository_identity_verified", false)
                && GetBool(document, "exact_file_inventory_verified", false)
                && GetBool(
                    document,
                    "path_case_size_md5_sha256_verified",
                    false)
                && !string.IsNullOrEmpty(inventoryFingerprint)
                && !string.IsNullOrEmpty(cloudInventoryHash)
                && !string.IsNullOrEmpty(backupConfigHash);
            bool restoreBinding =
                GetBool(document, "direct_cloud_restore_verified", false)
                && string.Equals(
                    GetString(
                        document,
                        "provider_upload_state",
                        string.Empty),
                    "fully_synced",
                    StringComparison.Ordinal)
                && string.Equals(
                    GetString(
                        document,
                        "restore_verification_state",
                        string.Empty),
                    "verified",
                    StringComparison.Ordinal)
                && !string.IsNullOrEmpty(canaryHash)
                && canaryBytes >= 0;

            if (!string.Equals(
                    verificationMode,
                    DirectCloudVerificationMode,
                    StringComparison.Ordinal)
                || !string.Equals(
                    storageMode,
                    DriveFsStorageMode,
                    StringComparison.Ordinal)
                || string.IsNullOrEmpty(planId)
                || string.IsNullOrEmpty(snapshotId)
                || !exactPathBinding
                || !identityBinding
                || !inventoryBinding
                || !restoreBinding
                || !assetBinding)
            {
                result.Kind = OffsiteStatusKind.StatusUnavailable;
                result.StatusLabel = "Direct cloud verification incomplete";
                result.StatusDetail =
                    "The latest proof lacks a complete My Drive path bound to the installed backup plan, repository identity, inventory, immutable-evidence, or direct-restore binding.";
                return result;
            }

            DateTime verifiedUtc;
            if (!TryGetUtc(document, "verified_utc", out verifiedUtc))
            {
                result.Kind = OffsiteStatusKind.StatusUnavailable;
                result.StatusLabel = "Direct cloud verification incomplete";
                result.StatusDetail =
                    "The latest proof has no valid verification timestamp.";
                return result;
            }

            DateTime lastSuccessFinishedUtc;
            if (!TryReadLastVerifiedFinishedUtc(
                    lastSuccess,
                    out lastSuccessFinishedUtc)
                || !BackupBindingMatches(
                    lastSuccess,
                    planId,
                    configGeneration,
                    localRepository,
                    repositoryId,
                    snapshotId,
                    true))
            {
                result.Kind = OffsiteStatusKind.StatusUnavailable;
                result.StatusLabel = "Direct cloud proof is stale";
                result.StatusDetail =
                    "The proof does not match the latest successfully verified backup plan, generation, repository, and snapshot.";
                return result;
            }

            if (currentStatus != null
                && !BackupBindingMatches(
                    currentStatus,
                    planId,
                    configGeneration,
                    localRepository,
                    repositoryId,
                    snapshotId,
                    false))
            {
                result.Kind = OffsiteStatusKind.StatusUnavailable;
                result.StatusLabel = "Direct cloud proof is stale";
                result.StatusDetail =
                    "The proof does not match the repository plan or generation in current protected backup telemetry.";
                return result;
            }

            DateTime currentTelemetryUtc;
            bool currentHasTimestamp = TryGetUtc(
                currentStatus,
                "finished_utc",
                out currentTelemetryUtc)
                || TryGetUtc(
                    currentStatus,
                    "started_utc",
                    out currentTelemetryUtc);
            if (verifiedUtc < lastSuccessFinishedUtc
                || (currentHasTimestamp && verifiedUtc < currentTelemetryUtc))
            {
                result.Kind = OffsiteStatusKind.StatusUnavailable;
                result.StatusLabel = "Direct cloud proof is stale";
                result.StatusDetail =
                    "The cloud verification predates the latest repository-changing backup attempt or successful backup.";
                return result;
            }

            result.PlanId = planId;
            result.ConfigGeneration = configGeneration;
            result.RepositoryId = repositoryId;
            result.RepositoryPath = localRepository;
            result.SnapshotId = snapshotId;
            result.InventoryFingerprintSha256 = inventoryFingerprint;
            result.FileCount = files;
            result.ByteCount = bytes;
            result.LastUpdatedLocal = verifiedUtc.ToLocalTime();
            result.ProviderUploadConfirmed = true;
            result.RestoreVerified = true;
            result.Kind = OffsiteStatusKind.RestoreVerified;
            result.StatusLabel = "Google Drive repository verified";
            result.StatusDetail =
                "The live streamed repository matches Google Drive's API inventory, and an independent direct-cloud restore succeeded.";
            return result;
        }

        // The repository of the installed backup plan: backup-config.json under the active engine's protected install
        // root, read and validated by SourceConfiguration.Load (the same read every protected action starts from). An
        // empty string when it cannot be read, which no proof matches: a proof is never accepted without a plan to
        // bind it to.
        private static string ReadConfiguredRepository()
        {
            try
            {
                return SourceConfiguration.Load().RepositoryPath ?? string.Empty;
            }
            catch (Exception)
            {
                return string.Empty;
            }
        }

        // The repository's path below the My Drive root, with forward slashes, or an empty string when the
        // repository is not strictly below that root or the relative path has an empty, "." or ".." part.
        private static string CloudPathForLocalRepository(
            string repository,
            string myDriveRoot)
        {
            if (string.IsNullOrEmpty(repository)
                || string.IsNullOrEmpty(myDriveRoot)
                || !repository.StartsWith(
                    myDriveRoot + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase))
            {
                return string.Empty;
            }
            string relative = repository.Substring(myDriveRoot.Length)
                .TrimStart(Path.DirectorySeparatorChar)
                .Replace(Path.DirectorySeparatorChar, '/');
            if (string.IsNullOrEmpty(relative)
                || relative.StartsWith("/", StringComparison.Ordinal)
                || relative.EndsWith("/", StringComparison.Ordinal)
                || relative.Split('/').Any(part =>
                    string.IsNullOrEmpty(part)
                    || part == "."
                    || part == ".."))
            {
                return string.Empty;
            }
            return relative;
        }

        private static bool BackupBindingMatches(
            IDictionary<string, object> document,
            string planId,
            long configGeneration,
            string repositoryPath,
            string repositoryId,
            string snapshotId,
            bool requireSnapshot)
        {
            if (document == null)
            {
                return false;
            }
            long recordedGeneration;
            if (CanonicalPlanId(GetString(document, "plan_id", string.Empty))
                    != planId
                || !TryGetJsonInteger(
                    document,
                    "config_generation",
                    1,
                    out recordedGeneration)
                || recordedGeneration != configGeneration
                || !string.Equals(
                    CanonicalWindowsPath(
                        GetString(document, "repository", string.Empty)),
                    repositoryPath,
                    StringComparison.OrdinalIgnoreCase)
                || !string.Equals(
                    GetString(
                        document,
                        "repository_storage_mode",
                        string.Empty),
                    DriveFsStorageMode,
                    StringComparison.Ordinal)
                || CanonicalSnapshotId(
                    GetString(document, "repository_id", string.Empty))
                    != repositoryId)
            {
                return false;
            }
            if (!requireSnapshot)
            {
                string currentSnapshot = CanonicalSnapshotId(
                    GetString(document, "snapshot_id", string.Empty));
                return string.IsNullOrEmpty(currentSnapshot)
                    || currentSnapshot == snapshotId;
            }
            return CanonicalSnapshotId(
                GetString(document, "snapshot_id", string.Empty)) == snapshotId;
        }

        private static bool TryGetJsonInteger(
            IDictionary<string, object> source,
            string key,
            long minimum,
            out long result)
        {
            result = -1;
            if (source == null)
            {
                return false;
            }
            object value;
            if (!source.TryGetValue(key, out value)
                || value == null
                || value is bool
                || value is string)
            {
                return false;
            }
            try
            {
                if (value is double)
                {
                    double number = (double)value;
                    if (double.IsNaN(number)
                        || double.IsInfinity(number)
                        || Math.Truncate(number) != number
                        || number > long.MaxValue
                        || number < minimum)
                    {
                        return false;
                    }
                }
                if (value is decimal)
                {
                    decimal number = (decimal)value;
                    if (decimal.Truncate(number) != number
                        || number > long.MaxValue
                        || number < minimum)
                    {
                        return false;
                    }
                }
                result = Convert.ToInt64(value, CultureInfo.InvariantCulture);
                return result >= minimum;
            }
            catch (Exception error)
            {
                if (error is FormatException
                    || error is InvalidCastException
                    || error is OverflowException)
                {
                    return false;
                }
                throw;
            }
        }

        private static string CanonicalPlanId(string value)
        {
            Guid parsed;
            if (!Guid.TryParse(value, out parsed) || parsed == Guid.Empty)
            {
                return string.Empty;
            }
            string canonical = parsed.ToString("D");
            return string.Equals(value, canonical, StringComparison.Ordinal)
                ? canonical
                : string.Empty;
        }

        private static string CanonicalWindowsPath(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || !Path.IsPathRooted(value))
            {
                return string.Empty;
            }
            try
            {
                return TrimTrailingSeparators(Path.GetFullPath(value));
            }
            catch (Exception error)
            {
                if (error is ArgumentException
                    || error is NotSupportedException
                    || error is PathTooLongException)
                {
                    return string.Empty;
                }
                throw;
            }
        }

        private static string CanonicalSnapshotId(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length != 64)
            {
                return string.Empty;
            }
            foreach (char item in value)
            {
                if (!((item >= '0' && item <= '9')
                    || (item >= 'a' && item <= 'f')
                    || (item >= 'A' && item <= 'F')))
                {
                    return string.Empty;
                }
            }
            return value.ToLowerInvariant();
        }

        private static string CleanOffsiteDetail(string value)
        {
            if (!string.IsNullOrEmpty(value)
                && (value.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0
                    || value.IndexOf("dpapi", StringComparison.OrdinalIgnoreCase) >= 0
                    || value.IndexOf("RESTIC_", StringComparison.OrdinalIgnoreCase) >= 0
                    || value.IndexOf("recovery key", StringComparison.OrdinalIgnoreCase) >= 0))
            {
                return "Off-site status needs attention without exposing credential details.";
            }
            return CleanDisplayText(value, 320);
        }

        // No readable status: nothing is known about a backup, so none is called failed (a file that cannot be read for a moment
        // is not a failed run, and used to be announced as one) and none is called verified. `detail` is a fixed sentence, never
        // an exception's own text, which can name a path or quote the file.
        private TelemetrySnapshot BuildTelemetryError(
            string stateKey,
            string label,
            string detail,
            DateTime lastWriteUtc)
        {
            TelemetrySnapshot snapshot = new TelemetrySnapshot();
            snapshot.StateKey = stateKey;
            snapshot.StatusLabel = label;
            snapshot.StatusDetail = CleanDisplayText(detail, 400);
            snapshot.IsStatusUnavailable = true;
            snapshot.ProgressIsEstimated = true;
            snapshot.ConfidenceLabel = "Status unavailable";
            snapshot.PhaseLabel = "Unavailable";
            snapshot.LastUpdatedLocal = ToLocalOrNow(lastWriteUtc);
            return snapshot;
        }

        private TelemetrySnapshot BuildDryRunSnapshot(
            IDictionary<string, object> document,
            DateTime lastWriteUtc)
        {
            string state = GetString(document, "state", "unknown").ToLowerInvariant();
            IDictionary<string, object> summary = GetDictionary(document, "summary");
            IDictionary<string, object> progress = GetDictionary(document, "progress");
            long files = FirstNonNegative(
                GetLong(summary, "total_files_processed", -1),
                GetLong(progress, "files_done", 0));
            long bytes = FirstNonNegative(
                GetLong(summary, "total_bytes_processed", -1),
                GetLong(progress, "bytes_done", 0));
            double duration = GetDouble(summary, "total_duration", -1);
            if (duration < 0)
            {
                duration = DurationBetween(document);
            }

            TelemetrySnapshot snapshot = new TelemetrySnapshot();
            snapshot.RunId = GetString(document, "run_id", string.Empty);
            snapshot.SnapshotId = GetString(document, "snapshot_id", string.Empty);
            snapshot.FilesDone = Math.Max(0, files);
            snapshot.EstimatedFiles = Math.Max(0, files);
            snapshot.BytesDone = Math.Max(0, bytes);
            snapshot.EstimatedBytes = Math.Max(0, bytes);
            snapshot.StoredBytes = Math.Max(0, GetLong(summary, "data_added_packed", 0));
            snapshot.Elapsed = SafeTimeSpan(duration);
            snapshot.TransferRateBytesPerSecond = duration > 0 && bytes > 0
                ? bytes / duration
                : 0;
            snapshot.ErrorCount = SafeInt(GetLong(document, "error_count", 0));
            snapshot.LastUpdatedLocal = ToLocalOrNow(lastWriteUtc);
            snapshot.PhaseIndex = -1;
            snapshot.PhaseLabel = "Baseline";

            if (state == "clean")
            {
                snapshot.StateKey = "ready";
                snapshot.StatusLabel = "Ready for the first backup";
                snapshot.StatusDetail = "Verified dry run: "
                    + TelemetryFormat.FormatCount(snapshot.FilesDone) + " files and "
                    + TelemetryFormat.FormatBytes(snapshot.BytesDone)
                    + " scanned with no errors.";
                snapshot.IsSuccess = false;
                snapshot.Percent = 0;
                snapshot.ProgressIsEstimated = true;
                snapshot.ConfidenceLabel = "Validation baseline ready";
            }
            else
            {
                snapshot.StateKey = state;
                snapshot.StatusLabel = state == "source_errors"
                    ? "Dry run found unreadable files"
                    : "Dry run needs attention";
                snapshot.StatusDetail = snapshot.ErrorCount > 0
                    ? TelemetryFormat.FormatCount(snapshot.ErrorCount) + " source errors were recorded."
                    : CleanDisplayText(GetString(document, "failure", "The dry run did not complete cleanly."), 240);
                snapshot.IsFailure = true;
                snapshot.ProgressIsEstimated = false;
                snapshot.ConfidenceLabel = "Final dry-run result";
            }
            return snapshot;
        }

        private static void ApplyAnomalyAcknowledgement(
            TelemetrySnapshot snapshot,
            IDictionary<string, object> status,
            JsonReadResult lastSuccessRead,
            IDictionary<string, object> acknowledgement)
        {
            if (snapshot == null || !snapshot.HasMaintenanceHold ||
                status == null || lastSuccessRead == null ||
                lastSuccessRead.Document == null || acknowledgement == null)
            {
                return;
            }
            IDictionary<string, object> evidence = lastSuccessRead.Document;
            IEnumerable<string> scopes = GetCollection(acknowledgement, "scope")
                .Select(item => Convert.ToString(item, CultureInfo.InvariantCulture));
            // The schema and scope the active engine writes (an acknowledgement for Rewindle, an off-site promotion
            // approval for the legacy personal edition); every binding below is the same for both.
            bool exact = GetString(acknowledgement, "schema", string.Empty)
                    == EngineProfile.Current.AnomalyReviewSchema
                && GetLong(acknowledgement, "schema_version", 0) == 1
                && GetString(acknowledgement, "decision", string.Empty) == "approved"
                && GetBool(acknowledgement, "maintenance_hold_remains", false)
                && scopes.Any(EngineProfile.Current.IsAnomalyReviewScope)
                && GetString(acknowledgement, "plan_id", string.Empty)
                    == GetString(status, "plan_id", string.Empty)
                && GetLong(acknowledgement, "config_generation", -1)
                    == GetLong(status, "config_generation", -2)
                && GetString(acknowledgement, "repository_id", string.Empty)
                    == GetString(status, "repository_id", string.Empty)
                && GetString(acknowledgement, "run_id", string.Empty)
                    == GetString(status, "run_id", string.Empty)
                && GetString(acknowledgement, "snapshot_id", string.Empty)
                    == GetString(status, "snapshot_id", string.Empty)
                && (GetString(evidence, "state", string.Empty) == "success"
                    || GetString(evidence, "state", string.Empty) == "success_unchanged")
                && GetBool(evidence, "verification_complete", false)
                && GetBool(evidence, "maintenance_hold", false)
                && GetString(evidence, "plan_id", string.Empty)
                    == GetString(status, "plan_id", string.Empty)
                && GetLong(evidence, "config_generation", -1)
                    == GetLong(status, "config_generation", -2)
                && GetString(evidence, "repository_id", string.Empty)
                    == GetString(status, "repository_id", string.Empty)
                && GetString(evidence, "run_id", string.Empty)
                    == GetString(status, "run_id", string.Empty)
                && GetString(evidence, "snapshot_id", string.Empty)
                    == GetString(status, "snapshot_id", string.Empty)
                && !string.IsNullOrEmpty(lastSuccessRead.Sha256)
                && GetString(acknowledgement, "backup_evidence_sha256", string.Empty)
                    == lastSuccessRead.Sha256;
            if (!exact)
            {
                return;
            }
            snapshot.AnomalyReviewAcknowledged = true;
            snapshot.StatusLabel = EngineProfile.Current.AnomalyReview.StatusLabel;
            snapshot.StatusDetail = EngineProfile.Current.AnomalyReview.StatusDetail;
            snapshot.PhaseLabel = "Reviewed";
        }

        private TelemetrySnapshot BuildBackupSnapshot(
            IDictionary<string, object> document,
            DateTime lastWriteUtc)
        {
            string state = GetString(document, "state", "unknown").ToLowerInvariant();
            IDictionary<string, object> progress = GetDictionary(document, "progress");
            IDictionary<string, object> summary = GetDictionary(document, "summary");
            bool terminalSuccess = state == "success" || state == "success_unchanged";
            bool terminalCancelled = state == "cancelled";
            bool recordedTerminalFailure = state == "failed" || state == "partial"
                || state == "cancel_failed";
            string phaseState = (state == "cancelling" || terminalCancelled)
                ? GetString(document, "phase_at_cancel_request", "backing_up").ToLowerInvariant()
                : state;
            PhaseInfo phase = recordedTerminalFailure
                ? InferFailurePhase(document, state)
                : GetPhase(phaseState);
            bool active = !terminalSuccess && !terminalCancelled && !recordedTerminalFailure
                && state != "unknown" && state != "waiting";

            DateTime startedUtc;
            bool hasStarted = TryGetUtc(document, "started_utc", out startedUtc);
            bool interrupted = active && IsStaleActiveStatus(document, startedUtc, hasStarted, lastWriteUtc);
            if (interrupted)
            {
                active = false;
                state = "interrupted";
            }
            bool terminalFailure = recordedTerminalFailure || interrupted;
            DateTime finishedUtc;
            bool hasFinished = TryGetUtc(document, "finished_utc", out finishedUtc);
            DateTime effectiveEndUtc = hasFinished
                ? finishedUtc
                : interrupted && lastWriteUtc != DateTime.MinValue
                    ? lastWriteUtc
                    : DateTime.UtcNow;
            double wrapperElapsed = hasStarted
                ? (effectiveEndUtc - startedUtc).TotalSeconds
                : 0;
            wrapperElapsed = Clamp(wrapperElapsed, 0, MaximumEtaSeconds * 2);
            double resticElapsed = GetDouble(progress, "seconds_elapsed", -1);
            double elapsedForRate = resticElapsed > 0 ? resticElapsed : wrapperElapsed;

            long progressFiles = Math.Max(0, GetLong(progress, "files_done", 0));
            long progressBytes = Math.Max(0, GetLong(progress, "bytes_done", 0));
            long summaryFiles = Math.Max(0, GetLong(summary, "total_files_processed", 0));
            long summaryBytes = Math.Max(0, GetLong(summary, "total_bytes_processed", 0));
            long filesDone = terminalSuccess || terminalCancelled || terminalFailure
                ? Math.Max(progressFiles, summaryFiles)
                : progressFiles;
            long bytesDone = terminalSuccess || terminalCancelled || terminalFailure
                ? Math.Max(progressBytes, summaryBytes)
                : progressBytes;

            EstimateBaseline baseline = BuildBaseline(
                GetString(document, "run_id", string.Empty),
                BuildSourceFingerprint(document));
            long exactFiles = Math.Max(0, GetLong(progress, "total_files", 0));
            long exactBytes = Math.Max(0, GetLong(progress, "total_bytes", 0));
            long estimatedFiles = exactFiles > 0 ? exactFiles : baseline.Files;
            long estimatedBytes = exactBytes > 0 ? exactBytes : baseline.Bytes;
            if (estimatedFiles > 0 && filesDone > estimatedFiles)
            {
                estimatedFiles = filesDone;
            }
            if (estimatedBytes > 0 && bytesDone > estimatedBytes)
            {
                estimatedBytes = bytesDone;
            }

            double resticPercent;
            bool hasExactPercent = TryGetResticPercent(progress, out resticPercent);
            List<double> exactFractions = new List<double>();
            if (hasExactPercent)
            {
                exactFractions.Add(resticPercent);
            }
            if (exactFiles > 0 && filesDone > 0)
            {
                exactFractions.Add(Clamp((double)filesDone / exactFiles, 0, 1));
            }
            if (exactBytes > 0 && bytesDone > 0)
            {
                exactFractions.Add(Clamp((double)bytesDone / exactBytes, 0, 1));
            }

            bool exactProgress = exactFractions.Count > 0;
            double backupFraction;
            if (exactProgress)
            {
                backupFraction = Median(exactFractions);
            }
            else
            {
                List<double> estimatedFractions = new List<double>();
                if (estimatedFiles > 0 && filesDone > 0)
                {
                    estimatedFractions.Add((double)filesDone / estimatedFiles);
                }
                if (estimatedBytes > 0 && bytesDone > 0)
                {
                    estimatedFractions.Add((double)bytesDone / estimatedBytes);
                }
                if (estimatedFractions.Count > 0)
                {
                    backupFraction = Median(estimatedFractions);
                }
                else
                {
                    double expectedBackupSeconds = baseline.ResticDurationSeconds;
                    backupFraction = expectedBackupSeconds > 0
                        ? elapsedForRate / expectedBackupSeconds
                        : 0;
                }
            }
            if (!exactProgress && baseline.UsesComparableRuns)
            {
                double comparableExpectedSeconds = ComparableExpectedResticSeconds(
                    baseline,
                    filesDone,
                    bytesDone,
                    elapsedForRate);
                backupFraction = comparableExpectedSeconds > 0
                    ? elapsedForRate / comparableExpectedSeconds
                    : 0;
            }
            backupFraction = Clamp(
                backupFraction,
                0,
                active || interrupted || terminalCancelled ? 0.985 : 1);

            TelemetrySnapshot snapshot = new TelemetrySnapshot();
            snapshot.StateKey = state;
            snapshot.StatusLabel = interrupted
                ? "Backup appears interrupted"
                : state == "cancelling"
                    ? "Cancelling backup safely"
                    : phase.StatusLabel;
            snapshot.IsActive = active;
            snapshot.IsFailure = terminalFailure;
            snapshot.IsSuccess = terminalSuccess;
            snapshot.IsCancelled = terminalCancelled;
            snapshot.HasMaintenanceHold = terminalSuccess
                && GetBool(document, "maintenance_hold", false);
            snapshot.MaintenanceHoldDetail = snapshot.HasMaintenanceHold
                ? BuildChangeAnomalyDetail(document)
                : string.Empty;
            snapshot.CancelOutcome = CleanIdentifier(
                GetString(document, "cancel_outcome", string.Empty),
                100);
            snapshot.FilesDone = filesDone;
            snapshot.EstimatedFiles = Math.Max(0, estimatedFiles);
            snapshot.BytesDone = bytesDone;
            snapshot.EstimatedBytes = Math.Max(0, estimatedBytes);
            snapshot.StoredBytes = Math.Max(0, GetLong(summary, "data_added_packed", 0));
            snapshot.TransferRateBytesPerSecond = elapsedForRate > 0
                ? bytesDone / elapsedForRate
                : 0;
            snapshot.Elapsed = SafeTimeSpan(wrapperElapsed);
            snapshot.ErrorCount = Math.Max(
                SafeInt(GetLong(document, "error_count", 0)),
                GetCollectionCount(document, "errors"));
            snapshot.PhaseIndex = phase.Index;
            snapshot.PhaseLabel = phase.PhaseLabel;
            snapshot.LastUpdatedLocal = ToLocalOrNow(lastWriteUtc);
            snapshot.RunId = GetString(document, "run_id", string.Empty);
            snapshot.SnapshotId = GetString(document, "snapshot_id", string.Empty);
            if (snapshot.HasMaintenanceHold)
            {
                snapshot.StatusLabel = "Backup verified — review changes";
                snapshot.PhaseLabel = "Review changes";
            }

            if (terminalSuccess)
            {
                snapshot.Percent = 1;
                snapshot.ProgressIsEstimated = false;
                snapshot.ConfidenceLabel = "Final run result";
            }
            else if (terminalCancelled)
            {
                snapshot.Percent = OverallPercent(phase.Stage, backupFraction);
                snapshot.ProgressIsEstimated = true;
                snapshot.ConfidenceLabel = "Progress when cancellation completed";
                snapshot.PhaseLabel = "Cancelled";
                snapshot.StatusLabel = "Backup cancelled";
            }
            else if (terminalFailure)
            {
                snapshot.Percent = OverallPercent(phase.Stage, backupFraction);
                snapshot.ProgressIsEstimated = true;
                snapshot.ConfidenceLabel = interrupted
                    ? "Last recorded progress before interruption"
                    : "Last recorded progress before failure";
            }
            else
            {
                snapshot.Percent = OverallPercent(phase.Stage, backupFraction);
                snapshot.ProgressIsEstimated = phase.Stage != 1 || !exactProgress;
                snapshot.ConfidenceLabel = BuildConfidenceLabel(
                    exactProgress && phase.Stage == 1,
                    baseline);
            }

            if (active)
            {
                double? etaSeconds = EstimateEtaSeconds(
                    document,
                    progress,
                    phase.Stage,
                    backupFraction,
                    filesDone,
                    estimatedFiles,
                    bytesDone,
                    estimatedBytes,
                    elapsedForRate,
                    wrapperElapsed,
                    baseline);
                if (etaSeconds.HasValue)
                {
                    snapshot.Eta = SafeTimeSpan(etaSeconds.Value);
                    snapshot.EstimatedCompletion = DateTime.Now.Add(snapshot.Eta.Value);
                }
            }

            snapshot.StatusDetail = BuildStatusDetail(snapshot, document);
            return snapshot;
        }

        private string BuildStatusDetail(
            TelemetrySnapshot snapshot,
            IDictionary<string, object> document)
        {
            if (snapshot.HasMaintenanceHold)
            {
                return snapshot.MaintenanceHoldDetail;
            }
            if (snapshot.StateKey == "interrupted")
            {
                return "The protected status stopped updating and its backup process is no longer running or no longer matches this status; no completed result was recorded.";
            }
            if (snapshot.StateKey == "success")
            {
                return "Verified " + TelemetryFormat.FormatCount(snapshot.FilesDone)
                    + " files; " + TelemetryFormat.FormatBytes(snapshot.StoredBytes)
                    + " added to the repository.";
            }
            if (snapshot.StateKey == "success_unchanged")
            {
                return "All protected files already matched the latest verified snapshot.";
            }
            if (snapshot.StateKey == "cancelled")
            {
                return "Restic stopped cooperatively. Previously verified snapshots remain available, and this run was not marked successful.";
            }
            if (snapshot.StateKey == "cancelling")
            {
                return "Restic received a run-bound cancellation request and is stopping cleanly.";
            }
            if (snapshot.IsFailure)
            {
                string failure = GetString(document, "failure", string.Empty);
                if (!string.IsNullOrEmpty(failure))
                {
                    return CleanDisplayText(failure, 240);
                }
                return snapshot.ErrorCount > 0
                    ? TelemetryFormat.FormatCount(snapshot.ErrorCount) + " errors were recorded during this run."
                    : "The backup stopped before verification completed.";
            }
            if (snapshot.StateKey == "backing_up")
            {
                string detail = TelemetryFormat.FormatCount(snapshot.FilesDone) + " files \u2022 "
                    + TelemetryFormat.FormatBytes(snapshot.BytesDone) + " read";
                if (snapshot.TransferRateBytesPerSecond > 0)
                {
                    detail += " \u2022 "
                        + TelemetryFormat.FormatBytes((long)snapshot.TransferRateBytesPerSecond)
                        + "/s";
                }
                return detail;
            }
            if (snapshot.StateKey == "starting")
            {
                return "Validating the repository and preparing the protected source list.";
            }
            if (snapshot.StateKey == "verifying_snapshot")
            {
                return "Confirming that the new snapshot is present and correctly bound to this computer.";
            }
            if (snapshot.StateKey == "checking_repository")
            {
                return "Checking repository structure before the run is marked successful.";
            }
            if (snapshot.StateKey == "restoring_canary")
            {
                return "Restoring and checking a small test file to prove recovery works.";
            }
            if (snapshot.StateKey == "checking_data_subset")
            {
                return "Reading this run's scheduled repository-data sample.";
            }
            return "Backup telemetry was received; the current phase is not yet classified.";
        }

        private static string BuildChangeAnomalyDetail(
            IDictionary<string, object> document)
        {
            IDictionary<string, object> anomaly = GetDictionary(document, "change_anomaly");
            IDictionary<string, object> measurements = GetDictionary(anomaly, "measurements");
            List<string> evidence = new List<string>();
            double deletionRatio = GetDouble(measurements, "deletion_ratio", -1);
            double changeRatio = GetDouble(measurements, "file_change_ratio", -1);
            double dataRatio = GetDouble(measurements, "data_added_ratio", -1);
            if (deletionRatio >= 0)
            {
                evidence.Add((deletionRatio * 100).ToString("0.0", CultureInfo.CurrentCulture)
                    + "% estimated deletions");
            }
            if (changeRatio >= 0)
            {
                evidence.Add((changeRatio * 100).ToString("0.0", CultureInfo.CurrentCulture)
                    + "% new or changed files");
            }
            if (dataRatio >= 0)
            {
                evidence.Add((dataRatio * 100).ToString("0.0", CultureInfo.CurrentCulture)
                    + "% repository data added versus the prior logical size");
            }
            string measurementsText = evidence.Count == 0
                ? "an unusually large change set"
                : string.Join(", ", evidence.Take(3).ToArray());
            return "The snapshot was kept and verified, but " + measurementsText
                + EngineProfile.Current.AnomalyReview.HoldDetailSuffix;
        }

        private static string BuildSourceFingerprint(IDictionary<string, object> document)
        {
            List<string> normalizedSources = GetCollection(document, "sources")
                .Select(item => Convert.ToString(item, CultureInfo.InvariantCulture))
                .Where(item => !string.IsNullOrWhiteSpace(item))
                .Select(NormalizeFingerprintValue)
                .OrderBy(item => item, StringComparer.Ordinal)
                .ToList();
            string canonical = "v1\n"
                + NormalizeFingerprintValue(GetString(document, "repository", string.Empty)) + "\n"
                + NormalizeFingerprintValue(GetString(document, "repository_volume_serial", string.Empty)) + "\n"
                + NormalizeFingerprintValue(GetString(document, "exclude_file_sha256", string.Empty)) + "\n"
                + string.Join("\n", normalizedSources.ToArray());
            using (SHA256 sha256 = SHA256.Create())
            {
                byte[] hash = sha256.ComputeHash(Encoding.UTF8.GetBytes(canonical));
                StringBuilder result = new StringBuilder(hash.Length * 2);
                foreach (byte value in hash)
                {
                    result.Append(value.ToString("x2", CultureInfo.InvariantCulture));
                }
                return result.ToString();
            }
        }

        private static string NormalizeFingerprintValue(string value)
        {
            return (value ?? string.Empty)
                .Trim()
                .Replace('/', '\\')
                .TrimEnd('\\')
                .ToUpperInvariant();
        }

        private EstimateBaseline BuildBaseline(string currentRunId, string sourceFingerprint)
        {
            List<RunMetricRecord> backups = historyRecords
                .Where(item => item.Success
                    && item.TypeKey == "backup"
                    && string.Equals(item.SourceFingerprint, sourceFingerprint, StringComparison.Ordinal)
                    && !string.Equals(item.RunId, currentRunId, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(item => item.StartedUtc)
                .Take(20)
                .ToList();
            List<RunMetricRecord> source = backups;
            bool dryRunOnly = false;
            bool usesComparableRuns = false;
            if (source.Count == 0)
            {
                source = historyRecords
                    .Where(item => item.Success
                        && item.TypeKey == "dry_run"
                        && string.Equals(item.SourceFingerprint, sourceFingerprint, StringComparison.Ordinal))
                    .OrderByDescending(item => item.StartedUtc)
                    .Take(5)
                    .ToList();
                dryRunOnly = source.Count > 0;
            }
            if (source.Count == 0)
            {
                source = historyRecords
                    .Where(item => item.Success
                        && item.TypeKey == "backup"
                        && !string.Equals(item.RunId, currentRunId, StringComparison.OrdinalIgnoreCase))
                    .OrderByDescending(item => item.StartedUtc)
                    .Take(10)
                    .ToList();
                usesComparableRuns = source.Count > 0;
            }

            EstimateBaseline baseline = new EstimateBaseline();
            baseline.SampleCount = source.Count;
            baseline.DryRunOnly = dryRunOnly;
            baseline.UsesComparableRuns = usesComparableRuns;
            baseline.Files = MedianLong(source.Where(item => item.Files > 0).Select(item => item.Files));
            baseline.Bytes = MedianLong(source.Where(item => item.ProcessedBytes > 0).Select(item => item.ProcessedBytes));
            baseline.TotalDurationSeconds = Median(
                source.Where(item => item.DurationSeconds > 0)
                    .Select(item => item.DurationSeconds));
            baseline.ResticDurationSeconds = Median(
                source.Where(item => item.ResticDurationSeconds > 0)
                    .Select(item => item.ResticDurationSeconds));
            if (baseline.ResticDurationSeconds <= 0)
            {
                baseline.ResticDurationSeconds = baseline.TotalDurationSeconds;
            }

            IEnumerable<RunMetricRecord> overheadSource = usesComparableRuns ? source : backups;
            List<double> overheads = overheadSource
                .Where(item => item.DurationSeconds > item.ResticDurationSeconds
                    && item.ResticDurationSeconds > 0)
                .Select(item => item.DurationSeconds - item.ResticDurationSeconds)
                .ToList();
            baseline.PostProcessingSeconds = overheads.Count > 0 ? Median(overheads) : 240;
            if (dryRunOnly)
            {
                baseline.TotalDurationSeconds += baseline.PostProcessingSeconds;
            }
            return baseline;
        }

        private double? EstimateEtaSeconds(
            IDictionary<string, object> document,
            IDictionary<string, object> progress,
            int phaseIndex,
            double backupFraction,
            long filesDone,
            long estimatedFiles,
            long bytesDone,
            long estimatedBytes,
            double resticElapsed,
            double wrapperElapsed,
            EstimateBaseline baseline)
        {
            if (phaseIndex == 1)
            {
                if (baseline.UsesComparableRuns)
                {
                    double expectedResticSeconds = ComparableExpectedResticSeconds(
                        baseline,
                        filesDone,
                        bytesDone,
                        resticElapsed);
                    if (expectedResticSeconds > 0)
                    {
                        double comparableRemaining = Math.Max(
                            baseline.PostProcessingSeconds,
                            expectedResticSeconds - resticElapsed
                                + baseline.PostProcessingSeconds);
                        return Clamp(comparableRemaining, 0, MaximumEtaSeconds);
                    }
                }

                List<double> candidates = new List<double>();
                double exactRemaining = GetDouble(progress, "seconds_remaining", -1);
                if (exactRemaining >= 0)
                {
                    candidates.Add(exactRemaining);
                }
                if (resticElapsed > 1 && filesDone > 0 && estimatedFiles > filesDone)
                {
                    candidates.Add((estimatedFiles - filesDone) / (filesDone / resticElapsed));
                }
                if (resticElapsed > 1 && bytesDone > 0 && estimatedBytes > bytesDone)
                {
                    candidates.Add((estimatedBytes - bytesDone) / (bytesDone / resticElapsed));
                }
                if (resticElapsed > 1 && backupFraction > 0.002 && backupFraction < 1)
                {
                    candidates.Add(resticElapsed * (1 - backupFraction) / backupFraction);
                }
                if (candidates.Count == 0 && baseline.ResticDurationSeconds > resticElapsed)
                {
                    candidates.Add(baseline.ResticDurationSeconds - resticElapsed);
                }
                if (candidates.Count == 0)
                {
                    return null;
                }
                return Clamp(Median(candidates) + baseline.PostProcessingSeconds, 0, MaximumEtaSeconds);
            }

            if (phaseIndex == 0)
            {
                double expected = baseline.TotalDurationSeconds;
                return expected > wrapperElapsed
                    ? (double?)Clamp(expected - wrapperElapsed, 0, MaximumEtaSeconds)
                    : null;
            }

            List<double> historicDurations = historyRecords
                .Where(item => item.Success
                    && item.TypeKey == "backup"
                    && item.DurationSeconds > 0
                    && !string.Equals(item.RunId, GetString(document, "run_id", string.Empty),
                        StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(item => item.StartedUtc)
                .Take(20)
                .Select(item => item.DurationSeconds)
                .ToList();
            if (historicDurations.Count > 0)
            {
                double historicRemaining = Median(historicDurations) - wrapperElapsed;
                if (historicRemaining > 0)
                {
                    return Clamp(historicRemaining, 0, MaximumEtaSeconds);
                }
            }

            double fallback;
            switch (phaseIndex)
            {
                case 2:
                    fallback = 90;
                    break;
                case 3:
                    fallback = 300;
                    break;
                case 4:
                    fallback = 45;
                    break;
                case 5:
                    fallback = 600;
                    break;
                default:
                    return null;
            }
            return fallback;
        }

        private static double ComparableExpectedResticSeconds(
            EstimateBaseline baseline,
            long filesDone,
            long bytesDone,
            double resticElapsed)
        {
            if (baseline == null || baseline.ResticDurationSeconds <= 0)
            {
                return 0;
            }

            double observedWorkScale = 1;
            if (baseline.Files > 0 && filesDone > 0)
            {
                observedWorkScale = Math.Max(
                    observedWorkScale,
                    (double)filesDone / baseline.Files);
            }
            if (baseline.Bytes > 0 && bytesDone > 0)
            {
                observedWorkScale = Math.Max(
                    observedWorkScale,
                    (double)bytesDone / baseline.Bytes);
            }

            // A different folder set has an unknown amount of work. Once it exceeds
            // comparable history, reserve headroom instead of implying it is done.
            double scaleWithHeadroom = observedWorkScale > 1
                ? observedWorkScale * 1.25
                : 1;
            double expected = baseline.ResticDurationSeconds * scaleWithHeadroom;
            if (expected <= resticElapsed)
            {
                expected = resticElapsed + Math.Max(
                    baseline.PostProcessingSeconds,
                    baseline.ResticDurationSeconds * 0.25);
            }
            return Clamp(expected, 0, MaximumEtaSeconds);
        }

        private string BuildConfidenceLabel(bool exactProgress, EstimateBaseline baseline)
        {
            if (exactProgress)
            {
                return "Restic-reported progress";
            }
            if (baseline.DryRunOnly)
            {
                return "Estimated from verified dry run";
            }
            if (baseline.UsesComparableRuns)
            {
                return "Low-confidence estimate from comparable recent runs";
            }
            if (baseline.SampleCount >= 5)
            {
                return "High-confidence median of matching folder-set runs";
            }
            if (baseline.SampleCount > 0)
            {
                return "Estimated from matching folder-set history";
            }
            return "Learning from this run";
        }

        private static double OverallPercent(int phaseIndex, double backupFraction)
        {
            switch (phaseIndex)
            {
                case 0:
                    return 0.015;
                case 1:
                    return Clamp(0.04 + 0.72 * backupFraction, 0.04, 0.75);
                case 2:
                    return 0.80;
                case 3:
                    return 0.86;
                case 4:
                    return 0.94;
                case 5:
                    return 0.97;
                case 6:
                    return 1;
                default:
                    return 0;
            }
        }

        private static PhaseInfo GetPhase(string state)
        {
            switch (state)
            {
                case "starting":
                    return new PhaseInfo(0, 0, "Preparing", "Preparing backup");
                // The wrappers' preflight phases: the backup storage, the protected folders and the repository key are
                // checked before Restic reads anything.
                case "checking_repository_storage":
                    return new PhaseInfo(0, 0, "Preparing", "Checking backup storage");
                case "preflighting_sources":
                    return new PhaseInfo(0, 0, "Preparing", "Checking protected folders");
                case "authenticating_repository":
                    return new PhaseInfo(0, 0, "Preparing", "Opening the backup repository");
                // The legacy personal edition checks its streamed storage again after the snapshot is verified.
                case "verifying_repository_storage":
                    return new PhaseInfo(2, 3, "Repository", "Checking storage");
                case "backing_up":
                    return new PhaseInfo(0, 1, "Backing up", "Backing up files");
                case "verifying_snapshot":
                    return new PhaseInfo(1, 2, "Snapshot", "Confirming snapshot");
                case "checking_repository":
                    return new PhaseInfo(2, 3, "Repository", "Checking storage");
                case "restoring_canary":
                    return new PhaseInfo(3, 4, "Recovery test", "Running restore test");
                case "checking_data_subset":
                    return new PhaseInfo(3, 5, "Data sample", "Reading a sample of backup data");
                case "cancelling":
                    return new PhaseInfo(0, 1, "Cancelling", "Stopping backup safely");
                case "cancelled":
                    return new PhaseInfo(0, 1, "Cancelled", "Backup cancelled");
                case "success":
                    return new PhaseInfo(4, 6, "Complete", "Backup complete");
                case "success_unchanged":
                    return new PhaseInfo(4, 6, "Complete", "Everything is up to date");
                default:
                    return new PhaseInfo(-1, -1, "Unknown", "Checking backup status");
            }
        }

        private static PhaseInfo InferFailurePhase(
            IDictionary<string, object> document,
            string state)
        {
            long backupExitCode = GetLong(document, "backup_exit_code", -1);
            if (state == "partial" || backupExitCode > 0)
            {
                return new PhaseInfo(0, 1, "Backing up", "Backup incomplete");
            }
            if (backupExitCode < 0)
            {
                return new PhaseInfo(0, 0, "Preparing", "Backup failed while preparing");
            }

            string snapshotId = GetString(document, "snapshot_id", string.Empty);
            if (string.IsNullOrEmpty(snapshotId))
            {
                return new PhaseInfo(1, 2, "Snapshot", "Snapshot verification failed");
            }

            IDictionary<string, object> verification = GetDictionary(document, "verification");
            if (!GetBool(verification, "repository_structure", false))
            {
                return new PhaseInfo(2, 3, "Repository", "Storage check failed");
            }

            IDictionary<string, object> canary = GetDictionary(verification, "canary");
            if (!GetBool(canary, "verified", false))
            {
                return new PhaseInfo(3, 4, "Recovery test", "Restore test failed");
            }
            if (!string.IsNullOrEmpty(GetString(verification, "data_subset", string.Empty)))
            {
                return new PhaseInfo(3, 5, "Data sample", "Backup data check failed");
            }
            return new PhaseInfo(3, 4, "Verification", "Backup verification failed");
        }

        private static bool IsStaleActiveStatus(
            IDictionary<string, object> document,
            DateTime startedUtc,
            bool hasStarted,
            DateTime lastWriteUtc)
        {
            DateTime nowUtc = DateTime.UtcNow;
            double statusAgeSeconds = lastWriteUtc == DateTime.MinValue
                ? MaximumActiveStatusAgeSeconds + 1
                : Math.Max(0, (nowUtc - lastWriteUtc).TotalSeconds);
            if (statusAgeSeconds > MaximumActiveStatusAgeSeconds)
            {
                return true;
            }

            if (hasStarted)
            {
                DateTime bootUtc = nowUtc - TimeSpan.FromMilliseconds(GetTickCount64());
                if (startedUtc < bootUtc.AddMinutes(-2))
                {
                    return true;
                }
            }

            long processIdValue = GetLong(document, "wrapper_pid", -1);
            if (processIdValue <= 0 || processIdValue > int.MaxValue)
            {
                return statusAgeSeconds > MissingProcessGraceSeconds;
            }

            try
            {
                using (Process process = Process.GetProcessById((int)processIdValue))
                {
                    if (process.HasExited)
                    {
                        return statusAgeSeconds > MissingProcessGraceSeconds;
                    }
                    if (hasStarted)
                    {
                        try
                        {
                            DateTime processStartUtc = process.StartTime.ToUniversalTime();
                            if (Math.Abs((processStartUtc - startedUtc).TotalMinutes) > 5)
                            {
                                return statusAgeSeconds > MissingProcessGraceSeconds;
                            }
                        }
                        catch (System.ComponentModel.Win32Exception)
                        {
                        }
                        catch (InvalidOperationException)
                        {
                            return statusAgeSeconds > MissingProcessGraceSeconds;
                        }
                    }
                    return false;
                }
            }
            catch (ArgumentException)
            {
                return statusAgeSeconds > MissingProcessGraceSeconds;
            }
            catch (InvalidOperationException)
            {
                return statusAgeSeconds > MissingProcessGraceSeconds;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                return false;
            }
        }

        [DllImport("kernel32.dll")]
        private static extern ulong GetTickCount64();

        private bool UpsertMetric(RunMetricRecord candidate)
        {
            RunMetricRecord existing = historyRecords.FirstOrDefault(item =>
                string.Equals(item.RunId, candidate.RunId, StringComparison.OrdinalIgnoreCase)
                && string.Equals(item.TypeKey, candidate.TypeKey, StringComparison.Ordinal));
            if (existing != null)
            {
                if (MetricEquals(existing, candidate))
                {
                    return false;
                }
                historyRecords.Remove(existing);
            }
            historyRecords.Add(candidate);
            if (historyRecords.Count > MaximumHistoryRuns)
            {
                historyTruncated = true;
            }
            historyRecords = historyRecords
                .OrderByDescending(item => item.StartedUtc)
                .Take(MaximumHistoryRuns)
                .ToList();
            // The cap can drop the record that was just added: a dry-run baseline older than every kept
            // run is offered again on every refresh. Only a change to the kept set needs persisting, or the
            // whole history is rewritten (and flushed to disk) once a second.
            return existing != null || historyRecords.Any(item => ReferenceEquals(item, candidate));
        }

        private static bool MetricEquals(RunMetricRecord left, RunMetricRecord right)
        {
            return left.RunId == right.RunId
                && left.TypeKey == right.TypeKey
                && left.StateKey == right.StateKey
                && left.Success == right.Success
                && left.StartedUtc == right.StartedUtc
                && left.FinishedUtc == right.FinishedUtc
                && Math.Abs(left.DurationSeconds - right.DurationSeconds) < 0.001
                && Math.Abs(left.ResticDurationSeconds - right.ResticDurationSeconds) < 0.001
                && left.Files == right.Files
                && left.ProcessedBytes == right.ProcessedBytes
                && left.StoredBytes == right.StoredBytes
                && left.SnapshotId == right.SnapshotId
                && left.SourceFingerprint == right.SourceFingerprint;
        }

        private RunMetricRecord CreateBackupMetric(IDictionary<string, object> document)
        {
            string state = GetString(document, "state", string.Empty).ToLowerInvariant();
            if (state != "success" && state != "success_unchanged"
                && state != "failed" && state != "partial"
                && state != "cancelled" && state != "cancel_failed")
            {
                return null;
            }
            return CreateMetric(document, "backup", state,
                state == "success" || state == "success_unchanged");
        }

        private RunMetricRecord CreateDryRunMetric(IDictionary<string, object> document)
        {
            string state = GetString(document, "state", string.Empty).ToLowerInvariant();
            if (state != "clean" && state != "source_errors" && state != "failed")
            {
                return null;
            }
            return CreateMetric(document, "dry_run", state, state == "clean");
        }

        private RunMetricRecord CreateMetric(
            IDictionary<string, object> document,
            string typeKey,
            string stateKey,
            bool success)
        {
            string runId = CleanIdentifier(GetString(document, "run_id", string.Empty), 100);
            DateTime startedUtc;
            if (string.IsNullOrEmpty(runId) || !TryGetUtc(document, "started_utc", out startedUtc))
            {
                return null;
            }
            DateTime finishedUtc;
            bool hasFinished = TryGetUtc(document, "finished_utc", out finishedUtc);
            IDictionary<string, object> summary = GetDictionary(document, "summary");
            IDictionary<string, object> progress = GetDictionary(document, "progress");

            RunMetricRecord metric = new RunMetricRecord();
            metric.RunId = runId;
            metric.TypeKey = typeKey;
            metric.StateKey = stateKey;
            metric.Success = success;
            metric.SourceFingerprint = BuildSourceFingerprint(document);
            metric.StartedUtc = startedUtc;
            metric.FinishedUtc = hasFinished ? finishedUtc : startedUtc;
            metric.DurationSeconds = hasFinished
                ? Clamp((finishedUtc - startedUtc).TotalSeconds, 0, MaximumEtaSeconds * 2)
                : Math.Max(0, GetDouble(summary, "total_duration", 0));
            metric.ResticDurationSeconds = Math.Max(0,
                GetDouble(summary, "total_duration", 0));
            metric.Files = Math.Max(0, FirstNonNegative(
                GetLong(summary, "total_files_processed", -1),
                GetLong(progress, "files_done", 0)));
            metric.ProcessedBytes = Math.Max(0, FirstNonNegative(
                GetLong(summary, "total_bytes_processed", -1),
                GetLong(progress, "bytes_done", 0)));
            metric.StoredBytes = Math.Max(0, FirstNonNegative(
                GetLong(summary, "data_added_packed", -1),
                GetLong(summary, "data_added", 0)));
            metric.SnapshotId = CleanIdentifier(
                FirstNonEmpty(
                    GetString(document, "snapshot_id", string.Empty),
                    GetString(summary, "snapshot_id", string.Empty)),
                128);
            return metric;
        }

        private IList<RunMetricView> BuildHistoryViews()
        {
            return historyRecords
                .OrderByDescending(item => item.StartedUtc)
                .Select(item => new RunMetricView
                {
                    StartedLocal = item.StartedUtc.ToLocalTime(),
                    RunId = item.RunId,
                    TypeLabel = item.TypeKey == "dry_run" ? "Dry run" : "Backup",
                    StateLabel = MetricStateLabel(item.StateKey),
                    Success = item.Success,
                    DurationSeconds = item.DurationSeconds,
                    Files = item.Files,
                    ProcessedBytes = item.ProcessedBytes,
                    StoredBytes = item.StoredBytes,
                    SnapshotShort = ShortSnapshot(item.SnapshotId)
                })
                .ToList();
        }

        private static string MetricStateLabel(string state)
        {
            switch (state)
            {
                case "success":
                    return "Verified";
                case "success_unchanged":
                    return "Unchanged";
                case "clean":
                    return "Clean baseline";
                case "partial":
                    return "Incomplete";
                case "source_errors":
                    return "Source errors";
                case "failed":
                    return "Failed";
                case "cancelled":
                    return "Cancelled";
                case "cancel_failed":
                    return "Cancellation failed";
                default:
                    return state;
            }
        }

        private void TryPersistHistory()
        {
            // Nothing is written while the file on disk is unsettled (it exists but could not be read yet) or is not this build's
            // to rewrite. What was learned meanwhile stays in memory, and is written once it is safe to.
            if (!persistenceReady || historyReadOnly)
            {
                return;
            }
            if (historyLoadPending)
            {
                historyWriteDeferred = true;
                return;
            }
            historyWriteDeferred = false;
            List<object> runs = new List<object>();
            foreach (RunMetricRecord metric in historyRecords)
            {
                runs.Add(SerializeMetric(metric));
            }
            // Written back as they were read: a record of a kind this build does not draw is somebody else's data.
            foreach (IDictionary<string, object> preserved in preservedHistoryRecords)
            {
                runs.Add(preserved);
            }
            Dictionary<string, object> root = new Dictionary<string, object>();
            root["schema_version"] = 1;
            root["updated_utc"] = FormatUtc(DateTime.UtcNow);
            root["history_truncated"] = historyTruncated;
            root["runs"] = runs;
            TryAtomicWriteJson(historyPath, root);
        }

        private Dictionary<string, object> SerializeMetric(RunMetricRecord metric)
        {
            Dictionary<string, object> value = new Dictionary<string, object>();
            value["run_id"] = metric.RunId;
            value["type"] = metric.TypeKey;
            value["state"] = metric.StateKey;
            value["success"] = metric.Success;
            value["started_utc"] = FormatUtc(metric.StartedUtc);
            value["finished_utc"] = FormatUtc(metric.FinishedUtc);
            value["duration_seconds"] = metric.DurationSeconds;
            value["restic_duration_seconds"] = metric.ResticDurationSeconds;
            value["files"] = metric.Files;
            value["processed_bytes"] = metric.ProcessedBytes;
            value["stored_bytes"] = metric.StoredBytes;
            value["snapshot_id"] = metric.SnapshotId;
            value["source_fingerprint"] = metric.SourceFingerprint;
            return value;
        }

        private List<RunMetricRecord> ParseHistory(IDictionary<string, object> root)
        {
            if (GetBool(root, "history_truncated", false))
            {
                historyTruncated = true;
            }
            List<RunMetricRecord> result = new List<RunMetricRecord>();
            List<IDictionary<string, object>> preserved = new List<IDictionary<string, object>>();
            foreach (object item in GetCollection(root, "runs"))
            {
                IDictionary<string, object> value = item as IDictionary<string, object>;
                if (value == null)
                {
                    continue;
                }

                string runId = CleanIdentifier(GetString(value, "run_id", string.Empty), 100);
                string type = GetString(value, "type", string.Empty);
                string state = CleanIdentifier(GetString(value, "state", string.Empty), 50);
                if (type.Length > 0 && type != "backup" && type != "dry_run")
                {
                    // A kind of record this build does not draw. It stays out of every list and chart, but it is kept as it
                    // was read so that writing the history back does not delete it.
                    if (preserved.Count < MaximumHistoryRuns)
                    {
                        preserved.Add(value);
                    }
                    continue;
                }
                DateTime startedUtc;
                DateTime finishedUtc;
                if (string.IsNullOrEmpty(runId)
                    || (type != "backup" && type != "dry_run")
                    || !TryGetUtc(value, "started_utc", out startedUtc))
                {
                    continue;
                }
                if (!TryGetUtc(value, "finished_utc", out finishedUtc))
                {
                    finishedUtc = startedUtc;
                }

                RunMetricRecord metric = new RunMetricRecord();
                metric.RunId = runId;
                metric.TypeKey = type;
                metric.StateKey = state;
                metric.Success = GetBool(value, "success", false);
                metric.StartedUtc = startedUtc;
                metric.FinishedUtc = finishedUtc;
                metric.DurationSeconds = Clamp(
                    GetDouble(value, "duration_seconds", 0), 0, MaximumEtaSeconds * 2);
                metric.ResticDurationSeconds = Clamp(
                    GetDouble(value, "restic_duration_seconds", 0), 0, MaximumEtaSeconds * 2);
                metric.Files = Math.Max(0, GetLong(value, "files", 0));
                metric.ProcessedBytes = Math.Max(0, GetLong(value, "processed_bytes", 0));
                metric.StoredBytes = Math.Max(0, GetLong(value, "stored_bytes", 0));
                metric.SnapshotId = CleanIdentifier(
                    GetString(value, "snapshot_id", string.Empty), 128);
                metric.SourceFingerprint = CleanIdentifier(
                    GetString(value, "source_fingerprint", string.Empty), 128);
                result.Add(metric);
            }
            preservedHistoryRecords = preserved;

            List<RunMetricRecord> normalized = result
                .GroupBy(item => item.TypeKey + "\n" + item.RunId,
                    StringComparer.OrdinalIgnoreCase)
                .Select(group => group.OrderByDescending(item => item.FinishedUtc).First())
                .OrderByDescending(item => item.StartedUtc)
                .ToList();
            if (normalized.Count > MaximumHistoryRuns)
            {
                historyTruncated = true;
            }
            return normalized
                .Take(MaximumHistoryRuns)
                .ToList();
        }

        private void TryAtomicWriteJson(string targetPath, object value)
        {
            if (!persistenceReady || string.IsNullOrEmpty(targetPath))
            {
                return;
            }

            string targetFullPath;
            try
            {
                targetFullPath = Path.GetFullPath(targetPath);
                string parent = TrimTrailingSeparators(Path.GetDirectoryName(targetFullPath));
                if (!string.Equals(parent, TrimTrailingSeparators(dashboardDirectory),
                    StringComparison.OrdinalIgnoreCase)
                    || IsPathInside(targetFullPath, stateDirectory)
                    || (File.GetAttributes(dashboardDirectory) & FileAttributes.ReparsePoint) != 0)
                {
                    persistenceReady = false;
                    return;
                }
            }
            catch (Exception error)
            {
                if (IsExpectedIoException(error))
                {
                    persistenceReady = false;
                    return;
                }
                throw;
            }

            string temporaryPath = Path.Combine(
                dashboardDirectory,
                "." + Path.GetFileName(targetFullPath) + "."
                    + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                string json;
                try
                {
                    json = serializer.Serialize(value);
                }
                catch (InvalidOperationException)
                {
                    // Too large, or nested too deeply, to be written back (records kept from a newer build can be either): the
                    // file on disk stays exactly as it is.
                    return;
                }
                byte[] bytes = new UTF8Encoding(false).GetBytes(json);
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

                if (File.Exists(targetFullPath))
                {
                    AtomicFile.ReplaceExisting(temporaryPath, targetFullPath);
                }
                else
                {
                    try
                    {
                        File.Move(temporaryPath, targetFullPath);
                    }
                    catch (IOException)
                    {
                        if (!File.Exists(targetFullPath))
                        {
                            throw;
                        }
                        AtomicFile.ReplaceExisting(temporaryPath, targetFullPath);
                    }
                }
            }
            catch (Exception error)
            {
                if (!IsExpectedIoException(error))
                {
                    throw;
                }
            }
            finally
            {
                try
                {
                    if (File.Exists(temporaryPath))
                    {
                        File.Delete(temporaryPath);
                    }
                }
                catch (Exception error)
                {
                    if (!IsExpectedIoException(error))
                    {
                        throw;
                    }
                }
            }
        }

        private JsonReadResult ReadJsonObject(string path)
        {
            return ReadJsonObject(path, MaximumJsonLength);
        }

        private JsonReadResult ReadJsonObject(string path, int maximumLength)
        {
            if (string.IsNullOrEmpty(path))
            {
                return JsonReadResult.Missing();
            }

            Exception lastError = null;
            bool observedExisting = false;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                try
                {
                    // Asked of the file itself: File.Exists says false for a file it may not look at as well as for one that is
                    // not there. A file that is missing (or whose folder is) is nothing to report; one that is refused is a state
                    // of its own, and Windows' answer is not going to change on a second try.
                    FileAttributes attributes;
                    try
                    {
                        attributes = File.GetAttributes(path);
                    }
                    catch (FileNotFoundException)
                    {
                        return JsonReadResult.Missing();
                    }
                    catch (DirectoryNotFoundException)
                    {
                        return JsonReadResult.Missing();
                    }
                    catch (UnauthorizedAccessException)
                    {
                        return JsonReadResult.Invalid(true, 0, DateTime.MinValue,
                            "Access to the telemetry file was denied.", JsonReadResult.ReasonAccessDenied);
                    }
                    if ((attributes & FileAttributes.Directory) != 0)
                    {
                        return JsonReadResult.Missing();
                    }
                    observedExisting = true;
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        return JsonReadResult.Invalid(true, 0, DateTime.MinValue,
                            "Refusing to follow a reparse-point telemetry file.", JsonReadResult.ReasonLink);
                    }

                    string json;
                    string sha256;
                    long length;
                    using (FileStream stream = new FileStream(
                        path,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete))
                    {
                        length = stream.Length;
                        if (length > maximumLength)
                        {
                            return JsonReadResult.Invalid(true, length, DateTime.MinValue,
                                "Telemetry JSON exceeds the safety limit.", JsonReadResult.ReasonTooLarge);
                        }
                        byte[] payload = new byte[(int)length];
                        int offset = 0;
                        while (offset < payload.Length)
                        {
                            int read = stream.Read(payload, offset, payload.Length - offset);
                            if (read <= 0)
                            {
                                throw new EndOfStreamException(
                                    "Telemetry JSON changed while it was read.");
                            }
                            offset += read;
                        }
                        using (SHA256 algorithm = SHA256.Create())
                        {
                            byte[] digest = algorithm.ComputeHash(payload);
                            StringBuilder hash = new StringBuilder(64);
                            foreach (byte value in digest)
                            {
                                hash.Append(value.ToString(
                                    "x2",
                                    CultureInfo.InvariantCulture));
                            }
                            sha256 = hash.ToString();
                        }
                        using (MemoryStream memory = new MemoryStream(payload, false))
                        using (StreamReader reader = new StreamReader(
                            memory,
                            new UTF8Encoding(false, true),
                            true,
                            4096,
                            false))
                        {
                            json = reader.ReadToEnd();
                        }
                    }
                    object parsed = serializer.DeserializeObject(json);
                    IDictionary<string, object> document = parsed as IDictionary<string, object>;
                    if (document == null)
                    {
                        return JsonReadResult.Invalid(true, length, DateTime.MinValue,
                            "Telemetry JSON root is not an object.", JsonReadResult.ReasonInvalid);
                    }
                    DateTime lastWriteUtc;
                    try
                    {
                        lastWriteUtc = File.GetLastWriteTimeUtc(path);
                    }
                    catch (IOException)
                    {
                        lastWriteUtc = DateTime.MinValue;
                    }
                    return JsonReadResult.Valid(document, length, lastWriteUtc, sha256);
                }
                catch (Exception error)
                {
                    if (!IsExpectedReadException(error))
                    {
                        throw;
                    }
                    lastError = error;
                    if (attempt < 2)
                    {
                        Thread.Sleep(15 * (attempt + 1));
                    }
                }
            }

            return JsonReadResult.Invalid(
                observedExisting || File.Exists(path),
                0,
                DateTime.MinValue,
                lastError == null ? "Telemetry could not be read." : lastError.Message,
                ClassifyReadFailure(lastError));
        }

        // What a read that failed after its tries says went wrong, as a code the caller words. The exception's own text is kept
        // only for the self-test, which is for people who are debugging the reader.
        private static string ClassifyReadFailure(Exception error)
        {
            if (error is UnauthorizedAccessException || error is SecurityException)
            {
                return JsonReadResult.ReasonAccessDenied;
            }
            if (error is EndOfStreamException)
            {
                return JsonReadResult.ReasonChanging;
            }
            if (error is PathTooLongException)
            {
                return JsonReadResult.ReasonUnreadable;
            }
            if (error is IOException)
            {
                return JsonReadResult.ReasonLocked;
            }
            if (error is ArgumentException || error is InvalidOperationException || error is FormatException)
            {
                return JsonReadResult.ReasonInvalid;
            }
            return JsonReadResult.ReasonUnreadable;
        }

        private static bool TryGetResticPercent(
            IDictionary<string, object> progress,
            out double percent)
        {
            percent = 0;
            if (progress == null || !progress.ContainsKey("percent_done"))
            {
                return false;
            }
            double value = GetDouble(progress, "percent_done", -1);
            if (value > 1 && value <= 100)
            {
                value /= 100.0;
            }
            if (value <= 0 || value > 1 || double.IsNaN(value) || double.IsInfinity(value))
            {
                return false;
            }
            percent = value;
            return true;
        }

        private static IDictionary<string, object> GetDictionary(
            IDictionary<string, object> source,
            string key)
        {
            if (source == null)
            {
                return null;
            }
            object value;
            return source.TryGetValue(key, out value)
                ? value as IDictionary<string, object>
                : null;
        }

        private static IEnumerable<object> GetCollection(
            IDictionary<string, object> source,
            string key)
        {
            if (source == null)
            {
                return Enumerable.Empty<object>();
            }
            object value;
            if (!source.TryGetValue(key, out value) || value == null || value is string)
            {
                return Enumerable.Empty<object>();
            }
            object[] array = value as object[];
            if (array != null)
            {
                return array;
            }
            ArrayList list = value as ArrayList;
            if (list != null)
            {
                return list.Cast<object>();
            }
            IEnumerable enumerable = value as IEnumerable;
            return enumerable == null
                ? Enumerable.Empty<object>()
                : enumerable.Cast<object>();
        }

        private static int GetCollectionCount(
            IDictionary<string, object> source,
            string key)
        {
            return GetCollection(source, key).Take(100000).Count();
        }

        private static string GetString(
            IDictionary<string, object> source,
            string key,
            string fallback)
        {
            if (source == null)
            {
                return fallback;
            }
            object value;
            if (!source.TryGetValue(key, out value) || value == null)
            {
                return fallback;
            }
            string text = value as string;
            return text ?? Convert.ToString(value, CultureInfo.InvariantCulture) ?? fallback;
        }

        private static long GetLong(
            IDictionary<string, object> source,
            string key,
            long fallback)
        {
            if (source == null)
            {
                return fallback;
            }
            object value;
            if (!source.TryGetValue(key, out value) || value == null)
            {
                return fallback;
            }
            try
            {
                if (value is double)
                {
                    double number = (double)value;
                    if (double.IsNaN(number) || double.IsInfinity(number)
                        || number > long.MaxValue || number < long.MinValue)
                    {
                        return fallback;
                    }
                    return (long)number;
                }
                if (value is decimal)
                {
                    decimal number = (decimal)value;
                    if (number > long.MaxValue || number < long.MinValue)
                    {
                        return fallback;
                    }
                    return (long)number;
                }
                return Convert.ToInt64(value, CultureInfo.InvariantCulture);
            }
            catch (Exception error)
            {
                if (error is FormatException || error is InvalidCastException
                    || error is OverflowException)
                {
                    return fallback;
                }
                throw;
            }
        }

        private static double GetDouble(
            IDictionary<string, object> source,
            string key,
            double fallback)
        {
            if (source == null)
            {
                return fallback;
            }
            object value;
            if (!source.TryGetValue(key, out value) || value == null)
            {
                return fallback;
            }
            try
            {
                double number = Convert.ToDouble(value, CultureInfo.InvariantCulture);
                return double.IsNaN(number) || double.IsInfinity(number) ? fallback : number;
            }
            catch (Exception error)
            {
                if (error is FormatException || error is InvalidCastException
                    || error is OverflowException)
                {
                    return fallback;
                }
                throw;
            }
        }

        private static bool GetBool(
            IDictionary<string, object> source,
            string key,
            bool fallback)
        {
            if (source == null)
            {
                return fallback;
            }
            object value;
            if (!source.TryGetValue(key, out value) || value == null)
            {
                return fallback;
            }
            if (value is bool)
            {
                return (bool)value;
            }
            bool parsed;
            return bool.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), out parsed)
                ? parsed
                : fallback;
        }

        private static bool TryGetUtc(
            IDictionary<string, object> source,
            string key,
            out DateTime utc)
        {
            utc = DateTime.MinValue;
            string value = GetString(source, key, string.Empty);
            if (string.IsNullOrWhiteSpace(value))
            {
                return false;
            }
            DateTimeOffset parsed;
            if (!DateTimeOffset.TryParse(
                value,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out parsed))
            {
                return false;
            }
            utc = parsed.UtcDateTime;
            return true;
        }

        private static bool TryReadLastVerifiedFinishedUtc(
            IDictionary<string, object> document,
            out DateTime finishedUtc)
        {
            finishedUtc = DateTime.MinValue;
            if (document == null)
            {
                return false;
            }
            string state = GetString(document, "state", string.Empty).ToLowerInvariant();
            if ((state != "success" && state != "success_unchanged") ||
                !GetBool(document, "verification_complete", false))
            {
                return false;
            }
            return TryGetUtc(document, "finished_utc", out finishedUtc);
        }

        private static double DurationBetween(IDictionary<string, object> source)
        {
            DateTime start;
            DateTime finish;
            if (!TryGetUtc(source, "started_utc", out start)
                || !TryGetUtc(source, "finished_utc", out finish))
            {
                return 0;
            }
            return Math.Max(0, (finish - start).TotalSeconds);
        }

        private static long MedianLong(IEnumerable<long> values)
        {
            List<long> sorted = values.OrderBy(value => value).ToList();
            if (sorted.Count == 0)
            {
                return 0;
            }
            int middle = sorted.Count / 2;
            if ((sorted.Count & 1) == 1)
            {
                return sorted[middle];
            }
            return (long)(((decimal)sorted[middle - 1] + sorted[middle]) / 2m);
        }

        private static double Median(IEnumerable<double> values)
        {
            List<double> sorted = values
                .Where(value => !double.IsNaN(value) && !double.IsInfinity(value) && value >= 0)
                .OrderBy(value => value)
                .ToList();
            if (sorted.Count == 0)
            {
                return 0;
            }
            int middle = sorted.Count / 2;
            return (sorted.Count & 1) == 1
                ? sorted[middle]
                : (sorted[middle - 1] + sorted[middle]) / 2.0;
        }

        private static double Clamp(double value, double minimum, double maximum)
        {
            return Math.Max(minimum, Math.Min(maximum, value));
        }

        private static TimeSpan SafeTimeSpan(double seconds)
        {
            return TimeSpan.FromSeconds(Clamp(seconds, 0, MaximumEtaSeconds * 2));
        }

        private static int SafeInt(long value)
        {
            if (value > int.MaxValue)
            {
                return int.MaxValue;
            }
            if (value < int.MinValue)
            {
                return int.MinValue;
            }
            return (int)value;
        }

        private static long FirstNonNegative(long first, long second)
        {
            return first >= 0 ? first : Math.Max(0, second);
        }

        private static string FirstNonEmpty(string first, string second)
        {
            return string.IsNullOrEmpty(first) ? second : first;
        }

        private static string ShortSnapshot(string snapshotId)
        {
            if (string.IsNullOrEmpty(snapshotId))
            {
                return string.Empty;
            }
            return snapshotId.Length <= 8 ? snapshotId : snapshotId.Substring(0, 8);
        }

        private static string CleanIdentifier(string value, int maximumLength)
        {
            if (string.IsNullOrEmpty(value))
            {
                return string.Empty;
            }
            StringBuilder clean = new StringBuilder();
            foreach (char character in value)
            {
                if (character >= 32 && character != 127)
                {
                    clean.Append(character);
                }
                if (clean.Length >= maximumLength)
                {
                    break;
                }
            }
            return clean.ToString();
        }

        private static string CleanDisplayText(string value, int maximumLength)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return "No additional detail is available.";
            }
            string clean = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
            while (clean.Contains("  "))
            {
                clean = clean.Replace("  ", " ");
            }
            return clean.Length <= maximumLength
                ? clean
                : clean.Substring(0, Math.Max(0, maximumLength - 1)) + "\u2026";
        }

        private static string FormatUtc(DateTime value)
        {
            DateTime utc = value.Kind == DateTimeKind.Utc ? value : value.ToUniversalTime();
            return utc.ToString("o", CultureInfo.InvariantCulture);
        }

        private static DateTime ToLocalOrNow(DateTime utc)
        {
            return utc == DateTime.MinValue ? DateTime.Now : utc.ToLocalTime();
        }

        private static string TrimTrailingSeparators(string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                return path;
            }
            string root = Path.GetPathRoot(path);
            while (path.Length > root.Length
                && (path[path.Length - 1] == Path.DirectorySeparatorChar
                    || path[path.Length - 1] == Path.AltDirectorySeparatorChar))
            {
                path = path.Substring(0, path.Length - 1);
            }
            return path;
        }

        private static bool PathsOverlap(string first, string second)
        {
            return IsPathInside(first, second) || IsPathInside(second, first);
        }

        private static bool IsPathInside(string candidate, string directory)
        {
            if (string.IsNullOrEmpty(candidate) || string.IsNullOrEmpty(directory))
            {
                return false;
            }
            string fullCandidate = TrimTrailingSeparators(Path.GetFullPath(candidate));
            string fullDirectory = TrimTrailingSeparators(Path.GetFullPath(directory));
            if (string.Equals(fullCandidate, fullDirectory, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            return fullCandidate.StartsWith(
                fullDirectory + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsExpectedReadException(Exception error)
        {
            return IsExpectedIoException(error)
                || error is InvalidOperationException
                || error is FormatException;
        }

        private static bool IsExpectedIoException(Exception error)
        {
            return error is IOException
                || error is UnauthorizedAccessException
                || error is SecurityException
                || error is NotSupportedException
                || error is ArgumentException;
        }
    }

    internal sealed class JsonReadResult
    {
        // Why a file that is there could not be used, as a code for the caller to word. The exception's own text (in Error) can
        // name a path or quote a fragment of the file, so it is never what a person is shown.
        public const string ReasonLocked = "locked";
        public const string ReasonChanging = "changing";
        public const string ReasonInvalid = "invalid_json";
        public const string ReasonTooLarge = "too_large";
        public const string ReasonLink = "reparse_point";
        public const string ReasonAccessDenied = "access_denied";
        public const string ReasonUnreadable = "unreadable";
        // Evidence that is there but is no longer read at all (the old local-mirror off-site status).
        public const string ReasonRetired = "retired";

        public bool Exists { get; private set; }
        public IDictionary<string, object> Document { get; private set; }
        public long Length { get; private set; }
        public DateTime LastWriteUtc { get; private set; }
        public string Sha256 { get; private set; }
        public string Error { get; private set; }
        public string Reason { get; private set; }

        // A failure that is usually over by the next read (a file held for a moment, or still being written), as opposed to a
        // refusal (a link, a size limit, a permission) or a file that is simply not what it should be.
        public bool IsTransient
        {
            get
            {
                return Reason == ReasonLocked || Reason == ReasonChanging
                    || Reason == ReasonInvalid || Reason == ReasonUnreadable;
            }
        }

        public static JsonReadResult Missing()
        {
            return new JsonReadResult
            {
                Exists = false,
                Length = 0,
                LastWriteUtc = DateTime.MinValue,
                Sha256 = string.Empty,
                Error = string.Empty,
                Reason = string.Empty
            };
        }

        public static JsonReadResult Valid(
            IDictionary<string, object> document,
            long length,
            DateTime lastWriteUtc,
            string sha256)
        {
            return new JsonReadResult
            {
                Exists = true,
                Document = document,
                Length = length,
                LastWriteUtc = lastWriteUtc,
                Sha256 = sha256 ?? string.Empty,
                Error = string.Empty,
                Reason = string.Empty
            };
        }

        public static JsonReadResult Invalid(
            bool exists,
            long length,
            DateTime lastWriteUtc,
            string error)
        {
            return Invalid(exists, length, lastWriteUtc, error, ReasonUnreadable);
        }

        public static JsonReadResult Invalid(
            bool exists,
            long length,
            DateTime lastWriteUtc,
            string error,
            string reason)
        {
            return new JsonReadResult
            {
                Exists = exists,
                Length = length,
                LastWriteUtc = lastWriteUtc,
                Sha256 = string.Empty,
                Error = error ?? "Telemetry JSON is invalid.",
                Reason = reason ?? ReasonUnreadable
            };
        }
    }

    internal sealed class PhaseInfo
    {
        public int Index { get; private set; }
        public int Stage { get; private set; }
        public string PhaseLabel { get; private set; }
        public string StatusLabel { get; private set; }

        public PhaseInfo(int index, int stage, string phaseLabel, string statusLabel)
        {
            Index = index;
            Stage = stage;
            PhaseLabel = phaseLabel;
            StatusLabel = statusLabel;
        }
    }

    internal sealed class EstimateBaseline
    {
        public int SampleCount { get; set; }
        public bool DryRunOnly { get; set; }
        public bool UsesComparableRuns { get; set; }
        public long Files { get; set; }
        public long Bytes { get; set; }
        public double TotalDurationSeconds { get; set; }
        public double ResticDurationSeconds { get; set; }
        public double PostProcessingSeconds { get; set; }
    }

    internal sealed class RunMetricRecord
    {
        public string RunId { get; set; }
        public string TypeKey { get; set; }
        public string StateKey { get; set; }
        public bool Success { get; set; }
        public DateTime StartedUtc { get; set; }
        public DateTime FinishedUtc { get; set; }
        public double DurationSeconds { get; set; }
        public double ResticDurationSeconds { get; set; }
        public long Files { get; set; }
        public long ProcessedBytes { get; set; }
        public long StoredBytes { get; set; }
        public string SnapshotId { get; set; }
        public string SourceFingerprint { get; set; }
    }
}
