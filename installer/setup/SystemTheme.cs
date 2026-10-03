using System;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace Rewindle.Setup
{
    // How Windows is set up for the person at this moment: dark or light apps, High Contrast, and whether animations are wanted.
    // The wizard follows all three (it is told at start and again whenever Windows reports a change), and so does the plain
    // native screen shown before the wizard can start.
    internal sealed class ThemeState
    {
        public bool Dark;
        public bool HighContrast;
        public bool ReducedMotion;

        public bool SameAs(ThemeState other)
        {
            return other != null && Dark == other.Dark && HighContrast == other.HighContrast && ReducedMotion == other.ReducedMotion;
        }
    }

    internal static class SystemTheme
    {
        private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

        // Set only by the tests that open the window, to see it in a theme other than the one Windows is set to.
        internal static ThemeState Override { get; set; }

        public static ThemeState Read()
        {
            if (Override != null)
            {
                return Override;
            }
            ThemeState state = new ThemeState();
            state.HighContrast = SystemParameters.HighContrast;
            // "Show animations in Windows" off is the Windows setting for reduced motion.
            state.ReducedMotion = !SystemParameters.ClientAreaAnimation;
            if (state.HighContrast)
            {
                // A High Contrast theme names its own colors; a dark one has a dark window color.
                Color window = SystemColors.WindowColor;
                state.Dark = (0.2126 * window.R + 0.7152 * window.G + 0.0722 * window.B) < 128;
            }
            else
            {
                state.Dark = AppsUseDarkTheme();
            }
            return state;
        }

        private static bool AppsUseDarkTheme()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(PersonalizeKey, false))
                {
                    if (key == null)
                    {
                        return false;
                    }
                    object value = key.GetValue("AppsUseLightTheme");
                    return value is int && (int)value == 0;
                }
            }
            catch (Exception)
            {
                // Without a readable setting the light theme is the safe one (Windows 10 before 1809 has no dark mode).
                return false;
            }
        }
    }
}
