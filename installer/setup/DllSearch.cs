using System;
using System.Runtime.InteropServices;

namespace Rewindle.Setup
{
    // Where Windows looks for a DLL that this process asks for by name. By default the program's own folder comes first, and Setup
    // is usually started from Downloads, where any web page can leave a file next to it: a DLL named like one Windows, .NET or
    // WPF loads by name while Setup runs (dwmapi.dll, bcrypt.dll, the C++ runtime, the shader compiler) would then run inside
    // Setup, which chooses what Windows' permission prompt starts. Program.Main restricts the search to System32 before anything else runs. The program's own folder is never
    // added back (no LOAD_LIBRARY_SEARCH_APPLICATION_DIR or _DEFAULT_DIRS), and neither is the folder the WebView2 libraries are
    // unpacked to: WebViewLibraries loads WebView2Loader.dll by its full path, and a DLL loaded by full path finds its own
    // dependencies in System32. The .NET runtime and WPF load their own files by full path, as before.
    internal static class DllSearch
    {
        private const uint LoadLibrarySearchSystem32 = 0x00000800;

        // True when Windows accepted the restriction (Windows 8 and later; Windows 7 needs update KB2533623).
        public static bool RestrictToSystem32()
        {
            try
            {
                return SetDefaultDllDirectories(LoadLibrarySearchSystem32);
            }
            catch (EntryPointNotFoundException)
            {
                return false;
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetDefaultDllDirectories(uint directoryFlags);
    }
}
