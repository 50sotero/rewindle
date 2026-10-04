using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Rewindle.Setup
{
    // Makes the WebView2 libraries that travel inside the setup program loadable from the folder they were unpacked to (its
    // resolved path, where SetupWorkspace holds them). The managed libraries are found by an AssemblyResolve handler (nothing next
    // to the program's own file is trusted or needed), and WebView2Loader.dll, which the managed library asks for by name, is
    // loaded by its full path first so that name resolves to it. The folder is not added to the DLL search order: it is in the
    // person's temporary folder, where another program could add a DLL that Windows would then find before its own. It must run
    // before the first method that mentions a WebView2 type is compiled, which is why it has no WebView2 types of its own and why
    // Program.Main calls it before anything else.
    internal static class WebViewLibraries
    {
        private static string folder;
        private static bool installed;

        public static void Install(string libraryFolder)
        {
            folder = libraryFolder;
            if (!installed)
            {
                AppDomain.CurrentDomain.AssemblyResolve += Resolve;
                installed = true;
            }
            // An empty string also takes the current folder out of the DLL search order.
            SetDllDirectory(string.Empty);
            string loader = Path.Combine(libraryFolder, "WebView2Loader.dll");
            if (LoadLibrary(loader) == IntPtr.Zero)
            {
                SetupLog.Write("WebView2Loader.dll could not be preloaded (error " + Marshal.GetLastWin32Error() + ").");
            }
        }

        private static Assembly Resolve(object sender, ResolveEventArgs args)
        {
            string name = new AssemblyName(args.Name).Name;
            if (folder != null &&
                (string.Equals(name, "Microsoft.Web.WebView2.Core", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(name, "Microsoft.Web.WebView2.Wpf", StringComparison.OrdinalIgnoreCase)))
            {
                string path = Path.Combine(folder, name + ".dll");
                if (File.Exists(path))
                {
                    return Assembly.LoadFrom(path);
                }
            }
            return null;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetDllDirectory(string path);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string path);
    }
}
