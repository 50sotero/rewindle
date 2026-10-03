using System;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;

namespace ResticBackuper.Dashboard
{
    // Where an error goes when nothing is there to show it: crash.log in the active engine's dashboard folder under
    // %LOCALAPPDATA% (ResticBackuperDashboard for Rewindle), the folder the dashboard already keeps its own files in. It is
    // bounded (the current file and one older one, a quarter megabyte each, and no entry is longer than 16 KB), says the same
    // error once a minute at most, and never throws, since it is called while something else is failing. An entry can name a file or folder, so it is for the owner (or a bug report they choose to
    // write), not something the dashboard sends anywhere.
    internal static class CrashLog
    {
        private const long MaximumFileBytes = 256 * 1024;
        private const int MaximumEntryCharacters = 16 * 1024;
        private static readonly TimeSpan RepeatInterval = TimeSpan.FromSeconds(60);
        private static readonly object gate = new object();
        private static string directoryOverride;
        private static string lastSignature = string.Empty;
        private static DateTime lastWriteUtc = DateTime.MinValue;
        private static int repeated;

        // A run with --isolated-presentation-store keeps clear of the dashboard's real folder, like the rest of its writes.
        internal static void UseIsolatedLocation(bool isolated)
        {
            lock (gate)
            {
                directoryOverride = isolated
                    ? EngineProfile.Current.IsolatedPresentationDirectory()
                    : null;
            }
        }

        // The log file, or an empty string when its folder cannot be worked out.
        internal static string FilePath
        {
            get
            {
                try
                {
                    return System.IO.Path.Combine(DirectoryPath(), "crash.log");
                }
                catch (Exception)
                {
                    return string.Empty;
                }
            }
        }

        private static string DirectoryPath()
        {
            lock (gate)
            {
                if (!string.IsNullOrEmpty(directoryOverride))
                {
                    return directoryOverride;
                }
            }
            string directory = EngineProfile.Current.DashboardDataDirectory();
            if (string.IsNullOrWhiteSpace(directory))
            {
                directory = System.IO.Path.Combine(
                    System.IO.Path.GetTempPath(),
                    EngineProfile.Current.DashboardDataDirectoryName);
            }
            return directory;
        }

        internal static void Write(string source, Exception error)
        {
            try
            {
                lock (gate)
                {
                    DateTime now = DateTime.UtcNow;
                    string detail = error == null ? "(no exception was given)" : error.ToString();
                    string firstLine = detail;
                    int lineBreak = detail.IndexOf('\n');
                    if (lineBreak >= 0)
                    {
                        firstLine = detail.Substring(0, lineBreak);
                    }
                    string signature = (error == null ? string.Empty : error.GetType().FullName) + "|" + firstLine;
                    if (now >= lastWriteUtc &&
                        now - lastWriteUtc < RepeatInterval &&
                        string.Equals(signature, lastSignature, StringComparison.Ordinal))
                    {
                        repeated++;
                        return;
                    }

                    StringBuilder entry = new StringBuilder();
                    entry.Append('[')
                        .Append(now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture))
                        .Append("] ")
                        .AppendLine(string.IsNullOrWhiteSpace(source) ? "error" : source);
                    if (repeated > 0)
                    {
                        entry.Append("(the error before this one happened ")
                            .Append(repeated.ToString(CultureInfo.InvariantCulture))
                            .AppendLine(" more times and was not written again)");
                    }
                    entry.Append("Rewindle ")
                        .Append(Assembly.GetExecutingAssembly().GetName().Version.ToString())
                        .Append(" on ")
                        .AppendLine(Environment.OSVersion.VersionString);
                    entry.AppendLine(detail.Length > MaximumEntryCharacters
                        ? detail.Substring(0, MaximumEntryCharacters) + "..."
                        : detail);
                    entry.AppendLine();

                    string directory = DirectoryPath();
                    Directory.CreateDirectory(directory);
                    string path = System.IO.Path.Combine(directory, "crash.log");
                    KeepWithinLimit(path);
                    File.AppendAllText(path, entry.ToString(), new UTF8Encoding(false));
                    lastSignature = signature;
                    lastWriteUtc = now;
                    repeated = 0;
                }
            }
            catch (Exception)
            {
                // A log that cannot be written is not worth failing over.
            }
        }

        // The current file is set aside as crash.log.old (replacing the one before it) once it has grown past the limit, so
        // the log never holds more than about half a megabyte.
        private static void KeepWithinLimit(string path)
        {
            FileInfo file = new FileInfo(path);
            if (!file.Exists || file.Length <= MaximumFileBytes)
            {
                return;
            }
            string older = path + ".old";
            try
            {
                if (File.Exists(older))
                {
                    File.Delete(older);
                }
                File.Move(path, older);
            }
            catch (Exception)
            {
                try
                {
                    File.Delete(path);
                }
                catch (Exception)
                {
                }
            }
        }
    }
}
