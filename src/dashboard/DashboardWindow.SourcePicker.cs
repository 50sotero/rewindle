using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Forms;

namespace ResticBackuper.Dashboard
{
    public partial class DashboardWindow
    {
        private sealed class SourcePickerSuggestion
        {
            public string Name;
            public string Path;
            public bool Protected;
        }

        private sealed class SourcePickerValidation
        {
            public string Status;
            public string Path;
            public string Name;
            public string Message;
        }

        private bool sourcePickerOpen;
        private bool sourcePickerBusy;
        private int sourcePickerValidationGeneration;
        private string sourcePickerPath = string.Empty;
        private string sourcePickerName = string.Empty;
        private string sourcePickerStatus = "idle";
        private string sourcePickerMessage = string.Empty;
        private long sourcePickerConfigGeneration;
        private string sourcePickerPlanId = string.Empty;
        private List<SourcePickerSuggestion> sourcePickerSuggestions =
            new List<SourcePickerSuggestion>();

        // False, with the reason, when the chooser could not be opened. The page waits for the answer to its command, so a refusal
        // that is only written into the folder notice would read to it as a chooser that opened.
        private bool TryOpenSourcePicker(out string error)
        {
            error = string.Empty;
            if (sourcePickerOpen)
            {
                if (sourcePickerBusy)
                {
                    PublishWebPresentationState();
                    return true;
                }
                ResetSourcePicker();
            }

            if (!CanOpenSourcePicker(out error))
            {
                SetSourceNotice(error, Amber, 10);
                return false;
            }

            sourcePickerOpen = true;
            sourcePickerBusy = false;
            sourcePickerValidationGeneration++;
            sourcePickerPath = string.Empty;
            sourcePickerName = string.Empty;
            sourcePickerStatus = "idle";
            sourcePickerMessage =
                "Choose a folder to back up. Nothing changes until you check it and choose Yes in the Windows permission prompt." +
                DescribeOneDriveKnownFolders(KnownFoldersInOneDrive());
            sourcePickerConfigGeneration = currentSourceConfiguration.ConfigGeneration;
            sourcePickerPlanId = currentSourceConfiguration.PlanId ?? string.Empty;
            sourcePickerSuggestions = BuildSourcePickerSuggestions(currentSourceConfiguration);
            PublishWebPresentationState();
            return true;
        }

        private bool CanOpenSourcePicker(out string error)
        {
            if (currentSourceConfiguration == null)
            {
                error = "Rewindle can't read its backup settings right now.";
                return false;
            }
            if (sourceOperationInProgress || BackupBlocksSourceChanges())
            {
                error = "Wait for the current backup or settings change to finish before choosing a folder.";
                return false;
            }
            error = string.Empty;
            return true;
        }

        private bool BrowseSourcePicker(out string error)
        {
            error = string.Empty;
            if (!sourcePickerOpen)
            {
                error = "Open the folder chooser before browsing for a folder.";
                return false;
            }
            if (sourcePickerBusy)
            {
                error = "The folder choice is still being checked.";
                return false;
            }

            string path;
            try
            {
                path = ShowModernFolderPicker();
            }
            catch (Exception exception)
            {
                error = "Windows' folder browser couldn't open. Type or paste the folder path instead.";
                return false;
            }
            if (string.IsNullOrWhiteSpace(path))
            {
                return true;
            }
            BeginSourcePickerValidation(path, out error);
            return string.IsNullOrWhiteSpace(error);
        }

        private bool BeginSourcePickerValidation(string path, out string error)
        {
            error = string.Empty;
            if (!sourcePickerOpen)
            {
                error = "Open the folder chooser before checking a folder.";
                return false;
            }
            if (sourcePickerBusy)
            {
                error = "The folder choice is already being checked.";
                return false;
            }
            if (path == null || path.Trim().Length == 0 || path.Trim().Length > 4096)
            {
                error = "Type or paste a folder path such as C:\\Users\\you\\Documents.";
                return false;
            }

            string requestedPath = path.Trim();
            int generation = ++sourcePickerValidationGeneration;
            sourcePickerBusy = true;
            sourcePickerPath = requestedPath;
            sourcePickerName = string.Empty;
            sourcePickerStatus = "checking";
            sourcePickerMessage = "Checking the folder and its drive…";
            SourceConfiguration configuration = currentSourceConfiguration;
            sourcePickerConfigGeneration = configuration == null
                ? 0
                : configuration.ConfigGeneration;
            sourcePickerPlanId = configuration == null ? string.Empty : configuration.PlanId ?? string.Empty;
            PublishWebPresentationState();

            CompleteSourcePickerValidation(configuration, requestedPath, generation);
            return true;
        }

