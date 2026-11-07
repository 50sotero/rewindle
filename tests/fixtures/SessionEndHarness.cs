using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace ResticBackuper.Dashboard
{
    // A stand-in for the dashboard window, wired the way DashboardWindow is: the application shuts down only when asked
    // (OnExplicitShutdown, as Program sets it), closing the window hides it unless allowClose is set, WPF's SessionEnding
    // sets allowClose, and the session-end guard is installed from SourceInitialized. The window opens off screen, without
    // focus or a taskbar button. Every step is written to the log file named on the command line, for the test to follow.
    internal sealed class SessionEndHarnessWindow : Window
    {
        private readonly string logPath;
        private bool allowClose;
        private SessionEndGuard guard;

        public SessionEndHarnessWindow(string logPath)
        {
            this.logPath = logPath;
            Title = "Rewindle session-end harness";
            Width = 200;
            Height = 100;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = -32000;
            Top = -32000;
            ShowActivated = false;
            ShowInTaskbar = false;
            Application.Current.SessionEnding += delegate
            {
                allowClose = true;
                Log("wpf-session-ending");
            };
            SourceInitialized += delegate
            {
                guard = SessionEndGuard.TryInstall(Application.Current, OnSessionEnded, OnSessionEndCancelled);
                Log("ready thread=" + GetCurrentThreadId() +
                    " window=" + new WindowInteropHelper(this).Handle.ToInt64() +
                    " guard=" + (guard != null ? "yes" : "no"));
            };
            Closing += OnClosing;
            Closed += delegate
            {
                Log("closed");
                Application.Current.Shutdown();
            };
        }

        private void OnSessionEnded()
        {
            Log("session-ended");
            allowClose = true;
            Close();
            Application.Current.Shutdown();
        }

        private void OnSessionEndCancelled()
        {
            Log("session-end-cancelled");
            allowClose = false;
        }

        private void OnClosing(object sender, CancelEventArgs args)
        {
            if (!allowClose)
            {
                args.Cancel = true;
                Hide();
                Log("hidden");
            }
            else
            {
                Log("closing");
            }
        }

        public void Log(string line)
        {
            File.AppendAllText(logPath, line + "\n");
        }

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();
    }

    internal static class SessionEndHarness
    {
        [STAThread]
        public static int Main(string[] args)
        {
            Application application = new Application();
            application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            SessionEndHarnessWindow window = new SessionEndHarnessWindow(Path.GetFullPath(args[0]));
            application.Exit += delegate { window.Log("exit"); };
            application.Run(window);
            window.Log("run-returned");
            return 0;
        }
    }
}
