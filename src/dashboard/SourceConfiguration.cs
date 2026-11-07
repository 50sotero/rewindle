using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal sealed class BackupSourceView
    {
        public string SourcePath { get; private set; }
        public bool IsProtectedCanary { get; private set; }
        public string DisplayName { get; private set; }
        public string ShortPath { get; private set; }

        public string RoleLabel
        {
            get { return IsProtectedCanary ? "Required" : "Protected"; }
        }

        public BackupSourceView(string sourcePath, bool isProtectedCanary)
        {
            SourcePath = sourcePath;
            IsProtectedCanary = isProtectedCanary;
            DisplayName = BuildDisplayName(sourcePath, isProtectedCanary);
            ShortPath = BuildShortPath(sourcePath);
        }

        private static string BuildDisplayName(string sourcePath, bool isProtectedCanary)
        {
            if (isProtectedCanary)
            {
                // The folder is Rewindle's own (its leaf is "Canary"), so it is named for what it is for, not for where it sits.
                return "Restore test file (added by Rewindle)";
            }

            string[,] knownFolders =
            {
                { Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Desktop" },
                { Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Documents" },
                { Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Pictures" },
                { Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "Music" },
                { Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "Videos" },
                { Environment.GetFolderPath(Environment.SpecialFolder.Favorites), "Favorites" }
            };
            for (int index = 0; index < knownFolders.GetLength(0); index++)
            {
                string knownPath = knownFolders[index, 0];
                if (!string.IsNullOrWhiteSpace(knownPath) &&
                    string.Equals(sourcePath, knownPath, StringComparison.OrdinalIgnoreCase))
                {
                    return knownFolders[index, 1];
                }
            }

            string root = Path.GetPathRoot(sourcePath);
            if (string.Equals(sourcePath, root, StringComparison.OrdinalIgnoreCase))
            {
                return root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + " drive";
            }

            // Any other folder is shown by its own name: the app does not rename a person's folders.
            string folderName = new DirectoryInfo(sourcePath).Name;
            return string.IsNullOrWhiteSpace(folderName) ? sourcePath : folderName;
        }

        private static string BuildShortPath(string sourcePath)
        {
            string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            string shortened = ReplacePathRoot(sourcePath, userProfile, "~");
            shortened = ReplacePathRoot(shortened, programData, "%PROGRAMDATA%");
            if (shortened.Length <= 58)
            {
                return shortened;
            }

            string root = Path.GetPathRoot(sourcePath) ?? string.Empty;
            DirectoryInfo directory = new DirectoryInfo(sourcePath);
            string leaf = directory.Name;
            string parent = directory.Parent == null ? string.Empty : directory.Parent.Name;
            string tail = string.IsNullOrWhiteSpace(parent)
                ? leaf
                : parent + Path.DirectorySeparatorChar + leaf;
            return root + "..." + Path.DirectorySeparatorChar + tail;
        }

        private static string ReplacePathRoot(string sourcePath, string rootPath, string replacement)
        {
            if (string.IsNullOrWhiteSpace(rootPath))
            {
                return sourcePath;
            }
            string normalizedRoot = rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (string.Equals(sourcePath, normalizedRoot, StringComparison.OrdinalIgnoreCase))
            {
                return replacement;
            }
            string prefix = normalizedRoot + Path.DirectorySeparatorChar;
            if (sourcePath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return replacement + Path.DirectorySeparatorChar + sourcePath.Substring(prefix.Length);
            }
            return sourcePath;
        }
    }

    // The installed backup configuration is not there: Rewindle is running on a computer without the backup service it reports on,
    // or before that service is installed. A type of its own so that this is told apart from a configuration that is there and
    // cannot be used, which is a fault and not a first run. It is still a FileNotFoundException, so everything that already
    // catches one keeps working.
    internal sealed class BackupInstallationMissingException : FileNotFoundException
    {
        internal const string DefaultMessage = "The installed backup configuration was not found.";

        internal BackupInstallationMissingException(string configurationPath)
            : base(DefaultMessage, configurationPath)
        {
        }
    }

    internal sealed class SourceConfiguration
    {
        private const int MaximumConfigurationBytes = 1024 * 1024;
        // A read of the configuration that lands in the middle of a rewrite is tried once more after this long (see
        // ReadConfigurationDocument). Load runs on the window's own thread too, so the wait is kept short: it is also what a
        // configuration that stays unreadable costs every time it is read.
        private const int ConfigurationReadRetryMilliseconds = 20;

        public string InstallRoot { get; private set; }
        public string ConfigurationPath { get; private set; }
        public string ManagerPath { get; private set; }
        public string RepositoryPath { get; private set; }
        public string StateDirectory { get; private set; }
        public string PlanId { get; private set; }
        public long ConfigGeneration { get; private set; }
        public string CloudPlaceholderPolicy { get; private set; }
        public IList<BackupSourceView> Sources { get; private set; }
        // For the Backup location card only (how full the backup drive is). Never required: a configuration without them, or with a value
        // that cannot be used, still loads, so the plan is never refused over a figure the card can do without. "google_drivefs_stream"
        // when the backups are kept in Google Drive for desktop, otherwise "local_ntfs".
        public string RepositoryStorageMode { get; private set; }
        // minimum_free_gib in bytes, the free space below which the backup service refuses to start a backup; -1 when it is missing or not
        // a usable number.
        public long MinimumFreeBytes { get; private set; }

        private SourceConfiguration()
        {
        }

        public static SourceConfiguration Load()
        {
            string installRoot = ResolveProtectedInstallRoot();
            string configurationPath = Path.Combine(installRoot, "backup-config.json");
            // Asked of the path itself rather than File.Exists, which answers false for a folder it may not look at as well: a
            // configuration that is not there means nothing is installed, and one Windows will not show is a different fault.
            // Read-only, and nothing is created.
            FileAttributes configurationAttributes;
            try
            {
                configurationAttributes = File.GetAttributes(configurationPath);
            }
            catch (FileNotFoundException)
            {
                throw new BackupInstallationMissingException(configurationPath);
            }
            catch (DirectoryNotFoundException)
            {
                throw new BackupInstallationMissingException(configurationPath);
            }
            if ((configurationAttributes & FileAttributes.Directory) != 0)
            {
                throw new BackupInstallationMissingException(configurationPath);
            }

            FileInfo configurationFile = new FileInfo(configurationPath);
            if (configurationFile.Length > MaximumConfigurationBytes)
            {
                throw new InvalidDataException("The backup configuration is unexpectedly large.");
            }

            IDictionary<string, object> document = ReadConfigurationDocument(configurationPath);

            object planValue;
            string planId = document.TryGetValue("plan_id", out planValue)
                ? planValue as string
                : null;
            Guid parsedPlanId;
            if (string.IsNullOrWhiteSpace(planId) ||
                !Guid.TryParseExact(planId, "D", out parsedPlanId) ||
                !string.Equals(planId, parsedPlanId.ToString("D"), StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "The backup plan migration is incomplete: plan_id is not a canonical UUID.");
            }
            long configGeneration = ReadPositiveInteger(document, "config_generation");
            object cloudPolicyValue;
            string cloudPolicy = document.TryGetValue("cloud_placeholder_policy", out cloudPolicyValue)
                ? cloudPolicyValue as string
                : null;
            if (cloudPolicy != "strict" && cloudPolicy != "allow")
            {
                throw new InvalidDataException(
                    "The backup configuration contains an invalid cloud placeholder policy.");
            }

            object repositoryValue;
            string repositoryPath = document.TryGetValue("repository", out repositoryValue)
                ? repositoryValue as string
                : null;
            if (string.IsNullOrWhiteSpace(repositoryPath) || !Path.IsPathRooted(repositoryPath))
            {
                throw new InvalidDataException("The backup configuration contains an invalid repository path.");
            }
            repositoryPath = NormalizePath(repositoryPath);

            object stateDirectoryValue;
            string stateDirectory = document.TryGetValue(
                "state_directory",
                out stateDirectoryValue)
                    ? stateDirectoryValue as string
                    : null;
            if (string.IsNullOrWhiteSpace(stateDirectory) ||
                !Path.IsPathRooted(stateDirectory))
            {
                throw new InvalidDataException(
                    "The backup configuration contains an invalid state directory.");
            }
            stateDirectory = NormalizePath(stateDirectory);

            object sourceValue;
            IEnumerable sourceItems = null;
            if (document.TryGetValue("sources", out sourceValue) && !(sourceValue is string))
            {
                sourceItems = sourceValue as IEnumerable;
            }
            if (sourceItems == null)
            {
                throw new InvalidDataException("The backup configuration has no source folder list.");
            }

            string canaryFilePath = null;
            object canaryValue;
            if (document.TryGetValue("canary_file", out canaryValue) && canaryValue is string)
            {
                string canaryFile = (string)canaryValue;
                if (Path.IsPathRooted(canaryFile))
                {
                    canaryFilePath = Path.GetFullPath(canaryFile);
                }
            }

            List<string> sourcePaths = new List<string>();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (object item in sourceItems)
            {
                string source = item as string;
                if (string.IsNullOrWhiteSpace(source) || !Path.IsPathRooted(source))
                {
                    throw new InvalidDataException("The backup configuration contains an invalid source path.");
                }
                string absoluteSource = NormalizePath(source);
                if (!string.Equals(source, absoluteSource, StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "The backup configuration contains a non-canonical source path.");
                }
                if (!seen.Add(absoluteSource))
                {
                    throw new InvalidDataException(
                        "The backup configuration contains a duplicate source path.");
                }
                sourcePaths.Add(absoluteSource);
            }
            if (sourcePaths.Count == 0)
            {
                throw new InvalidDataException("The backup configuration contains no source folders.");
            }

            object identitiesValue;
            IDictionary<string, object> identities =
                document.TryGetValue("source_identities", out identitiesValue)
                    ? identitiesValue as IDictionary<string, object>
                    : null;
            if (identities == null || identities.Count != sourcePaths.Count)
            {
                throw new InvalidDataException(
                    "The backup configuration must identify the volume for every source folder.");
            }
            foreach (string sourcePath in sourcePaths)
            {
                string matchingKey = null;
                int matchingCount = 0;
                foreach (string identityKey in identities.Keys)
                {
                    if (string.Equals(identityKey, sourcePath, StringComparison.OrdinalIgnoreCase))
                    {
                        matchingKey = identityKey;
                        matchingCount++;
                    }
                }
                if (matchingCount != 1 ||
                    !string.Equals(matchingKey, sourcePath, StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "A source volume identity is missing, duplicated, or non-canonical.");
                }
                IDictionary<string, object> identity =
                    identities[matchingKey] as IDictionary<string, object>;
                object serialValue;
                string serial = identity != null &&
                    identity.TryGetValue("expected_volume_serial", out serialValue)
                        ? serialValue as string
                        : null;
                if (!IsEightHex(serial))
                {
                    throw new InvalidDataException(
                        "A configured source volume identity is invalid.");
                }
            }

            string protectedCanarySource = null;
            if (canaryFilePath != null)
            {
                foreach (string sourcePath in sourcePaths)
                {
                    if (IsWithin(canaryFilePath, sourcePath) &&
                        (protectedCanarySource == null || sourcePath.Length > protectedCanarySource.Length))
                    {
                        protectedCanarySource = sourcePath;
                    }
                }
                if (protectedCanarySource == null)
                {
                    throw new InvalidDataException(
                        "The restore canary is not contained by any configured source folder.");
                }
            }

            List<BackupSourceView> sources = new List<BackupSourceView>();
            foreach (string sourcePath in sourcePaths)
            {
                bool protectedCanary = protectedCanarySource != null &&
                    string.Equals(sourcePath, protectedCanarySource, StringComparison.OrdinalIgnoreCase);
                sources.Add(new BackupSourceView(sourcePath, protectedCanary));
            }

            string storageMode;
            long minimumFreeBytes;
            ReadSpaceSettings(document, out storageMode, out minimumFreeBytes);

            return new SourceConfiguration
            {
                InstallRoot = installRoot,
                ConfigurationPath = configurationPath,
                ManagerPath = Path.Combine(installRoot, EngineProfile.Current.SourceManagerFileName),
                RepositoryPath = repositoryPath,
                StateDirectory = stateDirectory,
                PlanId = planId,
                ConfigGeneration = configGeneration,
                CloudPlaceholderPolicy = cloudPolicy,
                Sources = sources,
                RepositoryStorageMode = storageMode,
                MinimumFreeBytes = minimumFreeBytes
            };
        }

        // Reads the storage mode and the reserve, both engines' way. Never throws for them. The reserve is a number of GiB, fractions
        // allowed, 0 or more (true, false, text and anything else are not), converted the way the engine converts it: whole bytes,
        // the fraction cut off.
        internal static void ReadSpaceSettings(
            IDictionary<string, object> document,
            out string storageMode,
            out long minimumFreeBytes)
        {
            storageMode = "local_ntfs";
            minimumFreeBytes = -1;
            if (document == null)
            {
                return;
            }
            object modeValue;
            if (document.TryGetValue("repository_storage_mode", out modeValue) &&
                string.Equals(modeValue as string, "google_drivefs_stream", StringComparison.Ordinal))
            {
                storageMode = "google_drivefs_stream";
            }
            object reserveValue;
            if (!document.TryGetValue("minimum_free_gib", out reserveValue) || reserveValue == null)
            {
                return;
            }
            decimal gibibytes;
            if (reserveValue is int)
            {
                gibibytes = (int)reserveValue;
            }
            else if (reserveValue is long)
            {
                gibibytes = (long)reserveValue;
            }
            else if (reserveValue is decimal)
            {
                gibibytes = (decimal)reserveValue;
            }
            else
            {
                return;
            }
            if (gibibytes < 0)
            {
                return;
            }
            try
            {
                minimumFreeBytes = (long)decimal.Truncate(gibibytes * 1073741824m);
            }
            catch (OverflowException)
            {
                minimumFreeBytes = -1;
            }
        }

        public bool ContainsUserSource(string sourcePath)
        {
            string normalized = NormalizePath(sourcePath);
            foreach (BackupSourceView source in Sources)
            {
                if (string.Equals(source.SourcePath, normalized, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            return false;
        }

        // The installed manager rewrites this file when the plan changes, so it is read in a way that never keeps that writer out:
        // File.ReadAllText shares for reading only, which makes a rewrite fail while the file is being read (and the read fail while
        // a rewrite is under way). A read that lands in the middle of a rewrite finds a document that is cut short, which the parse
        // rejects, so it is tried once more a moment later instead of reporting a configuration that is only mid-write. The size
        // limit is checked on the open handle, the text is decoded as File.ReadAllText decoded it, and Load validates the document
        // exactly as before.
        private static IDictionary<string, object> ReadConfigurationDocument(string configurationPath)
        {
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    string json;
                    using (FileStream stream = new FileStream(
                        configurationPath,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete,
                        4096,
                        FileOptions.SequentialScan))
                    {
                        if (stream.Length > MaximumConfigurationBytes)
                        {
                            throw new InvalidDataException("The backup configuration is unexpectedly large.");
                        }
                        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true, 4096, true))
                        {
                            json = reader.ReadToEnd();
                        }
                    }
                    IDictionary<string, object> document =
                        new JavaScriptSerializer().DeserializeObject(json) as IDictionary<string, object>;
                    if (document == null)
                    {
                        throw new InvalidDataException("The backup configuration is not a JSON object.");
                    }
                    return document;
                }
                catch (Exception error)
                {
                    if (attempt > 0 || !(error is IOException || error is ArgumentException))
                    {
                        throw;
                    }
                }
                Thread.Sleep(ConfigurationReadRetryMilliseconds);
            }
        }

        // Where the installed configuration is expected, for a message that says where Rewindle looked. Empty when it cannot be
        // worked out. Nothing is read.
        internal static string ExpectedConfigurationPath()
        {
            try
            {
                return Path.Combine(ResolveProtectedInstallRoot(), "backup-config.json");
            }
            catch (Exception)
            {
                return string.Empty;
            }
        }

        // The protected install root is the active engine's folder under Program Files (ResticBackuper for Rewindle,
        // ResticPersonalBackup for the legacy personal edition), where its installer puts it and where every other
        // component looks for it, so it follows that folder instead of assuming drive C. An unreadable Program Files
        // folder fails closed: a relative path must never become the root that protected paths are compared with.
        private static string ResolveProtectedInstallRoot()
        {
            return EngineProfile.Current.InstallRoot();
        }

        private static bool IsWithin(string candidate, string parent)
        {
            string normalizedCandidate = Path.GetFullPath(candidate)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string normalizedParent = Path.GetFullPath(parent)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            return normalizedCandidate.StartsWith(normalizedParent, StringComparison.OrdinalIgnoreCase);
        }

        internal static string NormalizePath(string value)
        {
            string fullPath = Path.GetFullPath(value);
            string root = Path.GetPathRoot(fullPath);
            if (!string.Equals(fullPath, root, StringComparison.OrdinalIgnoreCase))
            {
                fullPath = fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            }
            return fullPath;
        }

        private static long ReadPositiveInteger(
            IDictionary<string, object> document,
            string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) ||
                (value is int) == false && (value is long) == false)
            {
                throw new InvalidDataException(
                    "The backup configuration contains an invalid " + name + ".");
            }
            long parsed = Convert.ToInt64(value, CultureInfo.InvariantCulture);
            if (parsed <= 0)
            {
                throw new InvalidDataException(
                    "The backup configuration contains an invalid " + name + ".");
            }
            return parsed;
        }

        private static bool IsEightHex(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length != 8)
            {
                return false;
            }
            foreach (char item in value)
            {
                bool isHex = (item >= '0' && item <= '9') ||
                    (item >= 'a' && item <= 'f') ||
                    (item >= 'A' && item <= 'F');
                if (!isHex)
                {
                    return false;
                }
            }
            return true;
        }
    }

    internal sealed class SourceManagerResult
    {
        public bool Succeeded { get; private set; }
        public bool UserCancelled { get; private set; }
        public int ExitCode { get; private set; }
        public string PlanId { get; private set; }
        public long PreviousConfigGeneration { get; private set; }
        public long ConfigGeneration { get; private set; }
        public string ChangedPath { get; private set; }
        public string ErrorMessage { get; private set; }

        public static SourceManagerResult Success(
            string planId,
            long previousConfigGeneration,
            long configGeneration,
            string changedPath)
        {
            return new SourceManagerResult
            {
                Succeeded = true,
                ExitCode = 0,
                PlanId = planId,
                PreviousConfigGeneration = previousConfigGeneration,
                ConfigGeneration = configGeneration,
                ChangedPath = changedPath
            };
        }

        public static SourceManagerResult Cancelled()
        {
            return new SourceManagerResult { UserCancelled = true, ExitCode = 1223 };
        }

        public static SourceManagerResult Failure(string message, int exitCode)
        {
            return new SourceManagerResult { ErrorMessage = message, ExitCode = exitCode };
        }
    }

    internal static class SourceManagerLauncher
    {
        private static string RequestDomain
        {
            get { return EngineProfile.Current.SourceRequestDomain; }
        }


        public static SourceManagerResult Run(SourceConfiguration configuration, string action, string sourcePath)
        {
            return Run(configuration, action, sourcePath, null);
        }

        public static SourceManagerResult Run(
            SourceConfiguration configuration,
            string action,
            string sourcePath,
            Action onElevatedProcessStarted)
        {
            if (configuration == null)
            {
                return SourceManagerResult.Failure("Rewindle can't read its backup settings right now, so no folder was changed.", -1);
            }
            if (!string.Equals(action, "Add", StringComparison.Ordinal) &&
                !string.Equals(action, "Remove", StringComparison.Ordinal))
            {
                return SourceManagerResult.Failure("The requested source operation is invalid.", -1);
            }
            if (!Path.IsPathRooted(sourcePath))
            {
                return SourceManagerResult.Failure("The selected folder path is not absolute.", -1);
            }
            if (!File.Exists(configuration.ManagerPath))
            {
                return SourceManagerResult.Failure(
                    "Rewindle's folder tool is missing from this installation, so no folder was changed. " +
                        EngineProfile.Current.ReinstallAdvice(),
                    -1);
            }
            FileAttributes managerAttributes = File.GetAttributes(configuration.ManagerPath);
            if ((managerAttributes & FileAttributes.ReparsePoint) != 0)
            {
                return SourceManagerResult.Failure(
                    "Rewindle's folder tool is not a normal file, so no folder was changed. " + EngineProfile.Current.ReinstallAdvice(),
                    -1);
            }

            string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string powerShell = Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powerShell))
            {
                return SourceManagerResult.Failure(
                    "Windows PowerShell, which Rewindle needs to change folders, was not found in the Windows folder. No folder was changed.",
                    -1);
            }

            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            string userSid = identity.User == null ? null : identity.User.Value;
            if (string.IsNullOrEmpty(userSid))
            {
                return SourceManagerResult.Failure("Rewindle couldn't tell which Windows account you are using, so no folder was changed.", -1);
            }

            string normalizedSource = SourceConfiguration.NormalizePath(sourcePath);
            string requestNonce = ElevatedRequestSecurity.CreateNonce();
            string requestDigest = ComputeRequestDigest(
                userSid,
                action,
                normalizedSource,
                requestNonce);
            string resultRoot = EngineProfile.Current.StateResultDirectory("SourceManagerResults");
            string resultPath = Path.Combine(resultRoot, requestNonce + ".json");
            if (!IsResultTargetAvailable(resultPath))
            {
                return SourceManagerResult.Failure(
                    "Rewindle couldn't start this change safely. Nothing was changed; try again.",
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
                configuration.ManagerPath,
                "-" + action,
                normalizedSource,
                "-ExpectedUserSid",
                userSid,
                "-ResultPath",
                resultPath,
                "-RequestNonce",
                requestNonce
            };

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powerShell;
            startInfo.Arguments = ElevatedRequestSecurity.BuildArgumentString(arguments);
            startInfo.WorkingDirectory = configuration.InstallRoot;
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
                        return SourceManagerResult.Failure("Windows didn't start the change. Nothing was changed.", -1);
                    }
                    if (onElevatedProcessStarted != null)
                    {
                        try
                        {
                            onElevatedProcessStarted();
                        }
                        catch
                        {
                            // Presentation callbacks must never interrupt the protected manager.
                        }
                    }
                    process.WaitForExit();
                    return ReadBoundResult(
                        resultPath,
                        requestNonce,
                        requestDigest,
                        userSid,
                        action,
                        normalizedSource,
                        configuration.PlanId,
                        configuration.ConfigGeneration,
                        process.ExitCode);
                }
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode == 1223)
                {
                    return SourceManagerResult.Cancelled();
                }
                return SourceManagerResult.Failure(error.Message, error.NativeErrorCode);
            }
            catch (Exception error)
            {
                return SourceManagerResult.Failure(error.Message, -1);
            }
        }

        // The folder tool has already run when its result is read, so a result that can't be used leaves the change's outcome unknown:
        // the person is sent to the folder list, never told that nothing changed (a retry of an add or removal that did go through is
        // the mistake this avoids).
        private const string UnknownChangeOutcome = " Rewindle can't tell whether the change was made, so check the folder list before you try again.";

        private static SourceManagerResult ReadBoundResult(
            string resultPath,
            string requestNonce,
            string requestDigest,
            string userSid,
            string action,
            string sourcePath,
            string planId,
            long configGeneration,
            int exitCode)
        {
            for (int attempt = 0; attempt < 10 && !File.Exists(resultPath); attempt++)
            {
                Thread.Sleep(25);
            }
            if (!File.Exists(resultPath))
            {
                return SourceManagerResult.Failure(
                    "Windows didn't report how the change went (code " +
                        exitCode.ToString(CultureInfo.InvariantCulture) +
                        ")." + UnknownChangeOutcome,
                    exitCode);
            }
            string resultRoot = Path.GetDirectoryName(resultPath);
            string stateRoot = string.IsNullOrWhiteSpace(resultRoot)
                ? null
                : Path.GetDirectoryName(resultRoot);
            if (string.IsNullOrWhiteSpace(stateRoot) ||
                string.IsNullOrWhiteSpace(resultRoot) ||
                !Directory.Exists(stateRoot) ||
                !Directory.Exists(resultRoot) ||
                !string.Equals(
                    Path.GetFileName(stateRoot),
                    EngineProfile.Current.ProductDirectoryName,
                    StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(
                    Path.GetFileName(resultRoot),
                    "SourceManagerResults",
                    StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(
                    Path.GetFileName(resultPath),
                    requestNonce + ".json",
                    StringComparison.Ordinal) ||
                (File.GetAttributes(stateRoot) & FileAttributes.ReparsePoint) != 0 ||
                (File.GetAttributes(resultRoot) & FileAttributes.ReparsePoint) != 0 ||
                (File.GetAttributes(resultPath) & FileAttributes.ReparsePoint) != 0)
            {
                return SourceManagerResult.Failure(
                    "Rewindle's data folder looks unsafe, so the result of the change was not used." + UnknownChangeOutcome + " " + EngineProfile.Current.ReinstallAdvice(),
                    exitCode);
            }
            if (!ElevatedRequestSecurity.HasProtectedResultAcl(stateRoot, userSid, true))
            {
                return SourceManagerResult.Failure(
                    "Rewindle's data folder has unexpected permissions, so the result of the change was not used." + UnknownChangeOutcome + " " + EngineProfile.Current.ReinstallAdvice(),
                    exitCode);
            }
            if (!ElevatedRequestSecurity.HasProtectedResultAcl(resultRoot, userSid, true))
            {
                return SourceManagerResult.Failure(
                    "Rewindle's data folder has unexpected permissions, so the result of the change was not used." + UnknownChangeOutcome + " " + EngineProfile.Current.ReinstallAdvice(),
                    exitCode);
            }

            try
            {
                // Omitting delete sharing means the validated file cannot be replaced
                // between its ACL check and read. Validate ACL from this same handle.
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
                        return SourceManagerResult.Failure(
                            "Rewindle's data folder has unexpected permissions, so the result of the change was not used." + UnknownChangeOutcome + " " + EngineProfile.Current.ReinstallAdvice(),
                            exitCode);
                    }
                    if (stream.Length <= 0 || stream.Length > 64 * 1024)
                    {
                        return SourceManagerResult.Failure(
                            "Windows gave an unreadable answer, so it was not used." + UnknownChangeOutcome,
                            exitCode);
                    }

                    using (StreamReader reader = new StreamReader(
                        stream,
                        new UTF8Encoding(false, true),
                        true,
                        4096,
                        true))
                    {
                        return ValidateBoundResultDocument(
                            reader.ReadToEnd(),
                            requestNonce,
                            requestDigest,
                            userSid,
                            action,
                            sourcePath,
                            planId,
                            configGeneration,
                            exitCode);
                    }
                }
            }
            catch (Exception error)
            {
                return SourceManagerResult.Failure(
                    "Rewindle couldn't verify Windows' answer (" + SanitizeError(error.Message).TrimEnd('.') + "), so it was not used." +
                        UnknownChangeOutcome,
                    exitCode);
            }
        }

        private static SourceManagerResult ValidateBoundResultDocument(
            string json,
            string requestNonce,
            string requestDigest,
            string userSid,
            string action,
            string sourcePath,
            string planId,
            long configGeneration,
            int exitCode)
        {
            try
            {
                IDictionary<string, object> document =
                    new JavaScriptSerializer().DeserializeObject(json) as
                        IDictionary<string, object>;
                if (document == null || ReadInteger(document, "schema_version") != 1 ||
                    !ElevatedRequestSecurity.FixedEquals(ReadString(document, "request_nonce"), requestNonce) ||
                    !ElevatedRequestSecurity.FixedEquals(ReadString(document, "request_digest"), requestDigest) ||
                    !ElevatedRequestSecurity.FixedEquals(ReadString(document, "request_user_sid"), userSid) ||
                    !ElevatedRequestSecurity.FixedEquals(
                        ReadString(document, "action"),
                        action.ToLowerInvariant()))
                {
                    return SourceManagerResult.Failure(
                        "Windows' answer didn't match this request, so it was not used." + UnknownChangeOutcome,
                        exitCode);
                }

                bool ok = ReadBoolean(document, "ok");
                if (ok && exitCode == 0)
                {
                    string reportedPlanId = ReadString(document, "plan_id");
                    long previousGeneration = ReadInteger64(
                        document,
                        "previous_config_generation");
                    long reportedGeneration = ReadInteger64(
                        document,
                        "config_generation");
                    string changedPath = ReadString(document, "path");
                    if (!ElevatedRequestSecurity.FixedEquals(reportedPlanId, planId) ||
                        previousGeneration != configGeneration ||
                        configGeneration == long.MaxValue ||
                        reportedGeneration != configGeneration + 1 ||
                        !string.Equals(changedPath, sourcePath, StringComparison.Ordinal))
                    {
                        return SourceManagerResult.Failure(
                            "Rewindle's backup settings changed in an unexpected way, so the result was not used." + UnknownChangeOutcome,
                            exitCode);
                    }
                    return SourceManagerResult.Success(
                        reportedPlanId,
                        previousGeneration,
                        reportedGeneration,
                        changedPath);
                }
                if (!ok && exitCode != 0)
                {
                    return SourceManagerResult.Failure(
                        SanitizeError(ReadOptionalString(document, "error")),
                        exitCode);
                }
                return SourceManagerResult.Failure(
                    "Windows' answer was unclear, so it was not used." + UnknownChangeOutcome,
                    exitCode);
            }
            catch (Exception error)
            {
                return SourceManagerResult.Failure(
                    "Rewindle couldn't verify Windows' answer (" + SanitizeError(error.Message).TrimEnd('.') + "), so it was not used." +
                        UnknownChangeOutcome,
                    exitCode);
            }
        }

        private static bool IsResultTargetAvailable(string resultPath)
        {
            return !File.Exists(resultPath) && !Directory.Exists(resultPath);
        }

        private static string ComputeRequestDigest(
            string userSid,
            string action,
            string canonicalPath,
            string nonce)
        {
            string payload = RequestDomain + "\n" + userSid + "\n" +
                action.ToLowerInvariant() + "\n" + canonicalPath + "\n" + nonce;
            using (SHA256 algorithm = SHA256.Create())
            {
                return ToLowerHex(algorithm.ComputeHash(new UTF8Encoding(false).GetBytes(payload)));
            }
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

        private static int ReadInteger(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value))
            {
                throw new InvalidDataException("Result field is missing: " + name);
            }
            return Convert.ToInt32(value, CultureInfo.InvariantCulture);
        }

        private static long ReadInteger64(
            IDictionary<string, object> document,
            string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) ||
                (!(value is int) && !(value is long)))
            {
                throw new InvalidDataException(
                    "Result field is missing or invalid: " + name);
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

        private static string SanitizeError(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return "The folder change failed.";
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
                ? "The folder change failed."
                : sanitized;
        }
    }
}