        private async void CompleteSourcePickerValidation(
            SourceConfiguration configuration,
            string requestedPath,
            int generation)
        {
            SourcePickerValidation result;
            try
            {
                result = await Task.Run(delegate
                {
                    return ValidateSourcePickerPath(configuration, requestedPath);
                });
            }
            catch
            {
                result = new SourcePickerValidation
                {
                    Status = "invalid",
                    Path = requestedPath,
                    Message = "The folder could not be checked. Try again."
                };
            }
            if (!sourcePickerOpen || generation != sourcePickerValidationGeneration)
            {
                return;
            }
            sourcePickerBusy = false;
            sourcePickerPath = result.Path ?? requestedPath;
            sourcePickerName = result.Name ?? string.Empty;
            sourcePickerStatus = result.Status ?? "invalid";
            sourcePickerMessage = result.Message ?? string.Empty;
            PublishWebPresentationState();
        }

        private SourcePickerValidation ValidateSourcePickerPath(
            SourceConfiguration configuration,
            string requestedPath)
        {
            string normalized;
            try
            {
                if (requestedPath.StartsWith("\\\\", StringComparison.Ordinal) ||
                    !Path.IsPathRooted(requestedPath))
                {
                    return InvalidSourcePickerPath(
                        requestedPath,
                        "Use a folder on this PC, such as C:\\Users\\you\\Documents.");
                }
                string root = Path.GetPathRoot(requestedPath);
                if (string.IsNullOrWhiteSpace(root) ||
                    root.Length != 3 || root[1] != ':' || root[2] != '\\')
                {
                    return InvalidSourcePickerPath(
                        requestedPath,
                        "Rewindle can only back up folders on this PC's own drives (like C: or D:), not network folders.");
                }
                normalized = SourceConfiguration.NormalizePath(requestedPath);
            }
            catch
            {
                return InvalidSourcePickerPath(requestedPath, "That folder path is not valid.");
            }

            if (!Directory.Exists(normalized))
            {
                return InvalidSourcePickerPath(
                    normalized,
                    "That folder is not available on this computer.");
            }
            if (!HasNormalDirectoryChain(normalized))
            {
                return InvalidSourcePickerPath(
                    normalized,
                    IsInsideOneDrive(normalized)
                        ? "This folder is inside OneDrive, and Rewindle can't back up OneDrive folders yet. " +
                            "Choose a folder that isn't in OneDrive, or move the files out of OneDrive first."
                        : "This folder (or a folder above it) is a link that Rewindle won't follow. Choose the real folder instead.");
            }

            try
            {
                DriveInfo drive = new DriveInfo(Path.GetPathRoot(normalized));
                if (!drive.IsReady ||
                    (drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable))
                {
                    return InvalidSourcePickerPath(
                        normalized,
                        "That folder is on a drive that isn't ready, or isn't a hard drive or USB drive on this PC, so it can't be backed up.");
                }
            }
            catch
            {
                return InvalidSourcePickerPath(
                    normalized,
                    "Rewindle couldn't check the drive this folder is on.");
            }

            if (configuration == null)
            {
                return InvalidSourcePickerPath(
                    normalized,
                    "Rewindle can't read its backup settings right now. Try again.");
            }

            foreach (BackupSourceView source in configuration.Sources)
            {
                if (string.Equals(source.SourcePath, normalized, StringComparison.OrdinalIgnoreCase))
                {
                    return new SourcePickerValidation
                    {
                        Status = "duplicate",
                        Path = normalized,
                        Name = source.DisplayName,
                        Message = source.IsProtectedCanary
                            ? "This is Rewindle's own restore-test folder. It is always included, so there is nothing to add."
                            : "This folder is already in your backup. Choose a different folder."
                    };
                }
                if (IsWithinPath(normalized, source.SourcePath) ||
                    IsWithinPath(source.SourcePath, normalized))
                {
                    if (IsWithinPath(normalized, source.SourcePath))
                    {
                        return new SourcePickerValidation
                        {
                            Status = "covered",
                            Path = normalized,
                            Name = new BackupSourceView(normalized, false).DisplayName,
                            Message = "This folder is already included because it is inside \"" +
                                source.DisplayName + "\". You don't need to add it."
                        };
                    }
                    return new SourcePickerValidation
                    {
                        Status = "invalid",
                        Path = normalized,
                        Name = new BackupSourceView(normalized, false).DisplayName,
                        Message = "This folder contains \"" + source.DisplayName + "\", which is already in your backup. " +
                            "To back up the larger folder instead, remove \"" + source.DisplayName +
                            "\" (and any other folders inside this one) first, then add this one."
                    };
                }
            }

            foreach (string protectedPath in GetSourcePickerProtectedPaths(configuration))
            {
                if (IsWithinPath(normalized, protectedPath) ||
                    IsWithinPath(protectedPath, normalized))
                {
                    return InvalidSourcePickerPath(
                        normalized,
                        "This folder is where Rewindle keeps its own files or your backups, so it can't be backed up. Choose a different folder.");
                }
            }

            // The backup refuses a folder that holds files kept only in the cloud (its "strict" policy), so say so now, not on the first
            // backup. The walk is bounded: a folder too big to finish in time is let through, never refused on a guess.
            OnlineOnlyScan onlineOnly = ScanForOnlineOnly(
                normalized,
                ReadExcludedFolderNames(configuration),
                OnlineOnlyScanEntryLimit,
                OnlineOnlyScanTimeLimit,
                delegate(FileSystemInfo entry) { return entry.Attributes; });
            if (onlineOnly.Found)
            {
                return InvalidSourcePickerPath(
                    normalized,
                    "Some files in this folder are stored only in the cloud (OneDrive or a similar app). Rewindle can only back up files that are on this PC, " +
                    "so backups of this folder would fail. In that app, right-click the folder, choose \"Always keep on this device\", " +
                    "wait for the files to download, then choose Check folder.");
            }

            BackupSourceView view = new BackupSourceView(normalized, false);
            return new SourcePickerValidation
            {
                Status = "ready",
                Path = normalized,
                Name = view.DisplayName,
                Message = "Ready to add. After you choose Add folder, Windows asks for your permission (\"Do you want to allow this app to make changes to your device?\"). " +
                    "It may say \"Windows PowerShell\": that is Rewindle's helper, so choose Yes. No backup starts now."
            };
        }

