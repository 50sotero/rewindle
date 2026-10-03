using System;
using System.IO;

namespace ResticBackuper.Dashboard
{
    internal static class AtomicFile
    {
        public static void ReplaceExisting(string replacementPath, string targetPath)
        {
            if (string.IsNullOrEmpty(replacementPath) || string.IsNullOrEmpty(targetPath))
            {
                throw new ArgumentException("Atomic replacement paths are required.");
            }

            string replacementFullPath = Path.GetFullPath(replacementPath);
            string targetFullPath = Path.GetFullPath(targetPath);
            string replacementDirectory = Path.GetDirectoryName(replacementFullPath);
            string targetDirectory = Path.GetDirectoryName(targetFullPath);
            if (string.IsNullOrEmpty(replacementDirectory)
                || string.IsNullOrEmpty(targetDirectory)
                || !string.Equals(
                    replacementDirectory,
                    targetDirectory,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException(
                    "Atomic replacement and target must share one directory.");
            }

            string backupPath = Path.Combine(
                targetDirectory,
                ".atomic-" + Guid.NewGuid().ToString("N") + ".bak");
            try
            {
                File.Replace(
                    replacementFullPath,
                    targetFullPath,
                    backupPath,
                    true);
                File.Delete(backupPath);
            }
            finally
            {
                try
                {
                    if (File.Exists(backupPath))
                    {
                        File.Delete(backupPath);
                    }
                }
                catch
                {
                    // Preserve the original replacement/cleanup exception.
                }
            }
        }
    }
}
