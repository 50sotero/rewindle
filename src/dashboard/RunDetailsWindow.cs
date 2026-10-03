using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace ResticBackuper.Dashboard
{
    internal sealed class RunDetails
    {
        public string RunId { get; set; }
        public string TypeLabel { get; set; }
        public string ResultLabel { get; set; }
        public DateTime StartedLocal { get; set; }
        public string StartedDisplay { get; set; }
        public string DurationDisplay { get; set; }
        public string FilesDisplay { get; set; }
        public string ProcessedDisplay { get; set; }
        public string StoredDisplay { get; set; }
        public string Phase { get; set; }
        public string FailureCode { get; set; }
        public string ExitCode { get; set; }
        public string SnapshotId { get; set; }
        public string Failure { get; set; }
        public string Remediation { get; set; }
        public string LogPath { get; set; }
        public IList<string> AffectedPaths { get; set; }
        public IList<string> Events { get; set; }
        // The log is longer than the part that is read, so the oldest events are not listed.
        public bool EventsTruncated { get; set; }
        // Set when part of the log could not be read; everything else is still shown.
        public string LogNote { get; set; }

        public bool HasLog
        {
            get { return !string.IsNullOrWhiteSpace(LogPath) && File.Exists(LogPath); }
        }

        public string CopyText()
        {
            StringBuilder value = new StringBuilder();
            value.AppendLine("Rewindle backup run details");
            value.AppendLine("Run: " + RunId);
            value.AppendLine("Type: " + TypeLabel);
            value.AppendLine("Result: " + ResultLabel);
            value.AppendLine("Started: " + StartedDisplay);
            value.AppendLine("Duration: " + DurationDisplay);
            value.AppendLine("Phase: " + DisplayOrDash(Phase));
            value.AppendLine("Failure code: " + DisplayOrDash(FailureCode));
            value.AppendLine("Exit code: " + DisplayOrDash(ExitCode));
            value.AppendLine("Snapshot: " + DisplayOrDash(SnapshotId));
            if (!string.IsNullOrWhiteSpace(Failure))
                value.AppendLine("Detail: " + Failure);
            if (!string.IsNullOrWhiteSpace(Remediation))
                value.AppendLine("Suggested action: " + Remediation);
            if (AffectedPaths != null && AffectedPaths.Count > 0)
            {
                value.AppendLine("Affected paths:");
                foreach (string path in AffectedPaths) value.AppendLine("- " + path);
            }
            // Added after the original lines, which keep their text and order, so a summary pasted into
            // a bug report carries the full date with its time zone and the run's totals.
            value.AppendLine("Started at: " + (StartedLocal == DateTime.MinValue
                ? "-"
                : StartedLocal.ToString("yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture)));
            value.AppendLine("Files: " + DisplayOrDash(FilesDisplay));
            value.AppendLine("Processed: " + DisplayOrDash(ProcessedDisplay));
            value.AppendLine("Stored: " + DisplayOrDash(StoredDisplay));
            return value.ToString().TrimEnd();
        }

        private static string DisplayOrDash(string value)
        {
            return string.IsNullOrWhiteSpace(value) ? "-" : value;
        }
    }

    internal static class RunDetailsReader
    {
        private const int MaximumStatusBytes = 4 * 1024 * 1024;
        // Only this much of the end of a log is read, however long the log is, so any run can be opened.
        private const int MaximumTailBytes = 4 * 1024 * 1024;
        private const int MaximumEvents = 250;
        private const int MaximumEventCharacters = 2000;
        private const int MaximumAffectedPaths = 50;
        private const string PartialLogNote =
            "Part of this log could not be read, so some events may be missing.";

        internal static RunDetails Load(
            SourceConfiguration configuration,
            RunMetricView run)
        {
            if (configuration == null || run == null || !ValidRunId(run.RunId))
                throw new InvalidDataException("The selected run identity is invalid.");

            RunDetails details = new RunDetails
            {
                RunId = run.RunId,
                TypeLabel = run.TypeLabel ?? "Backup",
                ResultLabel = run.StateLabel ?? "Unknown",
                StartedLocal = run.StartedLocal,
                StartedDisplay = run.StartedDisplay,
                DurationDisplay = run.DurationDisplay,
                FilesDisplay = run.FilesDisplay,
                ProcessedDisplay = run.ProcessedBytesDisplay,
                StoredDisplay = run.StoredBytesDisplay,
                Phase = string.Empty,
                FailureCode = string.Empty,
                ExitCode = string.Empty,
                SnapshotId = run.SnapshotDisplay == "-" ? string.Empty : run.SnapshotDisplay,
                Failure = string.Empty,
                Remediation = string.Empty,
                AffectedPaths = new List<string>(),
                Events = new List<string>(),
                LogNote = string.Empty
            };

            string stateDirectory = SourceConfiguration.NormalizePath(
                configuration.StateDirectory);
            string statusName = string.Equals(
                run.TypeLabel,
                "Dry run",
                StringComparison.OrdinalIgnoreCase)
                    ? "dry-run-latest.json"
                    : "status.json";
            string statusPath = ConfinedPath(stateDirectory, statusName);
            IDictionary<string, object> status = TryReadObject(statusPath);
            if (status != null && string.Equals(
                ReadString(status, "run_id"),
                run.RunId,
                StringComparison.Ordinal))
            {
                ApplyStatus(details, status);
            }

            string logsDirectory = ConfinedPath(stateDirectory, "logs");
            string prefix = string.Equals(
                run.TypeLabel,
                "Dry run",
                StringComparison.OrdinalIgnoreCase)
                    ? "dry-run-"
                    : "backup-";
            string logPath = ConfinedPath(
                logsDirectory,
                prefix + run.RunId + ".jsonl.log");
            details.LogPath = IsRegularFile(logPath) ? logPath : string.Empty;
            if (details.HasLog)
            {
                ApplyLog(details, logPath);
            }
            details.Remediation = Remediation(details.FailureCode, details.Phase);
            return details;
        }

        private static void ApplyStatus(
            RunDetails details,
            IDictionary<string, object> status)
        {
            details.Phase = FirstNonEmpty(
                ReadString(status, "failure_phase"),
                ReadString(status, "phase_at_cancel_request"),
                ReadString(status, "state"));
            details.FailureCode = ReadString(status, "failure_code");
            details.ExitCode = FirstNonEmpty(
                ReadScalar(status, "exit_code"),
                ReadScalar(status, "backup_exit_code"),
                ReadScalar(status, "restic_exit_code"));
            details.SnapshotId = FirstNonEmpty(
                ReadString(status, "snapshot_id"),
                details.SnapshotId);
            details.Failure = CleanDetail(ReadString(status, "failure"));
            foreach (string path in ReadStringCollection(status, "affected_paths"))
                AddAffectedPath(details, path);
            foreach (object value in ReadCollection(status, "errors"))
            {
                IDictionary<string, object> error = value as IDictionary<string, object>;
                if (error == null) continue;
                AddAffectedPath(details, ReadString(error, "item"));
                AddAffectedPath(details, ReadString(error, "path"));
                IDictionary<string, object> nested = ReadDictionary(error, "error");
                AddAffectedPath(details, ReadString(nested, "path"));
            }
        }

        private static void ApplyLog(RunDetails details, string logPath)
        {
            // A long run reports progress many times a second. Consecutive progress updates collapse into
            // the newest one, so the newest 250 events reach back through the whole run instead of being a
            // single stretch of ticks.
            LinkedList<string> events = new LinkedList<string>();
            bool lastWasProgress = false;
            try
            {
                using (FileStream stream = new FileStream(
                    logPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                {
                    bool tailOnly = stream.Length > MaximumTailBytes;
                    if (tailOnly)
                    {
                        stream.Seek(-MaximumTailBytes, SeekOrigin.End);
                        // The seek can land inside a line, or inside a multi-byte character. Move past the
                        // next line break while still reading bytes, so decoding starts on a whole line.
                        int next;
                        while ((next = stream.ReadByte()) != -1 && next != 0x0A)
                        {
                        }
                        details.EventsTruncated = true;
                    }
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
                            if (line.Length == 0 || line.Length > 1024 * 1024) continue;
                            IDictionary<string, object> document = TryParseObject(line);
                            if (document == null) continue;
                            ApplyLogIdentity(details, document);
                            bool progress;
                            string display = FormatEvent(details, document, out progress);
                            if (string.IsNullOrWhiteSpace(display)) continue;
                            display = LimitEvent(display);
                            if (progress && lastWasProgress && events.Last != null)
                            {
                                events.Last.Value = display;
                            }
                            else
                            {
                                events.AddLast(display);
                                if (events.Count > MaximumEvents)
                                {
                                    events.RemoveFirst();
                                    details.EventsTruncated = true;
                                }
                            }
                            lastWasProgress = progress;
                        }
                    }
                }
            }
            catch (Exception error)
            {
                // The rest of the details (status, failure, paths) are still worth showing.
                if (!IsRecoverableReadError(error)) throw;
                details.LogNote = PartialLogNote;
            }
            details.Events = events.ToList();
        }

        private static bool IsRecoverableReadError(Exception error)
        {
            return error is IOException || error is UnauthorizedAccessException ||
                error is InvalidDataException || error is ArgumentException ||
                error is InvalidOperationException || error is NotSupportedException;
        }

        private static string LimitEvent(string display)
        {
            return display.Length > MaximumEventCharacters
                ? display.Substring(0, MaximumEventCharacters) + "..."
                : display;
        }

        private static void ApplyLogIdentity(
            RunDetails details,
            IDictionary<string, object> document)
        {
            string wrapperEvent = ReadString(document, "wrapper_event");
            if (wrapperEvent == "failure")
            {
                details.Phase = FirstNonEmpty(
                    ReadString(document, "failure_phase"), details.Phase);
                details.FailureCode = FirstNonEmpty(
                    ReadString(document, "failure_code"), details.FailureCode);
                details.Failure = FirstNonEmpty(
                    CleanDetail(ReadString(document, "error")), details.Failure);
                foreach (string path in ReadStringCollection(document, "affected_paths"))
                    AddAffectedPath(details, path);
            }
            if (wrapperEvent == "backup_verified")
            {
                details.SnapshotId = FirstNonEmpty(
                    ReadString(document, "snapshot_id"), details.SnapshotId);
            }
            string messageType = ReadString(document, "message_type");
            if (messageType == "error")
            {
                AddAffectedPath(details, ReadString(document, "item"));
                AddAffectedPath(details, ReadString(document, "path"));
                IDictionary<string, object> nested = ReadDictionary(document, "error");
                AddAffectedPath(details, ReadString(nested, "path"));
            }
        }

        // `progress` reports whether the line is a restic progress update, which ApplyLog collapses.
        private static string FormatEvent(
            RunDetails details,
            IDictionary<string, object> document,
            out bool progress)
        {
            progress = false;
            string timestamp = FormatTimestamp(
                FirstNonEmpty(
                    ReadString(document, "utc"),
                    ReadString(document, "time")),
                details.StartedLocal);
            string prefix = string.IsNullOrWhiteSpace(timestamp) ? string.Empty : timestamp + "  ";
            string wrapperEvent = ReadString(document, "wrapper_event");
            if (!string.IsNullOrWhiteSpace(wrapperEvent))
            {
                string detail = wrapperEvent.Replace('_', ' ');
                if (wrapperEvent == "failure")
                    detail += ": " + CleanDetail(ReadString(document, "error"));
                return prefix + detail;
            }

            string messageType = ReadString(document, "message_type");
            if (messageType == "error")
            {
                IDictionary<string, object> nested = ReadDictionary(document, "error");
                string message = CleanDetail(FirstNonEmpty(
                    ReadString(nested, "message"),
                    ReadString(document, "message"),
                    "Restic reported an affected item."));
                string item = FirstNonEmpty(
                    ReadString(document, "item"),
                    ReadString(document, "path"));
                return prefix + "error: " + message +
                    (string.IsNullOrWhiteSpace(item) ? string.Empty : "  [" + item + "]");
            }
            if (messageType == "summary")
            {
                List<string> totals = new List<string>();
                long total;
                if (TryReadCount(document, "total_files_processed", out total))
                    totals.Add(TelemetryFormat.FormatCount(total) + " files");
                if (TryReadCount(document, "total_bytes_processed", out total))
                    totals.Add(TelemetryFormat.FormatBytes(total) + " processed");
                return prefix + "Restic summary" +
                    (totals.Count == 0 ? string.Empty : ": " + string.Join(", ", totals.ToArray()));
            }
            if (messageType == "status")
            {
                progress = true;
                List<string> done = new List<string>();
                long count;
                if (TryReadCount(document, "files_done", out count))
                    done.Add(TelemetryFormat.FormatCount(count) + " files");
                if (TryReadCount(document, "bytes_done", out count))
                    done.Add(TelemetryFormat.FormatBytes(count));
                return prefix + "progress: " +
                    (done.Count == 0 ? "update" : string.Join(", ", done.ToArray()));
            }
            return string.Empty;
        }

        // The wrapper stamps events in UTC. The page shows the run in local time, so the timeline does too.
        // A stamp that cannot be read as a date is kept as written, never relabelled.
        private static string FormatTimestamp(string timestamp, DateTime runStartedLocal)
        {
            if (string.IsNullOrWhiteSpace(timestamp)) return string.Empty;
            timestamp = timestamp.Trim();
            DateTimeOffset stamp;
            if (timestamp.Length >= 10 && timestamp[4] == '-' && DateTimeOffset.TryParse(
                timestamp,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal,
                out stamp))
            {
                try
                {
                    DateTime local = stamp.ToLocalTime().DateTime;
                    return local.ToString(
                        local.Date == runStartedLocal.Date ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss",
                        CultureInfo.InvariantCulture);
                }
                catch (ArgumentOutOfRangeException)
                {
                    // A stamp at the edge of the supported range stays as written.
                }
            }
            return timestamp.Length > 64 ? timestamp.Substring(0, 64) : timestamp;
        }

        // Restic reports counts as JSON numbers, which arrive as int, long, decimal or double by size.
        private static bool TryReadCount(
            IDictionary<string, object> document,
            string key,
            out long value)
        {
            value = -1;
            object raw;
            if (document == null || !document.TryGetValue(key, out raw) ||
                raw == null || raw is string) return false;
            try
            {
                if (raw is int || raw is long)
                {
                    value = Convert.ToInt64(raw, CultureInfo.InvariantCulture);
                    return value >= 0;
                }
                double number = Convert.ToDouble(raw, CultureInfo.InvariantCulture);
                if (double.IsNaN(number) || number < 0 || number >= long.MaxValue) return false;
                value = (long)number;
                return true;
            }
            catch (InvalidCastException) { return false; }
            catch (FormatException) { return false; }
            catch (OverflowException) { return false; }
        }

        private static string Remediation(string failureCode, string phase)
        {
            switch (failureCode)
            {
                case "source_preflight_failed":
                    return "Reconnect or grant access to the affected source, verify its expected volume, then run the backup again.";
                case "volume_identity_mismatch":
                    return "Reconnect the expected disk. Do not rebind a changed drive until its identity and contents are reviewed.";
                case "repository_low_space":
                    return "Free space on the repository volume or move the repository with the protected location workflow.";
                case "repository_storage_unavailable":
                    return "Reconnect the backup storage (for a Google Drive repository, make sure Google Drive for desktop is running and signed in), then run the backup again.";
                case "repository_authentication_failed":
                    return "Use Check recovery readiness to test the active credential and recovery key independently.";
                case "source_data_unreadable":
                    return "Review the affected paths and permissions. The incomplete run is not treated as a verified backup.";
                case "repository_structure_check_failed":
                case "repository_data_check_failed":
                    return "Do not delete snapshots. Use Check recovery readiness and preserve the repository for diagnosis.";
                case "restore_canary_failed":
                    return "Use Check recovery readiness to verify the restore test file, credentials, and alternate-location restore path.";
                case "cooperative_cancellation":
                    return "No repair is required. A new backup can be started when the protected task is idle.";
            }
            if (!string.IsNullOrWhiteSpace(phase) && phase.IndexOf(
                "cancel",
                StringComparison.OrdinalIgnoreCase) >= 0)
                return "Confirm the protected task is idle, then retry when ready.";
            return string.IsNullOrWhiteSpace(failureCode)
                ? string.Empty
                : "Export a redacted diagnostic bundle and use Check recovery readiness before retrying.";
        }

        private static IDictionary<string, object> TryReadObject(string path)
        {
            if (!IsRegularFile(path)) return null;
            FileInfo file = new FileInfo(path);
            if (file.Length <= 0 || file.Length > MaximumStatusBytes) return null;
            try
            {
                return TryParseObject(File.ReadAllText(path, Encoding.UTF8));
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        private static IDictionary<string, object> TryParseObject(string json)
        {
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = MaximumStatusBytes;
                return serializer.DeserializeObject(json) as IDictionary<string, object>;
            }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        private static string ConfinedPath(string parent, string child)
        {
            string normalizedParent = SourceConfiguration.NormalizePath(parent);
            string candidate = SourceConfiguration.NormalizePath(Path.Combine(
                normalizedParent,
                child));
            string prefix = normalizedParent.TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The protected run-details path escaped its state directory.");
            return candidate;
        }

        private static bool IsRegularFile(string path)
        {
            if (!File.Exists(path) || Directory.Exists(path)) return false;
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0;
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

        private static void AddAffectedPath(RunDetails details, string value)
        {
            if (details.AffectedPaths.Count >= MaximumAffectedPaths ||
                string.IsNullOrWhiteSpace(value) || value.Length > 1024 ||
                value.IndexOf('\0') >= 0 || value.IndexOf('\r') >= 0 ||
                value.IndexOf('\n') >= 0 || !Path.IsPathRooted(value)) return;
            if (!details.AffectedPaths.Any(item => string.Equals(
                item,
                value,
                StringComparison.OrdinalIgnoreCase)))
                details.AffectedPaths.Add(value);
        }

        private static string CleanDetail(string value)
        {
            string text = (value ?? string.Empty).Replace("\r", " ").Replace("\n", " ").Trim();
            if (text.IndexOf("RESTIC_PASSWORD", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("password-command", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("dpapi", StringComparison.OrdinalIgnoreCase) >= 0)
                return "Sensitive credential-related detail was withheld.";
            return text.Length > 800 ? text.Substring(0, 800) : text;
        }

        private static IDictionary<string, object> ReadDictionary(
            IDictionary<string, object> document,
            string key)
        {
            object value;
            return document != null && document.TryGetValue(key, out value)
                ? value as IDictionary<string, object>
                : null;
        }

        private static IEnumerable ReadCollection(
            IDictionary<string, object> document,
            string key)
        {
            object value;
            if (document == null || !document.TryGetValue(key, out value) ||
                value == null || value is string) return new object[0];
            return value as IEnumerable ?? new object[0];
        }

        private static IEnumerable<string> ReadStringCollection(
            IDictionary<string, object> document,
            string key)
        {
            foreach (object value in ReadCollection(document, key))
            {
                string text = value as string;
                if (!string.IsNullOrWhiteSpace(text)) yield return text;
            }
        }

        private static string ReadString(
            IDictionary<string, object> document,
            string key)
        {
            object value;
            return document != null && document.TryGetValue(key, out value)
                ? value as string ?? string.Empty
                : string.Empty;
        }

        private static string ReadScalar(
            IDictionary<string, object> document,
            string key)
        {
            object value;
            if (document == null || !document.TryGetValue(key, out value) || value == null)
                return string.Empty;
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        private static string FirstNonEmpty(params string[] values)
        {
            foreach (string value in values)
                if (!string.IsNullOrWhiteSpace(value)) return value;
            return string.Empty;
        }
    }

    // Another program can hold the Windows clipboard open for a moment. WPF already retries that, so a
    // failure that reaches here is a clipboard that stayed busy; say so plainly instead of showing a COM
    // error code.
    internal static class ClipboardText
    {
        private const int ClipboardCannotOpen = unchecked((int)0x800401D0);

        internal static bool TrySet(string text, out string problem)
        {
            problem = string.Empty;
            try
            {
                Clipboard.SetText(text ?? string.Empty);
                return true;
            }
            catch (System.Runtime.InteropServices.ExternalException error)
            {
                problem = error.ErrorCode == ClipboardCannotOpen
                    ? "The Windows clipboard is busy. Try again in a moment."
                    : "The text could not be copied to the clipboard. " + error.Message;
                return false;
            }
        }
    }

    internal sealed class RunDetailsWindow : Window
    {
        private readonly RunDetails details;
        private readonly DashboardThemePalette palette;
        private TextBox eventFilterBox;
        private TextBox eventsBox;
        private TextBlock eventSummary;
        private IList<string> eventLines;
        private Button copyEventsButton;

        internal RunDetailsWindow(RunDetails details, DashboardThemePalette palette)
        {
            if (details == null) throw new ArgumentNullException("details");
            this.details = details;
            this.palette = palette;
            Title = "Backup run details";
            Width = 920;
            Height = 720;
            MinWidth = 720;
            MinHeight = 560;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            DashboardVisualStyle.ApplyWindow(this, palette);
            Content = BuildContent();
            DashboardVisualStyle.ApplyDialogEntrance(this);
            PreviewKeyDown += delegate(object sender, KeyEventArgs args)
            {
                if (args.Key == Key.F &&
                    (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control &&
                    eventFilterBox != null)
                {
                    eventFilterBox.Focus();
                    eventFilterBox.SelectAll();
                    args.Handled = true;
                    return;
                }
                if (args.Key == Key.Escape)
                {
                    if (eventFilterBox != null && eventFilterBox.IsKeyboardFocusWithin &&
                        !string.IsNullOrEmpty(eventFilterBox.Text))
                    {
                        eventFilterBox.Clear();
                        args.Handled = true;
                        return;
                    }
                    Close();
                    args.Handled = true;
                }
            };
            AutomationProperties.SetName(this, "Details for backup run " + details.RunId);
        }

        private UIElement BuildContent()
        {
            Grid root = new Grid { Margin = new Thickness(24) };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            StackPanel heading = new StackPanel();
            TextBlock eyebrow = Text(details.TypeLabel.ToUpperInvariant() + "  /  " + details.ResultLabel.ToUpperInvariant(), 11, ResultAccent(), FontWeights.Bold);
            heading.Children.Add(eyebrow);
            heading.Children.Add(Text("Run " + details.RunId, 24, palette.TextPrimary, FontWeights.SemiBold));
            TextBlock time = Text(details.StartedDisplay + "  |  " + details.DurationDisplay, 12, palette.TextSecondary, FontWeights.Normal);
            time.Margin = new Thickness(0, 5, 0, 0);
            heading.Children.Add(time);
            root.Children.Add(heading);

            UniformGrid facts = new UniformGrid { Rows = 1, Columns = 4, Margin = new Thickness(0, 18, 0, 0) };
            facts.Children.Add(Fact("PHASE", details.Phase));
            facts.Children.Add(Fact("FAILURE CODE", details.FailureCode));
            facts.Children.Add(Fact("EXIT CODE", details.ExitCode));
            facts.Children.Add(Fact("SNAPSHOT", details.SnapshotId));
            Grid.SetRow(facts, 1);
            root.Children.Add(facts);

            StackPanel attention = new StackPanel { Margin = new Thickness(0, 16, 0, 0) };
            if (!string.IsNullOrWhiteSpace(details.Failure))
                attention.Children.Add(Callout("What happened", details.Failure, palette.Danger));
            if (!string.IsNullOrWhiteSpace(details.Remediation))
                attention.Children.Add(Callout("Suggested next step", details.Remediation, palette.Warning));
            if (details.AffectedPaths.Count > 0)
            {
                Border paths = Card();
                StackPanel pathPanel = new StackPanel();
                pathPanel.Children.Add(Text(
                    "Affected paths (" + details.AffectedPaths.Count.ToString(CultureInfo.CurrentCulture) + ")",
                    13,
                    palette.TextPrimary,
                    FontWeights.SemiBold));
                ListBox list = new ListBox
                {
                    ItemsSource = details.AffectedPaths,
                    MaxHeight = 120,
                    Margin = new Thickness(0, 8, 0, 0),
                    Background = Brushes.Transparent,
                    Foreground = palette.TextSecondary,
                    BorderThickness = new Thickness(0)
                };
                AutomationProperties.SetName(list, "Affected paths recorded for this run");
                pathPanel.Children.Add(list);
                paths.Child = pathPanel;
                attention.Children.Add(paths);
            }
            if (string.IsNullOrWhiteSpace(details.Failure) &&
                string.IsNullOrWhiteSpace(details.Remediation) &&
                details.AffectedPaths.Count == 0)
            {
                attention.Children.Add(Callout(
                    "No additional issue detail",
                    "This run did not record a failure message or affected paths. The bounded event list below is the complete structured detail available for this run.",
                    palette.TextSecondary));
            }
            Grid.SetRow(attention, 2);
            root.Children.Add(attention);

            Border eventCard = Card();
            eventCard.Margin = new Thickness(0, 16, 0, 0);
            Grid eventGrid = new Grid();
            eventGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            eventGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            eventGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            Grid eventHeading = new Grid();
            eventHeading.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            eventHeading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel eventTitle = new StackPanel();
            eventTitle.Children.Add(Text("Protected log events", 14, palette.TextPrimary, FontWeights.SemiBold));
            eventSummary = Text("", 11, palette.TextSecondary, FontWeights.Normal);
            eventSummary.Margin = new Thickness(0, 3, 0, 0);
            eventTitle.Children.Add(eventSummary);
            eventHeading.Children.Add(eventTitle);
            eventFilterBox = new TextBox
            {
                Width = 230,
                Height = 32,
                Padding = new Thickness(9, 6, 9, 6),
                Background = palette.SurfaceSoft,
                Foreground = palette.TextPrimary,
                BorderBrush = palette.Border,
                CaretBrush = palette.TextPrimary,
                ToolTip = "Filter visible events by message, path, phase, or timestamp. Ctrl+F focuses this field."
            };
            AutomationProperties.SetName(eventFilterBox, "Filter protected log events");
            AutomationProperties.SetHelpText(
                eventFilterBox,
                "Type a word or phrase to filter the bounded structured event list. Press Escape to clear.");
            eventFilterBox.TextChanged += delegate { ApplyEventFilter(); };
            StackPanel filterField = new StackPanel();
            TextBlock filterLabel = Text("Filter events (Ctrl+F)", 11, palette.TextSecondary, FontWeights.Normal);
            filterLabel.Margin = new Thickness(0, 0, 0, 4);
            filterField.Children.Add(filterLabel);
            filterField.Children.Add(eventFilterBox);
            Grid.SetColumn(filterField, 1);
            eventHeading.Children.Add(filterField);
            eventGrid.Children.Add(eventHeading);

            StackPanel eventTools = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 8, 0, 0)
            };
            Button clearFilter = Button("Clear filter");
            clearFilter.MinWidth = 98;
            clearFilter.Click += delegate { eventFilterBox.Clear(); eventFilterBox.Focus(); };
            AutomationProperties.SetName(clearFilter, "Clear event filter");
            eventTools.Children.Add(clearFilter);
            Grid.SetRow(eventTools, 1);
            eventGrid.Children.Add(eventTools);

            eventsBox = new TextBox
            {
                IsReadOnly = true,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.NoWrap,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 11,
                Background = palette.SurfaceSoft,
                Foreground = palette.TextSecondary,
                BorderBrush = palette.Border,
                BorderThickness = new Thickness(1),
                Margin = new Thickness(0, 10, 0, 0),
                Padding = new Thickness(10)
            };
            eventLines = details.Events == null
                ? new List<string>()
                : details.Events.Where(item => !string.IsNullOrWhiteSpace(item)).ToList();
            AutomationProperties.SetName(eventsBox, "Bounded structured protected log events");
            AutomationProperties.SetHelpText(
                eventsBox,
                "Read-only bounded events. Use Ctrl+F or the filter field to find a message.");
            Grid.SetRow(eventsBox, 2);
            eventGrid.Children.Add(eventsBox);
            eventCard.Child = eventGrid;
            Grid.SetRow(eventCard, 3);
            root.Children.Add(eventCard);

            StackPanel actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 16, 0, 0)
            };
            Button open = Button("Open log location");
            open.IsEnabled = details.HasLog;
            open.ToolTip = details.HasLog
                ? "Select the exact protected log in File Explorer."
                : "No protected log file is available for this run.";
            open.Click += OnOpenLog;
            AutomationProperties.SetName(open, "Open exact protected log location");
            actions.Children.Add(open);
            Button copy = Button("Copy summary");
            copy.Margin = new Thickness(8, 0, 0, 0);
            copy.Click += OnCopySummary;
            AutomationProperties.SetName(copy, "Copy structured run summary");
            actions.Children.Add(copy);
            Button copyEvents = Button("Copy visible events");
            copyEventsButton = copyEvents;
            copyEvents.Margin = new Thickness(8, 0, 0, 0);
            copyEvents.Click += OnCopyEvents;
            copyEvents.ToolTip = "Copy the currently filtered event list to the clipboard.";
            AutomationProperties.SetName(copyEvents, "Copy visible protected log events");
            actions.Children.Add(copyEvents);
            Button close = Button("Close");
            close.Margin = new Thickness(8, 0, 0, 0);
            close.Background = palette.AccentInfo;
            close.Foreground = palette.TextOnAccent;
            close.Click += delegate { Close(); };
            close.IsDefault = true;
            actions.Children.Add(close);
            Grid.SetRow(actions, 4);
            root.Children.Add(actions);
            ApplyEventFilter();
            return root;
        }

        private void OnOpenLog(object sender, RoutedEventArgs args)
        {
            if (!details.HasLog) return;
            try
            {
                ProcessStartInfo start = new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "/select," + Quote(details.LogPath),
                    UseShellExecute = true
                };
                Process.Start(start);
            }
            catch (Exception error)
            {
                MessageBox.Show(
                    this,
                    "The protected log could not be opened.\n\n" + error.Message,
                    "Open log location",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
        }

        private void OnCopySummary(object sender, RoutedEventArgs args)
        {
            string problem;
            if (ClipboardText.TrySet(details.CopyText(), out problem)) return;
            MessageBox.Show(
                this,
                problem,
                "Copy summary",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }

        private void OnCopyEvents(object sender, RoutedEventArgs args)
        {
            if (copyEventsButton == null || !copyEventsButton.IsEnabled) return;
            string problem;
            if (ClipboardText.TrySet(eventsBox == null ? string.Empty : eventsBox.Text, out problem))
            {
                eventSummary.Text = "Visible events copied to the clipboard.";
                return;
            }
            MessageBox.Show(
                this,
                problem,
                "Copy visible events",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }

        private void ApplyEventFilter()
        {
            if (eventFilterBox == null || eventsBox == null || eventSummary == null || eventLines == null)
            {
                return;
            }
            string query = (eventFilterBox.Text ?? string.Empty).Trim();
            IList<string> visible = string.IsNullOrWhiteSpace(query)
                ? eventLines
                : eventLines.Where(item => item.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0).ToList();
            eventsBox.Text = string.Join(Environment.NewLine, visible.ToArray());
            if (copyEventsButton != null)
            {
                copyEventsButton.IsEnabled = visible.Count > 0;
                copyEventsButton.ToolTip = visible.Count > 0
                    ? "Copy the currently filtered event list to the clipboard."
                    : "There are no visible events to copy.";
            }
            if (eventLines.Count == 0)
            {
                eventSummary.Text = !details.HasLog
                    ? "No protected log is available for this run."
                    : string.IsNullOrEmpty(details.LogNote)
                        ? "No structured events were recorded in this log."
                        : details.LogNote;
            }
            else if (string.IsNullOrWhiteSpace(query))
            {
                eventSummary.Text = eventLines.Count.ToString(CultureInfo.CurrentCulture) +
                    " bounded event" + (eventLines.Count == 1 ? string.Empty : "s") +
                    " · newest protected details are shown" +
                    (details.EventsTruncated ? "; older events are not listed" : string.Empty) +
                    (string.IsNullOrEmpty(details.LogNote) ? string.Empty : ". " + details.LogNote);
            }
            else if (visible.Count == 0)
            {
                eventSummary.Text = "No bounded events match “" + query + "”. Press Escape to clear the filter.";
            }
            else
            {
                eventSummary.Text = visible.Count.ToString(CultureInfo.CurrentCulture) +
                    " of " + eventLines.Count.ToString(CultureInfo.CurrentCulture) +
                    " bounded events match “" + query + "”.";
            }
        }

        private Brush ResultAccent()
        {
            string value = (details.ResultLabel ?? string.Empty).ToLowerInvariant();
            if (value.IndexOf("fail", StringComparison.Ordinal) >= 0 ||
                value.IndexOf("error", StringComparison.Ordinal) >= 0)
            {
                return palette.Danger;
            }
            if (value.IndexOf("cancel", StringComparison.Ordinal) >= 0 ||
                value.IndexOf("partial", StringComparison.Ordinal) >= 0 ||
                value.IndexOf("attention", StringComparison.Ordinal) >= 0)
            {
                return palette.Warning;
            }
            if (value.IndexOf("verified", StringComparison.Ordinal) >= 0 ||
                value.IndexOf("success", StringComparison.Ordinal) >= 0 ||
                value.IndexOf("clean", StringComparison.Ordinal) >= 0 ||
                value.IndexOf("complete", StringComparison.Ordinal) >= 0)
            {
                return palette.Success;
            }
            return palette.AccentInfoText;
        }

        private Border Fact(string label, string value)
        {
            Border card = Card();
            card.Margin = new Thickness(0, 0, 8, 0);
            StackPanel panel = new StackPanel();
            panel.Children.Add(Text(label, 10, palette.TextSecondary, FontWeights.Bold));
            TextBlock content = Text(
                string.IsNullOrWhiteSpace(value) ? "-" : value,
                12,
                palette.TextPrimary,
                FontWeights.SemiBold);
            content.Margin = new Thickness(0, 5, 0, 0);
            content.TextTrimming = TextTrimming.CharacterEllipsis;
            content.ToolTip = value;
            panel.Children.Add(content);
            card.Child = panel;
            return card;
        }

        private Border Callout(string title, string detail, Brush accent)
        {
            Border card = Card();
            card.BorderBrush = accent;
            StackPanel panel = new StackPanel();
            panel.Children.Add(Text(title, 12, accent, FontWeights.Bold));
            TextBlock body = Text(detail, 12, palette.TextPrimary, FontWeights.Normal);
            body.TextWrapping = TextWrapping.Wrap;
            body.Margin = new Thickness(0, 5, 0, 0);
            panel.Children.Add(body);
            card.Child = panel;
            return card;
        }

        private Border Card()
        {
            return new Border
            {
                Background = palette.Surface,
                BorderBrush = palette.Border,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(14),
                Margin = new Thickness(0, 8, 0, 0)
            };
        }

        private Button Button(string label)
        {
            Button button = new Button
            {
                Content = label,
                MinWidth = 112,
                MinHeight = 36,
                Padding = new Thickness(14, 6, 14, 6),
                Background = palette.SurfaceSoft,
                Foreground = palette.TextPrimary,
                BorderBrush = palette.Border,
                BorderThickness = new Thickness(1)
            };
            DashboardVisualStyle.ApplyButtonChrome(button, 8.0);
            DashboardVisualStyle.ApplyFocusOutline(button, palette.Focus);
            ToolTipService.SetShowOnDisabled(button, true);
            return button;
        }

        private static TextBlock Text(string value, double size, Brush color, FontWeight weight)
        {
            return new TextBlock
            {
                Text = value ?? string.Empty,
                FontSize = size,
                Foreground = color,
                FontWeight = weight
            };
        }

        private static string Quote(string value)
        {
            return "\"" + (value ?? string.Empty).Replace("\"", "\\\"") + "\"";
        }
    }
}