        private static SourcePickerValidation InvalidSourcePickerPath(string path, string message)
        {
            return new SourcePickerValidation
            {
                Status = "invalid",
                Path = path ?? string.Empty,
                Name = string.Empty,
                Message = message
            };
        }

        private static bool HasNormalDirectoryChain(string path)
        {
            try
            {
                DirectoryInfo current = new DirectoryInfo(path);
                while (current != null)
                {
                    if ((current.Attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        return false;
                    }
                    current = current.Parent;
                }
                return true;
            }
            catch
            {
                return false;
            }
        }

        // Whether `path` is, or is below, one of OneDrive's folders. The roots are the ones Windows names in the environment; a business
        // account's folder ("OneDrive - Company") is OneDriveCommercial.
        private static bool IsInsideOneDrive(string path)
        {
            return IsInsideOneDrive(path, OneDriveRoots());
        }

        internal static bool IsInsideOneDrive(string path, IEnumerable<string> oneDriveRoots)
        {
            if (oneDriveRoots == null)
            {
                return false;
            }
            foreach (string root in oneDriveRoots)
            {
                if (!string.IsNullOrWhiteSpace(root) && IsWithinPath(path, root))
                {
                    return true;
                }
            }
            return false;
        }

        private static string[] OneDriveRoots()
        {
            return new[]
            {
                Environment.GetEnvironmentVariable("OneDrive"),
                Environment.GetEnvironmentVariable("OneDriveConsumer"),
                Environment.GetEnvironmentVariable("OneDriveCommercial")
            };
        }

        // The usual folders that OneDrive keeps (its "backup this folder" option moves them there), by the name the picker gives them.
        private static List<string> KnownFoldersInOneDrive()
        {
            List<string> names = new List<string>();
            string[,] known =
            {
                { "Desktop", Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) },
                { "Documents", Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) },
                { "Pictures", Environment.GetFolderPath(Environment.SpecialFolder.MyPictures) },
                { "Music", Environment.GetFolderPath(Environment.SpecialFolder.MyMusic) },
                { "Videos", Environment.GetFolderPath(Environment.SpecialFolder.MyVideos) }
            };
            for (int index = 0; index < known.GetLength(0); index++)
            {
                if (!string.IsNullOrWhiteSpace(known[index, 1]) && IsInsideOneDrive(known[index, 1]))
                {
                    names.Add(known[index, 0]);
                }
            }
            return names;
        }

        // The sentence added to the opening message when some usual folders are missing from the quick locations because OneDrive keeps them.
        internal static string DescribeOneDriveKnownFolders(IList<string> names)
        {
            if (names == null || names.Count == 0)
            {
                return string.Empty;
            }
            string list = names.Count == 1
                ? names[0]
                : string.Join(", ", names.Take(names.Count - 1).ToArray()) + " and " + names[names.Count - 1];
            return " Your " + list + (names.Count == 1 ? " folder is" : " folders are") +
                " inside OneDrive, which Rewindle can't back up yet, so " + (names.Count == 1 ? "it isn't" : "they aren't") + " listed.";
        }

