using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Microsoft.Win32;

namespace Rewindle.Setup
{
    // The Rewindle Setup window: the wizard page in a WebView2 control, and, before the page can run, the plain native screen
    // (StatusPanel) that explains a missing WebView2 Runtime and offers to install it. The web view is hardened the way the
    // dashboard's is: the page is served from a virtual host that maps to the unpacked wizard folder and nowhere else, every other
    // address is refused (navigation, new windows, downloads, permission prompts, external schemes, requests), developer tools
    // and browser shortcuts are off, and the only way in or out is the message bridge (SetupBridge), which has a fixed list of
    // commands and checks what comes with each.
    internal sealed class SetupWindow : Window, IBridgeServices
    {
        private static readonly double[] ZoomSteps = { 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0 };

        private readonly SetupWorkspace workspace;
        private readonly SetupBridge bridge;
        private readonly Grid layout = new Grid();
        private readonly StatusPanel panel = new StatusPanel();
        private readonly ImageSource icon;
        private WebView2 webView;
        private ThemeState theme;
        private bool webStarting;
        private int renderRecoveries;
        private CancellationTokenSource runtimeInstall;

        public SetupWindow(SetupWorkspace workspace, BridgeEnvironment environment, ImageSource icon)
        {
            this.workspace = workspace;
            this.icon = icon;
            bridge = new SetupBridge(this, environment);
            theme = SystemTheme.Read();

            Title = "Rewindle Setup";
            if (icon != null)
            {
                Icon = icon;
                panel.Icon = icon;
            }
            UseLayoutRounding = true;
            SnapsToDevicePixels = true;
            MinWidth = 520;
            MinHeight = 440;
            // About 960 by 680, but never more than the screen can show: at 200% display scaling a 1080p screen has room for
            // only about 520 device-independent pixels of height.
            Rect work = SystemParameters.WorkArea;
            Width = Math.Min(960, Math.Max(MinWidth, work.Width - 24));
            Height = Math.Min(680, Math.Max(MinHeight, work.Height - 24));
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            FlowDirection = FlowDirection.LeftToRight;

            layout.Children.Add(panel);
            panel.Visibility = Visibility.Collapsed;
            Content = layout;
            ApplyTheme(theme);

            SourceInitialized += delegate { SetTitleBarTheme(theme.Dark); };
            ContentRendered += OnContentRendered;
            Activated += delegate { FocusWeb(); };
            Closing += OnClosing;
            Closed += OnClosed;
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        }

        // ---- start-up ------------------------------------------------------------------------------------------------------

        private void OnContentRendered(object sender, EventArgs args)
        {
            ContentRendered -= OnContentRendered;
            Begin();
        }

        private void Begin()
        {
            if (WebViewRuntime.InstalledVersion() == null)
            {
                ShowRuntimeMissing();
                return;
            }
            StartWeb();
        }

        private async void StartWeb()
        {
            if (webStarting)
            {
                return;
            }
            webStarting = true;
            try
            {
                if (webView == null)
                {
                    webView = new WebView2();
                    webView.AllowExternalDrop = false;
                    webView.HorizontalAlignment = HorizontalAlignment.Stretch;
                    webView.VerticalAlignment = VerticalAlignment.Stretch;
                    webView.Focusable = true;
                    ApplyWebBackground();
                    layout.Children.Insert(0, webView);
                }
                panel.Visibility = Visibility.Collapsed;
                webView.Visibility = Visibility.Visible;

                Directory.CreateDirectory(workspace.WebViewDataFolder);
                CoreWebView2Environment webEnvironment =
                    await CoreWebView2Environment.CreateAsync(null, workspace.WebViewDataFolder, null);
                await webView.EnsureCoreWebView2Async(webEnvironment);
                CoreWebView2 core = webView.CoreWebView2;
                if (core == null)
                {
                    throw new InvalidOperationException("The web view started without a display surface.");
                }
                ConfigureWeb(core);
                ApplyWebBackground();
                // The pages come from memory (OnResourceRequested): no folder is mapped to the page's origin.
                core.Navigate(WebPolicy.PageAddress);
            }
            catch (Exception error)
            {
                SetupLog.Write("The web view could not start", error);
                RemoveWeb();
                if (IsRuntimeMissing(error))
                {
                    ShowRuntimeMissing();
                }
                else
                {
                    ShowFailure(
                        "Setup couldn’t open its window",
                        "The part of Windows that draws Setup’s pages didn’t start. Nothing was changed. " +
                            "Close Setup and open it again; if it keeps happening, restart your PC.",
                        error.Message);
                }
            }
            finally
            {
                webStarting = false;
            }
        }

