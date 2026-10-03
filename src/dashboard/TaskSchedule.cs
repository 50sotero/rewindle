using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Xml;

namespace ResticBackuper.Dashboard
{
    internal enum BackupScheduleCadence
    {
        Daily,
        SelectedDays
    }

    internal enum BackupTaskState
    {
        Unknown = 0,
        Disabled = 1,
        Queued = 2,
        Ready = 3,
        Running = 4
    }

    internal sealed class ScheduleChangeRequest
    {
        private ScheduleChangeRequest()
        {
        }

        public BackupScheduleCadence Cadence { get; private set; }
        public TimeSpan TimeOfDay { get; private set; }
        public DayOfWeek[] Days { get; private set; }
        public bool Enabled { get; private set; }
        public bool StartWhenAvailable { get; private set; }
        public bool WakeToRun { get; private set; }
        public bool AllowStartOnBatteries { get; private set; }
        public bool StopIfGoingOnBatteries { get; private set; }

        public string CadenceArgument
        {
            get { return Cadence == BackupScheduleCadence.Daily ? "Daily" : "SelectedDays"; }
        }

        public string TimeArgument
        {
            get { return TaskScheduleCanonicalizer.FormatTime(TimeOfDay); }
        }

        public string DaysArgument
        {
            get { return TaskScheduleCanonicalizer.FormatDays(Days); }
        }

        public string Summary
        {
            get { return TaskScheduleCanonicalizer.CreateSummary(Cadence, TimeOfDay, Days, Enabled); }
        }

        public string CanonicalPolicy
        {
            get
            {
                return TaskScheduleCanonicalizer.CreatePolicyPayload(
                    Cadence,
                    TimeOfDay,
                    Days,
                    Enabled,
                    StartWhenAvailable,
                    WakeToRun,
                    AllowStartOnBatteries,
                    StopIfGoingOnBatteries);
            }
        }

        public static bool TryCreate(
            BackupScheduleCadence cadence,
            TimeSpan timeOfDay,
            IEnumerable<DayOfWeek> days,
            bool enabled,
            bool startWhenAvailable,
            bool wakeToRun,
            bool allowStartOnBatteries,
            bool stopIfGoingOnBatteries,
            out ScheduleChangeRequest request,
            out string error)
        {
            request = null;
            error = null;
            DayOfWeek[] normalizedDays;
            if (!TaskScheduleCanonicalizer.TryNormalizePolicy(
                cadence,
                timeOfDay,
                days,
                out normalizedDays,
                out error))
            {
                return false;
            }

            request = new ScheduleChangeRequest
            {
                Cadence = cadence,
                TimeOfDay = new TimeSpan(timeOfDay.Hours, timeOfDay.Minutes, 0),
                Days = normalizedDays,
                Enabled = enabled,
                StartWhenAvailable = startWhenAvailable,
                WakeToRun = wakeToRun,
                AllowStartOnBatteries = allowStartOnBatteries,
                StopIfGoingOnBatteries = stopIfGoingOnBatteries
            };
            return true;
        }

        public static bool TryCreate(
            string cadence,
            string time,
            IEnumerable<string> dayTokens,
            bool enabled,
            bool startWhenAvailable,
            bool wakeToRun,
            bool allowStartOnBatteries,
            bool stopIfGoingOnBatteries,
            out ScheduleChangeRequest request,
            out string error)
        {
            request = null;
            error = null;
            BackupScheduleCadence parsedCadence;
            if (string.Equals(cadence, "Daily", StringComparison.OrdinalIgnoreCase))
            {
                parsedCadence = BackupScheduleCadence.Daily;
            }
            else if (string.Equals(cadence, "SelectedDays", StringComparison.OrdinalIgnoreCase))
            {
                parsedCadence = BackupScheduleCadence.SelectedDays;
            }
            else
            {
                error = "Choose Daily or Selected weekdays.";
                return false;
            }

            TimeSpan parsedTime;
            if (!TimeSpan.TryParseExact(
                time,
                @"hh\:mm",
                CultureInfo.InvariantCulture,
                out parsedTime))
            {
                error = "Enter the backup time as HH:mm.";
                return false;
            }

            List<DayOfWeek> parsedDays = new List<DayOfWeek>();
            if (dayTokens != null)
            {
                foreach (string token in dayTokens)
                {
                    DayOfWeek day;
                    if (!TaskScheduleCanonicalizer.TryParseDayToken(token, out day))
                    {
                        error = "A selected weekday is invalid.";
                        return false;
                    }
                    parsedDays.Add(day);
                }
            }
            return TryCreate(
                parsedCadence,
                parsedTime,
                parsedDays,
                enabled,
                startWhenAvailable,
                wakeToRun,
                allowStartOnBatteries,
                stopIfGoingOnBatteries,
                out request,
                out error);
        }

        public static ScheduleChangeRequest FromInstalled(TaskSchedule schedule)
        {
            if (schedule == null)
            {
                throw new ArgumentNullException("schedule");
            }
            ScheduleChangeRequest request;
            string error;
            if (!TryCreate(
                schedule.Cadence,
                schedule.TimeOfDay,
                schedule.Days,
                schedule.Enabled,
                schedule.StartWhenAvailable,
                schedule.WakeToRun,
                schedule.AllowStartOnBatteries,
                schedule.StopIfGoingOnBatteries,
                out request,
                out error))
            {
                throw new InvalidOperationException(error);
            }
            return request;
        }
    }

