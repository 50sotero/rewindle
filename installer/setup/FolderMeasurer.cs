using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security;
using System.Threading;

namespace Rewindle.Setup
{
    // The running total of one folder, as the wizard shows it while the walk is still going.
    internal sealed class FolderTotals
    {
        public long Bytes;
        public long Files;
        // Files that are only in the cloud (OneDrive and similar). They count in Bytes and Files too.
        public long PlaceholderFiles;
        public long PlaceholderBytes;
        // Folders that could not be opened (access denied and the like) and so are not in the total.
        public long SkippedFolders;

        public FolderTotals Copy()
        {
            FolderTotals copy = new FolderTotals();
            copy.Bytes = Bytes;
            copy.Files = Files;
            copy.PlaceholderFiles = PlaceholderFiles;
            copy.PlaceholderBytes = PlaceholderBytes;
            copy.SkippedFolders = SkippedFolders;
            return copy;
        }
    }

    // Adds up the files in a folder, for the "What to protect" page. Read-only and polite: it never follows a folder that is a
    // link (a junction or symbolic link, which could loop or leave the folder), it counts what it can read and tells how many
    // folders it could not, and it stops at once when the token is cancelled.
    internal static class FolderMeasurer
    {
        private const FileAttributes RecallOnOpen = (FileAttributes)0x00040000;
        private const FileAttributes RecallOnDataAccess = (FileAttributes)0x00400000;
        // The attributes the engine's preflight treats as online-only (CLOUD_ONLY_ATTRIBUTE_MASK in restic_common.py).
        private const FileAttributes OnlineOnly = RecallOnOpen | RecallOnDataAccess | FileAttributes.Offline;
        private static readonly TimeSpan ReportInterval = TimeSpan.FromMilliseconds(250);

        // Walks `path`, calling `report` with the totals so far every quarter of a second and once more, with done = true, at the
        // end. `error` is set when the folder itself cannot be measured. Cancelling ends the walk without a final report.
        public static void Measure(
            string path,
            CancellationToken cancel,
            Action<FolderTotals, bool, string> report)
        {
            Measure(path, ExclusionRules.None, cancel, report);
        }

        // Folders the backup leaves out (exclusions) are neither counted nor walked, as in its own preflight.
        public static void Measure(
            string path,
            ExclusionRules exclusions,
            CancellationToken cancel,
            Action<FolderTotals, bool, string> report)
        {
            FolderTotals totals = new FolderTotals();
            DirectoryInfo root;
            try
            {
                root = new DirectoryInfo(path);
                if (!root.Exists)
                {
                    report(totals, true, "This folder can’t be found.");
                    return;
                }
                if ((root.Attributes & OnlineOnly) != 0)
                {
                    // An online-only folder itself: the engine's preflight classifies the folder first and refuses it.
                    totals.PlaceholderFiles++;
                }
                if ((root.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    report(totals, true, "This folder is a link, so its size can’t be shown.");
                    return;
                }
            }
            catch (Exception error)
            {
                if (!IsAccessProblem(error))
                {
                    throw;
                }
                report(totals, true, "This folder can’t be opened.");
                return;
            }

            Stopwatch clock = Stopwatch.StartNew();
            TimeSpan nextReport = ReportInterval;
            Stack<DirectoryInfo> pending = new Stack<DirectoryInfo>();
            pending.Push(root);
            while (pending.Count > 0)
            {
                if (cancel.IsCancellationRequested)
                {
                    return;
                }
                DirectoryInfo directory = pending.Pop();
                try
                {
                    foreach (FileSystemInfo entry in directory.EnumerateFileSystemInfos())
                    {
                        if (cancel.IsCancellationRequested)
                        {
                            return;
                        }
                        FileAttributes attributes = entry.Attributes;
                        if ((attributes & FileAttributes.Directory) != 0)
                        {
                            // Left out of every backup, so neither its size nor its online-only files matter: the engine's
                            // preflight prunes these before it classifies anything in them.
                            if (exclusions.IsDefinitelyExcluded(entry.FullName))
                            {
                                continue;
                            }
                            // A folder can be online-only too (OneDrive marks it as a reparse point as well), and the engine's
                            // preflight classifies every entry, folders included, before it decides not to walk one, so it is
                            // counted here before the link check below skips it.
                            if ((attributes & OnlineOnly) != 0)
                            {
                                totals.PlaceholderFiles++;
                            }
                            // A link is not walked: its target is somewhere else, or the folder itself.
                            if ((attributes & FileAttributes.ReparsePoint) == 0)
                            {
                                pending.Push((DirectoryInfo)entry);
                            }
                            continue;
                        }
                        long length = 0;
                        try
                        {
                            length = ((FileInfo)entry).Length;
                        }
                        catch (Exception error)
                        {
                            if (!IsAccessProblem(error))
                            {
                                throw;
                            }
                        }
                        totals.Files++;
                        totals.Bytes += length;
                        if ((attributes & OnlineOnly) != 0)
                        {
                            totals.PlaceholderFiles++;
                            totals.PlaceholderBytes += length;
                        }
                        if (clock.Elapsed >= nextReport)
                        {
                            report(totals.Copy(), false, null);
                            nextReport = clock.Elapsed + ReportInterval;
                        }
                    }
                }
                catch (Exception error)
                {
                    if (!IsAccessProblem(error))
                    {
                        throw;
                    }
                    totals.SkippedFolders++;
                }
            }
            report(totals.Copy(), true, null);
        }

        // Access denied, a path that is too long or gone, a drive that went away: the folder is skipped, not the whole walk.
        private static bool IsAccessProblem(Exception error)
        {
            return error is UnauthorizedAccessException ||
                error is IOException ||
                error is SecurityException ||
                error is NotSupportedException ||
                error is ArgumentException;
        }
    }
}
