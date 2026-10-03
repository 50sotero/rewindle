using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal sealed class DiagnosticExportResult
    {
        public bool Succeeded { get; private set; }
        public string ExportPath { get; private set; }
        public string ErrorMessage { get; private set; }

        internal static DiagnosticExportResult Success(string path)
        {
            return new DiagnosticExportResult { Succeeded = true, ExportPath = path };
        }

        internal static DiagnosticExportResult Failure(string error)
        {
            return new DiagnosticExportResult
            {
                ErrorMessage = string.IsNullOrWhiteSpace(error)
                    ? "The diagnostic bundle could not be exported safely."
                    : error
            };
        }
    }

    internal static class DiagnosticExporter
    {
        private const int MaximumJsonBytes = 4 * 1024 * 1024;
        private const int MaximumLogTailBytes = 2 * 1024 * 1024;
        private const int MaximumCrashLogBytes = 64 * 1024;
        private const int MaximumLogEvents = 300;
        private const int MaximumArchiveEntries = 24;

        internal static DiagnosticExportResult Export(
            SourceConfiguration configuration,
            TaskSchedule schedule,
            TelemetrySnapshot snapshot,
            string destination)
        {
            if (configuration == null)
                return DiagnosticExportResult.Failure(
                    "The protected configuration is unavailable.");
            string temporary = string.Empty;
            try
            {
                string target = ValidateDestination(configuration, destination);
                if (File.Exists(target) || Directory.Exists(target))
                    return DiagnosticExportResult.Failure(
                        "Choose a new ZIP filename. Existing files are never overwritten by diagnostic export.");

                IDictionary<string, object> rawConfiguration = ReadRequiredObject(
                    configuration.ConfigurationPath);
                DiagnosticRedactor redactor = new DiagnosticRedactor(
                    configuration,
                    rawConfiguration);
                Dictionary<string, object> documents = new Dictionary<string, object>(
                    StringComparer.Ordinal);
                // Every document that could not go in, and why (a fixed code, never an exception's words). A file that is locked or
                // damaged used to be left out without a word, which made a bundle with a gap look like a complete one.
                List<object> skipped = new List<object>();
                documents["configuration.json"] = redactor.Sanitize(
                    rawConfiguration,
                    "configuration");
                AddProtectedDocument(
                    documents,
                    redactor,
                    skipped,
                    "status.json",
                    Path.Combine(configuration.StateDirectory, "status.json"));
                AddProtectedDocument(
                    documents,
                    redactor,
                    skipped,
                    "last-success.json",
                    Path.Combine(configuration.StateDirectory, "last-success.json"));
                AddProtectedDocument(
                    documents,
                    redactor,
                    skipped,
                    "dry-run-latest.json",
                    Path.Combine(configuration.StateDirectory, "dry-run-latest.json"));
                AddProtectedDocument(
                    documents,
                    redactor,
                    skipped,
                    "recovery-health-latest.json",
                    Path.Combine(configuration.StateDirectory, "recovery-health-latest.json"));
                string protectedOffsiteStatus = Path.Combine(
                    configuration.StateDirectory,
                    "google-drive-sync-status.json");
                // The active engine's protected direct-cloud proof (empty when ProgramData cannot be located).
                string directCloudVerification = EngineProfile.Current.CloudVerificationProofPath();
                AddProtectedDocument(
                    documents,
                    redactor,
                    skipped,
                    "my-drive-latest-verification.json",
                    directCloudVerification);
                AddProtectedDocument(
                    documents,
                    redactor,
                    skipped,
                    "legacy-google-drive-sync-status.json",
                    protectedOffsiteStatus);
                AddProtectedDocument(
                    documents,
                    redactor,
                    skipped,
                    "runtime-manifest.json",
                    Path.Combine(configuration.InstallRoot, "runtime-manifest.json"));

                documents["schedule.json"] = redactor.Sanitize(
                    BuildSchedule(schedule),
                    "schedule");
                documents["dashboard-state.json"] = redactor.Sanitize(
                    BuildDashboardState(snapshot),
                    "dashboard_state");
                string logSkipReason;
                object logEvents = BuildLatestLogEvents(configuration, snapshot, out logSkipReason);
                if (logEvents != null)
                {
                    redactor.Observe(logEvents);
                    documents["latest-run-log-events.json"] = redactor.Sanitize(
                        logEvents,
                        "log_events");
                }
                else
                {
                    skipped.Add(SkippedDocument("latest-run-log-events.json", logSkipReason));
                }
                object selfTest = BuildTelemetrySelfTest(configuration, redactor);
                if (selfTest != null)
                {
                    documents["telemetry-self-test.json"] = selfTest;
                }
                else
                {
                    skipped.Add(SkippedDocument("telemetry-self-test.json", "not_available"));
                }
                object crashLog = BuildCrashLog(redactor);
                if (crashLog != null)
                {
                    documents["crash-log.json"] = crashLog;
                }

                Dictionary<string, object> manifest = new Dictionary<string, object>();
                manifest["schema"] = EngineProfile.Current.DiagnosticsSchema;
                manifest["schema_version"] = 1;
                // Which engine this bundle describes: a fixed profile id and name, and the version the engine's own
                // version file states (validated, or a fixed word), so none of them can carry a path or an identity.
                manifest["engine_profile"] = EngineProfile.Current.Id;
                manifest["engine_name"] = EngineProfile.Current.DisplayName;
                manifest["engine_version"] = EngineProfile.Current.ReadEngineVersion();
                manifest["created_utc"] = DateTime.UtcNow.ToString(
                    "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
                    CultureInfo.InvariantCulture);
                manifest["dashboard_version"] = Assembly.GetExecutingAssembly()
                    .GetName().Version.ToString();
                manifest["operating_system"] = Environment.OSVersion.VersionString;
                manifest["process_architecture"] = Environment.Is64BitProcess
                    ? "x64"
                    : "x86";
                manifest["timezone"] = TimeZoneInfo.Local.Id;
                manifest["identity_redacted"] = true;
                manifest["paths_redacted"] = true;
                manifest["secrets_included"] = false;
                manifest["repository_modified"] = false;
                manifest["snapshots_modified"] = false;
                manifest["entries"] = documents.Keys.OrderBy(item => item).ToArray();
                manifest["skipped_documents"] = skipped;
                documents["manifest.json"] = redactor.Sanitize(manifest, "manifest");
                documents["redaction-report.json"] = redactor.Report();

                if (documents.Count > MaximumArchiveEntries)
                    throw new InvalidDataException("The diagnostic bundle entry limit was exceeded.");

                JavaScriptSerializer serializer = Serializer();
                Dictionary<string, string> payloads = new Dictionary<string, string>(
                    StringComparer.Ordinal);
                foreach (KeyValuePair<string, object> document in documents)
                {
                    string json = serializer.Serialize(document.Value);
                    try
                    {
                        redactor.AssertSafe(json);
                    }
                    catch (InvalidDataException error)
                    {
                        throw new InvalidDataException(
                            document.Key + ": " + error.Message,
                            error);
                    }
                    payloads[document.Key] = PrettyJson(json);
                }

                string directory = Path.GetDirectoryName(target);
                temporary = Path.Combine(
                    directory,
                    "." + Path.GetFileName(target) + ".partial-" +
                    Guid.NewGuid().ToString("N"));
                using (FileStream stream = new FileStream(
                    temporary,
                    FileMode.CreateNew,
                    FileAccess.ReadWrite,
                    FileShare.None))
                using (ZipArchive archive = new ZipArchive(
                    stream,
                    ZipArchiveMode.Create,
                    false,
                    Encoding.UTF8))
                {
                    foreach (KeyValuePair<string, string> payload in payloads.OrderBy(
                        item => item.Key,
                        StringComparer.Ordinal))
                    {
                        WriteEntry(archive, payload.Key, payload.Value);
                    }
                    WriteEntry(
                        archive,
                        "README.txt",
                        "Rewindle diagnostics: a redacted support bundle\r\n\r\n" +
                        "Personal paths (with the file and folder names under them), Windows identities and account IDs, host names, command lines, and credential-like values are removed. " +
                        "manifest.json lists every document that could not be included, and why (skipped_documents), and telemetry-self-test.json shows what Rewindle could read from the backup's state folder. " +
                        "This export is read-only and does not modify the repository or snapshots.\r\n");
                }
                File.Move(temporary, target);
                temporary = string.Empty;
                return DiagnosticExportResult.Success(target);
            }
            catch (Exception error)
            {
                return DiagnosticExportResult.Failure(SanitizeError(error.Message));
            }
            finally
            {
                if (!string.IsNullOrEmpty(temporary))
                {
                    try
                    {
                        if (File.Exists(temporary)) File.Delete(temporary);
                    }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
            }
        }

        // The destination rules, in one place: the export checks them when it starts, and the Save dialog checks them before it
        // closes (so a refusal is read while the person can still choose another folder, not after the name is typed and the
        // work is waiting). Throws with the reason in plain words.
        internal static string ValidateDestination(
            SourceConfiguration configuration,
            string destination)
        {
            if (string.IsNullOrWhiteSpace(destination) || !Path.IsPathRooted(destination))
                throw new InvalidDataException("Choose an absolute diagnostic ZIP path.");
            string target = SourceConfiguration.NormalizePath(destination);
            if (!string.Equals(
                Path.GetExtension(target),
                ".zip",
                StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The diagnostic export must use a .zip filename.");
            string parent = Path.GetDirectoryName(target);
            if (string.IsNullOrWhiteSpace(parent) || !Directory.Exists(parent))
                throw new DirectoryNotFoundException(
                    "The diagnostic export folder does not exist.");
            DirectoryInfo current = new DirectoryInfo(parent);
            while (current != null)
            {
                if ((current.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException(
                        "Diagnostic export refuses reparse-point destination folders.");
                current = current.Parent;
            }

            List<string> protectedPaths = new List<string>
            {
                configuration.InstallRoot,
                configuration.StateDirectory,
                configuration.RepositoryPath
            };
            protectedPaths.AddRange(configuration.Sources.Select(item => item.SourcePath));
            foreach (string protectedPath in protectedPaths)
            {
                if (PathsOverlap(target, protectedPath))
                    throw new InvalidDataException(
                        "The support bundle cannot be saved inside a protected folder, the backup location or the backup service's own folders. Choose a folder outside them.");
            }
            return target;
        }

        private static bool PathsOverlap(string first, string second)
        {
            string left = SourceConfiguration.NormalizePath(first);
            string right = SourceConfiguration.NormalizePath(second);
            if (string.Equals(left, right, StringComparison.OrdinalIgnoreCase)) return true;
            string leftPrefix = left.TrimEnd(Path.DirectorySeparatorChar) +
                Path.DirectorySeparatorChar;
            string rightPrefix = right.TrimEnd(Path.DirectorySeparatorChar) +
                Path.DirectorySeparatorChar;
            return leftPrefix.StartsWith(rightPrefix, StringComparison.OrdinalIgnoreCase) ||
                rightPrefix.StartsWith(leftPrefix, StringComparison.OrdinalIgnoreCase);
        }

        private static void AddProtectedDocument(
            IDictionary<string, object> documents,
            DiagnosticRedactor redactor,
            ICollection<object> skipped,
            string name,
            string path)
        {
            string reason;
            IDictionary<string, object> document = TryReadObject(path, out reason);
            if (document != null)
            {
                redactor.Observe(document);
                documents[name] = redactor.Sanitize(document, name);
            }
            else
            {
                skipped.Add(SkippedDocument(name, reason));
            }
        }

        // One entry of manifest.json's skipped_documents: the document's name and a fixed reason code, nothing else.
        private static IDictionary<string, object> SkippedDocument(string name, string reason)
        {
            Dictionary<string, object> entry = new Dictionary<string, object>();
            entry["name"] = name;
            entry["reason"] = string.IsNullOrEmpty(reason) ? "missing" : reason;
            return entry;
        }

        private static IDictionary<string, object> ReadRequiredObject(string path)
        {
            IDictionary<string, object> document = TryReadObject(path);
            if (document == null)
                throw new InvalidDataException(
                    "The protected configuration could not be read for diagnostic export.");
            return document;
        }

        private static IDictionary<string, object> TryReadObject(string path)
        {
            string reason;
            return TryReadObject(path, out reason);
        }

        // `reason` says why nothing came back: missing, locked, access_denied, invalid_json, too_large or reparse_point. The file is
        // read with the sharing a writer allows (one that is being rewritten right now is the usual reason a document used to go
        // missing from a bundle), and a locked or half-written one is tried twice more a moment later before it is given up on.
        private static IDictionary<string, object> TryReadObject(string path, out string reason)
        {
            reason = "missing";
            if (string.IsNullOrEmpty(path)) return null;
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    FileAttributes attributes;
                    try
                    {
                        attributes = File.GetAttributes(path);
                    }
                    catch (FileNotFoundException)
                    {
                        reason = "missing";
                        return null;
                    }
                    catch (DirectoryNotFoundException)
                    {
                        reason = "missing";
                        return null;
                    }
                    if ((attributes & FileAttributes.Directory) != 0)
                    {
                        reason = "missing";
                        return null;
                    }
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        reason = "reparse_point";
                        return null;
                    }
                    string json;
                    using (FileStream stream = new FileStream(
                        path,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete))
                    {
                        if (stream.Length > MaximumJsonBytes)
                        {
                            reason = "too_large";
                            return null;
                        }
                        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true, 4096, true))
                        {
                            json = reader.ReadToEnd();
                        }
                    }
                    IDictionary<string, object> document = Serializer().DeserializeObject(json)
                        as IDictionary<string, object>;
                    if (document == null)
                    {
                        reason = "invalid_json";
                        return null;
                    }
                    reason = string.Empty;
                    return document;
                }
                catch (UnauthorizedAccessException)
                {
                    // Windows' answer to who may read a file does not change a moment later.
                    reason = "access_denied";
                    return null;
                }
                catch (IOException) { reason = "locked"; }
                catch (ArgumentException) { reason = "invalid_json"; }
                catch (InvalidOperationException) { reason = "invalid_json"; }
                if (attempt >= 2) return null;
                Thread.Sleep(30 * (attempt + 1));
            }
        }

        private static IDictionary<string, object> BuildSchedule(TaskSchedule schedule)
        {
            Dictionary<string, object> value = new Dictionary<string, object>();
            value["available"] = schedule != null;
            if (schedule == null) return value;
            value["cadence"] = schedule.Cadence.ToString();
            value["time_of_day"] = schedule.TimeOfDay.ToString(@"hh\:mm", CultureInfo.InvariantCulture);
            value["days"] = schedule.Days.Select(item => item.ToString()).ToArray();
            value["enabled"] = schedule.Enabled;
            value["start_when_available"] = schedule.StartWhenAvailable;
            value["wake_to_run"] = schedule.WakeToRun;
            value["allow_start_on_batteries"] = schedule.AllowStartOnBatteries;
            value["stop_if_going_on_batteries"] = schedule.StopIfGoingOnBatteries;
            value["state"] = schedule.State.ToString();
            value["next_run_local"] = schedule.NextRunTime.HasValue
                ? schedule.NextRunTime.Value.ToString("o", CultureInfo.InvariantCulture)
                : null;
            return value;
        }

        private static IDictionary<string, object> BuildDashboardState(
            TelemetrySnapshot snapshot)
        {
            Dictionary<string, object> value = new Dictionary<string, object>();
            value["available"] = snapshot != null;
            if (snapshot == null) return value;
            value["state"] = snapshot.StateKey;
            value["status"] = snapshot.StatusLabel;
            value["detail"] = snapshot.StatusDetail;
            value["active"] = snapshot.IsActive;
            value["success"] = snapshot.IsSuccess;
            value["failure"] = snapshot.IsFailure;
            value["status_unavailable"] = snapshot.IsStatusUnavailable;
            value["cancelled"] = snapshot.IsCancelled;
            value["maintenance_hold"] = snapshot.HasMaintenanceHold;
            value["anomaly_review_acknowledged"] = snapshot.AnomalyReviewAcknowledged;
            OffsiteStatusView offsite = snapshot.OffsiteStatus;
            if (offsite != null)
            {
                value["offsite_copy"] = new Dictionary<string, object>
                {
                    { "kind", offsite.Kind.ToString() },
                    { "status", offsite.StatusLabel },
                    { "detail", offsite.StatusDetail },
                    { "plan_id", offsite.PlanId },
                    { "config_generation", offsite.ConfigGeneration },
                    { "repository_id", offsite.RepositoryId },
                    { "repository_path", offsite.RepositoryPath },
                    { "snapshot_id", offsite.SnapshotId },
                    {
                        "inventory_fingerprint_sha256",
                        offsite.InventoryFingerprintSha256
                    },
                    { "files", offsite.FileCount },
                    { "bytes", offsite.ByteCount },
                    { "provider_upload_confirmed", offsite.ProviderUploadConfirmed },
                    { "restore_verified", offsite.RestoreVerified },
                    {
                        "updated_local",
                        offsite.LastUpdatedLocal.HasValue
                            ? offsite.LastUpdatedLocal.Value.ToString(
                                "o",
                                CultureInfo.InvariantCulture)
                            : null
                    }
                };
            }
            value["run_id"] = snapshot.RunId;
            value["snapshot_id"] = snapshot.SnapshotId;
            value["files"] = snapshot.FilesDone;
            value["processed_bytes"] = snapshot.BytesDone;
            value["stored_bytes"] = snapshot.StoredBytes;
            value["errors"] = snapshot.ErrorCount;
            value["phase"] = snapshot.PhaseLabel;
            value["last_verified_utc"] = snapshot.LastVerifiedFinishedUtc.HasValue
                ? snapshot.LastVerifiedFinishedUtc.Value.ToString("o", CultureInfo.InvariantCulture)
                : null;
            return value;
        }

        // `skipReason` is why there is no document (a fixed code for manifest.json), and is empty when there is one.
        private static object BuildLatestLogEvents(
            SourceConfiguration configuration,
            TelemetrySnapshot snapshot,
            out string skipReason)
        {
            skipReason = "missing";
            if (snapshot == null || !ValidRunId(snapshot.RunId)) return null;
            string path = Path.Combine(
                configuration.StateDirectory,
                "logs",
                "backup-" + snapshot.RunId + ".jsonl.log");
            if (!File.Exists(path) || Directory.Exists(path)) return null;
            FileInfo file = new FileInfo(path);
            if ((file.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                skipReason = "reparse_point";
                return null;
            }
            if (file.Length <= 0) return null;
            skipReason = string.Empty;
            List<object> events = new List<object>();
            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                bool truncated = stream.Length > MaximumLogTailBytes;
                if (truncated)
                {
                    stream.Seek(-MaximumLogTailBytes, SeekOrigin.End);
                    // The cut lands on an arbitrary byte, which can be in the middle of a multi-byte character. Raw bytes are
                    // skipped to the end of the line it fell in (a continuation byte is never a line feed), so decoding starts
                    // on a whole line, and the decoder is never given half a character to choke on.
                    int next;
                    while ((next = stream.ReadByte()) != -1 && next != 0x0A)
                    {
                    }
                }
                // Replacement characters rather than an exception for a byte that is not text: the log is for reading, and one
                // bad byte must not cost the whole bundle. A line that is not JSON is skipped below, as it always was.
                using (StreamReader reader = new StreamReader(
                    stream,
                    new UTF8Encoding(false, false),
                    true,
                    4096,
                    false))
                {
                    string line;
                    while ((line = reader.ReadLine()) != null)
                    {
                        if (line.Length <= 0 || line.Length > 1024 * 1024) continue;
                        IDictionary<string, object> document;
                        try
                        {
                            document = Serializer().DeserializeObject(line)
                                as IDictionary<string, object>;
                        }
                        catch (ArgumentException) { continue; }
                        catch (InvalidOperationException) { continue; }
                        if (document == null) continue;
                        document.Remove("command");
                        document.Remove("traceback");
                        events.Add(document);
                        if (events.Count > MaximumLogEvents)
                            events.RemoveAt(0);
                    }
                }
            }
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["schema_version"] = 1;
            result["tail_truncated"] = file.Length > MaximumLogTailBytes;
            result["events"] = events;
            return result;
        }

        // The newest part of the dashboard's own crash.log (see CrashLog), so a bug report carries what the app wrote when it failed. It
        // gets the redaction and the self-check every other document gets, and is the one document that is left out, instead of failing
        // the whole export, when it cannot be made safe: it is made of whatever an exception happened to say, which nothing vets.
        private static object BuildCrashLog(DiagnosticRedactor redactor)
        {
            try
            {
                string path = CrashLog.FilePath;
                if (string.IsNullOrEmpty(path) || !File.Exists(path) || Directory.Exists(path)) return null;
                FileInfo file = new FileInfo(path);
                if ((file.Attributes & FileAttributes.ReparsePoint) != 0 || file.Length <= 0) return null;
                List<string> lines = new List<string>();
                bool truncated;
                using (FileStream stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                {
                    truncated = stream.Length > MaximumCrashLogBytes;
                    if (truncated) stream.Seek(-MaximumCrashLogBytes, SeekOrigin.End);
                    using (StreamReader reader = new StreamReader(
                        stream,
                        new UTF8Encoding(false, false),
                        true,
                        4096,
                        false))
                    {
                        // A cut tail starts part-way through a line.
                        if (truncated) reader.ReadLine();
                        string line;
                        while ((line = reader.ReadLine()) != null) lines.Add(line);
                    }
                }
                Dictionary<string, object> document = new Dictionary<string, object>();
                document["schema_version"] = 1;
                document["tail_truncated"] = truncated;
                document["lines"] = lines;
                object clean = redactor.Sanitize(document, "crash_log");
                redactor.AssertSafe(Serializer().Serialize(clean));
                return clean;
            }
            catch (Exception)
            {
                return null;
            }
        }

        // What the telemetry reader finds in the backup's state folder, file by file (there or not, valid JSON or not, how big, and
        // what stopped it), so a document that is missing from the bundle can be explained from the bundle itself. It is the
        // reader's own self-test, run on the same folder, and it holds absolute paths, so it gets the redaction and the self-check
        // every other document gets. Like the crash log, it is left out rather than failing the whole export when it cannot be made
        // safe; manifest.json then says it is missing.
        private static object BuildTelemetrySelfTest(SourceConfiguration configuration, DiagnosticRedactor redactor)
        {
            try
            {
                string json = new TelemetryReader(configuration.StateDirectory, false).SelfTestJson();
                IDictionary<string, object> document = Serializer().DeserializeObject(json)
                    as IDictionary<string, object>;
                if (document == null) return null;
                redactor.Observe(document);
                object clean = redactor.Sanitize(document, "self_test");
                redactor.AssertSafe(Serializer().Serialize(clean));
                return clean;
            }
            catch (Exception)
            {
                return null;
            }
        }

        private static void WriteEntry(ZipArchive archive, string name, string content)
        {
            ZipArchiveEntry entry = archive.CreateEntry(name, CompressionLevel.Optimal);
            using (Stream stream = entry.Open())
            using (StreamWriter writer = new StreamWriter(
                stream,
                new UTF8Encoding(false),
                4096,
                false))
            {
                writer.Write(content ?? string.Empty);
            }
        }

        private static JavaScriptSerializer Serializer()
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = MaximumJsonBytes;
            serializer.RecursionLimit = 100;
            return serializer;
        }

        private static string PrettyJson(string compact)
        {
            // JavaScriptSerializer has no indented mode. A valid compact payload is
            // deterministic, smaller, and avoids a second untrusted parse.
            return compact + Environment.NewLine;
        }

        private static bool ValidRunId(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length > 100) return false;
            foreach (char item in value)
            {
                if (!(char.IsLetterOrDigit(item) || item == '-' || item == '_' ||
                    item == '.' || item == '+')) return false;
            }
            return true;
        }

        private static string SanitizeError(string message)
        {
            string value = string.IsNullOrWhiteSpace(message)
                ? "Diagnostic export failed."
                : message.Trim();
            if (value.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("dpapi", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("RESTIC_", StringComparison.OrdinalIgnoreCase) >= 0)
                return "Diagnostic export failed without exposing credential details.";
            return value.Length > 1000 ? value.Substring(0, 1000) : value;
        }
    }

    internal sealed class DiagnosticRedactor
    {
        private static readonly Regex DrivePath = new Regex(
            "(?i)[a-z]:\\\\[^\\r\\n\\\";]*",
            RegexOptions.CultureInvariant);
        private static readonly Regex UncPath = new Regex(
            "\\\\\\\\[^\\\\\\s]+\\\\[^\\r\\n\\\";]*",
            RegexOptions.CultureInvariant);
        private static readonly Regex Email = new Regex(
            @"(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b",
            RegexOptions.CultureInvariant);
        private static readonly Regex LongToken = new Regex(
            @"\b[A-Za-z0-9+/=]{97,}\b",
            RegexOptions.CultureInvariant);
        // A Windows security identifier (S-1-5-21-...), which names an account as surely as its user name does. The
        // short well-known ones (S-1-5-18) are not personal and are left alone.
        private static readonly Regex Sid = new Regex(
            @"(?<![A-Za-z0-9])S-1-[0-9]+(?:-[0-9]+){2,}(?![0-9A-Za-z])",
            RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
        // The start of a path in free text: a drive letter and a slash of either kind, or two slashes and a server name. A
        // drive letter that closes a word ("https:/") is not one when the slash leans forward; with a backslash it always is.
        private const string PathStart =
            @"(?:[A-Za-z]:\\|(?<![A-Za-z0-9])[A-Za-z]:/|\\\\[^\\/\s""]+[\\/]|(?<![:A-Za-z0-9\\/])//[^\\/\s""]+[\\/])";
        // A whole path: its start, then everything up to a quote, a semicolon, the end of the line, or a colon that is
        // followed by a space or by nothing (the ": Access is denied." an error message puts after the path). A colon
        // inside the path ("\\?\C:\") belongs to it, and so does an apostrophe inside a word ("Bob's Files"). A path can
        // hold spaces, so words that follow it without one of those separators are taken with it.
        private static readonly Regex AnyPath = new Regex(
            PathStart + @"(?:[^\r\n"";:']|:(?!\s|\z)|'(?=[A-Za-z0-9]))*",
            RegexOptions.CultureInvariant);
        // What the self-check adds for paths written with forward slashes: the backslash forms are the two patterns above.
        private static readonly Regex ForwardSlashPath = new Regex(
            @"(?<![A-Za-z0-9])[A-Za-z]:/|(?<![:A-Za-z0-9\\/])//[^\\/\s""]+[\\/]",
            RegexOptions.CultureInvariant);

        private readonly List<KeyValuePair<string, string>> replacements =
            new List<KeyValuePair<string, string>>();
        // The places a path can be under (the runtime, the state, the repository, each protected folder, the profile), written
        // with backslashes and longest first, so a path keeps the name of the place it was in.
        private readonly List<KeyValuePair<string, string>> pathRoots =
            new List<KeyValuePair<string, string>>();
        private readonly HashSet<string> secretValues = new HashSet<string>(
            StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> identityTokens =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private int pathRedactions;
        private int secretRedactions;
        private int identityRedactions;
        private int tokenRedactions;

        internal DiagnosticRedactor(
            SourceConfiguration configuration,
            IDictionary<string, object> rawConfiguration)
        {
            AddReplacement(Environment.UserName, "<windows-user>");
            AddReplacement(Environment.MachineName, "<computer>");
            AddPath(Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile), "<user-profile>");
            AddPath(configuration.InstallRoot, "<runtime-path>");
            AddPath(configuration.StateDirectory, "<state-path>");
            AddPath(configuration.RepositoryPath, "<repository-path>");
            AddPath(configuration.ConfigurationPath, "<configuration-path>");
            int source = 0;
            foreach (BackupSourceView item in configuration.Sources)
            {
                source++;
                AddPath(item.SourcePath, "<source-path:" +
                    source.ToString(CultureInfo.InvariantCulture) + ">");
            }
            DiscoverSensitiveValues(rawConfiguration, string.Empty);
            SortReplacements();
        }

        internal void Observe(object value)
        {
            DiscoverSensitiveValues(value, string.Empty);
            SortReplacements();
        }

        internal object Sanitize(object value, string key)
        {
            if (value == null) return null;
            IDictionary<string, object> dictionary = value as IDictionary<string, object>;
            if (dictionary != null)
            {
                Dictionary<string, object> clean = new Dictionary<string, object>();
                foreach (KeyValuePair<string, object> item in dictionary)
                {
                    // Keys can carry paths too (source_identities is keyed by every protected folder),
                    // so they are scrubbed like values. Decisions about the value still use the original
                    // key, and originals that scrub to the same text stay distinct.
                    clean[UniqueKey(clean, SanitizeString(item.Key))] =
                        SanitizeValue(item.Value, item.Key);
                }
                return clean;
            }
            IEnumerable sequence = value as IEnumerable;
            if (sequence != null && !(value is string))
            {
                List<object> clean = new List<object>();
                foreach (object item in sequence) clean.Add(Sanitize(item, key));
                return clean;
            }
            return SanitizeValue(value, key);
        }

        private static string UniqueKey(IDictionary<string, object> existing, string key)
        {
            if (!existing.ContainsKey(key)) return key;
            int suffix = 2;
            while (existing.ContainsKey(key + "#" + suffix.ToString(CultureInfo.InvariantCulture)))
                suffix++;
            return key + "#" + suffix.ToString(CultureInfo.InvariantCulture);
        }

        internal IDictionary<string, object> Report()
        {
            Dictionary<string, object> value = new Dictionary<string, object>();
            value["schema_version"] = 1;
            value["paths_redacted"] = pathRedactions;
            value["secrets_redacted"] = secretRedactions;
            value["identities_redacted"] = identityRedactions;
            value["long_tokens_redacted"] = tokenRedactions;
            value["original_values_included"] = false;
            value["command_lines_included"] = false;
            return value;
        }

        internal void AssertSafe(string payload)
        {
            foreach (KeyValuePair<string, string> replacement in replacements)
            {
                if (payload.IndexOf(replacement.Key, StringComparison.OrdinalIgnoreCase) >= 0)
                    throw new InvalidDataException(
                        "Diagnostic redaction self-check found an original identity or path for " +
                        replacement.Value + ".");
            }
            foreach (string secret in secretValues)
            {
                if (payload.IndexOf(secret, StringComparison.OrdinalIgnoreCase) >= 0)
                    throw new InvalidDataException(
                        "Diagnostic redaction self-check found a protected value.");
            }
            // The payload is JSON, which writes every backslash twice. A redacted path that keeps its tail,
            // like "<state-path>\logs\run.log", therefore has two backslashes in a row in the text. Read
            // it back as the strings read before looking for a UNC path, so only a real "\\server\share"
            // counts and not the doubled separators of a safe remainder.
            string readable = payload.Replace("\\\\", "\\");
            if (DrivePath.IsMatch(payload) || UncPath.IsMatch(readable) ||
                ForwardSlashPath.IsMatch(payload) || Sid.IsMatch(payload) ||
                Email.IsMatch(payload) || LongToken.IsMatch(payload))
                throw new InvalidDataException(
                    "Diagnostic redaction self-check found an unredacted path, identity, or token.");
        }

        private object SanitizeValue(object value, string key)
        {
            if (value == null) return null;
            if (SensitiveKey(key))
            {
                secretRedactions++;
                return "<redacted>";
            }
            if (value is IDictionary<string, object> ||
                (value is IEnumerable && !(value is string)))
            {
                return Sanitize(value, key);
            }
            string text = value as string;
            if (text == null) return value;
            if (IdentityKey(key))
            {
                identityRedactions++;
                return IdentityToken(key, text);
            }
            return SanitizeString(text);
        }

        private string SanitizeString(string value)
        {
            string result = value ?? string.Empty;
            foreach (string secret in secretValues.OrderByDescending(item => item.Length))
            {
                if (secret.Length < 4) continue;
                result = ReplaceIgnoreCase(result, secret, "<redacted>", ref secretRedactions);
            }
            // A path goes whole, before the names below are swapped for their tokens: a root that is only replaced would leave
            // every file and folder name under it in the text.
            result = AnyPath.Replace(result, ReplacePath);
            foreach (KeyValuePair<string, string> replacement in replacements)
            {
                int before = result.Length;
                string next = Regex.Replace(
                    result,
                    Regex.Escape(replacement.Key),
                    replacement.Value.Replace("$", "$$"),
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
                if (!string.Equals(result, next, StringComparison.Ordinal))
                {
                    if (replacement.Value.IndexOf("path", StringComparison.OrdinalIgnoreCase) >= 0)
                        pathRedactions++;
                    else
                        identityRedactions++;
                }
                result = next;
            }
            result = CountedReplace(DrivePath, result, "<windows-path>", ref pathRedactions);
            result = CountedReplace(UncPath, result, "<network-path>", ref pathRedactions);
            result = CountedReplace(Sid, result, "<sid>", ref identityRedactions);
            result = CountedReplace(Email, result, "<email>", ref identityRedactions);
            result = CountedReplace(LongToken, result, "<long-token>", ref tokenRedactions);
            return result;
        }

        private void DiscoverSensitiveValues(object value, string key)
        {
            IDictionary<string, object> dictionary = value as IDictionary<string, object>;
            if (dictionary != null)
            {
                foreach (KeyValuePair<string, object> item in dictionary)
                    DiscoverSensitiveValues(item.Value, item.Key);
                return;
            }
            IEnumerable sequence = value as IEnumerable;
            if (sequence != null && !(value is string))
            {
                foreach (object item in sequence) DiscoverSensitiveValues(item, key);
                return;
            }
            string text = value as string;
            if (string.IsNullOrWhiteSpace(text)) return;
            if (SensitiveKey(key)) secretValues.Add(text);
            if (IdentityKey(key)) AddReplacement(text, "<identity>");
            if (LooksLikeRootedPath(text)) AddPath(
                text,
                "<configured-path:" + (replacements.Count + 1).ToString(
                    CultureInfo.InvariantCulture) + ">");
        }

        private static bool LooksLikeRootedPath(string value)
        {
            try
            {
                return Path.IsPathRooted(value);
            }
            catch (ArgumentException)
            {
                return false;
            }
            catch (NotSupportedException)
            {
                return false;
            }
        }

        private void AddPath(string value, string token)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            string root = value.TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            AddReplacement(root, token);
            // Only a root that starts the way a path does in text (a drive letter, or two slashes) can be a place a path was
            // under. Free text also writes such a path with forward slashes, so that spelling is known too, and the self-check
            // looks for it.
            if (root.Length < 3 || !StartsLikeAbsolutePath(root)) return;
            string forward = root.Replace('\\', '/');
            if (!string.Equals(forward, root, StringComparison.Ordinal)) AddReplacement(forward, token);
            AddPathRoot(root.Replace('/', '\\'), token);
        }

        private static bool StartsLikeAbsolutePath(string value)
        {
            if (value.Length < 2) return false;
            return (char.IsLetter(value[0]) && value[1] == ':') ||
                ((value[0] == '\\' || value[0] == '/') && (value[1] == '\\' || value[1] == '/'));
        }

        private void AddPathRoot(string root, string token)
        {
            if (pathRoots.Any(item => string.Equals(
                item.Key,
                root,
                StringComparison.OrdinalIgnoreCase))) return;
            pathRoots.Add(new KeyValuePair<string, string>(root, token));
        }

        // A path found in text, taken whole. One under a known place becomes that place's token, with "/<redacted>" for whatever
        // was below it, so nothing under a protected folder survives and the token still says what kind of place it was. Any other
        // path becomes a generic token. The text around the path, a reason after a ": ", is not touched.
        private string ReplacePath(Match match)
        {
            pathRedactions++;
            string text = match.Value;
            string path = text.TrimEnd();
            string trailing = text.Substring(path.Length);
            string token;
            bool exact;
            if (TryFindPathRoot(path, out token, out exact))
                return (exact ? token : token + "/<redacted>") + trailing;
            return (path[0] == '\\' || path[0] == '/' ? "<network-path>" : "<windows-path>") + trailing;
        }

        private bool TryFindPathRoot(string path, out string token, out bool exact)
        {
            string normalized = path.Replace('/', '\\');
            // The named places first (runtime, state, repository, a protected folder, the profile), then paths that only appeared in a
            // document, so a file under a protected folder is still reported as being in it.
            for (int pass = 0; pass < 2; pass++)
            {
                foreach (KeyValuePair<string, string> root in pathRoots)
                {
                    bool fromDocument = root.Value.StartsWith("<configured-path:", StringComparison.Ordinal);
                    if (fromDocument != (pass == 1)) continue;
                    if (!normalized.StartsWith(root.Key, StringComparison.OrdinalIgnoreCase)) continue;
                    // The root has to end where a folder name ends: "...\Documents" is not a root of "...\Documents2".
                    if (normalized.Length > root.Key.Length && normalized[root.Key.Length] != '\\') continue;
                    token = root.Value;
                    exact = normalized.Substring(root.Key.Length).Trim('\\').Length == 0;
                    return true;
                }
            }
            token = null;
            exact = false;
            return false;
        }

        private void AddReplacement(string value, string token)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length < 3) return;
            if (replacements.Any(item => string.Equals(
                item.Key,
                value,
                StringComparison.OrdinalIgnoreCase))) return;
            replacements.Add(new KeyValuePair<string, string>(value, token));
        }

        private void SortReplacements()
        {
            replacements.RemoveAll(item => string.IsNullOrWhiteSpace(item.Key));
            replacements.Sort(delegate(
                KeyValuePair<string, string> left,
                KeyValuePair<string, string> right)
            {
                return right.Key.Length.CompareTo(left.Key.Length);
            });
            pathRoots.Sort(delegate(
                KeyValuePair<string, string> left,
                KeyValuePair<string, string> right)
            {
                return right.Key.Length.CompareTo(left.Key.Length);
            });
        }

        private string IdentityToken(string key, string value)
        {
            string combined = key + "\u001f" + value;
            string token;
            if (!identityTokens.TryGetValue(combined, out token))
            {
                token = "<" + key.Replace('_', '-') + ":" +
                    (identityTokens.Count + 1).ToString(CultureInfo.InvariantCulture) + ">";
                identityTokens[combined] = token;
            }
            return token;
        }

        private static bool SensitiveKey(string key)
        {
            string value = (key ?? string.Empty).ToLowerInvariant();
            if (value == "secrets_included" || value == "command_lines_included")
                return false;
            return value == "command" || value == "arguments" ||
                value.Contains("password") || value.Contains("secret") ||
                value.Contains("credential") || value.Contains("dpapi") ||
                value.Contains("recovery_key") || value.Contains("reviewer_sid") ||
                value == "sid" || value.EndsWith("_sid", StringComparison.Ordinal);
        }

        private static bool IdentityKey(string key)
        {
            string value = (key ?? string.Empty).ToLowerInvariant();
            return value == "hostname" || value == "host" ||
                value == "username" || value == "user" ||
                value == "account" || value == "owner" ||
                value == "plan_id" || value == "repository_id" ||
                value == "local_repository_id" ||
                value == "cloud_repository_id" ||
                value == "run_id" || value == "snapshot_id" ||
                value == "inventory_fingerprint_sha256" ||
                value == "cloud_inventory_document_sha256" ||
                value == "backup_config_sha256" ||
                value == "canary_sha256" ||
                value == "immutable_proof_sha256" ||
                value == "cloud_verification_assets_manifest_sha256" ||
                value == "cloud_repository_path" ||
                value == "canary_snapshot_path" ||
                value == "remote_name" ||
                value.EndsWith("_fingerprint", StringComparison.Ordinal) ||
                value == "cancel_channel_id";
        }

        private static string ReplaceIgnoreCase(
            string input,
            string value,
            string replacement,
            ref int counter)
        {
            Regex pattern = new Regex(
                Regex.Escape(value),
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            int matches = pattern.Matches(input).Count;
            counter += matches;
            return matches == 0 ? input : pattern.Replace(input, replacement);
        }

        private static string CountedReplace(
            Regex expression,
            string input,
            string replacement,
            ref int counter)
        {
            int matches = expression.Matches(input).Count;
            counter += matches;
            return matches == 0 ? input : expression.Replace(input, replacement);
        }
    }
}
