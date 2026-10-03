using System;
using System.IO;
using System.Text;

namespace Rewindle.Setup
{
    // A small text log of what Setup itself did (never the contents of anyone's files, passwords or the recovery key), so a
    // person can attach it to a bug report. It is overwritten on every run, lives in the user's temp folder next to nothing
    // else of Rewindle's, and is left in place when Setup exits. Without Initialize (in the unit tests) writing does nothing.
    internal static class SetupLog
    {
        private const int MaximumBytes = 256 * 1024;
        private static readonly object gate = new object();
        private static string path;
        private static long written;

        public static string FilePath
        {
            get { return path; }
        }

        public static void Initialize(string logPath)
        {
            lock (gate)
            {
                path = logPath;
                written = 0;
                try
                {
                    File.WriteAllText(path, string.Empty, new UTF8Encoding(false));
                }
                catch (Exception)
                {
                    path = null;
                }
            }
        }

        public static void Write(string message)
        {
            lock (gate)
            {
                if (path == null || written > MaximumBytes)
                {
                    return;
                }
                try
                {
                    string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + (message ?? string.Empty) + Environment.NewLine;
                    File.AppendAllText(path, line, new UTF8Encoding(false));
                    written += line.Length;
                }
                catch (Exception)
                {
                    // A log that cannot be written is not worth stopping Setup for.
                }
            }
        }

        public static void Write(string context, Exception error)
        {
            Write(context + ": " + (error == null ? "unknown error" : error.ToString()));
        }
    }
}
