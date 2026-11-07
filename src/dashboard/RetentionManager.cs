using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    // Clean-up of old backups, read side and launch side. The dashboard never removes anything itself: it reads the
    // engine's protected clean-up records (setting, list of what would go, history) and starts Manage-Retention.ps1
    // through UAC for one request the person made. Nothing here runs for an engine without a clean-up manager.
    internal static class RetentionNames
    {
        internal const string PolicyFileName = "retention-policy.json";
        internal const string PreviewFileName = "retention-preview.json";
        internal const string HistoryFileName = "retention-history.json";
        internal const string EvidenceFileName = "last-success.json";
        internal const string ResultDirectoryName = "RetentionManagerResults";
        internal const string GroupBy = "host,paths";
        internal const string RemoveSetDomain = "ResticBackuper.RetentionRemoveSet.v1";
        internal const string InstallDomain = "ResticBackuper.RetentionInstall.v1";
        internal const string LocalNtfsMode = "local_ntfs";
        // The engine's own limits (retention.py), so a file the engine accepts is never refused here.
        internal const int MaximumPolicyBytes = 16 * 1024;
        internal const int MaximumPreviewBytes = 8 * 1024 * 1024;
        internal const int MaximumHistoryBytes = 1024 * 1024;
        internal const int MaximumEvidenceBytes = 4 * 1024 * 1024;
        internal const int MaximumManifestBytes = 8 * 1024 * 1024;
        internal const int MaximumConfigurationBytes = 1024 * 1024;
        internal const int MaximumResultBytes = 64 * 1024;
        internal const int MaximumItems = 10000;
        internal const int DefaultDaily = 14;
        internal const int DefaultWeekly = 8;
        internal const int DefaultMonthly = 24;
        internal const int MinimumDaily = 7;
        internal const int MaximumDaily = 90;
        internal const int MinimumWeekly = 4;
        internal const int MaximumWeekly = 104;
        internal const int MinimumMonthly = 6;
        internal const int MaximumMonthly = 120;

        internal static bool CountsInRange(int daily, int weekly, int monthly)
        {
            return daily >= MinimumDaily && daily <= MaximumDaily &&
                weekly >= MinimumWeekly && weekly <= MaximumWeekly &&
                monthly >= MinimumMonthly && monthly <= MaximumMonthly;
        }

        // Why a clean-up is not possible right now, as the engine writes it.
        internal static readonly string[] GateCodes = new[]
        {
            "google_drive_not_supported", "pending_change", "no_verified_backup", "last_backup_not_verified",
            "folders_changed", "change_review_open", "clock_problem", "future_dated_backup",
            "backup_location_unavailable", "policy_inactive"
        };

        // A refusal the manager can answer with: the gates, and the three only a request can meet.
        internal static readonly string[] RefusalCodes = new[]
        {
            "busy", "google_drive_not_supported", "pending_change", "no_verified_backup", "last_backup_not_verified",
            "folders_changed", "change_review_open", "clock_problem", "future_dated_backup",
            "backup_location_unavailable", "policy_inactive", "preview_mismatch", "earlier_changes_not_confirmed"
        };

        internal static bool IsOneOf(string value, string[] accepted)
        {
            if (value == null)
            {
                return false;
            }
            foreach (string item in accepted)
            {
                if (string.Equals(item, value, StringComparison.Ordinal))
                {
                    return true;
                }
            }
            return false;
        }
    }

    // Whether the installed engine has the clean-up manager: the same reading rules as RestoreSessionCapability. A
    // missing block means an older Rewindle engine, which the page tells to reinstall.
    internal static class RetentionCapability
    {
        private const int MaximumBytes = 16 * 1024;

        internal static bool IsSupported(EngineProfile profile, string installRoot)
        {
            if (profile == null || string.IsNullOrEmpty(profile.RetentionManagerFileName) ||
                string.IsNullOrWhiteSpace(installRoot))
            {
                return false;
            }
            try
            {
                DirectoryInfo root = new DirectoryInfo(installRoot);
                string path = Path.Combine(root.FullName, EngineProfile.EngineCapabilitiesFileName);
                FileInfo file = new FileInfo(path);
                if (!root.Exists || (root.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    !file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    file.Length <= 0 || file.Length > MaximumBytes)
                {
                    return false;
                }
                byte[] bytes = RetentionFiles.ReadAllBounded(path, MaximumBytes);
                IDictionary<string, object> document = RetentionJson.ParseObject(bytes, MaximumBytes);
                IDictionary<string, object> block = RetentionJson.Object(document, "retention");
                long? schemaVersion = RetentionJson.Integer(document, "schema_version");
                return block != null && schemaVersion.HasValue && schemaVersion.Value == 1 &&
                    string.Equals(RetentionJson.String(document, "schema"), profile.EngineCapabilitiesSchema, StringComparison.Ordinal) &&
                    string.Equals(RetentionJson.String(block, "manager"), profile.RetentionManagerFileName, StringComparison.Ordinal) &&
                    string.Equals(RetentionJson.String(block, "request_domain"), profile.RetentionRequestDomain, StringComparison.Ordinal) &&
                    string.Equals(RetentionJson.String(block, "policy_schema"), profile.RetentionPolicySchema, StringComparison.Ordinal) &&
                    string.Equals(RetentionJson.String(block, "preview_schema"), profile.RetentionPreviewSchema, StringComparison.Ordinal) &&
                    string.Equals(RetentionJson.String(block, "history_schema"), profile.RetentionHistorySchema, StringComparison.Ordinal);
            }
            catch
            {
                return false;
            }
        }
    }

    internal static class RetentionJson
    {
        internal static IDictionary<string, object> ParseObject(byte[] bytes, int limit)
        {
            if (bytes == null || bytes.Length == 0 || bytes.Length > limit)
            {
                throw new InvalidDataException("The document has an invalid size.");
            }
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = int.MaxValue;
            IDictionary<string, object> document =
                serializer.DeserializeObject(new UTF8Encoding(false, true).GetString(bytes)) as IDictionary<string, object>;
            if (document == null)
            {
                throw new InvalidDataException("The document is not one JSON object.");
            }
            return document;
        }

        internal static string String(IDictionary<string, object> document, string name)
        {
            object value;
            return document != null && document.TryGetValue(name, out value) ? value as string : null;
        }

        internal static bool? Boolean(IDictionary<string, object> document, string name)
        {
            object value;
            if (document == null || !document.TryGetValue(name, out value) || !(value is bool))
            {
                return null;
            }
            return (bool)value;
        }

        // A whole number, as the engine writes counts and generations (never a boolean or a fraction).
        internal static long? Integer(IDictionary<string, object> document, string name)
        {
            object value;
            if (document == null || !document.TryGetValue(name, out value) || value == null)
            {
                return null;
            }
            if (value is int)
            {
                return (int)value;
            }
            if (value is long)
            {
                return (long)value;
            }
            return null;
        }

        internal static IDictionary<string, object> Object(IDictionary<string, object> document, string name)
        {
            object value;
            return document != null && document.TryGetValue(name, out value)
                ? value as IDictionary<string, object>
                : null;
        }

        internal static object[] Array(IDictionary<string, object> document, string name)
        {
            object value;
            return document != null && document.TryGetValue(name, out value) ? value as object[] : null;
        }
    }

    // The engine's clean-up records may only be changed by Administrators or SYSTEM: a program running as the user must
    // not be able to rewrite what decides which backups are removed. A port of secret_store.admin_only_writable_problem
    // with owner_limited_by_owner_rights: inherited entries count, deny entries and entries that apply only to children
    // are skipped, and an owner other than Administrators or SYSTEM is accepted only when an OWNER RIGHTS entry applies
    // to the object itself (Windows then gives the owner only that entry's rights).
    internal static class RetentionAcl
    {
        private const string SystemSid = "S-1-5-18";
        private const string AdministratorsSid = "S-1-5-32-544";
        private const string OwnerRightsSid = "S-1-3-4";
        // Write or append data, write extended attributes, delete a child, write attributes, delete, change the access
        // list or the owner, maximum allowed, generic all and generic write.
        private const int WriteRights = 0x00000002 | 0x00000004 | 0x00000010 | 0x00000040 | 0x00000100 |
            0x00010000 | 0x00040000 | 0x00080000 | 0x02000000 | 0x10000000 | 0x40000000;

        internal static bool AdminOnlyWritable(FileSystemSecurity security)
        {
            if (security == null)
            {
                return false;
            }
            try
            {
                return AdminOnlyWritable(security.GetSecurityDescriptorSddlForm(
                    AccessControlSections.Owner | AccessControlSections.Access));
            }
            catch
            {
                return false;
            }
        }

        internal static bool AdminOnlyWritable(string sddl)
        {
            try
            {
                RawSecurityDescriptor descriptor = new RawSecurityDescriptor(sddl);
                RawAcl acl = descriptor.DiscretionaryAcl;
                if (acl == null || acl.Count == 0 ||
                    (descriptor.ControlFlags & ControlFlags.DiscretionaryAclPresent) == 0)
                {
                    return false;
                }
                bool ownerRightsEntry = false;
                foreach (GenericAce ace in acl)
                {
                    if ((ace.AceFlags & AceFlags.InheritOnly) != 0 || ace.AceType == AceType.AccessDenied)
                    {
                        continue;
                    }
                    CommonAce common = ace as CommonAce;
                    if (ace.AceType != AceType.AccessAllowed || common == null)
                    {
                        return false;
                    }
                    string sid = common.SecurityIdentifier.Value;
                    if (sid == SystemSid || sid == AdministratorsSid)
                    {
                        continue;
                    }
                    if ((common.AccessMask & WriteRights) != 0)
                    {
                        return false;
                    }
                    if (sid == OwnerRightsSid)
                    {
                        ownerRightsEntry = true;
                    }
                }
                SecurityIdentifier owner = descriptor.Owner;
                if (owner == null)
                {
                    return false;
                }
                return owner.Value == SystemSid || owner.Value == AdministratorsSid || ownerRightsEntry;
            }
            catch
            {
                return false;
            }
        }
    }

    // One protected record as it was read: whether it is there, its bytes and SHA-256, or why it could not be trusted.
    internal sealed class RetentionFileRead
    {
        internal bool Exists;
        internal byte[] Bytes;
        internal string Sha256;
        internal string Problem;
        internal long Length;
        internal DateTime LastWriteUtc;
    }

    internal static class RetentionFiles
    {
        // For the disposable regression suites only: files below the current user's temporary folder carry the user's own
        // permissions, so the admin-only check is skipped for them. A real state folder is never below that folder.
        private static bool trustTemporaryFolder;

        internal static void TrustTemporaryFolderForTesting(bool trust)
        {
            trustTemporaryFolder = trust;
        }

        internal static bool IsTrustedTestPath(string path)
        {
            if (!trustTemporaryFolder || string.IsNullOrEmpty(path))
            {
                return false;
            }
            string temporary = Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\');
            string full = Path.GetFullPath(path);
            return full.StartsWith(temporary + "\\", StringComparison.OrdinalIgnoreCase);
        }

        internal static byte[] ReadAllBounded(string path, int limit)
        {
            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                return ReadStream(stream, limit);
            }
        }

        private static byte[] ReadStream(FileStream stream, int limit)
        {
            if (stream.Length <= 0 || stream.Length > limit)
            {
                throw new InvalidDataException("The file has an invalid size.");
            }
            byte[] bytes = new byte[(int)stream.Length];
            int offset = 0;
            while (offset < bytes.Length)
            {
                int read = stream.Read(bytes, offset, bytes.Length - offset);
                if (read <= 0)
                {
                    throw new InvalidDataException("The file ended early.");
                }
                offset += read;
            }
            return bytes;
        }

        // A record in the protected state folder: a regular file (no link), within its limit, that only Administrators
        // or SYSTEM can change. Never throws.
        internal static RetentionFileRead ReadProtected(string path, int limit)
        {
            RetentionFileRead read = new RetentionFileRead();
            try
            {
                FileInfo file = new FileInfo(path);
                if (!file.Exists)
                {
                    return read;
                }
                read.Exists = true;
                read.Length = file.Length;
                read.LastWriteUtc = file.LastWriteTimeUtc;
                if ((file.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    read.Problem = "unsafe";
                    return read;
                }
                if (file.Length <= 0 || file.Length > limit)
                {
                    read.Problem = "size";
                    return read;
                }
                using (FileStream stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                {
                    if (!IsTrustedTestPath(path) && !RetentionAcl.AdminOnlyWritable(stream.GetAccessControl()))
                    {
                        read.Problem = "unprotected";
                        return read;
                    }
                    read.Bytes = ReadStream(stream, limit);
                }
                read.Sha256 = RetentionDigests.Sha256(read.Bytes);
                return read;
            }
            catch (Exception)
            {
                read.Problem = "unreadable";
                read.Bytes = null;
                read.Sha256 = null;
                return read;
            }
        }
    }

    internal static class RetentionDigests
    {
        internal static string Sha256(byte[] bytes)
        {
            using (SHA256 algorithm = SHA256.Create())
            {
                return LowerHex(algorithm.ComputeHash(bytes));
            }
        }

        internal static string Sha256Lines(IList<string> lines)
        {
            return Sha256(new UTF8Encoding(false).GetBytes(string.Join("\n", lines)));
        }

        internal static string LowerHex(byte[] bytes)
        {
            StringBuilder text = new StringBuilder(bytes.Length * 2);
            foreach (byte item in bytes)
            {
                text.Append(item.ToString("x2", CultureInfo.InvariantCulture));
            }
            return text.ToString();
        }

        internal static bool IsLowerHex64(string value)
        {
            if (value == null || value.Length != 64)
            {
                return false;
            }
            foreach (char character in value)
            {
                if ((character < '0' || character > '9') && (character < 'a' || character > 'f'))
                {
                    return false;
                }
            }
            return true;
        }

        // retention.install_identity: every file the installer placed, by name and SHA-256, and the version, except the
        // backup configuration. Null when the manifest cannot be read.
        internal static string InstallIdentity(byte[] manifestBytes)
        {
            try
            {
                IDictionary<string, object> manifest = RetentionJson.ParseObject(manifestBytes, RetentionNames.MaximumManifestBytes);
                object[] files = RetentionJson.Array(manifest, "files");
                if (files == null)
                {
                    return null;
                }
                List<KeyValuePair<string, string>> entries = new List<KeyValuePair<string, string>>();
                foreach (object item in files)
                {
                    IDictionary<string, object> record = item as IDictionary<string, object>;
                    string relative = RetentionJson.String(record, "relative_path");
                    string digest = RetentionJson.String(record, "sha256");
                    if (record == null || relative == null || digest == null || digest.Length != 64 ||
                        !IsLowerHex64(digest.ToLowerInvariant()))
                    {
                        return null;
                    }
                    relative = relative.Replace('/', '\\').ToLowerInvariant();
                    if (relative == "backup-config.json")
                    {
                        continue;
                    }
                    entries.Add(new KeyValuePair<string, string>(relative, digest.ToLowerInvariant()));
                }
                entries.Sort(delegate(KeyValuePair<string, string> left, KeyValuePair<string, string> right)
                {
                    int byName = string.CompareOrdinal(left.Key, right.Key);
                    return byName != 0 ? byName : string.CompareOrdinal(left.Value, right.Value);
                });
                List<string> lines = new List<string>();
                lines.Add(RetentionNames.InstallDomain);
                lines.Add(RetentionJson.String(manifest, "version") ?? string.Empty);
                foreach (KeyValuePair<string, string> entry in entries)
                {
                    lines.Add(entry.Key + "\t" + entry.Value);
                }
                return Sha256Lines(lines);
            }
            catch
            {
                return null;
            }
        }

        internal static string PolicyDigest(
            string schema, string planId, string repositoryId, string installId, int daily, int weekly, int monthly)
        {
            return Sha256Lines(new[]
            {
                schema, planId, repositoryId, installId,
                daily.ToString(CultureInfo.InvariantCulture),
                weekly.ToString(CultureInfo.InvariantCulture),
                monthly.ToString(CultureInfo.InvariantCulture),
                RetentionNames.GroupBy
            });
        }

        internal static string SetDigest(string domain, IEnumerable<string> ids)
        {
            List<string> sorted = new List<string>(ids);
            sorted.Sort(string.CompareOrdinal);
            List<string> lines = new List<string>();
            lines.Add(domain);
            lines.AddRange(sorted);
            return Sha256Lines(lines);
        }

        // The request digest Manage-Retention.ps1 checks: every field of the request, the empty ones too, in a fixed order.
        internal static string RequestDigest(string domain, RetentionRequest request)
        {
            return Sha256Lines(new[]
            {
                domain,
                request.UserSid ?? string.Empty,
                request.Action ?? string.Empty,
                request.ConfigHash ?? string.Empty,
                request.PlanId ?? string.Empty,
                request.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                request.Enabled ?? string.Empty,
                request.KeepDaily ?? string.Empty,
                request.KeepWeekly ?? string.Empty,
                request.KeepMonthly ?? string.Empty,
                request.PreviewSha256 ?? string.Empty,
                request.RemoveSetSha256 ?? string.Empty,
                request.RemoveCount ?? string.Empty,
                request.ConfirmEarlierChanges ?? string.Empty,
                request.Nonce ?? string.Empty
            });
        }
    }

    // One backup in the list of what would go or what stays.
    internal sealed class RetentionItemView
    {
        internal string Id;
        internal string Time;
        internal long? Files;
        internal List<string> Reasons = new List<string>();
    }

    // An earlier checked backup the person is asked to look over before old backups go, and why. "hold": it changed far
    // more files than usual and nobody confirmed it. "not_compared": it could not be compared with the backup before it
    // (the first backup, or the first after a folder, exclusion or location change). "unknown": its record does not say,
    // as an older backup service's does not. Only "hold" is worded as unusual changes.
    internal sealed class RetentionEarlierChange
    {
        internal string FinishedUtc;
        internal string Kind;

        internal static string KindOf(string value)
        {
            return value == "hold" || value == "not_compared" ? value : "unknown";
        }
    }

    internal sealed class RetentionHistoryEntryView
    {
        internal string Nonce;
        internal string Outcome;
        internal string FinishedUtc;
        internal long ConfirmedCount;
        internal long RemovedCount;
        internal bool PruneCompleted;
        internal bool CheckCompleted;
        internal long? FreeBytesBefore;
        internal long? FreeBytesAfter;
    }

    // Everything the dashboard knows about clean-up, from one read of the engine's records.
    internal sealed class RetentionView
    {
        // "off", "on" or "unknown" (the setting could not be trusted).
        internal string Mode = "unknown";
        internal string Problem = string.Empty;
        // The local NTFS backup location is the only one clean-up supports for now.
        internal bool GoogleDrive;
        internal int KeepDaily = RetentionNames.DefaultDaily;
        internal int KeepWeekly = RetentionNames.DefaultWeekly;
        internal int KeepMonthly = RetentionNames.DefaultMonthly;
        // A setting that was on and no longer belongs to the installed program files: an update or reinstall turned it off.
        internal bool ResetByReinstall;
        internal string PolicySha256;
        internal string EvidenceSha256;
        internal string RepositoryId;
        // "none", "ready", "blocked", "error" or "stale".
        internal string PreviewStatus = "none";
        internal string PreviewSha256;
        internal string BlockedReason = string.Empty;
        internal string ErrorCode = string.Empty;
        internal string CreatedUtc = string.Empty;
        internal string RemoveSetSha256;
        internal int RemoveCount;
        internal int KeepCount;
        internal List<RetentionItemView> Remove = new List<RetentionItemView>();
        internal List<RetentionItemView> Keep = new List<RetentionItemView>();
        internal List<RetentionEarlierChange> EarlierChanges = new List<RetentionEarlierChange>();
        internal bool EarlierChangesUnknown;
        internal bool NeedsFilesConfirmed;
        internal bool PrunePending;
        internal string FutureDatedUtc = string.Empty;
        internal RetentionHistoryEntryView LastRun;
        // What the read was keyed on, so an unchanged set of files is not parsed again.
        internal string Stamp = string.Empty;
    }

    internal static class RetentionStateReader
    {
        // Never throws: a record that cannot be trusted makes the view "unknown" or its list an error, and nothing is
        // offered that could remove a backup.
        internal static RetentionView Read(
            EngineProfile profile,
            string stateDirectory,
            string installRoot,
            string planId,
            long configGeneration,
            RetentionView previous)
        {
            RetentionView view = new RetentionView();
            try
            {
                string stamp = StampOf(stateDirectory, installRoot) + "|" + planId + "|" +
                    configGeneration.ToString(CultureInfo.InvariantCulture);
                if (previous != null && string.Equals(previous.Stamp, stamp, StringComparison.Ordinal))
                {
                    return previous;
                }
                view.Stamp = stamp;
                DirectoryInfo state = new DirectoryInfo(stateDirectory);
                if (!state.Exists || (state.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    view.Problem = "state_unavailable";
                    return view;
                }
                // Each record may be a file the user owns when OWNER RIGHTS limits the owner to reading, which is only safe
                // while nobody but Administrators and SYSTEM can create files in the folder: so the folder is checked too.
                if (!RetentionFiles.IsTrustedTestPath(stateDirectory) && !RetentionAcl.AdminOnlyWritable(
                    state.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access)))
                {
                    view.Problem = "state_unprotected";
                    return view;
                }
                ReadConfiguration(Path.Combine(installRoot, EngineProfile.ConfigurationFileName), view);

                RetentionFileRead evidence = RetentionFiles.ReadProtected(
                    Path.Combine(stateDirectory, RetentionNames.EvidenceFileName), RetentionNames.MaximumEvidenceBytes);
                if (evidence.Bytes != null)
                {
                    view.EvidenceSha256 = evidence.Sha256;
                    try
                    {
                        string repository = RetentionJson.String(
                            RetentionJson.ParseObject(evidence.Bytes, RetentionNames.MaximumEvidenceBytes), "repository_id");
                        view.RepositoryId = RetentionDigests.IsLowerHex64(repository) ? repository : null;
                    }
                    catch
                    {
                        view.RepositoryId = null;
                    }
                }

                RetentionFileRead policyRead = RetentionFiles.ReadProtected(
                    Path.Combine(stateDirectory, RetentionNames.PolicyFileName), RetentionNames.MaximumPolicyBytes);
                if (policyRead.Exists && policyRead.Bytes == null)
                {
                    view.Mode = "unknown";
                    view.Problem = "policy_" + policyRead.Problem;
                    return view;
                }
                IDictionary<string, object> policy = null;
                if (policyRead.Bytes != null)
                {
                    try
                    {
                        policy = RetentionJson.ParseObject(policyRead.Bytes, RetentionNames.MaximumPolicyBytes);
                    }
                    catch
                    {
                        view.Mode = "unknown";
                        view.Problem = "policy_unreadable";
                        return view;
                    }
                }
                ApplyPolicy(profile, policy, installRoot, planId, view);
                if (view.Mode != "on")
                {
                    ReadHistory(profile, stateDirectory, planId, view);
                    return view;
                }
                ReadPreview(profile, stateDirectory, planId, configGeneration, view);
                ReadHistory(profile, stateDirectory, planId, view);
                return view;
            }
            catch (Exception)
            {
                view.Mode = "unknown";
                view.Problem = "unreadable";
                return view;
            }
        }

        private static string StampOf(string stateDirectory, string installRoot)
        {
            StringBuilder stamp = new StringBuilder();
            foreach (string path in new[]
            {
                Path.Combine(stateDirectory, RetentionNames.PolicyFileName),
                Path.Combine(stateDirectory, RetentionNames.PreviewFileName),
                Path.Combine(stateDirectory, RetentionNames.HistoryFileName),
                Path.Combine(stateDirectory, RetentionNames.EvidenceFileName),
                Path.Combine(installRoot, "runtime-manifest.json"),
                Path.Combine(installRoot, EngineProfile.ConfigurationFileName)
            })
            {
                FileInfo file = new FileInfo(path);
                stamp.Append(file.Exists
                    ? file.Length.ToString(CultureInfo.InvariantCulture) + ":" +
                        file.LastWriteTimeUtc.Ticks.ToString(CultureInfo.InvariantCulture)
                    : "-");
                stamp.Append(';');
            }
            return stamp.ToString();
        }

        private static void ReadConfiguration(string configurationPath, RetentionView view)
        {
            try
            {
                FileInfo file = new FileInfo(configurationPath);
                if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    return;
                }
                IDictionary<string, object> configuration = RetentionJson.ParseObject(
                    RetentionFiles.ReadAllBounded(configurationPath, RetentionNames.MaximumConfigurationBytes),
                    RetentionNames.MaximumConfigurationBytes);
                string mode = RetentionJson.String(configuration, "repository_storage_mode");
                view.GoogleDrive = mode != null && !string.Equals(mode, RetentionNames.LocalNtfsMode, StringComparison.Ordinal);
            }
            catch
            {
                // The plan itself reports a configuration it cannot read; clean-up stays as the engine decides.
            }
        }

        internal static string InstallIdentityOf(string installRoot)
        {
            try
            {
                string path = Path.Combine(installRoot, "runtime-manifest.json");
                FileInfo file = new FileInfo(path);
                if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    return null;
                }
                return RetentionDigests.InstallIdentity(RetentionFiles.ReadAllBounded(path, RetentionNames.MaximumManifestBytes));
            }
            catch
            {
                return null;
            }
        }

        // retention.policy_problem, from the dashboard's side.
        private static void ApplyPolicy(
            EngineProfile profile,
            IDictionary<string, object> policy,
            string installRoot,
            string planId,
            RetentionView view)
        {
            view.Mode = "off";
            if (policy == null)
            {
                return;
            }
            long? daily = RetentionJson.Integer(policy, "keep_daily");
            long? weekly = RetentionJson.Integer(policy, "keep_weekly");
            long? monthly = RetentionJson.Integer(policy, "keep_monthly");
            bool countsValid = daily.HasValue && weekly.HasValue && monthly.HasValue &&
                RetentionNames.CountsInRange((int)Math.Min(daily.Value, int.MaxValue),
                    (int)Math.Min(weekly.Value, int.MaxValue), (int)Math.Min(monthly.Value, int.MaxValue));
            if (countsValid)
            {
                // The counts used before are offered again when it is turned back on.
                view.KeepDaily = (int)daily.Value;
                view.KeepWeekly = (int)weekly.Value;
                view.KeepMonthly = (int)monthly.Value;
            }
            if (!string.Equals(RetentionJson.String(policy, "schema"), profile.RetentionPolicySchema, StringComparison.Ordinal) ||
                RetentionJson.Integer(policy, "schema_version") != 1 ||
                RetentionJson.Boolean(policy, "enabled") != true || !countsValid ||
                !string.Equals(RetentionJson.String(policy, "group_by"), RetentionNames.GroupBy, StringComparison.Ordinal) ||
                !string.Equals(RetentionJson.String(policy, "plan_id"), planId, StringComparison.Ordinal))
            {
                return;
            }
            string repositoryId = RetentionJson.String(policy, "repository_id");
            string installId = RetentionJson.String(policy, "install_id");
            string digest = RetentionJson.String(policy, "policy_sha256");
            if (!RetentionDigests.IsLowerHex64(repositoryId) ||
                (view.RepositoryId != null && !string.Equals(repositoryId, view.RepositoryId, StringComparison.Ordinal)))
            {
                return;
            }
            string currentInstall = InstallIdentityOf(installRoot);
            if (currentInstall == null)
            {
                view.Mode = "unknown";
                view.Problem = "install_unreadable";
                return;
            }
            if (!string.Equals(installId, currentInstall, StringComparison.Ordinal))
            {
                view.ResetByReinstall = true;
                return;
            }
            string expected = RetentionDigests.PolicyDigest(profile.RetentionPolicySchema, planId, repositoryId, installId,
                view.KeepDaily, view.KeepWeekly, view.KeepMonthly);
            if (!string.Equals(digest, expected, StringComparison.Ordinal))
            {
                return;
            }
            view.Mode = "on";
            view.PolicySha256 = digest;
        }

        private static void ReadPreview(
            EngineProfile profile,
            string stateDirectory,
            string planId,
            long configGeneration,
            RetentionView view)
        {
            RetentionFileRead read = RetentionFiles.ReadProtected(
                Path.Combine(stateDirectory, RetentionNames.PreviewFileName), RetentionNames.MaximumPreviewBytes);
            if (!read.Exists)
            {
                view.PreviewStatus = "none";
                return;
            }
            if (read.Bytes == null)
            {
                view.PreviewStatus = "error";
                view.ErrorCode = read.Problem == "unprotected" ? "records_unprotected" : "preview_unreadable";
                return;
            }
            IDictionary<string, object> preview;
            try
            {
                preview = RetentionJson.ParseObject(read.Bytes, RetentionNames.MaximumPreviewBytes);
            }
            catch
            {
                view.PreviewStatus = "error";
                view.ErrorCode = "preview_unreadable";
                return;
            }
            view.PreviewSha256 = read.Sha256;
            string state = RetentionJson.String(preview, "state");
            IDictionary<string, object> evidence = RetentionJson.Object(preview, "evidence");
            IDictionary<string, object> previewPolicy = RetentionJson.Object(preview, "policy");
            if (!string.Equals(RetentionJson.String(preview, "schema"), profile.RetentionPreviewSchema, StringComparison.Ordinal) ||
                RetentionJson.Integer(preview, "schema_version") != 1)
            {
                view.PreviewStatus = "error";
                view.ErrorCode = "preview_unreadable";
                return;
            }
            if (state == "disabled")
            {
                view.PreviewStatus = "none";
                return;
            }
            view.CreatedUtc = RetentionJson.String(preview, "created_utc") ?? string.Empty;
            // A list made before the latest backup, for another plan or setting, says nothing about what is there now.
            if (!string.Equals(RetentionJson.String(preview, "plan_id"), planId, StringComparison.Ordinal) ||
                RetentionJson.Integer(preview, "config_generation") != configGeneration ||
                !string.Equals(RetentionJson.String(evidence, "last_success_sha256"), view.EvidenceSha256, StringComparison.Ordinal) ||
                !string.Equals(RetentionJson.String(previewPolicy, "policy_sha256"), view.PolicySha256, StringComparison.Ordinal))
            {
                // A blocked list made with no checked backup at all stays as it is until there is one.
                if (!(state == "blocked" && view.EvidenceSha256 == null && RetentionJson.String(evidence, "last_success_sha256") == null))
                {
                    view.PreviewStatus = "stale";
                    return;
                }
            }
            if (state == "blocked")
            {
                string reason = RetentionJson.String(preview, "blocked_reason");
                view.PreviewStatus = "blocked";
                view.BlockedReason = RetentionNames.IsOneOf(reason, RetentionNames.GateCodes) ? reason : "policy_inactive";
                view.FutureDatedUtc = RetentionJson.String(preview, "future_dated_utc") ?? string.Empty;
                return;
            }
            if (state != "ready")
            {
                view.PreviewStatus = "error";
                string code = RetentionJson.String(preview, "error_code");
                view.ErrorCode = string.IsNullOrEmpty(code) || code.Length > 64 ? "failed" : code;
                return;
            }
            object[] remove = RetentionJson.Array(preview, "remove");
            object[] keep = RetentionJson.Array(preview, "keep");
            long? removeCount = RetentionJson.Integer(preview, "remove_count");
            long? keepCount = RetentionJson.Integer(preview, "keep_count");
            string removeSet = RetentionJson.String(preview, "remove_set_sha256");
            if (remove == null || keep == null || !removeCount.HasValue || !keepCount.HasValue ||
                removeCount.Value != remove.Length || keepCount.Value != keep.Length ||
                remove.Length > RetentionNames.MaximumItems || keep.Length > RetentionNames.MaximumItems ||
                !RetentionDigests.IsLowerHex64(removeSet))
            {
                view.PreviewStatus = "error";
                view.ErrorCode = "preview_unreadable";
                return;
            }
            List<string> removeIds = new List<string>();
            foreach (object item in remove)
            {
                RetentionItemView parsed = ParseItem(item);
                if (parsed == null)
                {
                    view.PreviewStatus = "error";
                    view.ErrorCode = "preview_unreadable";
                    return;
                }
                view.Remove.Add(parsed);
                removeIds.Add(parsed.Id);
            }
            foreach (object item in keep)
            {
                RetentionItemView parsed = ParseItem(item);
                if (parsed == null)
                {
                    view.PreviewStatus = "error";
                    view.ErrorCode = "preview_unreadable";
                    return;
                }
                view.Keep.Add(parsed);
            }
            // The list shown is the list that is confirmed: its digest must be the one the engine binds the removal to.
            if (!string.Equals(RetentionDigests.SetDigest(RetentionNames.RemoveSetDomain, removeIds), removeSet, StringComparison.Ordinal))
            {
                view.PreviewStatus = "error";
                view.ErrorCode = "preview_unreadable";
                view.Remove.Clear();
                view.Keep.Clear();
                return;
            }
            view.RemoveSetSha256 = removeSet;
            view.RemoveCount = remove.Length;
            view.KeepCount = keep.Length;
            object[] changes = RetentionJson.Array(preview, "earlier_changes");
            if (changes != null)
            {
                foreach (object item in changes)
                {
                    IDictionary<string, object> entry = item as IDictionary<string, object>;
                    RetentionEarlierChange change = new RetentionEarlierChange();
                    change.FinishedUtc = RetentionJson.String(entry, "finished_utc") ?? string.Empty;
                    // A kind this dashboard does not know is read as "unknown": the person is still asked to check their
                    // files, and nothing claims a change it cannot vouch for.
                    change.Kind = RetentionEarlierChange.KindOf(RetentionJson.String(entry, "kind"));
                    view.EarlierChanges.Add(change);
                }
            }
            view.EarlierChangesUnknown = RetentionJson.Boolean(preview, "earlier_changes_unknown") != false;
            // Anything but an explicit false asks the person to check their files.
            view.NeedsFilesConfirmed = RetentionJson.Boolean(preview, "needs_files_confirmed") != false;
            view.PrunePending = RetentionJson.Boolean(preview, "prune_pending") == true;
            view.PreviewStatus = "ready";
        }

        private static RetentionItemView ParseItem(object value)
        {
            IDictionary<string, object> item = value as IDictionary<string, object>;
            string id = RetentionJson.String(item, "id");
            string time = RetentionJson.String(item, "time");
            if (item == null || !RetentionDigests.IsLowerHex64(id) || string.IsNullOrEmpty(time) || time.Length > 64)
            {
                return null;
            }
            RetentionItemView view = new RetentionItemView();
            view.Id = id;
            view.Time = time;
            view.Files = RetentionJson.Integer(item, "files");
            object[] reasons = RetentionJson.Array(item, "reasons");
            if (reasons != null)
            {
                foreach (object reason in reasons)
                {
                    string text = reason as string;
                    if (text == "latest" || text == "day" || text == "week" || text == "month" ||
                        text == "checked" || text == "before_change")
                    {
                        view.Reasons.Add(text);
                    }
                }
            }
            return view;
        }

        private static void ReadHistory(EngineProfile profile, string stateDirectory, string planId, RetentionView view)
        {
            RetentionFileRead read = RetentionFiles.ReadProtected(
                Path.Combine(stateDirectory, RetentionNames.HistoryFileName), RetentionNames.MaximumHistoryBytes);
            if (read.Bytes == null)
            {
                return;
            }
            try
            {
                IDictionary<string, object> history = RetentionJson.ParseObject(read.Bytes, RetentionNames.MaximumHistoryBytes);
                object[] entries = RetentionJson.Array(history, "entries");
                if (!string.Equals(RetentionJson.String(history, "schema"), profile.RetentionHistorySchema, StringComparison.Ordinal) ||
                    !string.Equals(RetentionJson.String(history, "plan_id"), planId, StringComparison.Ordinal) ||
                    entries == null || entries.Length == 0)
                {
                    return;
                }
                view.LastRun = ParseHistoryEntry(entries[entries.Length - 1] as IDictionary<string, object>);
            }
            catch
            {
                view.LastRun = null;
            }
        }

        internal static RetentionHistoryEntryView ParseHistoryEntry(IDictionary<string, object> entry)
        {
            if (entry == null)
            {
                return null;
            }
            string outcome = RetentionJson.String(entry, "outcome");
            if (!RetentionNames.IsOneOf(outcome, new[]
                {
                    "removed", "nothing_to_remove", "partial", "space_pending", "check_failed", "failed"
                }))
            {
                return null;
            }
            RetentionHistoryEntryView view = new RetentionHistoryEntryView();
            view.Nonce = RetentionJson.String(entry, "request_nonce");
            view.Outcome = outcome;
            view.FinishedUtc = RetentionJson.String(entry, "finished_utc") ?? string.Empty;
            view.ConfirmedCount = RetentionJson.Integer(entry, "confirmed_count") ?? 0;
            view.RemovedCount = RetentionJson.Integer(entry, "removed_count") ?? 0;
            view.PruneCompleted = RetentionJson.Boolean(entry, "prune_completed") == true;
            view.CheckCompleted = RetentionJson.Boolean(entry, "check_completed") == true;
            view.FreeBytesBefore = RetentionJson.Integer(entry, "free_bytes_before");
            view.FreeBytesAfter = RetentionJson.Integer(entry, "free_bytes_after");
            return view;
        }

        // The newest recorded clean-up, read fresh: the launcher's independent check of what an apply says it did.
        internal static RetentionHistoryEntryView ReadNewestHistoryEntry(EngineProfile profile, string stateDirectory, string planId)
        {
            RetentionView view = new RetentionView();
            ReadHistory(profile, stateDirectory, planId, view);
            return view.LastRun;
        }
    }

    // What one launch asks the manager for. The manager reads the same values from its elevated command line.
    internal sealed class RetentionRequest
    {
        internal string Action;
        internal string Enabled = string.Empty;
        internal string KeepDaily = string.Empty;
        internal string KeepWeekly = string.Empty;
        internal string KeepMonthly = string.Empty;
        internal string PreviewSha256 = string.Empty;
        internal string RemoveSetSha256 = string.Empty;
        internal string RemoveCount = string.Empty;
        internal string ConfirmEarlierChanges = string.Empty;
        internal string Nonce;
        internal string Digest;
        internal string UserSid;
        internal string ConfigHash;
        internal string PlanId;
        internal long ConfigGeneration;
        internal string ResultPath;
    }

    internal sealed class RetentionProgress
    {
        internal string Stage;
        internal long? Count;
        internal double? Percent;
    }

    internal enum RetentionLaunchKind
    {
        Finished,
        Cancelled,
        StillRunning,
        Failed,
        Unconfirmed
    }

    // How one request ended, after the result was validated and checked against the records.
    internal sealed class RetentionLaunchResult
    {
        internal RetentionLaunchKind Kind;
        internal string State = string.Empty;
        internal string RefusalCode = string.Empty;
        internal int ExitCode;
        internal long RemovedCount;
        internal bool PruneCompleted;
        internal bool CheckCompleted;
        internal bool RemovalUnverified;
        internal string PreviewSha256;
        internal string Error = string.Empty;
    }

    // Starts the manager. Production asks Windows (runas, which shows the approval prompt and throws a Win32Exception
    // 1223 when it is declined); the regression suite passes a stand-in.
    internal delegate Process RetentionManagerLaunch(ProcessStartInfo start, RetentionRequest request);

    internal static class RetentionManagerLauncher
    {
        private const int ListingTimeoutMilliseconds = 10 * 60 * 1000;
        private const int ProgressPollMilliseconds = 500;

        internal static RetentionManagerLaunch Launch = DefaultLaunch;

        private static Process DefaultLaunch(ProcessStartInfo start, RetentionRequest request)
        {
            return Process.Start(start);
        }

        internal static RetentionRequest CreateRequest(
            EngineProfile profile,
            string action,
            string userSid,
            string configHash,
            string planId,
            long configGeneration)
        {
            RetentionRequest request = new RetentionRequest();
            request.Action = action;
            request.UserSid = userSid;
            request.ConfigHash = configHash;
            request.PlanId = planId;
            request.ConfigGeneration = configGeneration;
            request.Nonce = ElevatedRequestSecurity.CreateNonce();
            request.ResultPath = Path.Combine(
                profile.StateResultDirectory(RetentionNames.ResultDirectoryName), request.Nonce + ".json");
            return request;
        }

        internal static void Seal(EngineProfile profile, RetentionRequest request)
        {
            request.Digest = RetentionDigests.RequestDigest(profile.RetentionRequestDomain, request);
        }

        // The manager's command line: only the arguments the action takes, since Windows PowerShell's -File binder can
        // drop an empty one. The manager and its digest treat a missing argument as an empty string.
        internal static List<string> BuildArguments(RetentionRequest request, string managerPath)
        {
            List<string> arguments = new List<string>
            {
                "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                "-File", managerPath, "-Action", request.Action
            };
            AddIfPresent(arguments, "-Enabled", request.Enabled);
            AddIfPresent(arguments, "-KeepDaily", request.KeepDaily);
            AddIfPresent(arguments, "-KeepWeekly", request.KeepWeekly);
            AddIfPresent(arguments, "-KeepMonthly", request.KeepMonthly);
            AddIfPresent(arguments, "-ExpectedPreviewSha256", request.PreviewSha256);
            AddIfPresent(arguments, "-ExpectedRemoveSetSha256", request.RemoveSetSha256);
            AddIfPresent(arguments, "-ExpectedRemoveCount", request.RemoveCount);
            AddIfPresent(arguments, "-ConfirmEarlierChanges", request.ConfirmEarlierChanges);
            arguments.AddRange(new[]
            {
                "-ExpectedUserSid", request.UserSid,
                "-ExpectedConfigSha256", request.ConfigHash,
                "-ExpectedPlanId", request.PlanId,
                "-ExpectedConfigGeneration", request.ConfigGeneration.ToString(CultureInfo.InvariantCulture),
                "-ResultPath", request.ResultPath,
                "-RequestNonce", request.Nonce,
                "-RequestDigest", request.Digest
            });
            return arguments;
        }

        private static void AddIfPresent(List<string> arguments, string name, string value)
        {
            if (!string.IsNullOrEmpty(value))
            {
                arguments.Add(name);
                arguments.Add(value);
            }
        }

        internal static RetentionLaunchResult Run(
            EngineProfile profile,
            RetentionRequest request,
            Action onElevatedProcessStarted,
            Action<RetentionProgress> onProgress)
        {
            RetentionLaunchResult result = new RetentionLaunchResult();
            try
            {
                string installRoot = profile.InstallRoot();
                string managerPath = profile.ManagerPath(profile.RetentionManagerFileName);
                FileInfo manager = new FileInfo(managerPath);
                if (!Directory.Exists(installRoot) ||
                    (File.GetAttributes(installRoot) & FileAttributes.ReparsePoint) != 0 ||
                    !manager.Exists || (manager.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    !string.Equals(Path.GetFullPath(manager.DirectoryName).TrimEnd('\\'),
                        Path.GetFullPath(installRoot).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                {
                    result.Kind = RetentionLaunchKind.Failed;
                    result.Error = "The clean-up step of the backup service is missing. " + profile.ReinstallAdvice();
                    return result;
                }
                string powerShell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "WindowsPowerShell", "v1.0", "powershell.exe");
                if (File.Exists(request.ResultPath) || Directory.Exists(request.ResultPath))
                {
                    result.Kind = RetentionLaunchKind.Failed;
                    result.Error = "Rewindle couldn't prepare the request. Try again.";
                    return result;
                }
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = powerShell;
                start.Arguments = ElevatedRequestSecurity.BuildArgumentString(BuildArguments(request, managerPath));
                start.WorkingDirectory = installRoot;
                start.UseShellExecute = true;
                start.Verb = "runas";
                start.WindowStyle = ProcessWindowStyle.Hidden;
                start.ErrorDialog = false;

                int exitCode;
                using (Process process = Launch(start, request))
                {
                    if (process == null)
                    {
                        result.Kind = RetentionLaunchKind.Failed;
                        result.Error = "Windows did not start the clean-up step.";
                        return result;
                    }
                    if (onElevatedProcessStarted != null)
                    {
                        try { onElevatedProcessStarted(); }
                        catch { }
                    }
                    Stopwatch waited = Stopwatch.StartNew();
                    while (!process.WaitForExit(ProgressPollMilliseconds))
                    {
                        if (onProgress != null)
                        {
                            RetentionProgress progress = ReadProgress(request);
                            if (progress != null)
                            {
                                try { onProgress(progress); }
                                catch { }
                            }
                        }
                        // Listing what would go has a time limit; removing never does, since stopping it half-way is worse
                        // than waiting. Nothing is stopped either way: the page says it finishes on its own.
                        if (request.Action != "apply" && waited.ElapsedMilliseconds > ListingTimeoutMilliseconds)
                        {
                            result.Kind = RetentionLaunchKind.StillRunning;
                            return result;
                        }
                    }
                    process.WaitForExit();
                    exitCode = process.ExitCode;
                }
                result.ExitCode = exitCode;
                return ReadResult(profile, request, exitCode, result);
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode == 1223)
                {
                    result.Kind = RetentionLaunchKind.Cancelled;
                    return result;
                }
                result.Kind = RetentionLaunchKind.Failed;
                result.Error = "Windows could not start the clean-up step.";
                return result;
            }
            catch (Exception)
            {
                result.Kind = RetentionLaunchKind.Unconfirmed;
                return result;
            }
        }

        private static RetentionProgress ReadProgress(RetentionRequest request)
        {
            try
            {
                string path = request.ResultPath + ".progress.json";
                FileInfo file = new FileInfo(path);
                if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    file.Length <= 0 || file.Length > RetentionNames.MaximumResultBytes)
                {
                    return null;
                }
                byte[] bytes;
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (!RetentionFiles.IsTrustedTestPath(path) &&
                        !ElevatedRequestSecurity.HasProtectedResultAcl(stream.GetAccessControl(), request.UserSid))
                    {
                        return null;
                    }
                    bytes = new byte[(int)Math.Min(stream.Length, RetentionNames.MaximumResultBytes)];
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        int read = stream.Read(bytes, offset, bytes.Length - offset);
                        if (read <= 0) return null;
                        offset += read;
                    }
                }
                IDictionary<string, object> document = RetentionJson.ParseObject(bytes, RetentionNames.MaximumResultBytes);
                if (!ElevatedRequestSecurity.FixedEquals(RetentionJson.String(document, "request_nonce"), request.Nonce) ||
                    !ElevatedRequestSecurity.FixedEquals(RetentionJson.String(document, "request_digest"), request.Digest))
                {
                    return null;
                }
                RetentionProgress progress = new RetentionProgress();
                progress.Stage = RetentionJson.String(document, "stage");
                progress.Count = RetentionJson.Integer(document, "count");
                long? percent = RetentionJson.Integer(document, "percent");
                progress.Percent = percent.HasValue ? (double?)Math.Max(0, Math.Min(100, percent.Value)) : null;
                return progress;
            }
            catch
            {
                return null;
            }
        }

        private static RetentionLaunchResult ReadResult(
            EngineProfile profile, RetentionRequest request, int exitCode, RetentionLaunchResult result)
        {
            for (int attempt = 0; attempt < 20 && !File.Exists(request.ResultPath); attempt++)
            {
                Thread.Sleep(25);
            }
            string json;
            try
            {
                string resultRoot = Path.GetDirectoryName(request.ResultPath);
                string stateRoot = Path.GetDirectoryName(resultRoot);
                FileInfo file = new FileInfo(request.ResultPath);
                if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    (File.GetAttributes(resultRoot) & FileAttributes.ReparsePoint) != 0 ||
                    (File.GetAttributes(stateRoot) & FileAttributes.ReparsePoint) != 0 ||
                    !string.Equals(Path.GetFileName(resultRoot), RetentionNames.ResultDirectoryName, StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(Path.GetFileName(request.ResultPath), request.Nonce + ".json", StringComparison.Ordinal))
                {
                    result.Kind = RetentionLaunchKind.Unconfirmed;
                    return result;
                }
                bool trusted = RetentionFiles.IsTrustedTestPath(request.ResultPath);
                if (!trusted && (!ElevatedRequestSecurity.HasProtectedResultAcl(stateRoot, request.UserSid, true) ||
                    !ElevatedRequestSecurity.HasProtectedResultAcl(resultRoot, request.UserSid, true)))
                {
                    result.Kind = RetentionLaunchKind.Unconfirmed;
                    return result;
                }
                using (FileStream stream = new FileStream(request.ResultPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    if ((!trusted && !ElevatedRequestSecurity.HasProtectedResultAcl(stream.GetAccessControl(), request.UserSid)) ||
                        stream.Length <= 0 || stream.Length > RetentionNames.MaximumResultBytes)
                    {
                        result.Kind = RetentionLaunchKind.Unconfirmed;
                        return result;
                    }
                    using (StreamReader reader = new StreamReader(stream, new UTF8Encoding(false, true), true))
                    {
                        json = reader.ReadToEnd();
                    }
                }
            }
            catch
            {
                result.Kind = RetentionLaunchKind.Unconfirmed;
                return result;
            }
            RetentionResultDocument document;
            string error;
            if (!TryValidateResultDocument(json, request, exitCode, out document, out error))
            {
                result.Kind = RetentionLaunchKind.Unconfirmed;
                return result;
            }
            result.State = document.State;
            result.RefusalCode = document.RefusalCode ?? string.Empty;
            result.RemovedCount = document.RemovedCount;
            result.PruneCompleted = document.PruneCompleted;
            result.CheckCompleted = document.CheckCompleted;
            result.RemovalUnverified = document.RemovalUnverified;
            result.PreviewSha256 = document.PreviewSha256;
            if (!ConfirmIndependently(profile, request, document))
            {
                result.Kind = RetentionLaunchKind.Unconfirmed;
                return result;
            }
            result.Kind = RetentionLaunchKind.Finished;
            return result;
        }

        // The result is only a claim: a fresh read of the records must agree with it before the page says it happened.
        private static bool ConfirmIndependently(EngineProfile profile, RetentionRequest request, RetentionResultDocument document)
        {
            string stateDirectory = Path.GetDirectoryName(Path.GetDirectoryName(request.ResultPath));
            if (document.State == "configured" || document.State == "disabled")
            {
                RetentionFileRead policyRead = RetentionFiles.ReadProtected(
                    Path.Combine(stateDirectory, RetentionNames.PolicyFileName), RetentionNames.MaximumPolicyBytes);
                if (policyRead.Bytes == null)
                {
                    return false;
                }
                IDictionary<string, object> policy = RetentionJson.ParseObject(policyRead.Bytes, RetentionNames.MaximumPolicyBytes);
                bool enabled = RetentionJson.Boolean(policy, "enabled") == true;
                if (enabled != (request.Enabled == "1"))
                {
                    return false;
                }
                if (enabled && (
                    !string.Equals(Convert.ToString(RetentionJson.Integer(policy, "keep_daily"), CultureInfo.InvariantCulture), request.KeepDaily, StringComparison.Ordinal) ||
                    !string.Equals(Convert.ToString(RetentionJson.Integer(policy, "keep_weekly"), CultureInfo.InvariantCulture), request.KeepWeekly, StringComparison.Ordinal) ||
                    !string.Equals(Convert.ToString(RetentionJson.Integer(policy, "keep_monthly"), CultureInfo.InvariantCulture), request.KeepMonthly, StringComparison.Ordinal)))
                {
                    return false;
                }
            }
            if (document.State == "configured" || document.State == "previewed" ||
                (request.Action == "apply" && document.HistoryRecorded))
            {
                RetentionFileRead previewRead = RetentionFiles.ReadProtected(
                    Path.Combine(stateDirectory, RetentionNames.PreviewFileName), RetentionNames.MaximumPreviewBytes);
                // A backup may have finished since and the list been made again; only a list that is still the one the
                // step wrote is compared.
                if (previewRead.Bytes == null ||
                    (document.PreviewSha256 != null && previewRead.Sha256 != document.PreviewSha256 &&
                        request.Action != "apply"))
                {
                    return false;
                }
            }
            if (request.Action == "apply" && document.HistoryRecorded)
            {
                RetentionHistoryEntryView entry = RetentionStateReader.ReadNewestHistoryEntry(profile, stateDirectory, request.PlanId);
                if (entry == null || !ElevatedRequestSecurity.FixedEquals(entry.Nonce, request.Nonce) ||
                    entry.RemovedCount != document.RemovedCount)
                {
                    return false;
                }
            }
            return true;
        }

        private static int ExpectedExitCode(string state)
        {
            switch (state)
            {
                case "configured":
                case "disabled":
                case "previewed":
                case "removed":
                case "nothing_to_remove":
                    return 0;
                case "refused":
                    return 2;
                case "preview_changed":
                    return 3;
                case "partial":
                    return 4;
                case "space_pending":
                    return 5;
                case "check_failed":
                    return 6;
                default:
                    return 1;
            }
        }

        private static bool StateAllowed(RetentionRequest request, string state)
        {
            if (state == "refused" || state == "failed")
            {
                return true;
            }
            if (request.Action == "configure")
            {
                return state == (request.Enabled == "1" ? "configured" : "disabled");
            }
            if (request.Action == "preview")
            {
                return state == "previewed";
            }
            return request.Action == "apply" && RetentionNames.IsOneOf(state, new[]
            {
                "removed", "nothing_to_remove", "preview_changed", "partial", "space_pending", "check_failed"
            });
        }

        internal static bool TryValidateResultDocument(
            string json,
            RetentionRequest request,
            int exitCode,
            out RetentionResultDocument result,
            out string error)
        {
            result = null;
            error = null;
            try
            {
                if (string.IsNullOrWhiteSpace(json) || json.Length > RetentionNames.MaximumResultBytes)
                {
                    throw new InvalidDataException("The result has an invalid size.");
                }
                IDictionary<string, object> document = RetentionJson.ParseObject(
                    new UTF8Encoding(false).GetBytes(json), RetentionNames.MaximumResultBytes);
                long? generation = RetentionJson.Integer(document, "config_generation");
                if (RetentionJson.Integer(document, "schema_version") != 1 ||
                    !ElevatedRequestSecurity.FixedEquals(RetentionJson.String(document, "request_nonce"), request.Nonce) ||
                    !ElevatedRequestSecurity.FixedEquals(RetentionJson.String(document, "request_digest"), request.Digest) ||
                    !ElevatedRequestSecurity.FixedEquals(RetentionJson.String(document, "request_user_sid"), request.UserSid) ||
                    !ElevatedRequestSecurity.FixedEquals(RetentionJson.String(document, "action"), request.Action) ||
                    !ElevatedRequestSecurity.FixedEquals(RetentionJson.String(document, "expected_config_sha256"), request.ConfigHash) ||
                    !ElevatedRequestSecurity.FixedEquals(RetentionJson.String(document, "plan_id"), request.PlanId) ||
                    !generation.HasValue || generation.Value != request.ConfigGeneration ||
                    !string.Equals(RetentionJson.String(document, "enabled"), request.Enabled, StringComparison.Ordinal) ||
                    !string.Equals(RetentionJson.String(document, "keep_daily"), request.KeepDaily, StringComparison.Ordinal) ||
                    !string.Equals(RetentionJson.String(document, "keep_weekly"), request.KeepWeekly, StringComparison.Ordinal) ||
                    !string.Equals(RetentionJson.String(document, "keep_monthly"), request.KeepMonthly, StringComparison.Ordinal) ||
                    !string.Equals(RetentionJson.String(document, "expected_preview_sha256"), request.PreviewSha256, StringComparison.Ordinal) ||
                    !string.Equals(RetentionJson.String(document, "expected_remove_set_sha256"), request.RemoveSetSha256, StringComparison.Ordinal) ||
                    !string.Equals(RetentionJson.String(document, "expected_remove_count"), request.RemoveCount, StringComparison.Ordinal) ||
                    !string.Equals(RetentionJson.String(document, "confirm_earlier_changes"), request.ConfirmEarlierChanges, StringComparison.Ordinal))
                {
                    throw new InvalidDataException("The result does not match this request.");
                }
                bool? ok = RetentionJson.Boolean(document, "ok");
                string state = RetentionJson.String(document, "state");
                string refusal = RetentionJson.String(document, "refusal_code");
                if (!ok.HasValue || ok.Value != (exitCode == 0) || state == null || !StateAllowed(request, state) ||
                    ExpectedExitCode(state) != exitCode ||
                    (state == "refused") != (refusal != null) ||
                    (refusal != null && !RetentionNames.IsOneOf(refusal, RetentionNames.RefusalCodes)))
                {
                    throw new InvalidDataException("The result disagrees with how the step ended.");
                }
                RetentionResultDocument parsed = new RetentionResultDocument();
                parsed.State = state;
                parsed.RefusalCode = refusal;
                parsed.RemovedCount = RetentionJson.Integer(document, "removed_count") ?? 0;
                parsed.PruneCompleted = RetentionJson.Boolean(document, "prune_completed") == true;
                parsed.CheckCompleted = RetentionJson.Boolean(document, "check_completed") == true;
                parsed.RemovalUnverified = RetentionJson.Boolean(document, "removal_unverified") == true;
                parsed.HistoryRecorded = RetentionJson.Boolean(document, "history_recorded") == true;
                string previewSha = RetentionJson.String(document, "preview_sha256");
                if (previewSha != null && !RetentionDigests.IsLowerHex64(previewSha))
                {
                    throw new InvalidDataException("The result names an invalid list.");
                }
                parsed.PreviewSha256 = previewSha;
                if (request.Action == "apply" && (state == "removed" || state == "nothing_to_remove" ||
                    state == "partial" || state == "space_pending" || state == "check_failed"))
                {
                    long confirmed;
                    string removedSet = RetentionJson.String(document, "removed_set_sha256");
                    if (!long.TryParse(request.RemoveCount, NumberStyles.None, CultureInfo.InvariantCulture, out confirmed) ||
                        parsed.RemovedCount < 0 || parsed.RemovedCount > confirmed || !RetentionDigests.IsLowerHex64(removedSet))
                    {
                        throw new InvalidDataException("The result names an invalid removed list.");
                    }
                    // A complete clean-up removed exactly the confirmed list, freed its space and checked the rest.
                    if (state == "removed" && (parsed.RemovedCount != confirmed ||
                        !string.Equals(removedSet, request.RemoveSetSha256, StringComparison.Ordinal) ||
                        !parsed.PruneCompleted || !parsed.CheckCompleted))
                    {
                        throw new InvalidDataException("The result disagrees with the confirmed list.");
                    }
                    if (state == "nothing_to_remove" && (confirmed != 0 || parsed.RemovedCount != 0))
                    {
                        throw new InvalidDataException("The result disagrees with the confirmed list.");
                    }
                }
                result = parsed;
                return true;
            }
            catch (Exception exception)
            {
                error = exception.Message;
                return false;
            }
        }
    }

    internal sealed class RetentionResultDocument
    {
        internal string State;
        internal string RefusalCode;
        internal long RemovedCount;
        internal bool PruneCompleted;
        internal bool CheckCompleted;
        internal bool RemovalUnverified;
        internal bool HistoryRecorded;
        internal string PreviewSha256;
    }
}
