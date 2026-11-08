using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;

namespace ResticBackuper.Dashboard
{
    // ---- Find a file in every backup (Restore, Choose a backup) ---------------------------------------------------------
    // The person types part of a name; the flow's approved restore session (RestoreSessionHost) runs find_files, which looks
    // through the backups in the list on screen, newest first, for about 20 seconds a page, and the results stay here, in
    // memory, until the list is read again or Restore closes. "Look further back" asks for the next page from where the
    // last one stopped. Restore this selects that one path in that backup and goes on to Choose a folder, so the rest is the
    // ordinary restore. Only an engine whose session serves the search gets it (restoreFlowSearchAvailable); the page shows
    // no Find tab otherwise. The rules for the text and the checks on a page are in RestoreFileSearch.cs.
    public partial class DashboardWindow
    {
        internal const string RestoreFlowSearchUnavailableMessage =
            "Searching all your backups at once is not available with the backup service on this PC. Choose a backup by date, then open its folders to find your file.";

        private bool restoreFlowSearchAvailable;
        private RestoreFlowSearchState restoreFlowSearch = new RestoreFlowSearchState();
        // A search is refused this close to the next scheduled backup: the search holds the run lock for up to about 25 seconds,
        // and a scheduled backup that finds it held does not run.
        private static readonly TimeSpan RestoreFlowSearchBackupDueWindow = TimeSpan.FromMinutes(2);

        private static readonly string[] RestoreFlowSearchCommands =
        {
            "restoreFlowFindFiles",
            "restoreFlowFindMore",
            "restoreFlowFindClear",
            "restoreFlowPickFound"
        };

        // The search of the open flow: its text, where it stands, and what it found (merged over the pages asked for).
        private sealed class RestoreFlowSearchState
        {
            internal string Text = string.Empty;
            // idle, searching, done or failed.
            internal string Status = "idle";
            // With done: complete, more, tooMany, tooBroad or tooSlow.
            internal string Outcome = string.Empty;
            internal string Message = string.Empty;
            internal string Error = string.Empty;
            internal bool ListChanged;
            // The last page looked through no backup (tooSlow: the list or the next backup took its time): the page offers Try
            // again, which goes on from the same backup, rather than Look further back.
            internal bool NothingSearched;
            internal int Searched;
            internal string NewestTime;
            internal string OldestSearchedTime;
            internal string NextFromSnapshotId;
            internal bool Overflow;
            internal List<RestoreFlowSearchEntry> Entries = new List<RestoreFlowSearchEntry>();
        }

        private sealed class RestoreFlowSearchEntry
        {
            internal string Path;
            internal string Name;
            internal string Type;
            internal bool HasMoreVersions;
            internal List<RestoreFlowSearchVersion> Versions = new List<RestoreFlowSearchVersion>();

            internal string LastSeenTime
            {
                get { return Versions.Count == 0 ? null : Versions[0].SnapshotTime; }
            }
        }

        // One size and change time of a file (a folder has one row), the newest listed backup that holds it and the oldest.
        private sealed class RestoreFlowSearchVersion
        {
            internal string Key;
            internal string SnapshotId;
            internal string SnapshotTime;
            internal string FirstSnapshotTime;
            internal string Modified;
            internal long Size;
            internal long Backups;
            internal bool LegacyUnbound;
        }

        private static bool IsRestoreFlowSearchCommand(string command)
        {
            return RestoreFlowSearchCommands.Contains(command ?? string.Empty, StringComparer.Ordinal);
        }

        private bool ExecuteRestoreFlowSearchCommand(string command, IDictionary<string, object> payload, out string error)
        {
            if (command == "restoreFlowFindFiles")
            {
                return BeginRestoreFlowFind(payload, out error);
            }
            if (command == "restoreFlowFindMore")
            {
                return ContinueRestoreFlowFind(out error);
            }
            if (command == "restoreFlowFindClear")
            {
                return ClearRestoreFlowFind(out error);
            }
            if (command == "restoreFlowPickFound")
            {
                return PickRestoreFlowFound(payload, out error);
            }
            error = "The requested restore-flow command is not allowed.";
            return false;
        }

        private void ResetRestoreFlowSearch()
        {
            restoreFlowSearch = new RestoreFlowSearchState();
        }