    // The words for each schedule option, shared by the editor's own check boxes, the review of a change and the summary under Settings
    // (the Run conditions), so one option reads the same wherever it is shown. A phrase for the option being off is for the review, which
    // names both states; the summary lists only what is on (and the power choices, which are always one or the other).
    internal static class ScheduleOptionText
    {
        public const string RunMissed = "Run when the PC is next available";
        public const string WaitForNextRun = "Wait for the next scheduled time";
        public const string Wake = "Wake this PC from sleep";
        public const string NoWake = "Do not wake this PC";
        public const string StartOnBattery = "May start on battery";
        public const string WaitForAc = "Wait for AC power";
        public const string FinishIfUnplugged = "Let a running backup finish if the PC is unplugged";
        public const string StopIfUnplugged = "Windows may stop a running backup if the PC is unplugged";
    }

    internal sealed class TaskSchedule
    {
        internal TaskSchedule(
            BackupScheduleCadence cadence,
            TimeSpan timeOfDay,
            DayOfWeek[] days,
            bool enabled,
            bool startWhenAvailable,
            bool wakeToRun,
            bool allowStartOnBatteries,
            bool stopIfGoingOnBatteries,
            bool allowDemandStart,
            string taskName,
            string userSid,
            string command,
            string workingDirectory,
            BackupTaskState state,
            DateTime? nextRunTime,
            string semanticFingerprint)
        {
            Cadence = cadence;
            TimeOfDay = timeOfDay;
            Days = (DayOfWeek[])days.Clone();
            Enabled = enabled;
            StartWhenAvailable = startWhenAvailable;
            WakeToRun = wakeToRun;
            AllowStartOnBatteries = allowStartOnBatteries;
            StopIfGoingOnBatteries = stopIfGoingOnBatteries;
            AllowDemandStart = allowDemandStart;
            TaskName = taskName;
            UserSid = userSid;
            Command = command;
            WorkingDirectory = workingDirectory;
            State = state;
            NextRunTime = nextRunTime;
            SemanticFingerprint = semanticFingerprint;
        }

        public BackupScheduleCadence Cadence { get; private set; }
        public TimeSpan TimeOfDay { get; private set; }
        public DayOfWeek[] Days { get; private set; }
        public bool Enabled { get; private set; }
        public bool StartWhenAvailable { get; private set; }
        public bool WakeToRun { get; private set; }
        public bool AllowStartOnBatteries { get; private set; }
        public bool StopIfGoingOnBatteries { get; private set; }
        public bool AllowDemandStart { get; private set; }
        public string TaskName { get; private set; }
        public string UserSid { get; private set; }
        public string Command { get; private set; }
        public string WorkingDirectory { get; private set; }
        public BackupTaskState State { get; private set; }
        public DateTime? NextRunTime { get; private set; }
        public string SemanticFingerprint { get; private set; }

        public string Summary
        {
            get { return TaskScheduleCanonicalizer.CreateSummary(Cadence, TimeOfDay, Days, Enabled); }
        }

        public string NextRunDisplay
        {
            get
            {
                if (!Enabled || State == BackupTaskState.Disabled)
                {
                    return "Paused";
                }
                if (!NextRunTime.HasValue || NextRunTime.Value.Year < 2000)
                {
                    return "Not scheduled";
                }
                return NextRunTime.Value.ToString("ddd, d MMM HH:mm", CultureInfo.CurrentCulture);
            }
        }

        public string SettingsSummary
        {
            get
            {
                List<string> settings = new List<string>();
                if (StartWhenAvailable)
                {
                    settings.Add(ScheduleOptionText.RunMissed);
                }
                if (WakeToRun)
                {
                    settings.Add(ScheduleOptionText.Wake);
                }
                settings.Add(AllowStartOnBatteries ? ScheduleOptionText.StartOnBattery : ScheduleOptionText.WaitForAc);
                if (AllowStartOnBatteries)
                {
                    settings.Add(StopIfGoingOnBatteries
                        ? ScheduleOptionText.StopIfUnplugged
                        : ScheduleOptionText.FinishIfUnplugged);
                }
                return string.Join(" • ", settings.ToArray());
            }
        }

        public bool Matches(ScheduleChangeRequest desired)
        {
            return desired != null &&
                Cadence == desired.Cadence &&
                TimeOfDay == desired.TimeOfDay &&
                TaskScheduleCanonicalizer.SameDays(Days, desired.Days) &&
                Enabled == desired.Enabled &&
                StartWhenAvailable == desired.StartWhenAvailable &&
                WakeToRun == desired.WakeToRun &&
                AllowStartOnBatteries == desired.AllowStartOnBatteries &&
                StopIfGoingOnBatteries == desired.StopIfGoingOnBatteries;
        }
    }

    internal sealed class TaskScheduleReadResult
    {
        public bool Succeeded { get; private set; }
        public TaskSchedule Schedule { get; private set; }
        public string ErrorMessage { get; private set; }

        public static TaskScheduleReadResult Success(TaskSchedule schedule)
        {
            return new TaskScheduleReadResult { Succeeded = true, Schedule = schedule };
        }

        public static TaskScheduleReadResult Failure(string message)
        {
            return new TaskScheduleReadResult { ErrorMessage = message };
        }
    }

    internal sealed class TaskScheduleRuntimeInfo
    {
        public TaskScheduleRuntimeInfo(BackupTaskState state, DateTime? nextRunTime)
        {
            State = state;
            NextRunTime = nextRunTime;
        }

        public BackupTaskState State { get; private set; }
        public DateTime? NextRunTime { get; private set; }

