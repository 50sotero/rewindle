using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace ResticBackuper.Dashboard
{
    internal static class Program
    {
        private static Mutex instanceMutex;
        private static EventWaitHandle showEvent;
        // One error box at a time, and not another within a minute of the last, whatever fails: something that goes wrong on
        // the one-second refresh would otherwise stack a box on every tick.
        private static readonly TimeSpan ErrorBoxInterval = TimeSpan.FromSeconds(60);
        private static readonly object errorBoxGate = new object();
        private static bool errorBoxOpen;
        private static DateTime lastErrorBoxUtc = DateTime.MinValue;

        [STAThread]
        private static int Main(string[] args)
        {
            AppOptions options;
            try
            {
                options = AppOptions.Parse(args);
            }
            catch (ArgumentException error)
            {
                ReportArgumentError(args, error.Message);
                return 2;
            }

            // A windowed build has no console to print to, so --help and --version answer in a box, and nothing else runs.
            if (options.ShowHelp)
            {
                ReportInformation(args, HelpText(), MessageBoxImage.Information);
                return 0;
            }
            if (options.ShowVersion)
            {
                ReportInformation(args, VersionText(), MessageBoxImage.Information);
                return 0;
            }

            // Which engine this process reports on, chosen once and before anything reads an engine path: the one whose
            // protected install root under Program Files holds a configuration (Rewindle first when both do), or the one
            // --engine names. Read-only. With neither installed Rewindle is chosen and the page explains that nothing is
            // installed; nothing here creates or changes anything.
            EngineSelection engine = EngineProfile.Select(options.EngineOverride);
            EngineProfile.Activate(engine.Profile);
            options.UseEngine(engine);

            if (options.SelfTest)
            {
                try
                {
                    TelemetryReader reader = new TelemetryReader(options.StateDirectory, false);
                    string selfTestJson = reader.SelfTestJson();
                    if (!string.IsNullOrEmpty(options.SelfTestOutput))
                    {
                        File.WriteAllText(options.SelfTestOutput, selfTestJson);
                    }
                    else
                    {
                        Console.WriteLine(selfTestJson);
                    }
                    return 0;
                }
                catch (Exception error)
                {
                    Console.Error.WriteLine(error.ToString());
                    return 1;
                }
            }

            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            if (principal.IsInRole(WindowsBuiltInRole.Administrator))
            {
                MessageBox.Show(
                    "This dashboard intentionally runs without administrator privileges. " +
                    "Protected folder changes and manual backup requests ask for Windows approval when needed. " +
                    "Please launch it normally instead of using Run as administrator.",
                    "Rewindle",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return 3;
            }

            string mutexName = options.UseIsolatedPresentationStore
                ? engine.Profile.PresentationMutexName
                : engine.Profile.InstanceMutexName;
            string showEventName = options.UseIsolatedPresentationStore
                ? engine.Profile.PresentationShowEventName
                : engine.Profile.ShowEventName;
            if (options.UseIsolatedPresentationStore)
            {
                DashboardThemeManager.UseSettingsRootForSmokeTesting(
                    Path.Combine(
                        engine.Profile.IsolatedPresentationDirectory(),
                        "theme"));
            }

            bool createdNew;
            instanceMutex = new Mutex(true, mutexName, out createdNew);
            if (!createdNew)
            {
                // A second quiet start (the logon task's --minimized, say) has nothing to show, so it must not bring the first
                // one's window up. Any other launch asks the running copy to show itself.
                if (!options.StartMinimized)
                {
                    try
                    {
                        using (EventWaitHandle existing = EventWaitHandle.OpenExisting(showEventName))
                        {
                            existing.Set();
                        }
                    }
                    catch (WaitHandleCannotBeOpenedException)
                    {
                    }
                }
                return 0;
            }

            // From here on this process is the running copy. Whatever goes wrong is written to crash.log (see CrashLog), and a
            // fault that would end the process says so first instead of vanishing.
            CrashLog.UseIsolatedLocation(options.UseIsolatedPresentationStore);
            AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
            TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
            try
            {
                showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, showEventName);
                Application application = new Application();
                application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
                application.DispatcherUnhandledException += OnDispatcherUnhandledException;

                DashboardWindow window = new DashboardWindow(options, showEvent);
                application.Run(window);
                return 0;
            }
            catch (Exception error)
            {
                CrashLog.Write("Start-up or main loop", error);
                ShowErrorBox("Rewindle could not start, or stopped unexpectedly.", error, true);
                return 1;
            }
            finally
            {
                ReleaseInstance();
            }
        }

        // The single-instance handles are given back whichever way the run ended. The mutex is released only by the thread that
        // owns it (this one, which took it when it was created), and only if it still does.
        private static void ReleaseInstance()
        {
            try
            {
                if (showEvent != null)
                {
                    showEvent.Dispose();
                }
            }
            catch (Exception)
            {
            }
            try
            {
                if (instanceMutex != null)
                {
                    instanceMutex.ReleaseMutex();
                }
            }
            catch (ApplicationException)
            {
                // Not owned by this thread: there is nothing to release.
            }
            catch (Exception)
            {
            }
            try
            {
                if (instanceMutex != null)
                {
                    instanceMutex.Dispose();
                }
            }
            catch (Exception)
            {
            }
        }

        // A windowed build has no console, so an unknown option used to end the process with exit code 2 and no word. Say what
        // was wrong. A scripted run (--self-test reads stderr) keeps writing to the console instead of waiting on a box.
        private static void ReportArgumentError(string[] args, string message)
        {
            if (IsScriptedRun(args))
            {
                Console.Error.WriteLine(message);
                return;
            }
            try
            {
                MessageBox.Show(
                    "Rewindle could not start.\n\n" + message +
                        "\n\nStart it without options for normal use, or with --help to see the options.",
                    "Rewindle",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
            catch (Exception)
            {
                Console.Error.WriteLine(message);
            }
        }

        // --help and --version: a box for a person, the console for a scripted run (see ReportArgumentError).
        private static void ReportInformation(string[] args, string text, MessageBoxImage image)
        {
            if (IsScriptedRun(args))
            {
                Console.WriteLine(text);
                return;
            }
            try
            {
                MessageBox.Show(text, "Rewindle", MessageBoxButton.OK, image);
            }
            catch (Exception)
            {
                Console.WriteLine(text);
            }
        }

        private static bool IsScriptedRun(string[] args)
        {
            foreach (string argument in args)
            {
                if (string.Equals(argument, "--self-test", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            return false;
        }

        // The version the app is released as: the informational version the build takes from the repository's VERSION file
        // ("0.2.0-alpha.1"), or the numeric assembly version when a build left that attribute out.
        internal static string DisplayVersion()
        {
            Assembly assembly = typeof(Program).Assembly;
            AssemblyInformationalVersionAttribute informational = (AssemblyInformationalVersionAttribute)Attribute.GetCustomAttribute(
                assembly,
                typeof(AssemblyInformationalVersionAttribute));
            if (informational != null && !string.IsNullOrWhiteSpace(informational.InformationalVersion))
            {
                return informational.InformationalVersion.Trim();
            }
            Version version = assembly.GetName().Version;
            return version == null ? "unknown" : version.ToString();
        }

        private static string VersionText()
        {
            AssemblyCopyrightAttribute copyright = (AssemblyCopyrightAttribute)Attribute.GetCustomAttribute(
                typeof(Program).Assembly,
                typeof(AssemblyCopyrightAttribute));
            return "Rewindle " + DisplayVersion() + "\n" +
                (copyright == null || string.IsNullOrWhiteSpace(copyright.Copyright) ? string.Empty : copyright.Copyright + "\n") +
                "MIT License. Powered by Restic.";
        }

        private static string HelpText()
        {
            return "Rewindle " + DisplayVersion() + "\n\n" +
                "Shows the state of your verified backups. Started without options, it opens the dashboard.\n\n" +
                "Options:\n" +
                "--minimized\n    Start in the notification area without opening the window.\n" +
                "--native\n    Use the classic Windows presentation instead of the web interface.\n" +
                "--preview\n    Start the labelled backup animation preview; protected actions stay off while it runs.\n" +
                "--isolated-presentation-store\n    Keep appearance settings separate and write no run history.\n" +
                "--engine rewindle | --engine legacy\n    Report on that engine even when the other one is installed.\n" +
                "--state-dir <absolute folder>\n    Read backup status from this folder instead of the engine's own.\n" +
                "--self-test [--self-test-output <absolute file>]\n    Check the backup status files without opening a window.\n" +
                "--version\n    Show the version.\n" +
                "--help\n    Show this help.";
        }

        // An exception on the dispatcher thread that nothing handled: a refresh tick, a bridge message, a click. The dashboard
        // carries on, as it did before, but the exception is kept and the box is shown at most once a minute.
        private static void OnDispatcherUnhandledException(
            object sender,
            DispatcherUnhandledExceptionEventArgs args)
        {
            CrashLog.Write("Dispatcher", args.Exception);
            ShowErrorBox("The backup dashboard hit an unexpected display error.", args.Exception, false);
            args.Handled = true;
        }

        // An exception on any other thread that nothing handled. When it is the kind that ends the process, the box is the
        // only word anyone gets, so it is shown whatever was shown a moment ago.
        private static void OnUnhandledException(object sender, UnhandledExceptionEventArgs args)
        {
            Exception error = args.ExceptionObject as Exception;
            CrashLog.Write(
                args.IsTerminating ? "Unhandled exception (the process is ending)" : "Unhandled exception",
                error ?? new InvalidOperationException(Convert.ToString(args.ExceptionObject, CultureInfo.InvariantCulture)));
            if (args.IsTerminating)
            {
                ShowErrorBox("Rewindle has to close because of an unexpected error.", error, true);
            }
        }

        // A task whose exception nobody observed. It no longer ends the process, so it is kept and marked as seen.
        private static void OnUnobservedTaskException(object sender, UnobservedTaskExceptionEventArgs args)
        {
            CrashLog.Write("Unobserved task exception", args.Exception);
            args.SetObserved();
        }

        // One box at a time. With force off it is also held back for a minute after the last, so a fault that repeats shows
        // once; the log has every occurrence either way. Nothing here may throw: it runs while something else is failing.
        private static void ShowErrorBox(string headline, Exception error, bool force)
        {
            lock (errorBoxGate)
            {
                DateTime now = DateTime.UtcNow;
                if (errorBoxOpen ||
                    (!force && now >= lastErrorBoxUtc && now - lastErrorBoxUtc < ErrorBoxInterval))
                {
                    return;
                }
                errorBoxOpen = true;
            }
            try
            {
                string reason = error == null || string.IsNullOrWhiteSpace(error.Message)
                    ? string.Empty
                    : "\n\n" + error.Message;
                string location = CrashLog.FilePath;
                MessageBox.Show(
                    headline + reason +
                        (string.IsNullOrEmpty(location)
                            ? string.Empty
                            : "\n\nThe details were saved to:\n" + location) +
                        "\n\nScheduled backups run separately and are not affected.",
                    "Rewindle",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
            catch (Exception)
            {
            }
            finally
            {
                lock (errorBoxGate)
                {
                    errorBoxOpen = false;
                    lastErrorBoxUtc = DateTime.UtcNow;
                }
            }
        }
    }

    public sealed class AppOptions
    {
        public string StateDirectory { get; private set; }
        public bool StartMinimized { get; private set; }
        public bool Preview { get; private set; }
        public bool Demo { get { return false; } }
        public bool UseIsolatedPresentationStore { get; private set; }
        public bool UseNativePresentation { get; private set; }
        public bool SelfTest { get; private set; }
        public string SelfTestOutput { get; private set; }
        // --help or --version: say so and do nothing else.
        public bool ShowHelp { get; private set; }
        public bool ShowVersion { get; private set; }
        // "rewindle" or "legacy" when --engine chose the engine, otherwise null (the install roots choose it).
        public string EngineOverride { get; private set; }
        // The engine chosen at start-up (see Program.Main), with where each engine was looked for.
        internal EngineSelection Engine { get; private set; }

        private AppOptions()
        {
        }

        // Called once the engine is chosen: --state-dir stays as given, otherwise the engine's own protected state
        // folder under ProgramData is used.
        internal void UseEngine(EngineSelection engine)
        {
            if (engine == null)
            {
                throw new ArgumentNullException("engine");
            }
            Engine = engine;
            if (string.IsNullOrEmpty(StateDirectory))
            {
                StateDirectory = engine.Profile.StateDirectory();
            }
        }

        public static AppOptions Parse(string[] args)
        {
            AppOptions result = new AppOptions();
            for (int index = 0; index < args.Length; index++)
            {
                string argument = args[index];
                if (string.Equals(argument, "--minimized", StringComparison.OrdinalIgnoreCase))
                {
                    result.StartMinimized = true;
                }
                else if (string.Equals(argument, "--preview", StringComparison.OrdinalIgnoreCase))
                {
                    result.Preview = true;
                }
                else if (string.Equals(argument, "--isolated-presentation-store", StringComparison.OrdinalIgnoreCase))
                {
                    result.UseIsolatedPresentationStore = true;
                }
                else if (string.Equals(argument, "--native", StringComparison.OrdinalIgnoreCase))
                {
                    result.UseNativePresentation = true;
                }
                else if (string.Equals(argument, "--self-test", StringComparison.OrdinalIgnoreCase))
                {
                    result.SelfTest = true;
                }
                else if (string.Equals(argument, "--help", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(argument, "-h", StringComparison.Ordinal) ||
                    string.Equals(argument, "-?", StringComparison.Ordinal) ||
                    string.Equals(argument, "/?", StringComparison.Ordinal))
                {
                    result.ShowHelp = true;
                }
                else if (string.Equals(argument, "--version", StringComparison.OrdinalIgnoreCase))
                {
                    result.ShowVersion = true;
                }
                else if (string.Equals(argument, "--self-test-output", StringComparison.OrdinalIgnoreCase))
                {
                    if (index + 1 >= args.Length)
                    {
                        throw new ArgumentException("--self-test-output requires an absolute file path");
                    }
                    string path = args[++index];
                    if (!Path.IsPathRooted(path))
                    {
                        throw new ArgumentException("--self-test-output must be absolute");
                    }
                    result.SelfTestOutput = FullPathArgument("--self-test-output", path);
                }
                else if (string.Equals(argument, "--engine", StringComparison.OrdinalIgnoreCase))
                {
                    if (index + 1 >= args.Length)
                    {
                        throw new ArgumentException(
                            "--engine requires \"" + EngineProfile.RewindleId + "\" or \"" + EngineProfile.LegacyId + "\"");
                    }
                    if (result.EngineOverride != null)
                    {
                        throw new ArgumentException("--engine can be given only once");
                    }
                    // FromId refuses anything that is not one of the two built-in engines.
                    result.EngineOverride = EngineProfile.FromId(args[++index]).Id;
                }
                else if (string.Equals(argument, "--state-dir", StringComparison.OrdinalIgnoreCase))
                {
                    if (index + 1 >= args.Length)
                    {
                        throw new ArgumentException("--state-dir requires an absolute directory path");
                    }
                    string path = args[++index];
                    if (!Path.IsPathRooted(path))
                    {
                        throw new ArgumentException("--state-dir must be absolute");
                    }
                    result.StateDirectory = FullPathArgument("--state-dir", path);
                }
                else
                {
                    throw new ArgumentException("Unknown dashboard argument: " + argument);
                }
            }
            return result;
        }

        // A path Windows cannot use ("C:\a:b", one that is too long) is a bad argument like any other, so it is reported as one
        // instead of ending the start-up with an exception nobody sees.
        private static string FullPathArgument(string option, string path)
        {
            try
            {
                return Path.GetFullPath(path);
            }
            catch (Exception error)
            {
                if (error is ArgumentException || error is NotSupportedException || error is PathTooLongException)
                {
                    throw new ArgumentException(option + " is not a usable path: " + error.Message);
                }
                throw;
            }
        }
    }
}
