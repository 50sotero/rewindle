using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Rewindle.Setup
{
    // The host's half of the contract with Install-ResticBackuper.ps1 and Uninstall-ResticBackuper.ps1 (docs/setup-contract.md is
    // the installer's own write-up). Everything the host knows about the installer's command line, its plan file and its
    // progress lines is in this file, so a change to the contract is a change here. The wizard's half, which reads the plan and
    // the progress lines for display, is web/src/setup/contract.ts.
    //
    // The host never forwards what the page sent as a command line: the page's choices are checked into InstallerInputs, and the
    // argument arrays below are built from that and from paths the host itself made.

    // What the person chose, as the installer takes it. A null Repository or Schedule is left out, so the installer uses its own default.
    internal sealed class InstallerInputs
    {
        public string Repository;
        public string StorageMode = InstallerContract.StorageLocalNtfs;
        public string DriveFsMyDriveRoot;
        public readonly List<string> Sources = new List<string>();
        public string Schedule;
        public bool Vss = true;
        public bool StartBackup;
    }

    // One line of the installer's progress file.
    internal sealed class ProgressLine
    {
        public string Raw;
        // The decoded JSON object, or null when the line is not a JSON object (the wizard still lists it under Details).
        public IDictionary<string, object> Fields;
        public bool IsResult;
        public bool ResultOk;
        public string ResultErrorMessage;
        public string RecoveryKeyPath;
        // True or false as the installer worked it out, null when it could not say (or there is no key). Only false stops a copy.
        public bool? RecoveryKeyReadableByUser;
        public string DashboardExecutable;
        public string InstallRoot;
    }

    internal static class InstallerContract
    {
        public const string PlanSchema = "Rewindle.InstallPlan.v1";
        public const string ProgressSchema = "Rewindle.InstallProgress.v1";
        public const string InstallScript = "Install-ResticBackuper.ps1";
        public const string UninstallScript = "Uninstall-ResticBackuper.ps1";
        public const string StorageLocalNtfs = "local_ntfs";
        public const string StorageDriveFs = "google_drivefs_stream";
        public const int MaximumPathLength = 1024;
        public const int MaximumSources = 64;
        // The folders travel as one -SourceList argument (joined with ';'). Windows starts no process whose command line is over
        // 32,767 characters, so the list is held well under that, leaving room for the rest of the installer's arguments.
        public const int MaximumSourceListLength = 16384;
        public const int MaximumPlanBytes = 4 * 1024 * 1024;
        public const int MaximumProgressLineBytes = 256 * 1024;

        private static readonly Regex SchedulePattern = new Regex(@"^([01]\d|2[0-3]):[0-5]\d$", RegexOptions.CultureInvariant);
        private static readonly Regex DrivePathPattern = new Regex(@"^[A-Za-z]:\\", RegexOptions.CultureInvariant);

        // A path the installer may be given: absolute, on a drive letter, and made of nothing a command line or a file name cannot
        // carry. The installer checks the rest (that the folder exists, which drive it is on, whether it overlaps another).
        public static bool IsAcceptablePath(string path)
        {
            if (string.IsNullOrEmpty(path) || path.Length > MaximumPathLength || !DrivePathPattern.IsMatch(path))
            {
                return false;
            }
            for (int index = 0; index < path.Length; index++)
            {
                char character = path[index];
                if (character < ' ' || character == '"' || character == '<' || character == '>' || character == '|' ||
                    character == '?' || character == '*')
                {
                    return false;
                }
                // Only the drive letter has a colon (more would name an alternate data stream).
                if (character == ':' && index != 1)
                {
                    return false;
                }
            }
            foreach (string part in path.Split('\\'))
            {
                if (part == ".." || part == ".")
                {
                    return false;
                }
            }
            return true;
        }

        public static bool IsAcceptableSchedule(string schedule)
        {
            return schedule != null && SchedulePattern.IsMatch(schedule);
        }

        // Reads what the page sent for getPlan (forInstall false: anything may be left out, because the plan will say what is
        // missing) or for install (forInstall true: everything the installer needs must be there). Returns false with a plain
        // sentence for the person when the payload cannot be used.
        public static bool TryReadInputs(
            IDictionary<string, object> raw,
            bool forInstall,
            out InstallerInputs inputs,
            out string error)
        {
            inputs = new InstallerInputs();
            error = null;
            if (raw == null)
            {
                if (forInstall)
                {
                    error = "Setup did not receive your choices.";
                    return false;
                }
                return true;
            }

            object repository = Json.Get(raw, "repository");
            if (repository != null)
            {
                string text = repository as string;
                if (text == null || text.Length > MaximumPathLength)
                {
                    error = "The backup location is not valid.";
                    return false;
                }
                if (text.Length > 0)
                {
                    if (!IsAcceptablePath(text))
                    {
                        error = "Choose a backup location on a drive with a letter, like D: or E:.";
                        return false;
                    }
                    inputs.Repository = text;
                }
            }

            object mode = Json.Get(raw, "storageMode");
            if (mode != null)
            {
                if (!string.Equals(mode as string, StorageLocalNtfs, StringComparison.Ordinal) &&
                    !string.Equals(mode as string, StorageDriveFs, StringComparison.Ordinal))
                {
                    error = "The kind of backup location is not valid.";
                    return false;
                }
                inputs.StorageMode = (string)mode;
            }

            object driveFs = Json.Get(raw, "driveFsMyDriveRoot");
            if (driveFs != null)
            {
                string text = driveFs as string;
                if (text == null || !IsAcceptablePath(text) || inputs.StorageMode != StorageDriveFs)
                {
                    error = "The Google Drive location is not valid.";
                    return false;
                }
                inputs.DriveFsMyDriveRoot = text;
            }

            object sources = Json.Get(raw, "sources");
            if (sources != null)
            {
                IList<object> list = Json.AsList(sources);
                if (list == null || list.Count > MaximumSources)
                {
                    error = "Rewindle can protect up to " + MaximumSources + " folders.";
                    return false;
                }
                foreach (object item in list)
                {
                    string text = item as string;
                    // A semicolon separates the folders in the installer's list, so a folder whose name has one cannot be passed.
                    if (text == null || !IsAcceptablePath(text) || text.IndexOf(';') >= 0)
                    {
                        error = "One of the folders can’t be backed up. Choose folders on a drive with a letter, and without a semicolon (;) in the name.";
                        return false;
                    }
                    inputs.Sources.Add(text);
                }
                if (string.Join(";", inputs.Sources.ToArray()).Length > MaximumSourceListLength)
                {
                    error = "Together, the chosen folders' paths are too long for Windows to hand to the installer. Choose fewer folders, or folders with shorter paths.";
                    return false;
                }
            }

            object schedule = Json.Get(raw, "schedule");
            if (schedule != null)
            {
                string text = schedule as string;
                if (!IsAcceptableSchedule(text))
                {
                    error = "Choose a time between 00:00 and 23:59.";
                    return false;
                }
                inputs.Schedule = text;
            }

            bool? vss = Json.Bool(raw, "vss");
            if (Json.Get(raw, "vss") != null && !vss.HasValue)
            {
                error = "The open-files choice is not valid.";
                return false;
            }
            inputs.Vss = !vss.HasValue || vss.Value;

            bool? start = Json.Bool(raw, "startBackup");
            inputs.StartBackup = start.HasValue && start.Value;

            if (forInstall)
            {
                if (inputs.Repository == null)
                {
                    error = "Choose where to keep your backups.";
                    return false;
                }
                if (inputs.Sources.Count == 0)
                {
                    error = "Choose at least one folder to protect.";
                    return false;
                }
                if (inputs.Schedule == null)
                {
                    error = "Choose a time for the daily backup.";
                    return false;
                }
            }
            return true;
        }

        // powershell.exe's own arguments for running one of the installer's scripts: no profile, never interactive, and the policy that
        // lets the unsigned script run, as Install.cmd starts it.
        private static List<string> ScriptArguments(string scriptPath)
        {
            List<string> arguments = new List<string>();
            arguments.Add("-NoProfile");
            // A prompt in a script nobody can see would wait for ever; with this switch it fails with a message instead.
            arguments.Add("-NonInteractive");
            arguments.Add("-ExecutionPolicy");
            arguments.Add("Bypass");
            arguments.Add("-File");
            arguments.Add(scriptPath);
            return arguments;
        }

        private static void AddChoices(List<string> arguments, InstallerInputs inputs)
        {
            if (inputs.Repository != null)
            {
                arguments.Add("-Repository");
                arguments.Add(inputs.Repository);
            }
            arguments.Add("-RepositoryStorageMode");
            arguments.Add(inputs.StorageMode);
            if (inputs.StorageMode == StorageDriveFs && inputs.DriveFsMyDriveRoot != null)
            {
                arguments.Add("-DriveFsMyDriveRoot");
                arguments.Add(inputs.DriveFsMyDriveRoot);
            }
            if (inputs.Sources.Count > 0)
            {
                arguments.Add("-SourceList");
                arguments.Add(string.Join(";", inputs.Sources.ToArray()));
            }
            if (inputs.Schedule != null)
            {
                arguments.Add("-Schedule");
                arguments.Add(inputs.Schedule);
            }
            if (!inputs.Vss)
            {
                arguments.Add("-DisableVss");
            }
        }

        // Plan mode: runs without elevation and changes nothing, and writes the plan to planOutput.
        public static List<string> PlanArguments(string scriptPath, string planOutput, InstallerInputs inputs)
        {
            List<string> arguments = ScriptArguments(scriptPath);
            arguments.Add("-PlanOnly");
            arguments.Add("-PlanOutput");
            arguments.Add(planOutput);
            AddChoices(arguments, inputs);
            return arguments;
        }

        // The install itself, which is started elevated: unattended, told whose profile it is for, and told where to report.
        public static List<string> InstallArguments(
            string scriptPath,
            string userSid,
            string progressPath,
            InstallerInputs inputs)
        {
            List<string> arguments = ScriptArguments(scriptPath);
            arguments.Add("-Unattended");
            arguments.Add("-ExpectedUserSid");
            arguments.Add(userSid);
            arguments.Add("-ProgressPath");
            arguments.Add(progressPath);
            AddChoices(arguments, inputs);
            if (inputs.StartBackup)
            {
                arguments.Add("-StartBackup");
            }
            return arguments;
        }

        public static List<string> UninstallArguments(string scriptPath, string userSid, string progressPath)
        {
            List<string> arguments = ScriptArguments(scriptPath);
            arguments.Add("-Unattended");
            arguments.Add("-ExpectedUserSid");
            arguments.Add(userSid);
            arguments.Add("-ProgressPath");
            arguments.Add(progressPath);
            return arguments;
        }

        // Checks a plan file's text: it must be a JSON object that names the plan schema. The wizard reads the rest.
        public static bool TryReadPlan(string text, out IDictionary<string, object> plan, out string error)
        {
            plan = null;
            error = null;
            if (string.IsNullOrWhiteSpace(text))
            {
                error = "The installer wrote an empty plan.";
                return false;
            }
            if (text.Length > MaximumPlanBytes)
            {
                error = "The installer's plan is larger than expected.";
                return false;
            }
            object parsed;
            try
            {
                parsed = Json.Parse(text.TrimStart('﻿'));
            }
            catch (Exception)
            {
                error = "The installer's plan could not be read.";
                return false;
            }
            IDictionary<string, object> root = Json.AsObject(parsed);
            if (root == null || !string.Equals(Json.String(root, "schema", 128), PlanSchema, StringComparison.Ordinal))
            {
                error = "The installer's plan is in a format this version of Setup does not know.";
                return false;
            }
            plan = root;
            return true;
        }

        // True when the plan says the install may go ahead: ok, and no errors.
        public static bool PlanAllowsInstall(IDictionary<string, object> plan)
        {
            if (plan == null)
            {
                return false;
            }
            bool? ok = Json.Bool(plan, "ok");
            IList<object> errors = Json.AsList(Json.Get(plan, "errors"));
            return ok.HasValue && ok.Value && (errors == null || errors.Count == 0);
        }

        // Reads one line of the progress file. Never throws: a line that is not JSON is kept as text, so Details can show it.
        public static ProgressLine ReadProgressLine(string raw)
        {
            ProgressLine line = new ProgressLine();
            line.Raw = raw;
            object parsed = null;
            try
            {
                parsed = Json.Parse(raw);
            }
            catch (Exception)
            {
            }
            line.Fields = Json.AsObject(parsed);
            if (line.Fields == null)
            {
                return line;
            }
            // Only a result in the schema this setup understands decides the outcome; anything else is kept as a line for Details.
            if (string.Equals(Json.String(line.Fields, "type", 32), "result", StringComparison.Ordinal) &&
                string.Equals(Json.String(line.Fields, "schema", 64), ProgressSchema, StringComparison.Ordinal))
            {
                line.IsResult = true;
                IDictionary<string, object> failure = Json.AsObject(Json.Get(line.Fields, "error"));
                bool? ok = Json.Bool(line.Fields, "ok");
                line.ResultOk = ok.HasValue && ok.Value && failure == null;
                if (failure != null)
                {
                    line.ResultErrorMessage = Json.String(failure, "message", 2048);
                }
                line.RecoveryKeyPath = Json.String(line.Fields, "recovery_key_path", MaximumPathLength);
                line.RecoveryKeyReadableByUser = Json.Bool(line.Fields, "recovery_key_readable_by_user");
                line.DashboardExecutable = Json.String(line.Fields, "dashboard_executable", MaximumPathLength);
                line.InstallRoot = Json.String(line.Fields, "install_root", MaximumPathLength);
            }
            return line;
        }
    }
}
