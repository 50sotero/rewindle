using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Principal;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Rewindle.Setup
{
    internal static class Program
    {
        private const string InstanceName = @"Local\RewindleSetup.Instance";
        private const string ShowName = @"Local\RewindleSetup.Show";
        private const string IconResource = "REWINDLE_ICON";

        private static SetupWindow window;

        [STAThread]
        private static int Main(string[] args)
        {
            foreach (string argument in args)
            {
                if (string.Equals(argument, "--version", StringComparison.OrdinalIgnoreCase))
                {
                    MessageBox.Show("Rewindle Setup " + ProductVersion(), "Rewindle Setup", MessageBoxButton.OK, MessageBoxImage.Information);
                    return 0;
                }
                if (string.Equals(argument, "--help", StringComparison.OrdinalIgnoreCase) || argument == "-?" || argument == "/?")
                {
                    MessageBox.Show(
                        "Rewindle Setup installs, repairs or removes Rewindle with a few guided steps.\n\n" +
                            "It takes no options. To install from a console instead, unpack the release ZIP and run Install.cmd.\n\n" +
                            "--version\n    Show the version of Rewindle this setup installs.",
                        "Rewindle Setup",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                    return 0;
                }
            }

            // One Setup at a time for each person: a second start brings the first one forward.
            bool createdNew;
            Mutex instance = new Mutex(true, InstanceName, out createdNew);
            if (!createdNew)
            {
                try
                {
                    using (EventWaitHandle existing = EventWaitHandle.OpenExisting(ShowName))
                    {
                        existing.Set();
                    }
                }
                catch (WaitHandleCannotBeOpenedException)
                {
                }
                instance.Dispose();
                return 0;
            }

            SetupWorkspace workspace = null;
            try
            {
                string temp = Path.GetTempPath();
                SetupLog.Initialize(Path.Combine(temp, "Rewindle-Setup.log"));
                SetupLog.Write("Rewindle Setup " + ProductVersion() + " starting.");
                SetupWorkspace.SweepStale(temp);
                workspace = SetupWorkspace.Create();
                SetupLog.Write("Working in " + workspace.Root);

                // The WebView2 libraries are unpacked and made findable before any code that mentions a WebView2 type runs.
                workspace.ExtractLibraries();
                WebViewLibraries.Install(workspace.ResolvedLibraryFolder);
                workspace.ExtractWeb();
                // The release bundle is large; it unpacks in the background while the first page opens.
                workspace.EnsureBundleExtracted();

                return RunWindow(workspace);
            }
            catch (Exception error)
            {
                SetupLog.Write("Setup could not start", error);
                ShowError("Rewindle Setup could not start.", error.Message);
                return 1;
            }
            finally
            {
                if (workspace != null)
                {
                    workspace.Dispose();
                }
                try
                {
                    instance.ReleaseMutex();
                }
                catch (ApplicationException)
                {
                }
                instance.Dispose();
            }
        }

        // Not inlined into Main: this is the first code that needs the WebView2 assemblies, and they are found only after the
        // resolver above is in place.
        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int RunWindow(SetupWorkspace workspace)
        {
            Application application = new Application();
            application.ShutdownMode = ShutdownMode.OnMainWindowClose;
            application.DispatcherUnhandledException += OnDispatcherUnhandledException;
            AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;

            BridgeEnvironment environment = new BridgeEnvironment();
            environment.ProductVersion = ProductVersion();
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                environment.UserSid = identity.User.Value;
            }
            environment.ProgramFilesFolder = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            environment.CommonDataFolder = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            environment.Plans = new PlanRunner(workspace.InstallScriptPath, workspace.PlansFolder, TimeSpan.FromSeconds(90), TimeSpan.FromMinutes(30));
            environment.Launcher = new ShellElevatedLauncher();
            environment.EnsureBundle = workspace.EnsureBundleExtracted;
            environment.InstallScriptPath = workspace.InstallScriptPath;
            environment.BundledUninstallScriptPath = workspace.BundledUninstallScriptPath;
            environment.BundleFolder = workspace.BundleFolder;
            environment.BundleSha256 = workspace.BundleSha256;
            environment.MeasureExclusions = workspace.ReadExclusions;
            environment.CreateProgressFolder = workspace.CreateProgressFolder;

            window = new SetupWindow(workspace, environment, LoadIcon());
            using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowName))
            {
                RegisteredWaitHandle registration = ThreadPool.RegisterWaitForSingleObject(
                    show,
                    delegate(object state, bool timedOut)
                    {
                        SetupWindow current = window;
                        if (current != null)
                        {
                            current.Dispatcher.BeginInvoke(new Action(delegate { Bring(current); }));
                        }
                    },
                    null,
                    Timeout.Infinite,
                    false);
                try
                {
                    application.Run(window);
                }
                finally
                {
                    registration.Unregister(null);
                    window = null;
                }
            }
            return 0;
        }

        private static void Bring(SetupWindow target)
        {
            if (target.WindowState == WindowState.Minimized)
            {
                target.WindowState = WindowState.Normal;
            }
            target.Activate();
        }

        // The application icon, which is also embedded in the program's resources for Explorer: decoded for the window and for
        // the plain native screens. A missing or unreadable icon only means the default one.
        private static ImageSource LoadIcon()
        {
            try
            {
                using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(IconResource))
                {
                    if (resource == null)
                    {
                        return null;
                    }
                    BitmapDecoder decoder = BitmapDecoder.Create(resource, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                    BitmapFrame best = null;
                    foreach (BitmapFrame frame in decoder.Frames)
                    {
                        if (best == null || frame.PixelWidth > best.PixelWidth)
                        {
                            best = frame;
                        }
                    }
                    if (best != null)
                    {
                        best.Freeze();
                    }
                    return best;
                }
            }
            catch (Exception)
            {
                return null;
            }
        }

        public static string ProductVersion()
        {
            object[] attributes = Assembly.GetExecutingAssembly()
                .GetCustomAttributes(typeof(AssemblyInformationalVersionAttribute), false);
            if (attributes.Length > 0)
            {
                return ((AssemblyInformationalVersionAttribute)attributes[0]).InformationalVersion;
            }
            return Assembly.GetExecutingAssembly().GetName().Version.ToString();
        }

        private static void ShowError(string headline, string detail)
        {
            try
            {
                MessageBox.Show(
                    headline + "\n\n" + detail + "\n\nNothing was installed. A log of what happened is at " + SetupLog.FilePath + ".",
                    "Rewindle Setup",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
            catch (Exception)
            {
            }
        }

        private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs args)
        {
            SetupLog.Write("Unhandled error on the UI thread", args.Exception);
            args.Handled = true;
            ShowError("Rewindle Setup ran into a problem and has to close.", args.Exception.Message);
            Application.Current.Shutdown(1);
        }

        private static void OnUnhandledException(object sender, UnhandledExceptionEventArgs args)
        {
            SetupLog.Write("Unhandled error", args.ExceptionObject as Exception);
        }
    }
}
