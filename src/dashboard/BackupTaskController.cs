using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Principal;

namespace ResticBackuper.Dashboard
{
    internal sealed class BackupTaskRequestResult
    {
        public bool Succeeded { get; private set; }
        public bool UserCancelled { get; private set; }
        public int ExitCode { get; private set; }
        public string ErrorMessage { get; private set; }

        public static BackupTaskRequestResult Success()
        {
            return new BackupTaskRequestResult { Succeeded = true, ExitCode = 0 };
        }

        public static BackupTaskRequestResult Cancelled()
        {
            return new BackupTaskRequestResult { UserCancelled = true, ExitCode = 1223 };
        }

        public static BackupTaskRequestResult Failure(string message, int exitCode)
        {
            return new BackupTaskRequestResult
            {
                ErrorMessage = message,
                ExitCode = exitCode
            };
        }
    }

    internal static class BackupTaskController
    {
        private static string TaskName
        {
            get { return EngineProfile.Current.BackupTaskName; }
        }

        public static BackupTaskRequestResult RequestStart()
        {
            string validationError;
            if (!TryValidateInstalledTaskForStart(out validationError))
            {
                return BackupTaskRequestResult.Failure(validationError, -1);
            }

            string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string schtasks = Path.Combine(systemDirectory, "schtasks.exe");
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = schtasks;
            startInfo.Arguments = "/Run /TN " + QuoteArgument(TaskName);
            startInfo.WorkingDirectory = systemDirectory;
            startInfo.UseShellExecute = true;
            startInfo.Verb = "runas";
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            startInfo.ErrorDialog = false;

            try
            {
                using (Process process = Process.Start(startInfo))
                {
                    if (process == null)
                    {
                        return BackupTaskRequestResult.Failure(
                            "Windows did not start the protected backup request.",
                            -1);
                    }
                    process.WaitForExit();
                    return process.ExitCode == 0
                        ? BackupTaskRequestResult.Success()
                        : BackupTaskRequestResult.Failure(
                            "Windows Task Scheduler did not accept the backup request (exit code " +
                                process.ExitCode.ToString(CultureInfo.InvariantCulture) + ").",
                            process.ExitCode);
                }
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode == 1223)
                {
                    return BackupTaskRequestResult.Cancelled();
                }
                return BackupTaskRequestResult.Failure(error.Message, error.NativeErrorCode);
            }
            catch (Exception error)
            {
                return BackupTaskRequestResult.Failure(error.Message, -1);
            }
        }

        private static bool TryValidateInstalledTaskForStart(out string error)
        {
            TaskScheduleReadResult result = TaskScheduleReader.ReadInstalled();
            if (!result.Succeeded || result.Schedule == null)
            {
                error = result.ErrorMessage ?? "The installed backup task is unavailable.";
                return false;
            }
            if (!result.Schedule.Enabled)
            {
                error = "The automatic backup schedule is paused. Resume it before starting a backup.";
                return false;
            }
            if (!result.Schedule.AllowDemandStart)
            {
                error = "The installed backup task does not allow a protected manual start.";
                return false;
            }
            error = null;
            return true;
        }

        // Pure parser seam retained for fixture tests. It accepts either of the
        // editor's supported calendar policies and never queries or runs a task.
        internal static bool TryValidateTaskXml(
            string xml,
            string expectedLauncher,
            string installRoot,
            out string error)
        {
            string userSid;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                userSid = identity.User == null ? null : identity.User.Value;
            }
            TaskSchedule schedule;
            if (!TaskScheduleReader.TryParseTaskXml(
                xml,
                expectedLauncher,
                installRoot,
                userSid,
                TaskScheduleRuntimeInfo.Unknown,
                out schedule,
                out error))
            {
                return false;
            }
            if (!schedule.Enabled || !schedule.AllowDemandStart)
            {
                error = "The installed backup task is paused or does not allow manual starts.";
                return false;
            }
            return true;
        }

        private static string QuoteArgument(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}
