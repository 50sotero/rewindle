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
        private string restoreFlowMessageDetail = "Choose the backup to restore from.";
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
                    ? "Restore is not available right now."
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
                error = "Your backup settings could not be read. " + exception.Message;
                return false;
            }
            string hash;
            try
            {
                hash = ComputeRestoreFlowConfigHash(configuration);
            }
            catch (Exception exception)
            {
                error = "Your backup settings could not be read. " + exception.Message;
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
            restoreFlowMessageDetail = "Opening your list of backups…";
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
            restoreFlowProgressMessage = "Reading your list of backups.";
            restoreFlowProgressPercent = 0;
            SetRestoreFlowMessage(
                "Loading your backups",
                "Looking at your backups does not change them.");
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
                                        "Reading your backups",
                                        "Rewindle is reading the list of backups.");
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
                CompleteRestoreFlowCancelled("Loading your backups was cancelled. Nothing was restored.");
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
                    "Windows permission was not given",
                    "Nothing was opened or changed. Rewindle needs that permission to read your backup.",
                    "cancelled");
                PublishWebPresentationState();
                return;
            }
            if (!result.Succeeded)
            {
                FailRestoreFlow(
                    "snapshots",
                    "Your backups could not be listed",
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
                restoreFlowSnapshots.Count == 0 ? "No backups to restore from" : "Choose a backup",
                restoreFlowSnapshots.Count == 0
                    ? "Nothing was found to restore from yet."
                    : restoreFlowSnapshots.Count == 1
                        ? "1 backup is available. Choose it to restore from."
                        : restoreFlowSnapshots.Count.ToString(CultureInfo.CurrentCulture) +
                            " backups are available. Choose one to restore from.");
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
                error = "Choose one of the backups in the list.";
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
            restoreFlowProgressMessage = "Opening the folder in your backup.";
            restoreFlowProgressPercent = 0;
            SetRestoreFlowMessage("Opening folder", "Opening " + DescribeRestoreFlowFolder(path) + ".");
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
                                    SetRestoreFlowMessage("Opening folder", "Opening " + DescribeRestoreFlowFolder(path) + ".");
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
                    "Opening the folder was cancelled. Nothing was restored.",
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
                    "Windows permission was not given, so this folder was not opened.",
                    previousPath,
                    previousEntries);
                return;
            }
            if (!result.Succeeded)
            {
                FailRestoreFlowTreeRead(
                    path,
                    string.IsNullOrWhiteSpace(result.ErrorMessage)
                        ? "That folder in your backup could not be opened."
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
                    (restoreFlowTreeEntries.Count == 1 ? " item" : " items") +
                    " in " + DescribeRestoreFlowFolder(path) + ". Tick what you need, or restore everything in this backup.");
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
                    SetRestoreFlowMessage("Waiting for Windows permission…", RestoreFlowApprovalNotice());
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
                return "Windows asks for your permission each time Rewindle opens your backup. Looking at it does not change anything.";
            }
            return session.Opened > 0
                ? "The earlier permission has ended, so Windows will ask for your permission again to let Rewindle read and restore from your backup."
                : "Windows will ask once for your permission to let Rewindle read and restore from your backup.";
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
                error = "Those files belong to a different backup. Choose the backup again.";
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
                        error = "One selected item was not found in the folder list. Open its folder again before continuing.";
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
                wholeSnapshot ? "Everything selected" : "Selection updated",
                wholeSnapshot
                    ? "Everything in this backup will be restored. Choose a folder to restore into next."
                    : paths.Count.ToString(CultureInfo.CurrentCulture) +
                        (paths.Count == 1 ? " item" : " items") +
                        " selected. Choose a folder to restore into next.");
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
                error = "The folder chooser could not open. " + exception.Message;
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
                SetRestoreFlowMessage("Choose a backup", "Choose a backup to continue.");
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
                        error = "Choose one of the backups in the list.";
                        return false;
                    }
                    if (!string.Equals(chosen.Id, restoreFlowSelectedSnapshotId, StringComparison.OrdinalIgnoreCase))
                    {
                        SelectRestoreFlowSnapshot(chosen.Id);
                    }
                }
                if (FindRestoreFlowSnapshot(restoreFlowSelectedSnapshotId) == null)
                {
                    error = "Choose a backup before choosing files.";
                    return false;
                }
                restoreFlowStep = "files";
                restoreFlowStatus = "ready";
                SetRestoreFlowMessage(
                    "Choose files",
                    restoreFlowTreeLoaded
                        ? "Tick the files or folders you need, or restore everything in this backup."
                        : "Restore everything in this backup, or open its folders to choose files.");
            }
            else if (step == "destination")
            {
                if (FindRestoreFlowSnapshot(restoreFlowSelectedSnapshotId) == null)
                {
                    error = "Choose a backup before choosing a folder.";
                    return false;
                }
                if (!restoreFlowWholeSnapshotSelected && restoreFlowSelectedPaths.Count == 0)
                {
                    error = "Choose files or folders first, or choose everything in the backup.";
                    return false;
                }
                restoreFlowStep = "destination";
                restoreFlowStatus = "ready";
                SetRestoreFlowMessage("Choose a folder", "Restore puts the copies in a new or empty folder. Your original files are not touched.");
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
                error = "Choose a new or empty folder to restore into.";
                return false;
            }
            if (path.Trim().Length > 4096)
            {
                error = "That folder path is too long.";
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
            restoreFlowDestinationStatus = "Checking that this folder is empty and safe to use…";
            restoreFlowDestinationFreeBytes = null;
            restoreFlowDestinationDrive = string.Empty;
            InvalidateRestoreFlowReview();
            restoreFlowStep = "destination";
            restoreFlowStatus = "loading";
            SetRestoreFlowMessage("Checking folder", "Restore only writes to a new or empty folder.");
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
                    Message = "That folder could not be checked: " + exception.Message
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
                ? "That folder has not been checked yet."
                : inspection.Message;
            restoreFlowDestinationFreeBytes = inspection == null ? null : inspection.FreeBytes;
            restoreFlowDestinationDrive = inspection == null ? string.Empty : inspection.Drive ?? string.Empty;
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage(
                restoreFlowDestinationValid ? "Folder ready" : "Choose another folder",
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
                "Check your choices, then press Restore now.");
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
                error = "Review your choices before starting.";
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
                error = "That backup is no longer available. Go back and choose a backup again.";
                return false;
            }
            bool legacyConfirmed = ReadRestoreFlowBoolean(payload, "legacyConfirmed");
            if (snapshot.IsLegacyUnbound && !legacyConfirmed)
            {
                error = "Confirm that you want to restore from this older backup first.";
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
                ? "Waiting for your permission on the Windows prompt before anything is written."
                : "Starting the restore.";
            restoreFlowProgressPercent = 0;
            restoreFlowResultSnapshotId = snapshot.Id;
            ClearRestoreFlowResult();
            restoreFlowResultSnapshotId = snapshot.Id;
            SetRestoreFlowMessage(
                "Starting restore",
                "Files are only added to the folder you chose. Nothing is overwritten.");
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
                                    restoreFlowProgressMessage = "Waiting for your permission on the Windows prompt before anything is written.";
                                    SetRestoreFlowMessage("Waiting for Windows permission…", RestoreFlowApprovalNotice());
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
                                        "Permission received. Checking the folder before anything is written.";
                                    SetRestoreFlowMessage(
                                        "Restoring",
                                        "Copying your files into the folder you chose, then checking each one.");
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
                    "Windows permission was not given",
                    "Nothing was restored. Rewindle needs that permission to read your backup.",
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
                    "Your files are in " + result.Report.Target + ".");
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
                restoreFlowResultError = result.ErrorMessage ?? "The restore stopped before every file was checked.";
                SetRestoreFlowMessage(
                    "Restore incomplete",
                    restoreFlowResultError + " Some files were copied to the folder you chose; your current files were not changed.");
                PublishWebPresentationState();
                return;
            }
            FailRestoreFlow(
                "restore",
                "Restore did not finish",
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
                    error = "The restore is running and cannot be stopped safely. Keep this window open until it finishes.";
                    return false;
                }
                restoreFlowCancelRequested = true;
                restoreFlowStatus = "canceling";
                SetRestoreFlowMessage(
                    "Stopping",
                    "The current step will finish safely, then Restore stops.");
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
                SetRestoreFlowMessage("Choose files", "Tick the files or folders you need, or restore everything in this backup.");
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
                : "Choose a different empty folder, or check this one again.";
            restoreFlowStep = "destination";
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage("Choose a folder again", restoreFlowDestinationStatus);
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
                error = "Wait for this step to finish before closing Restore.";
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
                    error = "That folder is not the one chosen for this restore.";
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
                error = "Open Restore first.";
                return false;
            }
            error = string.Empty;
            return true;
        }

        private bool CheckRestoreFlowOperationGuards(out string error)
        {
            if (sourceOperationInProgress || BackupBlocksSourceChanges() || previewEnabled)
            {
                error = "Wait for the running backup or settings change to finish, then try again.";
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
                    : "Restore is still working. Wait for it to finish.";
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
                        "Your backup settings changed while Restore was open. Choose Start again to continue with the current settings.";
                    SetRestoreFlowMessage("Backup settings changed", restoreFlowResultError);
                    PublishWebPresentationState();
                    error = "Your backup settings changed. Choose Start again to continue with the current settings.";
                    return false;
                }
                return true;
            }
            catch (Exception exception)
            {
                error = "Your backup settings could not be read. " + exception.Message;
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
                return InvalidRestoreFlowDestination("That folder path is not valid: " + exception.Message);
            }
            if (configuration == null)
            {
                return InvalidRestoreFlowDestination("Your backup settings are unavailable.");
            }
            if (!HasNormalRestoreFlowDirectoryChain(normalized))
            {
                return InvalidRestoreFlowDestination(
                    "This folder is inside OneDrive or is a shortcut or link, which Rewindle cannot restore into. " +
                    "Choose a folder that is not synced to OneDrive, for example a new folder on a local drive.");
            }
            try
            {
                string root = Path.GetPathRoot(normalized);
                DriveInfo drive = new DriveInfo(root);
                if (!drive.IsReady ||
                    (drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable))
                {
                    return InvalidRestoreFlowDestination(
                        "Choose a folder on a drive that is ready and connected to this computer. Network folders cannot be used.");
                }
                driveName = root.TrimEnd('\\', '/');
                freeBytes = ReadRestoreFlowFreeBytes(drive);
            }
            catch
            {
                return InvalidRestoreFlowDestination(
                    "That drive could not be checked. Make sure it is connected and ready.");
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
                    "That folder is part of what Rewindle backs up or where its backups are kept. Choose a different folder, for example a new folder on another drive.");
            }
            try
            {
                if (File.Exists(normalized))
                {
                    return InvalidRestoreFlowDestination(
                        "That path is a file, not a folder. Rewindle never overwrites files. Choose a new or empty folder.");
                }
                if (Directory.Exists(normalized) && Directory.EnumerateFileSystemEntries(normalized).Any())
                {
                    // Only the wording differs: a drive root is refused for the same reason as any folder that holds something.
                    return InvalidRestoreFlowDestination(IsRestoreFlowDriveRoot(normalized)
                        ? "This is a drive root, which usually holds hidden system folders that Explorer does not show. " +
                            "Choose or create a folder on this drive instead, for example " +
                            Path.Combine(Path.GetPathRoot(normalized), "Rewindle restore") + "."
                        : "That folder already has files in it. Choose a new or empty folder; Rewindle never overwrites files.");
                }
                return new RestoreFlowDestinationInspection
                {
                    Valid = true,
                    Error = false,
                    Message = Directory.Exists(normalized)
                        ? "Ready · this existing folder is empty and will hold the restored files."
                        : "Ready · this new folder will be created for the restored files.",
                    FreeBytes = freeBytes,
                    Drive = driveName
                };
            }
            catch (Exception exception)
            {
                return InvalidRestoreFlowDestination("That folder could not be checked: " + exception.Message);
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
                error = "That folder path is not valid.";
                return false;
            }
            normalized = normalized == "/" ? "/" : normalized.TrimEnd('/');
            foreach (string segment in normalized.Split('/'))
            {
                if (segment == ".." || segment == ".")
                {
                    error = "That folder path is not valid.";
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
                    throw new InvalidDataException("A selected item is not valid.");
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
                    " items for one restore. Tick a parent folder to include more.");
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
                errors.Add("Choose a backup before continuing.");
            }
            if (!restoreFlowWholeSnapshotSelected && restoreFlowSelectedPaths.Count == 0)
            {
                errors.Add("Choose files or folders, or choose everything in the backup.");
            }
            if (restoreFlowWholeSnapshotSelected && restoreFlowSelectedPaths.Count != 0)
            {
                errors.Add("Choose either some items or everything in the backup, not both.");
            }
            if (restoreFlowDestinationChecking || !restoreFlowDestinationValid)
            {
                errors.Add(string.IsNullOrWhiteSpace(restoreFlowDestinationStatus)
                    ? "Choose a new or empty folder to restore into."
                    : restoreFlowDestinationStatus);
            }
            if (snapshot != null && snapshot.IsLegacyUnbound)
            {
                warnings.Add("This backup was made before your current backup settings. Confirm that you want to restore from it.");
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
                ? "that drive"
                : restoreFlowDestinationDrive;
            return "Everything in this backup is about " + TelemetryFormat.FormatBytes(snapshot.ByteCount) + ", but only " +
                TelemetryFormat.FormatBytes(free) + " is free on " + drive + ". The restore may stop part-way. Choose a drive with more room if you can.";
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
                ? "That folder has not been checked yet."
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
            FailRestoreFlow(operation, "Backup settings could not be read", freshnessError, "error");
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
                ? "That folder in your backup could not be opened."
                : detail;
            restoreFlowTreeErrorPath = requestedPath ?? string.Empty;
            restoreFlowStep = "files";
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage(
                "Folder unavailable",
                "That folder was not opened. Try again, or choose another folder.");
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
            SetRestoreFlowMessage("Restore cancelled", detail);
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

        // A folder of the backup as a person writes it: restic keeps C:\Users\you as /C/Users/you, and "/" is the top of the backup.
        private static string DescribeRestoreFlowFolder(string snapshotPath)
        {
            string path = snapshotPath ?? string.Empty;
            if (path.Length <= 1)
            {
                return "the top level of your backup";
            }
            if (path.Length >= 2 && path[0] == '/' && char.IsLetter(path[1]) && (path.Length == 2 || path[2] == '/'))
            {
                path = path.Substring(1, 1) + ":" + path.Substring(2);
            }
            return path.Replace('/', '\\');
        }

        private static string FriendlyRestoreFlowStage(string stage)
        {
            switch ((stage ?? string.Empty).ToLowerInvariant())
            {
                case "preflight": return "Checking everything is ready";
                case "reading": return "Opening your backup";
                case "restoring": return "Copying and checking your files";
                case "complete": return "Finished";
                case "failed": return "Restore did not finish";
                default: return "Restoring your files";
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
                { "retryLabel", restoreFlowFailedOperation == "config" ? "Start again" : "Try again" }
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
                            ? "Everything in this backup"
                            : restoreFlowSelectedPaths.Count.ToString(CultureInfo.CurrentCulture) +
                                (restoreFlowSelectedPaths.Count == 1 ? " item" : " items") },
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
