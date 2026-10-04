using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;

namespace Rewindle.Setup
{
    // Unpacks a ZIP that is embedded in the setup program (the release bundle, the wizard's web files) into a folder, refusing
    // anything that is not a plain file or folder below that folder: rooted or drive-qualified names, "..", duplicates, names
    // that differ only by case, and archives that are far bigger than anything Rewindle ships. Returns the SHA-256 of every file
    // as it was written (keyed by its relative path, with backslashes), taken from the archive's own bytes: an elevated run of an
    // unpacked script checks its copy against these, since the unpacked folder belongs to the person and can change afterwards.
    internal static class SafeZip
    {
        private const int MaximumEntries = 20000;
        private const long MaximumTotalBytes = 1024L * 1024L * 1024L;

        public static Dictionary<string, string> Extract(Stream archiveStream, string destinationRoot)
        {
            if (archiveStream == null)
            {
                throw new ArgumentNullException("archiveStream");
            }
            Directory.CreateDirectory(destinationRoot);
            string root = Path.GetFullPath(destinationRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, string> hashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
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
                    using (SHA256 sha = SHA256.Create())
                    using (Stream source = entry.Open())
                    using (FileStream target = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        byte[] buffer = new byte[81920];
                        int read;
                        while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            sha.TransformBlock(buffer, 0, read, null, 0);
                            target.Write(buffer, 0, read);
                        }
                        sha.TransformFinalBlock(new byte[0], 0, 0);
                        hashes[relative] = ElevatedBootstrap.Hex(sha.Hash);
                    }
                }
            }
            return hashes;
        }
    }
}
