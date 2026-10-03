using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.ComponentModel;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal sealed class RecoveryHealthCheck
    {
        public string Id { get; private set; }
        public string Status { get; private set; }
        public string Summary { get; private set; }
        public string Detail { get; private set; }

        public string StatusDisplay
        {
            get
            {
                if (Status == "pass") return "Ready";
                if (Status == "warn") return "Review";
                return "Action needed";
            }
        }

        internal RecoveryHealthCheck(string id, string status, string summary, string detail)
        {
            Id = id;
            Status = status;
            Summary = summary;
            Detail = detail;
        }
    }

    internal sealed class RecoveryHealthReport
    {
        public bool Loaded { get; private set; }
        public string OverallStatus { get; private set; }
        public string ErrorMessage { get; private set; }
        public string RepositoryId { get; private set; }
        public long RepositoryFormat { get; private set; }
        public long? FreeBytes { get; private set; }
        public long ReserveBytes { get; private set; }
        public long? ActiveLockCount { get; private set; }
        public int FailedCheckCount { get; private set; }
        public int WarningCheckCount { get; private set; }
        public IList<RecoveryHealthCheck> Checks { get; private set; }

        internal static RecoveryHealthReport Success(
            string overallStatus,
            string repositoryId,
            long repositoryFormat,
            long? freeBytes,
            long reserveBytes,
            long? activeLockCount,
            int failedCheckCount,
            int warningCheckCount,
            IList<RecoveryHealthCheck> checks)
        {
            return new RecoveryHealthReport
            {
                Loaded = true,
                OverallStatus = overallStatus,
                RepositoryId = repositoryId,
                RepositoryFormat = repositoryFormat,
                FreeBytes = freeBytes,
                ReserveBytes = reserveBytes,
                ActiveLockCount = activeLockCount,
                FailedCheckCount = failedCheckCount,
                WarningCheckCount = warningCheckCount,
                Checks = checks ?? new List<RecoveryHealthCheck>()
            };
        }

        internal static RecoveryHealthReport Failure(string message)
        {
            return new RecoveryHealthReport
            {
                Loaded = false,
                OverallStatus = "blocked",
                ErrorMessage = string.IsNullOrWhiteSpace(message)
                    ? "Recovery readiness could not be inspected."
                    : message,
                Checks = new List<RecoveryHealthCheck>()
            };
        }
    }

    internal static class RecoveryHealthLauncher
    {
        private static string ExpectedSchema
        {
            get { return EngineProfile.Current.RecoveryHealthSchema; }
        }

        private const int MaximumOutputBytes = 4 * 1024 * 1024;
        private const int MaximumErrorBytes = 256 * 1024;

        internal static RecoveryHealthReport Inspect(SourceConfiguration configuration)
        {
            if (configuration == null)
            {
                return RecoveryHealthReport.Failure("Protected configuration is unavailable.");
            }
            try
            {
                string installRoot = SourceConfiguration.NormalizePath(configuration.InstallRoot);
                string python = SourceConfiguration.NormalizePath(
                    Path.Combine(installRoot, EngineProfile.Current.PythonRelativePath));
                string health = SourceConfiguration.NormalizePath(
                    Path.Combine(installRoot, "recovery_health.py"));
                string config = SourceConfiguration.NormalizePath(configuration.ConfigurationPath);
                if (!File.Exists(python) || !File.Exists(health) || !File.Exists(config) ||
                    !IsChildPath(python, installRoot) || !IsChildPath(health, installRoot) ||
                    !IsChildPath(config, installRoot))
                {
                    return RecoveryHealthReport.Failure(
                        "The protected recovery-health runtime is missing or unsafe.");
                }

                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = python;
                start.Arguments = JoinArguments(new[]
                {
                    "-E", "-S", "-B", health, "--config", config
                });
                start.WorkingDirectory = installRoot;
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;
                start.StandardOutputEncoding = new UTF8Encoding(false, true);
                start.StandardErrorEncoding = new UTF8Encoding(false, true);
                BoundedUtf8Capture output;
                BoundedUtf8Capture error;
                int exitCode;
                using (Process process = Process.Start(start))
                {
                    if (process == null)
                    {
                        return RecoveryHealthReport.Failure(
                            "Windows did not start the recovery-readiness inspector.");
                    }
                    output = new BoundedUtf8Capture(
                        process.StandardOutput.BaseStream,
                        MaximumOutputBytes);
                    error = new BoundedUtf8Capture(
                        process.StandardError.BaseStream,
                        MaximumErrorBytes);
                    output.Start();
                    error.Start();
                    if (!process.WaitForExit(60000))
                    {
                        try { process.Kill(); } catch { }
                        try { process.StandardOutput.Close(); } catch { }
                        try { process.StandardError.Close(); } catch { }
                        JoinCaptures(output, error);
                        return RecoveryHealthReport.Failure(
                            "Recovery-readiness inspection exceeded its one-minute limit.");
                    }
                    process.WaitForExit();
                    JoinCaptures(output, error);
                    exitCode = process.ExitCode;
                }
                if (output.Failed || error.Failed)
                {
                    return RecoveryHealthReport.Failure(
                        "Recovery-readiness output could not be read safely.");
                }
                if (output.ExceededLimit)
                {
                    return RecoveryHealthReport.Failure(
                        "Recovery-readiness output exceeded its safety limit.");
                }
                if (error.ExceededLimit)
                {
                    return RecoveryHealthReport.Failure(
                        "Recovery-readiness diagnostics exceeded their safety limit.");
                }
                if (output.ByteCount <= 0)
                {
                    return RecoveryHealthReport.Failure(
                        exitCode == 0 || string.IsNullOrWhiteSpace(error.Value)
                            ? "Recovery-readiness output was missing."
                            : Sanitize(error.Value));
                }
                if (exitCode != 0 && exitCode != 2)
                {
                    return RecoveryHealthReport.Failure(Sanitize(error.Value));
                }
                IDictionary<string, object> document =
                    new JavaScriptSerializer().DeserializeObject(output.Value) as IDictionary<string, object>;
                return ParseBoundReport(document, configuration);
            }
            catch (Exception error)
            {
                return RecoveryHealthReport.Failure(Sanitize(error.Message));
            }
        }

        private static void JoinCaptures(BoundedUtf8Capture output, BoundedUtf8Capture error)
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(5);
            output.JoinUntil(deadline);
            error.JoinUntil(deadline);
        }

        private static RecoveryHealthReport ParseBoundReport(
            IDictionary<string, object> document,
            SourceConfiguration configuration)
        {
            if (document == null || ReadLong(document, "schema_version") != 1 ||
                ReadString(document, "schema") != ExpectedSchema ||
                ReadString(document, "plan_id") != configuration.PlanId ||
                ReadLong(document, "config_generation") != configuration.ConfigGeneration ||
                !PathEquals(ReadString(document, "repository"), configuration.RepositoryPath))
            {
                return RecoveryHealthReport.Failure(
                    "Recovery-readiness data did not bind to the current protected plan.");
            }
            string overall = ReadString(document, "overall_status");
            if (overall != "healthy" && overall != "warning" && overall != "blocked")
            {
                throw new InvalidDataException("Recovery-health status is invalid.");
            }
            IList<RecoveryHealthCheck> checks = new List<RecoveryHealthCheck>();
            object rawChecks;
            if (!document.TryGetValue("checks", out rawChecks) || !(rawChecks is IEnumerable))
            {
                throw new InvalidDataException("Recovery-health checks are missing.");
            }
            foreach (object item in (IEnumerable)rawChecks)
            {
                IDictionary<string, object> check = item as IDictionary<string, object>;
                if (check == null || checks.Count >= 64)
                {
                    throw new InvalidDataException("Recovery-health checks are invalid or unbounded.");
                }
                string status = ReadString(check, "status");
                if (status != "pass" && status != "warn" && status != "fail")
                {
                    throw new InvalidDataException("Recovery-health check status is invalid.");
                }
                checks.Add(new RecoveryHealthCheck(
                    ReadString(check, "id"),
                    status,
                    ReadString(check, "summary"),
                    ReadOptionalString(check, "detail") ?? string.Empty));
            }
            if (checks.Count == 0)
            {
                throw new InvalidDataException("Recovery-health report contains no checks.");
            }
            long failed = ReadLong(document, "failed_check_count");
            long warnings = ReadLong(document, "warning_check_count");
            if (failed < 0 || failed > checks.Count || warnings < 0 || warnings > checks.Count)
            {
                throw new InvalidDataException("Recovery-health check counts are invalid.");
            }
            return RecoveryHealthReport.Success(
                overall,
                ReadOptionalString(document, "repository_id") ?? string.Empty,
                ReadOptionalLong(document, "repository_format") ?? 0,
                ReadOptionalLong(document, "free_bytes"),
                ReadLong(document, "reserve_bytes"),
                ReadOptionalLong(document, "active_lock_count"),
                checked((int)failed),
                checked((int)warnings),
                checks);
        }

        private static string JoinArguments(IEnumerable<string> arguments)
        {
            List<string> quoted = new List<string>();
            foreach (string argument in arguments) quoted.Add(Quote(argument ?? string.Empty));
            return string.Join(" ", quoted.ToArray());
        }

        private static string Quote(string value)
        {
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return value;
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char item in value)
            {
                if (item == '\\') { slashes++; continue; }
                if (item == '"')
                {
                    result.Append('\\', slashes * 2 + 1).Append('"');
                    slashes = 0;
                    continue;
                }
                if (slashes > 0) { result.Append('\\', slashes); slashes = 0; }
                result.Append(item);
            }
            if (slashes > 0) result.Append('\\', slashes * 2);
            return result.Append('"').ToString();
        }

        private static bool IsChildPath(string candidate, string parent)
        {
            string root = SourceConfiguration.NormalizePath(parent).TrimEnd('\\') + "\\";
            return SourceConfiguration.NormalizePath(candidate).StartsWith(
                root, StringComparison.OrdinalIgnoreCase);
        }

        private static bool PathEquals(string first, string second)
        {
            return string.Equals(
                SourceConfiguration.NormalizePath(first),
                SourceConfiguration.NormalizePath(second),
                StringComparison.OrdinalIgnoreCase);
        }

        private static string Sanitize(string value)
        {
            string text = string.IsNullOrWhiteSpace(value)
                ? "Recovery readiness could not be inspected."
                : value.Trim();
            if (text.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("dpapi", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("RESTIC_", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "Recovery readiness could not be inspected without exposing credential details.";
            }
            return text.Length > 1000 ? text.Substring(0, 1000) : text;
        }

        private sealed class BoundedUtf8Capture
        {
            private readonly Stream reader;
            private readonly int maximumBytes;
            private readonly MemoryStream value;
            private readonly Thread thread;
            private string decodedValue;

            internal BoundedUtf8Capture(Stream reader, int maximumBytes)
            {
                this.reader = reader;
                this.maximumBytes = maximumBytes;
                value = new MemoryStream(Math.Min(maximumBytes, 8192));
                thread = new Thread(ReadAll);
                thread.IsBackground = true;
            }

            internal bool ExceededLimit { get; private set; }
            internal bool Failed { get; private set; }
            internal int ByteCount { get; private set; }
            internal string Value { get { return decodedValue ?? string.Empty; } }

            internal void Start()
            {
                thread.Start();
            }

            internal void JoinUntil(DateTime deadline)
            {
                TimeSpan remaining = deadline - DateTime.UtcNow;
                int milliseconds = remaining <= TimeSpan.Zero
                    ? 0
                    : (int)Math.Min(int.MaxValue, Math.Ceiling(remaining.TotalMilliseconds));
                thread.Join(milliseconds);
                if (thread.IsAlive)
                {
                    Failed = true;
                    return;
                }
                if (!ExceededLimit && !Failed)
                {
                    try
                    {
                        decodedValue = new UTF8Encoding(false, true).GetString(value.ToArray());
                    }
                    catch
                    {
                        Failed = true;
                    }
                }
            }

            private void ReadAll()
            {
                try
                {
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        if (ByteCount > maximumBytes - count)
                        {
                            ExceededLimit = true;
                        }
                        else if (!ExceededLimit)
                        {
                            value.Write(buffer, 0, count);
                        }
                        ByteCount = ByteCount > int.MaxValue - count
                            ? int.MaxValue
                            : ByteCount + count;
                    }
                }
                catch
                {
                    Failed = true;
                }
            }
        }

        private static string ReadString(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || !(value is string))
                throw new InvalidDataException("Recovery-health field is missing: " + name);
            return (string)value;
        }

        private static string ReadOptionalString(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null) return null;
            if (!(value is string)) throw new InvalidDataException("Recovery-health field is invalid: " + name);
            return (string)value;
        }

        private static long ReadLong(IDictionary<string, object> document, string name)
        {
            long? value = ReadOptionalLong(document, name);
            if (!value.HasValue) throw new InvalidDataException("Recovery-health number is missing: " + name);
            return value.Value;
        }

        private static long? ReadOptionalLong(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null) return null;
            if (value is bool) throw new InvalidDataException("Recovery-health number is invalid: " + name);
            try { return Convert.ToInt64(value, CultureInfo.InvariantCulture); }
            catch (Exception error) { throw new InvalidDataException("Recovery-health number is invalid: " + name, error); }
        }
    }

    internal sealed class CredentialRepairResult
    {
        public bool Succeeded { get; private set; }
        public bool UserCancelled { get; private set; }
        public string ErrorMessage { get; private set; }
        public RecoveryHealthReport Health { get; private set; }

        internal static CredentialRepairResult Success(RecoveryHealthReport health)
        {
            return new CredentialRepairResult { Succeeded = true, Health = health };
        }

        internal static CredentialRepairResult Cancelled()
        {
            return new CredentialRepairResult { UserCancelled = true };
        }

        internal static CredentialRepairResult Failure(string message, RecoveryHealthReport health)
        {
            return new CredentialRepairResult
            {
                ErrorMessage = string.IsNullOrWhiteSpace(message)
                    ? "The active credential could not be repaired."
                    : message,
                Health = health
            };
        }
    }

    internal static class CredentialRepairLauncher
    {
        internal static CredentialRepairResult Repair(
            SourceConfiguration configuration,
            Action onElevatedProcessStarted)
        {
            if (configuration == null)
                return CredentialRepairResult.Failure("Protected configuration is unavailable.", null);
            try
            {
                string installRoot = SourceConfiguration.NormalizePath(configuration.InstallRoot);
                string python = SourceConfiguration.NormalizePath(Path.Combine(installRoot, EngineProfile.Current.PythonRelativePath));
                string repair = SourceConfiguration.NormalizePath(Path.Combine(installRoot, "credential_repair.py"));
                string config = SourceConfiguration.NormalizePath(configuration.ConfigurationPath);
                if (!File.Exists(python) || !File.Exists(repair) || !File.Exists(config))
                    return CredentialRepairResult.Failure("The protected credential-repair runtime is missing.", null);
                string sid = WindowsIdentity.GetCurrent().User.Value;
                string hash = FileSha256(config);
                string[] arguments =
                {
                    "-E", "-S", "-B", repair,
                    "--config", config,
                    "--expected-config-sha256", hash,
                    "--expected-plan-id", configuration.PlanId,
                    "--expected-generation", configuration.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                    "--expected-user-sid", sid
                };
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = python;
                start.Arguments = JoinArguments(arguments);
                start.WorkingDirectory = installRoot;
                start.UseShellExecute = true;
                start.Verb = "runas";
                start.WindowStyle = ProcessWindowStyle.Hidden;
                using (Process process = Process.Start(start))
                {
                    if (process == null)
                        return CredentialRepairResult.Failure("Windows did not start credential repair.", null);
                    if (onElevatedProcessStarted != null) onElevatedProcessStarted();
                    if (!process.WaitForExit(120000))
                        return CredentialRepairResult.Failure(
                            "Credential repair is still running; re-run readiness checks after it finishes.",
                            null);
                    if (process.ExitCode != 0)
                    {
                        RecoveryHealthReport failedHealth = RecoveryHealthLauncher.Inspect(configuration);
                        return CredentialRepairResult.Failure(
                            "The configured recovery key could not repair the active credential. Review the independent checks.",
                            failedHealth);
                    }
                }
                RecoveryHealthReport health = RecoveryHealthLauncher.Inspect(configuration);
                if (!health.Loaded || !CheckPassed(health, "active_credential") ||
                    !CheckPassed(health, "recovery_key"))
                {
                    return CredentialRepairResult.Failure(
                        "Credential repair finished, but independent authentication did not pass.",
                        health);
                }
                return CredentialRepairResult.Success(health);
            }
            catch (Win32Exception error)
            {
                return error.NativeErrorCode == 1223
                    ? CredentialRepairResult.Cancelled()
                    : CredentialRepairResult.Failure(Sanitize(error.Message), null);
            }
            catch (Exception error)
            {
                return CredentialRepairResult.Failure(Sanitize(error.Message), null);
            }
        }

        private static bool CheckPassed(RecoveryHealthReport report, string id)
        {
            foreach (RecoveryHealthCheck check in report.Checks)
            {
                if (string.Equals(check.Id, id, StringComparison.Ordinal) && check.Status == "pass")
                    return true;
            }
            return false;
        }

        private static string FileSha256(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] digest = algorithm.ComputeHash(stream);
                StringBuilder builder = new StringBuilder(64);
                foreach (byte value in digest) builder.Append(value.ToString("x2", CultureInfo.InvariantCulture));
                return builder.ToString();
            }
        }

        private static string JoinArguments(IEnumerable<string> arguments)
        {
            List<string> values = new List<string>();
            foreach (string value in arguments) values.Add(Quote(value ?? string.Empty));
            return string.Join(" ", values.ToArray());
        }

        private static string Quote(string value)
        {
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return value;
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char item in value)
            {
                if (item == '\\') { slashes++; continue; }
                if (item == '"')
                {
                    result.Append('\\', slashes * 2 + 1).Append('"');
                    slashes = 0;
                    continue;
                }
                if (slashes > 0) { result.Append('\\', slashes); slashes = 0; }
                result.Append(item);
            }
            if (slashes > 0) result.Append('\\', slashes * 2);
            return result.Append('"').ToString();
        }

        private static string Sanitize(string message)
        {
            string value = string.IsNullOrWhiteSpace(message)
                ? "Credential repair failed."
                : message.Trim();
            if (value.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("dpapi", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("RESTIC_", StringComparison.OrdinalIgnoreCase) >= 0)
                return "Credential repair failed without exposing credential details.";
            return value.Length > 1000 ? value.Substring(0, 1000) : value;
        }
    }

    internal sealed class StaleLockRepairResult
    {
        public bool Succeeded { get; private set; }
        public bool UserCancelled { get; private set; }
        public string ErrorMessage { get; private set; }
        public RecoveryHealthReport Health { get; private set; }

        internal static StaleLockRepairResult Success(RecoveryHealthReport health)
        {
            return new StaleLockRepairResult { Succeeded = true, Health = health };
        }

        internal static StaleLockRepairResult Cancelled()
        {
            return new StaleLockRepairResult { UserCancelled = true };
        }

        internal static StaleLockRepairResult Failure(string message, RecoveryHealthReport health)
        {
            return new StaleLockRepairResult
            {
                ErrorMessage = string.IsNullOrWhiteSpace(message)
                    ? "Repository locks could not be repaired safely."
                    : message,
                Health = health
            };
        }
    }

    internal static class StaleLockRepairLauncher
    {
        internal static StaleLockRepairResult Repair(
            SourceConfiguration configuration,
            Action onElevatedProcessStarted)
        {
            if (configuration == null)
                return StaleLockRepairResult.Failure("Protected configuration is unavailable.", null);
            try
            {
                string installRoot = SourceConfiguration.NormalizePath(configuration.InstallRoot);
                string python = SourceConfiguration.NormalizePath(Path.Combine(installRoot, EngineProfile.Current.PythonRelativePath));
                string script = SourceConfiguration.NormalizePath(Path.Combine(installRoot, "stale_lock_repair.py"));
                string config = SourceConfiguration.NormalizePath(configuration.ConfigurationPath);
                if (!File.Exists(python) || !File.Exists(script) || !File.Exists(config))
                    return StaleLockRepairResult.Failure("The protected stale-lock helper is missing.", null);
                string sid = WindowsIdentity.GetCurrent().User.Value;
                string hash = FileSha256(config);
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = python;
                start.Arguments = JoinArguments(new[]
                {
                    "-E", "-S", "-B", script,
                    "--config", config,
                    "--expected-config-sha256", hash,
                    "--expected-plan-id", configuration.PlanId,
                    "--expected-generation", configuration.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                    "--expected-user-sid", sid
                });
                start.WorkingDirectory = installRoot;
                start.UseShellExecute = true;
                start.Verb = "runas";
                start.WindowStyle = ProcessWindowStyle.Hidden;
                int exitCode;
                using (Process process = Process.Start(start))
                {
                    if (process == null)
                        return StaleLockRepairResult.Failure("Windows did not start stale-lock repair.", null);
                    if (onElevatedProcessStarted != null) onElevatedProcessStarted();
                    if (!process.WaitForExit(120000))
                        return StaleLockRepairResult.Failure(
                            "Stale-lock repair is still running; run readiness checks again after it finishes.",
                            null);
                    exitCode = process.ExitCode;
                }
                RecoveryHealthReport health = RecoveryHealthLauncher.Inspect(configuration);
                if (exitCode == 0 && health.Loaded &&
                    health.ActiveLockCount.HasValue && health.ActiveLockCount.Value == 0)
                    return StaleLockRepairResult.Success(health);
                if (exitCode == 3 && health.Loaded)
                    return StaleLockRepairResult.Failure(
                        "Restic retained one or more locks because it did not classify them as stale.",
                        health);
                return StaleLockRepairResult.Failure(
                    "Stale-lock repair was blocked or could not be independently verified.",
                    health);
            }
            catch (Win32Exception error)
            {
                return error.NativeErrorCode == 1223
                    ? StaleLockRepairResult.Cancelled()
                    : StaleLockRepairResult.Failure(Sanitize(error.Message), null);
            }
            catch (Exception error)
            {
                return StaleLockRepairResult.Failure(Sanitize(error.Message), null);
            }
        }

        private static string FileSha256(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] digest = algorithm.ComputeHash(stream);
                StringBuilder builder = new StringBuilder(64);
                foreach (byte value in digest) builder.Append(value.ToString("x2", CultureInfo.InvariantCulture));
                return builder.ToString();
            }
        }

        private static string JoinArguments(IEnumerable<string> arguments)
        {
            List<string> values = new List<string>();
            foreach (string value in arguments) values.Add(Quote(value ?? string.Empty));
            return string.Join(" ", values.ToArray());
        }

        private static string Quote(string value)
        {
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return value;
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char item in value)
            {
                if (item == '\\') { slashes++; continue; }
                if (item == '"')
                {
                    result.Append('\\', slashes * 2 + 1).Append('"');
                    slashes = 0;
                    continue;
                }
                if (slashes > 0) { result.Append('\\', slashes); slashes = 0; }
                result.Append(item);
            }
            if (slashes > 0) result.Append('\\', slashes * 2);
            return result.Append('"').ToString();
        }

        private static string Sanitize(string message)
        {
            string value = string.IsNullOrWhiteSpace(message)
                ? "Stale-lock repair failed."
                : message.Trim();
            if (value.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("dpapi", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("RESTIC_", StringComparison.OrdinalIgnoreCase) >= 0)
                return "Stale-lock repair failed without exposing credential details.";
            return value.Length > 1000 ? value.Substring(0, 1000) : value;
        }
    }

    internal sealed class AnomalyReviewResult
    {
        public bool Succeeded { get; private set; }
        public bool UserCancelled { get; private set; }
        public string ErrorMessage { get; private set; }

        internal static AnomalyReviewResult Success()
        {
            return new AnomalyReviewResult { Succeeded = true };
        }

        internal static AnomalyReviewResult Cancelled()
        {
            return new AnomalyReviewResult { UserCancelled = true };
        }

        internal static AnomalyReviewResult Failure(string message)
        {
            return new AnomalyReviewResult
            {
                ErrorMessage = string.IsNullOrWhiteSpace(message)
                    ? EngineProfile.Current.AnomalyReview.MismatchMessage
                    : message
            };
        }
    }

    internal static class AnomalyReviewLauncher
    {
        private const int MaximumJsonBytes = 4 * 1024 * 1024;

        internal static AnomalyReviewResult AcknowledgeReview(
            SourceConfiguration configuration,
            TelemetrySnapshot snapshot,
            Action onElevatedProcessStarted)
        {
            if (configuration == null || snapshot == null)
                return AnomalyReviewResult.Failure(
                    "The protected configuration or held backup is unavailable.");
            if (!snapshot.NeedsAnomalyReview ||
                string.IsNullOrWhiteSpace(snapshot.RunId) ||
                !IsSha256(snapshot.SnapshotId))
                return AnomalyReviewResult.Failure(
                    "The selected backup is not an exact, reviewable anomaly hold.");

            try
            {
                string installRoot = SourceConfiguration.NormalizePath(configuration.InstallRoot);
                string python = SourceConfiguration.NormalizePath(
                    Path.Combine(installRoot, EngineProfile.Current.PythonRelativePath));
                string script = SourceConfiguration.NormalizePath(
                    Path.Combine(installRoot, "anomaly_review.py"));
                string config = SourceConfiguration.NormalizePath(configuration.ConfigurationPath);
                string evidencePath = SourceConfiguration.NormalizePath(
                    Path.Combine(configuration.StateDirectory, "last-success.json"));
                string acknowledgementPath = SourceConfiguration.NormalizePath(
                    Path.Combine(configuration.StateDirectory, "anomaly-acknowledgement.json"));
                if (!IsRegularFile(python) || !IsRegularFile(script) ||
                    !IsRegularFile(config) || !IsRegularFile(evidencePath))
                    return AnomalyReviewResult.Failure(
                        "The protected anomaly-review helper or its verified evidence is missing.");

                IDictionary<string, object> evidence = ReadJsonObject(evidencePath);
                string repositoryId = ReadString(evidence, "repository_id");
                if (!EvidenceMatches(configuration, snapshot, evidence, repositoryId))
                    return AnomalyReviewResult.Failure(
                        "The latest verified backup no longer matches the change set shown in the dashboard.");

                string sid = WindowsIdentity.GetCurrent().User.Value;
                string configHash = FileSha256(config);
                string evidenceHash = FileSha256(evidencePath);
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = python;
                start.Arguments = JoinArguments(new[]
                {
                    "-E", "-S", "-B", script,
                    "--config", config,
                    "--expected-config-sha256", configHash,
                    "--expected-plan-id", configuration.PlanId,
                    "--expected-generation", configuration.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                    "--expected-user-sid", sid,
                    "--expected-run-id", snapshot.RunId,
                    "--expected-snapshot-id", snapshot.SnapshotId,
                    "--expected-evidence-sha256", evidenceHash
                });
                start.WorkingDirectory = installRoot;
                start.UseShellExecute = true;
                start.Verb = "runas";
                start.WindowStyle = ProcessWindowStyle.Hidden;
                int exitCode;
                using (Process process = Process.Start(start))
                {
                    if (process == null)
                        return AnomalyReviewResult.Failure(
                            "Windows did not start anomaly review.");
                    if (onElevatedProcessStarted != null) onElevatedProcessStarted();
                    if (!process.WaitForExit(180000))
                        return AnomalyReviewResult.Failure(
                            "Anomaly review is still running. Keep the app open and refresh after it finishes.");
                    exitCode = process.ExitCode;
                }
                if (exitCode != 0)
                    return AnomalyReviewResult.Failure(
                        EngineProfile.Current.AnomalyReview.HelperStoppedMessage);
                if (FileSha256(evidencePath) != evidenceHash ||
                    !IsRegularFile(acknowledgementPath))
                    return AnomalyReviewResult.Failure(
                        "Approval returned, but the exact protected evidence could not be confirmed.");

                IDictionary<string, object> acknowledgement = ReadJsonObject(
                    acknowledgementPath);
                if (!AcknowledgementMatches(
                    acknowledgement,
                    configuration,
                    snapshot,
                    repositoryId,
                    evidenceHash,
                    sid))
                    return AnomalyReviewResult.Failure(
                        "The protected approval does not match this exact backup generation.");
                return AnomalyReviewResult.Success();
            }
            catch (Win32Exception error)
            {
                return error.NativeErrorCode == 1223
                    ? AnomalyReviewResult.Cancelled()
                    : AnomalyReviewResult.Failure(Sanitize(error.Message));
            }
            catch (Exception error)
            {
                return AnomalyReviewResult.Failure(Sanitize(error.Message));
            }
        }

        private static bool EvidenceMatches(
            SourceConfiguration configuration,
            TelemetrySnapshot snapshot,
            IDictionary<string, object> evidence,
            string repositoryId)
        {
            string state = ReadString(evidence, "state");
            return (state == "success" || state == "success_unchanged")
                && ReadBool(evidence, "verification_complete")
                && ReadBool(evidence, "maintenance_hold")
                && ReadString(evidence, "plan_id") == configuration.PlanId
                && ReadLong(evidence, "config_generation") == configuration.ConfigGeneration
                && IsSha256(repositoryId)
                && ReadString(evidence, "run_id") == snapshot.RunId
                && ReadString(evidence, "snapshot_id") == snapshot.SnapshotId;
        }

        private static bool AcknowledgementMatches(
            IDictionary<string, object> acknowledgement,
            SourceConfiguration configuration,
            TelemetrySnapshot snapshot,
            string repositoryId,
            string evidenceHash,
            string sid)
        {
            object scopeValue;
            IEnumerable scope = acknowledgement.TryGetValue("scope", out scopeValue)
                ? scopeValue as IEnumerable
                : null;
            // The scope the active engine writes: an acknowledgement for Rewindle, an off-site promotion approval for
            // the legacy personal edition. Everything else the record is bound to is the same for both.
            bool hasReviewScope = false;
            if (scope != null && !(scope is string))
            {
                foreach (object item in scope)
                {
                    if (EngineProfile.Current.IsAnomalyReviewScope(
                        Convert.ToString(item, CultureInfo.InvariantCulture)))
                    {
                        hasReviewScope = true;
                    }
                }
            }
            return ReadString(acknowledgement, "schema")
                    == EngineProfile.Current.AnomalyReviewSchema
                && ReadLong(acknowledgement, "schema_version") == 1
                && ReadString(acknowledgement, "decision") == "approved"
                && ReadBool(acknowledgement, "maintenance_hold_remains")
                && hasReviewScope
                && ReadString(acknowledgement, "plan_id") == configuration.PlanId
                && ReadLong(acknowledgement, "config_generation")
                    == configuration.ConfigGeneration
                && ReadString(acknowledgement, "repository_id") == repositoryId
                && ReadString(acknowledgement, "run_id") == snapshot.RunId
                && ReadString(acknowledgement, "snapshot_id") == snapshot.SnapshotId
                && ReadString(acknowledgement, "backup_evidence_sha256") == evidenceHash
                && string.Equals(
                    ReadString(acknowledgement, "reviewer_sid"),
                    sid,
                    StringComparison.OrdinalIgnoreCase)
                && !ReadBool(acknowledgement, "snapshots_modified")
                && !ReadBool(acknowledgement, "repository_modified");
        }

        private static IDictionary<string, object> ReadJsonObject(string path)
        {
            FileInfo file = new FileInfo(path);
            if (!file.Exists || file.Length <= 0 || file.Length > MaximumJsonBytes ||
                (file.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Protected anomaly-review evidence is unsafe.");
            object parsed = new JavaScriptSerializer().DeserializeObject(
                File.ReadAllText(path, Encoding.UTF8));
            IDictionary<string, object> document = parsed as IDictionary<string, object>;
            if (document == null)
                throw new InvalidDataException("Protected anomaly-review evidence is invalid.");
            return document;
        }

        private static string ReadString(IDictionary<string, object> document, string key)
        {
            object value;
            return document != null && document.TryGetValue(key, out value)
                ? value as string ?? string.Empty
                : string.Empty;
        }

        private static long ReadLong(IDictionary<string, object> document, string key)
        {
            object value;
            if (document == null || !document.TryGetValue(key, out value) || value == null)
                return -1;
            try { return Convert.ToInt64(value, CultureInfo.InvariantCulture); }
            catch { return -1; }
        }

        private static bool ReadBool(IDictionary<string, object> document, string key)
        {
            object value;
            return document != null && document.TryGetValue(key, out value)
                && value is bool && (bool)value;
        }

        private static bool IsRegularFile(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path) || Directory.Exists(path))
                return false;
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0;
        }

        private static bool IsSha256(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length != 64) return false;
            foreach (char item in value)
            {
                if (!((item >= '0' && item <= '9') || (item >= 'a' && item <= 'f')))
                    return false;
            }
            return true;
        }

        private static string FileSha256(string path)
        {
            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] digest = algorithm.ComputeHash(stream);
                StringBuilder builder = new StringBuilder(64);
                foreach (byte value in digest)
                    builder.Append(value.ToString("x2", CultureInfo.InvariantCulture));
                return builder.ToString();
            }
        }

        private static string JoinArguments(IEnumerable<string> arguments)
        {
            List<string> values = new List<string>();
            foreach (string value in arguments) values.Add(Quote(value ?? string.Empty));
            return string.Join(" ", values.ToArray());
        }

        private static string Quote(string value)
        {
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
                return value;
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char item in value)
            {
                if (item == '\\') { slashes++; continue; }
                if (item == '"')
                {
                    result.Append('\\', slashes * 2 + 1).Append('"');
                    slashes = 0;
                    continue;
                }
                if (slashes > 0) { result.Append('\\', slashes); slashes = 0; }
                result.Append(item);
            }
            if (slashes > 0) result.Append('\\', slashes * 2);
            return result.Append('"').ToString();
        }

        private static string Sanitize(string message)
        {
            string value = string.IsNullOrWhiteSpace(message)
                ? "Anomaly review failed."
                : message.Trim();
            if (value.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("dpapi", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("RESTIC_", StringComparison.OrdinalIgnoreCase) >= 0)
                return "Anomaly review failed without exposing credential details.";
            return value.Length > 1000 ? value.Substring(0, 1000) : value;
        }
    }

    internal sealed class KeyRotationResult
    {
        public bool Succeeded { get; private set; }
        public bool UserCancelled { get; private set; }
        public string ErrorMessage { get; private set; }
        public RecoveryHealthReport Health { get; private set; }

        internal static KeyRotationResult Success(RecoveryHealthReport health)
        {
            return new KeyRotationResult { Succeeded = true, Health = health };
        }

        internal static KeyRotationResult Cancelled()
        {
            return new KeyRotationResult { UserCancelled = true };
        }

        internal static KeyRotationResult Failure(string message, RecoveryHealthReport health)
        {
            return new KeyRotationResult
            {
                ErrorMessage = string.IsNullOrWhiteSpace(message)
                    ? "Repository credentials could not be rotated safely."
                    : message,
                Health = health
            };
        }
    }

    internal static class KeyRotationLauncher
    {
        internal static KeyRotationResult Rotate(
            SourceConfiguration configuration,
            Action onElevatedProcessStarted)
        {
            if (configuration == null)
                return KeyRotationResult.Failure("Protected configuration is unavailable.", null);
            try
            {
                string installRoot = SourceConfiguration.NormalizePath(configuration.InstallRoot);
                string python = SourceConfiguration.NormalizePath(Path.Combine(installRoot, EngineProfile.Current.PythonRelativePath));
                string script = SourceConfiguration.NormalizePath(Path.Combine(installRoot, "key_rotation.py"));
                string config = SourceConfiguration.NormalizePath(configuration.ConfigurationPath);
                if (!File.Exists(python) || !File.Exists(script) || !File.Exists(config))
                    return KeyRotationResult.Failure("The protected key-rotation helper is missing.", null);
                string sid = WindowsIdentity.GetCurrent().User.Value;
                string hash = FileSha256(config);
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = python;
                start.Arguments = JoinArguments(new[]
                {
                    "-E", "-S", "-B", script,
                    "--config", config,
                    "--expected-config-sha256", hash,
                    "--expected-plan-id", configuration.PlanId,
                    "--expected-generation", configuration.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                    "--expected-user-sid", sid
                });
                start.WorkingDirectory = installRoot;
                start.UseShellExecute = true;
                start.Verb = "runas";
                start.WindowStyle = ProcessWindowStyle.Hidden;
                int exitCode;
                using (Process process = Process.Start(start))
                {
                    if (process == null)
                        return KeyRotationResult.Failure("Windows did not start key rotation.", null);
                    if (onElevatedProcessStarted != null) onElevatedProcessStarted();
                    if (!process.WaitForExit(600000))
                        return KeyRotationResult.Failure(
                            "Key rotation is still running; keep the app open and run readiness checks again after it finishes.",
                            null);
                    exitCode = process.ExitCode;
                }
                RecoveryHealthReport health = RecoveryHealthLauncher.Inspect(configuration);
                if (exitCode == 0 && health.Loaded &&
                    CheckPassed(health, "active_credential") &&
                    CheckPassed(health, "recovery_key") &&
                    CheckPassed(health, "rotation_rollback_key") &&
                    CheckPassed(health, "pending_transaction"))
                    return KeyRotationResult.Success(health);
                return KeyRotationResult.Failure(
                    exitCode == 0
                        ? "Key rotation finished, but independent current and rollback authentication did not pass."
                        : "Key rotation stopped safely. If a protected transaction is pending, run rotation again to recover it.",
                    health);
            }
            catch (Win32Exception error)
            {
                return error.NativeErrorCode == 1223
                    ? KeyRotationResult.Cancelled()
                    : KeyRotationResult.Failure(Sanitize(error.Message), null);
            }
            catch (Exception error)
            {
                return KeyRotationResult.Failure(Sanitize(error.Message), null);
            }
        }

        private static bool CheckPassed(RecoveryHealthReport report, string id)
        {
            if (report == null || report.Checks == null) return false;
            foreach (RecoveryHealthCheck check in report.Checks)
            {
                if (string.Equals(check.Id, id, StringComparison.Ordinal) && check.Status == "pass")
                    return true;
            }
            return false;
        }

        private static string FileSha256(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] digest = algorithm.ComputeHash(stream);
                StringBuilder builder = new StringBuilder(64);
                foreach (byte value in digest) builder.Append(value.ToString("x2", CultureInfo.InvariantCulture));
                return builder.ToString();
            }
        }

        private static string JoinArguments(IEnumerable<string> arguments)
        {
            List<string> values = new List<string>();
            foreach (string value in arguments) values.Add(Quote(value ?? string.Empty));
            return string.Join(" ", values.ToArray());
        }

        private static string Quote(string value)
        {
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return value;
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char item in value)
            {
                if (item == '\\') { slashes++; continue; }
                if (item == '"')
                {
                    result.Append('\\', slashes * 2 + 1).Append('"');
                    slashes = 0;
                    continue;
                }
                if (slashes > 0) { result.Append('\\', slashes); slashes = 0; }
                result.Append(item);
            }
            if (slashes > 0) result.Append('\\', slashes * 2);
            return result.Append('"').ToString();
        }

        private static string Sanitize(string message)
        {
            string value = string.IsNullOrWhiteSpace(message)
                ? "Key rotation failed."
                : message.Trim();
            if (value.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("dpapi", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("RESTIC_", StringComparison.OrdinalIgnoreCase) >= 0)
                return "Key rotation failed without exposing credential details.";
            return value.Length > 1000 ? value.Substring(0, 1000) : value;
        }
    }
}
