using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Rewindle.Setup
{
    // What the bridge needs from the window it serves. Everything except Post is called on the window's (UI) thread.
    internal interface IBridgeServices
    {
        // Runs the work on the UI thread, whichever thread calls. The only member that may be called from any thread.
        void Post(Action work);
        // Delivers a message to the page.
        void Send(string json);
        ThemeState Theme { get; }
        string Locale { get; }
        // The chosen folder, or an empty string when the person cancelled.
        string PickFolder(string title, string okButtonLabel, string legacyDescription);
        // The file name to save under, or an empty string when the person cancelled.
        string PickSaveFile(string initialFolder, string suggestedName);
        void CopyToClipboard(string text);
        void OpenAddress(string address);
        void RevealFile(string path);
        void StartProgram(string path, string arguments);
        // Steps the page's zoom ("in", "out" or "reset") and returns a sentence that says the new size.
        string Zoom(string direction);
        void RequestClose();
    }

    // The places Setup works with, as the bridge is told them. The tests give it folders of their own.
    internal sealed class BridgeEnvironment
    {
        public string ProductVersion;
        public string UserSid;
        public string ProgramFilesFolder;
        public string CommonDataFolder;
        public IPlanSource Plans;
        public IElevatedLauncher Launcher;
        // Completes when the release bundle (and so the installer script) is unpacked; faults with SetupFailure when it cannot be.
        public Func<Task> EnsureBundle;
        public string InstallScriptPath;
        public string BundledUninstallScriptPath;
        // The unpacked bundle, and the SHA-256 each of its files had when this program unpacked it. A script from there is run
        // elevated only through ElevatedBootstrap, which checks its copy against these.
        public string BundleFolder;
        public Func<string, string> BundleSha256;
        public Func<string> CreateProgressFolder;
    }

    // Everything the wizard page can ask the program to do, and nothing else. Each command checks its own payload before it
    // acts, takes no path, address or command line from the page that it has not validated (the page never names a file to
    // copy, a program to start or a script to run), and answers exactly once. Long work runs on other threads and reports back
    // through IBridgeServices.Post.
    internal sealed class SetupBridge
    {
        private const string InstalledProductFolder = "ResticBackuper";
        private const string DashboardExecutableName = "ResticBackuperDashboard.exe";
        private const int MaximumMeasuredPaths = 32;
        private const string PayloadManifest = "payload-manifest.json";
        private const int MaximumClipboardText = 64 * 1024;

        private readonly IBridgeServices ui;
        private readonly BridgeEnvironment environment;
        private readonly object gate = new object();
        private readonly Dictionary<string, CancellationTokenSource> measurements =
            new Dictionary<string, CancellationTokenSource>();
        private CancellationTokenSource planCancellation;
        private SetupOperation operation;
        private ProgressLine installResult;
        private string repositoryRoot;
        private volatile bool closing;

        public SetupBridge(IBridgeServices ui, BridgeEnvironment environment)
        {
            this.ui = ui;
            this.environment = environment;
        }

        // True while an elevated installer is working, or about to: closing the window then would leave it running unseen, and
        // removing the files it reads from while it does.
        public bool IsBusyPastCancel
        {
            get
            {
                SetupOperation current;
                lock (gate)
                {
                    current = operation;
                }
                return current != null && current.IsPastCancel;
            }
        }

        // The page is gone (its renderer failed). An install or uninstall still preparing is cancelled, since a reloaded page
        // could not follow it; returns whether one is still running anyway (Windows was already asked, or it is working).
        public bool StopForLostPage()
        {
            SetupOperation current;
            lock (gate)
            {
                current = operation;
            }
            if (current == null || !current.IsRunning)
            {
                return false;
            }
            return !current.Cancel();
        }

        // The window is closing: nothing more is answered, and whatever can still be stopped is stopped.
        public void Shutdown()
        {
            closing = true;
            CancellationTokenSource plan;
            List<CancellationTokenSource> measures;
            SetupOperation current;
            lock (gate)
            {
                plan = planCancellation;
                planCancellation = null;
                measures = new List<CancellationTokenSource>(measurements.Values);
                measurements.Clear();
                current = operation;
            }
            Cancel(plan);
            foreach (CancellationTokenSource measure in measures)
            {
                Cancel(measure);
            }
            if (current != null)
            {
                current.Cancel();
            }
        }

        public void ThemeChanged()
        {
            Emit("theme", ThemeFields());
        }

        // One message from the page. Runs on the UI thread.
        public void Receive(string json)
        {
            if (closing)
            {
                return;
            }
            BridgeRequest request;
            if (!BridgeProtocol.TryParseRequest(json, out request))
            {
                return;
            }
            if (request.Command == null)
            {
                Fail(request.Id, "unknown_command", "Setup doesn’t know that request.");
                return;
            }
            try
            {
                Dispatch(request);
            }
            catch (SetupFailure failure)
            {
                Fail(request.Id, failure.Code, failure.Message);
            }
            catch (Exception error)
            {
                SetupLog.Write("Command " + request.Command + " failed", error);
                Fail(request.Id, "failed", "Setup couldn’t do that. Try again.");
            }
        }

        private void Dispatch(BridgeRequest request)
        {
            switch (request.Command)
            {
                case "hello":
                    Hello(request);
                    break;
                case "getPlan":
                    GetPlan(request);
                    break;
                case "browseFolder":
                    BrowseFolder(request, "Choose a folder to protect", "Choose folder", "Choose a folder to protect.");
                    break;
                case "browseRepositoryFolder":
                    BrowseFolder(request, "Choose where to keep backups", "Use this folder", "Choose where to keep your backups.");
                    break;
                case "measureFolders":
                    MeasureFolders(request);
                    break;
                case "cancelMeasure":
                    CancelMeasure(request);
                    break;
                case "install":
                    StartOperation(request, SetupOperation.Install);
                    break;
                case "uninstall":
                    StartOperation(request, SetupOperation.Uninstall);
                    break;
                case "cancelInstall":
                    CancelInstall(request);
                    break;
                case "openDashboard":
                    OpenDashboard(request);
                    break;
                case "saveRecoveryKeyCopy":
                    SaveRecoveryKeyCopy(request);
                    break;
                case "showRecoveryKey":
                    ShowRecoveryKey(request);
                    break;
                case "copyText":
                    CopyText(request);
                    break;
                case "openUrl":
                    OpenUrl(request);
                    break;
                case "setZoom":
                    SetZoom(request);
                    break;
                case "close":
                    Respond(request.Id, Done());
                    ui.Post(delegate { ui.RequestClose(); });
                    break;
                default:
                    Fail(request.Id, "unknown_command", "Setup doesn’t know that request.");
                    break;
            }
        }

        // ---- answers and events -------------------------------------------------------------------------------------------

        private static Dictionary<string, object> Done()
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["done"] = true;
            return result;
        }

        private void Respond(string id, object result)
        {
            Send(BridgeProtocol.Response(id, result));
        }

        private void Fail(string id, string code, string message)
        {
            Send(BridgeProtocol.Failure(id, code, message));
        }

        private void Emit(string name, object data)
        {
            Send(BridgeProtocol.Event(name, data));
        }

        // From any thread: the message is delivered on the UI thread, unless the window is already closing.
        private void Send(string json)
        {
            ui.Post(delegate
            {
                if (!closing)
                {
                    ui.Send(json);
                }
            });
        }

        private Dictionary<string, object> ThemeFields()
        {
            ThemeState theme = ui.Theme;
            Dictionary<string, object> fields = new Dictionary<string, object>();
            fields["dark"] = theme.Dark;
            fields["highContrast"] = theme.HighContrast;
            fields["reducedMotion"] = theme.ReducedMotion;
            return fields;
        }

        private static void Cancel(CancellationTokenSource source)
        {
            if (source == null)
            {
                return;
            }
            try
            {
                source.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
        }

        // ---- commands ------------------------------------------------------------------------------------------------------

        private void Hello(BridgeRequest request)
        {
            Dictionary<string, object> info = ThemeFields();
            info["protocol"] = BridgeProtocol.Version;
            info["version"] = environment.ProductVersion;
            info["locale"] = ui.Locale;
            info["host"] = "desktop";
            Respond(request.Id, info);
        }

        // Plan mode, for the choices the page has now. A newer request replaces an older one that is still running (the
        // page checks as the person changes things, and only the latest answer matters).
        private void GetPlan(BridgeRequest request)
        {
            InstallerInputs inputs;
            string problem;
            if (!InstallerContract.TryReadInputs(Json.AsObject(Json.Get(request.Payload, "inputs")), false, out inputs, out problem))
            {
                throw new SetupFailure("invalid_inputs", problem);
            }
            CancellationTokenSource mine = new CancellationTokenSource();
            CancellationTokenSource previous;
            lock (gate)
            {
                previous = planCancellation;
                planCancellation = mine;
            }
            Cancel(previous);

            string id = request.Id;
            Task.Factory.StartNew(
                delegate
                {
                    try
                    {
                        WaitForBundle(mine.Token);
                        IDictionary<string, object> plan = environment.Plans.GetPlan(inputs, mine.Token);
                        Respond(id, plan);
                    }
                    catch (OperationCanceledException)
                    {
                        Fail(id, "superseded", "A newer check replaced this one.");
                    }
                    catch (SetupFailure failure)
                    {
                        Fail(id, failure.Code, failure.Message);
                    }
                    catch (Exception error)
                    {
                        SetupLog.Write("Plan request failed", error);
                        Fail(id, "plan_failed", "Setup couldn’t check this PC. Try again.");
                    }
                },
                CancellationToken.None,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default);
        }

        private void WaitForBundle(CancellationToken cancel)
        {
            try
            {
                environment.EnsureBundle().Wait(cancel);
            }
            catch (AggregateException error)
            {
                SetupLog.Write("The bundle could not be unpacked", error.InnerException ?? error);
                throw new SetupFailure(
                    "payload_unpack_failed",
                    "Setup couldn’t unpack its files. Check that this PC has free space, then try again.");
            }
        }

        private void BrowseFolder(BridgeRequest request, string title, string okLabel, string legacyDescription)
        {
            string id = request.Id;
            // After this message handler has returned, so a modal dialog is never run inside the web view's own callback.
            ui.Post(delegate
            {
                try
                {
                    string chosen = ui.PickFolder(title, okLabel, legacyDescription);
                    Dictionary<string, object> result = new Dictionary<string, object>();
                    if (string.IsNullOrEmpty(chosen))
                    {
                        result["path"] = null;
                    }
                    else
                    {
                        string full = Path.GetFullPath(chosen);
                        if (!Directory.Exists(full))
                        {
                            throw new SetupFailure("not_a_folder", "Choose a folder on this PC.");
                        }
                        result["path"] = full;
                    }
                    Respond(id, result);
                }
                catch (SetupFailure failure)
                {
                    Fail(id, failure.Code, failure.Message);
                }
                catch (Exception error)
                {
                    SetupLog.Write("The folder chooser failed", error);
                    Fail(id, "folder_picker_failed", "Windows couldn’t show the folder chooser.");
                }
            });
        }

        private void MeasureFolders(BridgeRequest request)
        {
            string token = Json.String(request.Payload, "request", 64);
            IList<object> list = Json.AsList(Json.Get(request.Payload, "paths"));
            if (!BridgeProtocol.IsValidId(token) || list == null || list.Count == 0 || list.Count > MaximumMeasuredPaths)
            {
                throw new SetupFailure("invalid_request", "There is nothing to measure.");
            }
            List<string> paths = new List<string>();
            foreach (object item in list)
            {
                string path = item as string;
                if (!InstallerContract.IsAcceptablePath(path))
                {
                    throw new SetupFailure("invalid_request", "One of the folders can’t be measured.");
                }
                paths.Add(path);
            }

            CancellationTokenSource source = new CancellationTokenSource();
            CancellationTokenSource replaced = null;
            lock (gate)
            {
                measurements.TryGetValue(token, out replaced);
                measurements[token] = source;
            }
            Cancel(replaced);

            Task.Factory.StartNew(
                delegate
                {
                    try
                    {
                        ParallelOptions options = new ParallelOptions();
                        options.MaxDegreeOfParallelism = 2;
                        options.CancellationToken = source.Token;
                        Parallel.ForEach(paths, options, delegate(string path)
                        {
                            try
                            {
                                FolderMeasurer.Measure(path, source.Token, delegate(FolderTotals totals, bool done, string error)
                                {
                                    Emit("measure", MeasureFields(token, path, totals, done, error));
                                });
                            }
                            catch (OperationCanceledException)
                            {
                                throw;
                            }
                            catch (Exception error)
                            {
                                SetupLog.Write("Measuring a folder failed", error);
                                Emit("measure", MeasureFields(token, path, new FolderTotals(), true, "This folder’s size can’t be shown."));
                            }
                        });
                    }
                    catch (OperationCanceledException)
                    {
                    }
                    catch (AggregateException)
                    {
                    }
                    finally
                    {
                        lock (gate)
                        {
                            CancellationTokenSource current;
                            if (measurements.TryGetValue(token, out current) && current == source)
                            {
                                measurements.Remove(token);
                            }
                        }
                    }
                },
                CancellationToken.None,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default);
            Dictionary<string, object> accepted = new Dictionary<string, object>();
            accepted["accepted"] = true;
            Respond(request.Id, accepted);
        }

        private static Dictionary<string, object> MeasureFields(string token, string path, FolderTotals totals, bool done, string error)
        {
            Dictionary<string, object> fields = new Dictionary<string, object>();
            fields["request"] = token;
            fields["path"] = path;
            fields["bytes"] = totals.Bytes;
            fields["files"] = totals.Files;
            fields["placeholderFiles"] = totals.PlaceholderFiles;
            fields["placeholderBytes"] = totals.PlaceholderBytes;
            fields["skippedFolders"] = totals.SkippedFolders;
            fields["done"] = done;
            fields["error"] = error;
            return fields;
        }

        private void CancelMeasure(BridgeRequest request)
        {
            string token = Json.String(request.Payload, "request", 64);
            CancellationTokenSource source = null;
            if (BridgeProtocol.IsValidId(token))
            {
                lock (gate)
                {
                    if (measurements.TryGetValue(token, out source))
                    {
                        measurements.Remove(token);
                    }
                }
            }
            Cancel(source);
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["cancelled"] = source != null;
            Respond(request.Id, result);
        }

        private void StartOperation(BridgeRequest request, string kind)
        {
            InstallerInputs inputs = null;
            if (kind == SetupOperation.Install)
            {
                string problem;
                if (!InstallerContract.TryReadInputs(Json.AsObject(Json.Get(request.Payload, "choices")), true, out inputs, out problem))
                {
                    throw new SetupFailure("invalid_choices", problem);
                }
            }

            SetupOperation next;
            lock (gate)
            {
                if (operation != null && operation.IsRunning)
                {
                    throw new SetupFailure("busy", "Setup is already working on something.");
                }
                string script = kind == SetupOperation.Install ? environment.InstallScriptPath : UninstallScriptPath();
                next = new SetupOperation(
                    kind,
                    environment.Plans,
                    environment.Launcher,
                    environment.UserSid,
                    script,
                    BundleLaunchFor(script),
                    environment.CreateProgressFolder,
                    delegate(string name, Dictionary<string, object> data) { OnOperationEvent(name, data); },
                    delegate { WaitForBundle(CancellationToken.None); });
                operation = next;
                if (inputs != null)
                {
                    repositoryRoot = Path.GetPathRoot(inputs.Repository);
                }
            }

            Dictionary<string, object> started = new Dictionary<string, object>();
            started["started"] = true;
            Respond(request.Id, started);
            Task.Factory.StartNew(
                delegate { next.Run(inputs); },
                CancellationToken.None,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default);
        }

        // The installed uninstaller sits in the protected install folder, where only administrators can change it, so it is the
        // one to run elevated, as long as it speaks the progress contract this setup reads. An uninstaller installed by an earlier
        // release (0.2.0-alpha.1) has no -ProgressPath and would refuse the call; then, as when there is none (a broken install),
        // the copy in this setup's own bundle is used.
        private string UninstallScriptPath()
        {
            string installed = Path.Combine(environment.ProgramFilesFolder, InstalledProductFolder, InstallerContract.UninstallScript);
            return File.Exists(installed) && SupportsProgressFeed(installed) ? installed : environment.BundledUninstallScriptPath;
        }

        // How to run a script elevated when it comes from this setup's own unpacked bundle; null for the uninstaller installed in
        // Program Files, which only administrators can change and which is run where it is. The installer's copy brings the
        // payload, which the installer itself verifies file by file against payload-manifest.json; that manifest and the script
        // are checked against what this program unpacked.
        private BundleLaunch BundleLaunchFor(string script)
        {
            if (string.IsNullOrEmpty(environment.BundleFolder) || environment.BundleSha256 == null)
            {
                return null;
            }
            string root = Path.GetFullPath(environment.BundleFolder).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string full = Path.GetFullPath(script);
            if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
            string relative = full.Substring(root.Length);
            BundleLaunch launch = new BundleLaunch();
            launch.SourceRoot = environment.BundleFolder;
            launch.ScriptRelativePath = relative;
            launch.ExpectedSha256 = environment.BundleSha256;
            if (string.Equals(relative, InstallerContract.InstallScript, StringComparison.OrdinalIgnoreCase))
            {
                launch.StagedItems = new string[] { relative, PayloadManifest, "payload" };
                launch.CheckedFiles = new string[] { relative, PayloadManifest };
            }
            else
            {
                launch.StagedItems = new string[] { relative };
                launch.CheckedFiles = new string[] { relative };
            }
            return launch;
        }

        // Whether an uninstaller script declares the -ProgressPath parameter and writes the progress schema this setup reads.
        // Reads at most 512 KB; a file that can't be read counts as not supporting it.
        internal static bool SupportsProgressFeed(string scriptPath)
        {
            try
            {
                using (FileStream stream = new FileStream(scriptPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
                {
                    char[] buffer = new char[512 * 1024];
                    int read = reader.ReadBlock(buffer, 0, buffer.Length);
                    string text = new string(buffer, 0, read);
                    return Regex.IsMatch(text, @"\[string\]\s*\$ProgressPath\b", RegexOptions.IgnoreCase) &&
                        text.IndexOf(InstallerContract.ProgressSchema, StringComparison.Ordinal) >= 0;
                }
            }
            catch (Exception)
            {
                return false;
            }
        }

        private void OnOperationEvent(string name, Dictionary<string, object> data)
        {
            if (name == "operationFinished")
            {
                lock (gate)
                {
                    object outcome;
                    if (operation != null && operation.Kind == SetupOperation.Install &&
                        data.TryGetValue("outcome", out outcome) && "succeeded".Equals(outcome))
                    {
                        installResult = operation.Result;
                    }
                }
            }
            Emit(name, data);
        }

        private void CancelInstall(BridgeRequest request)
        {
            SetupOperation current;
            lock (gate)
            {
                current = operation;
            }
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["cancelled"] = current != null && current.Cancel();
            Respond(request.Id, result);
        }

        private void OpenDashboard(BridgeRequest request)
        {
            string installRoot = Path.Combine(environment.ProgramFilesFolder, InstalledProductFolder);
            List<string> candidates = new List<string>();
            ProgressLine reported;
            lock (gate)
            {
                reported = installResult;
            }
            if (reported != null && !string.IsNullOrEmpty(reported.DashboardExecutable))
            {
                candidates.Add(reported.DashboardExecutable);
            }
            candidates.Add(Path.Combine(installRoot, DashboardExecutableName));

            string program = null;
            foreach (string candidate in candidates)
            {
                // Only the installed dashboard, in the installed folder: a path the installer reported is not trusted beyond that.
                if (IsInstalledDashboard(candidate, installRoot) && File.Exists(candidate))
                {
                    program = candidate;
                    break;
                }
            }
            if (program == null)
            {
                throw new SetupFailure(
                    "dashboard_missing",
                    "Setup couldn’t find Rewindle. If it was just installed, open it from the Start menu.");
            }
            string state = Path.Combine(environment.CommonDataFolder, InstalledProductFolder);
            string arguments = Directory.Exists(state) ? "--state-dir " + CommandLine.Quote(state) : string.Empty;
            ui.StartProgram(program, arguments);
            Respond(request.Id, Done());
        }

        public static bool IsInstalledDashboard(string path, string installRoot)
        {
            if (!InstallerContract.IsAcceptablePath(path))
            {
                return false;
            }
            string full = Path.GetFullPath(path);
            string root = Path.GetFullPath(installRoot).TrimEnd('\\') + "\\";
            return string.Equals(Path.GetFileName(full), DashboardExecutableName, StringComparison.OrdinalIgnoreCase) &&
                full.StartsWith(root, StringComparison.OrdinalIgnoreCase);
        }

        // The recovery key's path as the installer reported it, and the line it was reported in. The page never names the file.
        private ProgressLine RecoveryKeyReport()
        {
            ProgressLine reported;
            lock (gate)
            {
                reported = installResult;
            }
            if (reported == null || string.IsNullOrEmpty(reported.RecoveryKeyPath))
            {
                throw new SetupFailure("no_recovery_key", "Setup doesn’t have a recovery key to copy yet.");
            }
            if (!InstallerContract.IsAcceptablePath(reported.RecoveryKeyPath) ||
                !reported.RecoveryKeyPath.EndsWith(".txt", StringComparison.OrdinalIgnoreCase))
            {
                throw new SetupFailure("recovery_key_invalid", "Setup doesn’t recognise where the recovery key was saved.");
            }
            return reported;
        }

        private const string UnreadableKeyMessage =
            "Setup can’t open your recovery key, because only administrators can read it. Choose Show in folder, then copy the file " +
            "to a USB drive or another safe place, and choose Continue when Windows asks for permission.";

        private void SaveRecoveryKeyCopy(BridgeRequest request)
        {
            ProgressLine reported = RecoveryKeyReport();
            string id = request.Id;
            // Only an explicit "no" is taken as the answer; "unknown" is tried, and reading it says so if it cannot be done.
            if (reported.RecoveryKeyReadableByUser == false)
            {
                throw new SetupFailure("recovery_key_unreadable", UnreadableKeyMessage);
            }
            // Read before the person is asked where to save, so a key that cannot be read is told about at once.
            byte[] key = ReadRecoveryKey(reported.RecoveryKeyPath);
            ui.Post(delegate
            {
                try
                {
                    string destination = ui.PickSaveFile(SuggestedKeyFolder(), "Rewindle recovery key.txt");
                    Dictionary<string, object> result = new Dictionary<string, object>();
                    if (string.IsNullOrEmpty(destination))
                    {
                        result["saved"] = false;
                        Respond(id, result);
                        return;
                    }
                    WriteVerifiedCopy(destination, key);
                    result["saved"] = true;
                    result["path"] = destination;
                    Respond(id, result);
                }
                catch (SetupFailure failure)
                {
                    Fail(id, failure.Code, failure.Message);
                }
                catch (Exception error)
                {
                    SetupLog.Write("Saving the recovery key copy failed", error);
                    Fail(id, "recovery_key_save_failed", "The copy couldn’t be saved there. Choose another place and try again.");
                }
            });
        }

        private static byte[] ReadRecoveryKey(string path)
        {
            try
            {
                FileInfo info = new FileInfo(path);
                if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length > 64 * 1024)
                {
                    throw new SetupFailure("recovery_key_invalid", "Setup can’t find the recovery key where it was saved.");
                }
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    byte[] bytes = new byte[info.Length];
                    int total = 0;
                    while (total < bytes.Length)
                    {
                        int read = stream.Read(bytes, total, bytes.Length - total);
                        if (read <= 0)
                        {
                            break;
                        }
                        total += read;
                    }
                    if (total != bytes.Length)
                    {
                        throw new SetupFailure("recovery_key_invalid", "Setup couldn’t read the whole recovery key.");
                    }
                    return bytes;
                }
            }
            catch (UnauthorizedAccessException)
            {
                throw new SetupFailure("recovery_key_unreadable", UnreadableKeyMessage);
            }
        }

        // Writes the key and reads the copy back, so "saved" means the file on that drive holds the same bytes.
        private static void WriteVerifiedCopy(string destination, byte[] key)
        {
            if (!InstallerContract.IsAcceptablePath(destination))
            {
                throw new SetupFailure("recovery_key_save_failed", "Choose a place on a drive with a letter, like a USB drive.");
            }
            File.WriteAllBytes(destination, key);
            byte[] written = File.ReadAllBytes(destination);
            if (written.Length != key.Length)
            {
                throw new SetupFailure("recovery_key_save_failed", "The copy didn’t match the original. Choose another place and try again.");
            }
            for (int index = 0; index < key.Length; index++)
            {
                if (written[index] != key[index])
                {
                    throw new SetupFailure("recovery_key_save_failed", "The copy didn’t match the original. Choose another place and try again.");
                }
            }
        }

        // A removable drive that is not the one the backups are on: the best place for a copy that has to survive the PC.
        private string SuggestedKeyFolder()
        {
            string backups;
            lock (gate)
            {
                backups = repositoryRoot;
            }
            try
            {
                foreach (DriveInfo drive in DriveInfo.GetDrives())
                {
                    if (drive.DriveType == DriveType.Removable && drive.IsReady &&
                        !string.Equals(drive.RootDirectory.FullName, backups, StringComparison.OrdinalIgnoreCase))
                    {
                        return drive.RootDirectory.FullName;
                    }
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
            return null;
        }

        private void ShowRecoveryKey(BridgeRequest request)
        {
            ProgressLine reported = RecoveryKeyReport();
            ui.RevealFile(reported.RecoveryKeyPath);
            Respond(request.Id, Done());
        }

        private void CopyText(BridgeRequest request)
        {
            string text = Json.String(request.Payload, "text", MaximumClipboardText);
            if (string.IsNullOrEmpty(text))
            {
                throw new SetupFailure("invalid_request", "There is nothing to copy.");
            }
            ui.CopyToClipboard(text);
            Respond(request.Id, Done());
        }

        private void OpenUrl(BridgeRequest request)
        {
            string address;
            if (!ProjectLinks.TryResolve(Json.String(request.Payload, "target", 32), out address))
            {
                throw new SetupFailure("invalid_request", "Setup can’t open that link.");
            }
            ui.OpenAddress(address);
            Respond(request.Id, Done());
        }

        private void SetZoom(BridgeRequest request)
        {
            string direction = Json.String(request.Payload, "zoom", 16);
            if (direction != "in" && direction != "out" && direction != "reset")
            {
                throw new SetupFailure("invalid_request", "The requested zoom is not valid.");
            }
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["message"] = ui.Zoom(direction);
            Respond(request.Id, result);
        }
    }
}
