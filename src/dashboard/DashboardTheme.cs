using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace ResticBackuper.Dashboard
{
    public enum DashboardThemePreference
    {
        System,
        Midnight,
        Daylight
    }

    public enum DashboardThemeKind
    {
        Midnight,
        Daylight,
        WindowsHighContrast
    }

    public sealed class DashboardThemeResolution
    {
        internal DashboardThemeResolution(
            DashboardThemePreference preference,
            DashboardThemeKind effectiveKind,
            DashboardThemePalette palette)
        {
            Preference = preference;
            EffectiveKind = effectiveKind;
            Palette = palette;
        }

        public DashboardThemePreference Preference { get; private set; }

        public DashboardThemeKind EffectiveKind { get; private set; }

        public DashboardThemePalette Palette { get; private set; }

        public bool IsFollowingSystem
        {
            get { return Preference == DashboardThemePreference.System; }
        }

        public bool IsHighContrast
        {
            get { return EffectiveKind == DashboardThemeKind.WindowsHighContrast; }
        }
    }

    /// <summary>
    /// Immutable, semantic color tokens for the dashboard. Each brush is frozen so palettes can
    /// safely be shared by windows and drawing elements on the UI thread.
    /// </summary>
    public sealed class DashboardThemePalette
    {
        private readonly IDictionary<string, SolidColorBrush> legacyBrushes;

        internal DashboardThemePalette(PaletteDefinition definition)
        {
            if (definition == null)
            {
                throw new ArgumentNullException("definition");
            }

            Id = definition.Id;
            DisplayName = definition.DisplayName;
            IsDark = definition.IsDark;

            BackgroundTop = CreateBrush(definition.BackgroundTop);
            BackgroundBottom = CreateBrush(definition.BackgroundBottom);
            Surface = CreateBrush(definition.Surface);
            SurfaceSoft = CreateBrush(definition.SurfaceSoft);
            Border = CreateBrush(definition.Border);
            TextPrimary = CreateBrush(definition.TextPrimary);
            TextSecondary = CreateBrush(definition.TextSecondary);
            TextTertiary = CreateBrush(definition.TextTertiary);
            TableText = CreateBrush(definition.TableText);
            AccentPrimary = CreateBrush(definition.AccentPrimary);
            AccentInfo = CreateBrush(definition.AccentInfo);
            AccentInfoText = CreateBrush(definition.AccentInfoText);
            AccentPurple = CreateBrush(definition.AccentPurple);
            Success = CreateBrush(definition.Success);
            Danger = CreateBrush(definition.Danger);
            Warning = CreateBrush(definition.Warning);
            AccentInk = CreateBrush(definition.AccentInk);
            ButtonBackground = CreateBrush(definition.ButtonBackground);
            ButtonText = CreateBrush(definition.ButtonText);
            PrimaryButton = CreateBrush(definition.PrimaryButton);
            PrimaryButtonText = CreateBrush(definition.PrimaryButtonText);
            PrimaryButtonBorder = CreateBrush(definition.PrimaryButtonBorder);
            ProgressTrack = CreateBrush(definition.ProgressTrack);
            ScheduleBackground = CreateBrush(definition.ScheduleBackground);
            PhaseInactive = CreateBrush(definition.PhaseInactive);
            TextOnAccent = CreateBrush(definition.TextOnAccent);
            FooterText = CreateBrush(definition.FooterText);
            AddButtonText = CreateBrush(definition.AddButtonText);
            AddButtonBorder = CreateBrush(definition.AddButtonBorder);
            SafetyBackground = CreateBrush(definition.SafetyBackground);
            SafetyBorder = CreateBrush(definition.SafetyBorder);
            SafetyText = CreateBrush(definition.SafetyText);
            RowEven = CreateBrush(definition.RowEven);
            RowOdd = CreateBrush(definition.RowOdd);
            RowBorder = CreateBrush(definition.RowBorder);
            RequiredBackground = CreateBrush(definition.RequiredBackground);
            RequiredBorder = CreateBrush(definition.RequiredBorder);
            RemoveBackground = CreateBrush(definition.RemoveBackground);
            RemoveBorder = CreateBrush(definition.RemoveBorder);
            RemoveText = CreateBrush(definition.RemoveText);
            DangerActionText = CreateBrush(definition.DangerActionText);
            DangerActionBorder = CreateBrush(definition.DangerActionBorder);
            GridLine = CreateBrush(definition.GridLine);
            AlternatingRow = CreateBrush(definition.AlternatingRow);
            Selection = CreateBrush(definition.Selection);
            SelectionText = CreateBrush(definition.SelectionText);
            Focus = CreateBrush(definition.Focus);
            StatusLive = CreateBrush(definition.StatusLive);
            StatusWarning = CreateBrush(definition.StatusWarning);
            StatusDanger = CreateBrush(definition.StatusDanger);
            StatusSuccess = CreateBrush(definition.StatusSuccess);
            StatusReady = CreateBrush(definition.StatusReady);
            ChartMuted = CreateBrush(definition.ChartMuted);
            ChartGrid = CreateBrush(definition.ChartGrid);
            ChartPointOutline = CreateBrush(definition.ChartPointOutline);

            legacyBrushes = BuildLegacyBrushMap();
        }

        public string Id { get; private set; }

        public string DisplayName { get; private set; }

        public bool IsDark { get; private set; }

        public SolidColorBrush BackgroundTop { get; private set; }

        public SolidColorBrush BackgroundBottom { get; private set; }

        public SolidColorBrush Surface { get; private set; }

        public SolidColorBrush SurfaceSoft { get; private set; }

        public SolidColorBrush Border { get; private set; }

        public SolidColorBrush TextPrimary { get; private set; }

        public SolidColorBrush TextSecondary { get; private set; }

        public SolidColorBrush TextTertiary { get; private set; }

        public SolidColorBrush TableText { get; private set; }

        public SolidColorBrush AccentPrimary { get; private set; }

        public SolidColorBrush AccentInfo { get; private set; }

        public SolidColorBrush AccentInfoText { get; private set; }

        public SolidColorBrush AccentPurple { get; private set; }

        public SolidColorBrush Success { get; private set; }

        public SolidColorBrush Danger { get; private set; }

        public SolidColorBrush Warning { get; private set; }

        /// <summary>
        /// Text that is accent-colored and read as text (a stage badge, a fact label, a pending-change line). The same hue
        /// in both themes, as on the page (--accent-ink); AccentInfoText is blue in Midnight and teal in Daylight.
        /// </summary>
        public SolidColorBrush AccentInk { get; private set; }

        public SolidColorBrush ButtonBackground { get; private set; }

        public SolidColorBrush ButtonText { get; private set; }

        /// <summary>
        /// The primary button of a dialog, as the page draws its own: ink on the canvas (the page's bg-ink with text-canvas),
        /// not an accent fill. Windows High Contrast keeps the system button colors.
        /// </summary>
        public SolidColorBrush PrimaryButton { get; private set; }

        public SolidColorBrush PrimaryButtonText { get; private set; }

        public SolidColorBrush PrimaryButtonBorder { get; private set; }

        public SolidColorBrush ProgressTrack { get; private set; }

        public SolidColorBrush ScheduleBackground { get; private set; }

        public SolidColorBrush PhaseInactive { get; private set; }

        public SolidColorBrush TextOnAccent { get; private set; }

        public SolidColorBrush FooterText { get; private set; }

        public SolidColorBrush AddButtonText { get; private set; }

        public SolidColorBrush AddButtonBorder { get; private set; }

        public SolidColorBrush SafetyBackground { get; private set; }

        public SolidColorBrush SafetyBorder { get; private set; }

        public SolidColorBrush SafetyText { get; private set; }

        public SolidColorBrush RowEven { get; private set; }

        public SolidColorBrush RowOdd { get; private set; }

        public SolidColorBrush RowBorder { get; private set; }

        public SolidColorBrush RequiredBackground { get; private set; }

        public SolidColorBrush RequiredBorder { get; private set; }

        public SolidColorBrush RemoveBackground { get; private set; }

        public SolidColorBrush RemoveBorder { get; private set; }

        public SolidColorBrush RemoveText { get; private set; }

        public SolidColorBrush DangerActionText { get; private set; }

        public SolidColorBrush DangerActionBorder { get; private set; }

        public SolidColorBrush GridLine { get; private set; }

        public SolidColorBrush AlternatingRow { get; private set; }

        public SolidColorBrush Selection { get; private set; }

        public SolidColorBrush SelectionText { get; private set; }

        public SolidColorBrush Focus { get; private set; }

        public SolidColorBrush StatusLive { get; private set; }

        public SolidColorBrush StatusWarning { get; private set; }

        public SolidColorBrush StatusDanger { get; private set; }

        public SolidColorBrush StatusSuccess { get; private set; }

        public SolidColorBrush StatusReady { get; private set; }

        public SolidColorBrush ChartMuted { get; private set; }

        public SolidColorBrush ChartGrid { get; private set; }

        public SolidColorBrush ChartPointOutline { get; private set; }

        /// <summary>
        /// Maps a color literal from the original Midnight-only dashboard to its semantic token.
        /// This keeps incremental UI refactors theme-correct while hard-coded colors are removed.
        /// </summary>
        public SolidColorBrush BrushForLegacy(string midnightHex)
        {
            SolidColorBrush brush;
            if (TryGetLegacyBrush(midnightHex, out brush))
            {
                return brush;
            }

            throw new ArgumentException("The legacy dashboard color is not mapped.", "midnightHex");
        }

        public bool TryGetLegacyBrush(string midnightHex, out SolidColorBrush brush)
        {
            brush = null;
            if (string.IsNullOrWhiteSpace(midnightHex))
            {
                return false;
            }

            return legacyBrushes.TryGetValue(midnightHex.Trim(), out brush);
        }

        private IDictionary<string, SolidColorBrush> BuildLegacyBrushMap()
        {
            Dictionary<string, SolidColorBrush> brushes =
                new Dictionary<string, SolidColorBrush>(StringComparer.OrdinalIgnoreCase);

            brushes["#07131E"] = TextOnAccent;
            brushes["#07151D"] = AddButtonText;
            brushes["#08111F"] = BackgroundTop;
            brushes["#0C1424"] = ChartPointOutline;
            brushes["#0D1728"] = SurfaceSoft;
            brushes["#0D1926"] = RowOdd;
            brushes["#0F1A2B"] = AlternatingRow;
            brushes["#101B30"] = BackgroundBottom;
            brushes["#101E2C"] = RowEven;
            brushes["#111D2E"] = SurfaceSoft;
            brushes["#111D31"] = Surface;
            brushes["#12352F"] = StatusLive;
            brushes["#132638"] = SafetyBackground;
            brushes["#14243A"] = ScheduleBackground;
            brushes["#14352C"] = StatusSuccess;
            brushes["#17243A"] = ButtonBackground;
            brushes["#172B45"] = StatusReady;
            brushes["#172E43"] = RequiredBackground;
            brushes["#201016"] = DangerActionText;
            brushes["#213D59"] = Selection;
            brushes["#223149"] = GridLine;
            brushes["#22384B"] = RowBorder;
            brushes["#243149"] = ChartGrid;
            brushes["#25334A"] = ProgressTrack;
            brushes["#25334B"] = Border;
            brushes["#294157"] = SafetyBorder;
            brushes["#2B1C2A"] = RemoveBackground;
            brushes["#2DD4BF"] = AccentPrimary;
            brushes["#34D399"] = Success;
            brushes["#3A2F18"] = StatusWarning;
            brushes["#3B1D2A"] = StatusDanger;
            brushes["#3B5A70"] = RequiredBorder;
            brushes["#52D6C6"] = AddButtonBorder;
            brushes["#60A5FA"] = AccentInfo;
            brushes["#617089"] = FooterText;
            brushes["#7A3B4A"] = RemoveBorder;
            brushes["#8190A8"] = ChartMuted;
            brushes["#8FA0B8"] = TextSecondary;
            brushes["#A78BFA"] = AccentPurple;
            brushes["#B7C5D1"] = SafetyText;
            brushes["#D7E1EF"] = TableText;
            brushes["#F3F7FC"] = TextPrimary;
            brushes["#FB7185"] = Danger;
            brushes["#FBBF24"] = Warning;
            brushes["#FF9AAA"] = DangerActionBorder;
            brushes["#FFB2BC"] = RemoveText;

            return brushes;
        }

        private static SolidColorBrush CreateBrush(Color color)
        {
            SolidColorBrush brush = new SolidColorBrush(color);
            brush.Freeze();
            return brush;
        }
    }

    public static class DashboardThemeManager
    {
        private const int SettingsSchemaVersion = 1;
        private const int MaximumSettingsBytes = 16 * 1024;
        private const string SettingsFileName = "settings.json";
        private const string TrayHintFileName = "tray-hint-shown.json";
        private const string PersonalizeRegistryPath =
            @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

        private static readonly object SettingsSync = new object();
        private static string settingsDirectoryOverride;
        private static readonly DashboardThemePalette MidnightPalette =
            new DashboardThemePalette(CreateMidnightDefinition());
        private static readonly DashboardThemePalette DaylightPalette =
            new DashboardThemePalette(CreateDaylightDefinition());

        public static string SettingsPath
        {
            get { return GetSettingsPath(); }
        }

        // The isolated BeautifulUI presentation must not read or write the installed
        // dashboard's preference file. This override is set once during startup and is
        // intentionally internal so normal production launches keep the original path.
        internal static void UseSettingsRootForSmokeTesting(string directory)
        {
            if (string.IsNullOrWhiteSpace(directory))
            {
                throw new ArgumentException("The isolated settings directory is required.");
            }

            string fullPath = Path.GetFullPath(directory);
            lock (SettingsSync)
            {
                settingsDirectoryOverride = fullPath;
            }
        }

        public static DashboardThemeResolution LoadAndResolve()
        {
            return Resolve(LoadPreference());
        }

        public static DashboardThemeResolution Resolve(DashboardThemePreference preference)
        {
            if (!Enum.IsDefined(typeof(DashboardThemePreference), preference))
            {
                preference = DashboardThemePreference.System;
            }

            if (SystemParameters.HighContrast)
            {
                DashboardThemePalette highContrast =
                    new DashboardThemePalette(CreateHighContrastDefinition());
                return new DashboardThemeResolution(
                    preference,
                    DashboardThemeKind.WindowsHighContrast,
                    highContrast);
            }

            DashboardThemeKind effective = preference == DashboardThemePreference.Midnight
                ? DashboardThemeKind.Midnight
                : preference == DashboardThemePreference.Daylight
                    ? DashboardThemeKind.Daylight
                    : DetectSystemThemeKind();
            DashboardThemePalette palette = effective == DashboardThemeKind.Daylight
                ? DaylightPalette
                : MidnightPalette;
            return new DashboardThemeResolution(preference, effective, palette);
        }

        public static DashboardThemeKind DetectSystemThemeKind()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    PersonalizeRegistryPath,
                    false))
                {
                    if (key != null)
                    {
                        object raw = key.GetValue("AppsUseLightTheme", null);
                        int value;
                        if (raw != null && int.TryParse(
                            Convert.ToString(raw, CultureInfo.InvariantCulture),
                            NumberStyles.Integer,
                            CultureInfo.InvariantCulture,
                            out value))
                        {
                            return value == 0
                                ? DashboardThemeKind.Midnight
                                : DashboardThemeKind.Daylight;
                        }
                    }
                }
            }
            catch (Exception error)
            {
                if (IsFatal(error))
                {
                    throw;
                }
            }

            return IsDarkColor(SystemColors.WindowColor)
                ? DashboardThemeKind.Midnight
                : DashboardThemeKind.Daylight;
        }

        public static string GetPreferenceDisplayName(DashboardThemePreference preference)
        {
            switch (preference)
            {
                case DashboardThemePreference.Midnight:
                    return "Midnight";
                case DashboardThemePreference.Daylight:
                    return "Daylight";
                default:
                    return "System";
            }
        }

        public static bool TryParsePreference(
            string value,
            out DashboardThemePreference preference)
        {
            preference = DashboardThemePreference.System;
            if (string.Equals(value, "System", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            if (string.Equals(value, "Midnight", StringComparison.OrdinalIgnoreCase))
            {
                preference = DashboardThemePreference.Midnight;
                return true;
            }
            if (string.Equals(value, "Daylight", StringComparison.OrdinalIgnoreCase))
            {
                preference = DashboardThemePreference.Daylight;
                return true;
            }
            return false;
        }

        public static DashboardThemePreference LoadPreference()
        {
            lock (SettingsSync)
            {
                try
                {
                    string path = GetSettingsPath();
                    if (string.IsNullOrEmpty(path)
                        || !File.Exists(path)
                        || !IsSafeSettingsPath(path, false)
                        || IsReparsePoint(path))
                    {
                        return DashboardThemePreference.System;
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
                            return DashboardThemePreference.System;
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
                        return DashboardThemePreference.System;
                    }

                    JavaScriptSerializer serializer = CreateSerializer();
                    IDictionary<string, object> document =
                        serializer.DeserializeObject(json) as IDictionary<string, object>;
                    if (document == null
                        || ReadSchemaVersion(document) != SettingsSchemaVersion)
                    {
                        return DashboardThemePreference.System;
                    }

                    object rawTheme;
                    DashboardThemePreference preference;
                    if (!document.TryGetValue("theme", out rawTheme)
                        || rawTheme == null
                        || !TryParsePreference(
                            Convert.ToString(rawTheme, CultureInfo.InvariantCulture),
                            out preference))
                    {
                        return DashboardThemePreference.System;
                    }

                    return preference;
                }
                catch (Exception error)
                {
                    if (IsFatal(error))
                    {
                        throw;
                    }
                    return DashboardThemePreference.System;
                }
            }
        }

        public static bool TrySavePreference(DashboardThemePreference preference)
        {
            if (!Enum.IsDefined(typeof(DashboardThemePreference), preference))
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
                    if (!IsSafeSettingsPath(targetPath, true)
                        || IsReparsePoint(directory)
                        || (File.Exists(targetPath) && IsReparsePoint(targetPath)))
                    {
                        return false;
                    }

                    Dictionary<string, object> document = new Dictionary<string, object>();
                    document["schema_version"] = SettingsSchemaVersion;
                    document["theme"] = GetPreferenceDisplayName(preference);

                    string json = CreateSerializer().Serialize(document);
                    byte[] bytes = new UTF8Encoding(false, true).GetBytes(json);
                    if (bytes.Length > MaximumSettingsBytes)
                    {
                        return false;
                    }

                    temporaryPath = Path.Combine(
                        directory,
                        ".settings." + Guid.NewGuid().ToString("N") + ".tmp");
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
                        if (IsReparsePoint(targetPath))
                        {
                            return false;
                        }
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

        // The first time the window is closed to the notification area, Rewindle says that it is still running there. This claims
        // that message: it writes a small marker file beside the theme preference, in the same per-user folder (and under the same
        // isolated-root override, so an isolated run never touches the installed dashboard's folder), and a restart, an update or a
        // second launch finds it and says nothing. True only for the call that made the marker. It is false when the marker was
        // there already and when it cannot be written (a message that came back at every start would be worse than one that is
        // never said). The marker is never read, only looked for, and nothing outside the folder is touched.
        internal static bool TryClaimTrayHint()
        {
            lock (SettingsSync)
            {
                try
                {
                    string directory = GetSettingsDirectory();
                    if (string.IsNullOrWhiteSpace(directory))
                    {
                        return false;
                    }

                    Directory.CreateDirectory(directory);
                    if (IsReparsePoint(directory))
                    {
                        return false;
                    }

                    string path = Path.Combine(directory, TrayHintFileName);
                    try
                    {
                        File.GetAttributes(path);
                        // Something is there already: a marker, or a link in its place. Either way there is nothing to write.
                        return false;
                    }
                    catch (FileNotFoundException)
                    {
                    }
                    catch (DirectoryNotFoundException)
                    {
                    }

                    byte[] bytes = new UTF8Encoding(false, true).GetBytes(
                        "{\"schema_version\":1,\"tray_hint_shown_utc\":\""
                            + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\"}");
                    using (FileStream stream = new FileStream(
                        path,
                        FileMode.CreateNew,
                        FileAccess.Write,
                        FileShare.None,
                        4096,
                        FileOptions.WriteThrough))
                    {
                        stream.Write(bytes, 0, bytes.Length);
                        stream.Flush(true);
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
        }

        private static string GetSettingsPath()
        {
            try
            {
                string directory = GetSettingsDirectory();
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
                string expectedDirectory = GetSettingsDirectory();
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

        private static string GetSettingsDirectory()
        {
            if (!string.IsNullOrWhiteSpace(settingsDirectoryOverride))
            {
                return Path.GetFullPath(settingsDirectoryOverride);
            }

            // The active engine's dashboard folder under %LOCALAPPDATA% (empty when that folder cannot be located).
            string dashboardDirectory = EngineProfile.Current.DashboardDataDirectory();
            if (string.IsNullOrWhiteSpace(dashboardDirectory))
            {
                return string.Empty;
            }
            return Path.GetFullPath(dashboardDirectory);
        }

        private static bool IsPathInside(string candidatePath, string parentPath)
        {
            string candidate = Path.GetFullPath(candidatePath);
            string parent = Path.GetFullPath(parentPath)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return candidate.StartsWith(
                parent + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsReparsePoint(string path)
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }

        private static int ReadSchemaVersion(IDictionary<string, object> document)
        {
            object raw;
            int value;
            if (!document.TryGetValue("schema_version", out raw)
                || raw == null
                || !int.TryParse(
                    Convert.ToString(raw, CultureInfo.InvariantCulture),
                    NumberStyles.Integer,
                    CultureInfo.InvariantCulture,
                    out value))
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

        private static bool IsFatal(Exception error)
        {
            return error is OutOfMemoryException
                || error is StackOverflowException
                || error is ThreadAbortException
                || error is AccessViolationException;
        }

        private static bool IsDarkColor(Color color)
        {
            double luminance = (0.2126 * color.R)
                + (0.7152 * color.G)
                + (0.0722 * color.B);
            return luminance < 128;
        }

        private static PaletteDefinition CreateMidnightDefinition()
        {
            return new PaletteDefinition
            {
                Id = "midnight",
                DisplayName = "Midnight",
                IsDark = true,
                BackgroundTop = Hex("#101927"),
                BackgroundBottom = Hex("#14202C"),
                Surface = Hex("#1A2835"),
                SurfaceSoft = Hex("#17232F"),
                Border = Hex("#2D3D4A"),
                TextPrimary = Hex("#F6F4EE"),
                TextSecondary = Hex("#B7C2CA"),
                TextTertiary = Hex("#93A5B4"),
                TableText = Hex("#E8EEF0"),
                AccentPrimary = Hex("#76D6C8"),
                AccentInfo = Hex("#7CB8FF"),
                AccentInfoText = Hex("#A6D1FF"),
                AccentInk = Hex("#91E2D6"),
                AccentPurple = Hex("#B7A0FF"),
                Success = Hex("#63D6A0"),
                Danger = Hex("#FF8F9A"),
                Warning = Hex("#FFC36A"),
                ButtonBackground = Hex("#223342"),
                ButtonText = Hex("#F6F4EE"),
                // The page's primary button: --ink on --canvas (TextPrimary on BackgroundBottom).
                PrimaryButton = Hex("#F6F4EE"),
                PrimaryButtonText = Hex("#14202C"),
                PrimaryButtonBorder = Hex("#F6F4EE"),
                ProgressTrack = Hex("#223342"),
                ScheduleBackground = Hex("#17232F"),
                PhaseInactive = Hex("#405463"),
                TextOnAccent = Hex("#101927"),
                FooterText = Hex("#B7C2CA"),
                AddButtonText = Hex("#101927"),
                AddButtonBorder = Hex("#76D6C8"),
                SafetyBackground = Hex("#213E41"),
                SafetyBorder = Hex("#3B6F6B"),
                SafetyText = Hex("#C5E8E0"),
                RowEven = Hex("#1A2835"),
                RowOdd = Hex("#17232F"),
                RowBorder = Hex("#2D3D4A"),
                RequiredBackground = Hex("#1E3442"),
                RequiredBorder = Hex("#405463"),
                RemoveBackground = Hex("#3E2932"),
                RemoveBorder = Hex("#7A4C59"),
                RemoveText = Hex("#FFB8BF"),
                DangerActionText = Hex("#101927"),
                DangerActionBorder = Hex("#FFB8BF"),
                GridLine = Hex("#2D3D4A"),
                AlternatingRow = Hex("#17232F"),
                Selection = Hex("#2A3D4C"),
                SelectionText = Hex("#F6F4EE"),
                Focus = Hex("#91E2D6"),
                StatusLive = Hex("#213E41"),
                StatusWarning = Hex("#4A3727"),
                StatusDanger = Hex("#422A32"),
                StatusSuccess = Hex("#213E41"),
                StatusReady = Hex("#1E3442"),
                ChartMuted = Hex("#93A5B4"),
                ChartGrid = Hex("#2D3D4A"),
                ChartPointOutline = Hex("#101927")
            };
        }

        private static PaletteDefinition CreateDaylightDefinition()
        {
            return new PaletteDefinition
            {
                Id = "daylight",
                DisplayName = "Daylight",
                IsDark = false,
                BackgroundTop = Hex("#F6F4EE"),
                BackgroundBottom = Hex("#EFEDE7"),
                Surface = Hex("#FFFFFF"),
                SurfaceSoft = Hex("#F5F4EF"),
                Border = Hex("#D8D9D5"),
                TextPrimary = Hex("#101927"),
                // The page's own ramp (--ink-2 and --ink-3), where both were darkened for WCAG AA. The old tertiary was 4.2:1 on the
                // page and on the soft surface it is drawn over (11-12px helper text, pending steps); this one is 5.4:1. The secondary
                // moved with it so the two stay distinct tiers. Midnight already clears 7:1 and is unchanged.
                TextSecondary = Hex("#46535C"),
                TextTertiary = Hex("#58656F"),
                TableText = Hex("#1C2A34"),
                AccentPrimary = Hex("#167C73"),
                AccentInfo = Hex("#2D77B8"),
                AccentInfoText = Hex("#10655D"),
                AccentInk = Hex("#10655D"),
                AccentPurple = Hex("#6741B8"),
                Success = Hex("#267647"),
                Danger = Hex("#B33A42"),
                Warning = Hex("#8A4B00"),
                ButtonBackground = Hex("#E9E7E0"),
                ButtonText = Hex("#101927"),
                // The page's primary button: --ink on --canvas (TextPrimary on BackgroundBottom).
                PrimaryButton = Hex("#101927"),
                PrimaryButtonText = Hex("#EFEDE7"),
                PrimaryButtonBorder = Hex("#101927"),
                ProgressTrack = Hex("#D8D9D5"),
                ScheduleBackground = Hex("#EFEDE7"),
                PhaseInactive = Hex("#D8D9D5"),
                TextOnAccent = Hex("#FFFFFF"),
                FooterText = Hex("#46535C"),
                AddButtonText = Hex("#FFFFFF"),
                AddButtonBorder = Hex("#167C73"),
                SafetyBackground = Hex("#E3F1EB"),
                SafetyBorder = Hex("#B7CBC0"),
                SafetyText = Hex("#315A4F"),
                RowEven = Hex("#FFFFFF"),
                RowOdd = Hex("#F5F4EF"),
                RowBorder = Hex("#D8D9D5"),
                RequiredBackground = Hex("#EDF2F4"),
                RequiredBorder = Hex("#B8C8D0"),
                RemoveBackground = Hex("#FAEDEF"),
                RemoveBorder = Hex("#C7797F"),
                RemoveText = Hex("#7D2930"),
                DangerActionText = Hex("#FFFFFF"),
                DangerActionBorder = Hex("#7D2930"),
                GridLine = Hex("#D8D9D5"),
                AlternatingRow = Hex("#F5F4EF"),
                Selection = Hex("#E3F1EB"),
                SelectionText = Hex("#101927"),
                Focus = Hex("#10655D"),
                StatusLive = Hex("#E3F1EB"),
                StatusWarning = Hex("#FFF1DD"),
                StatusDanger = Hex("#F8E8EA"),
                StatusSuccess = Hex("#E3F1EB"),
                StatusReady = Hex("#EDF2F4"),
                ChartMuted = Hex("#58656F"),
                ChartGrid = Hex("#D8D9D5"),
                ChartPointOutline = Hex("#FFFFFF")
            };
        }

        private static PaletteDefinition CreateHighContrastDefinition()
        {
            Color window = SystemColors.WindowColor;
            Color windowText = SystemColors.WindowTextColor;
            Color control = SystemColors.ControlColor;
            Color controlText = SystemColors.ControlTextColor;
            Color highlight = SystemColors.HighlightColor;
            Color highlightText = SystemColors.HighlightTextColor;

            return new PaletteDefinition
            {
                Id = "windows-high-contrast",
                DisplayName = "Windows High Contrast",
                IsDark = IsDarkColor(window),
                BackgroundTop = window,
                BackgroundBottom = window,
                Surface = window,
                SurfaceSoft = window,
                Border = windowText,
                TextPrimary = windowText,
                TextSecondary = windowText,
                TextTertiary = windowText,
                TableText = windowText,
                AccentPrimary = windowText,
                AccentInfo = windowText,
                AccentInfoText = windowText,
                AccentInk = windowText,
                AccentPurple = windowText,
                Success = windowText,
                Danger = windowText,
                Warning = windowText,
                ButtonBackground = control,
                ButtonText = controlText,
                // A primary button is an ordinary system button here (the border is what tells it apart from the window).
                PrimaryButton = control,
                PrimaryButtonText = controlText,
                PrimaryButtonBorder = windowText,
                ProgressTrack = window,
                ScheduleBackground = window,
                PhaseInactive = window,
                TextOnAccent = window,
                FooterText = windowText,
                AddButtonText = window,
                AddButtonBorder = windowText,
                SafetyBackground = window,
                SafetyBorder = windowText,
                SafetyText = windowText,
                RowEven = window,
                RowOdd = window,
                RowBorder = windowText,
                RequiredBackground = window,
                RequiredBorder = windowText,
                RemoveBackground = window,
                RemoveBorder = windowText,
                RemoveText = windowText,
                DangerActionText = window,
                DangerActionBorder = windowText,
                GridLine = windowText,
                AlternatingRow = window,
                Selection = highlight,
                SelectionText = highlightText,
                Focus = highlight,
                StatusLive = window,
                StatusWarning = window,
                StatusDanger = window,
                StatusSuccess = window,
                StatusReady = window,
                ChartMuted = windowText,
                ChartGrid = windowText,
                ChartPointOutline = window
            };
        }

        private static Color Hex(string value)
        {
            return (Color)ColorConverter.ConvertFromString(value);
        }
    }

    internal sealed class PaletteDefinition
    {
        public string Id;
        public string DisplayName;
        public bool IsDark;
        public Color BackgroundTop;
        public Color BackgroundBottom;
        public Color Surface;
        public Color SurfaceSoft;
        public Color Border;
        public Color TextPrimary;
        public Color TextSecondary;
        public Color TextTertiary;
        public Color TableText;
        public Color AccentPrimary;
        public Color AccentInfo;
        public Color AccentInfoText;
        public Color AccentInk;
        public Color AccentPurple;
        public Color Success;
        public Color Danger;
        public Color Warning;
        public Color ButtonBackground;
        public Color ButtonText;
        public Color PrimaryButton;
        public Color PrimaryButtonText;
        public Color PrimaryButtonBorder;
        public Color ProgressTrack;
        public Color ScheduleBackground;
        public Color PhaseInactive;
        public Color TextOnAccent;
        public Color FooterText;
        public Color AddButtonText;
        public Color AddButtonBorder;
        public Color SafetyBackground;
        public Color SafetyBorder;
        public Color SafetyText;
        public Color RowEven;
        public Color RowOdd;
        public Color RowBorder;
        public Color RequiredBackground;
        public Color RequiredBorder;
        public Color RemoveBackground;
        public Color RemoveBorder;
        public Color RemoveText;
        public Color DangerActionText;
        public Color DangerActionBorder;
        public Color GridLine;
        public Color AlternatingRow;
        public Color Selection;
        public Color SelectionText;
        public Color Focus;
        public Color StatusLive;
        public Color StatusWarning;
        public Color StatusDanger;
        public Color StatusSuccess;
        public Color StatusReady;
        public Color ChartMuted;
        public Color ChartGrid;
        public Color ChartPointOutline;
    }
}
