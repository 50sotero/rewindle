using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;

namespace Rewindle.Setup
{
    // Unpacks a ZIP that is embedded in the setup program (the release bundle, the wizard's web files) into a folder, refusing
    // anything that is not a plain file or folder below that folder: rooted or drive-qualified names, "..", duplicates, names
    // that differ only by case, and archives that are far bigger than anything Rewindle ships.
    internal static class SafeZip
    {
        private const int MaximumEntries = 20000;
        private const long MaximumTotalBytes = 1024L * 1024L * 1024L;

        public static void Extract(Stream archiveStream, string destinationRoot)
        {
            if (archiveStream == null)
            {
                throw new ArgumentNullException("archiveStream");
            }
            Directory.CreateDirectory(destinationRoot);
            string root = Path.GetFullPath(destinationRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            long total = 0;

            using (ZipArchive archive = new ZipArchive(archiveStream, ZipArchiveMode.Read, false))
            {
                if (archive.Entries.Count > MaximumEntries)
                {
                    throw new InvalidDataException("The embedded payload has more files than expected.");
                }
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string name = entry.FullName ?? string.Empty;
                    bool isDirectory = name.EndsWith("/", StringComparison.Ordinal);
                    string relative = name.Replace('/', Path.DirectorySeparatorChar);
                    if (string.IsNullOrWhiteSpace(relative) ||
                        Path.IsPathRooted(relative) ||
                        relative.IndexOf('\0') >= 0 ||
                        relative.IndexOf(':') >= 0 ||
                        Array.IndexOf(relative.Split(Path.DirectorySeparatorChar), "..") >= 0 ||
                        !seen.Add(relative.TrimEnd(Path.DirectorySeparatorChar)))
                    {
                        throw new InvalidDataException("The embedded payload contains an unsafe path.");
                    }

                    string path = Path.GetFullPath(Path.Combine(destinationRoot, relative));
                    if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException("The embedded payload escapes its temporary folder.");
                    }
                    if (isDirectory)
                    {
                        Directory.CreateDirectory(path);
                        continue;
                    }

                    total += entry.Length;
                    if (total > MaximumTotalBytes)
                    {
                        throw new InvalidDataException("The embedded payload is larger than expected.");
                    }
                    string parent = Path.GetDirectoryName(path);
                    if (!string.IsNullOrEmpty(parent))
                    {
                        Directory.CreateDirectory(parent);
                    }
                    using (Stream source = entry.Open())
                    using (FileStream target = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        source.CopyTo(target);
                    }
                }
            }
        }
    }
}
