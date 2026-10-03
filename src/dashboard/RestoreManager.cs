using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Microsoft.Win32.SafeHandles;

namespace ResticBackuper.Dashboard
{
    internal sealed class RestoreSnapshot
    {
        public string Id { get; private set; }
        public string ShortId { get; private set; }
        public string Time { get; private set; }
        public string Hostname { get; private set; }
        public long ConfigGeneration { get; private set; }
        public long FileCount { get; private set; }
        public long ByteCount { get; private set; }
        public string SourceSummary { get; private set; }
        public string BindingState { get; private set; }
        public bool IsLegacyUnbound
        {
            get { return BindingState == "legacy_unbound"; }
        }

        public string WhenDisplay
        {
            get
            {
                DateTime parsed;
                return DateTime.TryParse(
                    Time,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                    out parsed)
                    ? parsed.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)
                    : Time;
            }
        }

        public string SizeDisplay
        {
            get { return FormatBytes(ByteCount); }
        }

        public string GenerationDisplay
        {
            get
            {
                return IsLegacyUnbound
                    ? "Legacy / unbound"
                    : "Generation " + ConfigGeneration.ToString(CultureInfo.InvariantCulture);
            }
        }

        internal RestoreSnapshot(
            string id,
            string shortId,
            string time,
            string hostname,
            long configGeneration,
            long fileCount,
            long byteCount,
            string sourceSummary,
            string bindingState)
        {
            Id = id;
            ShortId = shortId;
            Time = time;
            Hostname = hostname;
            ConfigGeneration = configGeneration;
            FileCount = fileCount;
            ByteCount = byteCount;
            SourceSummary = sourceSummary;
            BindingState = bindingState;
        }