        private static bool IsRuntimeMissing(Exception error)
        {
            if (error is WebView2RuntimeNotFoundException)
            {
                return true;
            }
            COMException interop = error as COMException;
            return interop != null && interop.ErrorCode == unchecked((int)0x80070002);
        }

        private void RemoveWeb()
        {
            WebView2 old = webView;
            webView = null;
            if (old != null)
            {
                try
                {
                    layout.Children.Remove(old);
                    old.Dispose();
                }
                catch (Exception)
                {
                }
            }
        }

        // ---- the web view's policy -----------------------------------------------------------------------------------------

        private void ConfigureWeb(CoreWebView2 core)
        {
            CoreWebView2Settings settings = core.Settings;
            settings.AreDevToolsEnabled = false;
            settings.AreDefaultContextMenusEnabled = false;
            settings.AreDefaultScriptDialogsEnabled = false;
            settings.IsStatusBarEnabled = false;
            // Ctrl+mouse wheel zooms the page. The keyboard route is the page's own: Ctrl+= / Ctrl+- / Ctrl+0 send a setZoom
            // command (see Zoom), because the accelerator keys below are off.
            settings.IsZoomControlEnabled = true;
            settings.IsGeneralAutofillEnabled = false;
            settings.IsPasswordAutosaveEnabled = false;
            settings.IsWebMessageEnabled = true;
            // Reload, print, find and the other browser shortcuts do nothing: a reload in the middle of an install would
            // throw away the page that shows it.
            settings.AreBrowserAcceleratorKeysEnabled = false;
            try
            {
                settings.IsSwipeNavigationEnabled = false;
                settings.IsPinchZoomEnabled = false;
            }
            catch (Exception)
            {
                // Older runtimes do not have these settings.
            }

            core.NavigationStarting += OnNavigationStarting;
            core.NavigationCompleted += OnNavigationCompleted;
            core.NewWindowRequested += delegate(object sender, CoreWebView2NewWindowRequestedEventArgs args) { args.Handled = true; };
            core.DownloadStarting += delegate(object sender, CoreWebView2DownloadStartingEventArgs args)
            {
                args.Cancel = true;
                args.Handled = true;
            };
            core.PermissionRequested += delegate(object sender, CoreWebView2PermissionRequestedEventArgs args)
            {
                args.State = CoreWebView2PermissionState.Deny;
                args.Handled = true;
            };
            core.LaunchingExternalUriScheme += delegate(object sender, CoreWebView2LaunchingExternalUriSchemeEventArgs args)
            {
                args.Cancel = true;
            };
            core.BasicAuthenticationRequested += delegate(object sender, CoreWebView2BasicAuthenticationRequestedEventArgs args)
            {
                args.Cancel = true;
            };
            core.ServerCertificateErrorDetected += delegate(object sender, CoreWebView2ServerCertificateErrorDetectedEventArgs args)
            {
                args.Action = CoreWebView2ServerCertificateErrorAction.Cancel;
            };
            core.ContextMenuRequested += delegate(object sender, CoreWebView2ContextMenuRequestedEventArgs args) { args.Handled = true; };
            core.WebResourceRequested += OnResourceRequested;
            core.WebMessageReceived += OnWebMessageReceived;
            core.ProcessFailed += OnProcessFailed;
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
            try
            {
                core.Profile.PreferredColorScheme = theme.Dark
                    ? CoreWebView2PreferredColorScheme.Dark
                    : CoreWebView2PreferredColorScheme.Light;
            }
            catch (Exception)
            {
                // An older runtime has no profile API. The page still pins its own theme from the first message.
            }
        }

