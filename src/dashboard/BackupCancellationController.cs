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
    internal enum BackupCancellationOutcome
    {
        Requested,
        UserCancelled,
        AlreadyFinished,
        Error
    }

    internal sealed class BackupCancellationResult
    {
        public BackupCancellationOutcome Outcome { get; private set; }
        public bool Requested { get { return Outcome == BackupCancellationOutcome.Requested; } }
        public bool UserCancelled { get { return Outcome == BackupCancellationOutcome.UserCancelled; } }
        public bool AlreadyFinished { get { return Outcome == BackupCancellationOutcome.AlreadyFinished; } }
        public bool Error { get { return Outcome == BackupCancellationOutcome.Error; } }
        public int ExitCode { get; private set; }
        public string ErrorMessage { get; private set; }

        public static BackupCancellationResult RequestAccepted()
        {
            return new BackupCancellationResult
            {
                Outcome = BackupCancellationOutcome.Requested,
                ExitCode = 0
            };
        }

        public static BackupCancellationResult CancelledByUser()
        {
            return new BackupCancellationResult
            {
                Outcome = BackupCancellationOutcome.UserCancelled,
                ExitCode = 1223
            };
        }

        public static BackupCancellationResult Finished()
        {
            return new BackupCancellationResult
            {
                Outcome = BackupCancellationOutcome.AlreadyFinished,
                ExitCode = 0
            };
        }

        public static BackupCancellationResult Failure(string message, int exitCode)
        {
            return new BackupCancellationResult
            {
                Outcome = BackupCancellationOutcome.Error,
                ErrorMessage = message,
                ExitCode = exitCode
            };
        }
    }

    internal static class BackupCancellationController
    {
        private static string RequestDomain
        {
            get { return EngineProfile.Current.BackupControlRequestDomain; }
        }

        private static string ManagerFileName
        {
            get { return EngineProfile.Current.BackupManagerFileName; }
        }

        private const string ResultDirectoryName = "BackupManagerResults";
        private const string StatusFileName = "status.json";
        private const int MaximumStatusBytes = 4 * 1024 * 1024;
        private const int MaximumResultBytes = 64 * 1024;
        private const int ManagerTimeoutMilliseconds = 120000;
        private static readonly HashSet<string> ActiveStates = new HashSet<string>(
            new[]
            {
                "starting",
                // The wrappers' preflight and storage phases. Each engine's own manager decides which of them it
                // accepts (the legacy personal edition's verifies storage after the backup).
                "checking_repository_storage",
                "preflighting_sources",
                "authenticating_repository",
                "verifying_repository_storage",
                "backing_up",
                "verifying_snapshot",
                "checking_repository",
                "restoring_canary",
                "checking_data_subset",
                "cancelling"
            },
            StringComparer.Ordinal);
        private static readonly HashSet<string> TerminalStates = new HashSet<string>(
            new[]
            {
                "success",
                "success_unchanged",
                "failed",
                "partial",
                "cancelled",
                "cancel_failed"
            },
            StringComparer.Ordinal);

        public static BackupCancellationResult RequestCancel(string expectedRunId)
        {
            return RequestCancel(expectedRunId, null);
        }

        public static BackupCancellationResult RequestCancel(
            string expectedRunId,
            Action onElevatedProcessStarted)
        {
            string runIdError;
            if (!TryValidateRunId(expectedRunId, out runIdError))
            {
                return BackupCancellationResult.Failure(runIdError, -1);
            }

            ActiveBackupStatus activeStatus;
            bool alreadyFinished;
            string statusError;
            if (!TryReadActiveStatus(
                expectedRunId,
                out activeStatus,
                out alreadyFinished,
                out statusError))
            {
                return BackupCancellationResult.Failure(statusError, -1);
            }
            if (alreadyFinished)
            {
                return BackupCancellationResult.Finished();
            }

            TaskScheduleReadResult taskResult = TaskScheduleReader.ReadInstalled();
            if (!taskResult.Succeeded || taskResult.Schedule == null)
            {
                return BackupCancellationResult.Failure(
                    taskResult.ErrorMessage ?? "The protected backup task is unavailable.",
                    -1);
            }
            TaskSchedule task = taskResult.Schedule;
            if (task.State == BackupTaskState.Unknown)
            {
                return BackupCancellationResult.Failure(
                    "The protected backup task state could not be confirmed.",
                    -1);
            }
            if (task.State != BackupTaskState.Running)
            {
                return BackupCancellationResult.Finished();
            }

            string userSid;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                userSid = identity.User == null ? null : identity.User.Value;
            }
            if (string.IsNullOrEmpty(userSid) ||
                !string.Equals(userSid, task.UserSid, StringComparison.OrdinalIgnoreCase))
            {
                return BackupCancellationResult.Failure(
                    "The protected backup task does not belong to the current Windows user.",
                    -1);
            }
            if (!IsLowerHexDigest(task.SemanticFingerprint))
            {
                return BackupCancellationResult.Failure(
                    "The protected backup task fingerprint is invalid.",
                    -1);
            }

            string installRoot = EngineProfile.Current.InstallRoot();
            string managerPath = Path.Combine(installRoot, ManagerFileName);
            string managerError;
            if (!ValidateManagerPath(managerPath, installRoot, out managerError))
            {
                return BackupCancellationResult.Failure(managerError, -1);
            }

            string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string powerShell = Path.Combine(
                systemDirectory,
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            if (!File.Exists(powerShell))
            {
                return BackupCancellationResult.Failure(
                    "Windows PowerShell is unavailable in System32.",
                    -1);
            }

            string requestNonce = CreateNonce();
            string requestDigest = ComputeRequestDigest(
                userSid,
                expectedRunId,
                activeStatus.WrapperPid,
                task.SemanticFingerprint,
                requestNonce);
            string resultRoot = EngineProfile.Current.StateResultDirectory(ResultDirectoryName);
            string resultPath = Path.Combine(resultRoot, requestNonce + ".json");
            if (File.Exists(resultPath) || Directory.Exists(resultPath))
            {
                return BackupCancellationResult.Failure(
                    "A protected backup-control result already uses this request nonce.",
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
                "-Action",
                "Cancel",
                "-RunId",
                expectedRunId,
                "-ExpectedWrapperPid",
                activeStatus.WrapperPid.ToString(CultureInfo.InvariantCulture),
                "-ExpectedTaskFingerprint",
                task.SemanticFingerprint,
                "-ExpectedUserSid",
                userSid,
                "-ResultPath",
                resultPath,
                "-RequestNonce",
                requestNonce
            };

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powerShell;
            startInfo.Arguments = BuildArgumentString(arguments);
            startInfo.WorkingDirectory = installRoot;
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
                        return BackupCancellationResult.Failure(
                            "Windows did not start the protected backup manager.",
                            -1);
                    }
                    if (onElevatedProcessStarted != null)
                    {
                        try { onElevatedProcessStarted(); }
                        catch { }
                    }
                    if (!process.WaitForExit(ManagerTimeoutMilliseconds))
                    {
                        return BackupCancellationResult.Failure(
                            "The protected backup manager did not finish in time.",
                            -1);
                    }
                    process.WaitForExit();
                    exitCode = process.ExitCode;
                }

                ValidatedCancellationResult validated;
                string resultError;
                if (!TryReadBoundResult(
                    resultPath,
                    requestNonce,
                    requestDigest,
                    userSid,
                    expectedRunId,
                    exitCode,
                    out validated,
                    out resultError))
                {
                    return BackupCancellationResult.Failure(resultError, exitCode);
                }
                if (!validated.Ok)
                {
                    return BackupCancellationResult.Failure(
                        validated.ErrorMessage,
                        exitCode);
                }
                return validated.AlreadyFinished
                    ? BackupCancellationResult.Finished()
                    : BackupCancellationResult.RequestAccepted();
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode == 1223)
                {
                    return BackupCancellationResult.CancelledByUser();
                }
                return BackupCancellationResult.Failure(
                    TaskScheduleReader.SanitizeError(error.Message),
                    error.NativeErrorCode);
            }
            catch (Exception error)
            {
                return BackupCancellationResult.Failure(
                    TaskScheduleReader.SanitizeError(error.Message),
                    -1);
            }
        }

        // The wrapper rewrites the status file all through a run, so the file is opened in a way that never keeps the writer out
        // (see TryReadActiveStatusOnce). That also lets a read land in the middle of a rewrite. The checks reject a document that
        // is cut short, and the read is tried again a moment later, like the telemetry reader does, instead of accepting it.
        private const int StatusReadAttempts = 3;

        private static bool TryReadActiveStatus(
            string expectedRunId,
            out ActiveBackupStatus status,
            out bool alreadyFinished,
            out string error)
        {
            for (int attempt = 0; ; attempt++)
            {
                bool read = TryReadActiveStatusOnce(
                    expectedRunId,
                    out status,
                    out alreadyFinished,
                    out error);
                if (read || attempt >= StatusReadAttempts - 1)
                {
                    return read;
                }
                Thread.Sleep(15 * (attempt + 1));
            }
        }

        private static bool TryReadActiveStatusOnce(
            string expectedRunId,
            out ActiveBackupStatus status,
            out bool alreadyFinished,
            out string error)
        {
            status = null;
            alreadyFinished = false;
            error = null;
            string stateRoot = EngineProfile.Current.StateDirectory();
            string statusPath = Path.Combine(stateRoot, StatusFileName);
            try
            {
                if (!Directory.Exists(stateRoot) ||
                    (File.GetAttributes(stateRoot) & FileAttributes.ReparsePoint) != 0)
                {
                    error = "The protected backup state directory is unavailable or unsafe.";
                    return false;
                }
                if (Directory.Exists(statusPath))
                {
                    error = "The protected backup status is not a normal file.";
                    return false;
                }
                if (!File.Exists(statusPath))
                {
                    alreadyFinished = true;
                    return true;
                }
                if ((File.GetAttributes(statusPath) & FileAttributes.ReparsePoint) != 0)
                {
                    error = "The protected backup status is not a normal file.";
                    return false;
                }
                // Shared for writing and deleting as well: the wrapper keeps rewriting this file, and a reader that does not share
                // makes that rewrite fail while it is being read (and this read fail while a rewrite is under way). Nothing else
                // is relaxed: the directory and file checks above and the size, strict UTF-8 and document checks below are as before.
                using (FileStream stream = new FileStream(
                    statusPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete,
                    4096,
                    FileOptions.SequentialScan))
                {
                    if (stream.Length <= 0 || stream.Length > MaximumStatusBytes)
                    {
                        error = "The protected backup status has an invalid size.";
                        return false;
                    }
                    using (StreamReader reader = new StreamReader(
                        stream,
                        new UTF8Encoding(false, true),
                        true,
                        4096,
                        true))
                    {
                        return TryValidateStatusDocument(
                            reader.ReadToEnd(),
                            expectedRunId,
                            out status,
                            out alreadyFinished,
                            out error);
                    }
                }
            }
            catch (Exception exception)
            {
                error = "The protected backup status could not be validated: " +
                    TaskScheduleReader.SanitizeError(exception.Message);
                return false;
            }
        }

        internal static bool TryValidateStatusDocument(
            string json,
            string expectedRunId,
            out ActiveBackupStatus status,
            out bool alreadyFinished,
            out string error)
        {
            status = null;
            alreadyFinished = false;
            error = null;
            try
            {
                if (string.IsNullOrWhiteSpace(json) || json.Length > MaximumStatusBytes)
                {
                    throw new InvalidDataException("The protected status document size is invalid.");
                }
                IDictionary<string, object> document =
                    new JavaScriptSerializer().DeserializeObject(json) as IDictionary<string, object>;
                if (document == null || ReadStrictInteger(document, "schema_version") != 1)
                {
                    throw new InvalidDataException("The protected status schema is invalid.");
                }
                string runId = ReadString(document, "run_id");
                string state = ReadString(document, "state");
                int wrapperPid = ReadStrictInteger(document, "wrapper_pid");
                if (wrapperPid <= 0)
                {
                    throw new InvalidDataException("The protected backup wrapper PID is invalid.");
                }
                string wrapperStartFileTime = ReadStrictUnsignedDecimalString(
                    document,
                    "wrapper_start_filetime");
                int launcherPid = ReadStrictInteger(document, "launcher_pid");
                string launcherStartFileTime = ReadStrictUnsignedDecimalString(
                    document,
                    "launcher_start_filetime");
                string cancelChannelId = ReadString(document, "cancel_channel_id");
                string cancelChannelFingerprint = ReadString(
                    document,
                    "cancel_channel_fingerprint");
                if (wrapperStartFileTime == "0" || launcherPid <= 0 ||
                    launcherStartFileTime == "0" || !IsLowerHexDigest(cancelChannelId))
                {
                    throw new InvalidDataException(
                        "The protected backup cancellation channel metadata is invalid.");
                }
                string cancelEventName = EngineProfile.Current.CancelEventName(cancelChannelId);
                if (!FixedEquals(
                    ComputeSha256Text(cancelEventName),
                    cancelChannelFingerprint))
                {
                    throw new InvalidDataException(
                        "The protected backup cancellation channel fingerprint is invalid.");
                }
                object finishedUtc;
                object exitCode;
                if (!document.TryGetValue("finished_utc", out finishedUtc) ||
                    !document.TryGetValue("exit_code", out exitCode))
                {
                    throw new InvalidDataException(
                        "The protected status is missing its completion fields.");
                }

                bool active = ActiveStates.Contains(state);
                bool terminal = TerminalStates.Contains(state);
                if (!active && !terminal)
                {
                    throw new InvalidDataException("The protected backup state is invalid.");
                }
                if (active && (finishedUtc != null || exitCode != null))
                {
                    throw new InvalidDataException(
                        "The protected active status contains a terminal result.");
                }
                if (terminal && !HasValidTerminalFields(finishedUtc, exitCode))
                {
                    throw new InvalidDataException(
                        "The protected terminal status has invalid completion fields.");
                }
                if (!FixedEquals(runId, expectedRunId) || terminal)
                {
                    alreadyFinished = true;
                    return true;
                }

                status = new ActiveBackupStatus(
                    runId,
                    wrapperPid,
                    wrapperStartFileTime,
                    launcherPid,
                    launcherStartFileTime,
                    cancelChannelId,
                    cancelChannelFingerprint,
                    state);
                return true;
            }
            catch (Exception exception)
            {
                error = "The protected backup status could not be validated: " +
                    TaskScheduleReader.SanitizeError(exception.Message);
                return false;
            }
        }

        private static bool ValidateManagerPath(
            string managerPath,
            string installRoot,
            out string error)
        {
            error = null;
            try
            {
                if (!Directory.Exists(installRoot) ||
                    (File.GetAttributes(installRoot) & FileAttributes.ReparsePoint) != 0 ||
                    !File.Exists(managerPath) ||
                    Directory.Exists(managerPath) ||
                    (File.GetAttributes(managerPath) & FileAttributes.ReparsePoint) != 0 ||
                    !TaskScheduleReader.SamePath(Path.GetDirectoryName(managerPath), installRoot))
                {
                    error = "The protected backup manager is missing or unsafe.";
                    return false;
                }
                return true;
            }
            catch (Exception exception)
            {
                error = "The protected backup manager could not be validated: " +
                    TaskScheduleReader.SanitizeError(exception.Message);
                return false;
            }
        }

        private static bool TryReadBoundResult(
            string resultPath,
            string requestNonce,
            string requestDigest,
            string userSid,
            string runId,
            int exitCode,
            out ValidatedCancellationResult result,
            out string error)
        {
            result = null;
            error = null;
            for (int attempt = 0; attempt < 20 && !File.Exists(resultPath); attempt++)
            {
                Thread.Sleep(25);
            }
            if (!File.Exists(resultPath))
            {
                error = "The protected backup manager returned exit code " +
                    exitCode.ToString(CultureInfo.InvariantCulture) +
                    " without a validated result.";
                return false;
            }

            string resultRoot = Path.GetDirectoryName(resultPath);
            string stateRoot = string.IsNullOrWhiteSpace(resultRoot)
                ? null
                : Path.GetDirectoryName(resultRoot);
            try
            {
                if (string.IsNullOrWhiteSpace(stateRoot) ||
                    string.IsNullOrWhiteSpace(resultRoot) ||
                    !Directory.Exists(stateRoot) ||
                    !Directory.Exists(resultRoot) ||
                    !string.Equals(
                        Path.GetFileName(stateRoot),
                        TaskScheduleReader.ProductDirectoryName,
                        StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(
                        Path.GetFileName(resultRoot),
                        ResultDirectoryName,
                        StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(
                        Path.GetFileName(resultPath),
                        requestNonce + ".json",
                        StringComparison.Ordinal) ||
                    (File.GetAttributes(stateRoot) & FileAttributes.ReparsePoint) != 0 ||
                    (File.GetAttributes(resultRoot) & FileAttributes.ReparsePoint) != 0 ||
                    (File.GetAttributes(resultPath) & FileAttributes.ReparsePoint) != 0)
                {
                    error = "The protected backup-control result path is unsafe.";
                    return false;
                }
                if (!HasProtectedResultAcl(stateRoot, userSid, true) ||
                    !HasProtectedResultAcl(resultRoot, userSid, true))
                {
                    error = "The protected backup-control result directory ACL is not trustworthy.";
                    return false;
                }

                using (FileStream stream = new FileStream(
                    resultPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    4096,
                    FileOptions.SequentialScan))
                {
                    if (!HasProtectedResultAcl(stream.GetAccessControl(), userSid))
                    {
                        error = "The protected backup-control result file ACL is not trustworthy.";
                        return false;
                    }
                    if (stream.Length <= 0 || stream.Length > MaximumResultBytes)
                    {
                        error = "The protected backup-control result has an invalid size.";
                        return false;
                    }
                    using (StreamReader reader = new StreamReader(
                        stream,
                        new UTF8Encoding(false, true),
                        true,
                        4096,
                        true))
                    {
                        return TryValidateResultDocument(
                            reader.ReadToEnd(),
                            requestNonce,
                            requestDigest,
                            userSid,
                            runId,
                            exitCode,
                            out result,
                            out error);
                    }
                }
            }
            catch (Exception exception)
            {
                error = "The protected backup-control result could not be validated: " +
                    TaskScheduleReader.SanitizeError(exception.Message);
                return false;
            }
        }

        internal static bool TryValidateResultDocument(
            string json,
            string requestNonce,
            string requestDigest,
            string userSid,
            string runId,
            int exitCode,
            out ValidatedCancellationResult result,
            out string error)
        {
            result = null;
            error = null;
            try
            {
                if (string.IsNullOrWhiteSpace(json) || json.Length > MaximumResultBytes)
                {
                    throw new InvalidDataException("The result document size is invalid.");
                }
                IDictionary<string, object> document =
                    new JavaScriptSerializer().DeserializeObject(json) as IDictionary<string, object>;
                if (document == null || ReadStrictInteger(document, "schema_version") != 1 ||
                    !FixedEquals(ReadString(document, "request_nonce"), requestNonce) ||
                    !FixedEquals(ReadString(document, "request_digest"), requestDigest) ||
                    !FixedEquals(ReadString(document, "request_user_sid"), userSid) ||
                    !FixedEquals(ReadString(document, "action"), "cancel") ||
                    !FixedEquals(ReadString(document, "run_id"), runId))
                {
                    throw new InvalidDataException(
                        "The protected backup-control result did not match this request.");
                }

                bool ok = ReadBoolean(document, "ok");
                bool requested = ReadBoolean(document, "requested");
                bool alreadyFinished = ReadBoolean(document, "already_finished");
                string managerError = ReadOptionalString(document, "error");
                if ((ok && exitCode != 0) || (!ok && exitCode == 0) ||
                    (ok && requested == alreadyFinished) ||
                    (!ok && (requested || alreadyFinished)) ||
                    (ok && managerError != null) ||
                    (!ok && string.IsNullOrWhiteSpace(managerError)))
                {
                    throw new InvalidDataException(
                        "The protected backup-control result disagreed with its process outcome.");
                }
                result = new ValidatedCancellationResult
                {
                    Ok = ok,
                    Requested = requested,
                    AlreadyFinished = alreadyFinished,
                    ErrorMessage = ok
                        ? null
                        : TaskScheduleReader.SanitizeError(managerError)
                };
                return true;
            }
            catch (Exception exception)
            {
                error = "The protected backup-control result could not be validated: " +
                    TaskScheduleReader.SanitizeError(exception.Message);
                return false;
            }
        }

        internal static string ComputeRequestDigest(
            string userSid,
            string runId,
            int wrapperPid,
            string taskFingerprint,
            string nonce)
        {
            string payload = RequestDomain + "\n" +
                userSid + "\n" +
                "cancel\n" +
                runId + "\n" +
                wrapperPid.ToString(CultureInfo.InvariantCulture) + "\n" +
                taskFingerprint + "\n" +
                nonce;
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] bytes = algorithm.ComputeHash(
                    new UTF8Encoding(false).GetBytes(payload));
                StringBuilder digest = new StringBuilder(bytes.Length * 2);
                foreach (byte item in bytes)
                {
                    digest.Append(item.ToString("x2", CultureInfo.InvariantCulture));
                }
                return digest.ToString();
            }
        }

        private static bool TryValidateRunId(string runId, out string error)
        {
            error = null;
            if (string.IsNullOrWhiteSpace(runId) || runId.Length > 128)
            {
                error = "The active backup run identifier is invalid.";
                return false;
            }
            foreach (char character in runId)
            {
                if (!(character >= 'a' && character <= 'z') &&
                    !(character >= 'A' && character <= 'Z') &&
                    !(character >= '0' && character <= '9') &&
                    character != '-' && character != '_' &&
                    character != '.' && character != ':')
                {
                    error = "The active backup run identifier is invalid.";
                    return false;
                }
            }
            return true;
        }

        private static bool HasProtectedResultAcl(
            string path,
            string userSid,
            bool directory)
        {
            try
            {
                FileSystemSecurity security = directory
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

        private static bool HasProtectedResultAcl(
            FileSystemSecurity security,
            string userSid)
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
                HashSet<string> allowed = new HashSet<string>(
                    required,
                    StringComparer.OrdinalIgnoreCase);
                allowed.Add("S-1-3-4");
                HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                FileSystemRights dangerous = FileSystemRights.WriteData |
                    FileSystemRights.CreateFiles |
                    FileSystemRights.AppendData |
                    FileSystemRights.CreateDirectories |
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

        private static int ReadStrictInteger(
            IDictionary<string, object> document,
            string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || !(value is int))
            {
                throw new InvalidDataException("Document field is missing or invalid: " + name);
            }
            return (int)value;
        }

        private static string ReadStrictUnsignedDecimalString(
            IDictionary<string, object> document,
            string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || !(value is string))
            {
                throw new InvalidDataException("Document field is missing or invalid: " + name);
            }
            string text = (string)value;
            if (text.Length == 0 || text.Length > 20 ||
                (text.Length > 1 && text[0] == '0'))
            {
                throw new InvalidDataException("Document field is not canonical unsigned decimal: " + name);
            }
            foreach (char character in text)
            {
                if (character < '0' || character > '9')
                {
                    throw new InvalidDataException(
                        "Document field is not canonical unsigned decimal: " + name);
                }
            }
            ulong parsed;
            if (!ulong.TryParse(
                text,
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out parsed))
            {
                throw new InvalidDataException("Document field exceeds UInt64: " + name);
            }
            return text;
        }

        private static bool HasValidTerminalFields(object finishedUtc, object exitCode)
        {
            string finishedText = finishedUtc as string;
            if (string.IsNullOrWhiteSpace(finishedText) || !(exitCode is int))
            {
                return false;
            }
            DateTimeOffset parsed;
            return DateTimeOffset.TryParse(
                finishedText,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out parsed);
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

        private static string ReadString(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || !(value is string))
            {
                throw new InvalidDataException("Document field is missing or invalid: " + name);
            }
            return (string)value;
        }

        private static string ReadOptionalString(
            IDictionary<string, object> document,
            string name)
        {
            object value;
            if (!document.TryGetValue(name, out value))
            {
                throw new InvalidDataException("Result field is missing: " + name);
            }
            if (value == null)
            {
                return null;
            }
            if (!(value is string))
            {
                throw new InvalidDataException("Result field is invalid: " + name);
            }
            return (string)value;
        }

        private static string CreateNonce()
        {
            byte[] bytes = new byte[32];
            using (RandomNumberGenerator generator = RandomNumberGenerator.Create())
            {
                generator.GetBytes(bytes);
            }
            StringBuilder value = new StringBuilder(bytes.Length * 2);
            foreach (byte item in bytes)
            {
                value.Append(item.ToString("x2", CultureInfo.InvariantCulture));
            }
            return value.ToString();
        }

        private static bool IsLowerHexDigest(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length != 64)
            {
                return false;
            }
            foreach (char character in value)
            {
                if ((character < '0' || character > '9') &&
                    (character < 'a' || character > 'f'))
                {
                    return false;
                }
            }
            return true;
        }

        private static string ComputeSha256Text(string value)
        {
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] bytes = algorithm.ComputeHash(
                    new UTF8Encoding(false).GetBytes(value));
                StringBuilder digest = new StringBuilder(bytes.Length * 2);
                foreach (byte item in bytes)
                {
                    digest.Append(item.ToString("x2", CultureInfo.InvariantCulture));
                }
                return digest.ToString();
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
            if (value.Length > 0 &&
                value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
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

        internal sealed class ActiveBackupStatus
        {
            public ActiveBackupStatus(
                string runId,
                int wrapperPid,
                string wrapperStartFileTime,
                int launcherPid,
                string launcherStartFileTime,
                string cancelChannelId,
                string cancelChannelFingerprint,
                string state)
            {
                RunId = runId;
                WrapperPid = wrapperPid;
                WrapperStartFileTime = wrapperStartFileTime;
                LauncherPid = launcherPid;
                LauncherStartFileTime = launcherStartFileTime;
                CancelChannelId = cancelChannelId;
                CancelChannelFingerprint = cancelChannelFingerprint;
                State = state;
            }

            public string RunId { get; private set; }
            public int WrapperPid { get; private set; }
            public string WrapperStartFileTime { get; private set; }
            public int LauncherPid { get; private set; }
            public string LauncherStartFileTime { get; private set; }
            public string CancelChannelId { get; private set; }
            public string CancelChannelFingerprint { get; private set; }
            public string State { get; private set; }
        }

        internal sealed class ValidatedCancellationResult
        {
            public bool Ok;
            public bool Requested;
            public bool AlreadyFinished;
            public string ErrorMessage;
        }
    }
}
