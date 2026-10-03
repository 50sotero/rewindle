using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal sealed class RepositoryProgress
    {
        public string Stage { get; private set; }
        public string Message { get; private set; }
        public double? Percent { get; private set; }
        public long? BytesCopied { get; private set; }
        public long? BytesTotal { get; private set; }
        public long? FilesCopied { get; private set; }
        public long? FilesTotal { get; private set; }
        public double? ThroughputBytesPerSecond { get; private set; }
        public double? EstimatedSecondsRemaining { get; private set; }
        public bool Cancellable { get; private set; }

        internal RepositoryProgress(
            string stage,
            string message,
            double? percent,
            long? bytesCopied,
            long? bytesTotal,
            long? filesCopied,
            long? filesTotal,
            double? throughputBytesPerSecond,
            double? estimatedSecondsRemaining,
            bool cancellable)
        {
            Stage = stage ?? string.Empty;
            Message = message ?? string.Empty;
            Percent = percent;
            BytesCopied = bytesCopied;
            BytesTotal = bytesTotal;
            FilesCopied = filesCopied;
            FilesTotal = filesTotal;
            ThroughputBytesPerSecond = throughputBytesPerSecond;
            EstimatedSecondsRemaining = estimatedSecondsRemaining;
            Cancellable = cancellable;
        }
    }

    internal sealed class RepositoryManagerResult
    {
        public bool Succeeded { get; private set; }
        public bool UserCancelled { get; private set; }
        public bool Changed { get; private set; }
        public bool OldRepositoryRetained { get; private set; }
        public int ExitCode { get; private set; }
        public string OldRepository { get; private set; }
        public string NewRepository { get; private set; }
        public string PlanId { get; private set; }
        public long PreviousConfigGeneration { get; private set; }
        public long ConfigGeneration { get; private set; }
        public string ErrorMessage { get; private set; }

        internal static RepositoryManagerResult Success(
            bool changed,
            string oldRepository,
            string newRepository,
            bool oldRepositoryRetained,
            string planId,
            long previousConfigGeneration,
            long configGeneration)
        {
            return new RepositoryManagerResult
            {
                Succeeded = true,
                Changed = changed,
                OldRepository = oldRepository,
                NewRepository = newRepository,
                PlanId = planId,
                PreviousConfigGeneration = previousConfigGeneration,
                ConfigGeneration = configGeneration,
                OldRepositoryRetained = oldRepositoryRetained,
                ExitCode = 0
            };
        }

        internal static RepositoryManagerResult Cancelled()
        {
            return new RepositoryManagerResult { UserCancelled = true, ExitCode = 1223 };
        }

        internal static RepositoryManagerResult Failure(string message, int exitCode)
        {
            return new RepositoryManagerResult
            {
                ErrorMessage = string.IsNullOrWhiteSpace(message)
                    ? "The protected repository relocation failed."
                    : message,
                ExitCode = exitCode
            };
        }
    }

    internal sealed class RepositoryRecoveryStatus
    {
        public bool Exists { get; private set; }
        public bool IsRecoverable { get; private set; }
        public string Message { get; private set; }

        private RepositoryRecoveryStatus(bool exists, bool isRecoverable, string message)
        {
            Exists = exists;
            IsRecoverable = isRecoverable;
            Message = message ?? string.Empty;
        }

        internal static RepositoryRecoveryStatus None()
        {
            return new RepositoryRecoveryStatus(false, false, string.Empty);
        }

        internal static RepositoryRecoveryStatus Recoverable()
        {
            return new RepositoryRecoveryStatus(
                true,
                true,
                "A repository move was interrupted. Repair it before another backup runs.");
        }

        internal static RepositoryRecoveryStatus Blocked(string message)
        {
            return new RepositoryRecoveryStatus(true, false, message);
        }
    }

    internal static class RepositoryManagerLauncher
    {
        private static string RequestDomain
        {
            get { return EngineProfile.Current.RepositoryRequestDomain; }
        }

        private static string RecoveryRequestDomain
        {
            get { return EngineProfile.Current.RepositoryRecoveryRequestDomain; }
        }

        private const string ResultDirectoryName = "RepositoryManagerResults";
        private const string JournalFileName = "repository-relocation.journal.json";
        private const int MaximumJsonBytes = 128 * 1024;

        internal static RepositoryManagerResult Run(
            SourceConfiguration configuration,
            string newRepository,
            Action onElevatedProcessStarted,
            Action<RepositoryProgress> onProgress)
        {
            if (configuration == null)
            {
                return RepositoryManagerResult.Failure(
                    "The protected backup configuration is unavailable.",
                    -1);
            }

            string currentRepository;
            string requestedRepository;
            try
            {
                currentRepository = CanonicalizeRepository(configuration.RepositoryPath);
                requestedRepository = CanonicalizeRepository(newRepository);
            }
            catch (Exception error)
            {
                return RepositoryManagerResult.Failure(
                    "The selected repository path is invalid: " + SanitizeError(error.Message),
                    -1);
            }
            if (string.Equals(currentRepository, requestedRepository, StringComparison.OrdinalIgnoreCase))
            {
                return RepositoryManagerResult.Failure(
                    "Choose a different folder from the current repository.",
                    -1);
            }
            if (IsWithin(requestedRepository, currentRepository) ||
                IsWithin(currentRepository, requestedRepository))
            {
                return RepositoryManagerResult.Failure(
                    "The new and current repository folders must not contain one another.",
                    -1);
            }

            string managerPath = Path.Combine(
                configuration.InstallRoot,
                EngineProfile.Current.RepositoryManagerFileName);
            if (!IsRegularFile(managerPath))
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository manager is missing or is not a regular file.",
                    -1);
            }
            if (!IsRegularFile(configuration.ConfigurationPath))
            {
                return RepositoryManagerResult.Failure(
                    "The protected backup configuration is missing or is not a regular file.",
                    -1);
            }

            string configSha256;
            try
            {
                configSha256 = ComputeFileSha256(configuration.ConfigurationPath);
            }
            catch (Exception error)
            {
                return RepositoryManagerResult.Failure(
                    "The protected backup configuration could not be fingerprinted: " +
                        SanitizeError(error.Message),
                    -1);
            }

            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            string userSid = identity.User == null ? null : identity.User.Value;
            if (string.IsNullOrWhiteSpace(userSid))
            {
                return RepositoryManagerResult.Failure(
                    "The current Windows user SID could not be determined.",
                    -1);
            }

            string powerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            if (!IsRegularFile(powerShell))
            {
                return RepositoryManagerResult.Failure(
                    "Windows PowerShell is unavailable in System32.",
                    -1);
            }

            string nonce = CreateNonce();
            string digest = ComputeRequestDigest(
                userSid,
                currentRepository,
                requestedRepository,
                configSha256,
                nonce);
            string resultRoot = EngineProfile.Current.StateResultDirectory(ResultDirectoryName);
            string resultPath = Path.Combine(resultRoot, nonce + ".json");
            string progressPath = resultPath + ".progress.json";
            if (File.Exists(resultPath) || Directory.Exists(resultPath) ||
                File.Exists(progressPath) || Directory.Exists(progressPath))
            {
                return RepositoryManagerResult.Failure(
                    "A protected repository result already uses this request nonce.",
                    -1);
            }

            string[] arguments =
            {
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-WindowStyle",
                "Hidden",
                "-File",
                managerPath,
                "-Relocate",
                "-NewRepository",
                requestedRepository,
                "-ExpectedUserSid",
                userSid,
                "-ExpectedCurrentRepository",
                currentRepository,
                "-ExpectedConfigSha256",
                configSha256,
                "-ResultPath",
                resultPath,
                "-RequestNonce",
                nonce,
                "-RequestDigest",
                digest
            };

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powerShell;
            startInfo.Arguments = BuildArgumentString(arguments);
            startInfo.WorkingDirectory = configuration.InstallRoot;
            startInfo.UseShellExecute = true;
            startInfo.Verb = "runas";
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            startInfo.ErrorDialog = false;

            try
            {
                int exitCode;
                using (Process process = Process.Start(startInfo))
                {
                    if (process == null)
                    {
                        return RepositoryManagerResult.Failure(
                            "Windows did not start the protected repository manager.",
                            -1);
                    }
                    InvokeSafely(onElevatedProcessStarted);
                    string lastProgressFingerprint = string.Empty;
                    while (!process.WaitForExit(500))
                    {
                        PublishProgress(
                            progressPath,
                            nonce,
                            digest,
                            userSid,
                            currentRepository,
                            requestedRepository,
                            configSha256,
                            configuration.PlanId,
                            configuration.ConfigGeneration,
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
                        currentRepository,
                        requestedRepository,
                        configSha256,
                        configuration.PlanId,
                        configuration.ConfigGeneration,
                        onProgress,
                        ref lastProgressFingerprint);
                }
                return ReadBoundResult(
                    resultPath,
                    nonce,
                    digest,
                    userSid,
                    currentRepository,
                    requestedRepository,
                    configSha256,
                    configuration.PlanId,
                    configuration.ConfigGeneration,
                    exitCode);
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode == 1223)
                {
                    return RepositoryManagerResult.Cancelled();
                }
                return RepositoryManagerResult.Failure(
                    SanitizeError(error.Message),
                    error.NativeErrorCode);
            }
            catch (Exception error)
            {
                return RepositoryManagerResult.Failure(SanitizeError(error.Message), -1);
            }
        }

        internal static RepositoryRecoveryStatus GetRecoveryStatus()
        {
            string journalPath = GetRecoveryJournalPath();
            if (!File.Exists(journalPath) && !Directory.Exists(journalPath))
            {
                return RepositoryRecoveryStatus.None();
            }

            try
            {
                WindowsIdentity identity = WindowsIdentity.GetCurrent();
                string userSid = identity.User == null ? null : identity.User.Value;
                if (string.IsNullOrWhiteSpace(userSid) ||
                    !IsRegularFile(journalPath) ||
                    !HasProtectedResultAcl(journalPath, userSid))
                {
                    return RepositoryRecoveryStatus.Blocked(
                        "The interrupted-move journal is not trustworthy. Backups remain paused; repair the protected installation before continuing.");
                }
                FileInfo journal = new FileInfo(journalPath);
                if (journal.Length <= 0 || journal.Length > MaximumJsonBytes)
                {
                    return RepositoryRecoveryStatus.Blocked(
                        "The interrupted-move journal has an invalid size. Backups remain paused until it is repaired.");
                }
                return RepositoryRecoveryStatus.Recoverable();
            }
            catch (Exception error)
            {
                return RepositoryRecoveryStatus.Blocked(
                    "The interrupted-move journal could not be validated: " +
                        SanitizeError(error.Message));
            }
        }

        internal static RepositoryManagerResult Recover(
            Action onElevatedProcessStarted,
            Action<RepositoryProgress> onProgress)
        {
            RepositoryRecoveryStatus status = GetRecoveryStatus();
            if (!status.Exists)
            {
                return RepositoryManagerResult.Failure(
                    "No interrupted repository move needs repair.",
                    -1);
            }
            if (!status.IsRecoverable)
            {
                return RepositoryManagerResult.Failure(status.Message, -1);
            }

            string managerPath;
            try
            {
                managerPath = EngineProfile.Current.ManagerPath(
                    EngineProfile.Current.RepositoryManagerFileName);
            }
            catch (InvalidOperationException error)
            {
                return RepositoryManagerResult.Failure(error.Message, -1);
            }
            if (!IsRegularFile(managerPath))
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository manager is missing or is not a regular file.",
                    -1);
            }

            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            string userSid = identity.User == null ? null : identity.User.Value;
            if (string.IsNullOrWhiteSpace(userSid))
            {
                return RepositoryManagerResult.Failure(
                    "The current Windows user SID could not be determined.",
                    -1);
            }

            string journalPath = GetRecoveryJournalPath();
            string journalSha256;
            try
            {
                journalSha256 = ComputeFileSha256(journalPath);
            }
            catch (Exception error)
            {
                return RepositoryManagerResult.Failure(
                    "The interrupted-move journal could not be fingerprinted: " +
                        SanitizeError(error.Message),
                    -1);
            }

            string powerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            if (!IsRegularFile(powerShell))
            {
                return RepositoryManagerResult.Failure(
                    "Windows PowerShell is unavailable in System32.",
                    -1);
            }

            string nonce = CreateNonce();
            string digest = ComputeRecoveryRequestDigest(userSid, journalSha256, nonce);
            string resultRoot = EngineProfile.Current.StateResultDirectory(ResultDirectoryName);
            string resultPath = Path.Combine(resultRoot, nonce + ".json");
            string progressPath = resultPath + ".progress.json";
            if (File.Exists(resultPath) || Directory.Exists(resultPath) ||
                File.Exists(progressPath) || Directory.Exists(progressPath))
            {
                return RepositoryManagerResult.Failure(
                    "A protected repository result already uses this request nonce.",
                    -1);
            }

            string[] arguments =
            {
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-WindowStyle",
                "Hidden",
                "-File",
                managerPath,
                "-Recover",
                "-ExpectedUserSid",
                userSid,
                "-ExpectedJournalSha256",
                journalSha256,
                "-ResultPath",
                resultPath,
                "-RequestNonce",
                nonce,
                "-RequestDigest",
                digest
            };

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powerShell;
            startInfo.Arguments = BuildArgumentString(arguments);
            startInfo.WorkingDirectory = Path.GetDirectoryName(managerPath);
            startInfo.UseShellExecute = true;
            startInfo.Verb = "runas";
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            startInfo.ErrorDialog = false;

            try
            {
                int exitCode;
                using (Process process = Process.Start(startInfo))
                {
                    if (process == null)
                    {
                        return RepositoryManagerResult.Failure(
                            "Windows did not start protected repository recovery.",
                            -1);
                    }
                    InvokeSafely(onElevatedProcessStarted);
                    string lastProgressFingerprint = string.Empty;
                    while (!process.WaitForExit(500))
                    {
                        PublishRecoveryProgress(
                            progressPath,
                            nonce,
                            digest,
                            userSid,
                            journalSha256,
                            onProgress,
                            ref lastProgressFingerprint);
                    }
                    process.WaitForExit();
                    exitCode = process.ExitCode;
                    PublishRecoveryProgress(
                        progressPath,
                        nonce,
                        digest,
                        userSid,
                        journalSha256,
                        onProgress,
                        ref lastProgressFingerprint);
                }
                return ReadBoundRecoveryResult(
                    resultPath,
                    nonce,
                    digest,
                    userSid,
                    journalSha256,
                    exitCode);
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode == 1223)
                {
                    return RepositoryManagerResult.Cancelled();
                }
                return RepositoryManagerResult.Failure(
                    SanitizeError(error.Message),
                    error.NativeErrorCode);
            }
            catch (Exception error)
            {
                return RepositoryManagerResult.Failure(SanitizeError(error.Message), -1);
            }
        }

        internal static string ComputeRequestDigest(
            string userSid,
            string currentRepository,
            string newRepository,
            string configSha256,
            string nonce)
        {
            string payload = RequestDomain + "\n" + userSid + "\nrelocate\n" +
                currentRepository + "\n" + newRepository + "\n" +
                configSha256.ToLowerInvariant() + "\n" + nonce.ToLowerInvariant();
            using (SHA256 algorithm = SHA256.Create())
            {
                return ToLowerHex(
                    algorithm.ComputeHash(new UTF8Encoding(false).GetBytes(payload)));
            }
        }

        internal static string ComputeRecoveryRequestDigest(
            string userSid,
            string journalSha256,
            string nonce)
        {
            string payload = RecoveryRequestDomain + "\n" + userSid + "\nrecover\n" +
                journalSha256.ToLowerInvariant() + "\n" + nonce.ToLowerInvariant();
            using (SHA256 algorithm = SHA256.Create())
            {
                return ToLowerHex(
                    algorithm.ComputeHash(new UTF8Encoding(false).GetBytes(payload)));
            }
        }

        internal static string CanonicalizeRepository(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || !Path.IsPathRooted(value))
            {
                throw new ArgumentException("A fully qualified folder is required.");
            }
            string fullPath = Path.GetFullPath(value);
            string root = Path.GetPathRoot(fullPath);
            if (string.Equals(fullPath, root, StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("A drive root cannot be used as the repository.");
            }
            return fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        private static RepositoryManagerResult ReadBoundResult(
            string resultPath,
            string nonce,
            string digest,
            string userSid,
            string currentRepository,
            string newRepository,
            string configSha256,
            string planId,
            long configGeneration,
            int exitCode)
        {
            for (int attempt = 0; attempt < 20 && !File.Exists(resultPath); attempt++)
            {
                Thread.Sleep(50);
            }
            if (!File.Exists(resultPath))
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository manager returned exit code " +
                        exitCode.ToString(CultureInfo.InvariantCulture) +
                        " without a validated result.",
                    exitCode);
            }
            string resultRoot = Path.GetDirectoryName(resultPath);
            string stateRoot = string.IsNullOrWhiteSpace(resultRoot)
                ? null
                : Path.GetDirectoryName(resultRoot);
            if (string.IsNullOrWhiteSpace(stateRoot) ||
                !string.Equals(Path.GetFileName(stateRoot), EngineProfile.Current.ProductDirectoryName, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetFileName(resultRoot), ResultDirectoryName, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetFileName(resultPath), nonce + ".json", StringComparison.Ordinal) ||
                !IsRegularFile(resultPath) ||
                !HasProtectedResultAcl(stateRoot, userSid) ||
                !HasProtectedResultAcl(resultRoot, userSid))
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository-manager result path is not trustworthy.",
                    exitCode);
            }

            try
            {
                using (FileStream stream = new FileStream(
                    resultPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    4096,
                    FileOptions.SequentialScan))
                {
                    if (!HasProtectedResultAcl(stream.GetAccessControl(), userSid) ||
                        stream.Length <= 0 || stream.Length > MaximumJsonBytes)
                    {
                        return RepositoryManagerResult.Failure(
                            "The protected repository-manager result file is not trustworthy.",
                            exitCode);
                    }
                    using (StreamReader reader = new StreamReader(
                        stream,
                        new UTF8Encoding(false, true),
                        true,
                        4096,
                        true))
                    {
                        IDictionary<string, object> document =
                            new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()) as
                                IDictionary<string, object>;
                        return ValidateResult(
                            document,
                            nonce,
                            digest,
                            userSid,
                            currentRepository,
                            newRepository,
                            configSha256,
                            planId,
                            configGeneration,
                            exitCode);
                    }
                }
            }
            catch (Exception error)
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository-manager result could not be validated: " +
                        SanitizeError(error.Message),
                    exitCode);
            }
        }

        private static RepositoryManagerResult ValidateResult(
            IDictionary<string, object> document,
            string nonce,
            string digest,
            string userSid,
            string currentRepository,
            string newRepository,
            string configSha256,
            string planId,
            long configGeneration,
            int exitCode)
        {
            if (document == null || ReadInteger(document, "schema_version") != 1 ||
                !FixedEquals(ReadString(document, "request_nonce"), nonce) ||
                !FixedEquals(ReadString(document, "request_digest"), digest) ||
                !FixedEquals(ReadString(document, "request_user_sid"), userSid) ||
                !FixedEquals(ReadString(document, "action"), "relocate") ||
                !PathEquals(ReadString(document, "current_repository"), currentRepository) ||
                !PathEquals(ReadString(document, "new_repository"), newRepository) ||
                !FixedEquals(ReadString(document, "expected_config_sha256"), configSha256))
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository-manager result did not match this request.",
                    exitCode);
            }

            bool ok = ReadBoolean(document, "ok");
            bool changed = ReadBoolean(document, "changed");
            bool retained = ReadBoolean(document, "old_repository_retained");
            string oldRepository = ReadString(document, "old_repository");
            string reportedNewRepository = ReadString(document, "new_repository");
            string reportedPlanId = ReadOptionalString(document, "plan_id");
            long? reportedPreviousGeneration =
                ReadOptionalLong(document, "previous_config_generation");
            long? reportedGeneration = ReadOptionalLong(document, "config_generation");
            string error = ReadOptionalString(document, "error");
            bool planTransitionMatches =
                FixedEquals(reportedPlanId, planId) &&
                reportedPreviousGeneration.HasValue &&
                reportedPreviousGeneration.Value == configGeneration &&
                configGeneration < long.MaxValue &&
                reportedGeneration.HasValue &&
                reportedGeneration.Value == configGeneration + 1;
            bool hasAnyPlanField = reportedPlanId != null ||
                reportedPreviousGeneration.HasValue || reportedGeneration.HasValue;
            if (hasAnyPlanField && !planTransitionMatches)
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository-manager result reported an invalid plan generation transition.",
                    exitCode);
            }
            if (ok && exitCode == 0 && changed && retained &&
                PathEquals(oldRepository, currentRepository) &&
                PathEquals(reportedNewRepository, newRepository) &&
                planTransitionMatches)
            {
                return RepositoryManagerResult.Success(
                    changed,
                    oldRepository,
                    reportedNewRepository,
                    retained,
                    reportedPlanId,
                    reportedPreviousGeneration.Value,
                    reportedGeneration.Value);
            }
            if (!ok && exitCode != 0)
            {
                return RepositoryManagerResult.Failure(SanitizeError(error), exitCode);
            }
            return RepositoryManagerResult.Failure(
                "The protected repository-manager result disagreed with the process result or retention policy.",
                exitCode);
        }

        private static RepositoryManagerResult ReadBoundRecoveryResult(
            string resultPath,
            string nonce,
            string digest,
            string userSid,
            string journalSha256,
            int exitCode)
        {
            for (int attempt = 0; attempt < 20 && !File.Exists(resultPath); attempt++)
            {
                Thread.Sleep(50);
            }
            if (!File.Exists(resultPath))
            {
                return RepositoryManagerResult.Failure(
                    "Protected repository recovery returned exit code " +
                        exitCode.ToString(CultureInfo.InvariantCulture) +
                        " without a validated result.",
                    exitCode);
            }
            string resultRoot = Path.GetDirectoryName(resultPath);
            string stateRoot = string.IsNullOrWhiteSpace(resultRoot)
                ? null
                : Path.GetDirectoryName(resultRoot);
            if (string.IsNullOrWhiteSpace(stateRoot) ||
                !string.Equals(Path.GetFileName(stateRoot), EngineProfile.Current.ProductDirectoryName, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetFileName(resultRoot), ResultDirectoryName, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetFileName(resultPath), nonce + ".json", StringComparison.Ordinal) ||
                !IsRegularFile(resultPath) ||
                !HasProtectedResultAcl(stateRoot, userSid) ||
                !HasProtectedResultAcl(resultRoot, userSid))
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository-recovery result path is not trustworthy.",
                    exitCode);
            }

            try
            {
                using (FileStream stream = new FileStream(
                    resultPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    4096,
                    FileOptions.SequentialScan))
                {
                    if (!HasProtectedResultAcl(stream.GetAccessControl(), userSid) ||
                        stream.Length <= 0 || stream.Length > MaximumJsonBytes)
                    {
                        return RepositoryManagerResult.Failure(
                            "The protected repository-recovery result file is not trustworthy.",
                            exitCode);
                    }
                    using (StreamReader reader = new StreamReader(
                        stream,
                        new UTF8Encoding(false, true),
                        true,
                        4096,
                        true))
                    {
                        IDictionary<string, object> document =
                            new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()) as
                                IDictionary<string, object>;
                        return ValidateRecoveryResult(
                            document,
                            nonce,
                            digest,
                            userSid,
                            journalSha256,
                            exitCode);
                    }
                }
            }
            catch (Exception error)
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository-recovery result could not be validated: " +
                        SanitizeError(error.Message),
                    exitCode);
            }
        }

        private static RepositoryManagerResult ValidateRecoveryResult(
            IDictionary<string, object> document,
            string nonce,
            string digest,
            string userSid,
            string journalSha256,
            int exitCode)
        {
            if (document == null || ReadInteger(document, "schema_version") != 1 ||
                !FixedEquals(ReadString(document, "request_nonce"), nonce) ||
                !FixedEquals(ReadString(document, "request_digest"), digest) ||
                !FixedEquals(ReadString(document, "request_user_sid"), userSid) ||
                !FixedEquals(ReadString(document, "action"), "recover") ||
                !FixedEquals(ReadString(document, "expected_journal_sha256"), journalSha256))
            {
                return RepositoryManagerResult.Failure(
                    "The protected repository-recovery result did not match this request.",
                    exitCode);
            }

            bool ok = ReadBoolean(document, "ok");
            string error = ReadOptionalString(document, "error");
            if (!ok && exitCode != 0)
            {
                return RepositoryManagerResult.Failure(SanitizeError(error), exitCode);
            }

            bool changed = ReadBoolean(document, "changed");
            bool retained = ReadBoolean(document, "old_repository_retained");
            string currentRepository = ReadString(document, "current_repository");
            string oldRepository = ReadString(document, "old_repository");
            string newRepository = ReadString(document, "new_repository");
            string repository = ReadString(document, "repository");
            string planId = ReadOptionalString(document, "plan_id");
            long? previousGeneration =
                ReadOptionalLong(document, "previous_config_generation");
            long? generation = ReadOptionalLong(document, "config_generation");
            long? abandonedGeneration =
                ReadOptionalLong(document, "abandoned_config_generation");
            Guid parsedPlanId;
            bool validPlanTransition = !string.IsNullOrWhiteSpace(planId) &&
                Guid.TryParseExact(planId, "D", out parsedPlanId) &&
                string.Equals(planId, parsedPlanId.ToString("D"), StringComparison.Ordinal) &&
                previousGeneration.HasValue && previousGeneration.Value > 0 &&
                generation.HasValue && generation.Value == previousGeneration.Value &&
                generation.Value < long.MaxValue && abandonedGeneration.HasValue &&
                abandonedGeneration.Value == generation.Value + 1;
            if (ok && exitCode == 0 && changed && retained &&
                PathEquals(currentRepository, oldRepository) &&
                PathEquals(repository, oldRepository) &&
                !PathEquals(newRepository, oldRepository) && validPlanTransition)
            {
                return RepositoryManagerResult.Success(
                    changed,
                    oldRepository,
                    newRepository,
                    retained,
                    planId,
                    previousGeneration.Value,
                    generation.Value);
            }
            return RepositoryManagerResult.Failure(
                "The protected repository-recovery result disagreed with the process result or retention policy.",
                exitCode);
        }

        private static void PublishRecoveryProgress(
            string progressPath,
            string nonce,
            string digest,
            string userSid,
            string journalSha256,
            Action<RepositoryProgress> callback,
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
                if (string.Equals(fingerprint, lastFingerprint, StringComparison.Ordinal))
                {
                    return;
                }
                if (item.Length <= 0 || item.Length > MaximumJsonBytes ||
                    (item.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    !HasProtectedResultAcl(progressPath, userSid))
                {
                    return;
                }
                IDictionary<string, object> document =
                    new JavaScriptSerializer().DeserializeObject(
                        File.ReadAllText(progressPath, Encoding.UTF8)) as IDictionary<string, object>;
                if (document == null ||
                    ReadInteger(document, "schema_version") != 1 ||
                    !FixedEquals(ReadString(document, "request_nonce"), nonce) ||
                    !FixedEquals(ReadString(document, "request_digest"), digest) ||
                    !FixedEquals(ReadString(document, "request_user_sid"), userSid) ||
                    !FixedEquals(ReadString(document, "action"), "recover") ||
                    !FixedEquals(ReadString(document, "expected_journal_sha256"), journalSha256))
                {
                    return;
                }
                string stage = ReadOptionalString(document, "stage") ?? string.Empty;
                if (stage != "preflight" && stage != "activating" &&
                    stage != "complete" && stage != "failed")
                {
                    return;
                }
                bool cancellable = ReadBoolean(document, "cancellable");
                if (cancellable)
                {
                    return;
                }
                lastFingerprint = fingerprint;
                callback(new RepositoryProgress(
                    stage,
                    ReadOptionalString(document, "message") ?? string.Empty,
                    ReadOptionalDouble(document, "percent"),
                    ReadOptionalLong(document, "bytes_copied"),
                    ReadOptionalLong(document, "bytes_total"),
                    ReadOptionalLong(document, "files_copied"),
                    ReadOptionalLong(document, "files_total"),
                    ReadOptionalDouble(document, "throughput_bytes_per_second"),
                    ReadOptionalDouble(document, "estimated_seconds_remaining"),
                    false));
            }
            catch
            {
                // Progress is advisory. The bound final result remains authoritative.
            }
        }

        private static void PublishProgress(
            string progressPath,
            string nonce,
            string digest,
            string userSid,
            string currentRepository,
            string newRepository,
            string configSha256,
            string planId,
            long configGeneration,
            Action<RepositoryProgress> callback,
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
                if (string.Equals(fingerprint, lastFingerprint, StringComparison.Ordinal))
                {
                    return;
                }
                if (item.Length <= 0 || item.Length > MaximumJsonBytes ||
                    (item.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    !HasProtectedResultAcl(progressPath, userSid))
                {
                    return;
                }
                IDictionary<string, object> document =
                    new JavaScriptSerializer().DeserializeObject(
                        File.ReadAllText(progressPath, Encoding.UTF8)) as IDictionary<string, object>;
                if (document == null)
                {
                    return;
                }
                if (ReadInteger(document, "schema_version") != 1 ||
                    !FixedEquals(ReadString(document, "request_nonce"), nonce) ||
                    !FixedEquals(ReadString(document, "request_digest"), digest) ||
                    !FixedEquals(ReadString(document, "request_user_sid"), userSid) ||
                    !FixedEquals(ReadString(document, "action"), "relocate") ||
                    !PathEquals(ReadString(document, "current_repository"), currentRepository) ||
                    !PathEquals(ReadString(document, "new_repository"), newRepository) ||
                    !FixedEquals(ReadString(document, "expected_config_sha256"), configSha256))
                {
                    return;
                }
                string reportedPlanId = ReadOptionalString(document, "plan_id");
                long? reportedPreviousGeneration =
                    ReadOptionalLong(document, "previous_config_generation");
                long? reportedGeneration = ReadOptionalLong(document, "config_generation");
                bool hasAnyPlanField = reportedPlanId != null ||
                    reportedPreviousGeneration.HasValue || reportedGeneration.HasValue;
                if (hasAnyPlanField &&
                    (!FixedEquals(reportedPlanId, planId) ||
                     !reportedPreviousGeneration.HasValue ||
                     reportedPreviousGeneration.Value != configGeneration ||
                     configGeneration == long.MaxValue ||
                     !reportedGeneration.HasValue ||
                     reportedGeneration.Value != configGeneration + 1))
                {
                    return;
                }
                string stage = ReadOptionalString(document, "stage") ?? string.Empty;
                if (stage != "preflight" && stage != "copying" &&
                    stage != "verifying" && stage != "activating" &&
                    stage != "complete" && stage != "failed")
                {
                    return;
                }
                string message = ReadOptionalString(document, "message") ?? string.Empty;
                double? percent = ReadOptionalDouble(document, "percent");
                long? copied = ReadOptionalLong(document, "bytes_copied");
                long? total = ReadOptionalLong(document, "bytes_total");
                long? filesCopied = ReadOptionalLong(document, "files_copied");
                long? filesTotal = ReadOptionalLong(document, "files_total");
                double? throughput = ReadOptionalDouble(document, "throughput_bytes_per_second");
                double? eta = ReadOptionalDouble(document, "estimated_seconds_remaining");
                bool cancellable = ReadBoolean(document, "cancellable");
                if (stage == "activating" && cancellable)
                {
                    return;
                }
                lastFingerprint = fingerprint;
                callback(new RepositoryProgress(
                    stage,
                    message,
                    percent,
                    copied,
                    total,
                    filesCopied,
                    filesTotal,
                    throughput,
                    eta,
                    cancellable));
            }
            catch
            {
                // Progress is advisory. The bound final result remains authoritative.
            }
        }

        private static string ComputeFileSha256(string path)
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
                    throw new InvalidDataException("The configuration has an invalid size.");
                }
                return ToLowerHex(algorithm.ComputeHash(stream));
            }
        }

        private static string GetRecoveryJournalPath()
        {
            return Path.Combine(EngineProfile.Current.StateDirectory(), JournalFileName);
        }

        private static bool IsRegularFile(string path)
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

        private static bool IsWithin(string candidate, string parent)
        {
            string prefix = parent.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
                Path.DirectorySeparatorChar;
            return candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }

        private static bool HasProtectedResultAcl(string path, string userSid)
        {
            try
            {
                FileSystemSecurity security = Directory.Exists(path)
                    ? (FileSystemSecurity)new DirectoryInfo(path).GetAccessControl(
                        AccessControlSections.Owner | AccessControlSections.Access)
                    : (FileSystemSecurity)new FileInfo(path).GetAccessControl(
                        AccessControlSections.Owner | AccessControlSections.Access);
                return HasProtectedResultAcl(security, userSid);
            }
            catch
            {
                return false;
            }
        }

        private static bool HasProtectedResultAcl(FileSystemSecurity security, string userSid)
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
                HashSet<string> allowed = new HashSet<string>(required, StringComparer.OrdinalIgnoreCase);
                allowed.Add("S-1-3-4");
                HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                FileSystemRights dangerous = FileSystemRights.WriteData |
                    FileSystemRights.AppendData |
                    FileSystemRights.WriteAttributes |
                    FileSystemRights.WriteExtendedAttributes |
                    FileSystemRights.Delete |
                    FileSystemRights.DeleteSubdirectoriesAndFiles |
                    FileSystemRights.ChangePermissions |
                    FileSystemRights.TakeOwnership;
                AuthorizationRuleCollection rules = security.GetAccessRules(
                    true,
                    true,
                    typeof(SecurityIdentifier));
                foreach (FileSystemAccessRule rule in rules)
                {
                    SecurityIdentifier sid = rule.IdentityReference as SecurityIdentifier;
                    string value = sid == null ? null : sid.Value;
                    if (value == null || rule.IsInherited ||
                        rule.AccessControlType != AccessControlType.Allow ||
                        !allowed.Contains(value))
                    {
                        return false;
                    }
                    if (value == "S-1-5-18" || value == "S-1-5-32-544")
                    {
                        if ((rule.FileSystemRights & FileSystemRights.FullControl) !=
                            FileSystemRights.FullControl)
                        {
                            return false;
                        }
                    }
                    else if ((rule.FileSystemRights & dangerous) != 0 ||
                        (rule.FileSystemRights & FileSystemRights.ReadAndExecute) !=
                            FileSystemRights.ReadAndExecute)
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

        private static string CreateNonce()
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
            StringBuilder value = new StringBuilder(bytes.Length * 2);
            foreach (byte item in bytes)
            {
                value.Append(item.ToString("x2", CultureInfo.InvariantCulture));
            }
            return value.ToString();
        }

        private static void InvokeSafely(Action callback)
        {
            if (callback == null)
            {
                return;
            }
            try { callback(); }
            catch { }
        }

        private static bool PathEquals(string left, string right)
        {
            try
            {
                return string.Equals(
                    CanonicalizeRepository(left),
                    CanonicalizeRepository(right),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private static bool FixedEquals(string left, string right)
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

        private static int ReadInteger(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value))
            {
                throw new InvalidDataException("Result field is missing: " + name);
            }
            return Convert.ToInt32(value, CultureInfo.InvariantCulture);
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

        private static double? ReadOptionalDouble(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null)
            {
                return null;
            }
            return Convert.ToDouble(value, CultureInfo.InvariantCulture);
        }

        private static long? ReadOptionalLong(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null)
            {
                return null;
            }
            return Convert.ToInt64(value, CultureInfo.InvariantCulture);
        }

        private static string SanitizeError(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return "The protected repository relocation failed.";
            }
            StringBuilder clean = new StringBuilder();
            foreach (char character in value)
            {
                if (!char.IsControl(character) || character == '\t')
                {
                    clean.Append(character);
                }
                if (clean.Length >= 2000)
                {
                    break;
                }
            }
            return clean.ToString().Trim();
        }

        private static string BuildArgumentString(IEnumerable<string> arguments)
        {
            StringBuilder result = new StringBuilder();
            foreach (string argument in arguments)
            {
                if (result.Length > 0)
                {
                    result.Append(' ');
                }
                result.Append(QuoteWindowsArgument(argument));
            }
            return result.ToString();
        }

        private static string QuoteWindowsArgument(string value)
        {
            if (value == null)
            {
                throw new ArgumentNullException("value");
            }
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                return value;
            }
            StringBuilder result = new StringBuilder();
            result.Append('"');
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('"');
                    backslashes = 0;
                    continue;
                }
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(character);
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }
    }
}
