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
    internal sealed class ScheduleManagerResult
    {
        public bool Succeeded { get; private set; }
        public bool UserCancelled { get; private set; }
        public bool Changed { get; private set; }
        public int ExitCode { get; private set; }
        public string ErrorMessage { get; private set; }
        public TaskSchedule InstalledSchedule { get; private set; }

        public static ScheduleManagerResult Success(bool changed, TaskSchedule installedSchedule)
        {
            return new ScheduleManagerResult
            {
                Succeeded = true,
                Changed = changed,
                ExitCode = 0,
                InstalledSchedule = installedSchedule
            };
        }

        public static ScheduleManagerResult Cancelled()
        {
            return new ScheduleManagerResult { UserCancelled = true, ExitCode = 1223 };
        }

        public static ScheduleManagerResult Failure(string message, int exitCode)
        {
            return new ScheduleManagerResult
            {
                ErrorMessage = message,
                ExitCode = exitCode
            };
        }
    }

    internal static class ScheduleManagerLauncher
    {
        private static string ManagerFileName
        {
            get { return EngineProfile.Current.ScheduleManagerFileName; }
        }

        private const string ResultDirectoryName = "ScheduleManagerResults";
        private const int MaximumResultBytes = 64 * 1024;
        private const int ManagerTimeoutMilliseconds = 120000;

        public static ScheduleManagerResult Run(ScheduleChangeRequest desired)
        {
            return Run(desired, null);
        }

        public static ScheduleManagerResult Run(
            ScheduleChangeRequest desired,
            Action onElevatedProcessStarted)
        {
            string validationError;
            if (!ValidateRequest(desired, out validationError))
            {
                return ScheduleManagerResult.Failure(validationError, -1);
            }

            TaskScheduleReadResult baselineResult = TaskScheduleReader.ReadInstalled();
            if (!baselineResult.Succeeded || baselineResult.Schedule == null)
            {
                return ScheduleManagerResult.Failure(
                    baselineResult.ErrorMessage ?? "The installed backup schedule is unavailable.",
                    -1);
            }
            TaskSchedule baseline = baselineResult.Schedule;

            string userSid;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                userSid = identity.User == null ? null : identity.User.Value;
            }
            if (string.IsNullOrEmpty(userSid) ||
                !string.Equals(userSid, baseline.UserSid, StringComparison.OrdinalIgnoreCase))
            {
                return ScheduleManagerResult.Failure(
                    "The backup task does not belong to the current Windows user.",
                    -1);
            }

            string installRoot = EngineProfile.Current.InstallRoot();
            string managerPath = Path.Combine(installRoot, ManagerFileName);
            string pathError;
            if (!ValidateManagerPath(managerPath, installRoot, out pathError))
            {
                return ScheduleManagerResult.Failure(pathError, -1);
            }

            string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string powerShell = Path.Combine(
                systemDirectory,
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            if (!File.Exists(powerShell))
            {
                return ScheduleManagerResult.Failure(
                    "Windows PowerShell is unavailable in System32.",
                    -1);
            }

            string requestNonce = ElevatedRequestSecurity.CreateNonce();
            string requestDigest = TaskScheduleCanonicalizer.ComputeRequestDigest(
                userSid,
                baseline.SemanticFingerprint,
                desired,
                requestNonce);
            string resultRoot = EngineProfile.Current.StateResultDirectory(ResultDirectoryName);
            string resultPath = Path.Combine(resultRoot, requestNonce + ".json");
            if (File.Exists(resultPath) || Directory.Exists(resultPath))
            {
                return ScheduleManagerResult.Failure(
                    "A protected schedule result already uses this request nonce.",
                    -1);
            }

            List<string> arguments = new List<string>
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
                "-Cadence",
                desired.CadenceArgument,
                "-Time",
                desired.TimeArgument
            };
            // Windows PowerShell's -File binder can discard an empty native
            // argv value. Daily uses the script's safe empty default instead.
            if (desired.Cadence == BackupScheduleCadence.SelectedDays)
            {
                arguments.Add("-Days");
                arguments.Add(desired.DaysArgument);
            }
            arguments.AddRange(new[]
            {
                "-StartWhenAvailable",
                BooleanArgument(desired.StartWhenAvailable),
                "-WakeToRun",
                BooleanArgument(desired.WakeToRun),
                "-AllowStartOnBatteries",
                BooleanArgument(desired.AllowStartOnBatteries),
                "-StopIfGoingOnBatteries",
                BooleanArgument(desired.StopIfGoingOnBatteries),
                "-Enabled",
                BooleanArgument(desired.Enabled),
                "-ExpectedCurrentFingerprint",
                baseline.SemanticFingerprint,
                "-ExpectedUserSid",
                userSid,
                "-ResultPath",
                resultPath,
                "-RequestNonce",
                requestNonce
            });

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powerShell;
            startInfo.Arguments = ElevatedRequestSecurity.BuildArgumentString(arguments);
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
                        return ScheduleManagerResult.Failure(
                            "Windows did not start the protected schedule manager.",
                            -1);
                    }
                    if (onElevatedProcessStarted != null)
                    {
                        try { onElevatedProcessStarted(); }
                        catch { }
                    }
                    if (!process.WaitForExit(ManagerTimeoutMilliseconds))
                    {
                        try { process.Kill(); }
                        catch { }
                        return ScheduleManagerResult.Failure(
                            "The protected schedule manager did not finish in time.",
                            -1);
                    }
                    process.WaitForExit();
                    exitCode = process.ExitCode;
                }

                ValidatedScheduleResult validated;
                string resultError;
                if (!TryReadBoundResult(
                    resultPath,
                    requestNonce,
                    requestDigest,
                    userSid,
                    baseline.SemanticFingerprint,
                    desired,
                    exitCode,
                    out validated,
                    out resultError))
                {
                    return ScheduleManagerResult.Failure(resultError, exitCode);
                }
                if (!validated.Ok)
                {
                    return ScheduleManagerResult.Failure(validated.ErrorMessage, exitCode);
                }

                // Treat the protected process result only as a claim. A fresh,
                // independent Task Scheduler read must prove the exact requested
                // policy before the UI may report success.
                TaskScheduleReadResult installedResult = TaskScheduleReader.ReadInstalled();
                if (!installedResult.Succeeded || installedResult.Schedule == null)
                {
                    return ScheduleManagerResult.Failure(
                        "The updated schedule could not be independently verified: " +
                            (installedResult.ErrorMessage ?? "unknown verification error"),
                        exitCode);
                }
                TaskSchedule installed = installedResult.Schedule;
                if (!installed.Matches(desired) || !installed.AllowDemandStart ||
                    !ElevatedRequestSecurity.FixedEquals(installed.SemanticFingerprint, validated.InstalledFingerprint))
                {
                    return ScheduleManagerResult.Failure(
                        "The installed schedule does not exactly match the approved settings.",
                        exitCode);
                }
                return ScheduleManagerResult.Success(validated.Changed, installed);
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode == 1223)
                {
                    return ScheduleManagerResult.Cancelled();
                }
                return ScheduleManagerResult.Failure(
                    TaskScheduleReader.SanitizeError(error.Message),
                    error.NativeErrorCode);
            }
            catch (Exception error)
            {
                return ScheduleManagerResult.Failure(
                    TaskScheduleReader.SanitizeError(error.Message),
                    -1);
            }
        }

        private static bool ValidateRequest(
            ScheduleChangeRequest desired,
            out string error)
        {
            error = null;
            if (desired == null)
            {
                error = "Choose the schedule settings to apply.";
                return false;
            }
            ScheduleChangeRequest normalized;
            if (!ScheduleChangeRequest.TryCreate(
                desired.Cadence,
                desired.TimeOfDay,
                desired.Days,
                desired.Enabled,
                desired.StartWhenAvailable,
                desired.WakeToRun,
                desired.AllowStartOnBatteries,
                desired.StopIfGoingOnBatteries,
                out normalized,
                out error))
            {
                return false;
            }
            if (!string.Equals(
                normalized.CanonicalPolicy,
                desired.CanonicalPolicy,
                StringComparison.Ordinal))
            {
                error = "The requested schedule is not in canonical form.";
                return false;
            }
            return true;
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
                    (File.GetAttributes(managerPath) & FileAttributes.ReparsePoint) != 0 ||
                    !TaskScheduleReader.SamePath(
                        Path.GetDirectoryName(managerPath),
                        installRoot))
                {
                    error = "The protected schedule manager is missing or unsafe.";
                    return false;
                }
                return true;
            }
            catch (Exception exception)
            {
                error = "The protected schedule manager could not be validated: " +
                    TaskScheduleReader.SanitizeError(exception.Message);
                return false;
            }
        }

        private static bool TryReadBoundResult(
            string resultPath,
            string requestNonce,
            string requestDigest,
            string userSid,
            string expectedFingerprint,
            ScheduleChangeRequest desired,
            int exitCode,
            out ValidatedScheduleResult result,
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
                error = "The protected schedule manager returned exit code " +
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
                    error = "The protected schedule result path is unsafe.";
                    return false;
                }
                if (!ElevatedRequestSecurity.HasProtectedResultAcl(stateRoot, userSid, true) ||
                    !ElevatedRequestSecurity.HasProtectedResultAcl(resultRoot, userSid, true))
                {
                    error = "The protected schedule result directory ACL is not trustworthy.";
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
                    if (!ElevatedRequestSecurity.HasProtectedResultAcl(stream.GetAccessControl(), userSid))
                    {
                        error = "The protected schedule result file ACL is not trustworthy.";
                        return false;
                    }
                    if (stream.Length <= 0 || stream.Length > MaximumResultBytes)
                    {
                        error = "The protected schedule result has an invalid size.";
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
                            expectedFingerprint,
                            desired,
                            exitCode,
                            out result,
                            out error);
                    }
                }
            }
            catch (Exception exception)
            {
                error = "The protected schedule result could not be validated: " +
                    TaskScheduleReader.SanitizeError(exception.Message);
                return false;
            }
        }

        internal static bool TryValidateResultDocument(
            string json,
            string requestNonce,
            string requestDigest,
            string userSid,
            string expectedFingerprint,
            ScheduleChangeRequest desired,
            int exitCode,
            out ValidatedScheduleResult result,
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
                if (document == null || ReadInteger(document, "schema_version") != 1 ||
                    !ElevatedRequestSecurity.FixedEquals(ReadString(document, "request_nonce"), requestNonce) ||
                    !ElevatedRequestSecurity.FixedEquals(ReadString(document, "request_digest"), requestDigest) ||
                    !ElevatedRequestSecurity.FixedEquals(ReadString(document, "request_user_sid"), userSid) ||
                    !ElevatedRequestSecurity.FixedEquals(ReadString(document, "action"), "apply") ||
                    !ElevatedRequestSecurity.FixedEquals(
                        ReadString(document, "expected_current_fingerprint"),
                        expectedFingerprint))
                {
                    throw new InvalidDataException(
                        "The protected schedule result did not match this request.");
                }

                bool ok = ReadBoolean(document, "ok");
                bool changed = ReadBoolean(document, "changed");
                bool rollbackPerformed = ReadBoolean(document, "rollback_performed");
                bool rollbackVerified = ReadBoolean(document, "rollback_verified");
                bool backupStarted = ReadBoolean(document, "backup_started");
                string installedFingerprint = ReadOptionalString(
                    document,
                    "installed_fingerprint");
                string managerError = ReadOptionalString(document, "error");
                object scheduleValue;
                if (!document.TryGetValue("schedule", out scheduleValue))
                {
                    throw new InvalidDataException("Result field is missing: schedule");
                }

                if (backupStarted || (ok && exitCode != 0) || (!ok && exitCode == 0) ||
                    (rollbackPerformed && !rollbackVerified) ||
                    (ok && (!IsLowerHexDigest(installedFingerprint) ||
                        !ResultScheduleMatches(scheduleValue, desired))) ||
                    (!ok && scheduleValue != null) ||
                    (!string.IsNullOrEmpty(installedFingerprint) &&
                        !IsLowerHexDigest(installedFingerprint)))
                {
                    throw new InvalidDataException(
                        "The protected schedule result disagreed with its verified outcome.");
                }
                result = new ValidatedScheduleResult
                {
                    Ok = ok,
                    Changed = changed,
                    RollbackPerformed = rollbackPerformed,
                    RollbackVerified = rollbackVerified,
                    InstalledFingerprint = installedFingerprint,
                    ErrorMessage = ok
                        ? null
                        : TaskScheduleReader.SanitizeError(managerError)
                };
                return true;
            }
            catch (Exception exception)
            {
                error = "The protected schedule result could not be validated: " +
                    TaskScheduleReader.SanitizeError(exception.Message);
                return false;
            }
        }

        private static string BooleanArgument(bool value)
        {
            return value ? "1" : "0";
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

        private static bool ResultScheduleMatches(
            object value,
            ScheduleChangeRequest desired)
        {
            IDictionary<string, object> schedule = value as IDictionary<string, object>;
            if (schedule == null || desired == null || schedule.Count != 8)
            {
                return false;
            }
            try
            {
                object daysValue;
                if (!schedule.TryGetValue("days", out daysValue))
                {
                    return false;
                }
                System.Collections.IEnumerable enumerable =
                    daysValue as System.Collections.IEnumerable;
                if (enumerable == null || daysValue is string)
                {
                    return false;
                }
                List<string> days = new List<string>();
                foreach (object item in enumerable)
                {
                    if (!(item is string))
                    {
                        return false;
                    }
                    days.Add((string)item);
                }
                return ElevatedRequestSecurity.FixedEquals(ReadString(schedule, "cadence"), desired.CadenceArgument) &&
                    ElevatedRequestSecurity.FixedEquals(ReadString(schedule, "time"), desired.TimeArgument) &&
                    ElevatedRequestSecurity.FixedEquals(string.Join(",", days.ToArray()), desired.DaysArgument) &&
                    ReadBoolean(schedule, "enabled") == desired.Enabled &&
                    ReadBoolean(schedule, "start_when_available") == desired.StartWhenAvailable &&
                    ReadBoolean(schedule, "wake_to_run") == desired.WakeToRun &&
                    ReadBoolean(schedule, "allow_start_on_batteries") ==
                        desired.AllowStartOnBatteries &&
                    ReadBoolean(schedule, "stop_if_going_on_batteries") ==
                        desired.StopIfGoingOnBatteries;
            }
            catch
            {
                return false;
            }
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

        private static string ReadString(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || !(value is string))
            {
                throw new InvalidDataException("Result field is missing or invalid: " + name);
            }
            return (string)value;
        }

        private static string ReadOptionalString(
            IDictionary<string, object> document,
            string name)
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

        internal sealed class ValidatedScheduleResult
        {
            public bool Ok;
            public bool Changed;
            public bool RollbackPerformed;
            public bool RollbackVerified;
            public string InstalledFingerprint;
            public string ErrorMessage;
        }
    }
}