        // What Windows sets on a file or folder whose content is only in the cloud (OneDrive and similar), as the backup's own preflight and
        // Setup's folder check read it (CLOUD_ONLY_ATTRIBUTE_MASK in restic_common.py): recall on open, recall on data access, offline.
        private const FileAttributes OnlineOnlyAttributes = (FileAttributes)0x00040000 | (FileAttributes)0x00400000 | FileAttributes.Offline;
        private const int OnlineOnlyScanEntryLimit = 20000;
        private static readonly TimeSpan OnlineOnlyScanTimeLimit = TimeSpan.FromSeconds(2);

        internal sealed class OnlineOnlyScan
        {
            // A file or folder that is only in the cloud was seen.
            public bool Found;
            // How many entries were looked at.
            public int Scanned;
            // Everything below the folder was looked at. False when the entry or time limit stopped the walk first; Found then says only
            // what was seen so far, and the caller does not treat the folder as refused for what it did not get to see.
            public bool Complete;
        }

        internal static bool IsOnlineOnly(FileAttributes attributes)
        {
            return (attributes & OnlineOnlyAttributes) != 0;
        }

        // The whole-folder rules of the backup's excludes.txt that name one folder wherever it is ("**/node_modules"), so the walk skips
        // what the backup skips. Anything more elaborate is not used, and those folders are looked at as usual.
        internal static HashSet<string> ParseExcludedFolderNames(IEnumerable<string> lines)
        {
            HashSet<string> names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (lines == null)
            {
                return names;
            }
            foreach (string raw in lines)
            {
                string line = (raw ?? string.Empty).Trim().Replace('\\', '/').TrimEnd('/');
                if (!line.StartsWith("**/", StringComparison.Ordinal))
                {
                    continue;
                }
                string name = line.Substring(3);
                if (name.Length == 0 || name.IndexOfAny(new[] { '/', '*', '?', '[', '!' }) >= 0)
                {
                    continue;
                }
                names.Add(name);
            }
            return names;
        }

        private static HashSet<string> ReadExcludedFolderNames(SourceConfiguration configuration)
        {
            try
            {
                string path = Path.Combine(configuration.InstallRoot, "excludes.txt");
                return ParseExcludedFolderNames(File.Exists(path) ? File.ReadAllLines(path) : null);
            }
            catch
            {
                return new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            }
        }