        public static TaskScheduleRuntimeInfo Unknown
        {
            get { return new TaskScheduleRuntimeInfo(BackupTaskState.Unknown, null); }
        }
    }

    internal static class TaskScheduleReader
    {
        // The engine's identities (task, install folder, launcher) come from the active engine profile.
        internal static string TaskName
        {
            get { return EngineProfile.Current.BackupTaskName; }
        }

        internal static string ProductDirectoryName
        {
            get { return EngineProfile.Current.ProductDirectoryName; }
        }

        internal static string LauncherFileName
        {
            get { return EngineProfile.Current.LauncherFileName; }
        }

        internal const string TaskNamespace = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        internal const int MaximumTaskXmlCharacters = 256 * 1024;
        private const int MaximumErrorCharacters = 32 * 1024;
        private const int QueryTimeoutMilliseconds = 15000;

        public static TaskScheduleReadResult ReadInstalled()
        {
            try
            {
                string userSid = GetCurrentUserSid();
                if (string.IsNullOrEmpty(userSid))
                {
                    return TaskScheduleReadResult.Failure(
                        "The current Windows user SID could not be determined.");
                }
                string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
                string schtasks = Path.Combine(systemDirectory, "schtasks.exe");
                string installRoot = EngineProfile.Current.InstallRoot();
                string expectedLauncher = Path.Combine(installRoot, LauncherFileName);

                string pathError;
                if (!ValidateProtectedInputs(schtasks, expectedLauncher, installRoot, out pathError))
                {
                    return TaskScheduleReadResult.Failure(pathError);
                }

                string xml;
                string queryError;
                if (!TryQueryTaskXml(schtasks, systemDirectory, out xml, out queryError))
                {
                    return TaskScheduleReadResult.Failure(queryError);
                }

                TaskScheduleRuntimeInfo runtime;
                string runtimeError;
                if (!TryReadRuntimeInfo(out runtime, out runtimeError))
                {
                    return TaskScheduleReadResult.Failure(runtimeError);
                }

                TaskSchedule schedule;
                string parseError;
                if (!TryParseTaskXml(
                    xml,
                    expectedLauncher,
                    installRoot,
                    userSid,
                    runtime,
                    out schedule,
                    out parseError))
                {
                    return TaskScheduleReadResult.Failure(parseError);
                }
                return TaskScheduleReadResult.Success(schedule);
            }
            catch (Exception error)
            {
                return TaskScheduleReadResult.Failure(
                    "The installed backup schedule could not be read: " + SanitizeError(error.Message));
            }
        }

