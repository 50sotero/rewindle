using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace ResticBackuper.Dashboard
{
    // ---- Find a file in every backup ------------------------------------------------------------------------------------
    // An approved restore session (RestoreSessionHost in RestoreManager.cs) serves `find_files`: Manage-Restore.ps1 runs
    // restore.py --find-json under the run lock, which looks for a name in the backups the list shows, newest first, for a
    // time the manager chooses, and says how far back it got. This file holds the rules for the text, the page of results
    // the dashboard accepts and the checks it makes on it. The flow's state, commands and wording are in
    // DashboardWindow.RestoreSearch.cs. See docs/engine-contract.md ("Restore approval session").

    // The rules a search text must meet. The same rules, in the same order, are in restore.py, Manage-Restore.ps1 and the
    // page (fileSearch.ts), and tests\fixtures\file-search-text-cases.json holds the cases all four pass. Only spaces are
    // trimmed; an unpaired surrogate is refused before the length is counted, in UTF-16 code units.
    internal static class RestoreFileSearchText
    {
        internal const int MinimumLength = 2;
        internal const int MaximumLength = 200;
        private const string Forbidden = "\\/:*?\"<>|";

        // "" when the text can be searched for, else the first rule it breaks: EMPTY, CONTROL, FORBIDDEN, SHORT or LONG.
        internal static string Problem(string value)
        {
            string text = Normalize(value);
            if (text.Length == 0)
            {
                return "EMPTY";
            }
            for (int index = 0; index < text.Length; index++)
            {
                char item = text[index];
                if (item < ' ' || item == '\u007f')
                {
                    return "CONTROL";
                }
                if (char.IsHighSurrogate(item) && index + 1 < text.Length && char.IsLowSurrogate(text[index + 1]))
                {
                    index++;
                    continue;
                }
                if (char.IsSurrogate(item))
                {
                    return "CONTROL";
                }
            }
            if (text.IndexOfAny(Forbidden.ToCharArray()) >= 0)
            {
                return "FORBIDDEN";
            }
            if (text.Length < MinimumLength)
            {
                return "SHORT";
            }
            if (text.Length > MaximumLength)
            {
                return "LONG";
            }
            return string.Empty;
        }

        internal static string Normalize(string value)
        {
            return (value ?? string.Empty).Trim(' ');
        }

        // A text exactly as it is sent and bound: acceptable, and already trimmed.
        internal static bool IsNormal(string value)
        {
            return value != null && Problem(value).Length == 0 && string.Equals(Normalize(value), value, StringComparison.Ordinal);
        }

        // What a search's result is bound to, so the record of a search never needs the text itself.
        internal static string Sha256(string text)
        {
            return RestoreManagerLauncher.ComputeSha256(new UTF8Encoding(false, true).GetBytes(text ?? string.Empty));
        }
    }

    // One version of a file found in the backups: a size and a change time, and the backups that hold it. A folder has one.
    internal sealed class RestoreFileVersion
    {
        public string SnapshotId { get; private set; }
        public string SnapshotTime { get; private set; }
        public string FirstSnapshotId { get; private set; }
        public string FirstSnapshotTime { get; private set; }
        public string Modified { get; private set; }
        public long Size { get; private set; }
        public long Backups { get; private set; }
        public string BindingState { get; private set; }

        public bool IsLegacyUnbound
        {
            get { return BindingState == "legacy_unbound"; }
        }

        internal RestoreFileVersion(
            string snapshotId,
            string snapshotTime,
            string firstSnapshotId,
            string firstSnapshotTime,
            string modified,
            long size,
            long backups,
            string bindingState)
        {
            SnapshotId = snapshotId;
            SnapshotTime = snapshotTime;
            FirstSnapshotId = firstSnapshotId;
            FirstSnapshotTime = firstSnapshotTime;
            Modified = modified;
            Size = size;
            Backups = backups;
            BindingState = bindingState;
        }
    }

    internal sealed class RestoreFileMatch
    {
        public string Path { get; private set; }
        public string Name { get; private set; }
        public string Type { get; private set; }
        public long VersionsTotal { get; private set; }
        public IList<RestoreFileVersion> Versions { get; private set; }

        internal RestoreFileMatch(string path, string name, string type, long versionsTotal, IList<RestoreFileVersion> versions)
        {
            Path = path;
            Name = name;
            Type = type;
            VersionsTotal = versionsTotal;
            Versions = versions;
        }
    }

    // One answer to a search: what it found and how far back it got. `Status` is complete, more, too_many, too_broad or
    // too_slow; `NextFromSnapshotId` is where the next request goes on, and null exactly when the search is complete.
    internal sealed class RestoreFileSearchPage
    {
        public string Status { get; private set; }
        public long SnapshotsTotal { get; private set; }
        public long SnapshotsSearched { get; private set; }
        public string SearchedNewestTime { get; private set; }
        public string SearchedOldestTime { get; private set; }
        public string NextFromSnapshotId { get; private set; }
        public long MatchesTotal { get; private set; }
        public IList<RestoreFileMatch> Matches { get; private set; }

        internal RestoreFileSearchPage(
            string status,
            long snapshotsTotal,
            long snapshotsSearched,
            string searchedNewestTime,
            string searchedOldestTime,
            string nextFromSnapshotId,
            long matchesTotal,
            IList<RestoreFileMatch> matches)
        {
            Status = status;
            SnapshotsTotal = snapshotsTotal;
            SnapshotsSearched = snapshotsSearched;
            SearchedNewestTime = searchedNewestTime;
            SearchedOldestTime = searchedOldestTime;
            NextFromSnapshotId = nextFromSnapshotId;
            MatchesTotal = matchesTotal;
            Matches = matches;
        }
    }

    internal static class RestoreFileSearch
    {
        internal const int MaximumMatches = 100;
        internal const int MaximumVersions = 10;
        private const long MaximumBackups = 10000;
        private const int MaximumTimeLength = 64;
        private const int MaximumPathLength = 1024;

        // The request fields of a search, checked before anything is sent (Manage-Restore.ps1 checks them again): a normal
        // text and one exact backup to start from, and neither on any other request.
        internal static void ValidateRequest(string action, string text, string fromSnapshotId)
        {
            if (action == "find_files")
            {
                if (!RestoreFileSearchText.IsNormal(text))
                {
                    throw new ArgumentException("The file search text is invalid.");
                }
                if (!RestoreManagerLauncher.IsLowerHex(fromSnapshotId, 64))
                {
                    throw new ArgumentException("A file search starts from one exact backup.");
                }
                return;
            }
            if (text != null || fromSnapshotId != null)
            {
                throw new ArgumentException("File search fields are only valid for a file search.");
            }
        }

        // The page restore.py returned, checked as Manage-Restore.ps1 (Assert-FindPayload) checks it: this search, this plan,
        // and within the limits. Anything else throws InvalidDataException, and the answer is not used.
        internal static RestoreFileSearchPage Parse(
            IDictionary<string, object> payload,
            string planId,
            string text,
            string fromSnapshotId)
        {
            if (payload == null || ReadString(payload, "schema") != EngineProfile.Current.FileSearchSchema ||
                ReadLong(payload, "schema_version") != 1)
            {
                throw Invalid("schema");
            }
            IDictionary<string, object> binding = ReadObject(payload, "binding");
            IDictionary<string, object> query = ReadObject(payload, "query");
            if (!ElevatedRequestSecurity.FixedEquals(ReadString(binding, "plan_id"), planId) ||
                ReadString(binding, "legacy_match_policy") != "exact-host-scheduled-tags-and-sources" ||
                !ElevatedRequestSecurity.FixedEquals(ReadString(query, "text"), text) ||
                !ElevatedRequestSecurity.FixedEquals(ReadString(query, "from_snapshot_id"), fromSnapshotId))
            {
                throw Invalid("binding");
            }
            string status = ReadString(payload, "status");
            if (status != "complete" && status != "more" && status != "too_many" && status != "too_broad" && status != "too_slow")
            {
                throw Invalid("status");
            }
            long total = ReadLong(payload, "snapshots_total");
            long searched = ReadLong(payload, "snapshots_searched");
            long matchesTotal = ReadLong(payload, "matches_total");
            string next = ReadOptionalString(payload, "next_from_snapshot_id");
            // A finished search has no next start, and too_many may have none when its last batch reached the oldest backup.
            if (total < 0 || total > MaximumBackups || searched < 0 || searched > total || matchesTotal < 0 ||
                (status == "complete"
                    ? next != null
                    : !(status == "too_many" && next == null) && !RestoreManagerLauncher.IsLowerHex(next, 64)))
            {
                throw Invalid("counts");
            }
            List<RestoreFileMatch> matches = new List<RestoreFileMatch>();
            foreach (object item in ReadItems(payload, "matches"))
            {
                if (matches.Count >= MaximumMatches)
                {
                    throw Invalid("matches");
                }
                matches.Add(ParseMatch(item as IDictionary<string, object>));
            }
            return new RestoreFileSearchPage(
                status,
                total,
                searched,
                ReadTime(payload, "searched_newest_time"),
                ReadTime(payload, "searched_oldest_time"),
                next,
                matchesTotal,
                matches);
        }

        private static RestoreFileMatch ParseMatch(IDictionary<string, object> match)
        {
            if (match == null)
            {
                throw Invalid("match");
            }
            string path = ReadString(match, "path");
            string type = ReadString(match, "type");
            if (!IsSnapshotPath(path) || path == "/" ||
                ReadString(match, "name") != path.Substring(path.LastIndexOf('/') + 1) ||
                (type != "file" && type != "dir"))
            {
                throw Invalid("match");
            }
            List<RestoreFileVersion> versions = new List<RestoreFileVersion>();
            foreach (object item in ReadItems(match, "versions"))
            {
                IDictionary<string, object> version = item as IDictionary<string, object>;
                if (version == null || versions.Count >= MaximumVersions)
                {
                    throw Invalid("versions");
                }
                string snapshotId = ReadString(version, "snapshot_id");
                string firstSnapshotId = ReadString(version, "first_snapshot_id");
                string bindingState = ReadString(version, "binding_state");
                long size = ReadLong(version, "size");
                long backups = ReadLong(version, "backups");
                if (!RestoreManagerLauncher.IsLowerHex(snapshotId, 64) || !RestoreManagerLauncher.IsLowerHex(firstSnapshotId, 64) ||
                    (bindingState != "plan" && bindingState != "legacy_unbound") || size < 0 || backups < 1 ||
                    backups > MaximumBackups)
                {
                    throw Invalid("version");
                }
                versions.Add(new RestoreFileVersion(
                    snapshotId,
                    ReadTime(version, "snapshot_time"),
                    firstSnapshotId,
                    ReadTime(version, "first_snapshot_time"),
                    ReadTime(version, "mtime"),
                    size,
                    backups,
                    bindingState));
            }
            long versionsTotal = ReadLong(match, "versions_total");
            if (versions.Count == 0 || versionsTotal < versions.Count || versionsTotal > MaximumBackups)
            {
                throw Invalid("versions");
            }
            return new RestoreFileMatch(path, path.Substring(path.LastIndexOf('/') + 1), type, versionsTotal, versions);
        }

        // A path in the form a folder listing gives it (TryNormalizeRestoreFlowTreePath accepts it unchanged): from the top,
        // forward slashes, and no empty, "." or ".." part.
        internal static bool IsSnapshotPath(string path)
        {
            if (path == null || path.Length == 0 || path.Length > MaximumPathLength || path[0] != '/' ||
                path.IndexOf('\\') >= 0 || path.IndexOf('\0') >= 0)
            {
                return false;
            }
            if (path == "/")
            {
                return true;
            }
            string[] parts = path.Split('/');
            for (int index = 1; index < parts.Length; index++)
            {
                if (parts[index].Length == 0 || parts[index] == "." || parts[index] == "..")
                {
                    return false;
                }
            }
            return true;
        }

        private static InvalidDataException Invalid(string part)
        {
            return new InvalidDataException("The file-search answer is not valid (" + part + ").");
        }

        private static string ReadString(IDictionary<string, object> document, string name)
        {
            object value;
            if (document == null || !document.TryGetValue(name, out value) || !(value is string))
            {
                throw Invalid(name);
            }
            return (string)value;
        }

        private static string ReadOptionalString(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null)
            {
                return null;
            }
            if (!(value is string))
            {
                throw Invalid(name);
            }
            return (string)value;
        }

        private static string ReadTime(IDictionary<string, object> document, string name)
        {
            string value = ReadOptionalString(document, name);
            if (value != null && value.Length > MaximumTimeLength)
            {
                throw Invalid(name);
            }
            return value;
        }

        private static long ReadLong(IDictionary<string, object> document, string name)
        {
            object value;
            if (document == null || !document.TryGetValue(name, out value) || (!(value is int) && !(value is long)))
            {
                throw Invalid(name);
            }
            return Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);
        }

        private static IDictionary<string, object> ReadObject(IDictionary<string, object> document, string name)
        {
            object value;
            IDictionary<string, object> result = document != null && document.TryGetValue(name, out value)
                ? value as IDictionary<string, object>
                : null;
            if (result == null)
            {
                throw Invalid(name);
            }
            return result;
        }

        private static IEnumerable ReadItems(IDictionary<string, object> document, string name)
        {
            object value;
            if (!document.TryGetValue(name, out value) || value == null || value is string || !(value is IEnumerable) ||
                value is IDictionary<string, object>)
            {
                throw Invalid(name);
            }
            return (IEnumerable)value;
        }
    }
}