        private void OnNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs args)
        {
            if (!WebPolicy.IsAllowedUri(args.Uri))
            {
                args.Cancel = true;
            }
        }

        private void OnNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs args)
        {
            if (args.IsSuccess)
            {
                FocusWeb();
                return;
            }
            if (args.WebErrorStatus == CoreWebView2WebErrorStatus.OperationCanceled)
            {
                return;
            }
            SetupLog.Write("The wizard page did not load: " + args.WebErrorStatus);
            ShowFailure(
                "Setup’s pages didn’t load",
                "Setup couldn’t show its first page. Nothing was changed. Close Setup and open it again.",
                "Status: " + args.WebErrorStatus);
        }

        // Every request the page makes is answered here: the wizard's own pages from memory (WebContent), and nothing else.
        private void OnResourceRequested(object sender, CoreWebView2WebResourceRequestedEventArgs args)
        {
            CoreWebView2 core = sender as CoreWebView2;
            if (core == null)
            {
                return;
            }
            string address = args.Request == null ? string.Empty : args.Request.Uri;
            if (!WebPolicy.IsAllowedUri(address))
            {
                args.Response = core.Environment.CreateWebResourceResponse(new MemoryStream(), 403, "Blocked", "Content-Type: text/plain");
                return;
            }
            if (!string.Equals(args.Request.Method, "GET", StringComparison.OrdinalIgnoreCase))
            {
                args.Response = core.Environment.CreateWebResourceResponse(new MemoryStream(), 405, "Method Not Allowed", "Content-Type: text/plain");
                return;
            }
            byte[] content;
            string contentType;
            if (!workspace.Web.TryGet(new Uri(address).AbsolutePath, out content, out contentType))
            {
                args.Response = core.Environment.CreateWebResourceResponse(new MemoryStream(), 404, "Not Found", "Content-Type: text/plain");
                return;
            }
            args.Response = core.Environment.CreateWebResourceResponse(
                new MemoryStream(content, false),
                200,
                "OK",
                "Content-Type: " + contentType + "\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store");
        }

        private void OnWebMessageReceived(object sender, CoreWebView2WebMessageReceivedEventArgs args)
        {
            if (!WebPolicy.IsAllowedUri(args.Source))
            {
                return;
            }
            string json = args.WebMessageAsJson;
            if (string.IsNullOrEmpty(json) || json.Length > BridgeProtocol.MaximumMessageLength)
            {
                return;
            }
            bridge.Receive(json);
        }

        private void OnProcessFailed(object sender, CoreWebView2ProcessFailedEventArgs args)
        {
            CoreWebView2ProcessFailedKind kind = args.ProcessFailedKind;
            SetupLog.Write("The web view reported a failure: " + kind);
            if (kind == CoreWebView2ProcessFailedKind.RenderProcessUnresponsive)
            {
                return;
            }
            // An install or uninstall that hasn't asked Windows yet is cancelled first: the reloaded page has no record of it and
            // would ignore its later prompt and progress.
            bool busy = bridge.StopForLostPage();
            // A page that crashed is reloaded once, on its own, unless an install is running (the reload would lose the page
            // that shows it, and the person could start a second one).
            if (kind == CoreWebView2ProcessFailedKind.RenderProcessExited && renderRecoveries == 0 && !busy)
            {
                renderRecoveries++;
                try
                {
                    ((CoreWebView2)sender).Reload();
                    return;
                }
                catch (Exception)
                {
                }
            }
            ShowFailure(
                "Setup’s window stopped working",
                busy
                    ? "The installation that was already running is not affected, and keeps going. Close this window when it has finished."
                    : "Nothing was changed. Close Setup and open it again.",
                "Reason: " + kind);
        }

        // ---- the native screens --------------------------------------------------------------------------------------------

        private void ShowPanel(StatusContent content)
        {
            if (webView != null)
            {
                webView.Visibility = Visibility.Collapsed;
            }
            panel.Visibility = Visibility.Visible;
            panel.Show(content);
        }

        private void ShowFailure(string title, string body, string detail)
        {
            StatusContent content = new StatusContent();
            content.Title = title;
            content.Body = body;
            content.Detail = detail;
            content.Buttons.Add(new StatusButton("Close", true, delegate { Close(); }));
            ShowPanel(content);
        }

        private void ShowRuntimeMissing()
        {
            StatusContent content = new StatusContent();
            content.Title = "Setup needs one more thing";
            content.Body =
                "Rewindle Setup shows its pages with Microsoft’s free WebView2 Runtime, which isn’t on this PC yet. " +
                "Setup can download it from Microsoft, check Microsoft’s signature on it and install it. " +
                "It takes about a minute and doesn’t change any of your files.";
            content.Detail = "About 2 MB from Microsoft. Windows may ask for permission.";
            content.Buttons.Add(new StatusButton("Install it now", true, InstallRuntime));
            content.Buttons.Add(new StatusButton("Close", false, delegate { Close(); }));
            content.Link = new StatusButton(
                "Download it from Microsoft’s website instead",
                false,
                delegate { OpenAddress(WebViewRuntime.BootstrapperAddress); });
            ShowPanel(content);
        }

        private void InstallRuntime()
        {
            CancellationTokenSource cancellation = new CancellationTokenSource();
            runtimeInstall = cancellation;
            ShowRuntimeProgress("Downloading the runtime from Microsoft…", -1);
            Task.Factory.StartNew(
                delegate
                {
                    Exception failure = null;
                    try
                    {
                        WebViewRuntime.Install(
                            workspace.Root,
                            cancellation.Token,
                            delegate(string text, double fraction)
                            {
                                Dispatcher.BeginInvoke(new Action(delegate { ShowRuntimeProgress(text, fraction); }));
                            });
                    }
                    catch (Exception error)
                    {
                        failure = error;
                    }
                    Dispatcher.BeginInvoke(new Action(delegate { OnRuntimeInstalled(failure); }));
                },
                CancellationToken.None,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default);
        }

        private void ShowRuntimeProgress(string text, double fraction)
        {
            StatusContent content = new StatusContent();
            content.Title = "Getting the display component";
            content.Body = text;
            content.Detail = "You can keep this window open while it works.";
            content.Progress = fraction;
            ShowPanel(content);
        }

        private void OnRuntimeInstalled(Exception failure)
        {
            if (failure == null)
            {
                StartWeb();
                return;
            }
            string message;
            if (failure is ElevationDeclinedException)
            {
                message = "Windows permission wasn’t given, so the runtime wasn’t installed.";
            }
            else if (failure is SetupFailure)
            {
                message = failure.Message;
            }
            else if (failure is OperationCanceledException)
            {
                message = "The installation was cancelled.";
            }
            else
            {
                SetupLog.Write("Installing the WebView2 Runtime failed", failure);
                message = "The runtime couldn’t be installed.";
            }
            StatusContent content = new StatusContent();
            content.Title = "The runtime wasn’t installed";
            content.Body = message;
            content.Detail = "Nothing else on this PC was changed.";
            content.Buttons.Add(new StatusButton("Try again", true, InstallRuntime));
            content.Buttons.Add(new StatusButton("Close", false, delegate { Close(); }));
            content.Link = new StatusButton(
                "Download it from Microsoft’s website instead",
                false,
                delegate { OpenAddress(WebViewRuntime.BootstrapperAddress); });
            ShowPanel(content);
        }

        // ---- theme ---------------------------------------------------------------------------------------------------------

        private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs args)
        {
            // Raised on a thread of the system's own; the change is read and applied on this window's.
            Dispatcher.BeginInvoke(new Action(RefreshTheme));
        }

        private void RefreshTheme()
        {
            ThemeState current = SystemTheme.Read();
            if (current.SameAs(theme))
            {
                return;
            }
            theme = current;
            ApplyTheme(current);
            bridge.ThemeChanged();
        }

        private void ApplyTheme(ThemeState state)
        {
            theme = state;
            StatusPalette palette = StatusPalette.For(state);
            Background = palette.Page;
            panel.ApplyTheme(state);
            SetTitleBarTheme(state.Dark);
            ApplyWebBackground();
            try
            {
                if (webView != null && webView.CoreWebView2 != null)
                {
                    webView.CoreWebView2.Profile.PreferredColorScheme = state.Dark
                        ? CoreWebView2PreferredColorScheme.Dark
                        : CoreWebView2PreferredColorScheme.Light;
                }
            }
            catch (Exception)
            {
            }
        }

        // What the web view shows before the page has painted: the page's own background, so a dark PC never sees a white flash.
        private void ApplyWebBackground()
        {
            if (webView == null)
            {
                return;
            }
            Color background = StatusPalette.For(theme).PageColor;
            webView.DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, background.R, background.G, background.B);
        }

        private void SetTitleBarTheme(bool dark)
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            if (handle == IntPtr.Zero)
            {
                return;
            }
            int value = dark ? 1 : 0;
            try
            {
                // 20 is the documented attribute (Windows 10 2004 and later), 19 the one earlier 20H1 builds used.
                if (DwmSetWindowAttribute(handle, 20, ref value, sizeof(int)) != 0)
                {
                    DwmSetWindowAttribute(handle, 19, ref value, sizeof(int));
                }
            }
            catch (Exception)
            {
            }
        }

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        private void FocusWeb()
        {
            WebView2 view = webView;
            if (view != null && view.Visibility == Visibility.Visible && IsActive)
            {
                try
                {
                    view.Focus();
                }
                catch (Exception)
                {
                }
            }
        }

        // ---- closing -------------------------------------------------------------------------------------------------------

        private void OnClosing(object sender, CancelEventArgs args)
        {
            if (bridge.IsBusyPastCancel)
            {
                // The installer is an elevated process this window cannot stop, and it reads the files Setup unpacked and
                // deletes when it exits, so the window stays until it has finished.
                MessageBox.Show(
                    this,
                    "Rewindle is still being installed or removed. Please wait until it has finished, then close this window.",
                    "Rewindle Setup",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                args.Cancel = true;
                return;
            }
            // Microsoft's WebView2 installer can't be stopped once it has started, and it runs from the folder Setup deletes
            // on exit. Cancel what hasn't started yet, then look again: if it started meanwhile, the window waits for it.
            CancellationTokenSource install = runtimeInstall;
            if (install != null)
            {
                if (!WebViewRuntime.BootstrapperRunning)
                {
                    install.Cancel();
                }
                if (WebViewRuntime.BootstrapperRunning)
                {
                    MessageBox.Show(
                        this,
                        "Microsoft’s installer for the display component is still running. Please wait until it has finished, then close this window.",
                        "Rewindle Setup",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                    args.Cancel = true;
                    return;
                }
            }
            bridge.Shutdown();
        }

        private void OnClosed(object sender, EventArgs args)
        {
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            RemoveWeb();
        }

        // ---- IBridgeServices -----------------------------------------------------------------------------------------------

        public void Post(Action work)
        {
            Dispatcher.BeginInvoke(work);
        }

        public void Send(string json)
        {
            try
            {
                CoreWebView2 core = webView == null ? null : webView.CoreWebView2;
                if (core != null)
                {
                    core.PostWebMessageAsJson(json);
                }
            }
            catch (Exception)
            {
                // The page went away between the work and its answer.
            }
        }

        public ThemeState Theme
        {
            get { return theme; }
        }

        public string Locale
        {
            get { return CultureInfo.CurrentCulture.Name; }
        }

        public string PickFolder(string title, string okButtonLabel, string legacyDescription)
        {
            return FolderPicker.Pick(new WindowInteropHelper(this).Handle, title, okButtonLabel, legacyDescription);
        }

        public string PickSaveFile(string initialFolder, string suggestedName)
        {
            SaveFileDialog dialog = new SaveFileDialog();
            dialog.Title = "Save a copy of your recovery key";
            dialog.FileName = suggestedName;
            dialog.DefaultExt = ".txt";
            dialog.AddExtension = true;
            dialog.Filter = "Text file (*.txt)|*.txt";
            dialog.OverwritePrompt = true;
            dialog.CheckPathExists = true;
            dialog.RestoreDirectory = true;
            if (!string.IsNullOrEmpty(initialFolder))
            {
                dialog.InitialDirectory = initialFolder;
            }
            bool? chosen = dialog.ShowDialog(this);
            return chosen == true ? dialog.FileName : string.Empty;
        }

        public void CopyToClipboard(string text)
        {
            for (int attempt = 0; attempt < 4; attempt++)
            {
                try
                {
                    Clipboard.SetText(text);
                    return;
                }
                catch (COMException)
                {
                    // Another program has the clipboard open for a moment.
                    Thread.Sleep(60);
                }
            }
            throw new SetupFailure("clipboard_busy", "Windows couldn’t copy that just now. Try again.");
        }

        public void OpenAddress(string address)
        {
            Uri uri;
            if (!Uri.TryCreate(address, UriKind.Absolute, out uri) ||
                !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
            try
            {
                ProcessStartInfo startInfo = new ProcessStartInfo(uri.AbsoluteUri);
                startInfo.UseShellExecute = true;
                Process.Start(startInfo);
            }
            catch (Win32Exception error)
            {
                SetupLog.Write("Opening a link failed", error);
                throw new SetupFailure("open_failed", "Windows couldn’t open the link in your browser.");
            }
        }

        public void RevealFile(string path)
        {
            string explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
            string arguments;
            if (File.Exists(path))
            {
                arguments = "/select," + CommandLine.Quote(path);
            }
            else
            {
                string folder = Path.GetDirectoryName(path);
                if (string.IsNullOrEmpty(folder) || !Directory.Exists(folder))
                {
                    throw new SetupFailure("recovery_key_invalid", "Setup can’t find the folder the recovery key was saved in.");
                }
                arguments = CommandLine.Quote(folder);
            }
            try
            {
                Process.Start(explorer, arguments);
            }
            catch (Win32Exception error)
            {
                SetupLog.Write("Opening File Explorer failed", error);
                throw new SetupFailure("open_failed", "Windows couldn’t open File Explorer.");
            }
        }

        public void StartProgram(string path, string arguments)
        {
            try
            {
                if (IsElevated())
                {
                    // Rewindle's dashboard refuses to run with administrator rights, so File Explorer starts it, as the person.
                    string explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
                    Process.Start(explorer, CommandLine.Quote(path));
                    return;
                }
                ProcessStartInfo startInfo = new ProcessStartInfo(path, arguments);
                startInfo.WorkingDirectory = Path.GetDirectoryName(path);
                startInfo.UseShellExecute = false;
                Process.Start(startInfo);
            }
            catch (Win32Exception error)
            {
                SetupLog.Write("Starting Rewindle failed", error);
                throw new SetupFailure("start_failed", "Windows couldn’t start Rewindle. Open it from the Start menu.");
            }
        }

        private static bool IsElevated()
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            }
        }

        // Steps the page's size the way the dashboard does. The answer is a sentence the page can speak.
        public string Zoom(string direction)
        {
            WebView2 view = webView;
            if (view == null || view.CoreWebView2 == null)
            {
                throw new SetupFailure("zoom_unavailable", "Setup is still starting.");
            }
            double current = view.ZoomFactor;
            double next = current;
            if (direction == "reset")
            {
                next = 1.0;
            }
            else if (direction == "in")
            {
                foreach (double step in ZoomSteps)
                {
                    if (step > current + 0.005)
                    {
                        next = step;
                        break;
                    }
                }
            }
            else
            {
                for (int index = ZoomSteps.Length - 1; index >= 0; index--)
                {
                    if (ZoomSteps[index] < current - 0.005)
                    {
                        next = ZoomSteps[index];
                        break;
                    }
                }
            }
            bool changed = Math.Abs(next - current) > 0.0001;
            if (changed)
            {
                view.ZoomFactor = next;
            }
            string percent = Math.Round(next * 100, MidpointRounding.AwayFromZero).ToString("0", CultureInfo.CurrentCulture) + "%";
            return changed || direction == "reset"
                ? "Zoom " + percent
                : direction == "in" ? "Zoom is at its largest, " + percent : "Zoom is at its smallest, " + percent;
        }

        public void RequestClose()
        {
            Close();
        }
    }
}