        // A bounded walk of `root` for a file or folder that is only in the cloud. It stops at the first one, after `entryLimit` entries or
        // after `timeLimit`, whichever comes first. A link is not followed (its target is somewhere else), and a folder that cannot be opened
        // is skipped. `attributesOf` is how an entry's attributes are read, so a test can supply them.
        internal static OnlineOnlyScan ScanForOnlineOnly(
            string root,
            ISet<string> skippedFolderNames,
            int entryLimit,
            TimeSpan timeLimit,
            Func<FileSystemInfo, FileAttributes> attributesOf)
        {
            OnlineOnlyScan scan = new OnlineOnlyScan();
            System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
            Stack<DirectoryInfo> pending = new Stack<DirectoryInfo>();
            try
            {
                DirectoryInfo start = new DirectoryInfo(root);
                if (IsOnlineOnly(attributesOf(start)))
                {
                    scan.Found = true;
                    return scan;
                }
                pending.Push(start);
            }
            catch
            {
                return scan;
            }
            while (pending.Count > 0)
            {
                DirectoryInfo directory = pending.Pop();
                try
                {
                    foreach (FileSystemInfo entry in directory.EnumerateFileSystemInfos())
                    {
                        if (scan.Scanned >= entryLimit || clock.Elapsed >= timeLimit)
                        {
                            return scan;
                        }
                        scan.Scanned++;
                        FileAttributes attributes = attributesOf(entry);
                        bool folder = (attributes & FileAttributes.Directory) != 0;
                        if (folder && skippedFolderNames != null && skippedFolderNames.Contains(entry.Name))
                        {
                            continue;
                        }
                        if (IsOnlineOnly(attributes))
                        {
                            scan.Found = true;
                            return scan;
                        }
                        if (folder && (attributes & FileAttributes.ReparsePoint) == 0)
                        {
                            pending.Push((DirectoryInfo)entry);
                        }
                    }
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
            scan.Complete = true;
            return scan;
        }

        private static bool IsWithinPath(string candidate, string parent)
        {
            if (string.IsNullOrWhiteSpace(candidate) || string.IsNullOrWhiteSpace(parent))
            {
                return false;
            }
            try
            {
                string normalizedCandidate = SourceConfiguration.NormalizePath(candidate);
                string normalizedParent = SourceConfiguration.NormalizePath(parent);
                string parentPrefix = normalizedParent.EndsWith(
                        Path.DirectorySeparatorChar.ToString(),
                        StringComparison.Ordinal) ||
                    normalizedParent.EndsWith(
                        Path.AltDirectorySeparatorChar.ToString(),
                        StringComparison.Ordinal)
                    ? normalizedParent
                    : normalizedParent + Path.DirectorySeparatorChar;
                return string.Equals(normalizedCandidate, normalizedParent, StringComparison.OrdinalIgnoreCase) ||
                    normalizedCandidate.StartsWith(
                        parentPrefix,
                        StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private static IEnumerable<string> GetSourcePickerProtectedPaths(SourceConfiguration configuration)
        {
            yield return configuration.RepositoryPath;
            yield return configuration.InstallRoot;
            yield return configuration.StateDirectory;
            yield return configuration.ManagerPath;
            string repositoryParent = null;
            try
            {
                DirectoryInfo parent = Directory.GetParent(configuration.RepositoryPath);
                repositoryParent = parent == null ? null : parent.FullName;
            }
            catch
            {
                repositoryParent = null;
            }
            if (!string.IsNullOrWhiteSpace(repositoryParent))
            {
                yield return Path.Combine(repositoryParent, "RecoveryTools");
            }
            string protectedRecoveryTools = EngineProfile.Current.ProtectedRecoveryToolsDirectory();
            if (!string.IsNullOrWhiteSpace(protectedRecoveryTools))
            {
                yield return protectedRecoveryTools;
            }
            foreach (string topologyPath in ReadConfiguredTopologyPaths(configuration.ConfigurationPath))
            {
                yield return topologyPath;
            }
        }

        private static IEnumerable<string> ReadConfiguredTopologyPaths(string configurationPath)
        {
            List<string> paths = new List<string>();
            if (string.IsNullOrWhiteSpace(configurationPath) ||
                !File.Exists(configurationPath))
            {
                return paths;
            }
            try
            {
                string json = File.ReadAllText(configurationPath);
                IDictionary<string, object> document =
                    new JavaScriptSerializer().DeserializeObject(json) as IDictionary<string, object>;
                // The recovery tools are a repository sibling for a local repository but a protected ProgramData folder for a
                // streamed Google Drive one (the Rewindle engine's DriveFS mode), so the configured folder is used as well.
                object recoveryToolsValue;
                string recoveryTools = document != null &&
                    document.TryGetValue("recovery_tools_directory", out recoveryToolsValue)
                        ? recoveryToolsValue as string
                        : null;
                if (!string.IsNullOrWhiteSpace(recoveryTools) && Path.IsPathRooted(recoveryTools))
                {
                    try { paths.Add(SourceConfiguration.NormalizePath(recoveryTools)); }
                    catch { }
                }
                object topologyValue;
                IDictionary<string, object> topology = document != null &&
                    document.TryGetValue("topology_paths", out topologyValue)
                        ? topologyValue as IDictionary<string, object>
                        : null;
                if (topology == null)
                {
                    return paths;
                }
                foreach (object rawPath in topology.Values)
                {
                    string path = rawPath as string;
                    if (string.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path))
                    {
                        continue;
                    }
                    string normalized;
                    try { normalized = SourceConfiguration.NormalizePath(path); }
                    catch { continue; }
                    paths.Add(normalized);
                }
            }
            catch
            {
            }
            return paths;
        }

        private static List<SourcePickerSuggestion> BuildSourcePickerSuggestions(
            SourceConfiguration configuration)
        {
            string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            List<SourcePickerSuggestion> result = new List<SourcePickerSuggestion>();
            AddSourcePickerSuggestion(result, configuration, "Desktop", Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory));
            AddSourcePickerSuggestion(result, configuration, "Documents", Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments));
            AddSourcePickerSuggestion(result, configuration, "Downloads", Path.Combine(userProfile, "Downloads"));
            AddSourcePickerSuggestion(result, configuration, "Pictures", Environment.GetFolderPath(Environment.SpecialFolder.MyPictures));
            AddSourcePickerSuggestion(result, configuration, "Music", Environment.GetFolderPath(Environment.SpecialFolder.MyMusic));
            AddSourcePickerSuggestion(result, configuration, "Videos", Environment.GetFolderPath(Environment.SpecialFolder.MyVideos));
            AddSourcePickerSuggestion(result, configuration, "Home folder", userProfile);
            return result;
        }

        private static void AddSourcePickerSuggestion(
            List<SourcePickerSuggestion> suggestions,
            SourceConfiguration configuration,
            string name,
            string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
            {
                return;
            }
            string normalized;
            try { normalized = SourceConfiguration.NormalizePath(path); }
            catch { return; }
            if (suggestions.Any(item => string.Equals(item.Path, normalized, StringComparison.OrdinalIgnoreCase)))
            {
                return;
            }
            // A usual folder that sits inside OneDrive (or behind a link) is refused when it is checked, so it is not offered; the opening
            // message says why (see KnownFoldersInOneDrive).
            if (!HasNormalDirectoryChain(normalized))
            {
                return;
            }
            if (configuration != null && configuration.Sources.Any(
                source => !string.Equals(source.SourcePath, normalized, StringComparison.OrdinalIgnoreCase) &&
                    IsWithinPath(source.SourcePath, normalized)))
            {
                return;
            }
            bool protectedPath = configuration != null && configuration.Sources.Any(
                source => IsWithinPath(normalized, source.SourcePath));
            suggestions.Add(new SourcePickerSuggestion
            {
                Name = name,
                Path = normalized,
                Protected = protectedPath
            });
        }

        private bool ConfirmSourcePicker(string path, out string error)
        {
            error = string.Empty;
            if (!sourcePickerOpen)
            {
                error = "Open the folder chooser before confirming a folder.";
                return false;
            }
            if (sourcePickerBusy)
            {
                error = "Wait for the current folder operation to finish.";
                return false;
            }
            if (string.IsNullOrWhiteSpace(path) ||
                !string.Equals(path, sourcePickerPath, StringComparison.Ordinal))
            {
                error = "Check this folder first, then choose Add folder.";
                return false;
            }
            if (!string.Equals(sourcePickerStatus, "ready", StringComparison.Ordinal))
            {
                error = "This folder isn't ready to add yet. Check it again.";
                return false;
            }
            try
            {
                currentSourceConfiguration = SourceConfiguration.Load();
            }
            catch
            {
                error = "Rewindle couldn't re-read its backup settings. Check the folder again before adding it.";
                sourcePickerStatus = "invalid";
                sourcePickerMessage = error;
                PublishWebPresentationState();
                return false;
            }
            if (currentSourceConfiguration == null ||
                !string.Equals(currentSourceConfiguration.PlanId, sourcePickerPlanId, StringComparison.Ordinal) ||
                currentSourceConfiguration.ConfigGeneration != sourcePickerConfigGeneration)
            {
                error = "Your backup settings changed while you were looking at this folder. Check it again.";
                sourcePickerStatus = "invalid";
                sourcePickerMessage = error;
                PublishWebPresentationState();
                return false;
            }
            if (BackupBlocksSourceChanges() || sourceOperationInProgress)
            {
                error = "A backup or settings change is running. Try again when it finishes.";
                sourcePickerStatus = "failed";
                sourcePickerMessage = error;
                PublishWebPresentationState();
                return false;
            }

            sourcePickerBusy = true;
            sourcePickerStatus = "busy";
            sourcePickerMessage = "Waiting for you to answer the Windows permission prompt. If you can't see it, look for a flashing icon on the taskbar. Nothing changes unless you choose Yes…";
            PublishWebPresentationState();
            ConfirmSourcePickerAsync(path);
            return true;
        }

        private async void ConfirmSourcePickerAsync(string path)
        {
            try
            {
                await ApplySourceChange("Add", path);
            }
            catch (Exception error)
            {
                sourceOperationStage = SourceOperationStage.Failed;
                sourceOperationError = error.Message;
            }
            sourcePickerBusy = false;
            if (sourceOperationStage == SourceOperationStage.Succeeded &&
                currentSourceConfiguration != null &&
                currentSourceConfiguration.ContainsUserSource(path))
            {
                sourcePickerStatus = "succeeded";
                sourcePickerMessage = "Folder added. It will be included in your next backup. Nothing was backed up just now.";
            }
            else if (sourceOperationStage == SourceOperationStage.Cancelled)
            {
                sourcePickerStatus = "cancelled";
                sourcePickerMessage = "You didn't allow the change in the Windows permission prompt, so nothing changed. Choose Try again to check the folder and add it, or choose another folder.";
            }
            else
            {
                sourcePickerStatus = "failed";
                sourcePickerMessage = "The folder wasn't added and nothing changed. Choose Try again to check it and add it again. " +
                    "If it keeps failing, restart Rewindle, or use Export diagnostics in Settings and send the file when you ask for help." +
                    (string.IsNullOrWhiteSpace(sourceOperationError)
                        ? string.Empty
                        : " (Technical detail: " + sourceOperationError + ")");
            }
            PublishWebPresentationState();
        }

        private bool CloseSourcePicker(out string error)
        {
            error = string.Empty;
            if (sourceOperationInProgress ||
                (sourcePickerBusy && string.Equals(sourcePickerStatus, "busy", StringComparison.Ordinal)))
            {
                error = "Wait for the folder change to finish before closing this window.";
                return false;
            }
            ResetSourcePicker();
            PublishWebPresentationState();
            return true;
        }

        private void ResetSourcePicker()
        {
            sourcePickerOpen = false;
            sourcePickerBusy = false;
            sourcePickerValidationGeneration++;
            sourcePickerPath = string.Empty;
            sourcePickerName = string.Empty;
            sourcePickerStatus = "idle";
            sourcePickerMessage = string.Empty;
            sourcePickerConfigGeneration = 0;
            sourcePickerPlanId = string.Empty;
            sourcePickerSuggestions.Clear();
        }

        private string ShowModernFolderPicker()
        {
            return ShowModernFolderPicker(
                "Choose a folder to back up",
                "Choose folder",
                "Choose a folder to back up.");
        }

        private string ShowModernFolderPicker(
            string title,
            string okButtonLabel,
            string legacyDescription)
        {
            return PickFolder(
                new WindowInteropHelper(this).Handle,
                title,
                okButtonLabel,
                legacyDescription);
        }

        // The folder chooser of the add-folder and restore-destination steps and of the backup-location window, which is a window
        // of its own: it is static and takes its owner as a handle for that reason, and it lives here because the shell interop
        // types it drives are private to this class. It is the picker Windows shows everywhere else (address bar, search, a
        // window that can be resized), and it only ever returns a file system folder (FOS_FORCEFILESYSTEM), never a library or
        // another virtual folder. What comes back is only a suggestion: the caller still checks it, and the protected manager
        // checks it again. An empty string means the person cancelled.
        internal static string PickFolder(
            IntPtr owner,
            string title,
            string okButtonLabel,
            string legacyDescription)
        {
            try
            {
                IFileOpenDialog dialog = CreateFileOpenDialog();
                try
                {
                    uint options;
                    if (dialog.GetOptions(out options) < 0)
                    {
                        options = 0;
                    }
                    options |= FileOpenDialogOptions.PickFolders |
                        FileOpenDialogOptions.ForceFileSystem |
                        FileOpenDialogOptions.PathMustExist |
                        FileOpenDialogOptions.NoChangeDirectory;
                    dialog.SetOptions(options);
                    dialog.SetTitle(title);
                    dialog.SetOkButtonLabel(okButtonLabel);
                    int result = dialog.Show(owner);
                    if (result == HResult.Cancelled)
                    {
                        return string.Empty;
                    }
                    if (result < 0)
                    {
                        Marshal.ThrowExceptionForHR(result);
                    }
                    IShellItem item;
                    int getResult = dialog.GetResult(out item);
                    if (getResult < 0)
                    {
                        Marshal.ThrowExceptionForHR(getResult);
                    }
                    try
                    {
                        IntPtr displayName;
                        int displayResult = item.GetDisplayName(
                            ShellItemDisplayName.DesktopAbsoluteParsing,
                            out displayName);
                        if (displayResult < 0)
                        {
                            Marshal.ThrowExceptionForHR(displayResult);
                        }
                        try
                        {
                            return Marshal.PtrToStringUni(displayName);
                        }
                        finally
                        {
                            if (displayName != IntPtr.Zero)
                            {
                                Marshal.FreeCoTaskMem(displayName);
                            }
                        }
                    }
                    finally
                    {
                        if (item != null && Marshal.IsComObject(item))
                        {
                            Marshal.FinalReleaseComObject(item);
                        }
                    }
                }
                finally
                {
                    if (Marshal.IsComObject(dialog))
                    {
                        Marshal.FinalReleaseComObject(dialog);
                    }
                }
            }
            catch (COMException)
            {
                return ShowLegacyFolderPicker(owner, legacyDescription);
            }
            catch (InvalidCastException)
            {
                return ShowLegacyFolderPicker(owner, legacyDescription);
            }
        }

        private string ShowLegacyFolderPicker()
        {
            return ShowLegacyFolderPicker(
                new WindowInteropHelper(this).Handle,
                "Choose a folder to back up.");
        }

        private static string ShowLegacyFolderPicker(IntPtr owner, string description)
        {
            using (FolderBrowserDialog picker = new FolderBrowserDialog())
            {
                picker.Description = description;
                picker.RootFolder = Environment.SpecialFolder.MyComputer;
                picker.ShowNewFolderButton = true;
                return picker.ShowDialog(new NativeWindowHandle(owner)) ==
                        System.Windows.Forms.DialogResult.OK
                    ? picker.SelectedPath
                    : string.Empty;
            }
        }

        private sealed class NativeWindowHandle : System.Windows.Forms.IWin32Window
        {
            public NativeWindowHandle(IntPtr handle)
            {
                Handle = handle;
            }

            public IntPtr Handle { get; private set; }
        }

        private static class FileOpenDialogOptions
        {
            internal const uint NoChangeDirectory = 0x00000008;
            internal const uint PathMustExist = 0x00000800;
            internal const uint ForceFileSystem = 0x00000040;
            internal const uint PickFolders = 0x00000020;
        }

        private static class ShellItemDisplayName
        {
            internal const uint DesktopAbsoluteParsing = 0x80028000;
        }

        private static class HResult
        {
            internal const int Cancelled = unchecked((int)0x800704C7);
        }

        [ComImport]
        [Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
        [ClassInterface(ClassInterfaceType.None)]
        private sealed class FileOpenDialogClass
        {
        }

        [ComImport]
        [Guid("D57C7288-D4AD-4768-BE02-9D969532D960")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileOpenDialog
        {
            [PreserveSig] int Show(IntPtr parent);
            [PreserveSig] int SetFileTypes(uint count, IntPtr filters);
            [PreserveSig] int SetFileTypeIndex(uint index);
            [PreserveSig] int GetFileTypeIndex(out uint index);
            [PreserveSig] int Advise(IntPtr events, out uint cookie);
            [PreserveSig] int Unadvise(uint cookie);
            [PreserveSig] int SetOptions(uint options);
            [PreserveSig] int GetOptions(out uint options);
            [PreserveSig] int SetDefaultFolder(IShellItem item);
            [PreserveSig] int SetFolder(IShellItem item);
            [PreserveSig] int GetFolder(out IShellItem item);
            [PreserveSig] int GetCurrentSelection(out IShellItem item);
            [PreserveSig] int SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
            [PreserveSig] int GetFileName(out IntPtr name);
            [PreserveSig] int SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            [PreserveSig] int SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            [PreserveSig] int SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            [PreserveSig] int GetResult(out IShellItem item);
            [PreserveSig] int AddPlace(IShellItem item, uint alignment);
            [PreserveSig] int SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
            [PreserveSig] int Close(int result);
            [PreserveSig] int SetClientGuid(ref Guid guid);
            [PreserveSig] int ClearClientData();
            [PreserveSig] int SetFilter(IntPtr filter);
        }

        [ComImport]
        [Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            [PreserveSig] int BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid riid, out IntPtr ppv);
            [PreserveSig] int GetParent(out IShellItem parent);
            [PreserveSig] int GetDisplayName(uint sigdnName, out IntPtr name);
            [PreserveSig] int GetAttributes(uint attributes, out uint result);
            [PreserveSig] int Compare(IShellItem item, uint hint, out int result);
        }

        [DllImport("ole32.dll", ExactSpelling = true)]
        private static extern int CoCreateInstance(
            ref Guid clsid,
            IntPtr outer,
            uint context,
            ref Guid iid,
            out IFileOpenDialog instance);

        private static IFileOpenDialog CreateFileOpenDialog()
        {
            Guid clsid = new Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7");
            Guid iid = new Guid("D57C7288-D4AD-4768-BE02-9D969532D960");
            IFileOpenDialog dialog;
            int result = CoCreateInstance(ref clsid, IntPtr.Zero, 1, ref iid, out dialog);
            if (result < 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }
            return dialog;
        }

        private Dictionary<string, object> BuildWebSourcePickerState()
        {
            if (!sourcePickerOpen)
            {
                return null;
            }
            List<Dictionary<string, object>> suggestions = new List<Dictionary<string, object>>();
            foreach (SourcePickerSuggestion suggestion in sourcePickerSuggestions)
            {
                suggestions.Add(new Dictionary<string, object>
                {
                    { "name", suggestion.Name ?? string.Empty },
                    { "path", suggestion.Path ?? string.Empty },
                    { "protected", suggestion.Protected }
                });
            }
            return new Dictionary<string, object>
            {
                { "open", true },
                { "path", sourcePickerPath ?? string.Empty },
                { "name", sourcePickerName ?? string.Empty },
                { "status", sourcePickerStatus ?? "idle" },
                { "message", sourcePickerMessage ?? string.Empty },
                { "suggestions", suggestions }
            };
        }
    }
}
