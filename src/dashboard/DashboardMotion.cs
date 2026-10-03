using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;

namespace ResticBackuper.Dashboard
{
    public enum DashboardMotionPreference
    {
        System,
        Full,
        Reduced
    }

    public sealed class DashboardMotionResolution
    {
        internal DashboardMotionResolution(
            DashboardMotionPreference preference,
            bool motionAllowed,
            bool isHighContrast)
        {
            Preference = preference;
            MotionAllowed = motionAllowed;
            IsHighContrast = isHighContrast;
        }

        public DashboardMotionPreference Preference { get; private set; }

        public bool MotionAllowed { get; private set; }

        public bool IsHighContrast { get; private set; }

        public bool IsFollowingSystem
        {
            get { return Preference == DashboardMotionPreference.System; }
        }
    }

    // Motion is a user preference with a separate, intentionally small settings file beside
    // the theme settings. Keeping it separate lets older theme files continue to load without
    // a migration while retaining the same per-user, atomic settings-root behavior.
    internal static class DashboardMotion
    {
        private const int SettingsSchemaVersion = 1;
        private const int MaximumSettingsBytes = 16 * 1024;
        private const string SettingsFileName = "motion.json";
        private const string MotionKey = "motion";
        private static readonly object SettingsSync = new object();
        private static DashboardMotionPreference currentPreference =
            DashboardMotionPreference.System;

        internal static DashboardMotionPreference CurrentPreference
        {
            get
            {
                lock (SettingsSync)
                {
                    return currentPreference;
                }
            }
        }

        internal static DashboardMotionResolution LoadAndResolve()
        {
            DashboardMotionPreference preference = LoadPreference();
            SetPreference(preference);
            return Resolve(preference);
        }

        internal static DashboardMotionResolution Resolve(
            DashboardMotionPreference preference)
        {
            return Resolve(
                preference,
                SystemParameters.ClientAreaAnimation,
                SystemParameters.HighContrast);
        }

        // Kept internal so smoke tests can exercise the accessibility matrix without
        // changing the user's Windows settings.
        internal static DashboardMotionResolution Resolve(
            DashboardMotionPreference preference,
            bool clientAreaAnimation,
            bool highContrast)
        {
            if (!Enum.IsDefined(typeof(DashboardMotionPreference), preference))
            {
                preference = DashboardMotionPreference.System;
            }

            bool allowed = !highContrast &&
                (preference == DashboardMotionPreference.Full ||
                 preference == DashboardMotionPreference.System &&
                    clientAreaAnimation);
            return new DashboardMotionResolution(preference, allowed, highContrast);
        }

        internal static void SetPreference(DashboardMotionPreference preference)
        {
            if (!Enum.IsDefined(typeof(DashboardMotionPreference), preference))
            {
                preference = DashboardMotionPreference.System;
            }
            lock (SettingsSync)
            {
                currentPreference = preference;
            }
        }

        internal static bool MotionAllowed()
        {
            return Resolve(CurrentPreference).MotionAllowed;
        }

        internal static string GetPreferenceDisplayName(
            DashboardMotionPreference preference)
        {
            switch (preference)
            {
                case DashboardMotionPreference.Full:
                    return "Full";
                case DashboardMotionPreference.Reduced:
                    return "Reduced";
                default:
                    return "System";
            }
        }

