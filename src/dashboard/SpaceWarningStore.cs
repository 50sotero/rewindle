using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    // The person's Low space warning (Settings > Backup location: warn when the backup drive will be full within 4, 8 or 12 weeks), kept
    // in space-warning.json beside the theme, motion and text-size files. It changes only when the page warns, never what a backup does,
    // so it is a display preference in the per-user settings folder rather than protected configuration. It is read and written the way
    // zoom.json is: a small file directly inside that folder, replaced atomically and never through a link. A file that is missing,
    // unreadable or odd means the default, 8 weeks.
    internal static class DashboardSpaceWarningStore
    {
        private const int SchemaVersion = 1;
        private const int MaximumBytes = 4 * 1024;
        private const string FileName = "space-warning.json";
        private static readonly object Sync = new object();

        // True when a valid choice was read; otherwise false and the default.
        internal static bool TryLoad(out int weeks)
        {
            weeks = BackupSpaceEvaluator.DefaultWarnWeeks;
            lock (Sync)
            {
                try
                {
                    string path = GetPath();
                    if (string.IsNullOrEmpty(path) || !File.Exists(path) || IsReparsePoint(path) ||
                        IsReparsePoint(Path.GetDirectoryName(path)))
                    {
                        return false;
                    }
                    FileInfo info = new FileInfo(path);
                    if (info.Length <= 0 || info.Length > MaximumBytes)
                    {
                        return false;
                    }
                    JavaScriptSerializer serializer = new JavaScriptSerializer();
                    serializer.MaxJsonLength = MaximumBytes;
                    serializer.RecursionLimit = 8;
                    IDictionary<string, object> document = serializer.DeserializeObject(
                        File.ReadAllText(path, new UTF8Encoding(false, true))) as IDictionary<string, object>;
                    object rawVersion, rawWeeks;
                    if (document == null ||
                        !document.TryGetValue("schema_version", out rawVersion) || !(rawVersion is int) ||
                        (int)rawVersion != SchemaVersion ||
                        !document.TryGetValue("warn_weeks", out rawWeeks) || !(rawWeeks is int) ||
                        !BackupSpaceEvaluator.IsAllowedWarnWeeks((int)rawWeeks))
                    {
                        return false;
                    }
                    weeks = (int)rawWeeks;
                    return true;
                }
                catch (Exception error)
                {
                    if (IsFatal(error))
                    {
                        throw;
                    }
                    weeks = BackupSpaceEvaluator.DefaultWarnWeeks;
                    return false;
                }
            }
        }

        // Best effort: a choice that cannot be kept only means the next launch warns at the default again.
        internal static bool TrySave(int weeks)
        {
            if (!BackupSpaceEvaluator.IsAllowedWarnWeeks(weeks))
            {
                return false;
            }
            lock (Sync)
            {
                string temporaryPath = null;
                try
                {
                    string targetPath = GetPath();
                    string directory = string.IsNullOrEmpty(targetPath) ? null : Path.GetDirectoryName(targetPath);
                    if (string.IsNullOrEmpty(directory))
                    {
                        return false;
                    }
                    Directory.CreateDirectory(directory);
                    if (IsReparsePoint(directory) || (File.Exists(targetPath) && IsReparsePoint(targetPath)))
                    {
                        return false;
                    }
                    byte[] bytes = new UTF8Encoding(false, true).GetBytes(
                        "{\"schema_version\":" + SchemaVersion.ToString(CultureInfo.InvariantCulture) +
                        ",\"warn_weeks\":" + weeks.ToString(CultureInfo.InvariantCulture) + "}");
                    temporaryPath = Path.Combine(directory, ".space-warning." + Guid.NewGuid().ToString("N") + ".tmp");
                    using (FileStream stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                    {
                        stream.Write(bytes, 0, bytes.Length);
                        stream.Flush(true);
                    }
                    if (File.Exists(targetPath))
                    {
                        AtomicFile.ReplaceExisting(temporaryPath, targetPath);
                    }
                    else
                    {
                        File.Move(temporaryPath, targetPath);
                    }
                    temporaryPath = null;
                    return true;
                }
                catch (Exception error)
                {
                    if (IsFatal(error))
                    {
                        throw;
                    }
                    return false;
                }
                finally
                {
                    if (!string.IsNullOrEmpty(temporaryPath))
                    {
                        try
                        {
                            File.Delete(temporaryPath);
                        }
                        catch (Exception error)
                        {
                            if (IsFatal(error))
                            {
                                throw;
                            }
                        }
                    }
                }
            }
        }

        // Beside the theme file, so --isolated-presentation-store and the tests' settings folder apply to it too.
        internal static string GetPath()
        {
            string themePath = DashboardThemeManager.SettingsPath;
            string directory = string.IsNullOrEmpty(themePath) ? string.Empty : Path.GetDirectoryName(Path.GetFullPath(themePath));
            return string.IsNullOrWhiteSpace(directory) ? string.Empty : Path.Combine(directory, FileName);
        }

        private static bool IsReparsePoint(string path)
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }

        private static bool IsFatal(Exception error)
        {
            return error is OutOfMemoryException ||
                error is StackOverflowException ||
                error is System.Threading.ThreadAbortException ||
                error is AccessViolationException;
        }
    }
}