        // What every search command needs: Restore open on Choose a backup, nothing running, a session that serves searches and
        // a list of backups to look through.
        private bool RequireRestoreFlowSearchReady(out string error)
        {
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            if (!restoreFlowSearchAvailable || restoreFlowApprovalSession == null)
            {
                error = RestoreFlowSearchUnavailableMessage;
                return false;
            }
            if (restoreFlowStep != "backup")
            {
                error = RestoreFlowSearchNotOnFirstStepMessage;
                return false;
            }
            if (restoreFlowSnapshots == null || restoreFlowSnapshots.Count == 0)
            {
                error = restoreFlowStatus == "failed" ? RestoreFlowSearchNoBackupsMessage : RestoreFlowSearchListNotReadyMessage;
                return false;
            }
            error = string.Empty;
            return true;
        }

        // Why a search cannot start now even though Restore is ready: a backup or settings change running, or a backup about to
        // start. Also sent to the page as a hint; each search command checks it again.
        private bool CheckRestoreFlowSearchGuards(out string error)
        {
            if (!CheckRestoreFlowOperationGuards(out error))
            {
                return false;
            }
            if (RestoreFlowBackupDueSoon())
            {
                error = RestoreFlowSearchBackupDueMessage;
                return false;
            }
            error = string.Empty;
            return true;
        }

        // Whether a scheduled backup is about to run: Windows is catching up on one it missed, or the next run is less than two
        // minutes away (or started a moment ago).
        private bool RestoreFlowBackupDueSoon()
        {
            TaskSchedule schedule = currentTaskSchedule;
            TelemetrySnapshot snapshot = string.IsNullOrEmpty(webTelemetryError) ? lastSnapshot : null;
            if (schedule != null && snapshot != null)
            {
                BackupFreshnessResult freshness = BackupFreshnessEvaluator.EvaluateNow(
                    schedule,
                    snapshot.LastVerifiedFinishedUtc,
                    scheduleCoveredThroughUtc,
                    AvailableSinceUtc());
                if (freshness != null && freshness.State == BackupFreshnessState.CatchingUp)
                {
                    return true;
                }
            }
            DateTime nextRun;
            string next = NextRunIso(schedule);
            if (next.Length == 0 ||
                !DateTime.TryParse(next, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out nextRun))
            {
                return false;
            }
            TimeSpan until = nextRun.ToUniversalTime() - DateTime.UtcNow;
            return until > TimeSpan.FromMinutes(-1) && until < RestoreFlowSearchBackupDueWindow;
        }

        private bool BeginRestoreFlowFind(IDictionary<string, object> payload, out string error)
        {
            string text;
            string fromSnapshotId;
            SourceConfiguration fresh;
            if (!CheckRestoreFlowFind(payload, out text, out fromSnapshotId, out fresh, out error))
            {
                return false;
            }
            restoreFlowConfiguration = fresh;
            ResetRestoreFlowSearch();
            restoreFlowSearch.Text = text;
            StartRestoreFlowFind(fresh, fromSnapshotId, false);
            return true;
        }

        // Everything Find checks before it asks the session, in this order: the flow, the text, the plan, then anything running
        // or about to run. The first page starts from the newest backup in the list on screen.
        private bool CheckRestoreFlowFind(
            IDictionary<string, object> payload,
            out string text,
            out string fromSnapshotId,
            out SourceConfiguration fresh,
            out string error)
        {
            text = string.Empty;
            fromSnapshotId = string.Empty;
            fresh = null;
            if (!RequireRestoreFlowSearchReady(out error))
            {
                return false;
            }
            text = RestoreFileSearchText.Normalize(WebReadString(payload, "text", 4096));
            string problem = RestoreFileSearchText.Problem(text);
            if (problem.Length != 0)
            {
                error = RestoreFlowSearchTextMessage(problem);
                return false;
            }
            if (!TryGetFreshRestoreFlowConfiguration(out fresh, out error) || !CheckRestoreFlowSearchGuards(out error))
            {
                return false;
            }
            fromSnapshotId = NewestRestoreFlowSnapshotId();
            if (fromSnapshotId.Length == 0)
            {
                error = RestoreFlowSearchListNotReadyMessage;
                return false;
            }
            return true;
        }

        // "Look further back" (and Try again after a page that looked through nothing, tooSlow): the next page, from where the last
        // ended.
        private bool ContinueRestoreFlowFind(out string error)
        {
            SourceConfiguration fresh;
            if (!CheckRestoreFlowFindMore(out fresh, out error))
            {
                return false;
            }
            restoreFlowConfiguration = fresh;
            StartRestoreFlowFind(fresh, restoreFlowSearch.NextFromSnapshotId, true);
            return true;
        }

