using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Windows;

namespace ResticBackuper.Dashboard
{
    public partial class DashboardWindow
    {
        private bool restoreFlowOpen;
        private bool restoreFlowBusy;
        private string restoreFlowStep = "backup";
        private string restoreFlowStatus = "idle";
        private string restoreFlowMessageTitle = "Choose a backup";
        private string restoreFlowMessageDetail = "Select one immutable snapshot to begin.";
        private IList<RestoreSnapshot> restoreFlowSnapshots = new List<RestoreSnapshot>();
        private IList<RestoreTreeEntry> restoreFlowTreeEntries = new List<RestoreTreeEntry>();
        private HashSet<string> restoreFlowObservedPaths = new HashSet<string>(StringComparer.Ordinal);
        private string restoreFlowTreePath = "/";
        private string restoreFlowSelectedSnapshotId = string.Empty;
        private IList<string> restoreFlowSelectedPaths = new List<string>();
        private bool restoreFlowWholeSnapshotSelected;
        private string restoreFlowDestinationPath = string.Empty;
        private bool restoreFlowDestinationValid;
        private bool restoreFlowDestinationChecking;
        private bool restoreFlowDestinationError;
        private string restoreFlowDestinationStatus = "Choose a new or empty folder.";
        // The room the checked destination's drive had when it was checked, and the drive's name ("E:"). Read together with the check, which
        // runs off the UI thread, and never while the state is built: a slow removable drive would stall every push to the page. null when it
        // could not be read. It is only ever the subject of a warning.
        private long? restoreFlowDestinationFreeBytes;
        private string restoreFlowDestinationDrive = string.Empty;
        private int restoreFlowDestinationValidationGeneration;
        private int restoreFlowOperationGeneration;
        private bool restoreFlowCancelRequested;
        private bool restoreFlowReviewReady;
        private string restoreFlowReviewFingerprint = string.Empty;
        private SourceConfiguration restoreFlowConfiguration;
        private string restoreFlowConfigHash = string.Empty;
        private long restoreFlowConfigGeneration;
        private string restoreFlowPlanId = string.Empty;
        private string restoreFlowProgressStage = string.Empty;
        private string restoreFlowProgressMessage = string.Empty;
        private int restoreFlowProgressPercent;
        // True from the moment a restore is requested until Windows has approved the protected step, so
        // the page can say it is waiting for the approval prompt rather than reporting 0% progress.
        private bool restoreFlowAwaitingApproval;
        private string restoreFlowResultStatus;
        private string restoreFlowResultTarget;
        private bool restoreFlowResultVerified;
        private string restoreFlowResultError;
        private string restoreFlowResultSnapshotId;
        private RestoreManagerResult restoreFlowLastResult;
        // The protected step that last failed: "snapshots", "tree", "restore" or "config". Retry uses it
        // to return to the step that can actually recover instead of always jumping to the destination.
        private string restoreFlowFailedOperation = string.Empty;
        // A folder that could not be read stays an inline problem on Choose files; the listing is kept.
        private string restoreFlowTreeError = string.Empty;
        private string restoreFlowTreeErrorPath = string.Empty;
        // One Windows approval per restore flow (RestoreSessionHost in RestoreManager.cs): the snapshot list, every folder and
        // the restore go to one protected session. Null when the installed engine does not serve sessions (the legacy personal
        // edition, or an older Rewindle engine): every protected step is then its own elevated request, as before.
        private RestoreSessionHost restoreFlowApprovalSession;
        // Folder listings already read in this flow, by snapshot and folder. A snapshot never changes, so a folder that was read
        // once is shown again without asking the backup (or Windows) again. Cleared with the snapshot, the plan and the flow.
        private Dictionary<string, IList<RestoreTreeEntry>> restoreFlowTreeCache;
        private List<string> restoreFlowTreeCacheOrder;
        // Whether restoreFlowTreeEntries holds a folder that was read. Choosing a backup reads nothing: its root is read only when
        // the person asks to browse it, so "Everything in this snapshot" never reads a folder.
        private bool restoreFlowTreeLoaded;
        private bool restoreFlowTreeLoadedBeforeRead;
        private const int RestoreFlowMaximumCachedFolders = 256;

        // One restore may name at most this many paths. The page is told the same number so it stops offering more
        // before the host would refuse them; the check in ParseRestoreFlowPaths stays the authority.
        private const int RestoreFlowMaximumPaths = 64;
        // A folder listing is published to the page on every state push, so only this many entries of it are sent. The
        // rest stay in restoreFlowTreeEntries (and in restoreFlowObservedPaths, which is what a selection is checked
        // against), and the page is told how many there are so it can say the list is not complete.
        private const int RestoreFlowMaximumPublishedEntries = 1000;

        private static readonly string[] RestoreFlowCommands =
        {
            "openRestore",
            "restoreFlowOpen",
            "restoreFlowBrowseSnapshots",
            "restoreFlowBrowseFiles",
            "restoreFlowSelectPaths",
            "restoreFlowNavigate",
            "restoreFlowBrowseDestination",
            "restoreFlowValidateDestination",
            "restoreFlowReview",
            "restoreFlowStart",
            "restoreFlowCancel",
            "restoreFlowRetry",
            "restoreFlowClose",
            // Neither takes anything from the page: they act on the folder the finished restore reported.
            "restoreFlowOpenDestination",
            "restoreFlowCopyDestination"
        };

        private bool IsRestoreFlowCommand(string command)
        {
            return RestoreFlowCommands.Contains(command ?? string.Empty, StringComparer.Ordinal);
        }

        private bool ExecuteRestoreFlowCommand(
            string command,
            IDictionary<string, object> payload,
            out string error)
        {
            error = string.Empty;
            if (command == "openRestore" || command == "restoreFlowOpen")
            {
                return OpenRestoreFlow(out error);
            }
            if (command == "restoreFlowBrowseSnapshots")
            {
                if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
                {
                    return false;
                }
                SourceConfiguration freshConfiguration;
                if (!TryGetFreshRestoreFlowConfiguration(out freshConfiguration, out error))
                {
                    return false;
                }
                restoreFlowConfiguration = freshConfiguration;
                BeginRestoreFlowSnapshotLoad();
                return true;
            }
            if (command == "restoreFlowBrowseFiles")
            {
                return BeginRestoreFlowBrowseFiles(payload, out error);
            }
            if (command == "restoreFlowSelectPaths")
            {
                return SelectRestoreFlowPaths(payload, out error);
            }
            if (command == "restoreFlowNavigate")
            {
                return NavigateRestoreFlow(payload, out error);
            }
            if (command == "restoreFlowBrowseDestination")
            {
                return BrowseRestoreFlowDestination(out error);
            }
            if (command == "restoreFlowValidateDestination")
            {
                return ValidateRestoreFlowDestinationCommand(payload, out error);
            }
            if (command == "restoreFlowReview")
            {
                return ReviewRestoreFlow(out error);
            }
            if (command == "restoreFlowStart")
            {
                return StartRestoreFlow(payload, out error);
            }
            if (command == "restoreFlowCancel")
            {
                return CancelRestoreFlow(out error);
            }
            if (command == "restoreFlowRetry")
            {
                return RetryRestoreFlow(out error);
            }
            if (command == "restoreFlowClose")
            {
                return CloseRestoreFlow(out error);
            }
            if (command == "restoreFlowOpenDestination")
            {
                return OpenRestoreFlowDestination(out error);
            }
            if (command == "restoreFlowCopyDestination")
            {
                return CopyRestoreFlowDestination(out error);
            }
            error = "The requested restore-flow command is not allowed.";
            return false;
        }

        private bool OpenRestoreFlow(out string error)
        {
            error = string.Empty;
            if (restoreFlowOpen)
            {
                return true;
            }
            return StartRestoreFlowSession(out error);
        }

        // Reload Restore after the protected plan changed. This is the only place besides Open that
        // captures a new configuration baseline, and it always runs because the user asked for it.
        private bool ReloadRestoreFlowConfiguration(out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            return StartRestoreFlowSession(out error);
        }

        // Starts the flow at "Choose a backup" from a freshly captured configuration baseline. Open and
        // Reload Restore share this so they pass the same readiness gate and reset exactly the same state.
        private bool StartRestoreFlowSession(out string error)
        {
            error = string.Empty;
            if (sourcePickerOpen)
            {
                error = "Finish or close the folder chooser before opening Restore.";
                return false;
            }
            UpdateRestoreReadiness();
            if (openRestoreCenterButton == null || !openRestoreCenterButton.IsEnabled)
            {
                error = restoreReadinessDetail == null
                    ? "The protected Restore Center is currently unavailable."
                    : restoreReadinessDetail.Text;
                return false;
            }

            SourceConfiguration configuration;
            try
            {
                configuration = SourceConfiguration.Load();
            }
            catch (Exception exception)
            {
                error = "The protected restore configuration could not be loaded. " + exception.Message;
                return false;
            }
            string hash;
            try
            {
                hash = ComputeRestoreFlowConfigHash(configuration);
            }
            catch (Exception exception)
            {
                error = "The protected restore configuration could not be checked. " + exception.Message;
                return false;
            }

            ResetRestoreFlowSession(configuration, hash);
            PublishWebPresentationState();
            BeginRestoreFlowSnapshotLoad();
            return true;
        }