        internal static bool TryParseTaskXml(
            string xml,
            string expectedLauncher,
            string installRoot,
            string expectedUserSid,
            TaskScheduleRuntimeInfo runtime,
            out TaskSchedule schedule,
            out string error)
        {
            schedule = null;
            error = null;
            if (string.IsNullOrWhiteSpace(xml) || xml.Length > MaximumTaskXmlCharacters)
            {
                error = "The installed backup task returned invalid metadata.";
                return false;
            }
            if (string.IsNullOrWhiteSpace(expectedUserSid))
            {
                error = "The expected backup-task user is unavailable.";
                return false;
            }
            if (runtime == null)
            {
                runtime = TaskScheduleRuntimeInfo.Unknown;
            }

            try
            {
                XmlDocument document = new XmlDocument();
                document.XmlResolver = null;
                document.PreserveWhitespace = false;
                document.LoadXml(xml);
                XmlNamespaceManager namespaces = new XmlNamespaceManager(document.NameTable);
                namespaces.AddNamespace("t", TaskNamespace);

                XmlNode root = document.DocumentElement;
                if (root == null || root.LocalName != "Task" || root.NamespaceURI != TaskNamespace)
                {
                    throw new InvalidDataException("The task document root is invalid.");
                }

                XmlNodeList actions = document.SelectNodes("/t:Task/t:Actions/*", namespaces);
                XmlNodeList principals = document.SelectNodes("/t:Task/t:Principals/t:Principal", namespaces);
                XmlNode actionsNode = ReadSingleNode(document, namespaces, "/t:Task/t:Actions");
                if (actions == null || actions.Count != 1 || actions[0].LocalName != "Exec" ||
                    principals == null || principals.Count != 1)
                {
                    throw new InvalidDataException(
                        "The task must have exactly one protected action and principal.");
                }
                EnsureOnlyChildren(
                    actions[0],
                    new[] { "Command", "Arguments", "WorkingDirectory" });
                EnsureOnlyChildren(
                    principals[0],
                    new[] { "UserId", "LogonType", "RunLevel" });

                string taskUri = ReadRequiredValue(
                    document,
                    namespaces,
                    "/t:Task/t:RegistrationInfo/t:URI");
                string command = ReadRequiredValue(
                    document,
                    namespaces,
                    "/t:Task/t:Actions/t:Exec/t:Command");
                string arguments = ReadOptionalValue(
                    document,
                    namespaces,
                    "/t:Task/t:Actions/t:Exec/t:Arguments");
                string workingDirectory = ReadRequiredValue(
                    document,
                    namespaces,
                    "/t:Task/t:Actions/t:Exec/t:WorkingDirectory");
                string userId = ReadRequiredValue(
                    document,
                    namespaces,
                    "/t:Task/t:Principals/t:Principal/t:UserId");
                string logonType = ReadRequiredValue(
                    document,
                    namespaces,
                    "/t:Task/t:Principals/t:Principal/t:LogonType");
                string runLevel = ReadRequiredValue(
                    document,
                    namespaces,
                    "/t:Task/t:Principals/t:Principal/t:RunLevel");
                string principalId = ReadAttribute(principals[0], "id");
                string actionsContext = ReadAttribute(actionsNode, "Context");

                string normalizedUserSid;
                if (!TryResolveSid(userId, out normalizedUserSid) ||
                    !string.Equals(normalizedUserSid, expectedUserSid, StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(taskUri, "\\" + TaskName, StringComparison.OrdinalIgnoreCase) ||
                    !SamePath(command, expectedLauncher) ||
                    !string.IsNullOrWhiteSpace(arguments) ||
                    !SamePath(workingDirectory, installRoot) ||
                    string.IsNullOrWhiteSpace(principalId) ||
                    !string.Equals(actionsContext, principalId, StringComparison.Ordinal) ||
                    !string.Equals(logonType, "InteractiveToken", StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(runLevel, "HighestAvailable", StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        "The backup task identity, action, or principal does not match this installation.");
                }

                string multipleInstances = ReadOptionalValue(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:MultipleInstancesPolicy");
                if (multipleInstances.Length == 0)
                {
                    multipleInstances = "IgnoreNew";
                }
                bool enabled = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:Enabled",
                    true);
                bool allowDemandStart = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:AllowStartOnDemand",
                    true);
                bool startWhenAvailable = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:StartWhenAvailable",
                    false);
                bool wakeToRun = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:WakeToRun",
                    false);
                bool disallowStartOnBatteries = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:DisallowStartIfOnBatteries",
                    true);
                bool stopIfGoingOnBatteries = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:StopIfGoingOnBatteries",
                    true);
                bool allowHardTerminate = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:AllowHardTerminate",
                    true);
                bool runOnlyIfNetworkAvailable = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:RunOnlyIfNetworkAvailable",
                    false);
                bool hidden = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:Hidden",
                    false);
                bool runOnlyIfIdle = ReadBoolean(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:RunOnlyIfIdle",
                    false);
                string executionTimeLimit = ReadOptionalValue(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:ExecutionTimeLimit");
                string priority = ReadOptionalValue(
                    document,
                    namespaces,
                    "/t:Task/t:Settings/t:Priority");
                if (priority.Length == 0)
                {
                    priority = "7";
                }

                if (!string.Equals(multipleInstances, "IgnoreNew", StringComparison.OrdinalIgnoreCase) ||
                    !allowHardTerminate || runOnlyIfNetworkAvailable ||
                    !allowDemandStart || hidden || runOnlyIfIdle ||
                    executionTimeLimit != "PT0S" ||
                    priority != "7")
                {
                    throw new InvalidDataException(
                        "The backup task execution policy does not match this installation.");
                }

                BackupScheduleCadence cadence;
                TimeSpan timeOfDay;
                DayOfWeek[] days;
                ParseSingleCalendarTrigger(
                    document,
                    namespaces,
                    out cadence,
                    out timeOfDay,
                    out days);

                schedule = new TaskSchedule(
                    cadence,
                    timeOfDay,
                    days,
                    enabled,
                    startWhenAvailable,
                    wakeToRun,
                    !disallowStartOnBatteries,
                    stopIfGoingOnBatteries,
                    allowDemandStart,
                    TaskName,
                    normalizedUserSid,
                    NormalizePath(command),
                    NormalizePath(workingDirectory),
                    runtime.State,
                    runtime.NextRunTime,
                    TaskScheduleCanonicalizer.ComputeTaskXmlFingerprint(document));
                return true;
            }
            catch (Exception exception)
            {
                error = "The installed backup task metadata could not be validated: " +
                    SanitizeError(exception.Message);
                return false;
            }
        }

        private static void ParseSingleCalendarTrigger(
            XmlDocument document,
            XmlNamespaceManager namespaces,
            out BackupScheduleCadence cadence,
            out TimeSpan timeOfDay,
            out DayOfWeek[] days)
        {
            XmlNodeList triggers = document.SelectNodes("/t:Task/t:Triggers/*", namespaces);
            if (triggers == null || triggers.Count != 1 || triggers[0].LocalName != "CalendarTrigger")
            {
                throw new InvalidDataException("The backup task must have exactly one calendar trigger.");
            }
            XmlNode trigger = triggers[0];
            foreach (XmlNode child in trigger.ChildNodes)
            {
                if (child.NodeType != XmlNodeType.Element)
                {
                    continue;
                }
                if (child.NamespaceURI != TaskNamespace ||
                    (child.LocalName != "StartBoundary" &&
                    child.LocalName != "Enabled" &&
                    child.LocalName != "ScheduleByDay" &&
                    child.LocalName != "ScheduleByWeek"))
                {
                    throw new InvalidDataException(
                        "The backup task uses an unsupported custom or repeating trigger option.");
                }
            }
            if (trigger.SelectSingleNode("t:Repetition", namespaces) != null)
            {
                throw new InvalidDataException("Repeating backup triggers are not supported.");
            }
            bool triggerEnabled = ReadBooleanFromNode(trigger, namespaces, "t:Enabled", true);
            if (!triggerEnabled)
            {
                throw new InvalidDataException(
                    "The calendar trigger is disabled independently of the task.");
            }

            XmlNode startNode = ReadSingleNode(trigger, namespaces, "t:StartBoundary");
            DateTime startBoundary;
            if (!DateTime.TryParse(
                startNode.InnerText.Trim(),
                CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.RoundtripKind,
                out startBoundary) ||
                startBoundary.TimeOfDay.Ticks % TimeSpan.TicksPerMinute != 0)
            {
                throw new InvalidDataException("The calendar start time is invalid.");
            }
            timeOfDay = new TimeSpan(startBoundary.Hour, startBoundary.Minute, 0);

            XmlNodeList dailyNodes = trigger.SelectNodes("t:ScheduleByDay", namespaces);
            XmlNodeList weeklyNodes = trigger.SelectNodes("t:ScheduleByWeek", namespaces);
            int dailyCount = dailyNodes == null ? 0 : dailyNodes.Count;
            int weeklyCount = weeklyNodes == null ? 0 : weeklyNodes.Count;
            if (dailyCount + weeklyCount != 1)
            {
                throw new InvalidDataException(
                    "The calendar trigger must be daily or use selected weekdays.");
            }

            if (dailyCount == 1)
            {
                XmlNode daily = dailyNodes[0];
                EnsureOnlyChildren(daily, new[] { "DaysInterval" });
                string interval = ReadRequiredValue(daily, namespaces, "t:DaysInterval");
                if (interval != "1")
                {
                    throw new InvalidDataException("Daily backups must recur every day.");
                }
                cadence = BackupScheduleCadence.Daily;
                days = new DayOfWeek[0];
                return;
            }

            XmlNode weekly = weeklyNodes[0];
            EnsureOnlyChildren(weekly, new[] { "WeeksInterval", "DaysOfWeek" });
            string weeksInterval = ReadRequiredValue(weekly, namespaces, "t:WeeksInterval");
            if (weeksInterval != "1")
            {
                throw new InvalidDataException("Selected weekdays must recur every week.");
            }
            XmlNode dayContainer = ReadSingleNode(weekly, namespaces, "t:DaysOfWeek");
            List<DayOfWeek> parsedDays = new List<DayOfWeek>();
            foreach (XmlNode dayNode in dayContainer.ChildNodes)
            {
                if (dayNode.NodeType != XmlNodeType.Element)
                {
                    continue;
                }
                DayOfWeek day;
                if (dayNode.NamespaceURI != TaskNamespace ||
                    !TaskScheduleCanonicalizer.TryParseXmlDay(dayNode.LocalName, out day) ||
                    parsedDays.Contains(day))
                {
                    throw new InvalidDataException("The selected weekday list is invalid.");
                }
                parsedDays.Add(day);
            }
            string normalizationError;
            DayOfWeek[] normalized;
            if (!TaskScheduleCanonicalizer.TryNormalizePolicy(
                BackupScheduleCadence.SelectedDays,
                timeOfDay,
                parsedDays,
                out normalized,
                out normalizationError))
            {
                throw new InvalidDataException(normalizationError);
            }
            cadence = BackupScheduleCadence.SelectedDays;
            days = normalized;
        }

        private static void EnsureOnlyChildren(XmlNode parent, string[] allowedNames)
        {
            HashSet<string> allowed = new HashSet<string>(
                allowedNames,
                StringComparer.Ordinal);
            foreach (XmlNode child in parent.ChildNodes)
            {
                if (child.NodeType == XmlNodeType.Element &&
                    (child.NamespaceURI != TaskNamespace || !allowed.Contains(child.LocalName)))
                {
                    throw new InvalidDataException("The calendar trigger contains an unsupported option.");
                }
            }
        }

        private static bool ValidateProtectedInputs(
            string schtasks,
            string expectedLauncher,
            string installRoot,
            out string error)
        {
            error = null;
            if (!File.Exists(schtasks))
            {
                error = "Windows Task Scheduler is unavailable in System32.";
                return false;
            }
            if (!Directory.Exists(installRoot) ||
                (File.GetAttributes(installRoot) & FileAttributes.ReparsePoint) != 0)
            {
                error = "The protected backup installation directory is unavailable.";
                return false;
            }
            if (!File.Exists(expectedLauncher) ||
                (File.GetAttributes(expectedLauncher) & FileAttributes.ReparsePoint) != 0)
            {
                error = "The protected backup launcher is missing or unsafe.";
                return false;
            }
            return true;
        }

        private static bool TryQueryTaskXml(
            string schtasks,
            string systemDirectory,
            out string xml,
            out string error)
        {
            xml = null;
            error = null;
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = schtasks;
            startInfo.Arguments = "/Query /TN \"" + TaskName + "\" /XML";
            startInfo.WorkingDirectory = systemDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;

            try
            {
                using (Process process = Process.Start(startInfo))
                {
                    if (process == null)
                    {
                        error = "Windows did not open the installed backup task.";
                        return false;
                    }
                    BoundedTextCapture output = new BoundedTextCapture(
                        process.StandardOutput,
                        MaximumTaskXmlCharacters);
                    BoundedTextCapture errors = new BoundedTextCapture(
                        process.StandardError,
                        MaximumErrorCharacters);
                    output.Start();
                    errors.Start();
                    if (!process.WaitForExit(QueryTimeoutMilliseconds))
                    {
                        try { process.Kill(); }
                        catch { }
                        output.Join();
                        errors.Join();
                        error = "Reading the installed backup task timed out.";
                        return false;
                    }
                    process.WaitForExit();
                    output.Join();
                    errors.Join();
                    if (output.Failed || errors.Failed)
                    {
                        error = "Windows Task Scheduler output could not be read safely.";
                        return false;
                    }
                    if (output.ExceededLimit || errors.ExceededLimit)
                    {
                        error = "Windows Task Scheduler returned too much metadata.";
                        return false;
                    }
                    if (process.ExitCode != 0)
                    {
                        error = string.IsNullOrWhiteSpace(errors.Value)
                            ? "The installed backup task is unavailable."
                            : SanitizeError(errors.Value);
                        return false;
                    }
                    xml = output.Value;
                    return true;
                }
            }
            catch (Exception exception)
            {
                error = "The installed backup task could not be queried: " +
                    SanitizeError(exception.Message);
                return false;
            }
        }

        private static bool TryReadRuntimeInfo(
            out TaskScheduleRuntimeInfo runtime,
            out string error)
        {
            runtime = null;
            error = null;
            object service = null;
            object folder = null;
            object task = null;
            try
            {
                Type serviceType = Type.GetTypeFromProgID("Schedule.Service", false);
                if (serviceType == null)
                {
                    error = "The Windows Task Scheduler service is unavailable.";
                    return false;
                }
                service = Activator.CreateInstance(serviceType);
                InvokeCom(service, "Connect", BindingFlags.InvokeMethod, new object[0]);
                folder = InvokeCom(service, "GetFolder", BindingFlags.InvokeMethod, new object[] { "\\" });
                task = InvokeCom(folder, "GetTask", BindingFlags.InvokeMethod, new object[] { TaskName });
                int stateValue = Convert.ToInt32(
                    InvokeCom(task, "State", BindingFlags.GetProperty, null),
                    CultureInfo.InvariantCulture);
                object nextValue = InvokeCom(task, "NextRunTime", BindingFlags.GetProperty, null);
                DateTime? nextRunTime = null;
                if (nextValue != null)
                {
                    DateTime candidate = Convert.ToDateTime(nextValue, CultureInfo.InvariantCulture);
                    if (candidate.Year >= 2000)
                    {
                        nextRunTime = candidate;
                    }
                }
                BackupTaskState state = Enum.IsDefined(typeof(BackupTaskState), stateValue)
                    ? (BackupTaskState)stateValue
                    : BackupTaskState.Unknown;
                runtime = new TaskScheduleRuntimeInfo(state, nextRunTime);
                return true;
            }
            catch (Exception exception)
            {
                error = "The backup task state could not be read safely: " +
                    SanitizeError(exception.Message);
                return false;
            }
            finally
            {
                ReleaseCom(task);
                ReleaseCom(folder);
                ReleaseCom(service);
            }
        }

        private static object InvokeCom(
            object target,
            string member,
            BindingFlags operation,
            object[] arguments)
        {
            if (target == null)
            {
                throw new InvalidOperationException("The Task Scheduler COM object is unavailable.");
            }
            return target.GetType().InvokeMember(
                member,
                operation,
                null,
                target,
                arguments,
                CultureInfo.InvariantCulture);
        }

        private static void ReleaseCom(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                try { Marshal.FinalReleaseComObject(value); }
                catch { }
            }
        }

        private static string GetCurrentUserSid()
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                return identity.User == null ? null : identity.User.Value;
            }
        }

        private static bool TryResolveSid(string value, out string sid)
        {
            sid = null;
            try
            {
                SecurityIdentifier identifier = value.StartsWith(
                    "S-",
                    StringComparison.OrdinalIgnoreCase)
                    ? new SecurityIdentifier(value)
                    : (SecurityIdentifier)new NTAccount(value).Translate(
                        typeof(SecurityIdentifier));
                sid = identifier.Value;
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static XmlNode ReadSingleNode(
            XmlNode node,
            XmlNamespaceManager namespaces,
            string xpath)
        {
            XmlNodeList nodes = node.SelectNodes(xpath, namespaces);
            if (nodes == null || nodes.Count != 1)
            {
                throw new InvalidDataException("Task metadata is missing or duplicated: " + xpath);
            }
            return nodes[0];
        }

        private static string ReadRequiredValue(
            XmlNode node,
            XmlNamespaceManager namespaces,
            string xpath)
        {
            string value = ReadSingleNode(node, namespaces, xpath).InnerText.Trim();
            if (value.Length == 0)
            {
                throw new InvalidDataException("Task metadata is empty: " + xpath);
            }
            return value;
        }

        private static string ReadOptionalValue(
            XmlNode node,
            XmlNamespaceManager namespaces,
            string xpath)
        {
            XmlNodeList nodes = node.SelectNodes(xpath, namespaces);
            if (nodes == null || nodes.Count == 0)
            {
                return string.Empty;
            }
            if (nodes.Count != 1)
            {
                throw new InvalidDataException("Task metadata is duplicated: " + xpath);
            }
            return nodes[0].InnerText.Trim();
        }

        private static bool ReadBoolean(
            XmlNode node,
            XmlNamespaceManager namespaces,
            string xpath,
            bool defaultValue)
        {
            string value = ReadOptionalValue(node, namespaces, xpath);
            XmlNodeList nodes = node.SelectNodes(xpath, namespaces);
            if (nodes == null || nodes.Count == 0)
            {
                return defaultValue;
            }
            if (nodes.Count != 1 || value.Length == 0)
            {
                throw new InvalidDataException(
                    "Task metadata contains an invalid Boolean: " + xpath);
            }
            if (string.Equals(value, "true", StringComparison.OrdinalIgnoreCase) || value == "1")
            {
                return true;
            }
            if (string.Equals(value, "false", StringComparison.OrdinalIgnoreCase) || value == "0")
            {
                return false;
            }
            throw new InvalidDataException("Task metadata contains an invalid Boolean: " + xpath);
        }

        private static bool ReadBooleanFromNode(
            XmlNode node,
            XmlNamespaceManager namespaces,
            string xpath,
            bool defaultValue)
        {
            return ReadBoolean(node, namespaces, xpath, defaultValue);
        }

        private static bool ReadRequiredBoolean(
            XmlNode node,
            XmlNamespaceManager namespaces,
            string xpath)
        {
            XmlNode value = ReadSingleNode(node, namespaces, xpath);
            string text = value.InnerText.Trim();
            if (string.Equals(text, "true", StringComparison.OrdinalIgnoreCase) || text == "1")
            {
                return true;
            }
            if (string.Equals(text, "false", StringComparison.OrdinalIgnoreCase) || text == "0")
            {
                return false;
            }
            throw new InvalidDataException("Task metadata contains an invalid Boolean: " + xpath);
        }

        private static string ReadAttribute(XmlNode node, string name)
        {
            if (node == null || node.Attributes == null || node.Attributes[name] == null)
            {
                return string.Empty;
            }
            return node.Attributes[name].Value.Trim();
        }

        internal static bool SamePath(string first, string second)
        {
            if (string.IsNullOrWhiteSpace(first) || string.IsNullOrWhiteSpace(second))
            {
                return false;
            }
            try
            {
                return string.Equals(
                    NormalizePath(first),
                    NormalizePath(second),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        internal static string NormalizePath(string value)
        {
            return Path.GetFullPath(value).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
        }

        internal static string SanitizeError(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return "The protected schedule operation failed.";
            }
            StringBuilder result = new StringBuilder();
            foreach (char character in value)
            {
                if (!char.IsControl(character) || character == '\t')
                {
                    result.Append(character);
                }
                if (result.Length >= 2000)
                {
                    break;
                }
            }
            string sanitized = result.ToString().Trim();
            return sanitized.Length == 0
                ? "The protected schedule operation failed."
                : sanitized;
        }

        private sealed class BoundedTextCapture
        {
            private readonly TextReader reader;
            private readonly int limit;
            private readonly StringBuilder value;
            private readonly Thread thread;

            public BoundedTextCapture(TextReader reader, int limit)
            {
                this.reader = reader;
                this.limit = limit;
                value = new StringBuilder(Math.Min(limit, 8192));
                thread = new Thread(ReadAll);
                thread.IsBackground = true;
            }

            public bool ExceededLimit { get; private set; }
            public bool Failed { get; private set; }
            public string Value { get { return value.ToString(); } }

            public void Start()
            {
                thread.Start();
            }

            public void Join()
            {
                thread.Join(5000);
                if (thread.IsAlive)
                {
                    Failed = true;
                }
            }

            private void ReadAll()
            {
                try
                {
                    char[] buffer = new char[4096];
                    int count;
                    while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        int remaining = limit - value.Length;
                        if (remaining > 0)
                        {
                            value.Append(buffer, 0, Math.Min(remaining, count));
                        }
                        if (count > remaining)
                        {
                            ExceededLimit = true;
                        }
                    }
                }
                catch
                {
                    Failed = true;
                }
            }
        }
    }

    internal static class TaskScheduleCanonicalizer
    {
        internal static string FingerprintDomain
        {
            get { return EngineProfile.Current.TaskXmlFingerprintDomain; }
        }

        internal static string RequestDomain
        {
            get { return EngineProfile.Current.ScheduleRequestDomain; }
        }

        private static readonly DayOfWeek[] OrderedDays =
        {
            DayOfWeek.Sunday,
            DayOfWeek.Monday,
            DayOfWeek.Tuesday,
            DayOfWeek.Wednesday,
            DayOfWeek.Thursday,
            DayOfWeek.Friday,
            DayOfWeek.Saturday
        };

        internal static bool TryNormalizePolicy(
            BackupScheduleCadence cadence,
            TimeSpan timeOfDay,
            IEnumerable<DayOfWeek> days,
            out DayOfWeek[] normalizedDays,
            out string error)
        {
            normalizedDays = null;
            error = null;
            if (timeOfDay < TimeSpan.Zero || timeOfDay >= TimeSpan.FromDays(1) ||
                timeOfDay.Seconds != 0 || timeOfDay.Milliseconds != 0)
            {
                error = "Choose a backup time between 00:00 and 23:59.";
                return false;
            }
            HashSet<DayOfWeek> selected = new HashSet<DayOfWeek>();
            if (days != null)
            {
                foreach (DayOfWeek day in days)
                {
                    if (!Enum.IsDefined(typeof(DayOfWeek), day) || !selected.Add(day))
                    {
                        error = "Each selected weekday must be valid and unique.";
                        return false;
                    }
                }
            }
            if (cadence == BackupScheduleCadence.Daily)
            {
                if (selected.Count != 0)
                {
                    error = "Daily schedules must not also contain selected weekdays.";
                    return false;
                }
                normalizedDays = new DayOfWeek[0];
                return true;
            }
            if (cadence != BackupScheduleCadence.SelectedDays || selected.Count == 0)
            {
                error = "Select at least one weekday.";
                return false;
            }
            List<DayOfWeek> ordered = new List<DayOfWeek>();
            foreach (DayOfWeek day in OrderedDays)
            {
                if (selected.Contains(day))
                {
                    ordered.Add(day);
                }
            }
            normalizedDays = ordered.ToArray();
            return true;
        }

        internal static bool TryParseDayToken(string token, out DayOfWeek day)
        {
            day = DayOfWeek.Monday;
            string normalized = string.IsNullOrWhiteSpace(token) ? string.Empty : token.Trim();
            for (int index = 0; index < OrderedDays.Length; index++)
            {
                DayOfWeek candidate = OrderedDays[index];
                if (string.Equals(normalized, DayToken(candidate), StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(normalized, candidate.ToString(), StringComparison.OrdinalIgnoreCase))
                {
                    day = candidate;
                    return true;
                }
            }
            return false;
        }

        internal static bool TryParseXmlDay(string value, out DayOfWeek day)
        {
            return TryParseDayToken(value, out day);
        }

        internal static string FormatTime(TimeSpan value)
        {
            return value.Hours.ToString("00", CultureInfo.InvariantCulture) + ":" +
                value.Minutes.ToString("00", CultureInfo.InvariantCulture);
        }

        internal static string FormatDays(IEnumerable<DayOfWeek> days)
        {
            if (days == null)
            {
                return string.Empty;
            }
            List<string> values = new List<string>();
            foreach (DayOfWeek day in days)
            {
                values.Add(DayToken(day));
            }
            return string.Join(",", values.ToArray());
        }

        internal static string CreatePolicyPayload(
            BackupScheduleCadence cadence,
            TimeSpan timeOfDay,
            IEnumerable<DayOfWeek> days,
            bool enabled,
            bool startWhenAvailable,
            bool wakeToRun,
            bool allowStartOnBatteries,
            bool stopIfGoingOnBatteries)
        {
            return (cadence == BackupScheduleCadence.Daily ? "Daily" : "SelectedDays") + "\n" +
                FormatTime(timeOfDay) + "\n" +
                FormatDays(days) + "\n" +
                BooleanToken(enabled) + "\n" +
                BooleanToken(startWhenAvailable) + "\n" +
                BooleanToken(wakeToRun) + "\n" +
                BooleanToken(allowStartOnBatteries) + "\n" +
                BooleanToken(stopIfGoingOnBatteries);
        }

        internal static string ComputeTaskXmlFingerprint(XmlDocument document)
        {
            if (document == null || document.DocumentElement == null)
            {
                throw new ArgumentNullException("document");
            }
            return ComputeSha256(FingerprintDomain + "\n" + document.DocumentElement.OuterXml);
        }

        internal static string ComputeRequestDigest(
            string userSid,
            string baselineFingerprint,
            ScheduleChangeRequest request,
            string nonce)
        {
            if (request == null)
            {
                throw new ArgumentNullException("request");
            }
            string payload = RequestDomain + "\n" +
                userSid + "\n" +
                "apply\n" +
                baselineFingerprint + "\n" +
                request.CadenceArgument.ToLowerInvariant() + "\n" +
                request.TimeArgument + "\n" +
                request.DaysArgument + "\n" +
                BooleanToken(request.Enabled) + "\n" +
                BooleanToken(request.StartWhenAvailable) + "\n" +
                BooleanToken(request.WakeToRun) + "\n" +
                BooleanToken(request.AllowStartOnBatteries) + "\n" +
                BooleanToken(request.StopIfGoingOnBatteries) + "\n" +
                nonce;
            return ComputeSha256(payload);
        }

        internal static string CreateSummary(
            BackupScheduleCadence cadence,
            TimeSpan timeOfDay,
            IEnumerable<DayOfWeek> days,
            bool enabled)
        {
            string schedule = cadence == BackupScheduleCadence.Daily
                ? "Daily at " + FormatTime(timeOfDay)
                : FormatFriendlyDays(days) + " at " + FormatTime(timeOfDay);
            return enabled ? schedule : "Paused — " + schedule;
        }

        internal static bool SameDays(DayOfWeek[] first, DayOfWeek[] second)
        {
            if (first == null || second == null || first.Length != second.Length)
            {
                return false;
            }
            for (int index = 0; index < first.Length; index++)
            {
                if (first[index] != second[index])
                {
                    return false;
                }
            }
            return true;
        }

        private static string DayToken(DayOfWeek day)
        {
            switch (day)
            {
                case DayOfWeek.Monday: return "Mon";
                case DayOfWeek.Tuesday: return "Tue";
                case DayOfWeek.Wednesday: return "Wed";
                case DayOfWeek.Thursday: return "Thu";
                case DayOfWeek.Friday: return "Fri";
                case DayOfWeek.Saturday: return "Sat";
                case DayOfWeek.Sunday: return "Sun";
                default: throw new ArgumentOutOfRangeException("day");
            }
        }

        private static string FormatFriendlyDays(IEnumerable<DayOfWeek> days)
        {
            List<string> values = new List<string>();
            HashSet<DayOfWeek> distinct = new HashSet<DayOfWeek>();
            if (days != null)
            {
                foreach (DayOfWeek day in days)
                {
                    values.Add(DayToken(day));
                    distinct.Add(day);
                }
            }
            // All seven days read as "Every day", not a list of seven. Only the words change: the cadence is still
            // SelectedDays, so what the editor compares and what the protected manager is asked to write are untouched.
            if (distinct.Count == 7)
            {
                return "Every day";
            }
            return string.Join(", ", values.ToArray());
        }

        private static string BooleanToken(bool value)
        {
            return value ? "1" : "0";
        }

        private static string ComputeSha256(string value)
        {
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] digest = algorithm.ComputeHash(
                    new UTF8Encoding(false).GetBytes(value));
                StringBuilder text = new StringBuilder(digest.Length * 2);
                foreach (byte item in digest)
                {
                    text.Append(item.ToString("x2", CultureInfo.InvariantCulture));
                }
                return text.ToString();
            }
        }
    }
}