        private static string FormatBytes(long value)
        {
            string[] units = { "B", "KiB", "MiB", "GiB", "TiB" };
            double size = Math.Max(0, value);
            int index = 0;
            while (size >= 1024 && index < units.Length - 1)
            {
                size /= 1024;
                index++;
            }
            return size.ToString(index == 0 ? "0" : "0.0", CultureInfo.CurrentCulture) + " " + units[index];
        }
    }

    internal sealed class RestoreTreeEntry
    {
        public string Name { get; private set; }
        public string EntryPath { get; private set; }
        public string EntryType { get; private set; }
        public long Size { get; private set; }

        public string SizeDisplay
        {
            get
            {
                if (EntryType == "dir")
                {
                    return "Folder";
                }
                string[] units = { "B", "KiB", "MiB", "GiB", "TiB" };
                double value = Math.Max(0, Size);
                int index = 0;
                while (value >= 1024 && index < units.Length - 1)
                {
                    value /= 1024;
                    index++;
                }
                return value.ToString(index == 0 ? "0" : "0.0", CultureInfo.CurrentCulture) + " " + units[index];
            }
        }

        internal RestoreTreeEntry(string name, string path, string type, long size)
        {
            Name = name;
            EntryPath = path;
            EntryType = type;
            Size = size;
        }
    }

    internal sealed class ProtectedRestoreReport
    {
        public string Result { get; private set; }
        public string SnapshotId { get; private set; }
        public string Target { get; private set; }
        public bool Verified { get; private set; }
        public bool PartialTargetRetained { get; private set; }
        public int ResticExitCode { get; private set; }
        public string ErrorMessage { get; private set; }
        public string SnapshotBinding { get; private set; }

        internal ProtectedRestoreReport(
            string result,
            string snapshotId,
            string target,
            bool verified,
            bool partialTargetRetained,
            int resticExitCode,
            string errorMessage,
            string snapshotBinding)
        {
            Result = result;
            SnapshotId = snapshotId;
            Target = target;
            Verified = verified;
            PartialTargetRetained = partialTargetRetained;
            ResticExitCode = resticExitCode;
            ErrorMessage = errorMessage;
            SnapshotBinding = snapshotBinding;
        }
    }

    internal sealed class RestoreManagerProgress
    {
        public string Stage { get; private set; }
        public string Message { get; private set; }
        public int Percent { get; private set; }

        internal RestoreManagerProgress(string stage, string message, int percent)
        {
            Stage = stage ?? string.Empty;
            Message = message ?? string.Empty;
            Percent = Math.Max(0, Math.Min(100, percent));
        }
    }

    internal sealed class RestoreManagerResult
    {
        public bool Succeeded { get; private set; }
        public bool UserCancelled { get; private set; }
        public bool Partial { get; private set; }
        public int ExitCode { get; private set; }
        public string ErrorMessage { get; private set; }
        public IList<RestoreSnapshot> Snapshots { get; private set; }
        public IList<RestoreTreeEntry> Entries { get; private set; }
        public ProtectedRestoreReport Report { get; private set; }
        public bool? HistoryRecorded { get; private set; }
        public string HistoryError { get; private set; }

        internal static RestoreManagerResult SuccessSnapshots(IList<RestoreSnapshot> snapshots)
        {
            return new RestoreManagerResult
            {
                Succeeded = true,
                ExitCode = 0,
                Snapshots = snapshots ?? new List<RestoreSnapshot>()
            };
        }

        internal static RestoreManagerResult SuccessTree(IList<RestoreTreeEntry> entries)
        {
            return new RestoreManagerResult
            {
                Succeeded = true,
                ExitCode = 0,
                Entries = entries ?? new List<RestoreTreeEntry>()
            };
        }

        internal static RestoreManagerResult SuccessRestore(
            ProtectedRestoreReport report,
            bool? historyRecorded,
            string historyError)
        {
            return new RestoreManagerResult
            {
                Succeeded = true,
                ExitCode = 0,
                Report = report,
                HistoryRecorded = historyRecorded,
                HistoryError = historyError
            };
        }

        internal static RestoreManagerResult PartialRestore(
            ProtectedRestoreReport report,
            string message,
            int exitCode,
            bool? historyRecorded,
            string historyError)
        {
            return new RestoreManagerResult
            {
                Partial = true,
                Report = report,
                ErrorMessage = message,
                ExitCode = exitCode,
                HistoryRecorded = historyRecorded,
                HistoryError = historyError
            };
        }

        internal static RestoreManagerResult EvidenceFailure(
            ProtectedRestoreReport report,
            string message,
            int exitCode,
            string historyError)
        {
            return new RestoreManagerResult
            {
                Report = report,
                ErrorMessage = message,
                ExitCode = exitCode,
                HistoryRecorded = false,
                HistoryError = historyError
            };
        }

        internal static RestoreManagerResult Cancelled()
        {
            return new RestoreManagerResult { UserCancelled = true, ExitCode = 1223 };
        }

        internal static RestoreManagerResult Failure(string message, int exitCode)
        {
            return new RestoreManagerResult
            {
                ErrorMessage = string.IsNullOrWhiteSpace(message)
                    ? "The protected restore operation failed."
                    : message,
                ExitCode = exitCode
            };
        }
    }

    internal static class RestoreManagerLauncher
    {
        private static string RequestDomain
        {
            get { return EngineProfile.Current.RestoreRequestDomain; }
        }

        private const string ResultDirectoryName = "RestoreManagerResults";
        private const int MaximumResultBytes = 8 * 1024 * 1024;

        internal static RestoreManagerResult ListSnapshots(
            SourceConfiguration configuration,
            Action onElevatedProcessStarted,
            Action<RestoreManagerProgress> onProgress)
        {
            return ListSnapshots(configuration, null, null, onElevatedProcessStarted, onProgress);
        }

        // With a restore approval session (see RestoreSessionHost) the request goes to its broker, which is started, with
        // one Windows approval, only when the flow has none that is still running; without one it is its own elevated
        // request. `onApprovalRequested` runs just before Windows asks for approval, `onElevatedProcessStarted` once it was
        // given (at once when a running session serves the request).
        internal static RestoreManagerResult ListSnapshots(
            SourceConfiguration configuration,
            RestoreSessionHost session,
            Action onApprovalRequested,
            Action onElevatedProcessStarted,
            Action<RestoreManagerProgress> onProgress)
        {
            return Run(
                configuration,
                "list_snapshots",
                string.Empty,
                string.Empty,
                string.Empty,
                new string[0],
                false,
                session,
                onApprovalRequested,
                onElevatedProcessStarted,
                onProgress);
        }

        internal static RestoreManagerResult ListTree(
            SourceConfiguration configuration,
            string snapshotId,
            string treePath,
            bool allowLegacyUnbound,
            Action onElevatedProcessStarted,
            Action<RestoreManagerProgress> onProgress)
        {
            return ListTree(
                configuration, snapshotId, treePath, allowLegacyUnbound, null, null, onElevatedProcessStarted, onProgress);
        }

        internal static RestoreManagerResult ListTree(
            SourceConfiguration configuration,
            string snapshotId,
            string treePath,
            bool allowLegacyUnbound,
            RestoreSessionHost session,
            Action onApprovalRequested,
            Action onElevatedProcessStarted,
            Action<RestoreManagerProgress> onProgress)
        {
            return Run(
                configuration,
                "list_tree",
                NormalizeSnapshotId(snapshotId),
                NormalizeTreePath(treePath),
                string.Empty,
                new string[0],
                allowLegacyUnbound,
                session,
                onApprovalRequested,
                onElevatedProcessStarted,
                onProgress);
        }

        internal static RestoreManagerResult Restore(
            SourceConfiguration configuration,
            string snapshotId,
            string target,
            IList<string> includes,
            bool allowLegacyUnbound,
            Action onElevatedProcessStarted,
            Action<RestoreManagerProgress> onProgress)
        {
            return Restore(
                configuration, snapshotId, target, includes, allowLegacyUnbound, null, null, onElevatedProcessStarted, onProgress);
        }

        internal static RestoreManagerResult Restore(
            SourceConfiguration configuration,
            string snapshotId,
            string target,
            IList<string> includes,
            bool allowLegacyUnbound,
            RestoreSessionHost session,
            Action onApprovalRequested,
            Action onElevatedProcessStarted,
            Action<RestoreManagerProgress> onProgress)
        {
            string normalizedTarget = SourceConfiguration.NormalizePath(target);
            return Run(
                configuration,
                "restore",
                NormalizeSnapshotId(snapshotId),
                string.Empty,
                normalizedTarget,
                includes ?? new string[0],
                allowLegacyUnbound,
                session,
                onApprovalRequested,
                onElevatedProcessStarted,
                onProgress);
        }

        internal static RestoreManagerResult RunRecoveryDrill(
            SourceConfiguration configuration,
            Action onElevatedProcessStarted,
            Action<RestoreManagerProgress> onProgress)
        {
            return Run(
                configuration,
                "restore_drill",
                string.Empty,
                string.Empty,
                string.Empty,
                new string[0],
                false,
                null,
                null,
                onElevatedProcessStarted,
                onProgress);
        }

        private static RestoreManagerResult Run(
            SourceConfiguration configuration,
            string action,
            string snapshotId,
            string treePath,
            string target,
            IList<string> includes,
            bool allowLegacyUnbound,
            RestoreSessionHost session,
            Action onApprovalRequested,
            Action onElevatedProcessStarted,
            Action<RestoreManagerProgress> onProgress)
        {
            if (configuration == null)
            {
                return RestoreManagerResult.Failure(
                    "The protected backup configuration is unavailable.",
                    -1);
            }
            string managerPath = Path.Combine(
                configuration.InstallRoot,
                EngineProfile.Current.RestoreManagerFileName);
            if (!IsRegularFile(managerPath) || !IsRegularFile(configuration.ConfigurationPath))
            {
                return RestoreManagerResult.Failure(
                    "The protected restore manager is missing from the installation.",
                    -1);
            }
            if (configuration.ConfigGeneration <= 0 ||
                string.IsNullOrWhiteSpace(configuration.PlanId))
            {
                return RestoreManagerResult.Failure(
                    "The protected backup plan migration is incomplete.",
                    -1);
            }

            try
            {
                ValidateRequestFields(
                    action, snapshotId, treePath, target, includes, allowLegacyUnbound);
                string configHash = ComputeFileSha256(configuration.ConfigurationPath);
                string includesJson = new JavaScriptSerializer().Serialize(includes);
                byte[] includeBytes = new UTF8Encoding(false).GetBytes(includesJson);
                string includesHash = ComputeSha256(includeBytes);
                string includesBase64 = Convert.ToBase64String(includeBytes);
                WindowsIdentity identity = WindowsIdentity.GetCurrent();
                string userSid = identity.User == null ? null : identity.User.Value;
                if (string.IsNullOrWhiteSpace(userSid))
                {
                    return RestoreManagerResult.Failure(
                        "The current Windows user SID could not be determined.",
                        -1);
                }
                if (session != null)
                {
                    if (action == "restore_drill")
                    {
                        throw new ArgumentException("A recovery drill is never served by a restore session.");
                    }
                    return RunInSession(
                        session,
                        configuration,
                        action,
                        snapshotId,
                        treePath,
                        target,
                        includesBase64,
                        includesHash,
                        configHash,
                        userSid,
                        allowLegacyUnbound,
                        onApprovalRequested,
                        onElevatedProcessStarted,
                        onProgress);
                }
                string nonce = CreateNonce();
                if (action == "restore_drill")
                {
                    target = BuildRecoveryDrillTarget(nonce);
                }
                string digest = ComputeRequestDigest(
                    userSid,
                    action,
                    configHash,
                    configuration.PlanId,
                    configuration.ConfigGeneration,
                    allowLegacyUnbound,
                    snapshotId,
                    treePath,
                    target,
                    includesHash,
                    nonce);
                string resultRoot = EngineProfile.Current.StateResultDirectory(ResultDirectoryName);
                string resultPath = Path.Combine(resultRoot, nonce + ".json");
                string progressPath = resultPath + ".progress.json";
                if (File.Exists(resultPath) || Directory.Exists(resultPath) ||
                    File.Exists(progressPath) || Directory.Exists(progressPath))
                {
                    return RestoreManagerResult.Failure(
                        "A protected restore result already uses this request nonce.",
                        -1);
                }
                string powerShell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe");
                if (!IsRegularFile(powerShell))
                {
                    return RestoreManagerResult.Failure(
                        "Windows PowerShell is unavailable in System32.",
                        -1);
                }

                List<string> arguments = new List<string>(new[]
                {
                    "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                    "-WindowStyle", "Hidden", "-File", managerPath,
                    "-Action", action,
                    "-IncludesBase64", includesBase64,
                    "-ExpectedUserSid", userSid,
                    "-ExpectedConfigSha256", configHash,
                    "-ExpectedPlanId", configuration.PlanId,
                    "-ExpectedConfigGeneration", configuration.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                    "-AllowLegacyUnbound", allowLegacyUnbound ? "1" : "0",
                    "-ResultPath", resultPath,
                    "-RequestNonce", nonce,
                    "-RequestDigest", digest
                });
                if (snapshotId.Length > 0)
                {
                    arguments.Add("-SnapshotId");
                    arguments.Add(snapshotId);
                }
                if (treePath.Length > 0)
                {
                    arguments.Add("-TreePath");
                    arguments.Add(treePath);
                }
                if (target.Length > 0 && action != "restore_drill")
                {
                    arguments.Add("-Target");
                    arguments.Add(target);
                }

                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = powerShell;
                start.Arguments = BuildArgumentString(arguments);
                start.WorkingDirectory = configuration.InstallRoot;
                start.UseShellExecute = true;
                start.Verb = "runas";
                start.WindowStyle = ProcessWindowStyle.Hidden;
                start.ErrorDialog = false;
                int exitCode;
                InvokeSafely(onApprovalRequested);
                using (Process process = Process.Start(start))
                {
                    if (process == null)
                    {
                        return RestoreManagerResult.Failure(
                            "Windows did not start the protected restore manager.",
                            -1);
                    }
                    InvokeSafely(onElevatedProcessStarted);
                    string lastProgressFingerprint = string.Empty;
                    while (!process.WaitForExit(400))
                    {
                        PublishProgress(
                            progressPath,
                            nonce,
                            digest,
                            userSid,
                            action,
                            configuration.PlanId,
                            configuration.ConfigGeneration,
                            allowLegacyUnbound,
                            snapshotId,
                            target,
                            onProgress,
                            ref lastProgressFingerprint);
                    }
                    process.WaitForExit();
                    exitCode = process.ExitCode;
                    PublishProgress(
                        progressPath,
                        nonce,
                        digest,
                        userSid,
                        action,
                        configuration.PlanId,
                        configuration.ConfigGeneration,
                        allowLegacyUnbound,
                        snapshotId,
                        target,
                        onProgress,
                        ref lastProgressFingerprint);
                }
                return ReadBoundResult(
                    resultPath,
                    nonce,
                    digest,
                    userSid,
                    action,
                    configHash,
                    configuration.PlanId,
                    configuration.ConfigGeneration,
                    allowLegacyUnbound,
                    snapshotId,
                    treePath,
                    target,
                    includesHash,
                    exitCode);
            }
            catch (Win32Exception error)
            {
                return error.NativeErrorCode == 1223
                    ? RestoreManagerResult.Cancelled()
                    : RestoreManagerResult.Failure(Sanitize(error.Message), error.NativeErrorCode);
            }
            catch (Exception error)
            {
                return RestoreManagerResult.Failure(Sanitize(error.Message), -1);
            }
        }

        // One request through the flow's restore approval session. Its result is the document a single request writes to its
        // protected file, bound to the session's nonce and digest, and is checked by the same ValidateResult. A session that
        // had already ended (idle, lifetime, a changed plan) before it read the request is replaced once, with a new approval;
        // a session that ends while serving a request is never asked again for it.
        private static RestoreManagerResult RunInSession(
            RestoreSessionHost session,
            SourceConfiguration configuration,
            string action,
            string snapshotId,
            string treePath,
            string target,
            string includesBase64,
            string includesHash,
            string configHash,
            string userSid,
            bool allowLegacyUnbound,
            Action onApprovalRequested,
            Action onElevatedProcessStarted,
            Action<RestoreManagerProgress> onProgress)
        {
            for (int attempt = 0; attempt < 2; attempt++)
            {
                RestoreSessionClient client = session.Acquire(
                    configuration,
                    configHash,
                    userSid,
                    onApprovalRequested,
                    onElevatedProcessStarted);
                RestoreSessionExchange exchange = client.Execute(
                    action,
                    snapshotId,
                    treePath,
                    target,
                    includesBase64,
                    allowLegacyUnbound,
                    onProgress);
                if (exchange.EndedBeforeRequest)
                {
                    continue;
                }
                if (exchange.Result == null)
                {
                    return RestoreManagerResult.Failure(Sanitize(exchange.Error), -1);
                }
                return ValidateResult(
                    exchange.Result,
                    client.Nonce,
                    client.Digest,
                    userSid,
                    action,
                    configHash,
                    configuration.PlanId,
                    configuration.ConfigGeneration,
                    allowLegacyUnbound,
                    snapshotId,
                    treePath,
                    target,
                    includesHash,
                    exchange.ExitCode);
            }
            return RestoreManagerResult.Failure(
                "The protected restore session ended before it could serve this request. Try again.",
                -1);
        }

        internal static string ComputeRequestDigest(
            string userSid,
            string action,
            string configHash,
            string planId,
            long configGeneration,
            bool allowLegacyUnbound,
            string snapshotId,
            string treePath,
            string target,
            string includesHash,
            string nonce)
        {
            string payload = string.Join("\n", new[]
            {
                RequestDomain,
                userSid,
                action,
                configHash.ToLowerInvariant(),
                planId,
                configGeneration.ToString(CultureInfo.InvariantCulture),
                allowLegacyUnbound ? "1" : "0",
                snapshotId ?? string.Empty,
                treePath ?? string.Empty,
                target ?? string.Empty,
                includesHash.ToLowerInvariant(),
                nonce.ToLowerInvariant()
            });
            return ComputeSha256(new UTF8Encoding(false).GetBytes(payload));
        }

        private static string BuildRecoveryDrillTarget(string nonce)
        {
            if (string.IsNullOrWhiteSpace(nonce) || nonce.Length != 64)
            {
                throw new ArgumentException("The recovery-drill nonce is invalid.");
            }
            string root = EngineProfile.Current.RestoreDrillsDirectory();
            return SourceConfiguration.NormalizePath(Path.Combine(root, "drill-" + nonce));
        }

        private static RestoreManagerResult ReadBoundResult(
            string resultPath,
            string nonce,
            string digest,
            string userSid,
            string action,
            string configHash,
            string planId,
            long generation,
            bool allowLegacyUnbound,
            string snapshotId,
            string treePath,
            string target,
            string includesHash,
            int exitCode)
        {
            for (int attempt = 0; attempt < 20 && !File.Exists(resultPath); attempt++)
            {
                Thread.Sleep(50);
            }
            string resultRoot = Path.GetDirectoryName(resultPath);
            string stateRoot = string.IsNullOrWhiteSpace(resultRoot)
                ? null
                : Path.GetDirectoryName(resultRoot);
            if (!File.Exists(resultPath) || string.IsNullOrWhiteSpace(stateRoot) ||
                !string.Equals(Path.GetFileName(stateRoot), EngineProfile.Current.ProductDirectoryName, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetFileName(resultRoot), ResultDirectoryName, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetFileName(resultPath), nonce + ".json", StringComparison.Ordinal) ||
                !IsRegularFile(resultPath) ||
                !HasProtectedAcl(stateRoot, userSid) || !HasProtectedAcl(resultRoot, userSid))
            {
                return RestoreManagerResult.Failure(
                    "The protected restore manager did not return a trustworthy result.",
                    exitCode);
            }
            try
            {
                using (FileStream stream = new FileStream(
                    resultPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    8192,
                    FileOptions.SequentialScan))
                {
                    if (!HasProtectedAcl(stream.GetAccessControl(), userSid) ||
                        stream.Length <= 0 || stream.Length > MaximumResultBytes)
                    {
                        return RestoreManagerResult.Failure(
                            "The protected restore result file is not trustworthy.",
                            exitCode);
                    }
                    using (StreamReader reader = new StreamReader(
                        stream,
                        new UTF8Encoding(false, true),
                        true,
                        8192,
                        true))
                    {
                        JavaScriptSerializer serializer = new JavaScriptSerializer();
                        serializer.MaxJsonLength = MaximumResultBytes;
                        IDictionary<string, object> document =
                            serializer.DeserializeObject(reader.ReadToEnd()) as
                                IDictionary<string, object>;
                        return ValidateResult(
                            document,
                            nonce,
                            digest,
                            userSid,
                            action,
                            configHash,
                            planId,
                            generation,
                            allowLegacyUnbound,
                            snapshotId,
                            treePath,
                            target,
                            includesHash,
                            exitCode);
                    }
                }
            }
            catch (Exception error)
            {
                return RestoreManagerResult.Failure(
                    "The protected restore result could not be validated: " + Sanitize(error.Message),
                    exitCode);
            }
        }

        private static RestoreManagerResult ValidateResult(
            IDictionary<string, object> document,
            string nonce,
            string digest,
            string userSid,
            string action,
            string configHash,
            string planId,
            long generation,
            bool allowLegacyUnbound,
            string snapshotId,
            string treePath,
            string target,
            string includesHash,
            int exitCode)
        {
            if (document == null || ReadLong(document, "schema_version") != 1 ||
                !FixedEquals(ReadString(document, "request_nonce"), nonce) ||
                !FixedEquals(ReadString(document, "request_digest"), digest) ||
                !FixedEquals(ReadString(document, "request_user_sid"), userSid) ||
                !FixedEquals(ReadString(document, "action"), action) ||
                !FixedEquals(ReadString(document, "expected_config_sha256"), configHash) ||
                !FixedEquals(ReadString(document, "plan_id"), planId) ||
                ReadLong(document, "config_generation") != generation ||
                ReadBoolean(document, "allow_legacy_unbound") != allowLegacyUnbound ||
                (action != "restore_drill" &&
                    !FixedEquals(NullToEmpty(ReadOptionalString(document, "snapshot_id")), snapshotId)) ||
                !FixedEquals(NullToEmpty(ReadOptionalString(document, "tree_path")), treePath) ||
                !PathOrEmptyEquals(ReadOptionalString(document, "target"), target) ||
                !FixedEquals(ReadString(document, "includes_sha256"), includesHash))
            {
                return RestoreManagerResult.Failure(
                    "The protected restore result did not match this request.",
                    exitCode);
            }
            bool ok = ReadBoolean(document, "ok");
            int backendExitCode = checked((int)ReadLong(document, "backend_exit_code"));
            string error = ReadOptionalString(document, "error");
            IDictionary<string, object> payload = ReadOptionalObject(document, "payload");
            bool? historyRecorded = ReadOptionalBoolean(document, "history_recorded");
            string historyError = ReadOptionalString(document, "history_error");
            if (action == "list_snapshots" && ok && exitCode == 0 && backendExitCode == 0)
            {
                return RestoreManagerResult.SuccessSnapshots(ParseSnapshots(payload, planId));
            }
            if (action == "list_tree" && ok && exitCode == 0 && backendExitCode == 0)
            {
                return RestoreManagerResult.SuccessTree(
                    ParseTree(payload, snapshotId, planId, allowLegacyUnbound));
            }
            if ((action == "restore" || action == "restore_drill") && payload != null)
            {
                string actualSnapshotId = action == "restore_drill"
                    ? NullToEmpty(ReadOptionalString(document, "snapshot_id"))
                    : snapshotId;
                if (!IsExactSnapshotId(actualSnapshotId))
                {
                    return RestoreManagerResult.Failure(
                        "The protected restore result returned an invalid snapshot identity.",
                        exitCode);
                }
                ProtectedRestoreReport report = ParseReport(
                    payload, actualSnapshotId, planId, target, allowLegacyUnbound);
                if (action == "restore_drill" && ok && exitCode == 0 &&
                    backendExitCode == 0 && report.Verified && report.Result == "verified")
                {
                    ValidateRecoveryDrillReport(payload, report, generation);
                }
                if (ok && exitCode == 0 && backendExitCode == 0 && report.Verified &&
                    report.Result == "verified")
                {
                    if (action == "restore_drill" && historyRecorded != true)
                    {
                        return RestoreManagerResult.EvidenceFailure(
                            report,
                            "The sample was restored and verified, but readiness evidence was not recorded.",
                            exitCode,
                            Sanitize(historyError));
                    }
                    return RestoreManagerResult.SuccessRestore(
                        report, historyRecorded, Sanitize(historyError));
                }
                if (action == "restore_drill" && !ok && exitCode != 0 &&
                    backendExitCode == 0 && report.Verified && report.Result == "verified" &&
                    historyRecorded == false)
                {
                    return RestoreManagerResult.EvidenceFailure(
                        report,
                        Sanitize(error),
                        exitCode,
                        Sanitize(historyError));
                }
                if (!ok && exitCode != 0 &&
                    (report.Result == "partial" || report.PartialTargetRetained))
                {
                    return RestoreManagerResult.PartialRestore(
                        report,
                        Sanitize(error ?? report.ErrorMessage),
                        exitCode,
                        historyRecorded,
                        Sanitize(historyError));
                }
            }
            if (!ok && exitCode != 0)
            {
                return RestoreManagerResult.Failure(Sanitize(error), exitCode);
            }
            return RestoreManagerResult.Failure(
                "The protected restore result disagreed with the backend exit status.",
                exitCode);
        }

        private static IList<RestoreSnapshot> ParseSnapshots(
            IDictionary<string, object> payload,
            string planId)
        {
            if (payload == null || ReadString(payload, "schema") !=
                    EngineProfile.Current.SnapshotListSchema)
            {
                throw new InvalidDataException("The snapshot-list payload schema is invalid.");
            }
            IDictionary<string, object> binding = ReadObject(payload, "binding");
            if (!FixedEquals(ReadString(binding, "plan_id"), planId) ||
                ReadString(binding, "legacy_match_policy") !=
                    "exact-host-scheduled-tags-and-sources")
            {
                throw new InvalidDataException("The snapshot list belongs to another backup plan.");
            }
            List<RestoreSnapshot> result = new List<RestoreSnapshot>();
            foreach (object item in ReadItems(payload, "snapshots"))
            {
                IDictionary<string, object> snapshot = item as IDictionary<string, object>;
                if (snapshot == null)
                {
                    throw new InvalidDataException("The snapshot list contains a non-object item.");
                }
                string id = ReadString(snapshot, "id");
                string bindingState = ReadString(snapshot, "binding_state");
                long generation;
                if (!IsExactSnapshotId(id))
                {
                    throw new InvalidDataException("The snapshot list contains an invalid immutable ID.");
                }
                if (bindingState == "plan")
                {
                    generation = ReadLong(snapshot, "config_generation");
                    if (!FixedEquals(ReadString(snapshot, "plan_id"), planId) || generation <= 0)
                    {
                        throw new InvalidDataException(
                            "The snapshot list contains invalid plan-binding metadata.");
                    }
                }
                else if (bindingState == "legacy_unbound")
                {
                    generation = 0;
                    if (ReadOptionalString(snapshot, "plan_id") != null ||
                        ReadOptionalLong(snapshot, "config_generation") != null)
                    {
                        throw new InvalidDataException(
                            "A legacy snapshot unexpectedly contains plan-binding metadata.");
                    }
                }
                else
                {
                    throw new InvalidDataException("The snapshot list contains an unknown binding.");
                }
                IDictionary<string, object> summary = ReadOptionalObject(snapshot, "summary");
                long files = summary == null ? 0 : ReadOptionalLong(summary, "total_files_processed") ?? 0;
                long bytes = summary == null ? 0 : ReadOptionalLong(summary, "total_bytes_processed") ?? 0;
                result.Add(new RestoreSnapshot(
                    id,
                    ReadOptionalString(snapshot, "short_id") ?? id.Substring(0, 8),
                    ReadOptionalString(snapshot, "time") ?? string.Empty,
                    ReadOptionalString(snapshot, "hostname") ?? string.Empty,
                    generation,
                    files,
                    bytes,
                    JoinStrings(ReadItems(snapshot, "paths")),
                    bindingState));
            }
            return result;
        }

        private static IList<RestoreTreeEntry> ParseTree(
            IDictionary<string, object> payload,
            string snapshotId,
            string planId,
            bool allowLegacyUnbound)
        {
            if (payload == null || ReadString(payload, "schema") !=
                    EngineProfile.Current.SnapshotTreeSchema ||
                !FixedEquals(ReadString(payload, "snapshot_id"), snapshotId))
            {
                throw new InvalidDataException("The snapshot-tree payload binding is invalid.");
            }
            IDictionary<string, object> snapshot = ReadObject(payload, "snapshot");
            string expectedBinding = allowLegacyUnbound ? "legacy_unbound" : "plan";
            if (ReadString(payload, "snapshot_binding") != expectedBinding ||
                ReadString(snapshot, "binding_state") != expectedBinding ||
                (!allowLegacyUnbound && !FixedEquals(ReadString(snapshot, "plan_id"), planId)) ||
                (allowLegacyUnbound &&
                    (ReadOptionalString(snapshot, "plan_id") != null ||
                     ReadOptionalLong(snapshot, "config_generation") != null)))
            {
                throw new InvalidDataException("The snapshot tree belongs to another backup plan.");
            }
            List<RestoreTreeEntry> entries = new List<RestoreTreeEntry>();
            foreach (object item in ReadItems(payload, "entries"))
            {
                IDictionary<string, object> entry = item as IDictionary<string, object>;
                if (entry == null)
                {
                    throw new InvalidDataException("The snapshot tree contains a non-object entry.");
                }
                string type = ReadOptionalString(entry, "type") ?? string.Empty;
                if (type != "file" && type != "dir" && type != "symlink" && type != "socket" &&
                    type != "dev" && type != "fifo")
                {
                    throw new InvalidDataException("The snapshot tree contains an invalid entry type.");
                }
                entries.Add(new RestoreTreeEntry(
                    ReadOptionalString(entry, "name") ?? string.Empty,
                    ReadOptionalString(entry, "path") ?? string.Empty,
                    type,
                    ReadOptionalLong(entry, "size") ?? 0));
            }
            return entries;
        }

        private static ProtectedRestoreReport ParseReport(
            IDictionary<string, object> payload,
            string snapshotId,
            string planId,
            string target,
            bool allowLegacyUnbound)
        {
            string expectedBinding = allowLegacyUnbound ? "legacy_unbound" : "plan";
            if (ReadString(payload, "schema") != EngineProfile.Current.RestoreReportSchema ||
                !FixedEquals(ReadString(payload, "snapshot_id"), snapshotId) ||
                ReadString(payload, "snapshot_binding") != expectedBinding ||
                (!allowLegacyUnbound && !FixedEquals(ReadString(payload, "plan_id"), planId)) ||
                (allowLegacyUnbound &&
                    (ReadOptionalString(payload, "plan_id") != null ||
                     ReadOptionalLong(payload, "snapshot_generation") != null)) ||
                !PathOrEmptyEquals(ReadString(payload, "target"), target))
            {
                throw new InvalidDataException("The protected restore report binding is invalid.");
            }
            string result = ReadString(payload, "result");
            if (result != "verified" && result != "partial" && result != "error")
            {
                throw new InvalidDataException("The protected restore report result is invalid.");
            }
            return new ProtectedRestoreReport(
                result,
                snapshotId,
                target,
                ReadBoolean(payload, "verified"),
                ReadBoolean(payload, "partial_target_retained"),
                checked((int)(ReadOptionalLong(payload, "restic_exit_code") ?? -1)),
                ReadOptionalString(payload, "error"),
                expectedBinding);
        }

        private static void ValidateRecoveryDrillReport(
            IDictionary<string, object> payload,
            ProtectedRestoreReport report,
            long generation)
        {
            long? sampleCount = ReadOptionalLong(payload, "sample_file_count");
            long? sampleBytes = ReadOptionalLong(payload, "sample_bytes");
            long? canaryBytes = ReadOptionalLong(payload, "canary_bytes");
            string canaryHash = ReadOptionalString(payload, "canary_sha256");
            string sampleHash = ReadOptionalString(payload, "sample_paths_sha256");
            if (ReadString(payload, "drill_kind") != "recovery_key_representative" ||
                ReadString(payload, "credential_source") != "recovery_key" ||
                ReadLong(payload, "snapshot_generation") != generation ||
                !ReadBoolean(payload, "canary_verified") ||
                canaryBytes == null || canaryBytes.Value < 0 ||
                !IsLowerHex(canaryHash, 64) ||
                ReadString(payload, "sample_policy") !=
                    "one-or-two-bounded-files-per-source-v1" ||
                sampleCount == null || sampleCount.Value < 2 || sampleCount.Value > 8 ||
                sampleBytes == null || sampleBytes.Value <= 0 ||
                sampleBytes.Value > 32L * 1024L * 1024L ||
                !IsLowerHex(sampleHash, 64) ||
                report.PartialTargetRetained)
            {
                throw new InvalidDataException(
                    "The protected recovery-drill report is incomplete or invalid.");
            }
        }

        private static void PublishProgress(
            string progressPath,
            string nonce,
            string digest,
            string userSid,
            string action,
            string planId,
            long generation,
            bool allowLegacyUnbound,
            string snapshotId,
            string target,
            Action<RestoreManagerProgress> callback,
            ref string lastFingerprint)
        {
            if (callback == null || !File.Exists(progressPath))
            {
                return;
            }
            try
            {
                FileInfo item = new FileInfo(progressPath);
                string fingerprint = item.Length.ToString(CultureInfo.InvariantCulture) + ":" +
                    item.LastWriteTimeUtc.Ticks.ToString(CultureInfo.InvariantCulture);
                if (fingerprint == lastFingerprint || item.Length <= 0 ||
                    item.Length > 256 * 1024 ||
                    (item.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    !HasProtectedAcl(progressPath, userSid))
                {
                    return;
                }
                IDictionary<string, object> document =
                    new JavaScriptSerializer().DeserializeObject(
                        File.ReadAllText(progressPath, Encoding.UTF8)) as IDictionary<string, object>;
                if (document == null || ReadLong(document, "schema_version") != 1 ||
                    !FixedEquals(ReadString(document, "request_nonce"), nonce) ||
                    !FixedEquals(ReadString(document, "request_digest"), digest) ||
                    !FixedEquals(ReadString(document, "request_user_sid"), userSid) ||
                    !FixedEquals(ReadString(document, "action"), action) ||
                    !FixedEquals(ReadString(document, "plan_id"), planId) ||
                    ReadLong(document, "config_generation") != generation ||
                    ReadBoolean(document, "allow_legacy_unbound") != allowLegacyUnbound ||
                    !ProgressSnapshotMatches(action, ReadOptionalString(document, "snapshot_id"), snapshotId) ||
                    !PathOrEmptyEquals(ReadOptionalString(document, "target"), target) ||
                    ReadBoolean(document, "cancellable"))
                {
                    return;
                }
                lastFingerprint = fingerprint;
                callback(new RestoreManagerProgress(
                    ReadString(document, "stage"),
                    ReadString(document, "message"),
                    checked((int)ReadLong(document, "percent"))));
            }
            catch
            {
                // Progress is advisory. The protected final result is authoritative.
            }
        }

        private static void ValidateRequestFields(
            string action,
            string snapshotId,
            string treePath,
            string target,
            IList<string> includes,
            bool allowLegacyUnbound)
        {
            if (action != "list_snapshots" && action != "list_tree" &&
                action != "restore" && action != "restore_drill")
            {
                throw new ArgumentException("The protected restore action is invalid.");
            }
            if ((action == "list_tree" || action == "restore") && !IsExactSnapshotId(snapshotId))
            {
                throw new ArgumentException("Choose one exact snapshot before continuing.");
            }
            if ((action == "list_snapshots" || action == "restore_drill") && snapshotId.Length != 0)
            {
                throw new ArgumentException("Snapshot listing must not include a snapshot selector.");
            }
            if ((action == "list_snapshots" || action == "restore_drill") && allowLegacyUnbound)
            {
                throw new ArgumentException(
                    "Legacy snapshot access is not valid for a snapshot-list request.");
            }
            if (action == "list_tree" && treePath.Length > 0 &&
                (!treePath.StartsWith("/", StringComparison.Ordinal) || treePath.IndexOf('\\') >= 0 ||
                 treePath.Length > 1024))
            {
                throw new ArgumentException("The snapshot folder path is invalid.");
            }
            if (action == "restore" && string.IsNullOrWhiteSpace(target))
            {
                throw new ArgumentException("Choose a new or empty restore destination.");
            }
            if (action == "restore_drill" &&
                (treePath.Length != 0 || target.Length != 0 || includes.Count != 0))
            {
                throw new ArgumentException(
                    "The protected manager derives every recovery-drill selector and target.");
            }
            if (includes == null || includes.Count > 64)
            {
                throw new ArgumentException("The restore selection exceeds 64 paths.");
            }
            foreach (string include in includes)
            {
                if (string.IsNullOrWhiteSpace(include) || include.Length > 1024 ||
                    include.IndexOf('\0') >= 0)
                {
                    throw new ArgumentException("A restore include path is invalid.");
                }
            }
            if (action != "restore" && includes.Count != 0)
            {
                throw new ArgumentException("File selections are only valid for restore requests.");
            }
        }

        private static string NormalizeSnapshotId(string value)
        {
            string result = (value ?? string.Empty).Trim().ToLowerInvariant();
            if (!IsExactSnapshotId(result))
            {
                throw new ArgumentException("Choose one exact snapshot before continuing.");
            }
            return result;
        }

        private static string NormalizeTreePath(string value)
        {
            string result = (value ?? string.Empty).Trim();
            return result == "/" ? "/" : result.TrimEnd('/');
        }

        private static bool IsExactSnapshotId(string value)
        {
            if (value == null || value.Length != 64)
            {
                return false;
            }
            foreach (char item in value)
            {
                if (!((item >= '0' && item <= '9') || (item >= 'a' && item <= 'f')))
                {
                    return false;
                }
            }
            return true;
        }

        internal static bool IsLowerHex(string value, int length)
        {
            if (value == null || value.Length != length) return false;
            foreach (char item in value)
            {
                if (!((item >= '0' && item <= '9') || (item >= 'a' && item <= 'f')))
                {
                    return false;
                }
            }
            return true;
        }

        internal static string ComputeFileSha256(string path)
        {
            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                8192,
                FileOptions.SequentialScan))
            using (SHA256 algorithm = SHA256.Create())
            {
                if (stream.Length <= 0 || stream.Length > 1024 * 1024)
                {
                    throw new InvalidDataException("The protected configuration has an invalid size.");
                }
                return ToLowerHex(algorithm.ComputeHash(stream));
            }
        }

        internal static string ComputeSha256(byte[] bytes)
        {
            using (SHA256 algorithm = SHA256.Create())
            {
                return ToLowerHex(algorithm.ComputeHash(bytes));
            }
        }

        internal static string CreateNonce()
        {
            byte[] bytes = new byte[32];
            using (RandomNumberGenerator generator = RandomNumberGenerator.Create())
            {
                generator.GetBytes(bytes);
            }
            return ToLowerHex(bytes);
        }

        private static string ToLowerHex(byte[] bytes)
        {
            StringBuilder builder = new StringBuilder(bytes.Length * 2);
            foreach (byte item in bytes)
            {
                builder.Append(item.ToString("x2", CultureInfo.InvariantCulture));
            }
            return builder.ToString();
        }

        internal static string BuildArgumentString(IEnumerable<string> arguments)
        {
            List<string> values = new List<string>();
            foreach (string argument in arguments)
            {
                values.Add(QuoteWindowsArgument(argument));
            }
            return string.Join(" ", values.ToArray());
        }

        private static string QuoteWindowsArgument(string value)
        {
            if (value == null)
            {
                return "\"\"";
            }
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                return value;
            }
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    slashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', slashes * 2 + 1);
                    result.Append('"');
                    slashes = 0;
                    continue;
                }
                if (slashes > 0)
                {
                    result.Append('\\', slashes);
                    slashes = 0;
                }
                result.Append(character);
            }
            if (slashes > 0)
            {
                result.Append('\\', slashes * 2);
            }
            result.Append('"');
            return result.ToString();
        }

        internal static bool IsRegularFile(string path)
        {
            try
            {
                return File.Exists(path) &&
                    (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0;
            }
            catch
            {
                return false;
            }
        }

        private static bool HasProtectedAcl(string path, string userSid)
        {
            try
            {
                FileSystemSecurity security = Directory.Exists(path)
                    ? (FileSystemSecurity)new DirectoryInfo(path).GetAccessControl(
                        AccessControlSections.Owner | AccessControlSections.Access)
                    : (FileSystemSecurity)new FileInfo(path).GetAccessControl(
                        AccessControlSections.Owner | AccessControlSections.Access);
                return HasProtectedAcl(security, userSid);
            }
            catch
            {
                return false;
            }
        }

        private static bool HasProtectedAcl(FileSystemSecurity security, string userSid)
        {
            try
            {
                SecurityIdentifier owner = security.GetOwner(
                    typeof(SecurityIdentifier)) as SecurityIdentifier;
                if (owner == null || owner.Value != "S-1-5-32-544" ||
                    !security.AreAccessRulesProtected)
                {
                    return false;
                }
                HashSet<string> required = new HashSet<string>(
                    new[] { "S-1-5-18", "S-1-5-32-544", userSid },
                    StringComparer.OrdinalIgnoreCase);
                HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                HashSet<string> allowed = new HashSet<string>(required, StringComparer.OrdinalIgnoreCase);
                allowed.Add("S-1-3-4");
                FileSystemRights dangerous = FileSystemRights.WriteData |
                    FileSystemRights.AppendData | FileSystemRights.WriteAttributes |
                    FileSystemRights.WriteExtendedAttributes | FileSystemRights.Delete |
                    FileSystemRights.DeleteSubdirectoriesAndFiles |
                    FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
                foreach (FileSystemAccessRule rule in security.GetAccessRules(
                    true,
                    true,
                    typeof(SecurityIdentifier)))
                {
                    SecurityIdentifier sid = rule.IdentityReference as SecurityIdentifier;
                    string value = sid == null ? null : sid.Value;
                    if (value == null || rule.IsInherited ||
                        rule.AccessControlType != AccessControlType.Allow ||
                        !allowed.Contains(value))
                    {
                        return false;
                    }
                    if (value != "S-1-5-18" && value != "S-1-5-32-544" &&
                        (rule.FileSystemRights & dangerous) != 0)
                    {
                        return false;
                    }
                    seen.Add(value);
                }
                return required.IsSubsetOf(seen);
            }
            catch
            {
                return false;
            }
        }

        internal static void InvokeSafely(Action callback)
        {
            if (callback == null)
            {
                return;
            }
            try { callback(); }
            catch { }
        }

        internal static string Sanitize(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return "The protected restore operation failed.";
            }
            StringBuilder result = new StringBuilder();
            foreach (char item in value)
            {
                if (!char.IsControl(item) || item == '\t')
                {
                    result.Append(item);
                }
                if (result.Length >= 2000)
                {
                    break;
                }
            }
            string safe = result.ToString().Trim();
            return safe.Length == 0 ? "The protected restore operation failed." : safe;
        }

        internal static bool FixedEquals(string left, string right)
        {
            if (left == null || right == null || left.Length != right.Length)
            {
                return false;
            }
            int difference = 0;
            for (int index = 0; index < left.Length; index++)
            {
                difference |= left[index] ^ right[index];
            }
            return difference == 0;
        }

        private static bool PathOrEmptyEquals(string left, string right)
        {
            string expected = right ?? string.Empty;
            string actual = left ?? string.Empty;
            if (expected.Length == 0 || actual.Length == 0)
            {
                return expected.Length == actual.Length;
            }
            return string.Equals(
                SourceConfiguration.NormalizePath(actual),
                SourceConfiguration.NormalizePath(expected),
                StringComparison.OrdinalIgnoreCase);
        }

        // A drill is requested without a snapshot (the manager picks the representative one), and both engines report
        // the snapshot they picked once they know it, as the final result does (checked there as an exact snapshot ID).
        // Progress is advisory and still bound to the nonce, digest, user, plan and generation.
        private static bool ProgressSnapshotMatches(string action, string reported, string requested)
        {
            string value = NullToEmpty(reported);
            string expected = NullToEmpty(requested);
            if (action == "restore_drill" && expected.Length == 0)
            {
                return value.Length == 0 || IsExactSnapshotId(value);
            }
            return FixedEquals(value, expected);
        }

        private static string NullToEmpty(string value)
        {
            return value ?? string.Empty;
        }

        private static string ReadString(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || !(value is string))
            {
                throw new InvalidDataException("Result field is missing or invalid: " + name);
            }
            return (string)value;
        }

        private static string ReadOptionalString(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null)
            {
                return null;
            }
            if (!(value is string))
            {
                throw new InvalidDataException("Result field is invalid: " + name);
            }
            return (string)value;
        }

        private static long ReadLong(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) ||
                (!(value is int) && !(value is long)))
            {
                throw new InvalidDataException("Result field is missing or invalid: " + name);
            }
            return Convert.ToInt64(value, CultureInfo.InvariantCulture);
        }

        private static long? ReadOptionalLong(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null)
            {
                return null;
            }
            if (!(value is int) && !(value is long))
            {
                throw new InvalidDataException("Result field is invalid: " + name);
            }
            return Convert.ToInt64(value, CultureInfo.InvariantCulture);
        }

        private static bool ReadBoolean(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || !(value is bool))
            {
                throw new InvalidDataException("Result field is missing or invalid: " + name);
            }
            return (bool)value;
        }

        private static bool? ReadOptionalBoolean(
            IDictionary<string, object> document,
            string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null)
            {
                return null;
            }
            if (!(value is bool))
            {
                throw new InvalidDataException("Result field is invalid: " + name);
            }
            return (bool)value;
        }

        private static IDictionary<string, object> ReadObject(
            IDictionary<string, object> document,
            string name)
        {
            IDictionary<string, object> result = ReadOptionalObject(document, name);
            if (result == null)
            {
                throw new InvalidDataException("Result object is missing or invalid: " + name);
            }
            return result;
        }

        private static IDictionary<string, object> ReadOptionalObject(
            IDictionary<string, object> document,
            string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null)
            {
                return null;
            }
            IDictionary<string, object> result = value as IDictionary<string, object>;
            if (result == null)
            {
                throw new InvalidDataException("Result object is invalid: " + name);
            }
            return result;
        }

        private static IEnumerable ReadItems(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value is string || !(value is IEnumerable))
            {
                throw new InvalidDataException("Result array is missing or invalid: " + name);
            }
            return (IEnumerable)value;
        }

        private static string JoinStrings(IEnumerable values)
        {
            List<string> result = new List<string>();
            foreach (object item in values)
            {
                string text = item as string;
                if (!string.IsNullOrWhiteSpace(text))
                {
                    result.Add(text);
                }
            }
            return string.Join(", ", result.ToArray());
        }
    }

    // ---- Restore approval session ---------------------------------------------------------------------------------------
    // One Windows approval per guided restore. Manage-Restore.ps1 -Operation session (RestoreRequest.v3) is started once,
    // with runas, and then serves any number of snapshot and folder listings and at most one restore over a named pipe:
    // only this account may open it, it has one instance, and the broker serves it only to this process (Windows' client
    // process ID and token) once it has proved the session token, whose hash alone is on the elevated command line. This
    // side uses the pipe only after Windows names its server as the process it started. Each request's result is the
    // document a single request writes to its protected file and is checked by the same RestoreManagerLauncher.ValidateResult.
    // See docs/engine-contract.md ("Restore approval session") and SECURITY.md.

    // Whether the installed engine serves restore approval sessions. The profile must have a broker and the protected
    // install root must hold the engine's capability document naming the same protocol, request domain and manager. Read
    // only and bounded; a link, a document that is too large, malformed or names anything else, or any error, is "no",
    // and the dashboard then asks for one approval per protected step, as before.
    internal static class RestoreSessionCapability
    {
        private const int MaximumBytes = 16 * 1024;

        internal static bool IsSupported(EngineProfile profile, string installRoot)
        {
            if (profile == null || string.IsNullOrEmpty(profile.RestoreSessionRequestDomain) ||
                string.IsNullOrEmpty(profile.RestoreSessionProtocol) || string.IsNullOrWhiteSpace(installRoot))
            {
                return false;
            }
            try
            {
                DirectoryInfo root = new DirectoryInfo(installRoot);
                string path = Path.Combine(root.FullName, EngineProfile.EngineCapabilitiesFileName);
                FileInfo file = new FileInfo(path);
                if (!root.Exists || (root.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    !file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    file.Length <= 0 || file.Length > MaximumBytes)
                {
                    return false;
                }
                byte[] bytes;
                using (FileStream stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                {
                    if (stream.Length <= 0 || stream.Length > MaximumBytes)
                    {
                        return false;
                    }
                    bytes = new byte[(int)stream.Length];
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        int read = stream.Read(bytes, offset, bytes.Length - offset);
                        if (read <= 0)
                        {
                            return false;
                        }
                        offset += read;
                    }
                }
                IDictionary<string, object> document = new JavaScriptSerializer().DeserializeObject(
                    new UTF8Encoding(false, true).GetString(bytes)) as IDictionary<string, object>;
                object schemaVersion;
                object sessionValue;
                IDictionary<string, object> session = document != null &&
                    document.TryGetValue("restore_session", out sessionValue)
                        ? sessionValue as IDictionary<string, object>
                        : null;
                return document != null && session != null &&
                    string.Equals(document["schema"] as string, profile.EngineCapabilitiesSchema, StringComparison.Ordinal) &&
                    document.TryGetValue("schema_version", out schemaVersion) && schemaVersion is int && (int)schemaVersion == 1 &&
                    session.ContainsKey("protocol") && session.ContainsKey("request_domain") && session.ContainsKey("manager") &&
                    string.Equals(session["protocol"] as string, profile.RestoreSessionProtocol, StringComparison.Ordinal) &&
                    string.Equals(session["request_domain"] as string, profile.RestoreSessionRequestDomain, StringComparison.Ordinal) &&
                    string.Equals(session["manager"] as string, profile.RestoreManagerFileName, StringComparison.Ordinal);
            }
            catch
            {
                return false;
            }
        }
    }

    // What one session launch asks the broker for. The broker reads the same values from its elevated command line; the
    // launcher gets them too so the regression suite's stand-in broker can answer without parsing that line.
    internal sealed class RestoreSessionRequest
    {
        internal string Nonce;
        internal string Digest;
        internal string UserSid;
        internal string ConfigHash;
        internal string PlanId;
        internal long ConfigGeneration;
        internal int DashboardProcessId;
        internal string PipeName;
        internal string SessionTokenSha256;
        internal int IdleTimeoutSeconds;
        internal int LifetimeSeconds;
        internal int ConnectTimeoutSeconds;
        internal string ResultPath;
    }

    // Starts the broker. Production asks Windows (runas, which shows the approval prompt and throws a Win32Exception 1223
    // when it is declined); the regression suite passes a stand-in.
    internal delegate Process RestoreSessionLauncher(ProcessStartInfo start, RestoreSessionRequest request);

    internal sealed class RestoreSessionExchange
    {
        // The result document of the request, or null.
        internal IDictionary<string, object> Result;
        internal int ExitCode;
        // The session had already ended before it read the request, so the request was not served and may be sent to a
        // new session.
        internal bool EndedBeforeRequest;
        internal string Error;
    }

    internal static class RestoreSessionFraming
    {
        internal const int MaximumRequestBytes = 256 * 1024;
        // The protected result limit (Write-ProtectedJson, the result reader).
        internal const int MaximumResponseBytes = 8 * 1024 * 1024;

        internal static byte[] Encode(IDictionary<string, object> message, int maximumBytes)
        {
            byte[] body = new UTF8Encoding(false).GetBytes(new JavaScriptSerializer().Serialize(message));
            if (body.Length <= 0 || body.Length > maximumBytes)
            {
                throw new InvalidDataException("A restore-session message exceeds its size limit.");
            }
            byte[] frame = new byte[body.Length + 4];
            frame[0] = (byte)(body.Length & 0xFF);
            frame[1] = (byte)((body.Length >> 8) & 0xFF);
            frame[2] = (byte)((body.Length >> 16) & 0xFF);
            frame[3] = (byte)((body.Length >> 24) & 0xFF);
            Buffer.BlockCopy(body, 0, frame, 4, body.Length);
            return frame;
        }

        internal static void Write(Stream stream, byte[] frame, int timeoutMilliseconds)
        {
            Task task = stream.WriteAsync(frame, 0, frame.Length);
            if (!WaitFor(task, timeoutMilliseconds))
            {
                throw new TimeoutException("The restore session did not take the message in time.");
            }
        }

        // The next message, or null when the other side closed the channel between messages. A frame outside the limit, one
        // that ends early, invalid UTF-8 or anything but one JSON object ends the exchange.
        internal static IDictionary<string, object> Read(Stream stream, int maximumBytes, int timeoutMilliseconds)
        {
            byte[] header = new byte[4];
            int headerRead = ReadSome(stream, header, 0, 4, timeoutMilliseconds);
            if (headerRead == 0)
            {
                return null;
            }
            ReadExactly(stream, header, headerRead, 4 - headerRead, timeoutMilliseconds);
            long length = header[0] | ((long)header[1] << 8) | ((long)header[2] << 16) | ((long)header[3] << 24);
            if (length <= 0 || length > maximumBytes)
            {
                throw new InvalidDataException("A restore-session message is empty or exceeds its size limit.");
            }
            byte[] body = new byte[(int)length];
            ReadExactly(stream, body, 0, body.Length, timeoutMilliseconds);
            string text = new UTF8Encoding(false, true).GetString(body);
            if (text.Length == 0 || text[0] != '{')
            {
                throw new InvalidDataException("A restore-session message is not one JSON object.");
            }
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = MaximumResponseBytes;
            IDictionary<string, object> message = serializer.DeserializeObject(text) as IDictionary<string, object>;
            if (message == null)
            {
                throw new InvalidDataException("A restore-session message is not one JSON object.");
            }
            return message;
        }

        // Exactly these fields, with exactly these names.
        internal static void RequireFields(IDictionary<string, object> message, params string[] names)
        {
            bool valid = message != null && message.Count == names.Length;
            if (valid)
            {
                foreach (string name in names)
                {
                    if (!message.ContainsKey(name))
                    {
                        valid = false;
                        break;
                    }
                }
            }
            if (!valid)
            {
                throw new InvalidDataException("A restore-session message does not have exactly the expected fields.");
            }
        }

        internal static string TypeOf(IDictionary<string, object> message)
        {
            object value;
            if (message == null || !message.TryGetValue("type", out value) || !(value is string))
            {
                throw new InvalidDataException("A restore-session message has no valid type.");
            }
            return (string)value;
        }

        internal static long ReadInteger(IDictionary<string, object> message, string name)
        {
            object value;
            if (!message.TryGetValue(name, out value) || (!(value is int) && !(value is long)))
            {
                throw new InvalidDataException("A restore-session message has an invalid " + name + ".");
            }
            return Convert.ToInt64(value, CultureInfo.InvariantCulture);
        }

        internal static string ReadString(IDictionary<string, object> message, string name, int maximumLength)
        {
            object value;
            if (!message.TryGetValue(name, out value) || !(value is string) || ((string)value).Length > maximumLength)
            {
                throw new InvalidDataException("A restore-session message has an invalid " + name + ".");
            }
            return (string)value;
        }

        private static int ReadSome(Stream stream, byte[] buffer, int offset, int count, int timeoutMilliseconds)
        {
            Task<int> task = stream.ReadAsync(buffer, offset, count);
            if (!WaitFor(task, timeoutMilliseconds))
            {
                throw new TimeoutException("The restore session did not answer in time.");
            }
            return task.Result;
        }

        private static void ReadExactly(Stream stream, byte[] buffer, int offset, int count, int timeoutMilliseconds)
        {
            while (count > 0)
            {
                int read = ReadSome(stream, buffer, offset, count, timeoutMilliseconds);
                if (read <= 0)
                {
                    throw new EndOfStreamException("The restore session ended inside a message.");
                }
                offset += read;
                count -= read;
            }
        }

        private static bool WaitFor(Task task, int timeoutMilliseconds)
        {
            try
            {
                return task.Wait(timeoutMilliseconds);
            }
            catch (AggregateException error)
            {
                Exception inner = error.GetBaseException();
                throw new IOException(inner == null ? "The restore session channel failed." : inner.Message, inner);
            }
        }
    }

    internal static class RestoreSessionNativeMethods
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint serverProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint GetProcessId(IntPtr process);
    }

    // One running session: the broker process this dashboard started and the verified channel to it.
    internal sealed class RestoreSessionClient : IDisposable
    {
        internal const int IdleTimeoutSeconds = 600;
        internal const int LifetimeSeconds = 3600;
        internal const int ConnectTimeoutSeconds = 120;
        // Given up this long before the broker would end it, so that a request never races its idle or absolute limit.
        private const int ExpiryMarginSeconds = 30;
        private const int HandshakeTimeoutMilliseconds = 30000;
        private const int PipeWaitMilliseconds = 60000;

        private readonly object gate = new object();
        private Process broker;
        private NamedPipeClientStream pipe;
        private DateTime lastActivityUtc;
        private DateTime lifetimeEndUtc;
        private bool ended;
        private bool restoreUsed;
        private bool serving;
        // Set once the broker answered the hello as the session this dashboard asked for. Nothing (not even a close) is sent
        // on a channel that was not verified.
        private bool verified;
        private long nextRequestId = 1;

        private RestoreSessionClient()
        {
        }

        internal string Nonce { get; private set; }
        internal string Digest { get; private set; }
        internal string UserSid { get; private set; }
        internal string ConfigHash { get; private set; }
        internal string PlanId { get; private set; }
        internal long ConfigGeneration { get; private set; }
        internal int BrokerProcessId { get; private set; }

        internal static string ComputeSessionDigest(RestoreSessionRequest request)
        {
            string payload = string.Join("\n", new[]
            {
                EngineProfile.Current.RestoreSessionRequestDomain,
                request.UserSid,
                "session",
                request.ConfigHash.ToLowerInvariant(),
                request.PlanId,
                request.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                request.DashboardProcessId.ToString(CultureInfo.InvariantCulture),
                request.PipeName,
                request.SessionTokenSha256,
                request.IdleTimeoutSeconds.ToString(CultureInfo.InvariantCulture),
                request.LifetimeSeconds.ToString(CultureInfo.InvariantCulture),
                request.ConnectTimeoutSeconds.ToString(CultureInfo.InvariantCulture),
                request.Nonce
            });
            return RestoreManagerLauncher.ComputeSha256(new UTF8Encoding(false).GetBytes(payload));
        }

        // Starts a broker (one Windows approval) and opens its channel. Throws when Windows or the broker refuses, when the
        // channel cannot be verified, or when the approval prompt is declined (Win32Exception 1223).
        internal static RestoreSessionClient Open(
            SourceConfiguration configuration,
            string configHash,
            string userSid,
            RestoreSessionLauncher launcher,
            Action onApproved)
        {
            EngineProfile profile = EngineProfile.Current;
            if (launcher == null || configuration == null || string.IsNullOrEmpty(profile.RestoreSessionRequestDomain))
            {
                throw new InvalidOperationException("This backup engine does not serve restore sessions.");
            }
            string managerPath = Path.Combine(configuration.InstallRoot, profile.RestoreManagerFileName);
            string powerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            if (!RestoreManagerLauncher.IsRegularFile(managerPath) || !RestoreManagerLauncher.IsRegularFile(powerShell))
            {
                throw new InvalidOperationException("The protected restore manager is missing from the installation.");
            }
            string token = RestoreManagerLauncher.CreateNonce();
            RestoreSessionRequest request = new RestoreSessionRequest();
            request.Nonce = RestoreManagerLauncher.CreateNonce();
            request.UserSid = userSid;
            request.ConfigHash = configHash.ToLowerInvariant();
            request.PlanId = configuration.PlanId;
            request.ConfigGeneration = configuration.ConfigGeneration;
            using (Process current = Process.GetCurrentProcess())
            {
                request.DashboardProcessId = current.Id;
            }
            request.PipeName = profile.RestoreSessionPipePrefix + RestoreManagerLauncher.CreateNonce();
            request.SessionTokenSha256 = RestoreManagerLauncher.ComputeSha256(new UTF8Encoding(false).GetBytes(token));
            request.IdleTimeoutSeconds = IdleTimeoutSeconds;
            request.LifetimeSeconds = LifetimeSeconds;
            request.ConnectTimeoutSeconds = ConnectTimeoutSeconds;
            request.ResultPath = Path.Combine(
                profile.StateResultDirectory("RestoreManagerResults"),
                request.Nonce + ".json");
            request.Digest = ComputeSessionDigest(request);
            if (File.Exists(request.ResultPath) || Directory.Exists(request.ResultPath))
            {
                throw new InvalidOperationException("A protected restore result already uses this request nonce.");
            }

            List<string> arguments = new List<string>(new[]
            {
                "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-WindowStyle", "Hidden", "-File", managerPath,
                "-Operation", "session",
                "-ExpectedUserSid", request.UserSid,
                "-ExpectedConfigSha256", request.ConfigHash,
                "-ExpectedPlanId", request.PlanId,
                "-ExpectedConfigGeneration", request.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                "-ResultPath", request.ResultPath,
                "-RequestNonce", request.Nonce,
                "-RequestDigest", request.Digest,
                "-DashboardProcessId", request.DashboardProcessId.ToString(CultureInfo.InvariantCulture),
                "-PipeName", request.PipeName,
                "-SessionTokenSha256", request.SessionTokenSha256,
                "-IdleTimeoutSeconds", request.IdleTimeoutSeconds.ToString(CultureInfo.InvariantCulture),
                "-LifetimeSeconds", request.LifetimeSeconds.ToString(CultureInfo.InvariantCulture),
                "-ConnectTimeoutSeconds", request.ConnectTimeoutSeconds.ToString(CultureInfo.InvariantCulture)
            });
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = powerShell;
            start.Arguments = RestoreManagerLauncher.BuildArgumentString(arguments);
            start.WorkingDirectory = configuration.InstallRoot;
            start.UseShellExecute = true;
            start.Verb = "runas";
            start.WindowStyle = ProcessWindowStyle.Hidden;
            start.ErrorDialog = false;

            DateTime launchedUtc = DateTime.UtcNow;
            Process process = launcher(start, request);
            if (process == null)
            {
                throw new InvalidOperationException("Windows did not start the protected restore session.");
            }
            RestoreSessionClient client = new RestoreSessionClient();
            client.broker = process;
            client.Nonce = request.Nonce;
            client.Digest = request.Digest;
            client.UserSid = request.UserSid;
            client.ConfigHash = request.ConfigHash;
            client.PlanId = request.PlanId;
            client.ConfigGeneration = request.ConfigGeneration;
            client.lifetimeEndUtc = launchedUtc.AddSeconds(LifetimeSeconds);
            try
            {
                client.BrokerProcessId = LaunchedProcessId(process);
                RestoreManagerLauncher.InvokeSafely(onApproved);
                client.Connect(request, token);
            }
            catch
            {
                client.Dispose();
                throw;
            }
            return client;
        }

        // The ID of the process Windows started. A handle from an elevated launch may not answer every query, so the handle
        // itself is asked when the managed property cannot be read.
        private static int LaunchedProcessId(Process process)
        {
            try
            {
                return process.Id;
            }
            catch (Exception)
            {
                uint id = RestoreSessionNativeMethods.GetProcessId(process.Handle);
                if (id == 0)
                {
                    throw new InvalidOperationException("Windows did not identify the protected restore session.");
                }
                return checked((int)id);
            }
        }

        private void Connect(RestoreSessionRequest request, string token)
        {
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(PipeWaitMilliseconds);
            while (pipe == null)
            {
                if (BrokerExited())
                {
                    throw new InvalidOperationException(
                        "The protected restore session stopped before it opened its channel.");
                }
                if (DateTime.UtcNow >= deadline)
                {
                    throw new TimeoutException("The protected restore session did not open its channel in time.");
                }
                NamedPipeClientStream candidate = new NamedPipeClientStream(
                    ".",
                    request.PipeName,
                    PipeDirection.InOut,
                    PipeOptions.Asynchronous,
                    System.Security.Principal.TokenImpersonationLevel.Identification);
                try
                {
                    candidate.Connect(250);
                    pipe = candidate;
                }
                catch (TimeoutException)
                {
                    candidate.Dispose();
                }
                catch (IOException)
                {
                    candidate.Dispose();
                }
                catch (UnauthorizedAccessException)
                {
                    // Someone else's pipe of that name: the broker cannot create its own and ends, which ends this wait.
                    candidate.Dispose();
                }
            }
            // Nothing is sent before Windows names the pipe's server as the broker this dashboard started: anyone could
            // have created a pipe with that name first.
            uint serverProcessId;
            if (!RestoreSessionNativeMethods.GetNamedPipeServerProcessId(pipe.SafePipeHandle, out serverProcessId) ||
                serverProcessId == 0 || serverProcessId != (uint)BrokerProcessId)
            {
                throw new InvalidOperationException(
                    "The protected restore session could not be verified, so nothing was sent to it.");
            }
            Dictionary<string, object> hello = new Dictionary<string, object>
            {
                { "type", "hello" },
                { "protocol", EngineProfile.Current.RestoreSessionProtocol },
                { "session_token", token },
                { "dashboard_process_id", request.DashboardProcessId }
            };
            RestoreSessionFraming.Write(
                pipe,
                RestoreSessionFraming.Encode(hello, RestoreSessionFraming.MaximumRequestBytes),
                HandshakeTimeoutMilliseconds);
            IDictionary<string, object> ready = RestoreSessionFraming.Read(
                pipe,
                RestoreSessionFraming.MaximumResponseBytes,
                HandshakeTimeoutMilliseconds);
            if (ready == null)
            {
                throw new InvalidOperationException("The protected restore session refused this dashboard.");
            }
            RestoreSessionFraming.RequireFields(
                ready,
                "type", "protocol", "request_nonce", "request_digest", "broker_process_id",
                "idle_timeout_seconds", "lifetime_seconds");
            if (RestoreSessionFraming.TypeOf(ready) != "ready" ||
                RestoreSessionFraming.ReadString(ready, "protocol", 128) != EngineProfile.Current.RestoreSessionProtocol ||
                !RestoreManagerLauncher.FixedEquals(RestoreSessionFraming.ReadString(ready, "request_nonce", 64), Nonce) ||
                !RestoreManagerLauncher.FixedEquals(RestoreSessionFraming.ReadString(ready, "request_digest", 64), Digest) ||
                RestoreSessionFraming.ReadInteger(ready, "broker_process_id") != BrokerProcessId ||
                RestoreSessionFraming.ReadInteger(ready, "idle_timeout_seconds") != request.IdleTimeoutSeconds ||
                RestoreSessionFraming.ReadInteger(ready, "lifetime_seconds") != request.LifetimeSeconds)
            {
                throw new InvalidDataException("The protected restore session is not the one this dashboard asked for.");
            }
            lock (gate)
            {
                lastActivityUtc = DateTime.UtcNow;
                verified = true;
            }
        }

        // A session that can take another request for this plan: not ended, its one restore not used, its broker running,
        // and well inside its idle and absolute limits.
        internal bool IsUsableFor(string configHash, string planId, long configGeneration, string userSid)
        {
            lock (gate)
            {
                DateTime now = DateTime.UtcNow;
                return verified && !ended && !restoreUsed && pipe != null && pipe.IsConnected && !BrokerExited() &&
                    now < lastActivityUtc.AddSeconds(IdleTimeoutSeconds - ExpiryMarginSeconds) &&
                    now < lifetimeEndUtc.AddSeconds(-ExpiryMarginSeconds) &&
                    string.Equals(ConfigHash, (configHash ?? string.Empty).ToLowerInvariant(), StringComparison.Ordinal) &&
                    string.Equals(PlanId, planId, StringComparison.Ordinal) &&
                    ConfigGeneration == configGeneration &&
                    string.Equals(UserSid, userSid, StringComparison.OrdinalIgnoreCase);
            }
        }

        internal bool IsLive
        {
            get
            {
                lock (gate)
                {
                    DateTime now = DateTime.UtcNow;
                    return verified && !ended && !restoreUsed && pipe != null && !BrokerExited() &&
                        now < lastActivityUtc.AddSeconds(IdleTimeoutSeconds - ExpiryMarginSeconds) &&
                        now < lifetimeEndUtc.AddSeconds(-ExpiryMarginSeconds);
                }
            }
        }

        internal RestoreSessionExchange Execute(
            string action,
            string snapshotId,
            string treePath,
            string target,
            string includesBase64,
            bool allowLegacyUnbound,
            Action<RestoreManagerProgress> onProgress)
        {
            NamedPipeClientStream channel;
            long requestId;
            lock (gate)
            {
                if (serving)
                {
                    return new RestoreSessionExchange { Error = "The protected restore session is still serving a request." };
                }
                if (ended || restoreUsed || pipe == null || !verified)
                {
                    return new RestoreSessionExchange { EndedBeforeRequest = true };
                }
                if (action != "list_snapshots" && action != "list_tree" && action != "restore")
                {
                    return new RestoreSessionExchange { Error = "A restore session serves only listings and one restore." };
                }
                serving = true;
                channel = pipe;
                requestId = nextRequestId++;
                if (action == "restore")
                {
                    // At most one restore per session, whatever happens next.
                    restoreUsed = true;
                }
            }
            try
            {
                Dictionary<string, object> request = new Dictionary<string, object>
                {
                    { "type", "request" },
                    { "request_id", requestId },
                    { "action", action },
                    { "snapshot_id", snapshotId ?? string.Empty },
                    { "tree_path", treePath ?? string.Empty },
                    { "target", target ?? string.Empty },
                    { "includes_base64", includesBase64 ?? string.Empty },
                    { "allow_legacy_unbound", allowLegacyUnbound ? "1" : "0" }
                };
                try
                {
                    RestoreSessionFraming.Write(
                        channel,
                        RestoreSessionFraming.Encode(request, RestoreSessionFraming.MaximumRequestBytes),
                        HandshakeTimeoutMilliseconds);
                }
                catch (IOException)
                {
                    // The broker had already gone: it never read this request.
                    End();
                    return new RestoreSessionExchange { EndedBeforeRequest = true };
                }
                catch (ObjectDisposedException)
                {
                    End();
                    return new RestoreSessionExchange { EndedBeforeRequest = true };
                }
                while (true)
                {
                    // A restore can run for hours; the broker going away closes the channel and ends the wait.
                    IDictionary<string, object> message = RestoreSessionFraming.Read(
                        channel,
                        RestoreSessionFraming.MaximumResponseBytes,
                        Timeout.Infinite);
                    if (message == null)
                    {
                        End();
                        return new RestoreSessionExchange
                        {
                            Error = "The protected restore session ended before it answered."
                        };
                    }
                    string type = RestoreSessionFraming.TypeOf(message);
                    if (type == "closed")
                    {
                        // The broker ended (idle, lifetime, a changed plan) before it read this request.
                        RestoreSessionFraming.RequireFields(message, "type", "reason");
                        RestoreSessionFraming.ReadString(message, "reason", 64);
                        End();
                        return new RestoreSessionExchange { EndedBeforeRequest = true };
                    }
                    if (type == "progress")
                    {
                        RestoreSessionFraming.RequireFields(message, "type", "request_id", "stage", "message", "percent");
                        if (RestoreSessionFraming.ReadInteger(message, "request_id") != requestId)
                        {
                            throw new InvalidDataException("The protected restore session reported progress for another request.");
                        }
                        RestoreManagerProgress progress = new RestoreManagerProgress(
                            RestoreSessionFraming.ReadString(message, "stage", 64),
                            RestoreSessionFraming.ReadString(message, "message", 2000),
                            checked((int)RestoreSessionFraming.ReadInteger(message, "percent")));
                        if (onProgress != null)
                        {
                            try { onProgress(progress); }
                            catch { }
                        }
                        continue;
                    }
                    if (type != "result")
                    {
                        throw new InvalidDataException("The protected restore session sent an unexpected message.");
                    }
                    RestoreSessionFraming.RequireFields(message, "type", "request_id", "exit_code", "result");
                    if (RestoreSessionFraming.ReadInteger(message, "request_id") != requestId)
                    {
                        throw new InvalidDataException("The protected restore session answered another request.");
                    }
                    object exitValue;
                    message.TryGetValue("exit_code", out exitValue);
                    if (!(exitValue is int) && !(exitValue is long))
                    {
                        throw new InvalidDataException("The protected restore session sent an invalid exit code.");
                    }
                    IDictionary<string, object> result = message["result"] as IDictionary<string, object>;
                    if (result == null)
                    {
                        throw new InvalidDataException("The protected restore session sent no result.");
                    }
                    lock (gate)
                    {
                        lastActivityUtc = DateTime.UtcNow;
                    }
                    if (action == "restore")
                    {
                        End();
                    }
                    return new RestoreSessionExchange
                    {
                        Result = result,
                        ExitCode = checked((int)Convert.ToInt64(exitValue, CultureInfo.InvariantCulture))
                    };
                }
            }
            catch (Exception error)
            {
                // Anything the channel or the broker got wrong ends this session; it is never asked again.
                End();
                return new RestoreSessionExchange
                {
                    Error = "The protected restore session failed: " + RestoreManagerLauncher.Sanitize(error.Message)
                };
            }
            finally
            {
                lock (gate)
                {
                    serving = false;
                }
            }
        }

        // Asks the broker to end (when it is not serving a request) and drops the channel. The broker cannot be stopped
        // from here (it is elevated); it ends on the close message, or on the closed channel, or when this process exits.
        internal void Close()
        {
            NamedPipeClientStream channel;
            bool idle;
            lock (gate)
            {
                channel = pipe;
                idle = verified && !serving && !ended;
                ended = true;
                pipe = null;
            }
            if (channel != null && idle)
            {
                try
                {
                    Dictionary<string, object> close = new Dictionary<string, object> { { "type", "close" } };
                    RestoreSessionFraming.Write(
                        channel,
                        RestoreSessionFraming.Encode(close, RestoreSessionFraming.MaximumRequestBytes),
                        1000);
                }
                catch
                {
                    // The channel is dropped below either way.
                }
            }
            if (channel != null)
            {
                try { channel.Dispose(); }
                catch { }
            }
            Process process;
            lock (gate)
            {
                process = broker;
                broker = null;
            }
            if (process != null)
            {
                try { process.Dispose(); }
                catch { }
            }
        }

        public void Dispose()
        {
            Close();
        }

        private void End()
        {
            NamedPipeClientStream channel;
            lock (gate)
            {
                ended = true;
                channel = pipe;
                pipe = null;
            }
            if (channel != null)
            {
                try { channel.Dispose(); }
                catch { }
            }
        }

        private bool BrokerExited()
        {
            try
            {
                return broker == null || broker.HasExited;
            }
            catch
            {
                // A handle that will not say is left to the channel, which closes with the broker.
                return false;
            }
        }
    }

    // The one restore approval session of one guided restore. It holds at most one running session and starts another
    // (with a new approval) only when the one it has can no longer serve: it ended, used its restore, reached its limits
    // or belongs to another plan. Closed with the flow, and on exit; a closed host starts nothing.
    internal sealed class RestoreSessionHost : IDisposable
    {
        private readonly object gate = new object();
        private readonly RestoreSessionLauncher launcher;
        private RestoreSessionClient client;
        private bool closed;
        private int launches;
        private int opened;

        internal RestoreSessionHost(RestoreSessionLauncher launcher)
        {
            if (launcher == null)
            {
                throw new ArgumentNullException("launcher");
            }
            this.launcher = launcher;
        }

        // Production: Windows shows its approval prompt for the broker (runas).
        internal static Process LaunchElevated(ProcessStartInfo start, RestoreSessionRequest request)
        {
            return Process.Start(start);
        }

        // How many brokers this flow asked Windows for, which is how many approval prompts it showed.
        internal int Launches
        {
            get
            {
                lock (gate)
                {
                    return launches;
                }
            }
        }

        // How many of those sessions were approved and opened.
        internal int Opened
        {
            get
            {
                lock (gate)
                {
                    return opened;
                }
            }
        }

        internal bool IsClosed
        {
            get
            {
                lock (gate)
                {
                    return closed;
                }
            }
        }

        // Whether a request now would be served without a new approval (for the page's wording only).
        internal bool HasLiveSession
        {
            get
            {
                RestoreSessionClient current;
                lock (gate)
                {
                    current = closed ? null : client;
                }
                return current != null && current.IsLive;
            }
        }

        internal RestoreSessionClient Acquire(
            SourceConfiguration configuration,
            string configHash,
            string userSid,
            Action onApprovalRequested,
            Action onApproved)
        {
            RestoreSessionClient current;
            RestoreSessionClient stale = null;
            lock (gate)
            {
                if (closed)
                {
                    throw new InvalidOperationException("Restore was closed, so no protected session is started for it.");
                }
                current = client;
                if (current != null && !current.IsUsableFor(
                    configHash,
                    configuration == null ? null : configuration.PlanId,
                    configuration == null ? 0 : configuration.ConfigGeneration,
                    userSid))
                {
                    stale = current;
                    current = null;
                    client = null;
                }
                if (current == null)
                {
                    launches++;
                }
            }
            if (stale != null)
            {
                stale.Close();
            }
            if (current != null)
            {
                RestoreManagerLauncher.InvokeSafely(onApproved);
                return current;
            }
            RestoreManagerLauncher.InvokeSafely(onApprovalRequested);
            RestoreSessionClient session = RestoreSessionClient.Open(configuration, configHash, userSid, launcher, onApproved);
            bool keep;
            lock (gate)
            {
                keep = !closed;
                if (keep)
                {
                    client = session;
                    opened++;
                }
            }
            if (!keep)
            {
                session.Close();
                throw new InvalidOperationException("Restore was closed, so no protected session is started for it.");
            }
            return session;
        }

        internal void Close()
        {
            RestoreSessionClient current;
            lock (gate)
            {
                closed = true;
                current = client;
                client = null;
            }
            if (current != null)
            {
                current.Close();
            }
        }

        public void Dispose()
        {
            Close();
        }
    }
}