        private void ResetRestoreFlowSession(SourceConfiguration configuration, string hash)
        {
            CloseRestoreFlowApprovalSession();
            ClearRestoreFlowTreeCache();
            restoreFlowTreeLoaded = false;
            restoreFlowApprovalSession = configuration != null &&
                RestoreSessionCapability.IsSupported(EngineProfile.Current, configuration.InstallRoot)
                    ? new RestoreSessionHost(RestoreSessionHost.LaunchElevated)
                    : null;
            restoreFlowOpen = true;
            restoreFlowBusy = false;
            restoreFlowConfiguration = configuration;
            restoreFlowConfigHash = hash;
            restoreFlowConfigGeneration = configuration.ConfigGeneration;
            restoreFlowPlanId = configuration.PlanId ?? string.Empty;
            restoreFlowStep = "backup";
            restoreFlowStatus = "idle";
            restoreFlowMessageTitle = "Choose a backup";
            restoreFlowMessageDetail = "Loading the snapshots for this protected backup plan…";
            restoreFlowSnapshots = new List<RestoreSnapshot>();
            restoreFlowTreeEntries = new List<RestoreTreeEntry>();
            restoreFlowObservedPaths = new HashSet<string>(StringComparer.Ordinal);
            restoreFlowTreePath = "/";
            ClearRestoreFlowTreeError();
            restoreFlowSelectedSnapshotId = string.Empty;
            restoreFlowSelectedPaths = new List<string>();
            restoreFlowWholeSnapshotSelected = false;
            restoreFlowDestinationPath = string.Empty;
            restoreFlowDestinationValid = false;
            restoreFlowDestinationChecking = false;
            restoreFlowDestinationError = false;
            restoreFlowDestinationStatus = "Choose a new or empty folder.";
            restoreFlowDestinationFreeBytes = null;
            restoreFlowDestinationDrive = string.Empty;
            restoreFlowReviewReady = false;
            restoreFlowReviewFingerprint = string.Empty;
            ClearRestoreFlowResult();
            restoreFlowCancelRequested = false;
            restoreFlowAwaitingApproval = false;
        }

        private void BeginRestoreFlowSnapshotLoad()
        {
            if (!restoreFlowOpen || restoreFlowBusy)
            {
                return;
            }
            restoreFlowTreeEntries = new List<RestoreTreeEntry>();
            restoreFlowObservedPaths.Clear();
            ClearRestoreFlowTreeCache();
            restoreFlowTreeLoaded = false;
            ClearRestoreFlowScope();
            ClearRestoreFlowTreeError();
            restoreFlowFailedOperation = string.Empty;
            InvalidateRestoreFlowReview();
            int operation = ++restoreFlowOperationGeneration;
            restoreFlowBusy = true;
            restoreFlowCancelRequested = false;
            restoreFlowAwaitingApproval = false;
            restoreFlowStep = "backup";
            restoreFlowStatus = "loading";
            restoreFlowProgressStage = "reading";
            restoreFlowProgressMessage = "Reading the protected snapshot history.";
            restoreFlowProgressPercent = 0;
            SetRestoreFlowMessage(
                "Loading snapshots",
                "Reading snapshots does not change them.");
            PublishWebPresentationState();
            SourceConfiguration configuration = restoreFlowConfiguration;
            LoadRestoreFlowSnapshotsAsync(configuration, operation);
        }