        private bool CheckRestoreFlowFindMore(out SourceConfiguration fresh, out string error)
        {
            fresh = null;
            if (!RequireRestoreFlowSearchReady(out error))
            {
                return false;
            }
            RestoreFlowSearchState state = restoreFlowSearch;
            if (state.Overflow)
            {
                error = RestoreFlowSearchNarrowFirstMessage;
                return false;
            }
            if (!RestoreFlowSearchCanGoOn(state))
            {
                error = RestoreFlowSearchNothingOlderMessage;
                return false;
            }
            if (FindRestoreFlowSnapshot(state.NextFromSnapshotId) == null)
            {
                error = RestoreFlowSearchListChangedMessage;
                return false;
            }
            return TryGetFreshRestoreFlowConfiguration(out fresh, out error) && CheckRestoreFlowSearchGuards(out error);
        }

        // Whether the last page left somewhere to go on from: older backups not yet searched (more), or the same backup again
        // after a page that could look through none in its time (tooSlow).
        private static bool RestoreFlowSearchCanGoOn(RestoreFlowSearchState state)
        {
            return state.Status == "done" && (state.Outcome == "more" || state.Outcome == "tooSlow") &&
                !string.IsNullOrEmpty(state.NextFromSnapshotId);
        }

        private bool ClearRestoreFlowFind(out string error)
        {
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            ResetRestoreFlowSearch();
            if (restoreFlowStep == "backup" && restoreFlowSnapshots != null && restoreFlowSnapshots.Count > 0)
            {
                SetRestoreFlowMessage("Choose a backup", "Choose a backup to continue.");
            }
            PublishWebPresentationState();
            return true;
        }

        // The backup the first page starts from: the newest in the list on screen (the page's own choice of newest), so a backup
        // made after the list was read is not searched and every result names a backup the person can see.
        private string NewestRestoreFlowSnapshotId()
        {
            RestoreSnapshot newest = null;
            DateTime? newestTime = null;
            foreach (RestoreSnapshot snapshot in restoreFlowSnapshots)
            {
                if (snapshot == null || !RestoreManagerLauncher.IsLowerHex(snapshot.Id, 64))
                {
                    continue;
                }
                DateTime? time = ParseRestoreFlowSearchTime(snapshot.Time);
                int order = CompareRestoreFlowSearchTimes(time, newestTime);
                if (newest == null || order > 0 || (order == 0 && string.CompareOrdinal(snapshot.Id, newest.Id) > 0))
                {
                    newest = snapshot;
                    newestTime = time;
                }
            }
            return newest == null ? string.Empty : newest.Id;
        }

        private void StartRestoreFlowFind(SourceConfiguration configuration, string fromSnapshotId, bool append)
        {
            int operation = ++restoreFlowOperationGeneration;
            restoreFlowBusy = true;
            restoreFlowCancelRequested = false;
            restoreFlowAwaitingApproval = false;
            restoreFlowStatus = "searching";
            restoreFlowSearch.Status = "searching";
            restoreFlowSearch.Error = string.Empty;
            restoreFlowSearch.ListChanged = false;
            SetRestoreFlowMessage("Searching your backups", RestoreFlowSearchingDetail(restoreFlowSearch.Text));
            PublishWebPresentationState();
            RunRestoreFlowFindAsync(configuration, restoreFlowSearch.Text, fromSnapshotId, operation, append);
        }

