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
                "Choose a folder to protect. Nothing changes until you review it and approve the Windows prompt.";
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
                error = "The protected backup configuration is unavailable.";
                return false;
            }
            if (sourceOperationInProgress || BackupBlocksSourceChanges())
            {
                error = "Wait for the current protected operation to finish before choosing a folder.";
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
                error = "The folder picker could not open. " + exception.Message;
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
                error = "Enter an absolute local folder path.";
                return false;
            }

            string requestedPath = path.Trim();
            int generation = ++sourcePickerValidationGeneration;
            sourcePickerBusy = true;
            sourcePickerPath = requestedPath;
            sourcePickerName = string.Empty;
            sourcePickerStatus = "checking";
            sourcePickerMessage = "Checking the folder, drive, and protected backup boundaries…";
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
                        "Use a local drive-letter path such as C:\\Users\\you\\Documents.");
                }
                string root = Path.GetPathRoot(requestedPath);
                if (string.IsNullOrWhiteSpace(root) ||
                    root.Length != 3 || root[1] != ':' || root[2] != '\\')
                {
                    return InvalidSourcePickerPath(
                        requestedPath,
                        "Use a local drive-letter path. Network and UNC folders are not supported.");
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
                    "This folder uses a reparse point or link. Choose a normal local folder.");
            }

            try
            {
                DriveInfo drive = new DriveInfo(Path.GetPathRoot(normalized));
                if (!drive.IsReady ||
                    (drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable))
                {
                    return InvalidSourcePickerPath(
                        normalized,
                        "The folder must be on a ready local fixed or removable drive.");
                }
            }
            catch
            {
                return InvalidSourcePickerPath(
                    normalized,
                    "The folder's local drive could not be checked.");
            }

            if (configuration == null)
            {
                return InvalidSourcePickerPath(
                    normalized,
                    "The protected backup configuration is unavailable. Refresh and try again.");
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
                            ? "This folder holds the required restore test file and is already protected."
                            : "This folder is already protected. Choose another folder."
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
                            Message = "This folder is already covered by protected folder \"" +
                                source.DisplayName + "\". You do not need to add it separately."
                        };
                    }
                    return new SourcePickerValidation
                    {
                        Status = "invalid",
                        Path = normalized,
                        Name = new BackupSourceView(normalized, false).DisplayName,
                        Message = "This folder contains the existing protected folder \"" +
                            source.DisplayName + "\". Choose a separate folder so protected folders do not overlap."
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
                        "This folder overlaps protected Rewindle storage. Choose a folder outside the app, repository, and state locations.");
                }
            }

            BackupSourceView view = new BackupSourceView(normalized, false);
            return new SourcePickerValidation
            {
                Status = "ready",
                Path = normalized,
                Name = view.DisplayName,
                Message = "Ready to protect. The folder will be included in future backups after Windows approval; no backup starts now."
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
                error = "Check this exact folder before protecting it.";
                return false;
            }
            if (!string.Equals(sourcePickerStatus, "ready", StringComparison.Ordinal))
            {
                error = "The folder is not ready to protect.";
                return false;
            }
            try
            {
                currentSourceConfiguration = SourceConfiguration.Load();
            }
            catch
            {
                error = "The backup plan could not be refreshed. Check the folder again before saving.";
                sourcePickerStatus = "invalid";
                sourcePickerMessage = error;
                PublishWebPresentationState();
                return false;
            }
            if (currentSourceConfiguration == null ||
                !string.Equals(currentSourceConfiguration.PlanId, sourcePickerPlanId, StringComparison.Ordinal) ||
                currentSourceConfiguration.ConfigGeneration != sourcePickerConfigGeneration)
            {
                error = "The backup plan changed while this folder was being reviewed. Check the folder again.";
                sourcePickerStatus = "invalid";
                sourcePickerMessage = error;
                PublishWebPresentationState();
                return false;
            }
            if (BackupBlocksSourceChanges() || sourceOperationInProgress)
            {
                error = "A protected operation is already running. Try again when it finishes.";
                sourcePickerStatus = "failed";
                sourcePickerMessage = error;
                PublishWebPresentationState();
                return false;
            }

            sourcePickerBusy = true;
            sourcePickerStatus = "busy";
            sourcePickerMessage = "Waiting for Windows approval. Your backup plan will change only after approval succeeds…";
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
                sourcePickerMessage = "Folder protected. It will be included in the next backup; no backup was started.";
            }
            else if (sourceOperationStage == SourceOperationStage.Cancelled)
            {
                sourcePickerStatus = "cancelled";
                sourcePickerMessage = "Windows approval was cancelled. Nothing changed; you can review or choose another folder.";
            }
            else
            {
                sourcePickerStatus = "failed";
                sourcePickerMessage = string.IsNullOrWhiteSpace(sourceOperationError)
                    ? "The folder was not added. Review the folder and try again."
                    : sourceOperationError;
            }
            PublishWebPresentationState();
        }

        private bool CloseSourcePicker(out string error)
        {
            error = string.Empty;
            if (sourceOperationInProgress ||
                (sourcePickerBusy && string.Equals(sourcePickerStatus, "busy", StringComparison.Ordinal)))
            {
                error = "Wait for the protected folder change to finish before closing this chooser.";
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
                "Choose a folder to protect",
                "Review folder",
                "Choose a folder to protect in future Restic backup runs.");
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
                "Choose a folder to protect in future Restic backup runs.");
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
