using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using System.Web.Script.Serialization;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace ResticBackuper.Dashboard
{
    public partial class DashboardWindow
    {
        private const int WebProtocolVersion = 1;
        private const int MaximumWebMessageLength = 64 * 1024;
        private const string WebHostName = "restic.local";
        private const string WebHostOrigin = "https://restic.local";
        // The Evergreen bootstrapper from Microsoft. A fixed address: nothing the page or the
        // protected state supplies is ever opened.
        private const string WebViewRuntimeDownloadUri = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";
        private const string WebPresentationDeveloperHint =
            "Building from source? Run build.ps1 to rebuild the bundled web assets, or start with --native for the diagnostic window.";
        // A crashed renderer or browser is reloaded on its own at most this often, so a crash loop ends
        // on the notice with a Reload button instead of spinning.
        private const int WebPresentationRecoveryLimit = 3;
        private static readonly TimeSpan WebPresentationRecoveryWindow = TimeSpan.FromMinutes(5);
        // One failed delivery is a hiccup (a collection race, a COM error); the notice waits for a streak.
        private const int WebPresentationPublishFailureLimit = 5;
        // A page that stops answering is often only busy, and reloading it throws away what is on it. The browser
        // repeats its report every few seconds for as long as the page is stuck, so the notice waits until the page
        // has been stuck this long, and a quiet spell of the second length means it came back by itself. After
        // "Keep waiting" the person is not asked again for the third.
        private static readonly TimeSpan WebPresentationUnresponsiveGrace = TimeSpan.FromSeconds(15);
        private static readonly TimeSpan WebPresentationUnresponsiveGap = TimeSpan.FromSeconds(10);
        private static readonly TimeSpan WebPresentationUnresponsiveRepeat = TimeSpan.FromSeconds(60);
        // The page is told the app is alive at least this often, even when there is no new state to send.
        private static readonly TimeSpan WebPresentationHeartbeatInterval = TimeSpan.FromSeconds(5);
        // The sizes Ctrl+= and Ctrl+- step through, smallest first (see ExecuteZoomCommand). 100% is what Ctrl+0 returns to. The
        // range is the one the layout was made for: it reflows to a narrow window, and the sidebar folds, so even at 200% a window
        // at its minimum width (about 450 pixels across by then) shows the whole page.
        private static readonly double[] WebZoomSteps = { 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0 };

        private WebView2 webPresentation;
        private Border webPresentationErrorSurface;
        private TextBlock webPresentationErrorTitle;
        private TextBlock webPresentationErrorText;
        private TextBlock webPresentationErrorDetail;
        private Button webPresentationKeepWaitingButton;
        private Button webPresentationReloadButton;
        private Button webPresentationRuntimeButton;
        private Button webPresentationExitButton;
        private Task webPresentationInitialization;
        private bool webPresentationConfigured;
        private bool webPresentationClosing;
        private bool webPresentationReady;
        private bool webPresentationHandshakeReady;
        // The browser process behind the control exited, so CoreWebView2 is unusable and only a fresh
        // control can recover.
        private bool webPresentationBrowserLost;
        private int webPresentationPublishFailures;
        private readonly List<DateTime> webPresentationRecoveryUtc = new List<DateTime>();
        private DateTime webPresentationUnresponsiveSinceUtc = DateTime.MinValue;
        private DateTime webPresentationUnresponsiveLastUtc = DateTime.MinValue;
        private DateTime webPresentationUnresponsiveNoticeUtc = DateTime.MinValue;
        private bool webPresentationUnresponsiveNoticeShown;
        // PublishWebPresentationState asks for a state; the page is sent one per dispatcher turn, and not again
        // while it would be identical to the last one it was sent.
        private bool webPresentationPublishQueued;
        private string webPresentationLastPostedState;
        private DateTime webPresentationLastPostUtc = DateTime.MinValue;
        private string webTelemetryError;
        private RunDetails webRunDetails;
        private RunMetricView webRunDetailsRun;
        private readonly JavaScriptSerializer webPresentationSerializer =
            new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 };
        // Whether each protected folder still exists. Directory.Exists can block for many seconds on a
        // disconnected network or removable volume, and every published state asks, so the answers are
        // probed off the UI thread and cached.
        private static readonly TimeSpan WebSourceExistenceRefreshInterval = TimeSpan.FromSeconds(10);
        private Dictionary<string, bool> webSourceExistence =
            new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        private DateTime webSourceExistenceCheckedUtc = DateTime.MinValue;
        private bool webSourceExistenceProbeInFlight;

        private void MountWebPresentation(Grid shell, FrameworkElement nativeRoot)
        {
            if (options == null || options.UseNativePresentation || shell == null)
            {
                return;
            }

            // The native tree remains fully built and wired so the protected dialogs and
            // existing operations stay as the adapter layer. WebView2 owns the visible surface.
            if (nativeRoot != null)
            {
                nativeRoot.Visibility = Visibility.Collapsed;
            }
            if (navigationRail != null)
            {
                navigationRail.Visibility = Visibility.Collapsed;
            }

            Panel previousParent = webPresentation == null
                ? null
                : webPresentation.Parent as Panel;
            if (previousParent != null && !object.ReferenceEquals(previousParent, shell))
            {
                previousParent.Children.Remove(webPresentation);
            }

            if (webPresentation == null)
            {
                webPresentation = new WebView2();
                webPresentation.HorizontalAlignment = HorizontalAlignment.Stretch;
                webPresentation.VerticalAlignment = VerticalAlignment.Stretch;
                webPresentation.Focusable = true;
                webPresentation.AllowExternalDrop = false;
                webPresentation.Visibility = Visibility.Visible;
                webPresentation.Loaded += OnWebPresentationLoaded;
            }
            if (!shell.Children.Contains(webPresentation))
            {
                shell.Children.Add(webPresentation);
            }
            Grid.SetColumn(webPresentation, 0);
            Grid.SetColumnSpan(webPresentation, 2);
            Panel.SetZIndex(webPresentation, 100);
            // The shell is rebuilt whenever the theme changes, so this also carries a new palette into a running web view.
            ApplyWebPresentationTheme();

            MountWebPresentationErrorSurface(shell);
            CoreWebView2 existing = WebPresentationCore();
            if (existing != null)
            {
                ConfigureWebPresentation(existing);
                PublishWebPresentationState();
                return;
            }
        }

        // What the web view shows before the page has painted, and the color scheme it reports to the page. Left alone the
        // surface is white, so a dark profile flashed white on every launch, and the page could only guess its theme (it
        // assumed dark) until the host's first message arrived. The background is the page's own (--page matches the
        // palette's top color), and the preferred color scheme makes prefers-color-scheme in the page name the theme the
        // host resolved, from the first frame, even for a fixed Dark or Light preference. Presentation only: nothing here
        // touches the message protocol.
        private void ApplyWebPresentationTheme()
        {
            WebView2 view = webPresentation;
            DashboardThemePalette palette = themeResolution == null ? null : themeResolution.Palette;
            if (view == null || palette == null)
            {
                return;
            }
            try
            {
                Color background = palette.BackgroundTop.Color;
                view.DefaultBackgroundColor = System.Drawing.Color.FromArgb(
                    255,
                    background.R,
                    background.G,
                    background.B);
                CoreWebView2 core = WebPresentationCore();
                if (core != null)
                {
                    core.Profile.PreferredColorScheme = palette.IsDark
                        ? CoreWebView2PreferredColorScheme.Dark
                        : CoreWebView2PreferredColorScheme.Light;
                }
            }
            catch (Exception)
            {
                // An older WebView2 runtime has no profile API, and a browser that went away cannot be told anything. The
                // page still pins its own theme once the first state arrives.
            }
        }

        // Once the browser process behind the control has crashed, reading CoreWebView2 throws instead of
        // returning null, so callers that only want to know whether a live browser is there ask through here.
        private CoreWebView2 WebPresentationCore()
        {
            WebView2 view = webPresentation;
            if (view == null)
            {
                return null;
            }
            try
            {
                return view.CoreWebView2;
            }
            catch (InvalidOperationException)
            {
                return null;
            }
        }

        private void OnWebPresentationLoaded(object sender, RoutedEventArgs args)
        {
            if (webPresentationClosing || webPresentationInitialization != null ||
                options == null || options.UseNativePresentation || webPresentation == null)
            {
                return;
            }
            webPresentationInitialization = InitializeWebPresentationAsync();
        }

        private void MountWebPresentationErrorSurface(Grid shell)
        {
            if (webPresentationErrorSurface == null)
            {
                webPresentationErrorSurface = new Border();
                webPresentationErrorSurface.Padding = new Thickness(42);
                webPresentationErrorSurface.Visibility = Visibility.Collapsed;

                StackPanel errorLayout = new StackPanel();
                errorLayout.VerticalAlignment = VerticalAlignment.Center;
                errorLayout.HorizontalAlignment = HorizontalAlignment.Center;
                errorLayout.MaxWidth = 720;

                webPresentationErrorTitle = new TextBlock();
                webPresentationErrorTitle.FontSize = 22;
                webPresentationErrorTitle.FontWeight = FontWeights.SemiBold;
                webPresentationErrorTitle.TextWrapping = TextWrapping.Wrap;
                errorLayout.Children.Add(webPresentationErrorTitle);

                webPresentationErrorText = new TextBlock();
                webPresentationErrorText.FontSize = 14;
                webPresentationErrorText.TextWrapping = TextWrapping.Wrap;
                webPresentationErrorText.Margin = new Thickness(0, 10, 0, 0);
                errorLayout.Children.Add(webPresentationErrorText);

                webPresentationErrorDetail = new TextBlock();
                webPresentationErrorDetail.FontSize = 12;
                webPresentationErrorDetail.TextWrapping = TextWrapping.Wrap;
                webPresentationErrorDetail.Margin = new Thickness(0, 14, 0, 0);
                errorLayout.Children.Add(webPresentationErrorDetail);

                StackPanel errorActions = new StackPanel();
                errorActions.Orientation = Orientation.Horizontal;
                errorActions.Margin = new Thickness(0, 24, 0, 0);
                webPresentationKeepWaitingButton = CreateButton("Keep waiting");
                webPresentationKeepWaitingButton.Margin = new Thickness(0, 0, 10, 0);
                webPresentationKeepWaitingButton.Click += OnWebPresentationKeepWaitingClick;
                errorActions.Children.Add(webPresentationKeepWaitingButton);
                webPresentationRuntimeButton = CreateButton("Download WebView2 Runtime");
                webPresentationRuntimeButton.Margin = new Thickness(0, 0, 10, 0);
                webPresentationRuntimeButton.Click += OnWebPresentationRuntimeDownloadClick;
                errorActions.Children.Add(webPresentationRuntimeButton);
                webPresentationReloadButton = CreateButton("Reload");
                webPresentationReloadButton.Margin = new Thickness(0, 0, 10, 0);
                webPresentationReloadButton.Click += OnWebPresentationReloadClick;
                errorActions.Children.Add(webPresentationReloadButton);
                webPresentationExitButton = CreateButton("Exit Rewindle");
                webPresentationExitButton.Click += OnWebPresentationExitClick;
                errorActions.Children.Add(webPresentationExitButton);
                errorLayout.Children.Add(errorActions);
                webPresentationErrorSurface.Child = errorLayout;
            }
            // The shell is rebuilt when the theme changes, so the notice follows the current palette.
            ApplyWebPresentationNoticePalette();

            Panel previousParent = webPresentationErrorSurface.Parent as Panel;
            if (previousParent != null && !object.ReferenceEquals(previousParent, shell))
            {
                previousParent.Children.Remove(webPresentationErrorSurface);
            }
            if (!shell.Children.Contains(webPresentationErrorSurface))
            {
                shell.Children.Add(webPresentationErrorSurface);
            }
            Grid.SetColumn(webPresentationErrorSurface, 0);
            Grid.SetColumnSpan(webPresentationErrorSurface, 2);
            Panel.SetZIndex(webPresentationErrorSurface, 200);
        }

        // The notice is built once and outlives theme changes, so its colors, and its buttons' (which take their
        // brushes from the same palette), are set again whenever the shell is rebuilt and whenever the notice is shown.
        private void ApplyWebPresentationNoticePalette()
        {
            if (webPresentationErrorSurface == null || themeResolution == null)
            {
                return;
            }
            webPresentationErrorSurface.Background = BackgroundTop;
            webPresentationErrorTitle.Foreground = PrimaryText;
            webPresentationErrorText.Foreground = PrimaryText;
            webPresentationErrorDetail.Foreground = MutedText;
            Button[] buttons =
            {
                webPresentationKeepWaitingButton,
                webPresentationRuntimeButton,
                webPresentationReloadButton,
                webPresentationExitButton
            };
            foreach (Button button in buttons)
            {
                if (button == null)
                {
                    continue;
                }
                button.Foreground = themeResolution.Palette.ButtonText;
                button.Background = themeResolution.Palette.ButtonBackground;
                button.BorderBrush = CardBorderBrush;
            }
        }

        private async Task InitializeWebPresentationAsync()
        {
            try
            {
                if (webPresentationClosing)
                {
                    return;
                }
                string webRoot = Path.Combine(
                    AppDomain.CurrentDomain.BaseDirectory,
                    "web");
                string indexPath = Path.Combine(webRoot, "index.html");
                if (!Directory.Exists(webRoot) || !File.Exists(indexPath))
                {
                    ShowWebPresentationFailure(
                        "Rewindle's interface files are missing",
                        "The dashboard's web interface was not found next to the app, so it cannot open. " +
                            "Reinstall Rewindle, then choose Reload. Your backups are not affected.",
                        "Expected: " + indexPath + "\n\n" + WebPresentationDeveloperHint,
                        true,
                        false);
                    return;
                }

                string userDataFolder = GetWebUserDataFolder();
                Directory.CreateDirectory(userDataFolder);
                CoreWebView2Environment environment =
                    await CoreWebView2Environment.CreateAsync(null, userDataFolder, null);
                if (webPresentationClosing || webPresentation == null)
                {
                    return;
                }
                await webPresentation.EnsureCoreWebView2Async(environment);
                if (webPresentationClosing || webPresentation == null ||
                    webPresentation.CoreWebView2 == null)
                {
                    if (!webPresentationClosing)
                    {
                        ShowWebPresentationFailure(
                            "Rewindle couldn't start its dashboard",
                            "The web view that draws the dashboard started without a display surface. " +
                                "Choose Reload to try again. Your backups are not affected.",
                            WebPresentationDeveloperHint,
                            true,
                            false);
                    }
                    return;
                }

                ConfigureWebPresentation(webPresentation.CoreWebView2);
                // Before the first navigation, so the page's first frame already sees the right color scheme.
                ApplyWebPresentationTheme();
                webPresentation.CoreWebView2.SetVirtualHostNameToFolderMapping(
                    WebHostName,
                    webRoot,
                    CoreWebView2HostResourceAccessKind.DenyCors);
                webPresentationReady = true;
                webPresentationHandshakeReady = false;
                webPresentation.CoreWebView2.Navigate(WebHostOrigin + "/index.html");
            }
            catch (Exception error)
            {
                if (webPresentationClosing)
                {
                    return;
                }
                if (IsWebViewRuntimeMissing(error))
                {
                    ShowWebPresentationFailure(
                        "Rewindle needs the Microsoft Edge WebView2 Runtime",
                        "Rewindle draws its dashboard with Microsoft's free WebView2 Runtime, which is not " +
                            "installed on this computer. Download and install it, then choose Reload. " +
                            "Your backups are not affected.",
                        WebPresentationDeveloperHint,
                        true,
                        true);
                    return;
                }
                ShowWebPresentationFailure(
                    "Rewindle couldn't start its dashboard",
                    "The web view that draws the dashboard could not start. Choose Reload to try again. " +
                        "Your backups are not affected.",
                    error.Message + "\n\n" + WebPresentationDeveloperHint,
                    true,
                    false);
            }
        }

        private static bool IsWebViewRuntimeMissing(Exception error)
        {
            if (error is WebView2RuntimeNotFoundException)
            {
                return true;
            }
            // Older loaders report a missing runtime as ERROR_FILE_NOT_FOUND.
            COMException interop = error as COMException;
            return interop != null && interop.ErrorCode == unchecked((int)0x80070002);
        }

        private string GetWebUserDataFolder()
        {
            if (options != null && options.UseIsolatedPresentationStore)
            {
                return EngineProfile.Current.IsolatedWebViewDirectory();
            }
            string dashboardDirectory = EngineProfile.Current.DashboardDataDirectory();
            if (string.IsNullOrWhiteSpace(dashboardDirectory))
            {
                dashboardDirectory = Path.Combine(
                    Path.GetTempPath(),
                    EngineProfile.Current.DashboardDataDirectoryName);
            }
            return Path.Combine(dashboardDirectory, "WebView2");
        }

        private void ConfigureWebPresentation(CoreWebView2 core)
        {
            if (core == null || webPresentationConfigured)
            {
                return;
            }

            CoreWebView2Settings settings = core.Settings;
            settings.AreDevToolsEnabled = false;
            settings.AreDefaultContextMenusEnabled = false;
            settings.AreDefaultScriptDialogsEnabled = false;
            settings.IsStatusBarEnabled = false;
            // Ctrl+mouse wheel (and pinch) zoom the page, so text can be made larger; the layout reflows down to narrow
            // widths. The keyboard route is the page's: Ctrl+= / Ctrl+- / Ctrl+0 send a setZoom command (see
            // ExecuteZoomCommand), because the accelerator keys below are off.
            settings.IsZoomControlEnabled = true;
            settings.IsGeneralAutofillEnabled = false;
            settings.IsPasswordAutosaveEnabled = false;
            settings.IsWebMessageEnabled = true;
            // Reload, print, find and the other browser shortcuts do nothing here. F5 is handled by the
            // page, which asks the host to refresh its data instead of reloading the page itself.
            settings.AreBrowserAcceleratorKeysEnabled = false;

            core.NavigationStarting += OnWebPresentationNavigationStarting;
            core.NavigationCompleted += OnWebPresentationNavigationCompleted;
            core.NewWindowRequested += OnWebPresentationNewWindowRequested;
            core.DownloadStarting += OnWebPresentationDownloadStarting;
            core.PermissionRequested += OnWebPresentationPermissionRequested;
            core.LaunchingExternalUriScheme += OnWebPresentationExternalUriScheme;
            core.BasicAuthenticationRequested += OnWebPresentationBasicAuthentication;
            core.ServerCertificateErrorDetected += OnWebPresentationCertificateError;
            core.ContextMenuRequested += OnWebPresentationContextMenuRequested;
            core.WebResourceRequested += OnWebPresentationResourceRequested;
            core.WebMessageReceived += OnWebPresentationMessageReceived;
            core.ProcessFailed += OnWebPresentationProcessFailed;
            core.AddWebResourceRequestedFilter(
                "*",
                CoreWebView2WebResourceContext.All);
            webPresentationConfigured = true;
        }

        private void OnWebPresentationNavigationStarting(
            object sender,
            CoreWebView2NavigationStartingEventArgs args)
        {
            if (webPresentationClosing)
            {
                args.Cancel = true;
                return;
            }
            if (!IsAllowedWebUri(args.Uri))
            {
                // A refused navigation leaves the page where it is, so the page keeps its handshake.
                args.Cancel = true;
                return;
            }
            webPresentationHandshakeReady = false;
            // The page that loads is new and has seen none of the states sent before it.
            webPresentationLastPostedState = null;
        }

        private void OnWebPresentationNavigationCompleted(
            object sender,
            CoreWebView2NavigationCompletedEventArgs args)
        {
            if (webPresentationClosing)
            {
                return;
            }
            if (args.IsSuccess)
            {
                HideWebPresentationFailure();
                return;
            }
            if (args.WebErrorStatus == CoreWebView2WebErrorStatus.OperationCanceled)
            {
                // The host refused an external link or a newer navigation replaced this one. Neither
                // means the dashboard failed to load.
                return;
            }
            ShowWebPresentationFailure(
                "Rewindle's dashboard didn't load",
                "The dashboard page could not be loaded. Choose Reload to try again. " +
                    "Your backups are not affected.",
                "Status: " + args.WebErrorStatus.ToString(),
                true,
                false);
        }

        private void OnWebPresentationNewWindowRequested(
            object sender,
            CoreWebView2NewWindowRequestedEventArgs args)
        {
            args.Handled = true;
        }

        private void OnWebPresentationDownloadStarting(
            object sender,
            CoreWebView2DownloadStartingEventArgs args)
        {
            args.Cancel = true;
            args.Handled = true;
        }

        private void OnWebPresentationPermissionRequested(
            object sender,
            CoreWebView2PermissionRequestedEventArgs args)
        {
            args.State = CoreWebView2PermissionState.Deny;
            args.Handled = true;
        }

        private void OnWebPresentationExternalUriScheme(
            object sender,
            CoreWebView2LaunchingExternalUriSchemeEventArgs args)
        {
            args.Cancel = true;
        }

        private void OnWebPresentationBasicAuthentication(
            object sender,
            CoreWebView2BasicAuthenticationRequestedEventArgs args)
        {
            args.Cancel = true;
        }

        private void OnWebPresentationCertificateError(
            object sender,
            CoreWebView2ServerCertificateErrorDetectedEventArgs args)
        {
            args.Action = CoreWebView2ServerCertificateErrorAction.Cancel;
        }

        private void OnWebPresentationContextMenuRequested(
            object sender,
            CoreWebView2ContextMenuRequestedEventArgs args)
        {
            args.Handled = true;
        }

        private void OnWebPresentationResourceRequested(
            object sender,
            CoreWebView2WebResourceRequestedEventArgs args)
        {
            string uri = args.Request == null ? string.Empty : args.Request.Uri;
            if (IsAllowedWebUri(uri))
            {
                return;
            }
            CoreWebView2 core = sender as CoreWebView2;
            if (core != null)
            {
                args.Response = core.Environment.CreateWebResourceResponse(
                    new MemoryStream(),
                    403,
                    "Blocked",
                    "Content-Type: text/plain");
            }
        }

        private void OnWebPresentationProcessFailed(
            object sender,
            CoreWebView2ProcessFailedEventArgs args)
        {
            if (webPresentationClosing)
            {
                return;
            }
            CoreWebView2ProcessFailedKind kind = args.ProcessFailedKind;
            if (kind == CoreWebView2ProcessFailedKind.RenderProcessUnresponsive)
            {
                // Not a failure yet: the page may only be busy. Its handshake stays, so that when it answers again
                // it is still sent the state.
                NoteWebPresentationUnresponsive();
                return;
            }
            bool browserLost = kind == CoreWebView2ProcessFailedKind.BrowserProcessExited;
            bool pageLost = kind == CoreWebView2ProcessFailedKind.RenderProcessExited;
            if (!browserLost && !pageLost)
            {
                // GPU, utility, sandbox-helper and plug-in processes restart on their own and the page
                // survives them, so there is nothing to tell the user.
                return;
            }
            webPresentationHandshakeReady = false;
            webPresentationLastPostedState = null;
            // A page that exited is no longer stuck.
            webPresentationUnresponsiveSinceUtc = DateTime.MinValue;
            webPresentationBrowserLost = webPresentationBrowserLost || browserLost;
            string cause = kind.ToString();
            Dispatcher.BeginInvoke(new Action(delegate { RecoverWebPresentation(cause); }));
        }

        // The browser reports an unresponsive page again every few seconds while it stays stuck. Reloading at the first
        // report would throw away what the page holds and, on a busy computer, spend the automatic reloads on a page
        // that was only slow, so the report is noted and the person is asked only once it has gone on for a while.
        private void NoteWebPresentationUnresponsive()
        {
            if (!NoteWebPresentationUnresponsiveReport(DateTime.UtcNow))
            {
                return;
            }
            ShowWebPresentationFailure(
                "The dashboard isn't responding",
                "The window that draws the dashboard has stopped answering. It may only be busy, so you can " +
                    "keep waiting, or reload it. Backups run separately and are not affected.",
                string.Empty,
                true,
                false,
                true);
        }

        // Records one report. True when it is the one that should raise the notice: the page has been stuck for the
        // whole grace period and the person has not been told yet.
        private bool NoteWebPresentationUnresponsiveReport(DateTime nowUtc)
        {
            if (webPresentationUnresponsiveSinceUtc == DateTime.MinValue ||
                nowUtc - webPresentationUnresponsiveLastUtc > WebPresentationUnresponsiveGap)
            {
                // The reports had stopped, so the page had recovered in between: this is a new episode.
                webPresentationUnresponsiveSinceUtc = nowUtc;
                webPresentationUnresponsiveNoticeUtc = nowUtc + WebPresentationUnresponsiveGrace;
                webPresentationUnresponsiveNoticeShown = false;
            }
            webPresentationUnresponsiveLastUtc = nowUtc;
            if (webPresentationUnresponsiveNoticeShown || nowUtc < webPresentationUnresponsiveNoticeUtc)
            {
                return false;
            }
            webPresentationUnresponsiveNoticeShown = true;
            return true;
        }

        // Called about once a second. Reports repeat while the page is stuck, so a quiet spell means it recovered by
        // itself: the notice has no reason to stay, and the page is sent the state it missed.
        private void CheckWebPresentationResponsive()
        {
            if (webPresentationUnresponsiveSinceUtc == DateTime.MinValue ||
                DateTime.UtcNow - webPresentationUnresponsiveLastUtc <= WebPresentationUnresponsiveGap)
            {
                return;
            }
            webPresentationUnresponsiveSinceUtc = DateTime.MinValue;
            if (webPresentationUnresponsiveNoticeShown)
            {
                // Only the not-responding notice goes; any other failure on screen is not about this.
                HideWebPresentationFailure();
            }
            PublishWebPresentationState();
        }

        private void OnWebPresentationKeepWaitingClick(object sender, RoutedEventArgs args)
        {
            // The page is not reloaded; it is given more time before the person is asked again.
            HideWebPresentationFailure();
            DateTime now = DateTime.UtcNow;
            webPresentationUnresponsiveSinceUtc = now;
            webPresentationUnresponsiveLastUtc = now;
            webPresentationUnresponsiveNoticeUtc = now + WebPresentationUnresponsiveRepeat;
        }

        // The page or its browser stopped. Reload on our own a few times, then hand the decision to the user.
        private void RecoverWebPresentation(string cause)
        {
            if (webPresentationClosing)
            {
                return;
            }
            if (TryBeginWebPresentationRecovery())
            {
                ReloadWebPresentation();
                return;
            }
            ShowWebPresentationFailure(
                "The dashboard keeps stopping",
                "The web view that draws the dashboard stopped several times in a row. Choose Reload to " +
                    "try again, or exit and reopen Rewindle. Backups run separately and are not affected.",
                "Cause: " + cause,
                true,
                false);
        }

        private bool TryBeginWebPresentationRecovery()
        {
            DateTime now = DateTime.UtcNow;
            webPresentationRecoveryUtc.RemoveAll(item => now - item > WebPresentationRecoveryWindow);
            if (webPresentationRecoveryUtc.Count >= WebPresentationRecoveryLimit)
            {
                return false;
            }
            webPresentationRecoveryUtc.Add(now);
            return true;
        }

        private void OnWebPresentationReloadClick(object sender, RoutedEventArgs args)
        {
            // An explicit request always runs, and starts the automatic allowance over.
            webPresentationRecoveryUtc.Clear();
            webPresentationPublishFailures = 0;
            ReloadWebPresentation();
        }

        private void OnWebPresentationRuntimeDownloadClick(object sender, RoutedEventArgs args)
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = WebViewRuntimeDownloadUri,
                    UseShellExecute = true
                });
            }
            catch (Exception error)
            {
                webPresentationErrorDetail.Text =
                    "The download page could not be opened (" + error.Message + "). " +
                    "Search for \"WebView2 Runtime\" on microsoft.com instead.";
                webPresentationErrorDetail.Visibility = Visibility.Visible;
            }
        }

        private void OnWebPresentationExitClick(object sender, RoutedEventArgs args)
        {
            ExitApplication();
        }

        // Navigates the live page again, or starts over with a fresh control when the browser behind it
        // is gone or the control never finished starting.
        private void ReloadWebPresentation()
        {
            if (webPresentationClosing)
            {
                return;
            }
            HideWebPresentationFailure();
            if (!webPresentationBrowserLost && webPresentationReady)
            {
                try
                {
                    CoreWebView2 core = WebPresentationCore();
                    if (core != null)
                    {
                        webPresentationHandshakeReady = false;
                        core.Navigate(WebHostOrigin + "/index.html");
                        return;
                    }
                }
                catch (Exception)
                {
                    // The browser went away underneath the control; a fresh control below recovers.
                }
            }
            RecreateWebPresentation();
        }

        private void RecreateWebPresentation()
        {
            Grid shell = shellLayout;
            if (webPresentationClosing || shell == null || options == null ||
                options.UseNativePresentation)
            {
                return;
            }
            WebView2 stale = webPresentation;
            webPresentation = null;
            webPresentationReady = false;
            webPresentationHandshakeReady = false;
            webPresentationConfigured = false;
            webPresentationBrowserLost = false;
            webPresentationInitialization = null;
            webPresentationLastPostedState = null;
            webPresentationPublishQueued = false;
            if (stale != null)
            {
                stale.Loaded -= OnWebPresentationLoaded;
                shell.Children.Remove(stale);
                try
                {
                    stale.Dispose();
                }
                catch
                {
                    // The controller may already be gone together with its browser process.
                }
            }
            // The new control starts itself from its Loaded event, exactly like the first one.
            MountWebPresentation(shell, null);
        }

        private void OnWebPresentationMessageReceived(
            object sender,
            CoreWebView2WebMessageReceivedEventArgs args)
        {
            if (webPresentationClosing)
            {
                return;
            }
            if (!IsAllowedWebUri(args.Source))
            {
                return;
            }
            string json = args.WebMessageAsJson;
            if (string.IsNullOrWhiteSpace(json) || json.Length > MaximumWebMessageLength)
            {
                return;
            }

            IDictionary<string, object> message;
            try
            {
                object parsed = webPresentationSerializer.DeserializeObject(json);
                message = parsed as IDictionary<string, object>;
                if (message == null && parsed is string)
                {
                    message = webPresentationSerializer.DeserializeObject((string)parsed)
                        as IDictionary<string, object>;
                }
            }
            catch
            {
                return;
            }
            if (message == null)
            {
                return;
            }

            string type = WebReadString(message, "type", 32);
            if (string.Equals(type, "ready", StringComparison.Ordinal))
            {
                webPresentationHandshakeReady = true;
                // A page that announces itself is alive, so any earlier notice is stale.
                HideWebPresentationFailure();
                // The page is waiting for its first state, so it is sent now, in full, whatever was sent before.
                PublishWebPresentationStateNow();
                return;
            }
            if (!string.Equals(type, "command", StringComparison.Ordinal))
            {
                return;
            }

            string id = WebReadString(message, "id", 128);
            string command = WebReadString(message, "command", 64);
            IDictionary<string, object> payload = null;
            object rawPayload;
            if (message.TryGetValue("payload", out rawPayload))
            {
                payload = rawPayload as IDictionary<string, object>;
            }

            if (string.Equals(command, "ready", StringComparison.Ordinal))
            {
                webPresentationHandshakeReady = true;
                HideWebPresentationFailure();
                SendWebCommandResult(id, true, string.Empty);
                PublishWebPresentationStateNow();
                return;
            }

            string error;
            bool accepted;
            try
            {
                accepted = ExecuteWebCommand(command, payload, out error);
            }
            catch (Exception exception)
            {
                // A command that throws is still answered. The page waits for the answer (a dialog that is busy, a close that
                // may have to be taken back), and left to itself the exception would only reach the dispatcher's message box
                // while the page never heard. The page is told in general terms, without the exception's own words; the
                // details go to the log, as they did when the exception reached the dispatcher.
                CrashLog.Write("Dashboard command", exception);
                accepted = false;
                error = "That action could not be completed. Refresh and try again.";
            }
            // The state the command led to goes out before its answer, as the page expects (a folder that was
            // chosen, for one, is in the state when the answer says the picker is done).
            FlushWebPresentationState();
            SendWebCommandResult(id, accepted, error);
        }

        private bool ExecuteWebCommand(
            string command,
            IDictionary<string, object> payload,
            out string error)
        {
            error = string.Empty;
            if (string.Equals(command, "setZoom", StringComparison.Ordinal))
            {
                // Only changes how large the page is drawn, so it works with a dialog open and over a stale link, which is
                // when somebody who needs it larger needs it most.
                return ExecuteZoomCommand(payload, out error);
            }
            if (IsRunDetailsCommand(command))
            {
                return ExecuteRunDetailsCommand(command, payload, out error);
            }
            if (IsRestoreFlowCommand(command))
            {
                if (webRunDetails != null)
                {
                    error = "Close run details before using the guided restore flow.";
                    return false;
                }
                return ExecuteRestoreFlowCommand(command, payload, out error);
            }
            if (webRunDetails != null && command != "refresh")
            {
                error = "Close run details before using other dashboard controls.";
                return false;
            }
            if (sourcePickerOpen &&
                (string.Equals(command, "backupNow", StringComparison.Ordinal) ||
                 string.Equals(command, "cancelBackup", StringComparison.Ordinal) ||
                 string.Equals(command, "togglePreview", StringComparison.Ordinal) ||
                 string.Equals(command, "removeSource", StringComparison.Ordinal) ||
                 string.Equals(command, "editSchedule", StringComparison.Ordinal) ||
                 string.Equals(command, "changeRepository", StringComparison.Ordinal) ||
                 string.Equals(command, "repairRepository", StringComparison.Ordinal) ||
                 string.Equals(command, "reviewChanges", StringComparison.Ordinal) ||
                 string.Equals(command, "openRestore", StringComparison.Ordinal) ||
                 string.Equals(command, "checkReadiness", StringComparison.Ordinal)))
            {
                error = "Finish or close the folder chooser before using another protected action.";
                return false;
            }
            if (restoreFlowOpen && command != "refresh")
            {
                error = "Finish or close the guided restore flow before using another dashboard control.";
                return false;
            }
            if (string.Equals(command, "refresh", StringComparison.Ordinal))
            {
                RefreshDashboard();
                return true;
            }
            if (string.Equals(command, "navigate", StringComparison.Ordinal))
            {
                string page = WebReadString(payload, "page", 32);
                if (page != "Protection" && page != "Activity" &&
                    page != "Restore" && page != "Settings")
                {
                    error = "The requested dashboard page is invalid.";
                    return false;
                }
                ShowDashboardPage(page);
                PublishWebPresentationState();
                return true;
            }
            if (string.Equals(command, "openLicensesFolder", StringComparison.Ordinal))
            {
                // Settings > About. Like the other open-location commands it takes no path from the page.
                return OpenLicensesFolder(out error);
            }
            if (string.Equals(command, "setTheme", StringComparison.Ordinal))
            {
                DashboardThemePreference preference;
                string theme = WebReadString(payload, "theme", 32);
                if (string.IsNullOrWhiteSpace(theme))
                {
                    theme = WebReadString(payload, "preference", 32);
                }
                if (!DashboardThemeManager.TryParsePreference(theme, out preference) ||
                    !themeButtons.ContainsKey(preference))
                {
                    error = "The requested dashboard theme is invalid.";
                    return false;
                }
                OnThemeSegmentClick(themeButtons[preference], new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "setMotion", StringComparison.Ordinal))
            {
                DashboardMotionPreference preference;
                string motion = WebReadString(payload, "motion", 32);
                if (string.IsNullOrWhiteSpace(motion))
                {
                    motion = WebReadString(payload, "preference", 32);
                }
                if (!DashboardMotion.TryParsePreference(motion, out preference) ||
                    !motionButtons.ContainsKey(preference))
                {
                    error = "The requested motion preference is invalid.";
                    return false;
                }
                return TrySetMotionPreference(preference, out error);
            }
            if (string.Equals(command, "togglePreview", StringComparison.Ordinal))
            {
                if (previewButton == null || !previewButton.IsEnabled)
                {
                    error = "The preview control is unavailable.";
                    return false;
                }
                previewButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                return true;
            }
            if (string.Equals(command, "selectRun", StringComparison.Ordinal))
            {
                string runId = WebReadString(payload, "runId", 128);
                RunMetricView run = FindHistoryRun(runId);
                if (run == null || historyGrid == null)
                {
                    error = "The requested backup run is unavailable.";
                    return false;
                }
                historyGrid.SelectedItem = run;
                historyGrid.ScrollIntoView(run);
                UpdateActivityActions();
                PublishWebPresentationState();
                return true;
            }
            if (string.Equals(command, "viewRunDetails", StringComparison.Ordinal))
            {
                string runId = WebReadString(payload, "runId", 128);
                RunMetricView run = string.IsNullOrWhiteSpace(runId)
                    ? (historyGrid == null ? null : historyGrid.SelectedItem as RunMetricView)
                    : FindHistoryRun(runId);
                if (run == null || historyGrid == null)
                {
                    error = "The requested backup run is unavailable.";
                    return false;
                }
                historyGrid.SelectedItem = run;
                if (viewRunDetailsButton == null || !viewRunDetailsButton.IsEnabled)
                {
                    error = "Run details are unavailable for the selected run.";
                    return false;
                }
                try
                {
                    if (!CanShowWebRunDetails())
                    {
                        error = "The run-details surface is unavailable. Restart the dashboard and try again.";
                        return false;
                    }
                    ShowWebRunDetails(run);
                    return true;
                }
                catch (Exception exception)
                {
                    error = "Run details could not be opened. " + exception.Message;
                    return false;
                }
            }

            Button actionButton;
            if (string.Equals(command, "backupNow", StringComparison.Ordinal))
            {
                actionButton = backupNowButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                OnBackupNowClick(actionButton, new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "cancelBackup", StringComparison.Ordinal))
            {
                actionButton = cancelBackupButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                OnCancelBackupClick(actionButton, new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "addSource", StringComparison.Ordinal))
            {
                actionButton = addSourceButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                // Published whether or not the chooser opened: a refusal that came after the old one was cleared away changes what the page shows.
                bool pickerOpened = TryOpenSourcePicker(out error);
                PublishWebPresentationState();
                return pickerOpened;
            }
            if (string.Equals(command, "browseSourcePicker", StringComparison.Ordinal))
            {
                return BrowseSourcePicker(out error);
            }
            if (string.Equals(command, "validateSourcePath", StringComparison.Ordinal))
            {
                string path = WebReadString(payload, "path", 4096);
                return BeginSourcePickerValidation(path, out error);
            }
            if (string.Equals(command, "confirmSourcePicker", StringComparison.Ordinal))
            {
                string path = WebReadString(payload, "path", 4096);
                return ConfirmSourcePicker(path, out error);
            }
            if (string.Equals(command, "closeSourcePicker", StringComparison.Ordinal))
            {
                return CloseSourcePicker(out error);
            }
            if (string.Equals(command, "removeSource", StringComparison.Ordinal))
            {
                string path = WebReadString(payload, "path", 4096);
                Button remove = FindRemoveSourceButton(path);
                if (!CheckWebAction(remove, out error)) return false;
                OnRemoveSourceClick(remove, new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "retrySourceChange", StringComparison.Ordinal))
            {
                actionButton = sourceOperationRetryButton;
                if (!CheckVisibleWebAction(actionButton, out error)) return false;
                OnRetrySourceOperationClick(actionButton, new RoutedEventArgs());
                PublishWebPresentationState();
                return true;
            }
            if (string.Equals(command, "dismissSourceChange", StringComparison.Ordinal))
            {
                actionButton = sourceOperationDismissButton;
                if (!CheckVisibleWebAction(actionButton, out error)) return false;
                OnDismissSourceOperationClick(actionButton, new RoutedEventArgs());
                PublishWebPresentationState();
                return true;
            }
            if (string.Equals(command, "editSchedule", StringComparison.Ordinal))
            {
                actionButton = editScheduleButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                OnEditScheduleClick(actionButton, new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "changeRepository", StringComparison.Ordinal))
            {
                actionButton = changeRepositoryButton != null && changeRepositoryButton.IsEnabled
                    ? changeRepositoryButton
                    : settingsChangeRepositoryButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                OnChangeRepositoryClick(actionButton, new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "repairRepository", StringComparison.Ordinal))
            {
                actionButton = protectionRepositoryRecoveryButton != null &&
                    protectionRepositoryRecoveryButton.IsEnabled
                    ? protectionRepositoryRecoveryButton
                    : settingsRepositoryRecoveryButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                OnRepairRepositoryClick(actionButton, new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "reviewChanges", StringComparison.Ordinal))
            {
                actionButton = reviewChangesButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                OnReviewChangesClick(actionButton, new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "openRestore", StringComparison.Ordinal))
            {
                actionButton = openRestoreCenterButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                OnOpenRestoreCenterClick(actionButton, new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "checkReadiness", StringComparison.Ordinal))
            {
                actionButton = checkRecoveryReadinessButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                OnCheckRecoveryReadinessClick(actionButton, new RoutedEventArgs());
                return true;
            }
            if (string.Equals(command, "exportDiagnostics", StringComparison.Ordinal))
            {
                actionButton = exportDiagnosticsButton;
                if (!CheckWebAction(actionButton, out error)) return false;
                OnExportDiagnosticsClick(actionButton, new RoutedEventArgs());
                return true;
            }

            error = "The requested dashboard command is not allowed.";
            return false;
        }

        // Opens the license notices that ship with the app (Restic, Python, WebView2 and the web dependencies): always the
        // "licenses" folder beside this executable, built from the app's own base directory. Nothing the page sends is
        // part of the path, and a folder that is missing or is a link is not opened.
        private static bool OpenLicensesFolder(out string error)
        {
            error = string.Empty;
            string folder;
            try
            {
                folder = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "licenses");
                DirectoryInfo licenses = new DirectoryInfo(folder);
                if (!licenses.Exists || (licenses.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    error = "The licenses folder is not next to this copy of Rewindle.";
                    return false;
                }
                folder = licenses.FullName;
            }
            catch (Exception exception)
            {
                error = "The licenses folder could not be found. " + exception.Message;
                return false;
            }
            try
            {
                // Quoted the way the other open-location commands quote a folder, so a name with spaces is one argument.
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "\"" + folder.Replace("\"", string.Empty) + "\"",
                    UseShellExecute = true
                });
                return true;
            }
            catch (Exception exception)
            {
                error = "The licenses folder could not be opened. " + exception.Message;
                return false;
            }
        }

        // Makes the dashboard larger or smaller, for people who need larger text. "in" and "out" step from where the page is now
        // (Ctrl+mouse wheel zooms it by itself, so it can be at any size), and "reset" returns to 100%. The new size is the
        // answer, which the page shows as a notice and so also tells a screen reader. It is not saved: Rewindle starts at 100%,
        // as it always has.
        private bool ExecuteZoomCommand(IDictionary<string, object> payload, out string message)
        {
            message = string.Empty;
            string direction = WebReadString(payload, "zoom", 16);
            if (direction != "in" && direction != "out" && direction != "reset")
            {
                message = "The requested zoom is invalid.";
                return false;
            }
            WebView2 view = webPresentation;
            if (view == null || webPresentationClosing || WebPresentationCore() == null)
            {
                message = "The dashboard is still starting. Try zooming again in a moment.";
                return false;
            }
            try
            {
                double current = view.ZoomFactor;
                double next = current;
                if (direction == "reset")
                {
                    next = 1.0;
                }
                else if (direction == "in")
                {
                    foreach (double step in WebZoomSteps)
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
                    for (int index = WebZoomSteps.Length - 1; index >= 0; index--)
                    {
                        if (WebZoomSteps[index] < current - 0.005)
                        {
                            next = WebZoomSteps[index];
                            break;
                        }
                    }
                }
                bool changed = Math.Abs(next - current) > 0.0001;
                if (changed || direction == "reset")
                {
                    view.ZoomFactor = next;
                }
                string percent = Math.Round(next * 100, MidpointRounding.AwayFromZero)
                    .ToString("0", CultureInfo.CurrentCulture) + "%";
                message = changed || direction == "reset"
                    ? "Zoom " + percent
                    : direction == "in"
                        ? "Zoom is at its largest, " + percent
                        : "Zoom is at its smallest, " + percent;
                return true;
            }
            catch (Exception error)
            {
                message = "The zoom could not be changed. " + error.Message;
                return false;
            }
        }

        private bool CheckWebAction(Button button, out string error)
        {
            if (button == null)
            {
                error = "The requested dashboard action is unavailable.";
                return false;
            }
            if (!button.IsEnabled)
            {
                error = button.ToolTip == null
                    ? "The requested dashboard action is currently unavailable."
                    : button.ToolTip.ToString();
                return false;
            }
            error = string.Empty;
            return true;
        }

        private bool CheckVisibleWebAction(Button button, out string error)
        {
            if (!CheckWebAction(button, out error))
            {
                return false;
            }
            if (button.Visibility != Visibility.Visible)
            {
                error = "The requested dashboard action is currently unavailable.";
                return false;
            }
            return true;
        }

        private Button FindRemoveSourceButton(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return null;
            }
            foreach (Button button in removeSourceButtons)
            {
                BackupSourceView source = button.Tag as BackupSourceView;
                if (source != null &&
                    string.Equals(source.SourcePath, path, StringComparison.OrdinalIgnoreCase))
                {
                    return button;
                }
            }
            return null;
        }

        private RunMetricView FindHistoryRun(string runId)
        {
            if (historyGrid == null || string.IsNullOrWhiteSpace(runId))
            {
                return null;
            }
            return historyGrid.Items.OfType<RunMetricView>().FirstOrDefault(
                run => string.Equals(run.RunId, runId, StringComparison.Ordinal));
        }

        private static string WebReadString(
            IDictionary<string, object> values,
            string key,
            int maximumLength)
        {
            if (values == null)
            {
                return string.Empty;
            }
            object value;
            if (!values.TryGetValue(key, out value) || value == null)
            {
                return string.Empty;
            }
            string result = Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty;
            if (result.Length > maximumLength)
            {
                return string.Empty;
            }
            return result;
        }

        private bool CanShowWebRunDetails()
        {
            return options != null && !options.UseNativePresentation &&
                webPresentation != null && webPresentationReady && webPresentationHandshakeReady &&
                !webPresentationClosing && WebPresentationCore() != null &&
                (webPresentationErrorSurface == null || webPresentationErrorSurface.Visibility != Visibility.Visible);
        }

        private void ShowWebRunDetails(RunMetricView run)
        {
            SourceConfiguration configuration = currentSourceConfiguration ??
                SourceConfiguration.Load();
            RunDetails details = RunDetailsReader.Load(configuration, run);
            webRunDetailsRun = run;
            webRunDetails = details;
            PublishWebPresentationState();
        }

        private static bool IsRunDetailsCommand(string command)
        {
            return command == "closeRunDetails" || command == "copyRunSummary" ||
                command == "copyRunEvents" || command == "copyRunSnapshot" ||
                command == "openRunLogLocation";
        }

        private bool ExecuteRunDetailsCommand(
            string command,
            IDictionary<string, object> payload,
            out string message)
        {
            message = string.Empty;
            // All actions refer to the exact run already loaded by the trusted reader.
            // The web surface never supplies a filesystem path or clipboard contents.
            string runId = WebReadString(payload, "runId", 128);
            if (webRunDetails == null || !string.Equals(
                runId, webRunDetails.RunId, StringComparison.Ordinal))
            {
                message = "These run details are no longer open. Select the run again.";
                return false;
            }
            if (command == "closeRunDetails")
            {
                webRunDetails = null;
                webRunDetailsRun = null;
                PublishWebPresentationState();
                return true;
            }
            try
            {
                string clipboardProblem;
                if (command == "copyRunSummary")
                {
                    if (!ClipboardText.TrySet(webRunDetails.CopyText(), out clipboardProblem))
                    {
                        message = clipboardProblem;
                        return false;
                    }
                    // The summary lists the affected paths, which can name private folders and files.
                    message = webRunDetails.AffectedPaths != null && webRunDetails.AffectedPaths.Count > 0
                        ? "Run summary copied. It lists file paths, so review it before sharing."
                        : "Run summary copied.";
                }
                else if (command == "copyRunSnapshot")
                {
                    string snapshot = webRunDetails.SnapshotId;
                    if (string.IsNullOrWhiteSpace(snapshot) || snapshot == "-" || snapshot == "\u2014")
                    {
                        message = "This run has no recorded snapshot ID.";
                        return false;
                    }
                    if (!ClipboardText.TrySet(snapshot, out clipboardProblem))
                    {
                        message = clipboardProblem;
                        return false;
                    }
                    message = "Snapshot ID copied.";
                }
                else if (command == "copyRunEvents")
                {
                    object rawQuery;
                    if (payload == null || !payload.TryGetValue("query", out rawQuery) ||
                        !(rawQuery is string) || ((string)rawQuery).Length > 4096)
                    {
                        message = "The event filter is invalid.";
                        return false;
                    }
                    string query = ((string)rawQuery).Trim();
                    IList<string> events = webRunDetails.Events ?? new List<string>();
                    string[] visible = events.Where(line => string.IsNullOrEmpty(query) ||
                        line.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0).ToArray();
                    if (visible.Length == 0)
                    {
                        message = "No events match this filter.";
                        return false;
                    }
                    if (!ClipboardText.TrySet(string.Join(Environment.NewLine, visible), out clipboardProblem))
                    {
                        message = clipboardProblem;
                        return false;
                    }
                    message = visible.Length.ToString(CultureInfo.CurrentCulture) +
                        (visible.Length == 1 ? " event copied." : " events copied.");
                }
                else if (command == "openRunLogLocation")
                {
                    if (!webRunDetails.HasLog)
                    {
                        message = "The log file is no longer available.";
                        return false;
                    }
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = "explorer.exe",
                        Arguments = "/select,\"" + webRunDetails.LogPath + "\"",
                        UseShellExecute = true
                    });
                }
                return true;
            }
            catch (Exception exception)
            {
                message = "The run-details action could not be completed. " + exception.Message;
                return false;
            }
        }

        private Dictionary<string, object> BuildWebRunDetailsState()
        {
            if (webRunDetails == null || webRunDetailsRun == null) return null;
            RunDetails details = webRunDetails;
            RunMetricView run = webRunDetailsRun;
            return new Dictionary<string, object>
            {
                { "id", details.RunId },
                { "type", details.TypeLabel },
                { "result", details.ResultLabel },
                { "success", run.Success },
                { "started", run.StartedLocal.ToString("o", CultureInfo.InvariantCulture) },
                { "startedDisplay", details.StartedDisplay },
                { "durationDisplay", details.DurationDisplay },
                { "filesDisplay", run.FilesDisplay },
                { "processedDisplay", run.ProcessedBytesDisplay },
                { "storedDisplay", run.StoredBytesDisplay },
                { "phase", details.Phase },
                { "failureCode", details.FailureCode },
                { "exitCode", details.ExitCode },
                { "snapshotId", details.SnapshotId },
                { "failure", details.Failure },
                { "remediation", details.Remediation },
                { "affectedPaths", details.AffectedPaths },
                { "events", details.Events },
                { "eventsTruncated", details.EventsTruncated },
                { "logNote", details.LogNote ?? string.Empty },
                { "hasLog", details.HasLog }
            };
        }

        private void SendWebCommandResult(string id, bool ok, string message)
        {
            CoreWebView2 core = WebPresentationCore();
            if (webPresentationClosing || !webPresentationReady || core == null)
            {
                return;
            }
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["type"] = "result";
            result["id"] = id ?? string.Empty;
            result["ok"] = ok;
            if (!string.IsNullOrWhiteSpace(message))
            {
                result["message"] = message;
            }
            try
            {
                core.PostWebMessageAsJson(
                    webPresentationSerializer.Serialize(result));
            }
            catch
            {
                // The renderer may have exited between the command and the response.
            }
        }

        // Asks for the state to be sent to the page. Many things ask in one turn (a refresh, a changed selection and a
        // rebound history list each publish while one tick is applied), and the page only needs the outcome, so the
        // request is honoured once, after the work that made it has finished. A command's own answer sends it first
        // (see OnWebPresentationMessageReceived), so the page still sees the state before the answer that refers to it.
        private void PublishWebPresentationState()
        {
            if (webPresentationClosing || options == null || options.UseNativePresentation ||
                webPresentation == null)
            {
                return;
            }
            if (!Dispatcher.CheckAccess())
            {
                Dispatcher.BeginInvoke(new Action(PublishWebPresentationState));
                return;
            }
            if (webPresentationPublishQueued)
            {
                return;
            }
            webPresentationPublishQueued = true;
            Dispatcher.BeginInvoke(
                new Action(FlushWebPresentationState),
                DispatcherPriority.Background);
        }

        // Sends a state that is waiting for its turn, if there is one. Safe to call when there is none.
        private void FlushWebPresentationState()
        {
            if (!webPresentationPublishQueued)
            {
                return;
            }
            webPresentationPublishQueued = false;
            PostWebPresentationState(false);
        }

        // For a page that has just announced itself: it has no state yet, so one goes out immediately, whatever was
        // sent before and whether or not the window is showing.
        private void PublishWebPresentationStateNow()
        {
            if (webPresentationClosing || options == null || options.UseNativePresentation ||
                webPresentation == null)
            {
                return;
            }
            webPresentationPublishQueued = false;
            webPresentationLastPostedState = null;
            PostWebPresentationState(true);
        }

        // Builds the state and posts it to the page. `force` sends it in full even if it has not changed and the window is
        // hidden. Otherwise a state identical to the last one sent is not sent again, and a window nobody can see is only
        // told the app is alive: the page takes about fifteen seconds of silence for a lost connection and then refuses
        // protected commands, so silence it was never owed a state for must not look like that.
        private void PostWebPresentationState(bool force)
        {
            if (webPresentationClosing || options == null || options.UseNativePresentation ||
                webPresentation == null)
            {
                return;
            }
            try
            {
                CoreWebView2 core = WebPresentationCore();
                if (!webPresentationReady || !webPresentationHandshakeReady || core == null)
                {
                    // The page asks for its first state itself, once it has loaded.
                    return;
                }
                bool unresponsive = webPresentationUnresponsiveSinceUtc != DateTime.MinValue;
                if (!force && (unresponsive || !IsVisible || WindowState == WindowState.Minimized))
                {
                    // A stuck page cannot read what is posted, and a browser keeps every message it is sent, so it is
                    // not sent a minute of states it will only throw away. A window that is hidden is sent the state
                    // when it is shown again (OnWindowVisibilityChanged).
                    PostWebHeartbeat(core);
                    return;
                }
                Dictionary<string, object> envelope = new Dictionary<string, object>();
                envelope["type"] = "state";
                envelope["state"] = BuildWebPresentationState();
                string state = webPresentationSerializer.Serialize(envelope);
                if (!force && string.Equals(state, webPresentationLastPostedState, StringComparison.Ordinal))
                {
                    PostWebHeartbeat(core);
                }
                else
                {
                    core.PostWebMessageAsJson(state);
                    webPresentationLastPostedState = state;
                    webPresentationLastPostUtc = DateTime.UtcNow;
                }
                if (webPresentationPublishFailures >= WebPresentationPublishFailureLimit)
                {
                    // Delivery works again after a streak that raised the notice.
                    HideWebPresentationFailure();
                }
                webPresentationPublishFailures = 0;
            }
            catch (Exception error)
            {
                // One failed delivery is retried by the next refresh; only a streak is worth interrupting for.
                webPresentationPublishFailures++;
                if (webPresentationPublishFailures == WebPresentationPublishFailureLimit)
                {
                    ShowWebPresentationFailure(
                        "The dashboard stopped updating",
                        "The latest backup status could not be sent to the dashboard several times in a " +
                            "row. Choose Reload to try again. Backups run separately and are not affected.",
                        error.Message,
                        true,
                        false);
                }
            }
        }

        // A message with no state in it. The page counts any message as proof that the app is alive, which is all it asks
        // of the silence that an unchanged state, or a window nobody can see, leaves.
        private void PostWebHeartbeat(CoreWebView2 core)
        {
            DateTime now = DateTime.UtcNow;
            if (now - webPresentationLastPostUtc < WebPresentationHeartbeatInterval)
            {
                return;
            }
            core.PostWebMessageAsJson("{\"type\":\"heartbeat\"}");
            webPresentationLastPostUtc = now;
        }

        private Dictionary<string, object> BuildWebPresentationState()
        {
            TelemetrySnapshot snapshot = lastSnapshot;
            Dictionary<string, object> state = new Dictionary<string, object>();
            state["page"] = selectedDashboardPage;
            state["demo"] = false;
            state["preview"] = previewEnabled;
            state["dataError"] = webTelemetryError ?? string.Empty;
            // The page formats some dates and figures itself; they follow the same regional format as the
            // strings built here, even when Windows shows its menus in another language.
            state["locale"] = CultureInfo.CurrentCulture.Name;
            state["theme"] = themePreference.ToString();
            state["motion"] = motionPreference.ToString();
            state["dark"] = themeResolution != null && themeResolution.Palette.IsDark;
            state["reducedMotion"] = motionResolution == null || !motionResolution.MotionAllowed;
            state["highContrast"] = themeResolution != null && themeResolution.IsHighContrast;
            state["updated"] = lastUpdated == null ? string.Empty : lastUpdated.Text ?? string.Empty;
            state["subtitle"] = headerSubtitle == null ? string.Empty : headerSubtitle.Text ?? string.Empty;
            state["status"] = BuildWebStatusState(snapshot);
            state["sources"] = BuildWebSourceStates();
            state["sourceStatus"] = sourceStatus == null ? string.Empty : sourceStatus.Text ?? string.Empty;
            state["sourceNotice"] = BuildWebSourceNoticeState();
            state["sourceOperation"] = BuildWebSourceOperationState();
            state["sourcePicker"] = BuildWebSourcePickerState();
            state["history"] = BuildWebHistoryStates(snapshot);
            state["historyTruncated"] = snapshot != null && snapshot.HistoryTruncated;
            // The reader's own limit, so the page names it instead of keeping a copy of the number.
            state["historyLimit"] = TelemetryReader.HistoryLimit;
            RunMetricView selected = historyGrid == null ? null : historyGrid.SelectedItem as RunMetricView;
            state["selectedRunId"] = selected == null ? null : selected.RunId;
            state["runDetails"] = BuildWebRunDetailsState();
            state["schedule"] = BuildWebScheduleState();
            state["repository"] = BuildWebRepositoryState();
            state["freshness"] = BuildWebFreshnessState(snapshot);
            state["offsite"] = BuildWebOffsiteState(snapshot);
            state["recovery"] = BuildWebRecoveryState();
            state["setup"] = BuildWebSetupState();
            state["restoreFlow"] = BuildWebRestoreFlowState();
            state["actions"] = BuildWebActionStates();
            return state;
        }

        // Whether the backup service this dashboard reports on is installed, and enough about this computer for a bug report. It is
        // additive and read-only: no action is gated on it (each action keeps its own rules), it only lets the page give one
        // explanation instead of an "unavailable" in every widget. `engineFound` is false only once Rewindle is sure nothing is
        // installed (see RefreshSources), so a configuration that cannot be read just now is not taken for a first run. `problem` is
        // the one fixed sentence for whatever is wrong with the configuration while none is in use, and empty while one is.
        private Dictionary<string, object> BuildWebSetupState()
        {
            Dictionary<string, object> setup = new Dictionary<string, object>();
            setup["engineFound"] = !sourceInstallationMissing;
            setup["problem"] = currentSourceConfiguration == null
                ? (sourceConfigurationNote ?? string.Empty)
                : string.Empty;
            setup["expectedConfig"] = SourceConfiguration.ExpectedConfigurationPath();
            setup["stateFolder"] = options == null ? string.Empty : options.StateDirectory ?? string.Empty;
            // The release version from VERSION ("0.2.0-alpha.1"), as About and a bug report name it.
            setup["appVersion"] = Program.DisplayVersion();
            setup["os"] = Environment.OSVersion.VersionString;
            setup["webView2"] = DescribeWebViewVersion();
            // The engine this window reports on, how it was chosen, its version and every place an engine was looked
            // for. Fixed names and the validated version file only (see EngineProfile).
            EngineSelection engine = options == null ? null : options.Engine;
            EngineProfile profile = engine == null ? EngineProfile.Current : engine.Profile;
            setup["engine"] = profile.DisplayName;
            setup["engineProfile"] = profile.Id;
            setup["engineVersion"] = CachedEngineVersion(profile);
            setup["engineChosenBy"] = engine != null && engine.Requested ? "--engine" : "install-root";
            setup["searchedConfigs"] = engine == null
                ? new List<string>()
                : new List<string>(engine.SearchedConfigurationPaths());
            return setup;
        }

        // The engine's version file is read once while it is installed, not on every publish (about once a second); a new
        // reading is taken after the engine has been reported missing.
        private string engineVersionText;
        private string engineVersionProfileId;

        private string CachedEngineVersion(EngineProfile profile)
        {
            if (sourceInstallationMissing)
            {
                engineVersionText = null;
                return string.Empty;
            }
            if (engineVersionText == null ||
                !string.Equals(engineVersionProfileId, profile.Id, StringComparison.Ordinal))
            {
                engineVersionText = profile.ReadEngineVersion();
                engineVersionProfileId = profile.Id;
            }
            return engineVersionText;
        }

        // The version of the WebView2 Runtime behind the page, which is half of what a report about a page that will not draw needs.
        // It does not change while the app runs, so it is asked once it can be answered.
        private string webViewVersionText;

        private string DescribeWebViewVersion()
        {
            if (!string.IsNullOrEmpty(webViewVersionText))
            {
                return webViewVersionText;
            }
            try
            {
                CoreWebView2 core = WebPresentationCore();
                if (core != null && core.Environment != null)
                {
                    webViewVersionText = core.Environment.BrowserVersionString ?? string.Empty;
                }
            }
            catch (Exception)
            {
                // A runtime that cannot say is reported as unknown.
            }
            return webViewVersionText ?? string.Empty;
        }

        private Dictionary<string, object> BuildWebStatusState(TelemetrySnapshot snapshot)
        {
            Dictionary<string, object> status = new Dictionary<string, object>();
            bool presentationPreview = previewEnabled && string.IsNullOrEmpty(webTelemetryError);
            if (!string.IsNullOrEmpty(webTelemetryError)) snapshot = null;
            status["key"] = presentationPreview
                ? "preview"
                : snapshot == null ? "unknown" : snapshot.StateKey ?? "unknown";
            status["title"] = heroTitle == null ? string.Empty : heroTitle.Text ?? string.Empty;
            status["detail"] = heroDetail == null ? string.Empty : heroDetail.Text ?? string.Empty;
            status["badge"] = statusBadgeText == null ? string.Empty : statusBadgeText.Text ?? string.Empty;
            status["active"] = presentationPreview || (snapshot != null && snapshot.IsActive);
            status["success"] = !presentationPreview && snapshot != null && snapshot.IsSuccess;
            status["failure"] = !presentationPreview && snapshot != null && snapshot.IsFailure;
            // True when nothing could be read (see TelemetrySnapshot.IsStatusUnavailable): neither a failed run nor a healthy one.
            status["unavailable"] = !presentationPreview && snapshot != null && snapshot.IsStatusUnavailable;
            status["cancelled"] = !presentationPreview && snapshot != null && snapshot.IsCancelled;
            double displayedProgress = presentationPreview
                ? currentProgress
                : snapshot == null ? 0.0 : Math.Max(0.0, Math.Min(1.0, snapshot.Percent));
            status["phaseIndex"] = presentationPreview
                ? (displayedProgress < 0.90 ? 0 : displayedProgress < 0.94 ? 1 : displayedProgress < 0.97 ? 2 : 3)
                : snapshot == null ? -1 : snapshot.PhaseIndex;
            status["phaseLabel"] = presentationPreview
                ? "Preview telemetry"
                : snapshot == null ? string.Empty : snapshot.PhaseLabel ?? string.Empty;
            status["progress"] = displayedProgress;
            status["estimated"] = presentationPreview || snapshot != null && snapshot.ProgressIsEstimated;
            status["runId"] = snapshot == null ? string.Empty : snapshot.RunId ?? string.Empty;
            status["files"] = filesValue == null ? string.Empty : filesValue.Text ?? string.Empty;
            status["bytes"] = bytesValue == null ? string.Empty : bytesValue.Text ?? string.Empty;
            status["speed"] = speedValue == null ? string.Empty : speedValue.Text ?? string.Empty;
            status["elapsed"] = elapsedValue == null ? string.Empty : elapsedValue.Text ?? string.Empty;
            status["errors"] = errorsValue == null ? string.Empty : errorsValue.Text ?? string.Empty;
            status["etaTitle"] = etaTitle == null ? string.Empty : etaTitle.Text ?? string.Empty;
            status["eta"] = etaValue == null ? string.Empty : etaValue.Text ?? string.Empty;
            status["etaHint"] = etaHint == null ? string.Empty : etaHint.Text ?? string.Empty;
            if (!string.IsNullOrEmpty(webTelemetryError))
            {
                status["title"] = "Dashboard data is temporarily unavailable";
                status["detail"] = webTelemetryError;
                status["badge"] = "Status unavailable";
                foreach (string metric in new[] { "files", "bytes", "speed", "elapsed", "errors", "eta" })
                    status[metric] = "—";
            }
            return status;
        }

        private List<Dictionary<string, object>> BuildWebSourceStates()
        {
            List<Dictionary<string, object>> result = new List<Dictionary<string, object>>();
            List<BackupSourceView> sources = new List<BackupSourceView>();
            if (currentSourceConfiguration != null && currentSourceConfiguration.Sources != null)
            {
                sources.AddRange(currentSourceConfiguration.Sources);
            }

            RefreshWebSourceExistence(sources);
            foreach (BackupSourceView source in sources)
            {
                bool exists = IsWebSourceAvailable(source.SourcePath);
                Dictionary<string, object> item = new Dictionary<string, object>();
                item["path"] = source.SourcePath ?? string.Empty;
                item["name"] = source.DisplayName ?? string.Empty;
                item["isCanary"] = source.IsProtectedCanary;
                item["exists"] = exists;
                item["canRemove"] = !source.IsProtectedCanary &&
                    FindRemoveSourceButton(source.SourcePath) != null &&
                    FindRemoveSourceButton(source.SourcePath).IsEnabled;
                item["detail"] = source.RoleLabel + "  •  " + source.ShortPath;
                result.Add(item);
            }
            return result;
        }

        // A folder is assumed present until a probe says otherwise, so the first published state after
        // startup or after adding a folder never waits on the disk.
        private bool IsWebSourceAvailable(string path)
        {
            bool exists;
            return !webSourceExistence.TryGetValue(path ?? string.Empty, out exists) || exists;
        }

        private void RefreshWebSourceExistence(IList<BackupSourceView> sources)
        {
            if (webSourceExistenceProbeInFlight || sources.Count == 0)
            {
                return;
            }
            bool unknownFolder = false;
            foreach (BackupSourceView source in sources)
            {
                if (!webSourceExistence.ContainsKey(source.SourcePath ?? string.Empty))
                {
                    unknownFolder = true;
                    break;
                }
            }
            if (!unknownFolder &&
                DateTime.UtcNow - webSourceExistenceCheckedUtc < WebSourceExistenceRefreshInterval)
            {
                return;
            }
            ProbeWebSourceExistenceAsync(sources
                .Select(source => source.SourcePath ?? string.Empty)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray());
        }

        private async void ProbeWebSourceExistenceAsync(string[] paths)
        {
            webSourceExistenceProbeInFlight = true;
            Dictionary<string, bool> probed = null;
            try
            {
                probed = await Task.Run(delegate
                {
                    Dictionary<string, bool> values =
                        new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
                    foreach (string path in paths)
                    {
                        bool exists;
                        try
                        {
                            exists = path.Length > 0 && Directory.Exists(path);
                        }
                        catch
                        {
                            exists = false;
                        }
                        values[path] = exists;
                    }
                    return values;
                });
            }
            catch
            {
                // Keep the previous answers; the next refresh probes again.
            }
            finally
            {
                webSourceExistenceProbeInFlight = false;
            }
            if (probed == null)
            {
                return;
            }
            webSourceExistenceCheckedUtc = DateTime.UtcNow;
            bool changed = false;
            foreach (KeyValuePair<string, bool> item in probed)
            {
                if (IsWebSourceAvailable(item.Key) != item.Value)
                {
                    changed = true;
                    break;
                }
            }
            webSourceExistence = probed;
            if (changed)
            {
                PublishWebPresentationState();
            }
        }

        // The outcome of the latest folder change, shown only while its timer runs. The same timer already
        // decides when the native status line falls back to its default text.
        private Dictionary<string, object> BuildWebSourceNoticeState()
        {
            if (DateTime.UtcNow >= sourceNoticeExpiresUtc || string.IsNullOrWhiteSpace(sourceNoticeText))
            {
                return null;
            }
            Dictionary<string, object> notice = new Dictionary<string, object>();
            notice["text"] = sourceNoticeText;
            notice["tone"] = sourceNoticeTone;
            return notice;
        }

        private Dictionary<string, object> BuildWebSourceOperationState()
        {
            Dictionary<string, object> operation = new Dictionary<string, object>();
            bool active = sourceOperationInProgress ||
                sourceOperationStage == SourceOperationStage.AwaitingApproval ||
                sourceOperationStage == SourceOperationStage.Applying ||
                sourceOperationStage == SourceOperationStage.Verifying;
            operation["active"] = active;
            operation["stage"] = sourceOperationStage.ToString();
            operation["path"] = sourceOperationPath ?? string.Empty;
            string message = sourceOperationError;
            if (string.IsNullOrWhiteSpace(message) && sourceOperationStatusText != null)
            {
                message = sourceOperationStatusText.Text;
            }
            operation["message"] = message ?? string.Empty;
            return operation;
        }

        private List<Dictionary<string, object>> BuildWebHistoryStates(TelemetrySnapshot snapshot)
        {
            List<Dictionary<string, object>> result = new List<Dictionary<string, object>>();
            IList<RunMetricView> history = snapshot == null || snapshot.History == null
                ? new List<RunMetricView>()
                : snapshot.History;
            foreach (RunMetricView run in history)
            {
                Dictionary<string, object> item = new Dictionary<string, object>();
                item["id"] = run.RunId ?? string.Empty;
                item["started"] = run.StartedLocal.ToString("o", CultureInfo.InvariantCulture);
                item["startedDisplay"] = run.StartedDisplay;
                item["type"] = run.TypeLabel ?? string.Empty;
                item["result"] = run.StateLabel ?? string.Empty;
                item["success"] = run.Success;
                item["durationSeconds"] = Math.Max(0.0, run.DurationSeconds);
                item["durationDisplay"] = run.DurationDisplay;
                item["files"] = run.Files;
                item["filesDisplay"] = run.FilesDisplay;
                item["processedBytes"] = run.ProcessedBytes;
                item["processedDisplay"] = run.ProcessedBytesDisplay;
                item["storedBytes"] = run.StoredBytes;
                item["storedDisplay"] = run.StoredBytesDisplay;
                item["snapshot"] = run.SnapshotShort ?? string.Empty;
                result.Add(item);
            }
            return result;
        }

        private Dictionary<string, object> BuildWebScheduleState()
        {
            // A schedule that cannot be read has a stable summary. The reason Windows gave can be long and technical
            // (up to 2,000 characters), so it travels on its own as `error`, for the page to word the problem and keep
            // the original under Details, rather than standing in for the summary and the detail.
            bool unreadable = currentTaskSchedule == null;
            Dictionary<string, object> schedule = new Dictionary<string, object>();
            schedule["summary"] = unreadable ? "Schedule unavailable" : currentTaskSchedule.Summary;
            schedule["nextRun"] = unreadable ? "Unavailable" : currentTaskSchedule.NextRunDisplay;
            schedule["detail"] = unreadable ? string.Empty : currentTaskSchedule.SettingsSummary;
            schedule["error"] = unreadable
                ? (string.IsNullOrWhiteSpace(scheduleReadError) ? "The installed schedule could not be verified." : scheduleReadError)
                : string.Empty;
            schedule["notice"] = BuildWebScheduleNoticeState();
            return schedule;
        }

        // The outcome of the latest schedule change. It lapses with its timer, except while a change is still being
        // applied: waiting for Windows approval takes as long as the person does, and its progress must stay up.
        private Dictionary<string, object> BuildWebScheduleNoticeState()
        {
            if (string.IsNullOrWhiteSpace(scheduleNoticeText))
            {
                return null;
            }
            if (!scheduleOperationInProgress && DateTime.UtcNow >= scheduleNoticeExpiresUtc)
            {
                return null;
            }
            Dictionary<string, object> notice = new Dictionary<string, object>();
            notice["text"] = scheduleNoticeText;
            notice["tone"] = string.IsNullOrWhiteSpace(scheduleNoticeTone) ? "info" : scheduleNoticeTone;
            return notice;
        }

        private Dictionary<string, object> BuildWebRepositoryState()
        {
            Dictionary<string, object> repository = new Dictionary<string, object>();
            repository["path"] = currentSourceConfiguration == null
                ? settingsRepositoryValue == null ? string.Empty : settingsRepositoryValue.Text ?? string.Empty
                : currentSourceConfiguration.RepositoryPath ?? string.Empty;
            repository["volume"] = settingsRepositoryVolume == null
                ? string.Empty
                : settingsRepositoryVolume.Text ?? string.Empty;
            // False only when the drive itself said it is not ready, so the page can warn about a missing backup drive
            // without reading it out of the volume text.
            repository["volumeReady"] = repositoryVolumeReady;
            return repository;
        }

        private Dictionary<string, object> BuildWebFreshnessState(TelemetrySnapshot snapshot)
        {
            bool readable = snapshot != null && string.IsNullOrEmpty(webTelemetryError);
            BackupFreshnessResult result = BackupFreshnessEvaluator.EvaluateNow(
                readable ? currentTaskSchedule : null,
                readable ? snapshot.LastVerifiedFinishedUtc : null,
                scheduleCoveredThroughUtc);
            Dictionary<string, object> freshness = new Dictionary<string, object>();
            freshness["title"] = result.StatusLabel;
            freshness["detail"] = result.Detail;
            freshness["state"] = result.State.ToString();
            freshness["verifiedAt"] = result.LastVerifiedUtc.HasValue
                ? result.LastVerifiedUtc.Value.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture)
                : string.Empty;
            return freshness;
        }

        private Dictionary<string, object> BuildWebOffsiteState(TelemetrySnapshot snapshot)
        {
            Dictionary<string, object> offsite = new Dictionary<string, object>();
            offsite["title"] = settingsOffsiteStatus == null
                ? string.Empty
                : settingsOffsiteStatus.Text ?? string.Empty;
            offsite["detail"] = settingsOffsiteDetail == null
                ? string.Empty
                : settingsOffsiteDetail.Text ?? string.Empty;
            offsite["evidence"] = settingsOffsiteEvidence == null
                ? string.Empty
                : settingsOffsiteEvidence.Text ?? string.Empty;
            OffsiteStatusView status = snapshot == null || !string.IsNullOrEmpty(webTelemetryError)
                ? null : snapshot.OffsiteStatus;
            offsite["kind"] = status == null ? "StatusUnavailable" : status.Kind.ToString();
            offsite["checkedAt"] = status != null && status.LastUpdatedLocal.HasValue
                ? status.LastUpdatedLocal.Value.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture)
                : string.Empty;
            offsite["providerConfirmed"] = status != null && status.ProviderUploadConfirmed;
            offsite["restoreVerified"] = status != null && status.RestoreVerified;
            // The provider is named only when the evidence names one (a direct My Drive proof is Google Drive's); the page
            // otherwise says "off-site copy" and nothing more.
            offsite["provider"] = status == null ? string.Empty : status.ProviderLabel ?? string.Empty;
            return offsite;
        }

        private Dictionary<string, object> BuildWebRecoveryState()
        {
            RepositoryRecoveryStatus status = repositoryRecoveryStatus ?? RepositoryRecoveryStatus.None();
            Dictionary<string, object> recovery = new Dictionary<string, object>();
            string readinessTitle = restoreReadinessTitle == null
                ? string.Empty
                : restoreReadinessTitle.Text ?? string.Empty;
            string readinessDetail = restoreReadinessDetail == null
                ? string.Empty
                : restoreReadinessDetail.Text ?? string.Empty;
            recovery["title"] = string.IsNullOrWhiteSpace(readinessTitle)
                ? (status.Exists ? "Repository repair required" : "Repository recovery clear")
                : readinessTitle;
            recovery["detail"] = string.IsNullOrWhiteSpace(readinessDetail)
                ? status.Message ?? string.Empty
                : readinessDetail;
            recovery["repairNeeded"] = status.Exists;
            recovery["repairMessage"] = protectionRepositoryRecoveryMessage == null
                ? string.Empty
                : protectionRepositoryRecoveryMessage.Text ?? string.Empty;
            recovery["repairState"] = protectionRepositoryRecoveryState == null
                ? string.Empty
                : protectionRepositoryRecoveryState.Text ?? string.Empty;
            recovery["repairBusy"] = repositoryRecoveryInProgress;
            recovery["repairPercent"] = repositoryRecoveryOperationPercent.HasValue
                ? (object)repositoryRecoveryOperationPercent.Value
                : null;
            return recovery;
        }

        private Dictionary<string, object> BuildWebActionStates()
        {
            Dictionary<string, object> actions = new Dictionary<string, object>();
            actions["togglePreview"] = BuildWebActionState(previewButton);
            actions["backupNow"] = BuildWebActionState(backupNowButton);
            actions["cancelBackup"] = BuildWebActionState(cancelBackupButton);
            actions["addSource"] = BuildWebActionState(addSourceButton);
            actions["retrySourceChange"] = BuildWebActionState(sourceOperationRetryButton);
            actions["dismissSourceChange"] = BuildWebActionState(sourceOperationDismissButton);
            actions["editSchedule"] = BuildWebActionState(editScheduleButton);
            actions["changeRepository"] = BuildWebActionState(changeRepositoryButton);
            actions["repairRepository"] = BuildWebActionState(
                protectionRepositoryRecoveryButton != null && protectionRepositoryRecoveryButton.IsEnabled
                    ? protectionRepositoryRecoveryButton
                    : settingsRepositoryRecoveryButton);
            actions["reviewChanges"] = BuildWebActionState(reviewChangesButton);
            actions["openRestore"] = BuildWebActionState(openRestoreCenterButton);
            actions["checkReadiness"] = BuildWebActionState(checkRecoveryReadinessButton);
            actions["viewRunDetails"] = BuildWebActionState(viewRunDetailsButton);
            actions["exportDiagnostics"] = BuildWebActionState(exportDiagnosticsButton);
            return actions;
        }

        private Dictionary<string, object> BuildWebActionState(Button button)
        {
            Dictionary<string, object> action = new Dictionary<string, object>();
            action["enabled"] = button != null && button.IsEnabled;
            action["visible"] = button != null && button.Visibility == Visibility.Visible;
            action["label"] = button == null || button.Content == null
                ? string.Empty
                : button.Content.ToString();
            object help = button == null ? null : button.ToolTip;
            action["help"] = help == null ? string.Empty : help.ToString();
            return action;
        }

        // The notice always offers Exit. Reload starts the web view again, and the runtime download is
        // only offered when the WebView2 Runtime is what is missing.
        private void ShowWebPresentationFailure(
            string title,
            string message,
            string detail,
            bool offerReload,
            bool offerRuntimeDownload)
        {
            ShowWebPresentationFailure(title, message, detail, offerReload, offerRuntimeDownload, false);
        }

        // `offerKeepWaiting` is for a page that has stopped answering but may only be busy: the notice then also lets the
        // person leave the page as it is.
        private void ShowWebPresentationFailure(
            string title,
            string message,
            string detail,
            bool offerReload,
            bool offerRuntimeDownload,
            bool offerKeepWaiting)
        {
            Action display = delegate
            {
                if (webPresentationClosing || webPresentationErrorSurface == null)
                {
                    return;
                }
                // The notice outlives theme changes, so it takes the current palette each time it is shown.
                ApplyWebPresentationNoticePalette();
                webPresentationUnresponsiveNoticeShown = offerKeepWaiting;
                string heading = string.IsNullOrWhiteSpace(title)
                    ? "Rewindle can't show its dashboard"
                    : title;
                string body = string.IsNullOrWhiteSpace(message)
                    ? "The dashboard's web interface is unavailable."
                    : message;
                webPresentationErrorTitle.Text = heading;
                webPresentationErrorText.Text = body;
                webPresentationErrorDetail.Text = detail ?? string.Empty;
                webPresentationErrorDetail.Visibility = string.IsNullOrWhiteSpace(detail)
                    ? Visibility.Collapsed
                    : Visibility.Visible;
                webPresentationKeepWaitingButton.Visibility = offerKeepWaiting
                    ? Visibility.Visible
                    : Visibility.Collapsed;
                webPresentationReloadButton.Visibility = offerReload
                    ? Visibility.Visible
                    : Visibility.Collapsed;
                webPresentationRuntimeButton.Visibility = offerRuntimeDownload
                    ? Visibility.Visible
                    : Visibility.Collapsed;
                // The hosted browser paints above ordinary WPF content, so it steps aside while the
                // notice is up.
                if (webPresentation != null)
                {
                    webPresentation.Visibility = Visibility.Collapsed;
                }
                webPresentationErrorSurface.Visibility = Visibility.Visible;
                AutomationProperties.SetName(webPresentationErrorSurface, heading + ". " + body);
                Button primary = offerKeepWaiting
                    ? webPresentationKeepWaitingButton
                    : offerRuntimeDownload
                        ? webPresentationRuntimeButton
                        : offerReload ? webPresentationReloadButton : webPresentationExitButton;
                primary.Focus();
            };
            if (Dispatcher.CheckAccess())
            {
                display();
            }
            else if (!Dispatcher.HasShutdownStarted && !Dispatcher.HasShutdownFinished)
            {
                Dispatcher.BeginInvoke(display);
            }
        }

        private void HideWebPresentationFailure()
        {
            Action hide = delegate
            {
                // A page that loads, announces itself or reloads is no longer the stuck one (OnWebPresentationKeepWaitingClick
                // starts the wait over after this).
                webPresentationUnresponsiveSinceUtc = DateTime.MinValue;
                webPresentationUnresponsiveNoticeShown = false;
                if (webPresentationErrorSurface == null ||
                    webPresentationErrorSurface.Visibility != Visibility.Visible)
                {
                    return;
                }
                // One of the notice's buttons has keyboard focus when it is dismissed by Reload; hand it
                // back to the page so the keyboard shortcuts work again without a click.
                bool hadFocus = webPresentationErrorSurface.IsKeyboardFocusWithin;
                webPresentationErrorSurface.Visibility = Visibility.Collapsed;
                if (webPresentation != null)
                {
                    webPresentation.Visibility = Visibility.Visible;
                    if (hadFocus)
                    {
                        webPresentation.Focus();
                    }
                }
            };
            if (Dispatcher.CheckAccess())
            {
                hide();
            }
            else if (!Dispatcher.HasShutdownStarted && !Dispatcher.HasShutdownFinished)
            {
                Dispatcher.BeginInvoke(hide);
            }
        }

        private void DisposeWebPresentation()
        {
            webPresentationClosing = true;
            webPresentationReady = false;
            webPresentationHandshakeReady = false;
            webPresentationConfigured = false;
            webPresentationLastPostedState = null;
            webPresentationPublishQueued = false;

            WebView2 view = webPresentation;
            webPresentation = null;
            if (view == null)
            {
                return;
            }

            view.Loaded -= OnWebPresentationLoaded;
            try
            {
                view.Dispose();
            }
            catch
            {
                // The WebView2 controller may already be shutting down with the window.
            }
        }

        private static bool IsAllowedWebUri(string value)
        {
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri))
            {
                return false;
            }
            return string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(uri.Host, WebHostName, StringComparison.OrdinalIgnoreCase) &&
                string.IsNullOrEmpty(uri.UserInfo) &&
                (uri.Port == -1 || uri.Port == 443);
        }
    }
}
