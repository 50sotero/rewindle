using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Principal;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace ResticBackuper.Dashboard
{
    // Settings > Old backups: clean-up of old backups. The page shows what the engine's records say; every change goes
    // through Manage-Retention.ps1 and one Windows approval, and a removal only ever names the list the person reviewed.
    public partial class DashboardWindow
    {
        private const int RetentionReviewPageSize = 100;
        private static readonly TimeSpan RetentionReadInterval = TimeSpan.FromSeconds(2);
        private static readonly TimeSpan RetentionNoticeLifetime = TimeSpan.FromSeconds(45);

        internal const string RetentionUnavailableMessage =
            "Clean-up of old backups isn't available for this backup service.";
        private const string RetentionReviewOpenMessage = "Close the list of old backups first.";
        private const string RetentionRunningMessage =
            "Old backups are being removed. Other changes wait until it finishes, and a backup that's due meanwhile is skipped.";
        private const string RetentionListingMessage =
            "Rewindle is checking for old backups. Other changes wait until it finishes.";

        private RetentionView retentionView;
        private bool retentionCapabilityKnown;
        private bool retentionCapabilitySupported;
        private bool retentionReadInFlight;
        private long retentionNextReadAt;
        private bool retentionOperationInProgress;
        private string retentionOperationAction = string.Empty;
        private string retentionOperationStage = string.Empty;
        private long retentionOperationCount;
        private double? retentionOperationPercent;
        private bool retentionReviewOpen;
        private RetentionView retentionReviewCapture;
        private bool retentionReviewChanged;
        private string retentionReviewList = "remove";
        private int retentionReviewOffset;
        private Dictionary<string, object> retentionReviewResult;
        private string retentionNoticeText = string.Empty;
        private string retentionNoticeTone = "info";
        private long retentionNoticeExpiresAt;

        private static readonly string[] RetentionCommands =
        {
            "retentionConfigure",
            "retentionCheckNow",
            "retentionOpenReview",
            "retentionReviewPage",
            "retentionApply",
            "retentionCloseReview"
        };

        // Protected actions that wait while a clean-up step runs: they would change what is backed up or where, or take
        // the backup service's lock the step holds.
        private static readonly string[] RetentionBusyBlockedCommands =
        {
            "backupNow", "addSource", "browseSourcePicker", "validateSourcePath", "confirmSourcePicker", "removeSource",
            "retrySourceChange", "editSchedule", "changeRepository", "repairRepository", "reviewChanges", "openRestore",
            "restoreFlowOpen", "checkReadiness", "togglePreview"
        };

        private static readonly string[] RetentionBusyBlockedActions =
        {
            "togglePreview", "backupNow", "addSource", "retrySourceChange", "editSchedule", "changeRepository",
            "repairRepository", "reviewChanges", "openRestore", "checkReadiness"
        };

        private bool IsRetentionCommand(string command)
        {
            return RetentionNames.IsOneOf(command, RetentionCommands);
        }

        // Asked before any other routing (ExecuteWebCommand): while the list of old backups is open nothing else runs, and
        // while a clean-up step runs nothing that would change the backups starts.
        private bool RetentionBlocksCommand(string command, out string error)
        {
            error = string.Empty;
            if (IsRetentionCommand(command) || command == "refresh" || command == "setZoom" || command == "navigate")
            {
                return false;
            }
            if (retentionReviewOpen)
            {
                error = RetentionReviewOpenMessage;
                return true;
            }
            if (retentionOperationInProgress &&
                (RetentionNames.IsOneOf(command, RetentionBusyBlockedCommands) || IsRestoreFlowCommand(command)))
            {
                error = retentionOperationAction == "apply" ? RetentionRunningMessage : RetentionListingMessage;
                return true;
            }
            return false;
        }

        private void ApplyRetentionBusyToActions(Dictionary<string, object> actions)
        {
            if (!retentionOperationInProgress || actions == null)
            {
                return;
            }
            string help = retentionOperationAction == "apply" ? RetentionRunningMessage : RetentionListingMessage;
            foreach (string name in RetentionBusyBlockedActions)
            {
                object value;
                Dictionary<string, object> action = actions.TryGetValue(name, out value)
                    ? value as Dictionary<string, object>
                    : null;
                if (action != null)
                {
                    action["enabled"] = false;
                    action["help"] = help;
                }
            }
        }

        private bool RetentionSupportedByProfile()
        {
            return !string.IsNullOrEmpty(EngineProfile.Current.RetentionManagerFileName);
        }

        // Why nothing can change clean-up right now, as one sentence, or empty. The engine checks everything again.
        private string RetentionBusyReason()
        {
            if (retentionOperationInProgress)
            {
                return "Wait for the current clean-up step to finish.";
            }
            if (previewEnabled)
            {
                return "Stop the animation preview first.";
            }
            if (lastSnapshot != null && lastSnapshot.IsActive)
            {
                return "Wait for the running backup to finish.";
            }
            if (backupStartInProgress || BackupRequestPending() || CancellationBlocksMutations(lastSnapshot))
            {
                return "Wait for the backup that is starting or stopping.";
            }
            if (anomalyReviewInProgress || sourceOperationInProgress || scheduleOperationInProgress ||
                repositoryOperationInProgress || RepositoryRecoveryBlocksMutations())
            {
                return "Wait until the other change to your backups finishes.";
            }
            if (restoreFlowOpen || sourcePickerOpen || webRunDetails != null)
            {
                return "Close the open window first.";
            }
            return string.Empty;
        }

        // ---- Reading -------------------------------------------------------------------------------------------------------

        private bool RetentionCapabilityAvailable()
        {
            if (!RetentionSupportedByProfile())
            {
                return false;
            }
            if (!retentionCapabilityKnown || !retentionCapabilitySupported)
            {
                try
                {
                    retentionCapabilitySupported = RetentionCapability.IsSupported(
                        EngineProfile.Current, EngineProfile.Current.InstallRoot());
                }
                catch
                {
                    retentionCapabilitySupported = false;
                }
                retentionCapabilityKnown = true;
            }
            return retentionCapabilitySupported;
        }

        // One read of the engine's clean-up records for the plan in use. Never for an engine without a clean-up manager.
        private RetentionView ReadRetentionViewNow()
        {
            SourceConfiguration configuration = currentSourceConfiguration;
            if (!RetentionSupportedByProfile() || configuration == null || !RetentionCapabilityAvailable())
            {
                return null;
            }
            EngineProfile profile = EngineProfile.Current;
            return RetentionStateReader.Read(
                profile,
                profile.StateDirectory(),
                profile.InstallRoot(),
                configuration.PlanId,
                configuration.ConfigGeneration,
                retentionView);
        }

        internal void RefreshRetentionStateNow()
        {
            retentionView = ReadRetentionViewNow();
            retentionNextReadAt = MonotonicAfter(RetentionReadInterval);
        }

        // What clean-up of old backups freed, for the Backup location card's forecast (BackupSpaceEvaluator). False while it is not
        // known: the engine keeps clean-up records that have not been read yet, or that could not be read, so the card waits rather
        // than forecast from what the backups added alone. A backup service without clean-up (the earlier personal edition, or an
        // older Rewindle engine) has freed nothing.
        private bool TryGetRetentionSpaceChanges(out IList<BackupSpaceCleanUp> cleanUps)
        {
            cleanUps = new List<BackupSpaceCleanUp>();
            if (!RetentionSupportedByProfile() || !retentionCapabilityKnown || !retentionCapabilitySupported)
            {
                return true;
            }
            RetentionView view = retentionView;
            if (view == null || !view.HistoryKnown)
            {
                return false;
            }
            foreach (RetentionSpaceChange change in view.SpaceChanges)
            {
                cleanUps.Add(new BackupSpaceCleanUp(change.FinishedUtc, change.FreedBytes));
            }
            return true;
        }

        // Whether how far back the backups go, as counted at `countedUtc`, may be out of date because clean-up of old backups
        // removed backups since then (or may have: nobody could confirm which). The count and the oldest date are then unknown
        // until a listing made since (the next backup, or the Restore list) counts them again, as they are while the engine's
        // clean-up records are not read yet or cannot be read. Never for a backup service without clean-up.
        private bool RetentionMayHaveRemovedSince(DateTime countedUtc)
        {
            if (!RetentionSupportedByProfile() || !retentionCapabilityKnown || !retentionCapabilitySupported)
            {
                return false;
            }
            RetentionView view = retentionView;
            if (view == null || !view.HistoryKnown)
            {
                return true;
            }
            return view.BackupsRemovedUtc.HasValue && view.BackupsRemovedUtc.Value > countedUtc.ToUniversalTime();
        }

        // Try again on a clean-up setting that couldn't be read reads it again at once, even when none of its files changed
        // since (a read that failed for a moment would otherwise be kept until one does).
        internal void ForgetUnreadableRetentionView()
        {
            RetentionView view = retentionView;
            if (view != null && view.Mode == "unknown")
            {
                retentionView = null;
                retentionNextReadAt = 0;
            }
        }

        private async void RefreshRetentionStateAsync()
        {
            if (retentionReadInFlight || Dispatcher == null || !RetentionSupportedByProfile() ||
                !MonotonicReached(retentionNextReadAt))
            {
                return;
            }
            retentionReadInFlight = true;
            RetentionView previous = retentionView;
            SourceConfiguration configuration = currentSourceConfiguration;
            RetentionView read = null;
            try
            {
                if (configuration != null && RetentionCapabilityAvailable())
                {
                    EngineProfile profile = EngineProfile.Current;
                    string state = profile.StateDirectory();
                    string install = profile.InstallRoot();
                    read = await Task.Run(delegate
                    {
                        return RetentionStateReader.Read(
                            profile, state, install, configuration.PlanId, configuration.ConfigGeneration, previous);
                    });
                }
            }
            catch
            {
                read = null;
            }
            finally
            {
                retentionReadInFlight = false;
                retentionNextReadAt = MonotonicAfter(RetentionReadInterval);
            }
            if (!ReferenceEquals(read, previous))
            {
                retentionView = read;
                PublishWebPresentationState();
            }
        }

        // ---- Commands ------------------------------------------------------------------------------------------------------

        private bool ExecuteRetentionCommand(string command, IDictionary<string, object> payload, out string error)
        {
            error = string.Empty;
            if (!RetentionSupportedByProfile() || !RetentionCapabilityAvailable())
            {
                error = RetentionUnavailableMessage;
                return false;
            }
            if (command == "retentionReviewPage")
            {
                return SetRetentionReviewPage(payload, out error);
            }
            if (command == "retentionCloseReview")
            {
                if (retentionOperationInProgress && retentionOperationAction == "apply")
                {
                    error = "Wait for the clean-up to finish. It can't be stopped half-way.";
                    return false;
                }
                CloseRetentionReview();
                PublishWebPresentationState();
                return true;
            }
            string busy = RetentionBusyReason();
            if (!string.IsNullOrEmpty(busy))
            {
                error = busy;
                return false;
            }
            RetentionView view = retentionView ?? ReadRetentionViewNow();
            retentionView = view;
            if (view == null || view.Mode == "unknown")
            {
                error = "Rewindle couldn't read the clean-up setting. Choose Try again.";
                return false;
            }
            if (view.GoogleDrive)
            {
                error = "Clean-up isn't available yet for backups kept in Google Drive.";
                return false;
            }
            if (command == "retentionConfigure")
            {
                return BeginRetentionConfigure(view, payload, out error);
            }
            if (command == "retentionCheckNow")
            {
                if (view.Mode != "on")
                {
                    error = "Turn on clean-up first.";
                    return false;
                }
                return BeginRetentionRequest("preview", null, out error);
            }
            if (command == "retentionOpenReview")
            {
                return OpenRetentionReview(out error);
            }
            if (command == "retentionApply")
            {
                return BeginRetentionApply(payload, out error);
            }
            error = "The requested dashboard command is not allowed.";
            return false;
        }

        private bool BeginRetentionConfigure(RetentionView view, IDictionary<string, object> payload, out string error)
        {
            error = string.Empty;
            string enabled = WebReadString(payload, "enabled", 1);
            RetentionRequest fields = new RetentionRequest();
            if (enabled == "0")
            {
                if (view.Mode != "on")
                {
                    error = "Clean-up is already off.";
                    return false;
                }
                fields.Enabled = "0";
                return BeginRetentionRequest("configure", fields, out error);
            }
            if (enabled != "1")
            {
                error = "Choose whether clean-up is on or off.";
                return false;
            }
            int daily;
            int weekly;
            int monthly;
            if (!TryReadRetentionCount(payload, "keepDaily", out daily) ||
                !TryReadRetentionCount(payload, "keepWeekly", out weekly) ||
                !TryReadRetentionCount(payload, "keepMonthly", out monthly) ||
                !RetentionNames.CountsInRange(daily, weekly, monthly))
            {
                error = "Choose numbers in the ranges shown.";
                return false;
            }
            fields.Enabled = "1";
            fields.KeepDaily = daily.ToString(CultureInfo.InvariantCulture);
            fields.KeepWeekly = weekly.ToString(CultureInfo.InvariantCulture);
            fields.KeepMonthly = monthly.ToString(CultureInfo.InvariantCulture);
            return BeginRetentionRequest("configure", fields, out error);
        }

        private static bool TryReadRetentionCount(IDictionary<string, object> payload, string name, out int value)
        {
            value = 0;
            string text = WebReadString(payload, name, 3);
            return text.Length > 0 && text[0] != '0' &&
                int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out value);
        }

        private bool OpenRetentionReview(out string error)
        {
            error = string.Empty;
            RetentionView view = ReadRetentionViewNow();
            retentionView = view;
            if (view == null || view.Mode != "on" || view.PreviewStatus != "ready")
            {
                error = "There is no current list of old backups. Choose Check now.";
                return false;
            }
            if (view.RemoveCount == 0 && !view.PrunePending)
            {
                error = "Nothing to remove right now.";
                return false;
            }
            retentionReviewCapture = view;
            retentionReviewOpen = true;
            retentionReviewChanged = false;
            retentionReviewResult = null;
            retentionReviewList = view.RemoveCount > 0 ? "remove" : "keep";
            retentionReviewOffset = 0;
            PublishWebPresentationState();
            return true;
        }

        private void CloseRetentionReview()
        {
            retentionReviewOpen = false;
            retentionReviewCapture = null;
            retentionReviewChanged = false;
            retentionReviewResult = null;
            retentionReviewOffset = 0;
        }

        private bool SetRetentionReviewPage(IDictionary<string, object> payload, out string error)
        {
            error = string.Empty;
            RetentionView capture = retentionReviewCapture;
            string list = WebReadString(payload, "list", 8);
            int offset;
            if (!retentionReviewOpen || capture == null || (list != "remove" && list != "keep") ||
                !int.TryParse(WebReadString(payload, "offset", 6), NumberStyles.None, CultureInfo.InvariantCulture, out offset))
            {
                error = "The list of old backups isn't open.";
                return false;
            }
            int total = list == "remove" ? capture.Remove.Count : capture.Keep.Count;
            if (offset < 0 || offset % RetentionReviewPageSize != 0 || (offset > 0 && offset >= total))
            {
                error = "That part of the list doesn't exist.";
                return false;
            }
            retentionReviewList = list;
            retentionReviewOffset = offset;
            PublishWebPresentationState();
            return true;
        }

        private bool BeginRetentionApply(IDictionary<string, object> payload, out string error)
        {
            error = string.Empty;
            RetentionView capture = retentionReviewCapture;
            if (!retentionReviewOpen || capture == null || retentionReviewResult != null && !IsRetryableReviewResult())
            {
                error = "Open the list of old backups first.";
                return false;
            }
            if (retentionReviewChanged)
            {
                error = "This list was updated. Nothing was removed.";
                return false;
            }
            if (EndRetentionReviewIfOutOfDate(capture, ReadRetentionViewNow()))
            {
                return true;
            }
            // The list on screen must still be the engine's current list, byte for byte.
            RetentionFileRead current = RetentionFiles.ReadProtected(
                Path.Combine(EngineProfile.Current.StateDirectory(), RetentionNames.PreviewFileName),
                RetentionNames.MaximumPreviewBytes);
            if (current.Bytes == null || !string.Equals(current.Sha256, capture.PreviewSha256, StringComparison.Ordinal))
            {
                retentionReviewChanged = true;
                PublishWebPresentationState();
                error = "This list was updated. Nothing was removed.";
                return false;
            }
            int removeCount;
            if (!int.TryParse(WebReadString(payload, "removeCount", 6), NumberStyles.None, CultureInfo.InvariantCulture, out removeCount) ||
                removeCount != capture.RemoveCount)
            {
                error = "The number of backups to remove doesn't match the list.";
                return false;
            }
            object confirmList;
            if (payload == null || !payload.TryGetValue("confirmList", out confirmList) || !(confirmList is bool) || !(bool)confirmList)
            {
                error = "Tick the box to confirm you've looked at the list.";
                return false;
            }
            object confirmFilesValue;
            bool confirmFiles = payload.TryGetValue("confirmEarlierChanges", out confirmFilesValue) &&
                confirmFilesValue is bool && (bool)confirmFilesValue;
            if (capture.NeedsFilesConfirmed && !confirmFiles)
            {
                error = "Tick the box to confirm you've checked your files.";
                return false;
            }
            RetentionRequest fields = new RetentionRequest();
            fields.PreviewSha256 = capture.PreviewSha256;
            fields.RemoveSetSha256 = capture.RemoveSetSha256;
            fields.RemoveCount = capture.RemoveCount.ToString(CultureInfo.InvariantCulture);
            fields.ConfirmEarlierChanges = confirmFiles ? "1" : "0";
            retentionReviewResult = null;
            return BeginRetentionRequest("apply", fields, out error);
        }

        // A backup that finished while the list was open makes it out of date. That is said before Windows asks for
        // permission, in the same words as when the protected step refuses it: the dialog ends with "close this list and
        // choose Check now". Returns whether it ended.
        private bool EndRetentionReviewIfOutOfDate(RetentionView capture, RetentionView fresh)
        {
            if (fresh != null)
            {
                retentionView = fresh;
            }
            if (fresh == null || fresh.Mode != "on" || fresh.PreviewStatus != "stale")
            {
                return false;
            }
            Dictionary<string, object> outOfDate = new Dictionary<string, object>();
            outOfDate["status"] = "refused";
            outOfDate["reason"] = "preview_mismatch";
            outOfDate["removedCount"] = 0L;
            outOfDate["confirmedCount"] = (long)capture.RemoveCount;
            outOfDate["freedDisplay"] = string.Empty;
            retentionReviewResult = outOfDate;
            PublishWebPresentationState();
            return true;
        }

        private bool IsRetryableReviewResult()
        {
            object status;
            return retentionReviewResult != null && retentionReviewResult.TryGetValue("status", out status) &&
                (string.Equals(status as string, "declined", StringComparison.Ordinal) ||
                 string.Equals(status as string, "preview_changed", StringComparison.Ordinal));
        }

        private bool BeginRetentionRequest(string action, RetentionRequest fields, out string error)
        {
            error = string.Empty;
            SourceConfiguration configuration = currentSourceConfiguration;
            if (configuration == null)
            {
                error = "Rewindle couldn't read the backup plan. Choose Try again.";
                return false;
            }
            EngineProfile profile = EngineProfile.Current;
            RetentionRequest request;
            try
            {
                string userSid;
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                {
                    userSid = identity.User == null ? null : identity.User.Value;
                }
                string configHash = RestoreManagerLauncher.ComputeFileSha256(configuration.ConfigurationPath);
                request = RetentionManagerLauncher.CreateRequest(
                    profile, action, userSid, configHash, configuration.PlanId, configuration.ConfigGeneration);
            }
            catch (Exception)
            {
                error = "Rewindle couldn't prepare the request. Try again.";
                return false;
            }
            if (fields != null)
            {
                request.Enabled = fields.Enabled;
                request.KeepDaily = fields.KeepDaily;
                request.KeepWeekly = fields.KeepWeekly;
                request.KeepMonthly = fields.KeepMonthly;
                request.PreviewSha256 = fields.PreviewSha256;
                request.RemoveSetSha256 = fields.RemoveSetSha256;
                request.RemoveCount = fields.RemoveCount;
                request.ConfirmEarlierChanges = fields.ConfirmEarlierChanges;
            }
            RetentionManagerLauncher.Seal(profile, request);
            retentionOperationInProgress = true;
            retentionOperationAction = action;
            retentionOperationStage = "approval";
            retentionOperationCount = action == "apply" ? ParseCount(request.RemoveCount) : 0;
            retentionOperationPercent = null;
            retentionNoticeText = string.Empty;
            RunRetentionRequest(profile, request);
            PublishWebPresentationState();
            return true;
        }

        private static long ParseCount(string value)
        {
            long count;
            return long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out count) ? count : 0;
        }

        private async void RunRetentionRequest(EngineProfile profile, RetentionRequest request)
        {
            RetentionLaunchResult result;
            Dispatcher dispatcher = Dispatcher;
            try
            {
                result = await Task.Run(delegate
                {
                    return RetentionManagerLauncher.Run(
                        profile,
                        request,
                        delegate
                        {
                            RetentionOnUiThread(dispatcher, delegate
                            {
                                if (retentionOperationInProgress)
                                {
                                    retentionOperationStage = request.Action == "apply" ? "checking" : "listing";
                                    PublishWebPresentationState();
                                }
                            });
                        },
                        delegate(RetentionProgress progress)
                        {
                            RetentionOnUiThread(dispatcher, delegate { ApplyRetentionProgress(progress); });
                        });
                });
            }
            catch (Exception)
            {
                result = new RetentionLaunchResult();
                result.Kind = RetentionLaunchKind.Unconfirmed;
            }
            FinishRetentionRequest(request, result);
        }

        private static void RetentionOnUiThread(Dispatcher dispatcher, Action action)
        {
            if (dispatcher == null)
            {
                action();
                return;
            }
            dispatcher.BeginInvoke(action, DispatcherPriority.Background);
        }

        private void ApplyRetentionProgress(RetentionProgress progress)
        {
            if (!retentionOperationInProgress || progress == null)
            {
                return;
            }
            string stage = progress.Stage == "freeing" || progress.Stage == "verifying" || progress.Stage == "checking"
                ? progress.Stage
                : retentionOperationStage;
            if (retentionOperationAction != "apply" && stage != "approval")
            {
                stage = "listing";
            }
            retentionOperationStage = stage;
            if (progress.Count.HasValue && progress.Count.Value >= 0)
            {
                retentionOperationCount = progress.Count.Value;
            }
            retentionOperationPercent = progress.Percent;
            PublishWebPresentationState();
        }

        internal void FinishRetentionRequest(RetentionRequest request, RetentionLaunchResult result)
        {
            retentionOperationInProgress = false;
            retentionOperationAction = string.Empty;
            retentionOperationStage = string.Empty;
            retentionOperationPercent = null;
            retentionView = null;
            try
            {
                RefreshRetentionStateNow();
            }
            catch
            {
                retentionView = null;
            }
            if (request.Action == "apply")
            {
                FinishRetentionApply(request, result);
            }
            else
            {
                FinishRetentionSetting(request, result);
            }
            PublishWebPresentationState();
        }

        private void FinishRetentionSetting(RetentionRequest request, RetentionLaunchResult result)
        {
            RetentionView view = retentionView;
            if (result.Kind == RetentionLaunchKind.Cancelled)
            {
                SetRetentionNotice("You didn't allow the change in the Windows permission prompt, so nothing changed.", "warning");
                return;
            }
            if (result.Kind == RetentionLaunchKind.StillRunning)
            {
                SetRetentionNotice("Rewindle is still checking. It finishes on its own; this page updates when it does.", "info");
                return;
            }
            if (result.Kind == RetentionLaunchKind.Failed)
            {
                SetRetentionNotice(string.IsNullOrEmpty(result.Error)
                    ? "Rewindle couldn't change clean-up. Nothing was removed. Try again."
                    : result.Error + " Nothing was removed.", "error");
                return;
            }
            if (result.Kind == RetentionLaunchKind.Unconfirmed)
            {
                SetRetentionNotice("Rewindle couldn't confirm the change. Nothing was removed. This page shows the setting as it is now.", "warning");
                return;
            }
            if (result.State == "refused")
            {
                SetRetentionNotice("Nothing changed because " + RetentionRefusalReason(result.RefusalCode) + ". " +
                    RetentionRefusalNextStep(result.RefusalCode), "warning");
                return;
            }
            if (result.State == "failed")
            {
                SetRetentionNotice("Rewindle couldn't check for old backups. Nothing was removed. Try again later.", "error");
                return;
            }
            if (result.State == "disabled")
            {
                SetRetentionNotice("Clean-up is off. Rewindle keeps every new backup.", "success");
                return;
            }
            bool ready = view != null && view.Mode == "on" && view.PreviewStatus == "ready";
            if (result.State == "configured")
            {
                if (ready && view.RemoveCount > 0)
                {
                    SetRetentionNotice("Clean-up is on.", "success");
                    // The list opens for the person to look at; nothing is removed until they confirm it.
                    string ignored;
                    OpenRetentionReview(out ignored);
                    return;
                }
                SetRetentionNotice(ready ? "Clean-up is on. Nothing to remove right now." : "Clean-up is on.", "success");
                return;
            }
            if (ready && view.RemoveCount > 0)
            {
                SetRetentionNotice(view.RemoveCount.ToString(CultureInfo.CurrentCulture) +
                    (view.RemoveCount == 1 ? " old backup can" : " old backups can") +
                    " be removed. Choose Review and remove to see the list.", "info");
            }
            else if (ready)
            {
                SetRetentionNotice("Nothing to remove right now.", "info");
            }
        }

        private void FinishRetentionApply(RetentionRequest request, RetentionLaunchResult result)
        {
            Dictionary<string, object> outcome = new Dictionary<string, object>();
            outcome["removedCount"] = result.RemovedCount;
            outcome["confirmedCount"] = ParseCount(request.RemoveCount);
            outcome["freedDisplay"] = string.Empty;
            outcome["reason"] = string.Empty;
            string status;
            switch (result.Kind)
            {
                case RetentionLaunchKind.Cancelled:
                    status = "declined";
                    break;
                case RetentionLaunchKind.Failed:
                    status = "failed";
                    outcome["reason"] = result.Error ?? string.Empty;
                    break;
                case RetentionLaunchKind.Finished:
                    status = result.State;
                    break;
                default:
                    status = "unconfirmed";
                    break;
            }
            if (status == "removed" || status == "nothing_to_remove")
            {
                RetentionView view = retentionView;
                if (view != null && view.LastRun != null && view.LastRun.FreeBytesBefore.HasValue &&
                    view.LastRun.FreeBytesAfter.HasValue && view.LastRun.FreeBytesAfter.Value > view.LastRun.FreeBytesBefore.Value)
                {
                    outcome["freedDisplay"] = FormatStorageBytes(view.LastRun.FreeBytesAfter.Value - view.LastRun.FreeBytesBefore.Value);
                }
            }
            if (status == "refused")
            {
                // An out-of-date list (a backup finished while it was open) ends here too: the result says to close it and
                // choose Check now. It is not marked as updated, since there is no new list to show until Check now makes one.
                outcome["reason"] = result.RefusalCode ?? string.Empty;
            }
            if (status == "partial" && result.RemovalUnverified)
            {
                outcome["reason"] = "unverified";
            }
            if (status == "space_pending" && !result.HistoryRecorded && result.RemovedCount > 0)
            {
                // The removal wasn't recorded, so the next list can't offer to finish freeing the space: the next removal does.
                outcome["reason"] = "unrecorded";
            }
            if (status == "check_failed" && result.CheckUnfinished)
            {
                outcome["reason"] = "unfinished";
            }
            outcome["status"] = status;
            retentionReviewResult = outcome;
            if (status == "preview_changed" || status == "declined")
            {
                // The engine wrote the new list (or nothing happened): the dialog shows the list as it is now.
                RetentionView view = retentionView;
                if (view != null && view.Mode == "on" && view.PreviewStatus == "ready" &&
                    (view.RemoveCount > 0 || view.PrunePending))
                {
                    retentionReviewCapture = view;
                    retentionReviewChanged = false;
                    retentionReviewList = view.RemoveCount > 0 ? "remove" : "keep";
                    retentionReviewOffset = 0;
                }
                else if (status == "preview_changed")
                {
                    // The new list offers nothing to remove, or isn't ready: the result says so and the dialog ends there.
                    outcome["reason"] = "closed";
                }
            }
            retentionReviewOpen = true;
        }

        private void SetRetentionNotice(string text, string tone)
        {
            retentionNoticeText = text ?? string.Empty;
            retentionNoticeTone = tone ?? "info";
            retentionNoticeExpiresAt = MonotonicAfter(RetentionNoticeLifetime);
        }

        // The reason a request was refused, to follow "because". Never a code or an engine word.
        internal static string RetentionRefusalReason(string code)
        {
            switch (code)
            {
                case "busy": return "a backup or another change is running";
                case "google_drive_not_supported": return "clean-up isn't available yet for backups kept in Google Drive";
                case "pending_change": return "an unfinished change to your backups must be completed first";
                case "no_verified_backup": return "there is no checked backup yet";
                case "last_backup_not_verified": return "the last backup didn't finish";
                case "folders_changed": return "your folders changed since the last backup";
                case "change_review_open": return "your latest backup needs a look first";
                case "clock_problem": return "your PC's date or time looks wrong";
                case "future_dated_backup": return "one of your backups is dated in the future";
                case "backup_location_unavailable": return "Rewindle can't reach your backup location";
                case "policy_inactive": return "clean-up is off";
                case "preview_mismatch": return "the list is out of date";
                case "earlier_changes_not_confirmed": return "your files need checking first";
                default: return "something it needs wasn't ready";
            }
        }

        internal static string RetentionRefusalNextStep(string code)
        {
            switch (code)
            {
                case "busy": return "Try again when it has finished.";
                case "google_drive_not_supported": return "Your backups stay where they are.";
                case "pending_change": return "Protection shows what to do.";
                case "no_verified_backup": return "Clean-up starts after your first backup has been made and checked.";
                case "last_backup_not_verified": return "Choose Back up now on Protection.";
                case "folders_changed": return "Choose Back up now on Protection, or wait for the next scheduled backup.";
                case "change_review_open": return "Look at it on Protection.";
                case "clock_problem": return "Correct it in Windows Settings under Time & language, then run a backup.";
                case "future_dated_backup": return "If that date is far away, save a problem report from Help and about.";
                case "backup_location_unavailable": return "Protection shows what to do.";
                case "policy_inactive": return "Turn it on again to use it.";
                case "preview_mismatch": return "Close the list and choose Check now.";
                case "earlier_changes_not_confirmed": return "Tick the box to say your files look right, then try again.";
                default: return "Try again later.";
            }
        }

        // ---- State ---------------------------------------------------------------------------------------------------------

        private Dictionary<string, object> BuildWebRetentionState()
        {
            Dictionary<string, object> state = new Dictionary<string, object>();
            state["keepDaily"] = RetentionNames.DefaultDaily;
            state["keepWeekly"] = RetentionNames.DefaultWeekly;
            state["keepMonthly"] = RetentionNames.DefaultMonthly;
            state["limits"] = new Dictionary<string, object>
            {
                { "daily", new[] { RetentionNames.MinimumDaily, RetentionNames.MaximumDaily } },
                { "weekly", new[] { RetentionNames.MinimumWeekly, RetentionNames.MaximumWeekly } },
                { "monthly", new[] { RetentionNames.MinimumMonthly, RetentionNames.MaximumMonthly } }
            };
            state["recommended"] = new Dictionary<string, object>
            {
                { "daily", RetentionNames.DefaultDaily },
                { "weekly", RetentionNames.DefaultWeekly },
                { "monthly", RetentionNames.DefaultMonthly }
            };
            state["resetByReinstall"] = false;
            state["problem"] = string.Empty;
            state["preview"] = null;
            state["lastRun"] = null;
            state["review"] = null;
            state["notice"] = null;
            state["operation"] = BuildWebRetentionOperation();
            state["unsupportedReason"] = string.Empty;
            Dictionary<string, object> off = WebRetentionAbility(false, RetentionUnavailableMessage);
            state["canConfigure"] = off;
            state["canTurnOff"] = off;
            state["canReview"] = off;
            state["canCheckNow"] = off;

            // The legacy personal edition has no clean-up manager: nothing of its state folder is read for it.
            if (!RetentionSupportedByProfile())
            {
                state["mode"] = "unsupported";
                state["unsupportedReason"] = "legacy";
                return state;
            }
            RefreshRetentionStateAsync();
            if (!retentionCapabilityKnown)
            {
                RetentionCapabilityAvailable();
            }
            if (retentionCapabilityKnown && !retentionCapabilitySupported)
            {
                state["mode"] = "unsupported";
                state["unsupportedReason"] = "older_service";
                return state;
            }
            RetentionView view = retentionView;
            if (view == null)
            {
                state["mode"] = "unknown";
                state["problem"] = currentSourceConfiguration == null ? "plan_unavailable" : "not_read";
                return state;
            }
            state["keepDaily"] = view.KeepDaily;
            state["keepWeekly"] = view.KeepWeekly;
            state["keepMonthly"] = view.KeepMonthly;
            if (view.GoogleDrive)
            {
                state["mode"] = "unsupported";
                state["unsupportedReason"] = "google_drive";
                return state;
            }
            state["mode"] = view.Mode;
            state["problem"] = view.Problem ?? string.Empty;
            state["resetByReinstall"] = view.Mode == "off" && view.ResetByReinstall;
            state["lastRun"] = BuildWebRetentionLastRun(view.LastRun);
            if (retentionNoticeText.Length > 0 && retentionNoticeExpiresAt != 0 && !MonotonicReached(retentionNoticeExpiresAt))
            {
                state["notice"] = new Dictionary<string, object> { { "text", retentionNoticeText }, { "tone", retentionNoticeTone } };
            }
            string busy = RetentionBusyReason();
            bool canChange = view.Mode != "unknown" && busy.Length == 0;
            state["canConfigure"] = WebRetentionAbility(canChange, busy.Length > 0 ? busy : "Rewindle couldn't read the clean-up setting.");
            state["canTurnOff"] = WebRetentionAbility(canChange && view.Mode == "on", busy.Length > 0 ? busy : "Clean-up is off.");
            if (view.Mode == "on")
            {
                Dictionary<string, object> preview = BuildWebRetentionPreview(view);
                state["preview"] = preview;
                string status = preview["status"] as string;
                bool reviewable = status == "ready" && (view.RemoveCount > 0 || view.PrunePending);
                state["canReview"] = WebRetentionAbility(reviewable && busy.Length == 0,
                    busy.Length > 0 ? busy : "There is nothing to review right now.");
                state["canCheckNow"] = WebRetentionAbility(busy.Length == 0, busy);
            }
            state["review"] = BuildWebRetentionReview();
            return state;
        }

        private static Dictionary<string, object> WebRetentionAbility(bool enabled, string help)
        {
            Dictionary<string, object> ability = new Dictionary<string, object>();
            ability["enabled"] = enabled;
            ability["help"] = enabled ? string.Empty : help ?? string.Empty;
            return ability;
        }

        private Dictionary<string, object> BuildWebRetentionOperation()
        {
            Dictionary<string, object> operation = new Dictionary<string, object>();
            operation["active"] = retentionOperationInProgress;
            operation["action"] = retentionOperationInProgress ? retentionOperationAction : string.Empty;
            operation["stage"] = retentionOperationInProgress ? retentionOperationStage : string.Empty;
            operation["count"] = retentionOperationCount;
            operation["percent"] = retentionOperationPercent.HasValue ? (object)retentionOperationPercent.Value : null;
            return operation;
        }

        // What the page needs to say about the list, without the list itself (that is sent only while it is open).
        private Dictionary<string, object> BuildWebRetentionPreview(RetentionView view)
        {
            Dictionary<string, object> preview = new Dictionary<string, object>();
            string status = view.PreviewStatus;
            string blocked = view.BlockedReason ?? string.Empty;
            // The dashboard knows some reasons before the engine is asked again: a list made before the latest backup is
            // not offered when that backup already shows why clean-up has to wait.
            TelemetrySnapshot snapshot = lastSnapshot;
            string live = string.Empty;
            if (snapshot != null && !snapshot.IsActive)
            {
                live = snapshot.LastVerifiedFinishedUtc == null ? "no_verified_backup"
                    : snapshot.IsFailure || snapshot.IsCancelled ? "last_backup_not_verified"
                    : snapshot.HasMaintenanceHold ? "change_review_open"
                    : string.Empty;
            }
            if (live.Length > 0 && status != "error" && status != "blocked")
            {
                status = "blocked";
                blocked = live;
            }
            preview["status"] = status;
            preview["blocked"] = status == "blocked" ? blocked : string.Empty;
            preview["errorCode"] = status == "error" ? view.ErrorCode ?? string.Empty : string.Empty;
            preview["checkedAt"] = view.CreatedUtc ?? string.Empty;
            preview["removeCount"] = status == "ready" ? view.RemoveCount : 0;
            preview["keepCount"] = status == "ready" ? view.KeepCount : 0;
            string oldest = string.Empty;
            string newest = string.Empty;
            if (status == "ready")
            {
                foreach (RetentionItemView item in view.Remove)
                {
                    if (oldest.Length == 0 || string.CompareOrdinal(item.Time, oldest) < 0) oldest = item.Time;
                    if (newest.Length == 0 || string.CompareOrdinal(item.Time, newest) > 0) newest = item.Time;
                }
            }
            preview["oldestRemoveAt"] = oldest;
            preview["newestRemoveAt"] = newest;
            preview["earlierChanges"] = status == "ready" ? BuildWebRetentionEarlierChanges(view.EarlierChanges) : new object[0];
            preview["earlierChangesUnknown"] = status == "ready" && view.EarlierChangesUnknown;
            preview["futureDatedAt"] = status == "blocked" && blocked == "future_dated_backup" ? view.FutureDatedUtc ?? string.Empty : string.Empty;
            preview["prunePending"] = status == "ready" && view.PrunePending;
            return preview;
        }

        // Each earlier backup to look over with its kind, newest first as the engine lists them. The page words a "hold" as
        // unusual changes and the other kinds as backups that could not be compared (retention.ts filesCheckSentence).
        private static object[] BuildWebRetentionEarlierChanges(List<RetentionEarlierChange> changes)
        {
            List<object> list = new List<object>();
            if (changes != null)
            {
                foreach (RetentionEarlierChange change in changes)
                {
                    Dictionary<string, object> item = new Dictionary<string, object>();
                    item["at"] = change.FinishedUtc ?? string.Empty;
                    item["kind"] = RetentionEarlierChange.KindOf(change.Kind);
                    list.Add(item);
                }
            }
            return list.ToArray();
        }

        private static Dictionary<string, object> BuildWebRetentionLastRun(RetentionHistoryEntryView entry)
        {
            if (entry == null)
            {
                return null;
            }
            Dictionary<string, object> lastRun = new Dictionary<string, object>();
            lastRun["finishedAt"] = entry.FinishedUtc ?? string.Empty;
            lastRun["outcome"] = entry.Outcome;
            lastRun["removedCount"] = entry.RemovedCount;
            lastRun["confirmedCount"] = entry.ConfirmedCount;
            lastRun["unverified"] = entry.RemovalUnverified;
            lastRun["checkUnfinished"] = entry.CheckUnfinished;
            lastRun["freedDisplay"] = entry.FreeBytesBefore.HasValue && entry.FreeBytesAfter.HasValue &&
                entry.FreeBytesAfter.Value > entry.FreeBytesBefore.Value
                    ? FormatStorageBytes(entry.FreeBytesAfter.Value - entry.FreeBytesBefore.Value)
                    : string.Empty;
            return lastRun;
        }

        // Only counts, month totals and one page of rows: up to 10,000 backups stay in the host (C16).
        private Dictionary<string, object> BuildWebRetentionReview()
        {
            RetentionView capture = retentionReviewCapture;
            if (!retentionReviewOpen || capture == null)
            {
                return null;
            }
            Dictionary<string, object> review = new Dictionary<string, object>();
            review["removeCount"] = capture.RemoveCount;
            review["keepCount"] = capture.KeepCount;
            string newestKept = string.Empty;
            foreach (RetentionItemView item in capture.Keep)
            {
                if (newestKept.Length == 0 || string.CompareOrdinal(item.Time, newestKept) > 0) newestKept = item.Time;
            }
            review["newestKeptAt"] = newestKept;
            review["earlierChanges"] = BuildWebRetentionEarlierChanges(capture.EarlierChanges);
            review["earlierChangesUnknown"] = capture.EarlierChangesUnknown;
            review["needsFilesConfirmed"] = capture.NeedsFilesConfirmed;
            review["pruneOnly"] = capture.RemoveCount == 0 && capture.PrunePending;
            review["changed"] = retentionReviewChanged;
            review["running"] = retentionOperationInProgress && retentionOperationAction == "apply";
            review["captureKey"] = capture.PreviewSha256 == null ? string.Empty : capture.PreviewSha256.Substring(0, 12);
            // Each backup belongs to the month of its own recorded time, as the engine counts it.
            List<object> months = new List<object>();
            Dictionary<string, int> monthCounts = new Dictionary<string, int>(StringComparer.Ordinal);
            List<string> monthOrder = new List<string>();
            foreach (RetentionItemView item in capture.Remove)
            {
                string month = item.Time.Length >= 7 ? item.Time.Substring(0, 7) : item.Time;
                if (!monthCounts.ContainsKey(month))
                {
                    monthCounts[month] = 0;
                    monthOrder.Add(month);
                }
                monthCounts[month]++;
            }
            monthOrder.Sort(string.CompareOrdinal);
            monthOrder.Reverse();
            foreach (string month in monthOrder)
            {
                months.Add(new Dictionary<string, object> { { "month", month }, { "count", monthCounts[month] } });
            }
            review["months"] = months.ToArray();
            List<RetentionItemView> source = retentionReviewList == "keep" ? capture.Keep : capture.Remove;
            List<RetentionItemView> sorted = new List<RetentionItemView>(source);
            sorted.Sort(delegate(RetentionItemView left, RetentionItemView right) { return string.CompareOrdinal(right.Time, left.Time); });
            int offset = Math.Max(0, Math.Min(retentionReviewOffset, Math.Max(0, sorted.Count - 1)));
            offset -= offset % RetentionReviewPageSize;
            List<object> rows = new List<object>();
            for (int index = offset; index < sorted.Count && index < offset + RetentionReviewPageSize; index++)
            {
                RetentionItemView item = sorted[index];
                Dictionary<string, object> row = new Dictionary<string, object>();
                row["key"] = item.Id.Substring(0, 12);
                row["when"] = item.Time;
                row["files"] = item.Files.HasValue ? (object)item.Files.Value : null;
                row["reasons"] = item.Reasons.ToArray();
                rows.Add(row);
            }
            review["page"] = new Dictionary<string, object>
            {
                { "list", retentionReviewList == "keep" ? "keep" : "remove" },
                { "offset", offset },
                { "total", sorted.Count },
                { "size", RetentionReviewPageSize },
                { "rows", rows.ToArray() }
            };
            review["result"] = retentionReviewResult;
            return review;
        }
    }
}
