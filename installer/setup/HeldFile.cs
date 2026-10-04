using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Rewindle.Setup
{
    // Files Setup runs or loads from the person's own temporary folder, where another program running as them could swap one
    // between the check and the use. Held open with only reading shared, a file can't be written, deleted or renamed, nor any
    // folder above it renamed or deleted. Its resolved path (every link and junction on the way followed) keeps naming it, where
    // a path through a junction could be pointed elsewhere at any time.
    internal static class HeldFile
    {
        public static FileStream Open(string path)
        {
            return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        }

        // The resolved path of an open file, without the \\?\ prefix; null when it can't be told, or would not mean exactly the
        // same file without that prefix.
        public static string ResolvedPath(SafeFileHandle file)
        {
            StringBuilder buffer = new StringBuilder(1024);
            uint length = GetFinalPathNameByHandle(file, buffer, (uint)buffer.Capacity, 0);
            string resolved = length > 0 && length < buffer.Capacity ? buffer.ToString() : null;
            if (resolved != null && resolved.StartsWith(@"\\?\UNC\", StringComparison.Ordinal))
            {
                resolved = @"\\" + resolved.Substring(8);
            }
            else if (resolved != null && resolved.StartsWith(@"\\?\", StringComparison.Ordinal))
            {
                resolved = resolved.Substring(4);
            }
            try
            {
                return resolved != null && string.Equals(Path.GetFullPath(resolved), resolved, StringComparison.Ordinal) ? resolved : null;
            }
            catch (Exception error)
            {
                if (!(error is ArgumentException) && !(error is NotSupportedException) && !(error is PathTooLongException))
                {
                    throw;
                }
                return null;
            }
        }

        [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint capacity, uint flags);
    }
}