        private async void LoadRestoreFlowSnapshotsAsync(
            SourceConfiguration configuration,
            int operation)
        {
            RestoreManagerResult result;
            RestoreSessionHost session = restoreFlowApprovalSession;
            try
            {
                result = await Task.Run(delegate
                {
                    return RestoreManagerLauncher.ListSnapshots(
                        configuration,
                        session,
                        delegate { OnRestoreFlowApprovalRequested(operation); },
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                if (restoreFlowOpen && operation == restoreFlowOperationGeneration)
                                {
                                    restoreFlowAwaitingApproval = false;
                                    SetRestoreFlowMessage(
                                        "Reading snapshots",
                                        "The protected repository is returning immutable backup history.");
                                    PublishWebPresentationState();
                                }
                            }));
                        },
                        delegate(RestoreManagerProgress progress)
                        {
                            OnRestoreFlowProgress(progress, operation);
                        });
                });
            }
            catch (Exception exception)
            {
                result = RestoreManagerResult.Failure(exception.Message, -1);
            }
            if (!restoreFlowOpen || operation != restoreFlowOperationGeneration)
            {
                return;
            }
            restoreFlowBusy = false;
            restoreFlowAwaitingApproval = false;
            if (restoreFlowCancelRequested)
            {
                restoreFlowFailedOperation = "snapshots";
                CompleteRestoreFlowCancelled("Snapshot loading was cancelled before any restore operation started.");
                return;
            }
            SourceConfiguration freshAfterRead;
            string freshnessError;
            if (!TryGetFreshRestoreFlowConfiguration(out freshAfterRead, out freshnessError))
            {
                EndRestoreFlowReadAfterFailedCheck("snapshots", freshnessError, null, null, null);
                return;
            }
            restoreFlowConfiguration = freshAfterRead;
            if (result.UserCancelled)
            {
                FailRestoreFlow(
                    "snapshots",
                    "Windows approval cancelled",
                    "No repository data was read.",
                    "cancelled");
                PublishWebPresentationState();
                return;
            }
            if (!result.Succeeded)
            {
                FailRestoreFlow(
                    "snapshots",
                    "Snapshots unavailable",
                    result.ErrorMessage,
                    "error");
                PublishWebPresentationState();
                return;
            }
            restoreFlowSnapshots = result.Snapshots ?? new List<RestoreSnapshot>();
            RestoreSnapshot selected = FindRestoreFlowSnapshot(restoreFlowSelectedSnapshotId);
            if (selected == null)
            {
                restoreFlowSelectedSnapshotId = string.Empty;
                restoreFlowTreeEntries = new List<RestoreTreeEntry>();
                restoreFlowTreeLoaded = false;
                restoreFlowTreePath = "/";
                ClearRestoreFlowScope();
            }
            restoreFlowStatus = restoreFlowSnapshots.Count == 0 ? "failed" : "ready";
            restoreFlowStep = "backup";
            SetRestoreFlowMessage(
                restoreFlowSnapshots.Count == 0 ? "No matching snapshots" : "Choose a backup",
                restoreFlowSnapshots.Count == 0
                    ? "No plan-bound or exact configuration-matched legacy snapshots are available."
                    : restoreFlowSnapshots.Count.ToString(CultureInfo.CurrentCulture) +
                        " immutable snapshot" +
                        (restoreFlowSnapshots.Count == 1 ? string.Empty : "s") +
                        " are available. Select one to restore from it.");
            PublishWebPresentationState();
        }

        private bool BeginRestoreFlowBrowseFiles(
            IDictionary<string, object> payload,
            out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            SourceConfiguration fresh;
            if (!TryGetFreshRestoreFlowConfiguration(out fresh, out error))
            {
                return false;
            }
            string snapshotId = WebReadString(payload, "snapshotId", 128).Trim().ToLowerInvariant();
            RestoreSnapshot snapshot = FindRestoreFlowSnapshot(snapshotId);
            if (snapshot == null)
            {
                error = "Choose one snapshot from the current protected history.";
                return false;
            }
            string path = WebReadString(payload, "path", 2048).Trim();
            if (path.Length == 0)
            {
                path = WebReadString(payload, "parentPath", 2048).Trim();
            }
            if (path.Length == 0)
            {
                path = "/";
            }
            if (!TryNormalizeRestoreFlowTreePath(path, out path, out error))
            {
                return false;
            }
            // Keep the listing the user already has (same snapshot only) so a folder that cannot be read
            // leaves it in place instead of replacing it with an empty tree.
            bool sameSnapshot = string.Equals(
                snapshot.Id,
                restoreFlowSelectedSnapshotId,
                StringComparison.OrdinalIgnoreCase);
            IList<RestoreTreeEntry> previousEntries = sameSnapshot
                ? restoreFlowTreeEntries
                : new List<RestoreTreeEntry>();
            string previousPath = sameSnapshot ? restoreFlowTreePath : "/";
            bool previousLoaded = sameSnapshot && restoreFlowTreeLoaded;
            if (!sameSnapshot)
            {
                SelectRestoreFlowSnapshot(snapshot.Id);
            }
            restoreFlowConfiguration = fresh;
            ClearRestoreFlowTreeError();
            restoreFlowFailedOperation = string.Empty;
            IList<RestoreTreeEntry> cached;
            if (TryGetCachedRestoreFlowTree(snapshot.Id, path, out cached))
            {
                // Read earlier in this flow, from a snapshot that cannot have changed: shown again, nothing is asked.
                ApplyRestoreFlowTreeListing(path, cached);
                return true;
            }
            restoreFlowTreeLoadedBeforeRead = previousLoaded;
            restoreFlowTreePath = path;
            restoreFlowTreeEntries = new List<RestoreTreeEntry>();
            restoreFlowTreeLoaded = false;
            restoreFlowBusy = true;
            restoreFlowCancelRequested = false;
            restoreFlowAwaitingApproval = false;
            restoreFlowStep = "files";
            restoreFlowStatus = "loading";
            restoreFlowProgressStage = "reading";
            restoreFlowProgressMessage = "Reading the selected snapshot folder.";
            restoreFlowProgressPercent = 0;
            SetRestoreFlowMessage("Loading files", "Reading " + path + " from the immutable snapshot.");
            int operation = ++restoreFlowOperationGeneration;
            PublishWebPresentationState();
            LoadRestoreFlowTreeAsync(fresh, snapshot, path, operation, previousPath, previousEntries);
            return true;
        }

        private async void LoadRestoreFlowTreeAsync(
            SourceConfiguration configuration,
            RestoreSnapshot snapshot,
            string path,
            int operation,
            string previousPath,
            IList<RestoreTreeEntry> previousEntries)
        {
            RestoreManagerResult result;
            RestoreSessionHost session = restoreFlowApprovalSession;
            try
            {
                result = await Task.Run(delegate
                {
                    return RestoreManagerLauncher.ListTree(
                        configuration,
                        snapshot.Id,
                        path,
                        snapshot.IsLegacyUnbound,
                        session,
                        delegate { OnRestoreFlowApprovalRequested(operation); },
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                if (restoreFlowOpen && operation == restoreFlowOperationGeneration &&
                                    restoreFlowAwaitingApproval)
                                {
                                    restoreFlowAwaitingApproval = false;
                                    SetRestoreFlowMessage("Loading files", "Reading " + path + " from the immutable snapshot.");
                                    PublishWebPresentationState();
                                }
                            }));
                        },
                        delegate(RestoreManagerProgress progress)
                        {
                            OnRestoreFlowProgress(progress, operation);
                        });
                });
            }
            catch (Exception exception)
            {
                result = RestoreManagerResult.Failure(exception.Message, -1);
            }
            if (!restoreFlowOpen || operation != restoreFlowOperationGeneration)
            {
                return;
            }
            restoreFlowBusy = false;
            restoreFlowAwaitingApproval = false;
            if (restoreFlowCancelRequested)
            {
                FailRestoreFlowTreeRead(
                    path,
                    "The folder read was cancelled before any restore operation started.",
                    previousPath,
                    previousEntries);
                return;
            }
            SourceConfiguration freshAfterRead;
            string freshnessError;
            if (!TryGetFreshRestoreFlowConfiguration(out freshAfterRead, out freshnessError))
            {
                EndRestoreFlowReadAfterFailedCheck("tree", freshnessError, path, previousPath, previousEntries);
                return;
            }
            restoreFlowConfiguration = freshAfterRead;
            if (result.UserCancelled)
            {
                FailRestoreFlowTreeRead(
                    path,
                    "Windows approval was cancelled, so this folder was not read.",
                    previousPath,
                    previousEntries);
                return;
            }
            if (!result.Succeeded)
            {
                FailRestoreFlowTreeRead(
                    path,
                    string.IsNullOrWhiteSpace(result.ErrorMessage)
                        ? "The snapshot folder could not be read."
                        : result.ErrorMessage,
                    previousPath,
                    previousEntries);
                return;
            }
            IList<RestoreTreeEntry> entries = result.Entries ?? new List<RestoreTreeEntry>();
            if (string.Equals(snapshot.Id, restoreFlowSelectedSnapshotId, StringComparison.OrdinalIgnoreCase))
            {
                StoreRestoreFlowTreeListing(snapshot.Id, path, entries);
            }
            ApplyRestoreFlowTreeListing(path, entries);
        }

        // Shows a folder that was read (now, or earlier in this flow) and records what it holds as observed, which is what a
        // selection is checked against.
        private void ApplyRestoreFlowTreeListing(string path, IList<RestoreTreeEntry> entries)
        {
            restoreFlowTreePath = path;
            restoreFlowTreeEntries = entries ?? new List<RestoreTreeEntry>();
            restoreFlowTreeLoaded = true;
            foreach (RestoreTreeEntry entry in restoreFlowTreeEntries)
            {
                string observedPath;
                string observedError;
                if (entry != null &&
                    TryNormalizeRestoreFlowTreePath(entry.EntryPath, out observedPath, out observedError) &&
                    observedPath != "/")
                {
                    restoreFlowObservedPaths.Add(observedPath);
                }
            }
            restoreFlowStep = "files";
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage(
                "Choose files",
                restoreFlowTreeEntries.Count.ToString(CultureInfo.CurrentCulture) +
                    " entr" + (restoreFlowTreeEntries.Count == 1 ? "y" : "ies") +
                    " loaded from " + path + ". Select paths or choose the entire snapshot.");
            PublishWebPresentationState();
        }

        private static string RestoreFlowTreeCacheKey(string snapshotId, string path)
        {
            return (snapshotId ?? string.Empty).ToLowerInvariant() + "\n" + (path ?? string.Empty);
        }

        private bool TryGetCachedRestoreFlowTree(string snapshotId, string path, out IList<RestoreTreeEntry> entries)
        {
            entries = null;
            return restoreFlowTreeCache != null &&
                restoreFlowTreeCache.TryGetValue(RestoreFlowTreeCacheKey(snapshotId, path), out entries) &&
                entries != null;
        }

        private void StoreRestoreFlowTreeListing(string snapshotId, string path, IList<RestoreTreeEntry> entries)
        {
            if (restoreFlowTreeCache == null || restoreFlowTreeCacheOrder == null)
            {
                restoreFlowTreeCache = new Dictionary<string, IList<RestoreTreeEntry>>(StringComparer.Ordinal);
                restoreFlowTreeCacheOrder = new List<string>();
            }
            string key = RestoreFlowTreeCacheKey(snapshotId, path);
            if (!restoreFlowTreeCache.ContainsKey(key))
            {
                restoreFlowTreeCacheOrder.Add(key);
            }
            restoreFlowTreeCache[key] = entries ?? new List<RestoreTreeEntry>();
            // A bounded cache: the folder read longest ago goes first, and is simply read again if it is opened again.
            while (restoreFlowTreeCacheOrder.Count > RestoreFlowMaximumCachedFolders)
            {
                restoreFlowTreeCache.Remove(restoreFlowTreeCacheOrder[0]);
                restoreFlowTreeCacheOrder.RemoveAt(0);
            }
        }

        private void ClearRestoreFlowTreeCache()
        {
            restoreFlowTreeCache = null;
            restoreFlowTreeCacheOrder = null;
        }

        // Ends the flow's restore approval session, if it has one (closing Restore, a changed plan, Reload Restore, exiting).
        private void CloseRestoreFlowApprovalSession()
        {
            RestoreSessionHost session = restoreFlowApprovalSession;
            restoreFlowApprovalSession = null;
            if (session != null)
            {
                session.Close();
            }
        }

        // Called (from the worker) just before Windows shows its approval prompt for a protected step.
        private void OnRestoreFlowApprovalRequested(int operation)
        {
            Dispatcher.BeginInvoke(new Action(delegate
            {
                if (!restoreFlowOpen || !restoreFlowBusy || operation != restoreFlowOperationGeneration)
                {
                    return;
                }
                restoreFlowAwaitingApproval = true;
                if (restoreFlowStep != "progress")
                {
                    SetRestoreFlowMessage("Waiting for Windows approval…", RestoreFlowApprovalNotice());
                }
                PublishWebPresentationState();
            }));
        }

        // What the person is told while Windows asks: once per restore session, or for each step without one.
        private string RestoreFlowApprovalNotice()
        {
            RestoreSessionHost session = restoreFlowApprovalSession;
            if (session == null)
            {
                return "Windows asks for approval for each protected step. Reading the backup does not change it.";
            }
            return session.Opened > 0
                ? "The approved restore session ended, so Windows will ask again to allow Rewindle to read and restore from your backup."
                : "Windows will ask once to allow Rewindle to read and restore from your backup.";
        }

        // Whether the next protected step needs a Windows approval: always without a session, and with one only once it ended.
        private bool RestoreFlowNextStepNeedsApproval()
        {
            RestoreSessionHost session = restoreFlowApprovalSession;
            return session == null || !session.HasLiveSession;
        }

        private bool SelectRestoreFlowPaths(
            IDictionary<string, object> payload,
            out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            string snapshotId = WebReadString(payload, "snapshotId", 128).Trim().ToLowerInvariant();
            if (string.IsNullOrWhiteSpace(snapshotId) ||
                !string.Equals(snapshotId, restoreFlowSelectedSnapshotId, StringComparison.OrdinalIgnoreCase))
            {
                error = "The file selection belongs to a different snapshot. Choose the current snapshot again.";
                return false;
            }
            bool wholeSnapshot = ReadRestoreFlowBoolean(payload, "wholeSnapshot");
            string rawPaths = WebReadString(payload, "paths", 64 * 1024);
            IList<string> paths;
            try
            {
                paths = ParseRestoreFlowPaths(rawPaths);
            }
            catch (Exception exception)
            {
                error = exception.Message;
                return false;
            }
            if (wholeSnapshot)
            {
                paths = new List<string>();
            }
            else
            {
                foreach (string path in paths)
                {
                    if (!restoreFlowObservedPaths.Contains(path))
                    {
                        error = "One selected path was not observed in the current snapshot browser. Browse it again before continuing.";
                        return false;
                    }
                }
            }
            restoreFlowSelectedPaths = paths;
            restoreFlowWholeSnapshotSelected = wholeSnapshot;
            InvalidateRestoreFlowReview();
            restoreFlowStep = "files";
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage(
                wholeSnapshot ? "Entire snapshot selected" : "Restore scope updated",
                wholeSnapshot
                    ? "Every path in this immutable snapshot will be restored. Review the destination next."
                    : paths.Count.ToString(CultureInfo.CurrentCulture) +
                        " snapshot path" + (paths.Count == 1 ? string.Empty : "s") +
                        " selected. Review the destination next.");
            PublishWebPresentationState();
            return true;
        }

        private bool BrowseRestoreFlowDestination(out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            string path;
            try
            {
                path = ShowModernFolderPicker(
                    "Choose a restore destination",
                    "Use destination",
                    "Choose a new or empty folder for the restored copy.");
            }
            catch (Exception exception)
            {
                error = "The destination folder picker could not open. " + exception.Message;
                return false;
            }
            if (string.IsNullOrWhiteSpace(path))
            {
                return true;
            }
            return BeginRestoreFlowDestinationValidation(path, out error);
        }

        private bool NavigateRestoreFlow(
            IDictionary<string, object> payload,
            out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            string step = WebReadString(payload, "step", 32).Trim().ToLowerInvariant();
            if (step == "backup")
            {
                restoreFlowStep = "backup";
                restoreFlowStatus = "ready";
                SetRestoreFlowMessage("Choose a backup", "Select one immutable snapshot to continue.");
            }
            else if (step == "files")
            {
                // Choosing a backup goes on to Choose files and reads nothing: "Everything in this snapshot" needs no folder,
                // and the root is read only when the person asks to browse it (restoreFlowBrowseFiles).
                string chosenId = WebReadString(payload, "snapshotId", 128).Trim().ToLowerInvariant();
                if (chosenId.Length > 0)
                {
                    RestoreSnapshot chosen = FindRestoreFlowSnapshot(chosenId);
                    if (chosen == null)
                    {
                        error = "Choose one snapshot from the current protected history.";
                        return false;
                    }
                    if (!string.Equals(chosen.Id, restoreFlowSelectedSnapshotId, StringComparison.OrdinalIgnoreCase))
                    {
                        SelectRestoreFlowSnapshot(chosen.Id);
                    }
                }
                if (FindRestoreFlowSnapshot(restoreFlowSelectedSnapshotId) == null)
                {
                    error = "Choose one immutable snapshot before browsing files.";
                    return false;
                }
                restoreFlowStep = "files";
                restoreFlowStatus = "ready";
                SetRestoreFlowMessage(
                    "Choose files",
                    restoreFlowTreeLoaded
                        ? "Select paths from this snapshot or choose the entire snapshot."
                        : "Restore everything in this snapshot, or browse its folders to choose files.");
            }
            else if (step == "destination")
            {
                if (FindRestoreFlowSnapshot(restoreFlowSelectedSnapshotId) == null)
                {
                    error = "Choose one immutable snapshot before choosing a destination.";
                    return false;
                }
                if (!restoreFlowWholeSnapshotSelected && restoreFlowSelectedPaths.Count == 0)
                {
                    error = "Choose one or more snapshot paths, or explicitly choose the entire snapshot first.";
                    return false;
                }
                restoreFlowStep = "destination";
                restoreFlowStatus = "ready";
                SetRestoreFlowMessage("Choose a destination", "Restore writes only to a new or empty separate folder.");
            }
            else
            {
                error = "The requested restore step is invalid.";
                return false;
            }
            ClearRestoreFlowTreeError();
            if (restoreFlowStep != "review")
            {
                InvalidateRestoreFlowReview();
            }
            PublishWebPresentationState();
            return true;
        }

        private bool ValidateRestoreFlowDestinationCommand(
            IDictionary<string, object> payload,
            out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            string path = WebReadString(payload, "path", 4096);
            if (path.Trim().Length == 0)
            {
                path = WebReadString(payload, "destination", 4096);
            }
            return BeginRestoreFlowDestinationValidation(path, out error);
        }

        private bool BeginRestoreFlowDestinationValidation(string path, out string error)
        {
            error = string.Empty;
            if (path == null || path.Trim().Length == 0)
            {
                error = "Choose a new or empty destination folder.";
                return false;
            }
            if (path.Trim().Length > 4096)
            {
                error = "The destination path is too long.";
                return false;
            }
            SourceConfiguration configuration;
            if (!TryGetFreshRestoreFlowConfiguration(out configuration, out error))
            {
                return false;
            }
            string requestedPath = path.Trim();
            int generation = ++restoreFlowDestinationValidationGeneration;
            restoreFlowDestinationPath = requestedPath;
            restoreFlowDestinationChecking = true;
            restoreFlowDestinationValid = false;
            restoreFlowDestinationError = false;
            restoreFlowDestinationStatus = "Checking that this destination is separate and empty…";
            restoreFlowDestinationFreeBytes = null;
            restoreFlowDestinationDrive = string.Empty;
            InvalidateRestoreFlowReview();
            restoreFlowStep = "destination";
            restoreFlowStatus = "loading";
            SetRestoreFlowMessage("Checking destination", "The restore can write only to a new or empty folder.");
            PublishWebPresentationState();
            ValidateRestoreFlowDestinationAsync(configuration, requestedPath, generation);
            return true;
        }

        private async void ValidateRestoreFlowDestinationAsync(
            SourceConfiguration configuration,
            string requestedPath,
            int generation)
        {
            RestoreFlowDestinationInspection inspection;
            try
            {
                inspection = await Task.Run(delegate
                {
                    return InspectRestoreFlowDestination(configuration, requestedPath);
                });
            }
            catch (Exception exception)
            {
                inspection = new RestoreFlowDestinationInspection
                {
                    Valid = false,
                    Error = true,
                    Message = "The destination could not be checked: " + exception.Message
                };
            }
            if (!restoreFlowOpen || generation != restoreFlowDestinationValidationGeneration ||
                !string.Equals(requestedPath, restoreFlowDestinationPath, StringComparison.Ordinal))
            {
                return;
            }
            ApplyRestoreFlowDestinationInspection(inspection);
        }

        private void ApplyRestoreFlowDestinationInspection(RestoreFlowDestinationInspection inspection)
        {
            restoreFlowDestinationChecking = false;
            restoreFlowDestinationValid = inspection != null && inspection.Valid;
            restoreFlowDestinationError = inspection != null && inspection.Error;
            restoreFlowDestinationStatus = inspection == null
                ? "The destination could not be checked yet."
                : inspection.Message;
            restoreFlowDestinationFreeBytes = inspection == null ? null : inspection.FreeBytes;
            restoreFlowDestinationDrive = inspection == null ? string.Empty : inspection.Drive ?? string.Empty;
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage(
                restoreFlowDestinationValid ? "Destination ready" : "Choose a safe destination",
                restoreFlowDestinationStatus);
            PublishWebPresentationState();
        }

        private bool ReviewRestoreFlow(out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            SourceConfiguration configuration;
            if (!TryGetFreshRestoreFlowConfiguration(out configuration, out error))
            {
                return false;
            }
            IList<string> errors;
            IList<string> warnings;
            BuildRestoreFlowValidation(out errors, out warnings);
            if (errors.Count > 0)
            {
                error = errors[0];
                restoreFlowStep = string.IsNullOrWhiteSpace(restoreFlowSelectedSnapshotId)
                    ? "backup"
                    : !restoreFlowDestinationValid ? "destination" : "files";
                restoreFlowStatus = "ready";
                SetRestoreFlowMessage("Review is not ready", error);
                PublishWebPresentationState();
                return false;
            }

            RestoreFlowDestinationInspection inspection = InspectRestoreFlowDestination(
                configuration,
                restoreFlowDestinationPath);
            ApplyRestoreFlowDestinationInspectionWithoutPublish(inspection);
            if (!restoreFlowDestinationValid)
            {
                error = restoreFlowDestinationStatus;
                restoreFlowStep = "destination";
                restoreFlowStatus = "ready";
                PublishWebPresentationState();
                return false;
            }
            restoreFlowReviewFingerprint = ComputeRestoreFlowReviewFingerprint(
                configuration,
                restoreFlowSelectedSnapshotId,
                restoreFlowSelectedPaths,
                restoreFlowWholeSnapshotSelected,
                restoreFlowDestinationPath);
            restoreFlowReviewReady = true;
            restoreFlowStep = "review";
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage(
                "Review restore",
                "Confirm the immutable snapshot, restore scope, and separate destination before starting.");
            PublishWebPresentationState();
            return true;
        }

        private bool StartRestoreFlow(
            IDictionary<string, object> payload,
            out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            if (!restoreFlowReviewReady || restoreFlowStep != "review")
            {
                error = "Review the snapshot, restore scope, and destination before starting.";
                return false;
            }
            SourceConfiguration configuration;
            if (!TryGetFreshRestoreFlowConfiguration(out configuration, out error))
            {
                return false;
            }
            IList<string> errors;
            IList<string> warnings;
            BuildRestoreFlowValidation(out errors, out warnings);
            if (errors.Count > 0)
            {
                error = errors[0];
                InvalidateRestoreFlowReview();
                restoreFlowStep = "destination";
                restoreFlowStatus = "ready";
                SetRestoreFlowMessage("Review expired", error);
                PublishWebPresentationState();
                return false;
            }
            string expectedFingerprint = ComputeRestoreFlowReviewFingerprint(
                configuration,
                restoreFlowSelectedSnapshotId,
                restoreFlowSelectedPaths,
                restoreFlowWholeSnapshotSelected,
                restoreFlowDestinationPath);
            if (!string.Equals(expectedFingerprint, restoreFlowReviewFingerprint, StringComparison.Ordinal))
            {
                error = "The restore review changed. Review it again before starting.";
                InvalidateRestoreFlowReview();
                restoreFlowStep = "review";
                restoreFlowStatus = "ready";
                SetRestoreFlowMessage("Review expired", error);
                PublishWebPresentationState();
                return false;
            }
            RestoreSnapshot snapshot = FindRestoreFlowSnapshot(restoreFlowSelectedSnapshotId);
            if (snapshot == null)
            {
                error = "The selected snapshot is no longer available. Refresh snapshots and choose it again.";
                return false;
            }
            bool legacyConfirmed = ReadRestoreFlowBoolean(payload, "legacyConfirmed");
            if (snapshot.IsLegacyUnbound && !legacyConfirmed)
            {
                error = "This legacy snapshot requires explicit confirmation before restore.";
                return false;
            }

            RestoreFlowDestinationInspection inspection = InspectRestoreFlowDestination(
                configuration,
                restoreFlowDestinationPath);
            ApplyRestoreFlowDestinationInspectionWithoutPublish(inspection);
            if (!restoreFlowDestinationValid)
            {
                error = restoreFlowDestinationStatus;
                InvalidateRestoreFlowReview();
                restoreFlowStep = "destination";
                restoreFlowStatus = "ready";
                PublishWebPresentationState();
                return false;
            }

            if (!CheckRestoreFlowOperationGuards(out error))
            {
                return false;
            }

            restoreFlowConfiguration = configuration;
            restoreFlowBusy = true;
            restoreFlowCancelRequested = false;
            restoreFlowStep = "progress";
            restoreFlowStatus = "running";
            restoreFlowProgressStage = "preflight";
            restoreFlowAwaitingApproval = RestoreFlowNextStepNeedsApproval();
            restoreFlowProgressMessage = restoreFlowAwaitingApproval
                ? "Waiting for Windows approval before writing the alternate folder."
                : "Starting the restore in the approved restore session.";
            restoreFlowProgressPercent = 0;
            restoreFlowResultSnapshotId = snapshot.Id;
            ClearRestoreFlowResult();
            restoreFlowResultSnapshotId = snapshot.Id;
            SetRestoreFlowMessage(
                "Starting protected restore",
                "Only the separate destination will be written. Existing files are never overwritten.");
            int operation = ++restoreFlowOperationGeneration;
            IList<string> includes = new List<string>(restoreFlowSelectedPaths);
            PublishWebPresentationState();
            RunRestoreFlowAsync(
                configuration,
                snapshot,
                includes,
                operation);
            return true;
        }

        private async void RunRestoreFlowAsync(
            SourceConfiguration configuration,
            RestoreSnapshot snapshot,
            IList<string> includes,
            int operation)
        {
            RestoreManagerResult result;
            RestoreSessionHost session = restoreFlowApprovalSession;
            string destination = restoreFlowDestinationPath;
            try
            {
                result = await Task.Run(delegate
                {
                    return RestoreManagerLauncher.Restore(
                        configuration,
                        snapshot.Id,
                        destination,
                        includes,
                        snapshot.IsLegacyUnbound,
                        session,
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                if (restoreFlowOpen && operation == restoreFlowOperationGeneration)
                                {
                                    restoreFlowAwaitingApproval = true;
                                    restoreFlowProgressMessage = "Waiting for Windows approval before writing the alternate folder.";
                                    SetRestoreFlowMessage("Waiting for Windows approval…", RestoreFlowApprovalNotice());
                                    PublishWebPresentationState();
                                }
                            }));
                        },
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                if (restoreFlowOpen && operation == restoreFlowOperationGeneration)
                                {
                                    // Until the manager reports its own progress, the line under the stage
                                    // must not keep saying the approval is still pending.
                                    restoreFlowAwaitingApproval = false;
                                    restoreFlowProgressMessage =
                                        "Windows approval received. Checking the request and the destination before anything is written.";
                                    SetRestoreFlowMessage(
                                        "Restore approved",
                                        "Restoring and verifying the selected snapshot in the alternate folder.");
                                    PublishWebPresentationState();
                                }
                            }));
                        },
                        delegate(RestoreManagerProgress progress)
                        {
                            OnRestoreFlowProgress(progress, operation);
                        });
                });
            }
            catch (Exception exception)
            {
                result = RestoreManagerResult.Failure(exception.Message, -1);
            }
            if (!restoreFlowOpen || operation != restoreFlowOperationGeneration)
            {
                return;
            }
            restoreFlowBusy = false;
            restoreFlowAwaitingApproval = false;
            restoreFlowLastResult = result;
            if (result.UserCancelled)
            {
                FailRestoreFlow(
                    "restore",
                    "Windows approval cancelled",
                    "No restore was started.",
                    "cancelled");
                PublishWebPresentationState();
                return;
            }
            if (result.Succeeded && result.Report != null && result.Report.Verified)
            {
                restoreFlowStep = "success";
                restoreFlowStatus = "succeeded";
                restoreFlowResultStatus = "success";
                restoreFlowResultTarget = result.Report.Target;
                restoreFlowResultVerified = true;
                restoreFlowResultError = string.Empty;
                SetRestoreFlowMessage(
                    "Restore complete and verified",
                    "The restored copy is ready at " + result.Report.Target + ".");
                PublishWebPresentationState();
                return;
            }
            if (result.Partial && result.Report != null)
            {
                restoreFlowFailedOperation = "restore";
                restoreFlowStep = "partial";
                restoreFlowStatus = "partial";
                restoreFlowResultStatus = "partial";
                restoreFlowResultTarget = result.Report.Target;
                restoreFlowResultVerified = result.Report.Verified;
                restoreFlowResultError = result.ErrorMessage ?? "The restore stopped before verification completed.";
                SetRestoreFlowMessage(
                    "Restore incomplete",
                    restoreFlowResultError + " Partial files remain in the alternate destination; live files were not changed.");
                PublishWebPresentationState();
                return;
            }
            FailRestoreFlow(
                "restore",
                "Restore did not complete",
                result.ErrorMessage,
                "error");
            PublishWebPresentationState();
        }

        private void OnRestoreFlowProgress(RestoreManagerProgress progress, int operation)
        {
            if (progress == null)
            {
                return;
            }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                // Progress belongs to an operation that is still running. One that arrives after the operation has
                // finished must not put its status back to "loading", which nothing would then end.
                if (!restoreFlowOpen || !restoreFlowBusy || operation != restoreFlowOperationGeneration)
                {
                    return;
                }
                restoreFlowProgressStage = progress.Stage ?? string.Empty;
                restoreFlowProgressMessage = progress.Message ?? string.Empty;
                restoreFlowProgressPercent = Math.Max(0, Math.Min(100, progress.Percent));
                restoreFlowStatus = restoreFlowStep == "progress" ? "running" : "loading";
                SetRestoreFlowMessage(FriendlyRestoreFlowStage(progress.Stage), progress.Message);
                PublishWebPresentationState();
            }));
        }

        private bool CancelRestoreFlow(out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error))
            {
                return false;
            }
            if (restoreFlowBusy)
            {
                if (restoreFlowStep == "progress")
                {
                    error = "The protected restore is already running and cannot be cancelled safely. Keep the flow open until it reaches a final result.";
                    return false;
                }
                restoreFlowCancelRequested = true;
                restoreFlowStatus = "canceling";
                SetRestoreFlowMessage(
                    "Cancellation requested",
                    "The protected operation will finish safely before its final result is shown.");
                PublishWebPresentationState();
                return true;
            }
            return CloseRestoreFlow(out error);
        }

        private bool RetryRestoreFlow(out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            // Decide where to go before the result and its failed-operation marker are cleared.
            string route = ResolveRestoreFlowRetryRoute();
            if (route == "reload")
            {
                // The protected plan changed. Nothing else can recover: every command would fail the same
                // freshness check, so the user explicitly reloads Restore against the current plan. The
                // failure stays recorded until the reload succeeds, so a blocked reload can be retried.
                return ReloadRestoreFlowConfiguration(out error);
            }
            ClearRestoreFlowResult();
            restoreFlowCancelRequested = false;
            if (route == "review")
            {
                // Windows approval was declined, so nothing was written. Go back to Review with the scope
                // and destination intact. Review re-inspects the destination and re-fingerprints the plan,
                // so no guard is skipped. This must run before the destination state is reset below.
                return ReviewRestoreFlow(out error);
            }
            if (route == "files")
            {
                restoreFlowStep = "files";
                restoreFlowStatus = "ready";
                SetRestoreFlowMessage("Choose files", "Select paths from this snapshot or choose the entire snapshot.");
                PublishWebPresentationState();
                return true;
            }
            if (route == "snapshots")
            {
                BeginRestoreFlowSnapshotLoad();
                return true;
            }
            InvalidateRestoreFlowReview();
            restoreFlowDestinationValid = false;
            restoreFlowDestinationChecking = false;
            restoreFlowDestinationStatus = string.IsNullOrWhiteSpace(restoreFlowDestinationPath)
                ? "Choose a new or empty folder."
                : "Choose a new destination or check the existing path again.";
            restoreFlowStep = "destination";
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage("Choose a destination again", restoreFlowDestinationStatus);
            PublishWebPresentationState();
            return true;
        }

        // Where "Try again" goes after a failure: "reload" (plan changed), "review" (restore approval
        // declined), "files" (folder read), "snapshots" (history read) or "destination" (restore failed).
        private string ResolveRestoreFlowRetryRoute()
        {
            string operation = restoreFlowFailedOperation ?? string.Empty;
            if (operation == "config")
            {
                return "reload";
            }
            if (operation == "restore" &&
                string.Equals(restoreFlowResultStatus, "cancelled", StringComparison.Ordinal))
            {
                return "review";
            }
            if (operation == "tree")
            {
                return "files";
            }
            if (operation == "snapshots" ||
                restoreFlowSnapshots == null ||
                restoreFlowSnapshots.Count == 0)
            {
                return "snapshots";
            }
            return "destination";
        }

        private bool CloseRestoreFlow(out string error)
        {
            error = string.Empty;
            if (!RequireRestoreFlowOpen(out error))
            {
                return false;
            }
            if (restoreFlowBusy)
            {
                error = "Wait for the protected restore operation to finish before closing this flow.";
                return false;
            }
            restoreFlowOpen = false;
            restoreFlowBusy = false;
            restoreFlowOperationGeneration++;
            restoreFlowDestinationValidationGeneration++;
            CloseRestoreFlowApprovalSession();
            ClearRestoreFlowTreeCache();
            restoreFlowTreeLoaded = false;
            restoreFlowAwaitingApproval = false;
            restoreFlowConfiguration = null;
            restoreFlowSnapshots = new List<RestoreSnapshot>();
            restoreFlowTreeEntries = new List<RestoreTreeEntry>();
            restoreFlowObservedPaths.Clear();
            restoreFlowSelectedPaths = new List<string>();
            restoreFlowSelectedSnapshotId = string.Empty;
            restoreFlowReviewFingerprint = string.Empty;
            restoreFlowReviewReady = false;
            ClearRestoreFlowTreeError();
            ClearRestoreFlowResult();
            PublishWebPresentationState();
            return true;
        }

        // The folder a finished restore reported, for the result screen's Open and Copy. The page never names the folder (the
        // commands carry no payload): only what the protected manager reported (restoreFlowResultTarget) is used, and only once the
        // restore has ended with files to look at, which is a verified restore or a partial one that leaves what it restored in
        // place. As a second check the folder must be the destination that was validated for this restore, or inside it, so a
        // report can never point Explorer or the clipboard anywhere else. It does not wait for the flow to be idle and it needs no
        // approval: the dashboard runs unelevated, and these only look at, or copy the name of, a folder it was told about.
        private bool TryGetRestoreFlowResultFolder(out string folder, out string error)
        {
            folder = string.Empty;
            if (!RequireRestoreFlowOpen(out error))
            {
                return false;
            }
            if (restoreFlowBusy ||
                (restoreFlowStep != "success" && restoreFlowStep != "partial"))
            {
                error = "The restored folder is available once a restore has finished.";
                return false;
            }
            string target = restoreFlowResultTarget;
            if (string.IsNullOrWhiteSpace(target))
            {
                error = "The restore did not report a folder.";
                return false;
            }
            try
            {
                string normalizedTarget = SourceConfiguration.NormalizePath(target.Trim());
                string normalizedDestination = SourceConfiguration.NormalizePath(
                    restoreFlowDestinationPath ?? string.Empty);
                if (!RestoreFlowPathWithin(normalizedTarget, normalizedDestination))
                {
                    error = "The reported folder is not the destination chosen for this restore.";
                    return false;
                }
                if (!Directory.Exists(normalizedTarget))
                {
                    error = "The restored folder was not found. It may have been moved or deleted.";
                    return false;
                }
                folder = normalizedTarget;
                return true;
            }
            catch (Exception exception)
            {
                error = "The restored folder could not be checked. " + exception.Message;
                return false;
            }
        }

        private bool OpenRestoreFlowDestination(out string error)
        {
            string folder;
            if (!TryGetRestoreFlowResultFolder(out folder, out error))
            {
                return false;
            }
            try
            {
                // Quoted the way the native restore window quotes it, so a name with spaces is one argument.
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "\"" + folder.Replace("\"", string.Empty) + "\"",
                    UseShellExecute = true
                });
                return true;
            }
            catch (Exception exception)
            {
                error = "The restored folder could not be opened. " + exception.Message;
                return false;
            }
        }

        // The page shows a command's message as a notice, whether or not it succeeded, so a copy says so in `error`.
        private bool CopyRestoreFlowDestination(out string error)
        {
            string folder;
            if (!TryGetRestoreFlowResultFolder(out folder, out error))
            {
                return false;
            }
            if (!ClipboardText.TrySet(folder, out error))
            {
                return false;
            }
            error = "Restore folder path copied.";
            return true;
        }

        private bool RequireRestoreFlowOpen(out string error)
        {
            if (!restoreFlowOpen)
            {
                error = "Open Restore before using the guided restore flow.";
                return false;
            }
            error = string.Empty;
            return true;
        }

        private bool CheckRestoreFlowOperationGuards(out string error)
        {
            if (sourceOperationInProgress || BackupBlocksSourceChanges() || previewEnabled)
            {
                error = "Wait for the active backup, protected folder change, repository operation, or schedule operation to finish before restoring.";
                return false;
            }
            error = string.Empty;
            return true;
        }

        private bool RequireRestoreFlowIdle(out string error)
        {
            if (restoreFlowBusy || restoreFlowDestinationChecking)
            {
                error = restoreFlowDestinationChecking
                    ? "The destination is still being checked."
                    : "The protected restore flow is still working.";
                return false;
            }
            error = string.Empty;
            return true;
        }

        private void SelectRestoreFlowSnapshot(string snapshotId)
        {
            restoreFlowSelectedSnapshotId = snapshotId ?? string.Empty;
            restoreFlowTreeEntries = new List<RestoreTreeEntry>();
            restoreFlowTreeLoaded = false;
            ClearRestoreFlowTreeCache();
            restoreFlowObservedPaths.Clear();
            ClearRestoreFlowScope();
            ClearRestoreFlowTreeError();
            InvalidateRestoreFlowReview();
            restoreFlowTreePath = "/";
        }

        private void ClearRestoreFlowScope()
        {
            restoreFlowSelectedPaths = new List<string>();
            restoreFlowWholeSnapshotSelected = false;
        }

        private void InvalidateRestoreFlowReview()
        {
            restoreFlowReviewReady = false;
            restoreFlowReviewFingerprint = string.Empty;
        }

        private RestoreSnapshot FindRestoreFlowSnapshot(string snapshotId)
        {
            if (string.IsNullOrWhiteSpace(snapshotId) || restoreFlowSnapshots == null)
            {
                return null;
            }
            return restoreFlowSnapshots.FirstOrDefault(snapshot =>
                string.Equals(snapshot.Id, snapshotId, StringComparison.OrdinalIgnoreCase));
        }

        private bool TryGetFreshRestoreFlowConfiguration(
            out SourceConfiguration configuration,
            out string error)
        {
            configuration = null;
            error = string.Empty;
            try
            {
                configuration = SourceConfiguration.Load();
                string hash = ComputeRestoreFlowConfigHash(configuration);
                if (restoreFlowConfiguration == null ||
                    !string.Equals(hash, restoreFlowConfigHash, StringComparison.Ordinal) ||
                    configuration.ConfigGeneration != restoreFlowConfigGeneration ||
                    !string.Equals(configuration.PlanId, restoreFlowPlanId, StringComparison.Ordinal))
                {
                    InvalidateRestoreFlowReview();
                    CloseRestoreFlowApprovalSession();
                    ClearRestoreFlowTreeCache();
                    restoreFlowStatus = "failed";
                    restoreFlowStep = "error";
                    restoreFlowFailedOperation = "config";
                    restoreFlowResultStatus = "error";
                    restoreFlowResultError =
                        "The protected backup plan changed while Restore was open. Reload Restore to continue with the current plan.";
                    SetRestoreFlowMessage("Configuration changed", restoreFlowResultError);
                    PublishWebPresentationState();
                    error = "The protected backup configuration changed. Reload Restore to continue with the current plan.";
                    return false;
                }
                return true;
            }
            catch (Exception exception)
            {
                error = "The protected backup configuration could not be checked. " + exception.Message;
                return false;
            }
        }

        private static string ComputeRestoreFlowConfigHash(SourceConfiguration configuration)
        {
            if (configuration == null || string.IsNullOrWhiteSpace(configuration.ConfigurationPath))
            {
                throw new InvalidDataException("The protected configuration path is unavailable.");
            }
            using (FileStream stream = new FileStream(
                configuration.ConfigurationPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                8192,
                FileOptions.SequentialScan))
            using (SHA256 algorithm = SHA256.Create())
            {
                return ToLowerHex(algorithm.ComputeHash(stream));
            }
        }

        private static string ToLowerHex(byte[] bytes)
        {
            StringBuilder builder = new StringBuilder(bytes.Length * 2);
            foreach (byte value in bytes)
            {
                builder.Append(value.ToString("x2", CultureInfo.InvariantCulture));
            }
            return builder.ToString();
        }

        private sealed class RestoreFlowDestinationInspection
        {
            internal bool Valid;
            internal bool Error;
            internal string Message;
            // Free space on the destination's drive and its name ("E:"), for a destination that passed every check; null and empty
            // when the drive would not say. A warning is made from them, never a refusal.
            internal long? FreeBytes;
            internal string Drive;
        }

        private static RestoreFlowDestinationInspection InspectRestoreFlowDestination(
            SourceConfiguration configuration,
            string requestedPath)
        {
            string normalized;
            long? freeBytes = null;
            string driveName = string.Empty;
            try
            {
                if (!IsAbsoluteRestoreFlowPath(requestedPath))
                {
                    return InvalidRestoreFlowDestination(
                        "Use an absolute local path, such as C:\\Restores\\2026-09-14.");
                }
                normalized = SourceConfiguration.NormalizePath(requestedPath.Trim());
            }
            catch (Exception exception)
            {
                return InvalidRestoreFlowDestination("The destination path is invalid: " + exception.Message);
            }
            if (configuration == null)
            {
                return InvalidRestoreFlowDestination("The protected backup configuration is unavailable.");
            }
            if (!HasNormalRestoreFlowDirectoryChain(normalized))
            {
                return InvalidRestoreFlowDestination(
                    "This destination uses a reparse point or link, which is common for OneDrive-synced folders, " +
                    "junctions and symbolic links. Choose a normal local folder.");
            }
            try
            {
                string root = Path.GetPathRoot(normalized);
                DriveInfo drive = new DriveInfo(root);
                if (!drive.IsReady ||
                    (drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable))
                {
                    return InvalidRestoreFlowDestination(
                        "The destination must be on a ready local fixed or removable drive.");
                }
                driveName = root.TrimEnd('\\', '/');
                freeBytes = ReadRestoreFlowFreeBytes(drive);
            }
            catch
            {
                return InvalidRestoreFlowDestination(
                    "The destination drive could not be checked.");
            }
            string[] protectedRoots = new[]
            {
                configuration.RepositoryPath,
                configuration.StateDirectory,
                configuration.InstallRoot
            };
            if (protectedRoots.Any(root => RestoreFlowPathsOverlap(normalized, root)) ||
                configuration.Sources.Any(source => RestoreFlowPathsOverlap(normalized, source.SourcePath)))
            {
                return InvalidRestoreFlowDestination(
                    "Choose a destination separate from the repository, app state, installation, and protected folders.");
            }
            try
            {
                if (File.Exists(normalized))
                {
                    return InvalidRestoreFlowDestination(
                        "This path is an existing file. Existing files are never overwritten.");
                }
                if (Directory.Exists(normalized) && Directory.EnumerateFileSystemEntries(normalized).Any())
                {
                    // Only the wording differs: a drive root is refused for the same reason as any folder that holds something.
                    return InvalidRestoreFlowDestination(IsRestoreFlowDriveRoot(normalized)
                        ? "This is a drive root, which usually holds hidden system folders that Explorer does not show. " +
                            "Choose or create a folder on this drive instead, for example " +
                            Path.Combine(Path.GetPathRoot(normalized), "Rewindle restore") + "."
                        : "This folder is not empty. Choose an empty folder; existing files are never overwritten.");
                }
                return new RestoreFlowDestinationInspection
                {
                    Valid = true,
                    Error = false,
                    Message = Directory.Exists(normalized)
                        ? "Ready · this existing folder is empty. Existing files will not be overwritten."
                        : "Ready · this new folder will be used as the separate restore destination.",
                    FreeBytes = freeBytes,
                    Drive = driveName
                };
            }
            catch (Exception exception)
            {
                return InvalidRestoreFlowDestination("The destination could not be checked: " + exception.Message);
            }
        }

        // How much room the drive says it has. This is only a warning, so a drive that will not say must not turn a destination that
        // passed every check into a refusal: its free space is simply not known.
        private static long? ReadRestoreFlowFreeBytes(DriveInfo drive)
        {
            try
            {
                long free = drive.AvailableFreeSpace;
                return free >= 0 ? (long?)free : null;
            }
            catch (IOException)
            {
                return null;
            }
            catch (UnauthorizedAccessException)
            {
                return null;
            }
        }

        private static RestoreFlowDestinationInspection InvalidRestoreFlowDestination(string message)
        {
            return new RestoreFlowDestinationInspection
            {
                Valid = false,
                Error = true,
                Message = message
            };
        }

        private static bool HasNormalRestoreFlowDirectoryChain(string path)
        {
            try
            {
                DirectoryInfo current = new DirectoryInfo(path);
                while (current != null)
                {
                    if (current.Exists &&
                        (current.Attributes & FileAttributes.ReparsePoint) != 0)
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

        // A path that is nothing but a drive's root, such as E:\. A root normally holds hidden system folders
        // ($RECYCLE.BIN, System Volume Information), so it is rarely empty even when Explorer shows nothing in it.
        private static bool IsRestoreFlowDriveRoot(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return false;
            }
            try
            {
                string root = Path.GetPathRoot(path);
                return !string.IsNullOrEmpty(root) &&
                    string.Equals(
                        path.TrimEnd('\\', '/'),
                        root.TrimEnd('\\', '/'),
                        StringComparison.OrdinalIgnoreCase);
            }
            catch (ArgumentException)
            {
                return false;
            }
        }

        private static bool IsAbsoluteRestoreFlowPath(string value)
        {
            string trimmed = (value ?? string.Empty).Trim();
            return trimmed.Length >= 3 &&
                char.IsLetter(trimmed[0]) &&
                trimmed[1] == ':' &&
                (trimmed[2] == '\\' || trimmed[2] == '/');
        }

        private static bool RestoreFlowPathsOverlap(string first, string second)
        {
            if (string.IsNullOrWhiteSpace(first) || string.IsNullOrWhiteSpace(second))
            {
                return false;
            }
            string left = first.TrimEnd('\\', '/');
            string right = second.TrimEnd('\\', '/');
            return RestoreFlowPathWithin(left, right) || RestoreFlowPathWithin(right, left);
        }

        private static bool RestoreFlowPathWithin(string path, string root)
        {
            if (string.Equals(path, root, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            return path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith(root + Path.AltDirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        }

        private static bool TryNormalizeRestoreFlowTreePath(
            string value,
            out string normalized,
            out string error)
        {
            normalized = (value ?? string.Empty).Trim();
            error = string.Empty;
            if (normalized.Length == 0)
            {
                normalized = "/";
                return true;
            }
            if (!normalized.StartsWith("/", StringComparison.Ordinal) ||
                normalized.IndexOf('\\') >= 0 || normalized.Length > 1024 ||
                normalized.IndexOf("//", StringComparison.Ordinal) >= 0)
            {
                error = "The snapshot folder path is invalid.";
                return false;
            }
            normalized = normalized == "/" ? "/" : normalized.TrimEnd('/');
            foreach (string segment in normalized.Split('/'))
            {
                if (segment == ".." || segment == ".")
                {
                    error = "The snapshot folder path is invalid.";
                    return false;
                }
            }
            return true;
        }

        private static IList<string> ParseRestoreFlowPaths(string value)
        {
            List<string> paths = new List<string>();
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (string raw in (value ?? string.Empty).Replace("\r", string.Empty).Split('\n'))
            {
                string path = raw.Trim();
                if (path.Length == 0)
                {
                    continue;
                }
                string normalized;
                string error;
                if (!TryNormalizeRestoreFlowTreePath(path, out normalized, out error) || normalized == "/")
                {
                    throw new InvalidDataException("A selected snapshot path is invalid.");
                }
                if (seen.Add(normalized))
                {
                    paths.Add(normalized);
                }
            }
            if (paths.Count > RestoreFlowMaximumPaths)
            {
                throw new InvalidDataException(
                    "Select at most " + RestoreFlowMaximumPaths.ToString(CultureInfo.InvariantCulture) +
                    " paths for one restore.");
            }
            return paths;
        }

        private static bool ReadRestoreFlowBoolean(
            IDictionary<string, object> payload,
            string key)
        {
            if (payload == null)
            {
                return false;
            }
            object raw;
            if (!payload.TryGetValue(key, out raw) || raw == null)
            {
                return false;
            }
            if (raw is bool)
            {
                return (bool)raw;
            }
            bool parsed;
            return bool.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture), out parsed) && parsed;
        }

        private void BuildRestoreFlowValidation(
            out IList<string> errors,
            out IList<string> warnings)
        {
            errors = new List<string>();
            warnings = new List<string>();
            RestoreSnapshot snapshot = FindRestoreFlowSnapshot(restoreFlowSelectedSnapshotId);
            if (snapshot == null)
            {
                errors.Add("Choose one immutable snapshot before continuing.");
            }
            if (!restoreFlowWholeSnapshotSelected && restoreFlowSelectedPaths.Count == 0)
            {
                errors.Add("Choose one or more snapshot paths, or explicitly choose the entire snapshot.");
            }
            if (restoreFlowWholeSnapshotSelected && restoreFlowSelectedPaths.Count != 0)
            {
                errors.Add("Choose either selected paths or the entire snapshot, not both.");
            }
            if (restoreFlowDestinationChecking || !restoreFlowDestinationValid)
            {
                errors.Add(string.IsNullOrWhiteSpace(restoreFlowDestinationStatus)
                    ? "Choose a new or empty destination folder."
                    : restoreFlowDestinationStatus);
            }
            if (snapshot != null && snapshot.IsLegacyUnbound)
            {
                warnings.Add("This legacy snapshot is not bound to the current plan ID and requires explicit confirmation before restore.");
            }
            string spaceWarning = BuildRestoreFlowSpaceWarning(snapshot);
            if (spaceWarning != null)
            {
                warnings.Add(spaceWarning);
            }
        }

        // A whole-snapshot restore needs about the snapshot's size in free space, and a little more for the files written beside the data.
        // This only says so. It is a warning and never an error: the size is the size at backup time and the free space was read once, when
        // the destination was checked, so neither can promise how the restore will end. A restore of chosen paths cannot be sized from the
        // snapshot, and an older snapshot may not report its size at all, so neither is compared. It reads what the check stored and never
        // asks the drive, because this runs for every state the page is sent.
        private string BuildRestoreFlowSpaceWarning(RestoreSnapshot snapshot)
        {
            if (snapshot == null || !restoreFlowWholeSnapshotSelected || !restoreFlowDestinationValid ||
                restoreFlowDestinationChecking || !restoreFlowDestinationFreeBytes.HasValue || snapshot.ByteCount <= 0)
            {
                return null;
            }
            long free = restoreFlowDestinationFreeBytes.Value;
            long needed = snapshot.ByteCount + (snapshot.ByteCount / 20);
            if (free >= needed)
            {
                return null;
            }
            string drive = string.IsNullOrWhiteSpace(restoreFlowDestinationDrive)
                ? "the destination drive"
                : restoreFlowDestinationDrive;
            return "This snapshot is about " + TelemetryFormat.FormatBytes(snapshot.ByteCount) + ", but only " +
                TelemetryFormat.FormatBytes(free) + " is free on " + drive + ". The restore may stop part-way.";
        }

        private string ComputeRestoreFlowReviewFingerprint(
            SourceConfiguration configuration,
            string snapshotId,
            IList<string> paths,
            bool wholeSnapshot,
            string destination)
        {
            string payload = string.Join(
                "\n",
                new[]
                {
                    restoreFlowConfigHash ?? string.Empty,
                    configuration == null ? string.Empty : configuration.PlanId ?? string.Empty,
                    configuration == null ? string.Empty : configuration.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                    snapshotId ?? string.Empty,
                    wholeSnapshot ? "1" : "0",
                    string.Join("\n", (paths ?? new List<string>()).ToArray()),
                    destination ?? string.Empty
                });
            using (SHA256 algorithm = SHA256.Create())
            {
                return ToLowerHex(algorithm.ComputeHash(new UTF8Encoding(false).GetBytes(payload)));
            }
        }

        private void ApplyRestoreFlowDestinationInspectionWithoutPublish(
            RestoreFlowDestinationInspection inspection)
        {
            restoreFlowDestinationChecking = false;
            restoreFlowDestinationValid = inspection != null && inspection.Valid;
            restoreFlowDestinationError = inspection != null && inspection.Error;
            restoreFlowDestinationStatus = inspection == null
                ? "The destination could not be checked yet."
                : inspection.Message;
            restoreFlowDestinationFreeBytes = inspection == null ? null : inspection.FreeBytes;
            restoreFlowDestinationDrive = inspection == null ? string.Empty : inspection.Drive ?? string.Empty;
        }

        private void SetRestoreFlowMessage(string title, string detail)
        {
            restoreFlowMessageTitle = title ?? string.Empty;
            restoreFlowMessageDetail = detail ?? string.Empty;
        }

        private void SetRestoreFlowFailure(string title, string detail, string resultStatus)
        {
            restoreFlowBusy = false;
            restoreFlowStep = "error";
            restoreFlowStatus = "failed";
            restoreFlowResultStatus = resultStatus ?? "error";
            restoreFlowResultError = detail ?? string.Empty;
            SetRestoreFlowMessage(title, detail);
        }

        private void FailRestoreFlow(string operation, string title, string detail, string resultStatus)
        {
            restoreFlowFailedOperation = operation ?? string.Empty;
            SetRestoreFlowFailure(title, detail, resultStatus);
        }

        // The check that the plan is unchanged, made after a protected read, could not complete. A plan that changed
        // has already moved the flow to its own "Configuration changed" result, which stays as it is. A configuration
        // that could not be read at all (locked, or being rewritten) has not, and would leave the dialog loading for
        // good, so it ends the read as a failure that Try again can recover from. `operation` is "snapshots" or
        // "tree"; the folder arguments are only used by the latter.
        private void EndRestoreFlowReadAfterFailedCheck(
            string operation,
            string freshnessError,
            string requestedPath,
            string previousPath,
            IList<RestoreTreeEntry> previousEntries)
        {
            restoreFlowBusy = false;
            if (!string.Equals(restoreFlowStatus, "loading", StringComparison.Ordinal))
            {
                PublishWebPresentationState();
                return;
            }
            if (operation == "tree")
            {
                // The listing that was just read is not trusted. The folder reports why, with its own Try again.
                FailRestoreFlowTreeRead(requestedPath, freshnessError, previousPath, previousEntries);
                return;
            }
            FailRestoreFlow(operation, "Configuration check failed", freshnessError, "error");
            PublishWebPresentationState();
        }

        // A folder that cannot be read is not a failed restore. Stay on Choose files with the listing the
        // user already had and report the reason inline, with the folder that failed so it can be retried.
        private void FailRestoreFlowTreeRead(
            string requestedPath,
            string detail,
            string previousPath,
            IList<RestoreTreeEntry> previousEntries)
        {
            restoreFlowBusy = false;
            restoreFlowFailedOperation = "tree";
            restoreFlowTreePath = string.IsNullOrEmpty(previousPath) ? "/" : previousPath;
            restoreFlowTreeEntries = previousEntries ?? new List<RestoreTreeEntry>();
            restoreFlowTreeLoaded = restoreFlowTreeLoadedBeforeRead;
            restoreFlowTreeError = string.IsNullOrWhiteSpace(detail)
                ? "The snapshot folder could not be read."
                : detail;
            restoreFlowTreeErrorPath = requestedPath ?? string.Empty;
            restoreFlowStep = "files";
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage(
                "Folder unavailable",
                "That snapshot folder was not opened. Try again, or choose another folder.");
            PublishWebPresentationState();
        }

        private void ClearRestoreFlowTreeError()
        {
            restoreFlowTreeError = string.Empty;
            restoreFlowTreeErrorPath = string.Empty;
        }

        private void CompleteRestoreFlowCancelled(string detail)
        {
            restoreFlowBusy = false;
            restoreFlowStep = "error";
            restoreFlowStatus = "failed";
            restoreFlowResultStatus = "cancelled";
            restoreFlowResultError = detail ?? string.Empty;
            SetRestoreFlowMessage("Restore flow cancelled", detail);
            PublishWebPresentationState();
        }

        private void ClearRestoreFlowResult()
        {
            restoreFlowResultStatus = null;
            restoreFlowResultTarget = null;
            restoreFlowResultVerified = false;
            restoreFlowResultError = null;
            restoreFlowFailedOperation = string.Empty;
            restoreFlowResultSnapshotId = string.IsNullOrWhiteSpace(restoreFlowSelectedSnapshotId)
                ? null
                : restoreFlowSelectedSnapshotId;
        }

        private static string FriendlyRestoreFlowStage(string stage)
        {
            switch ((stage ?? string.Empty).ToLowerInvariant())
            {
                case "preflight": return "Validating restore safety";
                case "reading": return "Reading protected snapshot data";
                case "restoring": return "Restoring and verifying";
                case "complete": return "Protected restore complete";
                case "failed": return "Protected restore needs attention";
                default: return "Protected restore operation";
            }
        }

        private Dictionary<string, object> BuildWebRestoreFlowState()
        {
            if (!restoreFlowOpen)
            {
                return null;
            }
            List<Dictionary<string, object>> snapshots = new List<Dictionary<string, object>>();
            foreach (RestoreSnapshot snapshot in restoreFlowSnapshots)
            {
                snapshots.Add(new Dictionary<string, object>
                {
                    { "id", snapshot.Id ?? string.Empty },
                    { "shortId", snapshot.ShortId ?? string.Empty },
                    { "when", snapshot.Time ?? string.Empty },
                    { "whenDisplay", snapshot.WhenDisplay ?? string.Empty },
                    { "hostname", snapshot.Hostname ?? string.Empty },
                    { "configGeneration", snapshot.ConfigGeneration.ToString(CultureInfo.InvariantCulture) },
                    { "fileCount", snapshot.FileCount },
                    { "fileCountDisplay", snapshot.FileCount.ToString("N0", CultureInfo.CurrentCulture) },
                    { "byteCount", snapshot.ByteCount },
                    { "sizeDisplay", snapshot.SizeDisplay ?? string.Empty },
                    { "sourceSummary", snapshot.SourceSummary ?? string.Empty },
                    { "bindingState", snapshot.BindingState ?? string.Empty },
                    { "isLegacyUnbound", snapshot.IsLegacyUnbound }
                });
            }
            // The listing is only used on Choose files, and a large folder would otherwise travel with every state
            // push (about once a second) from every step. Elsewhere the page is told only how many entries there
            // are, which is how it knows the host still holds a listing it can return to without reading the backup again.
            List<Dictionary<string, object>> entries = new List<Dictionary<string, object>>();
            int treeTotal = restoreFlowTreeEntries == null ? 0 : restoreFlowTreeEntries.Count;
            bool treeTruncated = false;
            if (restoreFlowStep == "files" && treeTotal > 0)
            {
                IEnumerable<RestoreTreeEntry> listed = restoreFlowTreeEntries;
                treeTruncated = treeTotal > RestoreFlowMaximumPublishedEntries;
                if (treeTruncated)
                {
                    // Folders first, so a listing that is cut short still lets the person open every subfolder.
                    listed = restoreFlowTreeEntries
                        .Where(candidate => candidate != null && candidate.EntryType == "dir")
                        .Concat(restoreFlowTreeEntries.Where(
                            candidate => candidate != null && candidate.EntryType != "dir"));
                }
                foreach (RestoreTreeEntry entry in listed
                    .Where(candidate => candidate != null)
                    .Take(RestoreFlowMaximumPublishedEntries))
                {
                    entries.Add(new Dictionary<string, object>
                    {
                        { "name", entry.Name ?? string.Empty },
                        { "path", entry.EntryPath ?? string.Empty },
                        { "type", entry.EntryType ?? string.Empty },
                        { "size", entry.Size },
                        { "sizeDisplay", entry.SizeDisplay ?? string.Empty }
                    });
                }
            }
            IList<string> validationErrors;
            IList<string> validationWarnings;
            BuildRestoreFlowValidation(out validationErrors, out validationWarnings);
            List<string> errors = validationErrors.ToList();
            List<string> warnings = validationWarnings.ToList();
            // Why a restore cannot start at this moment, so the page can say so before Restore now is pressed. It is
            // only a hint: StartRestoreFlow runs the same guard again when the restore is requested.
            string startBlocked;
            CheckRestoreFlowOperationGuards(out startBlocked);
            Dictionary<string, object> result = new Dictionary<string, object>
            {
                { "status", restoreFlowResultStatus },
                { "target", restoreFlowResultTarget },
                { "verified", restoreFlowResultVerified },
                { "error", restoreFlowResultError },
                { "snapshotId", restoreFlowResultSnapshotId },
                // A cancelled approval, an unreadable snapshot list or a changed plan is not a failed restore,
                // so only a restore that ran gets a fixed headline; anything else says what actually happened,
                // and the page words the headline when the host has none.
                { "title", restoreFlowResultStatus == "success"
                    ? "Restore complete and verified"
                    : restoreFlowResultStatus == "partial"
                        ? "Restore incomplete"
                        : string.IsNullOrWhiteSpace(restoreFlowMessageTitle)
                            ? null
                            : restoreFlowMessageTitle },
                { "message", restoreFlowResultError },
                { "retryable", restoreFlowResultStatus == "partial" || restoreFlowResultStatus == "error" || restoreFlowResultStatus == "cancelled" },
                { "retryLabel", restoreFlowFailedOperation == "config" ? "Reload Restore" : "Try again" }
            };
            return new Dictionary<string, object>
            {
                { "open", true },
                { "step", restoreFlowStep },
                { "status", restoreFlowStatus },
                { "busy", restoreFlowBusy },
                { "canCancel", restoreFlowBusy && restoreFlowStep != "progress" },
                { "startBlocked", startBlocked ?? string.Empty },
                { "message", new Dictionary<string, object>
                    {
                        { "title", restoreFlowMessageTitle },
                        { "detail", restoreFlowMessageDetail }
                    } },
                { "snapshots", snapshots },
                { "selectedSnapshotId", restoreFlowSelectedSnapshotId },
                { "limits", new Dictionary<string, object>
                    {
                        { "maxPaths", RestoreFlowMaximumPaths }
                    } },
                { "tree", new Dictionary<string, object>
                    {
                        { "path", restoreFlowTreePath },
                        { "entries", entries },
                        // How many entries the folder holds, whether or not they are all in `entries`.
                        { "total", treeTotal },
                        { "truncated", treeTruncated },
                        { "loading", restoreFlowBusy && restoreFlowStep == "files" },
                        // False until a folder of this snapshot was read: the page then offers Browse files instead of a list.
                        { "loaded", restoreFlowTreeLoaded },
                        { "error", restoreFlowTreeError ?? string.Empty },
                        { "errorPath", restoreFlowTreeErrorPath ?? string.Empty }
                    } },
                { "selectedPaths", restoreFlowSelectedPaths.ToArray() },
                { "wholeSnapshotSelected", restoreFlowWholeSnapshotSelected },
                { "destination", new Dictionary<string, object>
                    {
                        { "path", restoreFlowDestinationPath },
                        { "valid", restoreFlowDestinationValid },
                        { "checking", restoreFlowDestinationChecking },
                        { "status", restoreFlowDestinationStatus },
                        { "error", restoreFlowDestinationError ? restoreFlowDestinationStatus : string.Empty },
                        // Room on the checked destination's drive, as read when it was checked; empty when it was not read.
                        { "freeDisplay", restoreFlowDestinationValid && restoreFlowDestinationFreeBytes.HasValue
                            ? TelemetryFormat.FormatBytes(restoreFlowDestinationFreeBytes.Value)
                            : string.Empty },
                        { "drive", restoreFlowDestinationValid && restoreFlowDestinationFreeBytes.HasValue
                            ? (restoreFlowDestinationDrive ?? string.Empty)
                            : string.Empty }
                    } },
                { "validation", new Dictionary<string, object>
                    {
                        { "ready", errors.Count == 0 && !restoreFlowDestinationChecking },
                        { "errors", errors },
                        { "warnings", warnings },
                        // The warning in `warnings` that is about free space, for the review step, which shows it again.
                        { "spaceWarning", BuildRestoreFlowSpaceWarning(FindRestoreFlowSnapshot(restoreFlowSelectedSnapshotId)) ?? string.Empty },
                        { "scopeLabel", restoreFlowWholeSnapshotSelected
                            ? "Entire immutable snapshot"
                            : restoreFlowSelectedPaths.Count.ToString(CultureInfo.CurrentCulture) + " selected path" +
                                (restoreFlowSelectedPaths.Count == 1 ? string.Empty : "s") },
                        { "status", restoreFlowDestinationChecking
                            ? "checking"
                            : errors.Count == 0 ? "ready" : "invalid" },
                        { "message", restoreFlowDestinationStatus }
                    } },
                // Whether Windows is showing its approval prompt for this flow now, and whether the flow has one restore session
                // (one approval for every step) or asks for each step.
                { "approval", new Dictionary<string, object>
                    {
                        { "waiting", restoreFlowAwaitingApproval && restoreFlowBusy },
                        { "session", restoreFlowApprovalSession != null },
                        { "notice", RestoreFlowApprovalNotice() }
                    } },
                { "progress", new Dictionary<string, object>
                    {
                        { "stage", restoreFlowProgressStage },
                        { "message", restoreFlowProgressMessage },
                        { "percent", restoreFlowProgressPercent },
                        { "awaitingApproval", restoreFlowAwaitingApproval && restoreFlowStep == "progress" }
                    } },
                { "result", result }
            };
        }
    }
}