        internal static bool TryParsePreference(
            string value,
            out DashboardMotionPreference preference)
        {
            preference = DashboardMotionPreference.System;
            if (string.Equals(value, "System", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            if (string.Equals(value, "Full", StringComparison.OrdinalIgnoreCase))
            {
                preference = DashboardMotionPreference.Full;
                return true;
            }
            if (string.Equals(value, "Reduced", StringComparison.OrdinalIgnoreCase))
            {
                preference = DashboardMotionPreference.Reduced;
                return true;
            }
            return false;
        }

        internal static DashboardMotionPreference LoadPreference()
        {
            lock (SettingsSync)
            {
                try
                {
                    string path = GetSettingsPath();
                    if (string.IsNullOrEmpty(path) || !File.Exists(path) ||
                        !IsSafeSettingsPath(path, false) || IsReparsePoint(path))
                    {
                        return DashboardMotionPreference.System;
                    }

                    string json;
                    using (FileStream stream = new FileStream(
                        path,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.Read | FileShare.Delete))
                    {
                        if (stream.Length <= 0 || stream.Length > MaximumSettingsBytes)
                        {
                            return DashboardMotionPreference.System;
                        }
                        using (StreamReader reader = new StreamReader(
                            stream,
                            new UTF8Encoding(false, true),
                            true,
                            1024))
                        {
                            json = reader.ReadToEnd();
                        }
                    }

                    if (json.Length > MaximumSettingsBytes)
                    {
                        return DashboardMotionPreference.System;
                    }
                    IDictionary<string, object> document = CreateSerializer()
                        .DeserializeObject(json) as IDictionary<string, object>;
                    if (document == null || ReadSchemaVersion(document) != SettingsSchemaVersion)
                    {
                        return DashboardMotionPreference.System;
                    }

                    object rawMotion;
                    DashboardMotionPreference preference;
                    if (!document.TryGetValue(MotionKey, out rawMotion) || rawMotion == null ||
                        !TryParsePreference(Convert.ToString(
                            rawMotion,
                            CultureInfo.InvariantCulture),
                            out preference))
                    {
                        return DashboardMotionPreference.System;
                    }
                    return preference;
                }
                catch (Exception error)
                {
                    if (IsFatal(error))
                    {
                        throw;
                    }
                    return DashboardMotionPreference.System;
                }
            }
        }

        internal static bool TrySavePreference(DashboardMotionPreference preference)
        {
            if (!Enum.IsDefined(typeof(DashboardMotionPreference), preference))
            {
                return false;
            }

            lock (SettingsSync)
            {
                string temporaryPath = null;
                try
                {
                    string targetPath = GetSettingsPath();
                    if (string.IsNullOrEmpty(targetPath))
                    {
                        return false;
                    }
                    string directory = Path.GetDirectoryName(targetPath);
                    if (string.IsNullOrEmpty(directory))
                    {
                        return false;
                    }

                    Directory.CreateDirectory(directory);
                    if (!IsSafeSettingsPath(targetPath, true) ||
                        IsReparsePoint(directory) ||
                        (File.Exists(targetPath) && IsReparsePoint(targetPath)))
                    {
                        return false;
                    }

                    Dictionary<string, object> document = new Dictionary<string, object>();
                    document["schema_version"] = SettingsSchemaVersion;
                    document[MotionKey] = GetPreferenceDisplayName(preference);
                    byte[] bytes = new UTF8Encoding(false, true).GetBytes(
                        CreateSerializer().Serialize(document));
                    if (bytes.Length > MaximumSettingsBytes)
                    {
                        return false;
                    }

                    temporaryPath = Path.Combine(
                        directory,
                        ".motion." + Guid.NewGuid().ToString("N") + ".tmp");
                    using (FileStream stream = new FileStream(
                        temporaryPath,
                        FileMode.CreateNew,
                        FileAccess.Write,
                        FileShare.None,
                        4096,
                        FileOptions.WriteThrough))
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
                        try
                        {
                            File.Move(temporaryPath, targetPath);
                        }
                        catch (IOException)
                        {
                            if (!File.Exists(targetPath) || IsReparsePoint(targetPath))
                            {
                                throw;
                            }
                            AtomicFile.ReplaceExisting(temporaryPath, targetPath);
                        }
                    }
                    temporaryPath = null;
                    currentPreference = preference;
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
                            if (File.Exists(temporaryPath))
                            {
                                File.Delete(temporaryPath);
                            }
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

        private static string GetSettingsPath()
        {
            try
            {
                string themePath = DashboardThemeManager.SettingsPath;
                string directory = string.IsNullOrEmpty(themePath)
                    ? string.Empty
                    : Path.GetDirectoryName(Path.GetFullPath(themePath));
                if (string.IsNullOrWhiteSpace(directory))
                {
                    return string.Empty;
                }
                string candidate = Path.GetFullPath(Path.Combine(directory, SettingsFileName));
                return string.Equals(
                    Path.GetDirectoryName(candidate),
                    Path.GetFullPath(directory),
                    StringComparison.OrdinalIgnoreCase)
                    ? candidate
                    : string.Empty;
            }
            catch (Exception error)
            {
                if (IsFatal(error))
                {
                    throw;
                }
                return string.Empty;
            }
        }

        private static bool IsSafeSettingsPath(string path, bool directoryMustExist)
        {
            try
            {
                string expectedDirectory = Path.GetDirectoryName(
                    DashboardThemeManager.SettingsPath);
                if (string.IsNullOrWhiteSpace(expectedDirectory))
                {
                    return false;
                }
                expectedDirectory = Path.GetFullPath(expectedDirectory);
                string candidate = Path.GetFullPath(path);
                string candidateDirectory = Path.GetDirectoryName(candidate);
                if (!string.Equals(candidateDirectory, expectedDirectory,
                    StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                if (directoryMustExist && !Directory.Exists(expectedDirectory))
                {
                    return false;
                }
                if (Directory.Exists(expectedDirectory) && IsReparsePoint(expectedDirectory))
                {
                    return false;
                }
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
        }

        private static int ReadSchemaVersion(IDictionary<string, object> document)
        {
            object raw;
            int value;
            if (!document.TryGetValue("schema_version", out raw) || raw == null ||
                !int.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture),
                    NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
            {
                return 0;
            }
            return value;
        }

        private static JavaScriptSerializer CreateSerializer()
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = MaximumSettingsBytes;
            serializer.RecursionLimit = 8;
            return serializer;
        }

        private static bool IsReparsePoint(string path)
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }

        private static bool IsFatal(Exception error)
        {
            return error is OutOfMemoryException ||
                error is StackOverflowException ||
                error is ThreadAbortException ||
                error is AccessViolationException;
        }
    }
}