        private async void RunRestoreFlowFindAsync(
            SourceConfiguration configuration,
            string text,
            string fromSnapshotId,
            int operation,
            bool append)
        {
            RestoreManagerResult result;
            RestoreSessionHost session = restoreFlowApprovalSession;
            try
            {
                result = await Task.Run(delegate
                {
                    return RestoreManagerLauncher.FindFiles(
                        configuration,
                        session,
                        text,
                        fromSnapshotId,
                        delegate { OnRestoreFlowApprovalRequested(operation); },
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                if (restoreFlowOpen && operation == restoreFlowOperationGeneration && restoreFlowAwaitingApproval)
                                {
                                    restoreFlowAwaitingApproval = false;
                                    SetRestoreFlowMessage("Searching your backups", RestoreFlowSearchingDetail(text));
                                    PublishWebPresentationState();
                                }
                            }));
                        },
                        // A search reports no progress of its own; the shared handler would put the flow back to "loading".
                        delegate(RestoreManagerProgress progress) { });
                });
            }
            catch (Exception exception)
            {
                result = RestoreManagerResult.Failure(exception.Message, -1);
            }
            FinishRestoreFlowFind(result, operation, append);
        }

        // Takes the answer to one page, on the window's thread. An answer for a flow that closed or moved on is dropped.
        private void FinishRestoreFlowFind(RestoreManagerResult result, int operation, bool append)
        {
            if (!restoreFlowOpen || operation != restoreFlowOperationGeneration)
            {
                return;
            }
            restoreFlowBusy = false;
            restoreFlowAwaitingApproval = false;
            restoreFlowStatus = "ready";
            if (restoreFlowCancelRequested)
            {
                restoreFlowCancelRequested = false;
                FailRestoreFlowFind(RestoreFlowSearchStoppedMessage, false);
                return;
            }
            SourceConfiguration fresh;
            string freshnessError;
            if (!TryGetFreshRestoreFlowConfiguration(out fresh, out freshnessError))
            {
                // A plan that changed has already moved the flow to its own result; a plan that could not be read has not.
                if (restoreFlowFailedOperation != "config")
                {
                    FailRestoreFlowFind(freshnessError, false);
                }
                return;
            }
            restoreFlowConfiguration = fresh;
            if (result == null)
            {
                FailRestoreFlowFind(RestoreFlowSearchGenericFailureMessage, false);
                return;
            }
            if (result.UserCancelled)
            {
                FailRestoreFlowFind(RestoreFlowSearchDeclinedMessage, false);
                return;
            }
            if (!result.Succeeded || result.FileSearch == null)
            {
                bool listChanged;
                string message = DescribeRestoreFlowSearchFailure(result.ErrorMessage, out listChanged);
                FailRestoreFlowFind(message, listChanged);
                return;
            }
            ApplyRestoreFlowFindPage(result.FileSearch, append);
        }

        private void FailRestoreFlowFind(string message, bool listChanged)
        {
            RestoreFlowSearchState state = restoreFlowSearch;
            state.Status = "failed";
            state.Outcome = string.Empty;
            state.Message = string.Empty;
            state.Error = string.IsNullOrWhiteSpace(message) ? RestoreFlowSearchGenericFailureMessage : message;
            state.ListChanged = listChanged;
            SetRestoreFlowMessage("Search did not finish", state.Error);
            PublishWebPresentationState();
        }

        // Adds one checked page to the results. Every backup it names must be one of the list on screen, as that list says it is
        // (a plan backup or an older-setup one); otherwise the list changed under the search and nothing of the page is used.
        private void ApplyRestoreFlowFindPage(RestoreFileSearchPage page, bool append)
        {
            foreach (RestoreFileMatch match in page.Matches)
            {
                foreach (RestoreFileVersion found in match.Versions)
                {
                    RestoreSnapshot listed = FindRestoreFlowSnapshot(found.SnapshotId);
                    if (listed == null || listed.IsLegacyUnbound != found.IsLegacyUnbound)
                    {
                        FailRestoreFlowFind(RestoreFlowSearchListChangedMessage, true);
                        return;
                    }
                }
            }
            if (page.NextFromSnapshotId != null && FindRestoreFlowSnapshot(page.NextFromSnapshotId) == null)
            {
                FailRestoreFlowFind(RestoreFlowSearchListChangedMessage, true);
                return;
            }
            RestoreFlowSearchState state = restoreFlowSearch;
            if (!append)
            {
                state.Entries = new List<RestoreFlowSearchEntry>();
                state.Searched = 0;
                state.NewestTime = null;
                state.OldestSearchedTime = null;
            }
            state.Searched += (int)Math.Min(page.SnapshotsSearched, int.MaxValue - state.Searched);
            if (state.NewestTime == null)
            {
                state.NewestTime = page.SearchedNewestTime;
            }
            if (page.SearchedOldestTime != null)
            {
                state.OldestSearchedTime = page.SearchedOldestTime;
            }
            state.NextFromSnapshotId = page.NextFromSnapshotId;
            state.NothingSearched = page.SnapshotsSearched == 0;
            bool cut = MergeRestoreFlowSearchMatches(state, page.Matches);
            state.Overflow = cut || page.Status == "too_many" || state.Overflow;
            state.Outcome = state.Overflow ? "tooMany" : RestoreFlowSearchOutcome(page.Status);
            state.Status = "done";
            state.Error = string.Empty;
            state.ListChanged = false;
            state.Message = DescribeRestoreFlowSearchResult(state);
            SetRestoreFlowMessage("Search finished", state.Message);
            PublishWebPresentationState();
        }

        // Entries are one per type and path; a file's versions are one per size and change time, a folder has one row. A version
        // seen again adds its backups and keeps the newest and the oldest backup that hold it. At most ten versions an entry and
        // a hundred entries are kept, the most recently seen first. Returns whether entries were cut.
        private static bool MergeRestoreFlowSearchMatches(RestoreFlowSearchState state, IList<RestoreFileMatch> matches)
        {
            Dictionary<string, RestoreFlowSearchEntry> entries = new Dictionary<string, RestoreFlowSearchEntry>(StringComparer.Ordinal);
            foreach (RestoreFlowSearchEntry entry in state.Entries)
            {
                entries[entry.Type + "\n" + entry.Path] = entry;
            }
            foreach (RestoreFileMatch match in matches)
            {
                RestoreFlowSearchEntry entry;
                if (!entries.TryGetValue(match.Type + "\n" + match.Path, out entry))
                {
                    entry = new RestoreFlowSearchEntry { Path = match.Path, Name = match.Name, Type = match.Type };
                    entries[match.Type + "\n" + match.Path] = entry;
                    state.Entries.Add(entry);
                }
                if (match.VersionsTotal > match.Versions.Count)
                {
                    entry.HasMoreVersions = true;
                }
                foreach (RestoreFileVersion found in match.Versions)
                {
                    string key = match.Type == "dir"
                        ? "dir"
                        : found.Size.ToString(CultureInfo.InvariantCulture) + "\n" + (found.Modified ?? string.Empty);
                    RestoreFlowSearchVersion known = entry.Versions.FirstOrDefault(
                        candidate => string.Equals(candidate.Key, key, StringComparison.Ordinal));
                    string first = found.FirstSnapshotTime ?? found.SnapshotTime;
                    if (known == null)
                    {
                        entry.Versions.Add(new RestoreFlowSearchVersion
                        {
                            Key = key,
                            SnapshotId = found.SnapshotId,
                            SnapshotTime = found.SnapshotTime,
                            FirstSnapshotTime = first,
                            Modified = match.Type == "dir" ? null : found.Modified,
                            Size = match.Type == "dir" ? 0 : found.Size,
                            Backups = found.Backups,
                            LegacyUnbound = found.IsLegacyUnbound
                        });
                        continue;
                    }
                    known.Backups += found.Backups;
                    if (CompareRestoreFlowSearchTimes(
                        ParseRestoreFlowSearchTime(found.SnapshotTime),
                        ParseRestoreFlowSearchTime(known.SnapshotTime)) > 0)
                    {
                        known.SnapshotId = found.SnapshotId;
                        known.SnapshotTime = found.SnapshotTime;
                        known.LegacyUnbound = found.IsLegacyUnbound;
                    }
                    DateTime? firstTime = ParseRestoreFlowSearchTime(first);
                    if (firstTime.HasValue &&
                        CompareRestoreFlowSearchTimes(firstTime, ParseRestoreFlowSearchTime(known.FirstSnapshotTime)) < 0)
                    {
                        known.FirstSnapshotTime = first;
                    }
                }
                entry.Versions.Sort(delegate(RestoreFlowSearchVersion left, RestoreFlowSearchVersion right)
                {
                    return CompareRestoreFlowSearchTimes(
                        ParseRestoreFlowSearchTime(right.SnapshotTime),
                        ParseRestoreFlowSearchTime(left.SnapshotTime));
                });
                if (entry.Versions.Count > RestoreFileSearch.MaximumVersions)
                {
                    entry.Versions.RemoveRange(RestoreFileSearch.MaximumVersions, entry.Versions.Count - RestoreFileSearch.MaximumVersions);
                    entry.HasMoreVersions = true;
                }
            }
            state.Entries.Sort(delegate(RestoreFlowSearchEntry left, RestoreFlowSearchEntry right)
            {
                int order = CompareRestoreFlowSearchTimes(
                    ParseRestoreFlowSearchTime(right.LastSeenTime),
                    ParseRestoreFlowSearchTime(left.LastSeenTime));
                return order != 0 ? order : string.Compare(left.Path, right.Path, StringComparison.OrdinalIgnoreCase);
            });
            if (state.Entries.Count > RestoreFileSearch.MaximumMatches)
            {
                state.Entries.RemoveRange(RestoreFileSearch.MaximumMatches, state.Entries.Count - RestoreFileSearch.MaximumMatches);
                return true;
            }
            return false;
        }

        // Restore this: that path in that backup, selected on its own, then Choose a folder. The path is one the search found in
        // that backup, which is the form a folder listing gives, so the selection, the review and the restore are the usual ones.
        private bool PickRestoreFlowFound(IDictionary<string, object> payload, out string error)
        {
            if (!RequireRestoreFlowOpen(out error) || !RequireRestoreFlowIdle(out error))
            {
                return false;
            }
            string snapshotId = WebReadString(payload, "snapshotId", 128);
            string requested = WebReadString(payload, "path", 2048);
            string path;
            if (!RestoreManagerLauncher.IsLowerHex(snapshotId, 64) ||
                !TryNormalizeRestoreFlowTreePath(requested, out path, out error) || path == "/" ||
                !string.Equals(path, requested, StringComparison.Ordinal))
            {
                error = RestoreFlowSearchPickGoneMessage;
                return false;
            }
            RestoreFlowSearchEntry entry = restoreFlowSearch.Entries.FirstOrDefault(
                candidate => string.Equals(candidate.Path, path, StringComparison.Ordinal) &&
                    candidate.Versions.Any(held => string.Equals(held.SnapshotId, snapshotId, StringComparison.Ordinal)));
            if (entry == null)
            {
                error = RestoreFlowSearchPickGoneMessage;
                return false;
            }
            RestoreSnapshot snapshot = FindRestoreFlowSnapshot(snapshotId);
            RestoreFlowSearchVersion version = entry.Versions.First(
                candidate => string.Equals(candidate.SnapshotId, snapshotId, StringComparison.Ordinal));
            if (snapshot == null || snapshot.IsLegacyUnbound != version.LegacyUnbound)
            {
                error = RestoreFlowSearchPickBackupGoneMessage;
                return false;
            }
            SourceConfiguration fresh;
            if (!TryGetFreshRestoreFlowConfiguration(out fresh, out error))
            {
                return false;
            }
            restoreFlowConfiguration = fresh;
            if (!string.Equals(snapshot.Id, restoreFlowSelectedSnapshotId, StringComparison.OrdinalIgnoreCase))
            {
                SelectRestoreFlowSnapshot(snapshot.Id);
            }
            restoreFlowObservedPaths.Add(path);
            restoreFlowSelectedPaths = new List<string> { path };
            restoreFlowWholeSnapshotSelected = false;
            InvalidateRestoreFlowReview();
            ClearRestoreFlowTreeError();
            restoreFlowStep = "destination";
            restoreFlowStatus = "ready";
            SetRestoreFlowMessage("Choose a folder", RestoreFlowSearchPickedDetail(entry.Name, snapshot.WhenDisplay));
            PublishWebPresentationState();
            return true;
        }

        // The search as the page shows it, while it serves searches. Results travel only on Choose a backup, like a folder
        // listing only on Choose files.
        private Dictionary<string, object> BuildWebRestoreFlowSearchState()
        {
            if (!restoreFlowSearchAvailable)
            {
                return null;
            }
            RestoreFlowSearchState state = restoreFlowSearch;
            List<Dictionary<string, object>> results = new List<Dictionary<string, object>>();
            if (restoreFlowStep == "backup")
            {
                DateTime? newest = ParseRestoreFlowSearchTime(state.NewestTime);
                foreach (RestoreFlowSearchEntry entry in state.Entries)
                {
                    results.Add(BuildWebRestoreFlowSearchResult(entry, newest));
                }
            }
            string blocked;
            CheckRestoreFlowSearchGuards(out blocked);
            return new Dictionary<string, object>
            {
                { "text", state.Text },
                { "status", state.Status },
                { "outcome", state.Outcome },
                { "message", state.Message },
                { "error", state.Error },
                { "listChanged", state.ListChanged },
                { "nothingSearched", state.NothingSearched },
                { "searched", state.Searched },
                { "total", restoreFlowSnapshots == null ? 0 : restoreFlowSnapshots.Count },
                { "searchedOldest", state.OldestSearchedTime ?? string.Empty },
                { "searchedOldestDisplay", RestoreFlowSearchTimeDisplay(state.OldestSearchedTime) },
                { "canContinue", RestoreFlowSearchCanGoOn(state) && !state.Overflow &&
                    FindRestoreFlowSnapshot(state.NextFromSnapshotId) != null },
                { "overflow", state.Overflow },
                { "blocked", blocked ?? string.Empty },
                { "results", results },
                { "resultsTotal", state.Entries.Count }
            };
        }

        private static Dictionary<string, object> BuildWebRestoreFlowSearchResult(RestoreFlowSearchEntry entry, DateTime? newestSearched)
        {
            int slash = entry.Path.LastIndexOf('/');
            string folder = slash <= 0 ? "/" : entry.Path.Substring(0, slash);
            List<Dictionary<string, object>> versions = new List<Dictionary<string, object>>();
            foreach (RestoreFlowSearchVersion version in entry.Versions)
            {
                versions.Add(new Dictionary<string, object>
                {
                    { "snapshotId", version.SnapshotId },
                    { "when", version.SnapshotTime ?? string.Empty },
                    { "whenDisplay", RestoreFlowSearchTimeDisplay(version.SnapshotTime) },
                    { "firstWhen", version.FirstSnapshotTime ?? string.Empty },
                    { "firstWhenDisplay", RestoreFlowSearchTimeDisplay(version.FirstSnapshotTime) },
                    { "modified", version.Modified ?? string.Empty },
                    { "modifiedDisplay", RestoreFlowSearchTimeDisplay(version.Modified) },
                    { "size", version.Size },
                    { "sizeDisplay", entry.Type == "dir" ? string.Empty : TelemetryFormat.FormatBytes(version.Size) },
                    { "backups", version.Backups },
                    { "isLegacyUnbound", version.LegacyUnbound }
                });
            }
            DateTime? lastSeen = ParseRestoreFlowSearchTime(entry.LastSeenTime);
            return new Dictionary<string, object>
            {
                { "key", entry.Type + "|" + entry.Path },
                { "path", entry.Path },
                { "name", entry.Name },
                { "type", entry.Type },
                // Empty for an item at the top of the backup.
                { "folderDisplay", folder == "/" ? string.Empty : DescribeRestoreFlowFolder(folder) },
                { "lastSeen", entry.LastSeenTime ?? string.Empty },
                { "lastSeenDisplay", RestoreFlowSearchTimeDisplay(entry.LastSeenTime) },
                // Not in the newer backups that were looked through: moved, renamed or deleted since.
                { "missingFromNewer", lastSeen.HasValue && newestSearched.HasValue && lastSeen.Value < newestSearched.Value },
                { "hasMoreVersions", entry.HasMoreVersions },
                { "versions", versions }
            };
        }

        private static DateTime? ParseRestoreFlowSearchTime(string value)
        {
            DateTime parsed;
            if (string.IsNullOrEmpty(value) ||
                !DateTime.TryParse(
                    value,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                    out parsed))
            {
                return null;
            }
            return parsed;
        }

        // Orders two times, an unknown one before every known one.
        private static int CompareRestoreFlowSearchTimes(DateTime? left, DateTime? right)
        {
            if (!left.HasValue || !right.HasValue)
            {
                return left.HasValue ? 1 : right.HasValue ? -1 : 0;
            }
            return left.Value.CompareTo(right.Value);
        }

        private static string RestoreFlowSearchTimeDisplay(string value)
        {
            DateTime? parsed = ParseRestoreFlowSearchTime(value);
            return parsed.HasValue
                ? DateTime.SpecifyKind(parsed.Value, DateTimeKind.Utc).ToLocalTime().ToString("g", CultureInfo.CurrentCulture)
                : string.Empty;
        }

        private static string RestoreFlowSearchOutcome(string status)
        {
            switch (status)
            {
                case "complete": return "complete";
                case "too_many": return "tooMany";
                case "too_broad": return "tooBroad";
                case "too_slow": return "tooSlow";
                default: return "more";
            }
        }

        // ---- File search wording -----------------------------------------------------------------------------------------
        // Everything the host says about a search. tests\test_dashboard_file_search.py reads this region (up to the end marker)
        // for words a person should not have to know. Curly quotes are written as \u201C and \u201D.

        private const string RestoreFlowSearchNotOnFirstStepMessage = "Go back to Choose a backup to search your backups.";
        private const string RestoreFlowSearchListNotReadyMessage = "Wait for your list of backups to open, then search.";
        private const string RestoreFlowSearchNoBackupsMessage = "There are no backups to search yet.";
        private const string RestoreFlowSearchBackupDueMessage =
            "A backup is about to start. Search after it has finished, or choose a backup by date.";
        private const string RestoreFlowSearchNothingOlderMessage = "There are no older backups left to search.";
        private const string RestoreFlowSearchNarrowFirstMessage = "Type more of the name to narrow the search first.";
        private const string RestoreFlowSearchPickGoneMessage = "That version is no longer in the search results. Search again.";
        private const string RestoreFlowSearchPickBackupGoneMessage =
            "That backup is no longer in your list. Choose Reload backups, then search again.";
        private const string RestoreFlowSearchDeclinedMessage =
            "Windows permission was not given, so nothing was searched. Choose Find to be asked again.";
        private const string RestoreFlowSearchStoppedMessage = "The search was stopped. Nothing was changed. Choose Find to search again.";
        private const string RestoreFlowSearchRunLockMessage =
            "A backup or another change started, so Rewindle could not search just now. Nothing was changed. Search again when it has finished.";
        private const string RestoreFlowSearchTooLongMessage =
            "The search took too long and was stopped. Nothing was changed. Type more of the name and try again.";
        private const string RestoreFlowSearchListChangedMessage =
            "Your list of backups changed while Rewindle was searching. Choose Reload backups, then search again.";
        private const string RestoreFlowSearchGenericFailureMessage =
            "Rewindle could not search your backups this time. Nothing was changed. Try again; if it keeps happening, choose Save problem report in Settings.";

        // The rule a text breaks (RestoreFileSearchText.Problem), in the words the page uses for it.
        internal static string RestoreFlowSearchTextMessage(string problem)
        {
            switch (problem)
            {
                case "EMPTY": return "Type a file or folder name first.";
                case "SHORT": return "Type at least 2 characters of the name.";
                case "LONG": return "That is too long for a name. Type up to 200 characters.";
                case "FORBIDDEN": return "Type just the name, for example Budget.xlsx. A name cannot contain \\ / : * ? \" < > |.";
                case "CONTROL": return "That name has characters a file name cannot have. Type it again.";
                default: return string.Empty;
            }
        }

        private static string RestoreFlowSearchingDetail(string text)
        {
            return "Looking for \u201C" + text + "\u201D, newest backup first. This only reads your backups.";
        }

        private static string RestoreFlowSearchPickedDetail(string name, string whenDisplay)
        {
            return "\u201C" + name + "\u201D from the backup of " + whenDisplay + " is selected. Nothing is restored until the last step.";
        }

        // What the backup service's answer means for the person. The service's own sentences are in Manage-Restore.ps1; the
        // channel's (a lost connection, an answer that could not be confirmed) already come in the restore flow's words.
        private static string DescribeRestoreFlowSearchFailure(string error, out bool listChanged)
        {
            listChanged = false;
            string text = (error ?? string.Empty).ToLowerInvariant();
            if (text.Contains("already holds the run lock"))
            {
                return RestoreFlowSearchRunLockMessage;
            }
            if (text.Contains("no longer in the list"))
            {
                listChanged = true;
                return RestoreFlowSearchListChangedMessage;
            }
            if (text.Contains("took too long"))
            {
                return RestoreFlowSearchTooLongMessage;
            }
            if (text.Length == 0 || text.Contains("file search") || text.Contains("restore step failed"))
            {
                return RestoreFlowSearchGenericFailureMessage;
            }
            return error;
        }

        // The summary under the search: how far it looked and what it found. Totals come from the list on screen.
        private string DescribeRestoreFlowSearchResult(RestoreFlowSearchState state)
        {
            int total = restoreFlowSnapshots == null ? 0 : restoreFlowSnapshots.Count;
            string quoted = "\u201C" + state.Text + "\u201D";
            string oldest = RestoreFlowSearchTimeDisplay(state.OldestSearchedTime);
            string backTo = oldest.Length == 0 ? string.Empty : ", back to " + oldest;
            bool found = state.Entries.Count > 0;
            switch (state.Outcome)
            {
                case "complete":
                    if (found)
                    {
                        return total == 1
                            ? "Looked through your only backup."
                            : total > 1
                                ? "Looked through all " + total.ToString("N0", CultureInfo.CurrentCulture) + " backups."
                                : "Looked through your backups.";
                    }
                    return "No file or folder with " + quoted + " in its name is in " +
                        (total == 1
                            ? "your only backup"
                            : total > 1 ? "any of your " + total.ToString("N0", CultureInfo.CurrentCulture) + " backups" : "your backups") +
                        ". Check the spelling, or type a shorter part of the name.";
                case "tooMany":
                    return "More than 100 files and folders match " + quoted +
                        ". The 100 seen most recently are shown. Type more of the name to narrow it down.";
                case "tooBroad":
                    return "So many files are in folders whose names contain " + quoted +
                        " that Rewindle stopped looking. Type more of the file\u2019s name, for example Budget 2026.xlsx.";
                case "tooSlow":
                    // Opening the list, or the next backup, took the whole time. Try again goes on from the same backup.
                    return "Rewindle ran out of time before it could look through " + (state.Searched == 0 ? "a backup" : "an older backup") +
                        ". Your backups may be large or slow to reach right now. Nothing was changed. " +
                        "Choose Try again, or choose a backup by date and open its folders to find your file.";
            }
            if (state.NothingSearched)
            {
                return "Rewindle ran out of time before it could look through a backup. Nothing was changed. Choose Try again to keep going.";
            }
            string searched = state.Searched == 1
                ? "your newest backup"
                : "the " + state.Searched.ToString("N0", CultureInfo.CurrentCulture) + " newest" +
                    (total > state.Searched ? " of your " + total.ToString("N0", CultureInfo.CurrentCulture) : string.Empty) + " backups";
            return found
                ? "Looked through " + searched + backTo + ". Choose Look further back to search older ones."
                : "Nothing with " + quoted + " in its name in " + searched + backTo + ". Choose Look further back to search older ones.";
        }

        // ---- End of file search wording ----------------------------------------------------------------------------------
    }
}
