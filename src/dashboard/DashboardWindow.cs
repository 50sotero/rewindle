using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ResticBackuper.Dashboard
{
    public sealed partial class DashboardWindow : Window
    {
        private enum SourceOperationStage
        {
            Idle,
            AwaitingApproval,
            Applying,
            Verifying,
            Succeeded,
            Cancelled,
            Failed
        }

        private Brush BackgroundTop { get { return themeResolution.Palette.BackgroundTop; } }
        private Brush BackgroundBottom { get { return themeResolution.Palette.BackgroundBottom; } }
        private Brush CardBrush { get { return themeResolution.Palette.Surface; } }
        private Brush CardSoftBrush { get { return themeResolution.Palette.SurfaceSoft; } }
        private Brush CardBorderBrush { get { return themeResolution.Palette.Border; } }
        private Brush PrimaryText { get { return themeResolution.Palette.TextPrimary; } }
        private Brush MutedText { get { return themeResolution.Palette.TextSecondary; } }
        private Brush Teal { get { return themeResolution.Palette.AccentPrimary; } }
        private Brush Blue { get { return themeResolution.Palette.AccentInfo; } }
        private Brush BlueText { get { return themeResolution.Palette.AccentInfoText; } }
        private Brush Green { get { return themeResolution.Palette.Success; } }
        private Brush Rose { get { return themeResolution.Palette.Danger; } }
        private Brush Amber { get { return themeResolution.Palette.Warning; } }

        private readonly AppOptions options;
        private readonly TelemetryReader reader;
        private readonly EventWaitHandle showEvent;
        private readonly DispatcherTimer refreshTimer;
        private readonly Forms.NotifyIcon trayIcon;
        private Drawing.Icon trayApplicationIcon;
        private readonly List<Border> phaseMarkers = new List<Border>();
        private readonly List<TextBlock> phaseLabels = new List<TextBlock>();
        private readonly Dictionary<DashboardThemePreference, Button> themeButtons =
            new Dictionary<DashboardThemePreference, Button>();
        private readonly Dictionary<DashboardMotionPreference, Button> motionButtons =
            new Dictionary<DashboardMotionPreference, Button>();

        private DashboardThemePreference themePreference;
        private DashboardThemeResolution themeResolution;
        private DashboardMotionPreference motionPreference;
        private DashboardMotionResolution motionResolution;
        private bool themeChangeInProgress;
        private Grid headerLayout;
        private FrameworkElement headerTitlePanel;
        private FrameworkElement headerActions;
        private Grid shellLayout;
        private Border navigationRail;
        private Grid navigationLayout;
        private Border navigationIndicator;
        private TranslateTransform navigationIndicatorTransform;
        private bool navigationIndicatorInitialized;
        private TextBlock navigationBrand;
        private Button protectionNavButton;
        private Button activityNavButton;
        private Button restoreNavButton;
        private Button settingsNavButton;
        private Grid pageHost;
        private FrameworkElement settingsPage;
        private FrameworkElement restorePage;
        private string selectedDashboardPage = "Protection";
        private FrameworkElement protectionOverview;
        private FrameworkElement protectionHero;
        private FrameworkElement protectionSources;
        private UniformGrid metricsLayout;
        private FrameworkElement activeProgressPanel;
        private FrameworkElement activePhaseRail;
        private Grid historyLayout;
        private FrameworkElement historyChart;
        private FrameworkElement historyTable;
        private Grid footerLayout;
        private TextBlock footerDetails;
        private bool? compactLayout;
        private FrameworkElement lastVisiblePage;
        private bool activeProgressWasVisible;
        private int lastAnimatedPhase = -1;
        private string historyAnimationSignature = string.Empty;
        // What the history list and chart were last given. Every refresh loads fresh run objects, and giving the same
        // runs to the grid again clears and restores its selection, so they are only bound again when a run differs.
        private string historyBindSignature;
        private bool historyRebindInProgress;

        private TextBlock statusBadgeText;
        private Ellipse statusDot;
        private Border statusBadge;
        private TextBlock heroTitle;
        private TextBlock heroDetail;
        private TextBlock progressPercent;
        private TextBlock estimateBadge;
        private Border progressTrack;
        private Border progressFill;
        private TranslateTransform shimmerTransform;
        private TextBlock etaTitle;
        private TextBlock etaValue;
        private TextBlock etaHint;
        private TextBlock filesValue;
        private TextBlock bytesValue;
        private TextBlock speedValue;
        private TextBlock elapsedValue;
        private TextBlock errorsValue;
        private TextBlock lastUpdated;
        private TextBlock runCount;
        private DataGrid historyGrid;
        private Button viewRunDetailsButton;
        private Button exportDiagnosticsButton;
        private StackPanel sourceList;
        private RunChart runChart;
        private Button previewButton;
        private Button backupNowButton;
        private Button cancelBackupButton;
        private Button reviewChangesButton;
        private Button editScheduleButton;
        private Button changeRepositoryButton;
        private Button settingsChangeRepositoryButton;
        private Button openRestoreCenterButton;
        private Button checkRecoveryReadinessButton;
        private TextBlock restoreReadinessTitle;
        private TextBlock restoreReadinessDetail;
        private Border protectionRepositoryRecoveryCard;
        private Border settingsRepositoryRecoveryCard;
        private TextBlock protectionRepositoryRecoveryMessage;
        private TextBlock settingsRepositoryRecoveryMessage;
        private TextBlock protectionRepositoryRecoveryState;
        private TextBlock settingsRepositoryRecoveryState;
        private Button protectionRepositoryRecoveryButton;
        private Button settingsRepositoryRecoveryButton;
        private ProgressBar protectionRepositoryRecoveryProgress;
        private ProgressBar settingsRepositoryRecoveryProgress;
        private Button addSourceButton;
        private readonly List<Button> removeSourceButtons = new List<Button>();
        private TextBlock sourceSummary;
        private TextBlock sourceStatus;
        private TextBlock headerSubtitle;
        private TextBlock repositoryValue;
        private TextBlock settingsRepositoryValue;
        private TextBlock settingsRepositoryVolume;
        private TextBlock metricsContext;
        private TextBlock cancelActionStatus;
        private TextBlock scheduleActionStatus;
        private TextBlock protectionFreshnessStatus;
        private TextBlock settingsFreshnessStatus;
        private TextBlock settingsFreshnessDetail;
        private TextBlock settingsOffsiteStatus;
        private TextBlock settingsOffsiteDetail;
        private TextBlock settingsOffsiteEvidence;
        private Border sourceOperationItem;
        private Border sourceOperationTag;
        private TextBlock sourceOperationTagText;
        private Border sourceOperationGlyphFrame;
        private TextBlock sourceOperationGlyph;
        private TextBlock sourceOperationStatusText;
        private TextBlock sourceOperationDetailText;
        private Border sourceOperationRail;
        private Border sourceOperationRailSegment;
        private TranslateTransform sourceOperationRailTransform;
        private Button sourceOperationRetryButton;
        private Button sourceOperationDismissButton;
        private readonly Dictionary<string, FrameworkElement> sourceRows =
            new Dictionary<string, FrameworkElement>(StringComparer.OrdinalIgnoreCase);

        private SourceConfiguration currentSourceConfiguration;
        private string sourceSignature;
        private bool sourceOperationInProgress;
        private DateTime sourceNoticeExpiresUtc = DateTime.MinValue;
        // What the web surface shows for the same notice: its own text and tone, independent of the
        // native status line, which other updates may overwrite while the notice is still live.
        private string sourceNoticeText = string.Empty;
        private string sourceNoticeTone = "info";
        private SourceOperationStage sourceOperationStage = SourceOperationStage.Idle;
        private string sourceOperationAction = string.Empty;
        private string sourceOperationPath = string.Empty;
        private string sourceOperationError = string.Empty;
        private string lastSourceOperationAnnouncement = string.Empty;
        private int sourceOperationGeneration;
        private DateTime sourceOperationExpiresUtc = DateTime.MinValue;
        private bool animateNextSourceOperationEntry;
        private bool animateNextResolvedSourceRow;
        private bool backupStartInProgress;
        private bool anomalyReviewInProgress;
        private bool diagnosticExportInProgress;
        private DateTime backupRequestPendingUntilUtc = DateTime.MinValue;
        private string backupRequestBaselineRunId = string.Empty;
        // Windows answers a backup request before it decides whether the task may start, so a task that one of its own
        // conditions holds back (it waits for AC power, say) leaves no run and nothing else to explain it. When the pending
        // window ends with no run, this note says so. It rides on the Back up now help until a run shows up or the next
        // request replaces it; the run it was waiting for is remembered so that a run that did start clears it.
        private const string BackupNotStartedNotice =
            "Windows accepted the last backup request, but the backup did not start. The task may be waiting for AC power " +
            "or another task condition (see Edit schedule).";
        private string backupNotStartedText = string.Empty;
        private string backupNotStartedBaselineRunId = string.Empty;
        private bool cancellationRequestInProgress;
        private bool cancellationAwaitingTerminal;
        private string cancellationRequestedRunId = string.Empty;
        private string cancellationNotice = string.Empty;
        private Brush cancellationNoticeColor;
        private DateTime cancellationNoticeExpiresUtc = DateTime.MinValue;
        private string cancellationUnavailableRunId = string.Empty;
        private TaskSchedule currentTaskSchedule;
        private string scheduleReadError = string.Empty;
        private bool scheduleOperationInProgress;
        // The latest schedule change as the web surface shows it: its sentence, its tone ("info", "success",
        // "warning" or "error") and when it lapses. The native status line says the same, but every schedule
        // read rewrites that line, so the web page keeps a copy of its own. Reads never set it; only a change does.
        private const int ScheduleNoticeSeconds = 45;
        private string scheduleNoticeText = string.Empty;
        private string scheduleNoticeTone = "info";
        private DateTime scheduleNoticeExpiresUtc = DateTime.MinValue;
        private bool repositoryOperationInProgress;
        private bool repositoryRecoveryInProgress;
        private RepositoryRecoveryStatus repositoryRecoveryStatus = RepositoryRecoveryStatus.None();
        private string repositoryRecoveryOperationMessage = string.Empty;
        private double? repositoryRecoveryOperationPercent;
        private string lastRepositoryRecoveryAnnouncement = string.Empty;
        private DateTime nextScheduleRefreshUtc = DateTime.MinValue;
        // The 1 Hz tick loads telemetry (several JSON files, and a durable write of the run history when a run
        // changed) off the UI thread. An explicit refresh moves the generation, so a tick result that
        // was already in flight is dropped instead of overwriting the newer state.
        private bool refreshTickInFlight;
        private int refreshGeneration;
        // schtasks.exe and the Task Scheduler COM calls can block for seconds, so after the first inline
        // read the schedule is read off the UI thread. A background result only applies while nothing
        // fresher has landed: the generation moves whenever a forced read or a schedule edit starts.
        private bool scheduleReadSeeded;
        private bool scheduleReadInFlight;
        private bool scheduleConfirmationInProgress;
        private int scheduleReadGeneration;
        // Storage-volume text is probed off the UI thread and cached: DriveInfo can stall on a
        // disconnected network or removable drive.
        private static readonly TimeSpan RepositoryVolumeRefreshInterval = TimeSpan.FromSeconds(60);
        private string repositoryVolumePath = string.Empty;
        private string repositoryVolumeText = "Storage volume unavailable";
        // False only when the drive answered that it is not ready (unplugged, disconnected). Assumed true until a probe says
        // otherwise, and when the drive could not be asked at all (a network share has no drive to ask), so the page does
        // not warn about a volume nobody knows to be gone. Published as repository.volumeReady.
        private bool repositoryVolumeReady = true;
        private DateTime repositoryVolumeCheckedUtc = DateTime.MinValue;
        private bool repositoryVolumeProbeInFlight;
        private BackupFreshnessState? lastAnnouncedFreshnessState;

        private bool allowClose;
        private bool previewEnabled;
        private DateTime previewStarted;
        private string lastStateKey;
        // Whether the snapshot before the current one was a run in progress. The state key is the run's phase, so it changes
        // several times inside one run, and only the step from "not running" to "running" is a backup starting.
        private bool lastSnapshotWasActive;
        // A status that cannot be read is no news, so it is not a state a run left or entered (see HandleStateTransition). These
        // remember that an unreadable spell has happened since the last readable snapshot, and which run that snapshot described,
        // so a run that finished while the status could not be read is still told apart from one that was already announced.
        private bool statusWasUnreadable;
        private string lastTransitionRunId;
        // The tray icon's own state: whether the first-close hint has been looked at in this process, and the hover text it shows
        // now (it only changes when the status does, so the shell is not asked to redraw the icon every second).
        private bool trayHintChecked;
        private string lastTrayText;
        // Why there is no backup configuration to work with, as one sentence a disabled control can give. Empty while one is in use,
        // and before the first read has finished (nothing is wrong yet). `sourceInstallationMissing` is set only once the
        // installation is really missing: one that was there a moment ago is given a few refreshes before the page says nothing is
        // installed (a manager that replaces the file can leave it absent for an instant), while the very first read that finds
        // nothing is believed at once.
        private const int MissingInstallationRefreshes = 3;
        private string sourceConfigurationNote = string.Empty;
        private bool sourceInstallationMissing;
        private bool sourceConfigurationEverLoaded;
        private int sourceInstallationMissCount;
        // A start with --minimized (the logon task) has to create and show the window once, so the page can load, but it never
        // wants it seen: the window opens outside the visible desktop and without taking focus, is hidden as soon as it has
        // loaded (OnLoaded), and is put in the middle of the work area the first time someone asks for it (ShowDashboard).
        private bool hideAtLoad;
        private bool startupPlacementPending;
        // Set while the schedule's run times were just changed by someone, to the moment backups were last known to be current:
        // a slot the new schedule has before then never existed (see NoteScheduleReplaced). Null otherwise.
        private DateTime? scheduleCoveredThroughUtc;
        private double currentProgress;
        private TelemetrySnapshot lastSnapshot;
        private DateTime lastHeartbeatUtc = DateTime.MinValue;

        public DashboardWindow(AppOptions options, EventWaitHandle showEvent)
        {
            this.options = options;
            this.showEvent = showEvent;
            this.previewEnabled = options.Preview;
            this.previewStarted = DateTime.Now;
            this.reader = new TelemetryReader(
                options.StateDirectory,
                !options.UseIsolatedPresentationStore);
            this.themeResolution = DashboardThemeManager.LoadAndResolve();
            this.themePreference = this.themeResolution.Preference;
            this.motionResolution = DashboardMotion.LoadAndResolve();
            this.motionPreference = this.motionResolution.Preference;

            Title = "Rewindle";
            // The width is fitted to the work area as the height is: 1280 DIPs is wider than a 1080p screen at 175%.
            Width = Math.Min(1280, SystemParameters.WorkArea.Width - 40);
            Height = options.UseNativePresentation ? 720 : Math.Min(840, SystemParameters.WorkArea.Height - 40);
            // MinWidth holds the layout together on the smallest screens, but it follows the work area down as well, as the minimum
            // height does below. Held at 900 DIPs it is wider than a 1366x768 laptop at 175% (about 780), WPF raises Width to it, and the
            // window would open past the edge of the screen. The web page reflows to the narrower window and folds its sidebar (its
            // layouts go down to about 600 DIPs, hence the floor); the --native window keeps its own minimum, which its layout was made for.
            MinWidth = options.UseNativePresentation
                ? 900
                : Math.Min(900, Math.Max(640, SystemParameters.WorkArea.Width - 40));
            // The minimum height follows the work area as well. Held at 620 DIPs it is taller than a 1080p screen at 200% (about
            // 516 DIPs once the taskbar is counted), and the window would open with its bottom edge under the taskbar.
            MinHeight = Math.Min(620, Math.Max(420, SystemParameters.WorkArea.Height - 40));
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            if (options.StartMinimized)
            {
                // Application.Run shows the window, whatever its state, so it is shown where nobody can see it, without taking
                // focus and without a taskbar button. A minimized window with no taskbar button would still draw a title-bar
                // stub on the desktop. OnLoaded hides it; ShowDashboard puts it in its place the first time it is wanted.
                hideAtLoad = true;
                startupPlacementPending = true;
                ShowActivated = false;
                ShowInTaskbar = false;
                WindowStartupLocation = WindowStartupLocation.Manual;
                Left = SystemParameters.VirtualScreenLeft - Width - 200;
                Top = SystemParameters.VirtualScreenTop;
            }
            ApplyWindowPalette();

            Content = BuildInterface();
            Closing += OnClosing;
            Closed += OnClosed;
            Loaded += OnLoaded;
            SizeChanged += OnWindowSizeChanged;
            IsVisibleChanged += OnWindowVisibilityChanged;
            StateChanged += OnWindowStateChanged;
            PreviewKeyDown += OnDashboardPreviewKeyDown;
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
            SystemParameters.StaticPropertyChanged += OnSystemParametersChanged;
            Application.Current.SessionEnding += delegate { allowClose = true; };

            trayIcon = BuildTrayIcon();
            refreshTimer = new DispatcherTimer(DispatcherPriority.Background);
            refreshTimer.Interval = TimeSpan.FromSeconds(1);
            refreshTimer.Tick += OnRefreshTick;
            refreshTimer.Start();
        }

        private UIElement BuildInterface()
        {
            StopSourceOperationAnimation();
            phaseMarkers.Clear();
            phaseLabels.Clear();
            removeSourceButtons.Clear();
            sourceRows.Clear();
            themeButtons.Clear();
            motionButtons.Clear();
            compactLayout = null;
            lastVisiblePage = null;
            navigationIndicatorInitialized = false;
            sourceOperationItem = null;
            sourceOperationTag = null;
            sourceOperationTagText = null;
            sourceOperationGlyphFrame = null;
            sourceOperationGlyph = null;
            sourceOperationStatusText = null;
            sourceOperationDetailText = null;
            sourceOperationRail = null;
            sourceOperationRailSegment = null;
            sourceOperationRailTransform = null;
            sourceOperationRetryButton = null;
            sourceOperationDismissButton = null;

            // The history list and chart are created again below, so they have been given nothing yet.
            historyBindSignature = null;
            shellLayout = new Grid();
            shellLayout.Background = BackgroundTop;
            shellLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(216) });
            shellLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            navigationRail = BuildNavigationRail();
            shellLayout.Children.Add(navigationRail);

            Grid root = new Grid();
            root.Margin = new Thickness(24, 18, 24, 12);
            root.HorizontalAlignment = HorizontalAlignment.Stretch;
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(44) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(14) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(8) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            UIElement header = BuildHeader();
            Grid.SetRow(header, 0);
            root.Children.Add(header);

            pageHost = new Grid();
            protectionOverview = BuildProtectionPage();
            pageHost.Children.Add(protectionOverview);
            historyLayout = BuildActivityPage();
            pageHost.Children.Add(historyLayout);
            restorePage = (FrameworkElement)BuildRestorePage();
            pageHost.Children.Add(restorePage);
            settingsPage = (FrameworkElement)BuildSettingsPage();
            pageHost.Children.Add(settingsPage);
            Grid.SetRow(pageHost, 2);
            root.Children.Add(pageHost);

            footerDetails = new TextBlock();
            footerDetails.Text = "Encrypted locally  •  Protected changes require Windows approval";
            footerDetails.Foreground = themeResolution.Palette.FooterText;
            footerDetails.FontSize = 12;
            footerDetails.FontWeight = FontWeights.SemiBold;
            footerDetails.VerticalAlignment = VerticalAlignment.Bottom;
            footerDetails.HorizontalAlignment = HorizontalAlignment.Left;
            footerDetails.TextWrapping = TextWrapping.Wrap;
            lastUpdated = new TextBlock();
            lastUpdated.Foreground = themeResolution.Palette.FooterText;
            lastUpdated.FontSize = 12;
            lastUpdated.HorizontalAlignment = HorizontalAlignment.Right;
            lastUpdated.VerticalAlignment = VerticalAlignment.Bottom;

            footerLayout = new Grid();
            footerLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            footerLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            footerLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            footerLayout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(0) });
            footerLayout.Children.Add(footerDetails);
            Grid.SetColumn(lastUpdated, 1);
            footerLayout.Children.Add(lastUpdated);
            Grid.SetRow(footerLayout, 4);
            root.Children.Add(footerLayout);

            Grid.SetColumn(root, 1);
            shellLayout.Children.Add(root);
            MountWebPresentation(shellLayout, root);
            AutomationProperties.SetName(shellLayout, "Rewindle backup dashboard");
            ShowDashboardPage(selectedDashboardPage);
            ApplyResponsiveLayout();
            return shellLayout;
        }

        private Border BuildNavigationRail()
        {
            Border rail = new Border();
            rail.Background = BackgroundTop;
            rail.BorderBrush = CardBorderBrush;
            rail.BorderThickness = new Thickness(0, 0, 1, 0);
            rail.Padding = new Thickness(18, 22, 18, 16);

            navigationLayout = new Grid();
            Grid layout = navigationLayout;
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(22) });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            navigationIndicatorTransform = new TranslateTransform();
            navigationIndicator = new Border();
            navigationIndicator.Height = 40;
            navigationIndicator.VerticalAlignment = VerticalAlignment.Top;
            navigationIndicator.HorizontalAlignment = HorizontalAlignment.Stretch;
            navigationIndicator.Background = themeResolution.Palette.ButtonBackground;
            navigationIndicator.CornerRadius = new CornerRadius(7);
            navigationIndicator.Opacity = 0;
            navigationIndicator.IsHitTestVisible = false;
            navigationIndicator.RenderTransform = navigationIndicatorTransform;
            Grid.SetRowSpan(navigationIndicator, 4);
            Panel.SetZIndex(navigationIndicator, 0);
            layout.Children.Add(navigationIndicator);

            navigationBrand = new TextBlock();
            navigationBrand.Text = "REWINDLE";
            navigationBrand.FontSize = 13;
            navigationBrand.FontWeight = FontWeights.Bold;
            navigationBrand.Foreground = BlueText;
            navigationBrand.Margin = new Thickness(8, 2, 0, 0);
            Panel.SetZIndex(navigationBrand, 2);
            AutomationProperties.SetName(navigationBrand, "Rewindle navigation");
            layout.Children.Add(navigationBrand);

            StackPanel primary = new StackPanel();
            protectionNavButton = BuildNavigationButton("\uE83D", "Protection", "Protection");
            activityNavButton = BuildNavigationButton("\uE81C", "Activity", "Activity");
            restoreNavButton = BuildNavigationButton("\uE8F3", "Restore", "Restore");
            primary.Children.Add(protectionNavButton);
            primary.Children.Add(activityNavButton);
            primary.Children.Add(restoreNavButton);
            Grid.SetRow(primary, 2);
            Panel.SetZIndex(primary, 2);
            layout.Children.Add(primary);

            settingsNavButton = BuildNavigationButton("\uE713", "Settings", "Settings");
            Grid.SetRow(settingsNavButton, 3);
            Panel.SetZIndex(settingsNavButton, 2);
            layout.Children.Add(settingsNavButton);

            rail.Child = layout;
            AutomationProperties.SetName(rail, "Dashboard navigation");
            return rail;
        }

        private Button BuildNavigationButton(string glyph, string label, string page)
        {
            Button button = CreateButton(label);
            button.Tag = new string[] { page, glyph, label };
            button.Content = BuildIconLabel(glyph, label);
            button.HorizontalContentAlignment = HorizontalAlignment.Left;
            button.Margin = new Thickness(0, 0, 0, 6);
            button.Padding = new Thickness(10, 8, 10, 8);
            button.MinHeight = 40;
            button.Background = Brushes.Transparent;
            button.BorderBrush = Brushes.Transparent;
            button.Click += OnNavigationClick;
            AutomationProperties.SetName(button, "Open " + label);
            return button;
        }

        private void OnNavigationClick(object sender, RoutedEventArgs args)
        {
            Button button = sender as Button;
            string[] metadata = button == null ? null : button.Tag as string[];
            if (metadata == null || metadata.Length < 1)
            {
                return;
            }
            ShowDashboardPage(metadata[0]);
            PublishWebPresentationState();
        }

        private void ShowDashboardPage(string page)
        {
            string requestedPage = string.IsNullOrWhiteSpace(page) ? "Protection" : page;
            bool pageChanged = !string.Equals(selectedDashboardPage, requestedPage, StringComparison.Ordinal);
            selectedDashboardPage = requestedPage;
            if (protectionOverview != null)
            {
                protectionOverview.Visibility = string.Equals(selectedDashboardPage, "Protection", StringComparison.Ordinal)
                    ? Visibility.Visible
                    : Visibility.Collapsed;
            }
            if (historyLayout != null)
            {
                historyLayout.Visibility = string.Equals(selectedDashboardPage, "Activity", StringComparison.Ordinal)
                    ? Visibility.Visible
                    : Visibility.Collapsed;
            }
            if (settingsPage != null)
            {
                settingsPage.Visibility = string.Equals(selectedDashboardPage, "Settings", StringComparison.Ordinal)
                    ? Visibility.Visible
                    : Visibility.Collapsed;
            }
            if (restorePage != null)
            {
                restorePage.Visibility = string.Equals(selectedDashboardPage, "Restore", StringComparison.Ordinal)
                    ? Visibility.Visible
                    : Visibility.Collapsed;
            }
            StyleNavigationButton(protectionNavButton, "Protection");
            StyleNavigationButton(activityNavButton, "Activity");
            StyleNavigationButton(restoreNavButton, "Restore");
            StyleNavigationButton(settingsNavButton, "Settings");

            FrameworkElement visiblePage = string.Equals(selectedDashboardPage, "Activity", StringComparison.Ordinal)
                ? (FrameworkElement)historyLayout
                : string.Equals(selectedDashboardPage, "Restore", StringComparison.Ordinal)
                    ? restorePage
                    : string.Equals(selectedDashboardPage, "Settings", StringComparison.Ordinal)
                        ? settingsPage
                        : protectionOverview;
            if (visiblePage != null && (pageChanged || !object.ReferenceEquals(lastVisiblePage, visiblePage)))
            {
                DashboardVisualStyle.Reveal(
                    visiblePage,
                    lastVisiblePage == null ? DashboardVisualStyle.SectionDuration : DashboardVisualStyle.ExpandDuration,
                    TimeSpan.Zero,
                    8.0);
            }
            lastVisiblePage = visiblePage;
            AnimateNavigationIndicator();
        }

        private void StyleNavigationButton(Button button, string page)
        {
            if (button == null)
            {
                return;
            }
            bool selected = string.Equals(selectedDashboardPage, page, StringComparison.Ordinal);
            button.Background = Brushes.Transparent;
            button.BorderBrush = Brushes.Transparent;
            button.Foreground = selected ? PrimaryText : MutedText;
            AutomationProperties.SetItemStatus(button, selected ? "Selected" : "Not selected");
        }

        private void AnimateNavigationIndicator()
        {
            if (navigationLayout == null || navigationIndicator == null || navigationIndicatorTransform == null)
            {
                return;
            }
            Button selected = string.Equals(selectedDashboardPage, "Activity", StringComparison.Ordinal)
                ? activityNavButton
                : string.Equals(selectedDashboardPage, "Restore", StringComparison.Ordinal)
                    ? restoreNavButton
                    : string.Equals(selectedDashboardPage, "Settings", StringComparison.Ordinal)
                        ? settingsNavButton
                        : protectionNavButton;
            if (selected == null)
            {
                return;
            }

            Dispatcher.BeginInvoke(
                new Action(delegate
                {
                    if (selected.ActualHeight <= 0 || navigationLayout.ActualHeight <= 0)
                    {
                        return;
                    }
                    Point position = selected.TranslatePoint(new Point(0, 0), navigationLayout);
                    double height = Math.Max(36.0, selected.ActualHeight);
                    if (!navigationIndicatorInitialized || !DashboardVisualStyle.MotionAllowed())
                    {
                        navigationIndicatorTransform.BeginAnimation(TranslateTransform.YProperty, null);
                        navigationIndicator.BeginAnimation(FrameworkElement.HeightProperty, null);
                        navigationIndicatorTransform.Y = position.Y;
                        navigationIndicator.Height = height;
                        DashboardVisualStyle.AnimateDouble(
                            navigationIndicator,
                            UIElement.OpacityProperty,
                            1.0,
                            DashboardVisualStyle.DefaultDuration,
                            false);
                    }
                    else
                    {
                        DashboardVisualStyle.AnimateDouble(
                            navigationIndicatorTransform,
                            TranslateTransform.YProperty,
                            position.Y,
                            DashboardVisualStyle.StrongDuration,
                            true);
                        DashboardVisualStyle.AnimateDouble(
                            navigationIndicator,
                            FrameworkElement.HeightProperty,
                            height,
                            DashboardVisualStyle.StrongDuration,
                            true);
                        DashboardVisualStyle.AnimateDouble(
                            navigationIndicator,
                            UIElement.OpacityProperty,
                            1.0,
                            DashboardVisualStyle.DefaultDuration,
                            false);
                    }
                    navigationIndicatorInitialized = true;
                }),
                DispatcherPriority.Loaded);
        }

        private FrameworkElement BuildProtectionPage()
        {
            Grid page = new Grid();
            page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(10) });
            page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(12) });
            page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 220 });

            Grid pageHeader = new Grid();
            pageHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            pageHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel heading = new StackPanel();
            TextBlock title = new TextBlock();
            title.Text = "Protection";
            title.FontSize = 21;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            heading.Children.Add(title);
            TextBlock description = new TextBlock();
            description.Text = "Your current backup state, schedule, and protected folders";
            description.FontSize = 11.5;
            description.Foreground = MutedText;
            description.Margin = new Thickness(0, 2, 0, 0);
            heading.Children.Add(description);
            pageHeader.Children.Add(heading);

            StackPanel actions = new StackPanel();
            actions.Orientation = Orientation.Horizontal;
            actions.VerticalAlignment = VerticalAlignment.Center;

            reviewChangesButton = CreateButton("Review changes");
            reviewChangesButton.MinWidth = 126;
            reviewChangesButton.MinHeight = 38;
            reviewChangesButton.Margin = new Thickness(0, 0, 8, 0);
            reviewChangesButton.Background = BrushFrom("#3A2F18");
            reviewChangesButton.BorderBrush = Amber;
            reviewChangesButton.Foreground = Amber;
            reviewChangesButton.Visibility = Visibility.Collapsed;
            reviewChangesButton.Click += OnReviewChangesClick;
            AutomationProperties.SetAutomationId(
                reviewChangesButton,
                "ReviewBackupChangesButton");
            AutomationProperties.SetName(
                reviewChangesButton,
                "Review suspicious backup changes");
            AutomationProperties.SetHelpText(
                reviewChangesButton,
                EngineProfile.Current.AnomalyReview.ButtonHelp);
            actions.Children.Add(reviewChangesButton);

            backupNowButton = CreateButton("Back up now");
            backupNowButton.MinWidth = 116;
            backupNowButton.MinHeight = 38;
            backupNowButton.Background = Blue;
            backupNowButton.BorderBrush = Blue;
            backupNowButton.Foreground = themeResolution.Palette.TextOnAccent;
            backupNowButton.Click += OnBackupNowClick;
            AutomationProperties.SetAutomationId(backupNowButton, "BackupNowButton");
            AutomationProperties.SetName(backupNowButton, "Back up now");
            AutomationProperties.SetHelpText(
                backupNowButton,
                "Start the installed Restic backup now. Windows approval is required.");
            actions.Children.Add(backupNowButton);

            cancelBackupButton = CreateButton("Cancel backup");
            cancelBackupButton.Margin = new Thickness(8, 0, 0, 0);
            cancelBackupButton.MinWidth = 112;
            cancelBackupButton.MinHeight = 38;
            cancelBackupButton.Background = Brushes.Transparent;
            cancelBackupButton.BorderBrush = CardBorderBrush;
            cancelBackupButton.Foreground = MutedText;
            cancelBackupButton.Visibility = Visibility.Visible;
            cancelBackupButton.Click += OnCancelBackupClick;
            AutomationProperties.SetAutomationId(cancelBackupButton, "CancelBackupButton");
            AutomationProperties.SetName(cancelBackupButton, "Cancel running backup");
            AutomationProperties.SetHelpText(
                cancelBackupButton,
                "Available while an exact protected backup run is active.");
            actions.Children.Add(cancelBackupButton);
            Grid.SetColumn(actions, 1);
            pageHeader.Children.Add(actions);
            page.Children.Add(pageHeader);

            UIElement recoveryCard = BuildRepositoryRecoveryCard(true);
            Grid.SetRow(recoveryCard, 2);
            page.Children.Add(recoveryCard);

            protectionHero = (FrameworkElement)BuildHero();
            protectionHero.MinHeight = 168;
            Grid.SetRow(protectionHero, 3);
            page.Children.Add(protectionHero);

            protectionSources = (FrameworkElement)BuildSources();
            Grid.SetRow(protectionSources, 5);
            page.Children.Add(protectionSources);
            AutomationProperties.SetName(page, "Protection page");
            ScrollViewer scroller = new ScrollViewer();
            scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            scroller.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
            scroller.Content = page;
            AutomationProperties.SetName(scroller, "Scrollable Protection page");
            return scroller;
        }

        private Grid BuildActivityPage()
        {
            Grid page = new Grid();
            page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(12) });
            page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            StackPanel heading = new StackPanel();
            TextBlock title = new TextBlock();
            title.Text = "Activity";
            title.FontSize = 21;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            heading.Children.Add(title);
            TextBlock description = new TextBlock();
            description.Text = "Verified local run history and recent trend";
            description.FontSize = 12;
            description.Foreground = MutedText;
            description.Margin = new Thickness(0, 2, 0, 0);
            heading.Children.Add(description);
            page.Children.Add(heading);
            UIElement history = BuildHistory();
            Grid.SetRow(history, 2);
            page.Children.Add(history);
            AutomationProperties.SetName(page, "Backup activity page");
            return page;
        }

        private UIElement BuildRestorePage()
        {
            Grid page = new Grid();
            page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(12) });
            page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(12) });
            page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

            StackPanel heading = new StackPanel();
            TextBlock title = new TextBlock();
            title.Text = "Restore";
            title.FontSize = 21;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            heading.Children.Add(title);
            TextBlock description = new TextBlock();
            description.Text = "Browse immutable snapshots and recover files without touching live folders";
            description.FontSize = 11.5;
            description.Foreground = MutedText;
            description.Margin = new Thickness(0, 2, 0, 0);
            heading.Children.Add(description);
            page.Children.Add(heading);

            Border readinessCard = CreateCard();
            readinessCard.Padding = new Thickness(20, 18, 20, 18);
            Grid readiness = new Grid();
            readiness.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            readiness.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel readinessCopy = new StackPanel();
            TextBlock readinessEyebrow = new TextBlock();
            readinessEyebrow.Text = "RECOVERY READINESS";
            readinessEyebrow.FontSize = 10;
            readinessEyebrow.FontWeight = FontWeights.Bold;
            readinessEyebrow.Foreground = BlueText;
            readinessCopy.Children.Add(readinessEyebrow);
            restoreReadinessTitle = new TextBlock();
            restoreReadinessTitle.Text = "Checking protected restore components";
            restoreReadinessTitle.FontSize = 18;
            restoreReadinessTitle.FontWeight = FontWeights.SemiBold;
            restoreReadinessTitle.Foreground = PrimaryText;
            restoreReadinessTitle.Margin = new Thickness(0, 5, 0, 0);
            readinessCopy.Children.Add(restoreReadinessTitle);
            restoreReadinessDetail = new TextBlock();
            restoreReadinessDetail.Text = "Rewindle is validating the stable backup plan and restore manager.";
            restoreReadinessDetail.FontSize = 12;
            restoreReadinessDetail.Foreground = MutedText;
            restoreReadinessDetail.TextWrapping = TextWrapping.Wrap;
            restoreReadinessDetail.Margin = new Thickness(0, 4, 16, 0);
            readinessCopy.Children.Add(restoreReadinessDetail);
            readiness.Children.Add(readinessCopy);
            StackPanel recoveryActions = new StackPanel();
            recoveryActions.VerticalAlignment = VerticalAlignment.Center;
            checkRecoveryReadinessButton = CreateButton("Check recovery readiness");
            checkRecoveryReadinessButton.MinWidth = 164;
            checkRecoveryReadinessButton.MinHeight = 38;
            checkRecoveryReadinessButton.Margin = new Thickness(0, 0, 0, 8);
            checkRecoveryReadinessButton.Click += OnCheckRecoveryReadinessClick;
            AutomationProperties.SetName(checkRecoveryReadinessButton, "Check recovery readiness");
            AutomationProperties.SetHelpText(
                checkRecoveryReadinessButton,
                "Read-only checks validate the repository, both credentials, recovery bundle, capacity, locks, and restore drill.");
            recoveryActions.Children.Add(checkRecoveryReadinessButton);
            openRestoreCenterButton = CreateButton("Open Restore Center");
            openRestoreCenterButton.MinWidth = 164;
            openRestoreCenterButton.MinHeight = 42;
            openRestoreCenterButton.Background = Blue;
            openRestoreCenterButton.BorderBrush = Blue;
            openRestoreCenterButton.Foreground = themeResolution.Palette.TextOnAccent;
            openRestoreCenterButton.VerticalAlignment = VerticalAlignment.Center;
            openRestoreCenterButton.Click += OnOpenRestoreCenterClick;
            AutomationProperties.SetName(openRestoreCenterButton, "Open protected Restore Center");
            AutomationProperties.SetHelpText(
                openRestoreCenterButton,
                "Browse plan-bound snapshots and restore to a new or empty destination. Windows approval is required.");
            recoveryActions.Children.Add(openRestoreCenterButton);
            Grid.SetColumn(recoveryActions, 1);
            readiness.Children.Add(recoveryActions);
            readinessCard.Child = readiness;
            Grid.SetRow(readinessCard, 2);
            page.Children.Add(readinessCard);

            Border safetyCard = CreateCard();
            safetyCard.Padding = new Thickness(20, 18, 20, 18);
            StackPanel safety = new StackPanel();
            TextBlock safetyTitle = new TextBlock();
            safetyTitle.Text = "Restore safety contract";
            safetyTitle.FontSize = 16;
            safetyTitle.FontWeight = FontWeights.SemiBold;
            safetyTitle.Foreground = PrimaryText;
            safety.Children.Add(safetyTitle);
            string[] guarantees =
            {
                "Exact immutable snapshot ID — never a moving 'latest' selector",
                "Separate destination only — original folders and repository stay untouched",
                "Destination must be absent or empty, and Restic is told never to overwrite",
                "Every successful restore is verified; partial results are retained and clearly labelled"
            };
            foreach (string guarantee in guarantees)
            {
                Border row = new Border();
                row.Background = CardSoftBrush;
                row.BorderBrush = CardBorderBrush;
                row.BorderThickness = new Thickness(1);
                row.CornerRadius = new CornerRadius(10);
                row.Padding = new Thickness(12, 10, 12, 10);
                row.Margin = new Thickness(0, 10, 0, 0);
                TextBlock text = new TextBlock();
                text.Text = "✓  " + guarantee;
                text.FontSize = 12;
                text.Foreground = PrimaryText;
                text.TextWrapping = TextWrapping.Wrap;
                row.Child = text;
                safety.Children.Add(row);
            }
            safetyCard.Child = safety;
            Grid.SetRow(safetyCard, 4);
            page.Children.Add(safetyCard);
            AutomationProperties.SetName(page, "Restore page");
            return page;
        }

        private UIElement BuildSettingsPage()
        {
            ScrollViewer scroller = new ScrollViewer();
            scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            scroller.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
            StackPanel page = new StackPanel();
            page.MaxWidth = 720;
            page.HorizontalAlignment = HorizontalAlignment.Left;

            TextBlock title = new TextBlock();
            title.Text = "Settings";
            title.FontSize = 21;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            page.Children.Add(title);
            TextBlock description = new TextBlock();
            description.Text = "Backup storage, off-site verification, appearance, and Rewindle motion";
            description.FontSize = 11.5;
            description.Foreground = MutedText;
            description.Margin = new Thickness(0, 2, 0, 14);
            page.Children.Add(description);

            UIElement recoveryCard = BuildRepositoryRecoveryCard(false);
            page.Children.Add(recoveryCard);
            page.Children.Add(BuildStorageCard());
            page.Children.Add(BuildFreshnessCard());
            page.Children.Add(BuildOffsiteCard());

            Border appearanceCard = CreateCard();
            appearanceCard.Padding = new Thickness(18, 16, 18, 16);
            appearanceCard.Margin = new Thickness(0, 12, 0, 0);
            StackPanel appearance = new StackPanel();
            TextBlock appearanceTitle = new TextBlock();
            appearanceTitle.Text = "Appearance";
            appearanceTitle.FontSize = 16;
            appearanceTitle.FontWeight = FontWeights.SemiBold;
            appearanceTitle.Foreground = PrimaryText;
            appearance.Children.Add(appearanceTitle);
            TextBlock appearanceHint = new TextBlock();
            appearanceHint.Text = "Follow your system or keep a fixed light or dark workspace.";
            appearanceHint.FontSize = 12;
            appearanceHint.Foreground = MutedText;
            appearanceHint.Margin = new Thickness(0, 3, 0, 10);
            appearance.Children.Add(appearanceHint);
            appearance.Children.Add(BuildThemeSelector());
            appearanceCard.Child = appearance;
            page.Children.Add(appearanceCard);

            Border motionCard = CreateCard();
            motionCard.Padding = new Thickness(18, 16, 18, 16);
            motionCard.Margin = new Thickness(0, 12, 0, 0);
            Grid motion = new Grid();
            motion.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            motion.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel motionCopy = new StackPanel();
            TextBlock motionTitle = new TextBlock();
            motionTitle.Text = "Progress animation";
            motionTitle.FontSize = 16;
            motionTitle.FontWeight = FontWeights.SemiBold;
            motionTitle.Foreground = PrimaryText;
            motionCopy.Children.Add(motionTitle);
            TextBlock motionHint = new TextBlock();
            motionHint.Text =
                "System follows Windows animation settings. Full enables dashboard motion; " +
                "Reduced keeps progress and layout changes still. High contrast always stays still.";
            motionHint.FontSize = 12;
            motionHint.Foreground = MutedText;
            motionHint.Margin = new Thickness(0, 3, 18, 0);
            motionHint.TextWrapping = TextWrapping.Wrap;
            motionCopy.Children.Add(motionHint);
            motionCopy.Children.Add(BuildMotionSelector());
            motion.Children.Add(motionCopy);
            previewButton = CreateButton(previewEnabled ? "Stop preview" : "Preview animation");
            previewButton.MinHeight = 38;
            previewButton.Click += delegate
            {
                previewEnabled = !previewEnabled;
                previewStarted = DateTime.Now;
                previewButton.Content = previewEnabled ? "Stop preview" : "Preview animation";
                AutomationProperties.SetName(
                    previewButton,
                    previewEnabled ? "Stop backup flow preview" : "Preview backup flow");
                ShowDashboardPage("Protection");
                RefreshDashboard();
            };
            AutomationProperties.SetHelpText(
                previewButton,
                "Shows a clearly labeled animated example without starting a backup.");
            Grid.SetColumn(previewButton, 1);
            motion.Children.Add(previewButton);
            motionCard.Child = motion;
            page.Children.Add(motionCard);

            Border safetyCard = CreateCard();
            safetyCard.Padding = new Thickness(18, 16, 18, 16);
            safetyCard.Margin = new Thickness(0, 12, 0, 0);
            TextBlock safety = new TextBlock();
            safety.Text = "Folder, schedule, start, and cancellation requests use protected Windows flows. Closing this dashboard never terminates Restic.";
            safety.FontSize = 12;
            safety.Foreground = MutedText;
            safety.TextWrapping = TextWrapping.Wrap;
            safetyCard.Child = safety;
            page.Children.Add(safetyCard);

            scroller.Content = page;
            AutomationProperties.SetName(scroller, "Dashboard settings page");
            return scroller;
        }

        private UIElement BuildRepositoryRecoveryCard(bool protectionSurface)
        {
            Border card = CreateCard();
            card.BorderBrush = Rose;
            card.BorderThickness = new Thickness(2);
            card.Background = CardSoftBrush;
            card.Padding = new Thickness(16, 14, 16, 14);
            card.Margin = protectionSurface
                ? new Thickness(0, 0, 0, 10)
                : new Thickness(0, 0, 0, 12);
            card.Visibility = Visibility.Collapsed;

            Grid content = new Grid();
            content.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star)
            });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            StackPanel copy = new StackPanel();
            TextBlock eyebrow = new TextBlock();
            eyebrow.Text = "ACTION REQUIRED  \u2022  BACKUPS PAUSED";
            eyebrow.FontSize = 10;
            eyebrow.FontWeight = FontWeights.Bold;
            eyebrow.Foreground = Rose;
            copy.Children.Add(eyebrow);

            TextBlock title = new TextBlock();
            title.Text = "Interrupted repository move";
            title.FontSize = 16;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            title.Margin = new Thickness(0, 4, 12, 0);
            copy.Children.Add(title);

            TextBlock message = new TextBlock();
            message.Text = "Repair the protected repository state before another backup runs.";
            message.FontSize = 12;
            message.Foreground = MutedText;
            message.Margin = new Thickness(0, 3, 18, 0);
            message.TextWrapping = TextWrapping.Wrap;
            AutomationProperties.SetLiveSetting(message, AutomationLiveSetting.Assertive);
            copy.Children.Add(message);
            content.Children.Add(copy);

            Button repairButton = CreateButton("Repair interrupted move");
            repairButton.MinHeight = 38;
            repairButton.MinWidth = 178;
            repairButton.VerticalAlignment = VerticalAlignment.Center;
            repairButton.Background = Rose;
            repairButton.BorderBrush = Rose;
            repairButton.Foreground = themeResolution.Palette.TextOnAccent;
            repairButton.Click += OnRepairRepositoryClick;
            AutomationProperties.SetAutomationId(
                repairButton,
                protectionSurface
                    ? "ProtectionRepairRepositoryButton"
                    : "SettingsRepairRepositoryButton");
            AutomationProperties.SetName(repairButton, "Repair interrupted repository move");
            Grid.SetColumn(repairButton, 1);
            content.Children.Add(repairButton);

            StackPanel progressPanel = new StackPanel();
            progressPanel.Margin = new Thickness(0, 11, 0, 0);
            ProgressBar progress = new ProgressBar();
            progress.Minimum = 0;
            progress.Maximum = 100;
            progress.Height = 6;
            progress.Foreground = Blue;
            progress.Background = CardBorderBrush;
            progress.IsIndeterminate = true;
            progress.Visibility = Visibility.Collapsed;
            AutomationProperties.SetAutomationId(
                progress,
                protectionSurface
                    ? "ProtectionRepositoryRecoveryProgress"
                    : "SettingsRepositoryRecoveryProgress");
            progressPanel.Children.Add(progress);

            TextBlock state = new TextBlock();
            state.Text = "Waiting for protected recovery status.";
            state.FontSize = 11;
            state.FontWeight = FontWeights.SemiBold;
            state.Foreground = PrimaryText;
            state.Margin = new Thickness(0, 5, 0, 0);
            state.TextWrapping = TextWrapping.Wrap;
            AutomationProperties.SetLiveSetting(state, AutomationLiveSetting.Assertive);
            progressPanel.Children.Add(state);
            Grid.SetRow(progressPanel, 1);
            Grid.SetColumnSpan(progressPanel, 2);
            content.Children.Add(progressPanel);

            card.Child = content;
            AutomationProperties.SetAutomationId(
                card,
                protectionSurface
                    ? "ProtectionRepositoryRecoveryCard"
                    : "SettingsRepositoryRecoveryCard");
            AutomationProperties.SetName(
                card,
                "Interrupted repository move. Backups are paused until protected recovery succeeds.");
            AutomationProperties.SetHelpText(
                card,
                "Use the repair action. There is no dismiss or journal deletion action.");

            if (protectionSurface)
            {
                protectionRepositoryRecoveryCard = card;
                protectionRepositoryRecoveryMessage = message;
                protectionRepositoryRecoveryState = state;
                protectionRepositoryRecoveryButton = repairButton;
                protectionRepositoryRecoveryProgress = progress;
            }
            else
            {
                settingsRepositoryRecoveryCard = card;
                settingsRepositoryRecoveryMessage = message;
                settingsRepositoryRecoveryState = state;
                settingsRepositoryRecoveryButton = repairButton;
                settingsRepositoryRecoveryProgress = progress;
            }
            return card;
        }

        private UIElement BuildStorageCard()
        {
            Border card = CreateCard();
            card.Padding = new Thickness(18, 16, 18, 16);
            Grid content = new Grid();
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            StackPanel copy = new StackPanel();
            TextBlock title = new TextBlock();
            title.Text = "Backup storage";
            title.FontSize = 16;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            copy.Children.Add(title);
            TextBlock hint = new TextBlock();
            hint.Text = "Where the encrypted Restic repository is stored.";
            hint.FontSize = 12;
            hint.Foreground = MutedText;
            hint.Margin = new Thickness(0, 3, 18, 0);
            copy.Children.Add(hint);
            settingsRepositoryValue = new TextBlock();
            settingsRepositoryValue.Text = "Loading destination…";
            settingsRepositoryValue.FontSize = 13;
            settingsRepositoryValue.FontWeight = FontWeights.SemiBold;
            settingsRepositoryValue.Foreground = PrimaryText;
            settingsRepositoryValue.TextWrapping = TextWrapping.Wrap;
            settingsRepositoryValue.Margin = new Thickness(0, 12, 18, 0);
            copy.Children.Add(settingsRepositoryValue);
            settingsRepositoryVolume = new TextBlock();
            settingsRepositoryVolume.Text = "Reading storage volume…";
            settingsRepositoryVolume.FontSize = 11;
            settingsRepositoryVolume.Foreground = MutedText;
            settingsRepositoryVolume.Margin = new Thickness(0, 3, 18, 0);
            copy.Children.Add(settingsRepositoryVolume);
            content.Children.Add(copy);

            settingsChangeRepositoryButton = CreateButton("Change location");
            settingsChangeRepositoryButton.MinHeight = 38;
            settingsChangeRepositoryButton.VerticalAlignment = VerticalAlignment.Center;
            settingsChangeRepositoryButton.Click += OnChangeRepositoryClick;
            AutomationProperties.SetAutomationId(
                settingsChangeRepositoryButton,
                "SettingsChangeRepositoryButton");
            AutomationProperties.SetName(
                settingsChangeRepositoryButton,
                "Change protected backup repository location");
            Grid.SetColumn(settingsChangeRepositoryButton, 1);
            content.Children.Add(settingsChangeRepositoryButton);
            card.Child = content;
            return card;
        }

        private UIElement BuildFreshnessCard()
        {
            Border card = CreateCard();
            card.Padding = new Thickness(18, 16, 18, 16);
            card.Margin = new Thickness(0, 12, 0, 0);
            StackPanel content = new StackPanel();

            TextBlock title = new TextBlock();
            title.Text = "Backup freshness";
            title.FontSize = 16;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            content.Children.Add(title);

            TextBlock hint = new TextBlock();
            hint.Text = "Compares the last verified backup with the installed local schedule.";
            hint.FontSize = 12;
            hint.Foreground = MutedText;
            hint.Margin = new Thickness(0, 3, 0, 10);
            hint.TextWrapping = TextWrapping.Wrap;
            content.Children.Add(hint);

            settingsFreshnessStatus = new TextBlock();
            settingsFreshnessStatus.Text = "Checking freshness...";
            settingsFreshnessStatus.FontSize = 14;
            settingsFreshnessStatus.FontWeight = FontWeights.SemiBold;
            settingsFreshnessStatus.Foreground = BlueText;
            AutomationProperties.SetAutomationId(
                settingsFreshnessStatus,
                "SettingsBackupFreshnessStatus");
            AutomationProperties.SetName(
                settingsFreshnessStatus,
                "Backup freshness status: checking");
            AutomationProperties.SetLiveSetting(
                settingsFreshnessStatus,
                AutomationLiveSetting.Polite);
            content.Children.Add(settingsFreshnessStatus);

            settingsFreshnessDetail = new TextBlock();
            settingsFreshnessDetail.Text = "Waiting for protected backup telemetry and schedule metadata.";
            settingsFreshnessDetail.FontSize = 12;
            settingsFreshnessDetail.Foreground = MutedText;
            settingsFreshnessDetail.Margin = new Thickness(0, 3, 0, 0);
            settingsFreshnessDetail.TextWrapping = TextWrapping.Wrap;
            AutomationProperties.SetName(
                settingsFreshnessDetail,
                "Backup freshness detail");
            content.Children.Add(settingsFreshnessDetail);

            card.Child = content;
            AutomationProperties.SetName(card, "Backup freshness settings");
            AutomationProperties.SetHelpText(
                card,
                "Shows whether verified backups are keeping up with the installed daily or selected-weekday schedule.");
            return card;
        }

        private UIElement BuildOffsiteCard()
        {
            Border card = CreateCard();
            card.Padding = new Thickness(18, 16, 18, 16);
            card.Margin = new Thickness(0, 12, 0, 0);
            StackPanel content = new StackPanel();

            TextBlock title = new TextBlock();
            title.Text = "Off-site copy";
            title.FontSize = 16;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            content.Children.Add(title);

            TextBlock hint = new TextBlock();
            hint.Text =
                "Optional. When an off-site copy is set up, its evidence shows here: an exact inventory check and an independent direct-cloud restore.";
            hint.FontSize = 12;
            hint.Foreground = MutedText;
            hint.Margin = new Thickness(0, 3, 0, 10);
            hint.TextWrapping = TextWrapping.Wrap;
            content.Children.Add(hint);

            settingsOffsiteStatus = new TextBlock();
            settingsOffsiteStatus.Text = "Checking off-site status...";
            settingsOffsiteStatus.FontSize = 14;
            settingsOffsiteStatus.FontWeight = FontWeights.SemiBold;
            settingsOffsiteStatus.Foreground = BlueText;
            AutomationProperties.SetAutomationId(
                settingsOffsiteStatus,
                "SettingsOffsiteStatus");
            AutomationProperties.SetLiveSetting(
                settingsOffsiteStatus,
                AutomationLiveSetting.Polite);
            content.Children.Add(settingsOffsiteStatus);

            settingsOffsiteDetail = new TextBlock();
            settingsOffsiteDetail.Text = "Waiting for off-site verification evidence.";
            settingsOffsiteDetail.FontSize = 12;
            settingsOffsiteDetail.Foreground = MutedText;
            settingsOffsiteDetail.Margin = new Thickness(0, 3, 0, 0);
            settingsOffsiteDetail.TextWrapping = TextWrapping.Wrap;
            content.Children.Add(settingsOffsiteDetail);

            settingsOffsiteEvidence = new TextBlock();
            settingsOffsiteEvidence.Text =
                "No verified off-site inventory or restore evidence is available yet.";
            settingsOffsiteEvidence.FontSize = 11;
            settingsOffsiteEvidence.Foreground = MutedText;
            settingsOffsiteEvidence.Margin = new Thickness(0, 8, 0, 0);
            settingsOffsiteEvidence.TextWrapping = TextWrapping.Wrap;
            content.Children.Add(settingsOffsiteEvidence);

            card.Child = content;
            AutomationProperties.SetName(card, "Off-site copy status");
            AutomationProperties.SetHelpText(
                card,
                "Shows whether an off-site copy is set up, and whether its latest verification matched the backup and restored independently.");
            return card;
        }

        private UIElement BuildHeader()
        {
            headerLayout = new Grid();
            headerLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            headerLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            headerLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            headerLayout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(0) });
            headerLayout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(0) });

            StackPanel titlePanel = new StackPanel();
            headerTitlePanel = titlePanel;
            TextBlock title = new TextBlock();
            title.Text = "Rewindle";
            title.FontSize = 20;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            titlePanel.Children.Add(title);
            headerSubtitle = new TextBlock();
            headerSubtitle.Text = "Loading backup scope  •  Reading installed schedule";
            headerSubtitle.FontSize = 11;
            headerSubtitle.Foreground = MutedText;
            headerSubtitle.Margin = new Thickness(1, 1, 0, 0);
            headerSubtitle.TextTrimming = TextTrimming.CharacterEllipsis;
            titlePanel.Children.Add(headerSubtitle);
            headerLayout.Children.Add(titlePanel);

            StackPanel actions = new StackPanel();
            headerActions = actions;
            actions.Orientation = Orientation.Horizontal;
            actions.VerticalAlignment = VerticalAlignment.Center;
            Button refresh = CreateButton(string.Empty);
            refresh.Width = 40;
            refresh.MinHeight = 38;
            TextBlock refreshIcon = new TextBlock();
            refreshIcon.Text = "\uE72C";
            refreshIcon.FontFamily = new FontFamily("Segoe MDL2 Assets");
            refreshIcon.FontSize = 15;
            refresh.Content = refreshIcon;
            refresh.ToolTip = "Refresh now (F5)";
            refresh.Click += delegate { RefreshDashboard(); };
            AutomationProperties.SetName(refresh, "Refresh backup dashboard");
            AutomationProperties.SetHelpText(
                refresh,
                "Refresh backup status, protected folders, schedule, and run history. Shortcut: F5.");
            actions.Children.Add(refresh);

            Grid.SetColumn(actions, 1);
            headerLayout.Children.Add(actions);
            return headerLayout;
        }

        private UIElement BuildIconLabel(string glyph, string label)
        {
            StackPanel content = new StackPanel();
            content.Orientation = Orientation.Horizontal;
            TextBlock icon = new TextBlock();
            icon.Text = glyph;
            icon.FontFamily = new FontFamily("Segoe MDL2 Assets");
            icon.FontSize = 13;
            icon.Margin = string.IsNullOrEmpty(label)
                ? new Thickness(0)
                : new Thickness(0, 0, 7, 0);
            icon.VerticalAlignment = VerticalAlignment.Center;
            content.Children.Add(icon);
            if (!string.IsNullOrEmpty(label))
            {
                TextBlock text = new TextBlock();
                text.Text = label;
                text.VerticalAlignment = VerticalAlignment.Center;
                content.Children.Add(text);
            }
            return content;
        }

        private UIElement BuildThemeSelector()
        {
            StackPanel group = new StackPanel();
            group.VerticalAlignment = VerticalAlignment.Center;

            Border frame = new Border();
            frame.Background = CardSoftBrush;
            frame.BorderBrush = CardBorderBrush;
            frame.BorderThickness = new Thickness(1);
            frame.CornerRadius = new CornerRadius(18);
            frame.Padding = new Thickness(2);

            StackPanel segments = new StackPanel();
            segments.Orientation = Orientation.Horizontal;
            AddThemeSegment(segments, DashboardThemePreference.System, "System");
            AddThemeSegment(segments, DashboardThemePreference.Midnight, "Dark");
            AddThemeSegment(segments, DashboardThemePreference.Daylight, "Light");
            frame.Child = segments;
            group.Children.Add(frame);

            AutomationProperties.SetName(group, "Dashboard theme");
            AutomationProperties.SetHelpText(
                group,
                "Choose whether the dashboard follows Windows or uses the dark or light theme.");
            return group;
        }

        private UIElement BuildMotionSelector()
        {
            StackPanel group = new StackPanel();
            group.Margin = new Thickness(0, 12, 0, 0);
            group.VerticalAlignment = VerticalAlignment.Center;

            Border frame = new Border();
            frame.Background = CardSoftBrush;
            frame.BorderBrush = CardBorderBrush;
            frame.BorderThickness = new Thickness(1);
            frame.CornerRadius = new CornerRadius(18);
            frame.Padding = new Thickness(2);

            StackPanel segments = new StackPanel();
            segments.Orientation = Orientation.Horizontal;
            AddMotionSegment(segments, DashboardMotionPreference.System, "System");
            AddMotionSegment(segments, DashboardMotionPreference.Full, "Full");
            AddMotionSegment(segments, DashboardMotionPreference.Reduced, "Reduced");
            frame.Child = segments;
            group.Children.Add(frame);

            AutomationProperties.SetName(group, "Dashboard motion");
            AutomationProperties.SetHelpText(
                group,
                "System follows Windows animation settings. Full enables dashboard motion. " +
                "Reduced disables transform, layout, progress, and loading animations. " +
                "Windows high contrast always disables motion.");
            return group;
        }

        private void AddMotionSegment(
            Panel parent,
            DashboardMotionPreference preference,
            string label)
        {
            Button button = new Button();
            button.Content = label;
            button.Tag = preference;
            button.MinWidth = label.Length > 7 ? 72 : 58;
            button.MinHeight = 32;
            button.Padding = new Thickness(7, 3, 7, 3);
            button.Margin = new Thickness(motionButtons.Count == 0 ? 0 : 2, 0, 0, 0);
            button.BorderThickness = new Thickness(1);
            button.FontSize = 11;
            button.FontWeight = FontWeights.SemiBold;
            button.Cursor = Cursors.Hand;
            ToolTipService.SetShowOnDisabled(button, true);
            ApplyButtonChrome(button);
            button.Click += OnMotionSegmentClick;
            button.GotKeyboardFocus += delegate
            {
                button.BorderBrush = themeResolution.Palette.Focus;
                button.BorderThickness = new Thickness(2);
            };
            button.LostKeyboardFocus += delegate
            {
                StyleMotionSegment(
                    button,
                    (DashboardMotionPreference)button.Tag == motionPreference);
                button.BorderThickness = new Thickness(1);
            };
            AutomationProperties.SetName(button, "Use " + label + " motion");
            AutomationProperties.SetHelpText(
                button,
                preference == DashboardMotionPreference.System
                    ? "Follow the Windows animation setting; high contrast still disables motion."
                    : preference == DashboardMotionPreference.Full
                        ? "Always use dashboard motion unless Windows high contrast is active."
                        : "Disable transform, layout, progress, and loading animations.");
            motionButtons[preference] = button;
            StyleMotionSegment(button, preference == motionPreference);
            parent.Children.Add(button);
        }

        private void StyleMotionSegment(Button button, bool selected)
        {
            button.Background = selected ? Teal : Brushes.Transparent;
            button.Foreground = selected
                ? themeResolution.Palette.TextOnAccent
                : PrimaryText;
            button.BorderBrush = selected ? Teal : Brushes.Transparent;
            button.FontWeight = selected ? FontWeights.Bold : FontWeights.SemiBold;
            AutomationProperties.SetItemStatus(button, selected ? "Selected" : "Not selected");
        }

        private void AddThemeSegment(
            Panel parent,
            DashboardThemePreference preference,
            string label)
        {
            Button button = new Button();
            button.Content = label;
            button.Tag = preference;
            button.MinWidth = label.Length > 7 ? 62 : 52;
            button.MinHeight = 32;
            button.Padding = new Thickness(7, 3, 7, 3);
            button.Margin = new Thickness(themeButtons.Count == 0 ? 0 : 2, 0, 0, 0);
            button.BorderThickness = new Thickness(1);
            button.FontSize = 11;
            button.FontWeight = FontWeights.SemiBold;
            button.Cursor = Cursors.Hand;
            ToolTipService.SetShowOnDisabled(button, true);
            ApplyButtonChrome(button);
            button.Click += OnThemeSegmentClick;
            button.GotKeyboardFocus += delegate
            {
                button.BorderBrush = themeResolution.Palette.Focus;
                button.BorderThickness = new Thickness(2);
            };
            button.LostKeyboardFocus += delegate
            {
                StyleThemeSegment(button, (DashboardThemePreference)button.Tag == themePreference);
                button.BorderThickness = new Thickness(1);
            };
            AutomationProperties.SetName(button, "Use " + label + " dashboard theme");
            AutomationProperties.SetHelpText(
                button,
                preference == DashboardThemePreference.System
                    ? "Follow the Windows light, dark, and high contrast setting."
                    : "Use the " + label + " dashboard theme.");
            themeButtons[preference] = button;
            StyleThemeSegment(button, preference == themePreference);
            parent.Children.Add(button);
        }

        private void StyleThemeSegment(Button button, bool selected)
        {
            button.Background = selected ? Teal : Brushes.Transparent;
            button.Foreground = selected
                ? themeResolution.Palette.TextOnAccent
                : PrimaryText;
            button.BorderBrush = selected ? Teal : Brushes.Transparent;
            button.FontWeight = selected ? FontWeights.Bold : FontWeights.SemiBold;
            AutomationProperties.SetItemStatus(button, selected ? "Selected" : "Not selected");
        }

        private UIElement BuildHero()
        {
            Border card = CreateCard();
            Grid grid = new Grid();
            grid.Margin = new Thickness(18, 14, 18, 12);
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            Grid summary = new Grid();

            StackPanel left = new StackPanel();
            Grid statusLine = new Grid();
            statusLine.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            statusLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock heroEyebrow = new TextBlock();
            heroEyebrow.Text = "Protection status";
            heroEyebrow.FontSize = 11;
            heroEyebrow.FontWeight = FontWeights.SemiBold;
            heroEyebrow.Foreground = BlueText;
            heroEyebrow.VerticalAlignment = VerticalAlignment.Center;
            statusLine.Children.Add(heroEyebrow);
            statusBadge = BuildStatusBadge();
            Grid.SetColumn(statusBadge, 1);
            statusLine.Children.Add(statusBadge);
            left.Children.Add(statusLine);
            heroTitle = new TextBlock();
            heroTitle.Text = "Reading protected backup state…";
            heroTitle.FontSize = 20;
            heroTitle.FontWeight = FontWeights.SemiBold;
            heroTitle.Foreground = PrimaryText;
            heroTitle.Margin = new Thickness(0, 5, 0, 0);
            AutomationProperties.SetLiveSetting(heroTitle, AutomationLiveSetting.Polite);
            left.Children.Add(heroTitle);

            heroDetail = new TextBlock();
            heroDetail.Text = "Live progress will appear automatically when Restic starts.";
            heroDetail.FontSize = 12;
            heroDetail.Foreground = MutedText;
            heroDetail.Margin = new Thickness(0, 4, 16, 0);
            heroDetail.TextWrapping = TextWrapping.Wrap;
            left.Children.Add(heroDetail);

            cancelActionStatus = new TextBlock();
            cancelActionStatus.FontSize = 11;
            cancelActionStatus.Foreground = MutedText;
            cancelActionStatus.Margin = new Thickness(0, 6, 16, 0);
            cancelActionStatus.TextWrapping = TextWrapping.Wrap;
            cancelActionStatus.Visibility = Visibility.Collapsed;
            AutomationProperties.SetLiveSetting(cancelActionStatus, AutomationLiveSetting.Polite);
            left.Children.Add(cancelActionStatus);
            summary.Children.Add(left);

            StackPanel etaPanel = new StackPanel();
            etaPanel.HorizontalAlignment = HorizontalAlignment.Stretch;
            etaTitle = new TextBlock();
            etaTitle.Text = "Next automatic run";
            etaTitle.FontSize = 11;
            etaTitle.FontWeight = FontWeights.SemiBold;
            etaTitle.Foreground = MutedText;
            etaPanel.Children.Add(etaTitle);
            etaValue = new TextBlock();
            etaValue.Text = "—";
            etaValue.FontSize = 20;
            etaValue.FontWeight = FontWeights.SemiBold;
            etaValue.Foreground = PrimaryText;
            etaValue.Margin = new Thickness(0, 3, 0, 0);
            etaPanel.Children.Add(etaValue);
            etaHint = new TextBlock();
            etaHint.Text = "Waiting for backup state";
            etaHint.FontSize = 11;
            etaHint.Foreground = MutedText;
            etaHint.Margin = new Thickness(0, 2, 0, 0);
            etaHint.TextWrapping = TextWrapping.Wrap;
            etaPanel.Children.Add(etaHint);
            grid.Children.Add(summary);

            Border planFacts = new Border();
            planFacts.Background = CardSoftBrush;
            planFacts.BorderBrush = CardBorderBrush;
            planFacts.BorderThickness = new Thickness(0, 1, 0, 1);
            planFacts.Margin = new Thickness(0, 10, 0, 0);
            planFacts.Padding = new Thickness(10, 8, 10, 8);
            Grid scheduleMeta = new Grid();
            scheduleMeta.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.2, GridUnitType.Star) });
            scheduleMeta.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
            scheduleMeta.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            scheduleMeta.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel schedule = new StackPanel();
            schedule.Children.Add(etaPanel);
            scheduleActionStatus = new TextBlock();
            scheduleActionStatus.Text = "Reading installed schedule\u2026";
            scheduleActionStatus.FontSize = 10;
            scheduleActionStatus.Foreground = MutedText;
            scheduleActionStatus.Margin = new Thickness(0, 2, 0, 0);
            scheduleActionStatus.TextTrimming = TextTrimming.CharacterEllipsis;
            AutomationProperties.SetLiveSetting(
                scheduleActionStatus,
                AutomationLiveSetting.Polite);
            schedule.Children.Add(scheduleActionStatus);
            protectionFreshnessStatus = new TextBlock();
            protectionFreshnessStatus.Text = "Backup freshness: checking...";
            protectionFreshnessStatus.FontSize = 10;
            protectionFreshnessStatus.FontWeight = FontWeights.SemiBold;
            protectionFreshnessStatus.Foreground = BlueText;
            protectionFreshnessStatus.Margin = new Thickness(0, 3, 0, 0);
            protectionFreshnessStatus.TextTrimming = TextTrimming.CharacterEllipsis;
            AutomationProperties.SetAutomationId(
                protectionFreshnessStatus,
                "ProtectionBackupFreshnessStatus");
            AutomationProperties.SetName(
                protectionFreshnessStatus,
                "Backup freshness status: checking");
            AutomationProperties.SetHelpText(
                protectionFreshnessStatus,
                "Compares the last verified backup with the installed schedule.");
            AutomationProperties.SetLiveSetting(
                protectionFreshnessStatus,
                AutomationLiveSetting.Polite);
            schedule.Children.Add(protectionFreshnessStatus);
            scheduleMeta.Children.Add(schedule);
            StackPanel destination = new StackPanel();
            TextBlock repositoryLabel = new TextBlock();
            repositoryLabel.Text = "Destination";
            repositoryLabel.FontSize = 10;
            repositoryLabel.Foreground = MutedText;
            destination.Children.Add(repositoryLabel);
            repositoryValue = new TextBlock();
            repositoryValue.Text = "Loading repository…";
            repositoryValue.FontSize = 11;
            repositoryValue.Foreground = PrimaryText;
            repositoryValue.TextTrimming = TextTrimming.CharacterEllipsis;
            destination.Children.Add(repositoryValue);
            Grid.SetColumn(destination, 2);
            scheduleMeta.Children.Add(destination);
            StackPanel planActions = new StackPanel();
            planActions.Orientation = Orientation.Horizontal;
            planActions.Margin = new Thickness(12, 0, 0, 0);
            planActions.VerticalAlignment = VerticalAlignment.Center;
            changeRepositoryButton = CreateButton("Change location");
            changeRepositoryButton.MinHeight = 36;
            changeRepositoryButton.Background = Blue;
            changeRepositoryButton.BorderBrush = Blue;
            changeRepositoryButton.Foreground = themeResolution.Palette.TextOnAccent;
            changeRepositoryButton.Click += OnChangeRepositoryClick;
            AutomationProperties.SetAutomationId(changeRepositoryButton, "ChangeRepositoryButton");
            AutomationProperties.SetName(
                changeRepositoryButton,
                "Change protected backup repository location");
            AutomationProperties.SetHelpText(
                changeRepositoryButton,
                "Copy and verify the Restic repository in a new location. The old repository is retained and no backup starts.");
            planActions.Children.Add(changeRepositoryButton);
            editScheduleButton = CreateButton("Edit schedule");
            editScheduleButton.Margin = new Thickness(8, 0, 0, 0);
            editScheduleButton.MinHeight = 36;
            editScheduleButton.Click += OnEditScheduleClick;
            AutomationProperties.SetAutomationId(editScheduleButton, "EditScheduleButton");
            AutomationProperties.SetName(editScheduleButton, "Edit automatic backup schedule");
            AutomationProperties.SetHelpText(
                editScheduleButton,
                "Change the protected Windows backup schedule. Saving does not start a backup.");
            planActions.Children.Add(editScheduleButton);
            Grid.SetColumn(planActions, 3);
            scheduleMeta.Children.Add(planActions);
            planFacts.Child = scheduleMeta;
            Grid.SetRow(planFacts, 1);
            grid.Children.Add(planFacts);

            StackPanel progressPanel = new StackPanel();
            activeProgressPanel = progressPanel;
            progressPanel.Margin = new Thickness(0, 12, 0, 8);

            progressTrack = new Border();
            progressTrack.Height = 8;
            progressTrack.CornerRadius = new CornerRadius(4);
            progressTrack.Background = BrushFrom("#25334A");
            progressTrack.ClipToBounds = true;
            progressTrack.SizeChanged += delegate { AnimateProgress(currentProgress, false); };

            progressFill = new Border();
            progressFill.HorizontalAlignment = HorizontalAlignment.Left;
            progressFill.Width = 0;
            progressFill.CornerRadius = new CornerRadius(4);
            progressFill.Background = Teal;
            progressFill.ClipToBounds = true;
            Rectangle shimmer = new Rectangle();
            shimmer.Width = 170;
            shimmer.HorizontalAlignment = HorizontalAlignment.Left;
            shimmer.Fill = new LinearGradientBrush(
                new GradientStopCollection
                {
                    new GradientStop(Color.FromArgb(0, 255, 255, 255), 0),
                    new GradientStop(Color.FromArgb(92, 255, 255, 255), 0.5),
                    new GradientStop(Color.FromArgb(0, 255, 255, 255), 1)
                },
                new Point(0, 0.5),
                new Point(1, 0.5));
            shimmerTransform = new TranslateTransform(-190, 0);
            shimmer.RenderTransform = shimmerTransform;
            progressFill.Child = shimmer;
            progressTrack.Child = progressFill;
            progressPanel.Children.Add(progressTrack);

            Grid progressMeta = new Grid();
            progressMeta.Margin = new Thickness(0, 5, 0, 6);
            progressMeta.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            progressMeta.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            progressPercent = new TextBlock();
            progressPercent.Text = "0%";
            progressPercent.FontSize = 12;
            progressPercent.FontWeight = FontWeights.SemiBold;
            progressPercent.Foreground = PrimaryText;
            progressMeta.Children.Add(progressPercent);
            estimateBadge = new TextBlock();
            estimateBadge.Text = "ESTIMATE FROM VALIDATION BASELINE";
            estimateBadge.FontSize = 10;
            estimateBadge.FontWeight = FontWeights.SemiBold;
            estimateBadge.Foreground = Teal;
            estimateBadge.HorizontalAlignment = HorizontalAlignment.Right;
            estimateBadge.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(estimateBadge, 1);
            progressMeta.Children.Add(estimateBadge);
            progressPanel.Children.Add(progressMeta);

            activePhaseRail = (FrameworkElement)BuildPhaseRail();
            activePhaseRail.Visibility = Visibility.Collapsed;
            Grid.SetRow(progressPanel, 2);
            grid.Children.Add(progressPanel);

            metricsContext = new TextBlock();
            metricsContext.Text = "Latest recorded run";
            metricsContext.FontSize = 11;
            metricsContext.FontWeight = FontWeights.SemiBold;
            metricsContext.Foreground = MutedText;
            metricsContext.Margin = new Thickness(0, 6, 0, 2);
            Grid.SetRow(metricsContext, 3);
            grid.Children.Add(metricsContext);

            UIElement metrics = BuildMetrics();
            Grid.SetRow(metrics, 4);
            grid.Children.Add(metrics);

            card.Child = grid;
            return card;
        }

        private Border BuildStatusBadge()
        {
            statusDot = new Ellipse();
            statusDot.Width = 7;
            statusDot.Height = 7;
            statusDot.Fill = Blue;
            statusDot.Margin = new Thickness(0, 0, 7, 0);
            statusBadgeText = new TextBlock();
            statusBadgeText.Text = "LOADING";
            statusBadgeText.FontSize = 11;
            statusBadgeText.FontWeight = FontWeights.Bold;
            statusBadgeText.Foreground = PrimaryText;
            StackPanel badgeContent = new StackPanel();
            badgeContent.Orientation = Orientation.Horizontal;
            badgeContent.Children.Add(statusDot);
            badgeContent.Children.Add(statusBadgeText);
            Border badge = new Border();
            badge.Background = BrushFrom("#17243A");
            badge.BorderBrush = CardBorderBrush;
            badge.BorderThickness = new Thickness(1);
            badge.CornerRadius = new CornerRadius(12);
            badge.Padding = new Thickness(9, 4, 9, 4);
            badge.Child = badgeContent;
            AutomationProperties.SetName(badge, "Backup status");
            return badge;
        }

        private UIElement BuildPhaseRail()
        {
            Grid rail = new Grid();
            string[] labels = { "Backup", "Snapshot", "Repository", "Canary", "Complete" };
            for (int index = 0; index < labels.Length; index++)
            {
                rail.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                StackPanel step = new StackPanel();
                step.HorizontalAlignment = HorizontalAlignment.Center;
                Border marker = new Border();
                marker.Width = 18;
                marker.Height = 18;
                marker.CornerRadius = new CornerRadius(9);
                marker.Background = BrushFrom("#25334A");
                marker.BorderBrush = CardBorderBrush;
                marker.BorderThickness = new Thickness(1);
                TextBlock number = new TextBlock();
                number.Text = (index + 1).ToString(CultureInfo.InvariantCulture);
                number.FontSize = 10;
                number.FontWeight = FontWeights.Bold;
                number.Foreground = MutedText;
                number.HorizontalAlignment = HorizontalAlignment.Center;
                number.VerticalAlignment = VerticalAlignment.Center;
                marker.Child = number;
                phaseMarkers.Add(marker);
                step.Children.Add(marker);
                TextBlock label = new TextBlock();
                label.Text = labels[index];
                label.FontSize = 10;
                label.Foreground = MutedText;
                label.Margin = new Thickness(0, 2, 0, 0);
                label.HorizontalAlignment = HorizontalAlignment.Center;
                phaseLabels.Add(label);
                step.Children.Add(label);
                Grid.SetColumn(step, index);
                rail.Children.Add(step);
            }
            return rail;
        }

        private UIElement BuildMetrics()
        {
            metricsLayout = new UniformGrid();
            metricsLayout.Rows = 1;
            metricsLayout.Columns = 5;
            metricsLayout.Margin = new Thickness(0, 8, 0, 0);

            filesValue = new TextBlock();
            bytesValue = new TextBlock();
            speedValue = new TextBlock();
            elapsedValue = new TextBlock();
            errorsValue = new TextBlock();
            AddMetric(metricsLayout, "Files", filesValue, "Items visited", BlueText);
            AddMetric(metricsLayout, "Processed", bytesValue, "Logical source data", Teal);
            AddMetric(metricsLayout, "Throughput", speedValue, "Current average", BlueText);
            AddMetric(metricsLayout, "Elapsed", elapsedValue, "Current or latest run", BlueText);
            AddMetric(metricsLayout, "Errors", errorsValue, "Protected Restic output", Rose);
            return metricsLayout;
        }

        private void AddMetric(
            Panel parent,
            string title,
            TextBlock value,
            string hint,
            Brush accent)
        {
            Border item = new Border();
            item.BorderBrush = CardBorderBrush;
            item.BorderThickness = new Thickness(parent.Children.Count == 0 ? 0 : 1, 0, 0, 0);
            item.Padding = new Thickness(12, 0, 8, 0);
            StackPanel panel = new StackPanel();
            TextBlock heading = new TextBlock();
            heading.Text = title;
            heading.FontSize = 10;
            heading.FontWeight = FontWeights.SemiBold;
            heading.Foreground = MutedText;
            panel.Children.Add(heading);
            value.Text = "—";
            value.FontSize = 15;
            value.FontWeight = FontWeights.SemiBold;
            value.Foreground = PrimaryText;
            value.Margin = new Thickness(0, 2, 0, 0);
            panel.Children.Add(value);
            item.ToolTip = hint;
            item.Child = panel;
            parent.Children.Add(item);
        }

        private UIElement BuildSources()
        {
            Border card = CreateCard();
            card.Padding = new Thickness(16, 14, 16, 12);

            Grid cardGrid = new Grid();
            cardGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            cardGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            cardGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 120 });
            cardGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            Grid header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            StackPanel heading = new StackPanel();
            TextBlock title = new TextBlock();
            title.Text = "Protected folders";
            title.FontSize = 16;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            heading.Children.Add(title);

            sourceSummary = new TextBlock();
            sourceSummary.Text = "Loading protected configuration...";
            sourceSummary.FontSize = 12;
            sourceSummary.Foreground = MutedText;
            sourceSummary.Margin = new Thickness(0, 2, 0, 0);
            heading.Children.Add(sourceSummary);
            header.Children.Add(heading);

            addSourceButton = CreateButton("Add folder");
            addSourceButton.Background = Teal;
            addSourceButton.Foreground = BrushFrom("#07151D");
            addSourceButton.BorderBrush = BrushFrom("#52D6C6");
            addSourceButton.BorderThickness = new Thickness(1.5);
            addSourceButton.MinHeight = 34;
            addSourceButton.Padding = new Thickness(14, 6, 14, 6);
            addSourceButton.FontSize = 12;
            addSourceButton.Click += OnAddSourceClick;
            AutomationProperties.SetName(addSourceButton, "Add a folder to future backups");
            AutomationProperties.SetHelpText(
                addSourceButton,
                "Choose a folder and ask for Windows approval to protect it in future backups.");
            Grid.SetColumn(addSourceButton, 1);
            header.Children.Add(addSourceButton);
            cardGrid.Children.Add(header);

            sourceStatus = new TextBlock();
            sourceStatus.Text = "Windows approval is required to change protected folders.";
            sourceStatus.FontSize = 12;
            sourceStatus.Foreground = MutedText;
            sourceStatus.TextWrapping = TextWrapping.Wrap;
            sourceStatus.Margin = new Thickness(0, 7, 0, 0);
            AutomationProperties.SetLiveSetting(sourceStatus, AutomationLiveSetting.Polite);
            Grid.SetRow(sourceStatus, 1);
            cardGrid.Children.Add(sourceStatus);

            sourceList = new StackPanel();
            TextBlock loading = new TextBlock();
            loading.Text = "Loading protected folders...";
            loading.FontSize = 12;
            loading.Foreground = MutedText;
            loading.Margin = new Thickness(12, 14, 12, 14);
            sourceList.Children.Add(loading);

            Border sourceFrame = new Border();
            sourceFrame.Background = Brushes.Transparent;
            sourceFrame.BorderBrush = CardBorderBrush;
            sourceFrame.BorderThickness = new Thickness(1);
            sourceFrame.CornerRadius = new CornerRadius(10);
            sourceFrame.Padding = new Thickness(0);
            sourceFrame.Margin = new Thickness(0, 9, 0, 0);
            ScrollViewer sourceScroller = new ScrollViewer();
            sourceScroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            sourceScroller.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
            sourceScroller.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            sourceScroller.PanningMode = PanningMode.VerticalOnly;
            sourceScroller.CanContentScroll = true;
            sourceScroller.Content = sourceList;
            sourceFrame.Child = sourceScroller;
            AutomationProperties.SetName(sourceFrame, "Folders included in future backups");
            Grid.SetRow(sourceFrame, 2);
            cardGrid.Children.Add(sourceFrame);

            Border safety = new Border();
            safety.Background = Brushes.Transparent;
            safety.BorderThickness = new Thickness(0);
            safety.Padding = new Thickness(0);
            safety.Margin = new Thickness(0, 8, 0, 0);
            TextBlock safetyText = new TextBlock();
            safetyText.Text = "Removing a folder stops future backups. Existing snapshots remain intact.";
            safetyText.FontSize = 12;
            safetyText.Foreground = MutedText;
            safetyText.TextWrapping = TextWrapping.Wrap;
            safety.Child = safetyText;
            AutomationProperties.SetName(safety, safetyText.Text);
            Grid.SetRow(safety, 3);
            cardGrid.Children.Add(safety);

            card.Child = cardGrid;
            AutomationProperties.SetName(card, "Protected folders");
            return card;
        }

        private UIElement BuildSourceRow(BackupSourceView source, int index, bool managerAvailable)
        {
            Border row = new Border();
            row.Background = Brushes.Transparent;
            row.BorderBrush = CardBorderBrush;
            row.BorderThickness = new Thickness(0, 0, 0, 1);
            row.Padding = new Thickness(12, 5, 8, 5);
            row.MinHeight = 44;
            row.ToolTip = source.SourcePath;

            Grid grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            Ellipse marker = new Ellipse();
            marker.Width = 7;
            marker.Height = 7;
            marker.Fill = source.IsProtectedCanary ? Blue : Green;
            marker.Margin = new Thickness(0, 5, 10, 0);
            marker.VerticalAlignment = VerticalAlignment.Top;
            grid.Children.Add(marker);

            StackPanel details = new StackPanel();
            TextBlock name = new TextBlock();
            name.Text = source.DisplayName;
            name.FontSize = 12;
            name.FontWeight = FontWeights.SemiBold;
            name.Foreground = PrimaryText;
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            details.Children.Add(name);

            TextBlock path = new TextBlock();
            path.Text = source.ShortPath;
            path.FontSize = 11;
            path.Foreground = MutedText;
            path.TextTrimming = TextTrimming.CharacterEllipsis;
            path.ToolTip = source.SourcePath;
            path.Margin = new Thickness(0, 2, 10, 0);
            details.Children.Add(path);
            Grid.SetColumn(details, 1);
            grid.Children.Add(details);

            if (source.IsProtectedCanary)
            {
                Border required = new Border();
                required.Background = BrushFrom("#172E43");
                required.BorderBrush = BrushFrom("#3B5A70");
                required.BorderThickness = new Thickness(1);
                required.CornerRadius = new CornerRadius(12);
                required.Padding = new Thickness(7, 3, 7, 3);
                required.VerticalAlignment = VerticalAlignment.Center;
                TextBlock requiredText = new TextBlock();
                requiredText.Text = "Required";
                requiredText.FontSize = 10;
                requiredText.FontWeight = FontWeights.SemiBold;
                requiredText.Foreground = BlueText;
                required.Child = requiredText;
                AutomationProperties.SetName(required, "Required restore verification canary");
                Grid.SetColumn(required, 2);
                grid.Children.Add(required);
            }
            else
            {
                Button remove = CreateButton("×");
                remove.Tag = source;
                remove.Margin = new Thickness(10, 0, 0, 0);
                remove.Padding = new Thickness(0);
                remove.Width = 32;
                remove.Height = 32;
                remove.MinHeight = 32;
                remove.FontSize = 18;
                remove.Background = CardSoftBrush;
                remove.BorderBrush = CardBorderBrush;
                remove.Foreground = MutedText;
                remove.IsEnabled = managerAvailable && !sourceOperationInProgress;
                remove.Click += OnRemoveSourceClick;
                remove.MouseEnter += delegate
                {
                    remove.Background = BrushFrom("#2B1C2A");
                    remove.BorderBrush = Rose;
                    remove.Foreground = BrushFrom("#FFB2BC");
                };
                remove.MouseLeave += delegate
                {
                    if (!remove.IsKeyboardFocused)
                    {
                        remove.Background = CardSoftBrush;
                        remove.BorderBrush = CardBorderBrush;
                        remove.Foreground = MutedText;
                    }
                };
                remove.GotKeyboardFocus += delegate
                {
                    remove.BorderBrush = Rose;
                    remove.Foreground = Rose;
                };
                remove.LostKeyboardFocus += delegate
                {
                    remove.Background = CardSoftBrush;
                    remove.BorderBrush = CardBorderBrush;
                    remove.Foreground = MutedText;
                };
                AutomationProperties.SetName(
                    remove,
                    "Remove " + source.DisplayName + " from future backups");
                AutomationProperties.SetHelpText(
                    remove,
                    "Stops future backups of this folder. Existing snapshots remain intact.");
                removeSourceButtons.Add(remove);
                Grid.SetColumn(remove, 2);
                grid.Children.Add(remove);
            }

            row.Child = grid;
            AutomationProperties.SetName(
                row,
                source.DisplayName + ", " + source.SourcePath + ", " + source.RoleLabel);
            return row;
        }

        private bool ShouldShowPendingSourceItem(SourceConfiguration configuration)
        {
            if (!string.Equals(sourceOperationAction, "Add", StringComparison.Ordinal) ||
                string.IsNullOrWhiteSpace(sourceOperationPath) ||
                sourceOperationStage == SourceOperationStage.Idle ||
                sourceOperationStage == SourceOperationStage.Succeeded)
            {
                return false;
            }
            return configuration == null ||
                !configuration.ContainsUserSource(sourceOperationPath);
        }

        private FrameworkElement BuildSourceOperationItem()
        {
            BackupSourceView source = new BackupSourceView(sourceOperationPath, false);
            Border item = new Border();
            item.BorderThickness = new Thickness(2, 0, 0, 1);
            item.ClipToBounds = true;
            item.RenderTransform = new TranslateTransform(0, 0);

            Grid layout = new Grid();
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(2) });

            Grid folder = new Grid();
            folder.MinHeight = 44;
            folder.Margin = new Thickness(12, 5, 8, 5);
            folder.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            folder.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            folder.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            sourceOperationGlyphFrame = new Border();
            sourceOperationGlyphFrame.Width = 24;
            sourceOperationGlyphFrame.Height = 24;
            sourceOperationGlyphFrame.CornerRadius = new CornerRadius(12);
            sourceOperationGlyphFrame.Margin = new Thickness(0, 4, 10, 0);
            sourceOperationGlyphFrame.VerticalAlignment = VerticalAlignment.Top;
            sourceOperationGlyph = new TextBlock();
            sourceOperationGlyph.HorizontalAlignment = HorizontalAlignment.Center;
            sourceOperationGlyph.VerticalAlignment = VerticalAlignment.Center;
            sourceOperationGlyph.FontSize = 12;
            sourceOperationGlyph.FontWeight = FontWeights.Bold;
            sourceOperationGlyphFrame.Child = sourceOperationGlyph;
            folder.Children.Add(sourceOperationGlyphFrame);

            StackPanel details = new StackPanel();
            TextBlock name = new TextBlock();
            name.Text = source.DisplayName;
            name.FontSize = 12;
            name.FontWeight = FontWeights.SemiBold;
            name.Foreground = PrimaryText;
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            details.Children.Add(name);
            TextBlock path = new TextBlock();
            path.Text = source.ShortPath;
            path.FontSize = 11;
            path.Foreground = MutedText;
            path.TextTrimming = TextTrimming.CharacterEllipsis;
            path.ToolTip = source.SourcePath;
            path.Margin = new Thickness(0, 2, 10, 0);
            details.Children.Add(path);
            Grid.SetColumn(details, 1);
            folder.Children.Add(details);

            sourceOperationTag = new Border();
            sourceOperationTag.BorderThickness = new Thickness(1);
            sourceOperationTag.CornerRadius = new CornerRadius(12);
            sourceOperationTag.Padding = new Thickness(7, 3, 7, 3);
            sourceOperationTag.VerticalAlignment = VerticalAlignment.Center;
            sourceOperationTagText = new TextBlock();
            sourceOperationTagText.FontSize = 10;
            sourceOperationTagText.FontWeight = FontWeights.SemiBold;
            sourceOperationTag.Child = sourceOperationTagText;
            Grid.SetColumn(sourceOperationTag, 2);
            folder.Children.Add(sourceOperationTag);
            layout.Children.Add(folder);

            Border statusFrame = new Border();
            statusFrame.Padding = new Thickness(12, 5, 8, 7);
            Grid statusLayout = new Grid();
            statusLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            statusLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            statusLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            StackPanel copy = new StackPanel();
            sourceOperationStatusText = new TextBlock();
            sourceOperationStatusText.FontSize = 11.5;
            sourceOperationStatusText.FontWeight = FontWeights.SemiBold;
            sourceOperationStatusText.TextTrimming = TextTrimming.CharacterEllipsis;
            AutomationProperties.SetLiveSetting(sourceOperationStatusText, AutomationLiveSetting.Polite);
            copy.Children.Add(sourceOperationStatusText);
            sourceOperationDetailText = new TextBlock();
            sourceOperationDetailText.FontSize = 10.5;
            sourceOperationDetailText.Foreground = MutedText;
            sourceOperationDetailText.TextTrimming = TextTrimming.CharacterEllipsis;
            sourceOperationDetailText.Margin = new Thickness(0, 2, 6, 0);
            copy.Children.Add(sourceOperationDetailText);
            statusLayout.Children.Add(copy);

            sourceOperationRetryButton = CreateButton("Retry");
            sourceOperationRetryButton.MinHeight = 28;
            sourceOperationRetryButton.Padding = new Thickness(10, 3, 10, 3);
            sourceOperationRetryButton.Margin = new Thickness(8, 0, 0, 0);
            sourceOperationRetryButton.VerticalAlignment = VerticalAlignment.Center;
            sourceOperationRetryButton.Click += OnRetrySourceOperationClick;
            AutomationProperties.SetAutomationId(sourceOperationRetryButton, "RetryAddFolderButton");
            Grid.SetColumn(sourceOperationRetryButton, 1);
            statusLayout.Children.Add(sourceOperationRetryButton);

            sourceOperationDismissButton = CreateButton("Dismiss");
            sourceOperationDismissButton.MinHeight = 28;
            sourceOperationDismissButton.Padding = new Thickness(10, 3, 10, 3);
            sourceOperationDismissButton.Margin = new Thickness(6, 0, 0, 0);
            sourceOperationDismissButton.VerticalAlignment = VerticalAlignment.Center;
            sourceOperationDismissButton.Click += OnDismissSourceOperationClick;
            AutomationProperties.SetAutomationId(sourceOperationDismissButton, "DismissAddFolderStatusButton");
            Grid.SetColumn(sourceOperationDismissButton, 2);
            statusLayout.Children.Add(sourceOperationDismissButton);
            statusFrame.Child = statusLayout;
            Grid.SetRow(statusFrame, 1);
            layout.Children.Add(statusFrame);

            sourceOperationRail = new Border();
            sourceOperationRail.Height = 2;
            sourceOperationRail.Background = BrushFrom("#25334A");
            sourceOperationRail.ClipToBounds = true;
            sourceOperationRail.IsHitTestVisible = false;
            sourceOperationRailSegment = new Border();
            sourceOperationRailSegment.Width = 56;
            sourceOperationRailSegment.Height = 2;
            sourceOperationRailSegment.HorizontalAlignment = HorizontalAlignment.Left;
            sourceOperationRailSegment.Background = Blue;
            sourceOperationRailTransform = new TranslateTransform(-56, 0);
            sourceOperationRailSegment.RenderTransform = sourceOperationRailTransform;
            sourceOperationRail.Child = sourceOperationRailSegment;
            Grid.SetRow(sourceOperationRail, 2);
            layout.Children.Add(sourceOperationRail);

            item.Child = layout;
            item.ToolTip = sourceOperationPath;
            sourceOperationItem = item;
            RenderSourceOperationItem(false, true);
            if (animateNextSourceOperationEntry)
            {
                animateNextSourceOperationEntry = false;
                AnimateSourceItemEntrance(item);
            }
            return item;
        }

        private FrameworkElement BuildResolvedSourceRow(
            FrameworkElement normalRow,
            BackupSourceView source)
        {
            Border wrapper = new Border();
            wrapper.Background = BrushFrom("#14352C");
            wrapper.BorderBrush = Green;
            wrapper.BorderThickness = new Thickness(2, 0, 0, 1);
            wrapper.ClipToBounds = true;
            wrapper.RenderTransform = new TranslateTransform(0, 0);

            StackPanel content = new StackPanel();
            content.Children.Add(normalRow);
            Border receipt = new Border();
            receipt.Padding = new Thickness(12, 5, 8, 6);
            Grid receiptLayout = new Grid();
            receiptLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            receiptLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            TextBlock check = new TextBlock();
            check.Text = "\u2713";
            check.FontSize = 13;
            check.FontWeight = FontWeights.Bold;
            check.Foreground = Green;
            check.Margin = new Thickness(0, 0, 8, 0);
            receiptLayout.Children.Add(check);
            TextBlock status = new TextBlock();
            status.Text = "Folder added  \u2022  Included in the next backup";
            status.FontSize = 11.5;
            status.FontWeight = FontWeights.SemiBold;
            status.Foreground = Green;
            status.TextTrimming = TextTrimming.CharacterEllipsis;
            AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
            Grid.SetColumn(status, 1);
            receiptLayout.Children.Add(status);
            receipt.Child = receiptLayout;
            content.Children.Add(receipt);
            wrapper.Child = content;
            AutomationProperties.SetName(
                wrapper,
                source.DisplayName + " added to protected folders and included in the next backup");

            sourceOperationItem = wrapper;
            sourceOperationStatusText = status;
            sourceOperationDetailText = null;
            sourceOperationRail = null;
            sourceOperationRailSegment = null;
            sourceOperationRailTransform = null;
            sourceOperationRetryButton = null;
            sourceOperationDismissButton = null;
            if (animateNextResolvedSourceRow)
            {
                animateNextResolvedSourceRow = false;
                AnimateSourceItemEntrance(wrapper);
            }
            AnnounceSourceOperation(
                source.SourcePath + " was added to protected folders.",
                false);
            return wrapper;
        }

        private void AnimateSourceItemEntrance(FrameworkElement element)
        {
            if (element == null || !SourceMotionAllowed())
            {
                return;
            }
            TranslateTransform transform = element.RenderTransform as TranslateTransform;
            if (transform == null)
            {
                transform = new TranslateTransform();
                element.RenderTransform = transform;
            }
            element.Opacity = 1;
            transform.Y = 0;
            DoubleAnimation fade = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(167));
            fade.BeginTime = TimeSpan.FromMilliseconds(42);
            fade.FillBehavior = FillBehavior.Stop;
            fade.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
            element.BeginAnimation(UIElement.OpacityProperty, fade, HandoffBehavior.SnapshotAndReplace);
            DoubleAnimation settle = new DoubleAnimation(-4, 0, TimeSpan.FromMilliseconds(167));
            settle.FillBehavior = FillBehavior.Stop;
            settle.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
            transform.BeginAnimation(TranslateTransform.YProperty, settle, HandoffBehavior.SnapshotAndReplace);
        }

        private bool SourceMotionAllowed()
        {
            return DashboardVisualStyle.MotionAllowed() &&
                themeResolution != null &&
                !themeResolution.IsHighContrast;
        }

        private void ResetSourceOperationVisualReferences()
        {
            sourceOperationItem = null;
            sourceOperationTag = null;
            sourceOperationTagText = null;
            sourceOperationGlyphFrame = null;
            sourceOperationGlyph = null;
            sourceOperationStatusText = null;
            sourceOperationDetailText = null;
            sourceOperationRail = null;
            sourceOperationRailSegment = null;
            sourceOperationRailTransform = null;
            sourceOperationRetryButton = null;
            sourceOperationDismissButton = null;
        }

        private void StopSourceOperationAnimation()
        {
            if (sourceOperationItem != null)
            {
                sourceOperationItem.BeginAnimation(UIElement.OpacityProperty, null);
                sourceOperationItem.Opacity = 1;
                TranslateTransform transform = sourceOperationItem.RenderTransform as TranslateTransform;
                if (transform != null)
                {
                    transform.BeginAnimation(TranslateTransform.YProperty, null);
                    transform.Y = 0;
                }
            }
            if (sourceOperationRailTransform != null)
            {
                sourceOperationRailTransform.BeginAnimation(TranslateTransform.XProperty, null);
                sourceOperationRailTransform.X = -56;
            }
        }

        private void RenderSourceOperationItem(bool animate, bool announce)
        {
            if (sourceOperationItem == null)
            {
                return;
            }

            string tag;
            string glyph;
            string status;
            string detail;
            Brush tone;
            bool busy = false;
            bool retryVisible = false;
            bool dismissVisible = false;
            bool assertive = false;

            switch (sourceOperationStage)
            {
                case SourceOperationStage.AwaitingApproval:
                    tag = "Approval";
                    glyph = ">";
                    status = "Waiting for Windows approval";
                    detail = "Approve the Windows prompt to continue. No backup has started.";
                    tone = BlueText;
                    break;
                case SourceOperationStage.Applying:
                    tag = "Adding";
                    glyph = "...";
                    status = "Adding protected folder...";
                    detail = "Updating the protected folder list. No backup has started.";
                    tone = Teal;
                    busy = true;
                    break;
                case SourceOperationStage.Verifying:
                    tag = "Checking";
                    glyph = "?";
                    status = "Checking the protected configuration...";
                    detail = "The folder is not shown as protected until this check passes.";
                    tone = BlueText;
                    busy = true;
                    break;
                case SourceOperationStage.Cancelled:
                    tag = "Cancelled";
                    glyph = "-";
                    status = "Windows approval was cancelled";
                    detail = "No folders were changed.";
                    tone = Amber;
                    dismissVisible = true;
                    break;
                case SourceOperationStage.Failed:
                    tag = "Needs attention";
                    glyph = "!";
                    status = "Could not add folder";
                    detail = string.IsNullOrWhiteSpace(sourceOperationError)
                        ? "The protected list was not changed."
                        : sourceOperationError + " Protected list unchanged.";
                    tone = Rose;
                    retryVisible = true;
                    dismissVisible = true;
                    assertive = true;
                    break;
                default:
                    tag = "Pending";
                    glyph = ".";
                    status = "Folder change pending";
                    detail = "No backup has started.";
                    tone = MutedText;
                    break;
            }

            sourceOperationItem.Background = BrushFrom("#111D2E");
            sourceOperationItem.BorderBrush = tone;
            if (sourceOperationTag != null)
            {
                sourceOperationTag.Background = BrushFrom("#17243A");
                sourceOperationTag.BorderBrush = tone;
            }
            if (sourceOperationTagText != null)
            {
                sourceOperationTagText.Text = tag.ToUpperInvariant();
                sourceOperationTagText.Foreground = tone;
            }
            if (sourceOperationGlyphFrame != null)
            {
                sourceOperationGlyphFrame.Background = BrushFrom("#17243A");
                sourceOperationGlyphFrame.BorderBrush = tone;
            }
            if (sourceOperationGlyph != null)
            {
                sourceOperationGlyph.Text = glyph;
                sourceOperationGlyph.Foreground = tone;
            }
            if (sourceOperationStatusText != null)
            {
                sourceOperationStatusText.Text = status;
                sourceOperationStatusText.Foreground = tone;
                if (animate && SourceMotionAllowed())
                {
                    sourceOperationStatusText.BeginAnimation(UIElement.OpacityProperty, null);
                    sourceOperationStatusText.Opacity = 0.35;
                    DoubleAnimation fade = new DoubleAnimation(0.35, 1, TimeSpan.FromMilliseconds(167));
                    fade.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
                    sourceOperationStatusText.BeginAnimation(UIElement.OpacityProperty, fade, HandoffBehavior.SnapshotAndReplace);
                }
            }
            if (sourceOperationDetailText != null)
            {
                sourceOperationDetailText.Text = detail;
                sourceOperationDetailText.Foreground = MutedText;
            }
            if (sourceOperationRetryButton != null)
            {
                sourceOperationRetryButton.Visibility = retryVisible ? Visibility.Visible : Visibility.Collapsed;
                sourceOperationRetryButton.IsEnabled = retryVisible &&
                    !sourceOperationInProgress &&
                    !RepositoryRecoveryBlocksMutations();
                AutomationProperties.SetName(sourceOperationRetryButton, "Retry adding folder");
                AutomationProperties.SetHelpText(sourceOperationRetryButton, sourceOperationPath);
            }
            if (sourceOperationDismissButton != null)
            {
                sourceOperationDismissButton.Visibility = dismissVisible ? Visibility.Visible : Visibility.Collapsed;
                AutomationProperties.SetName(sourceOperationDismissButton, "Dismiss folder add status");
                AutomationProperties.SetHelpText(sourceOperationDismissButton, sourceOperationPath);
            }
            AutomationProperties.SetName(sourceOperationItem, status + ". " + detail + " " + sourceOperationPath);
            AutomationProperties.SetLiveSetting(
                sourceOperationItem,
                assertive ? AutomationLiveSetting.Assertive : AutomationLiveSetting.Polite);

            if (busy)
            {
                StartSourceOperationActivity();
            }
            else
            {
                StopSourceOperationAnimation();
                if (sourceOperationRail != null)
                {
                    sourceOperationRail.Background = BrushFrom("#25334A");
                }
                if (sourceOperationRailSegment != null)
                {
                    sourceOperationRailSegment.Visibility = Visibility.Collapsed;
                }
            }
            if (announce)
            {
                AnnounceSourceOperation(status + ". " + detail, assertive);
            }
        }

        private void StartSourceOperationActivity()
        {
            if (sourceOperationRail == null || sourceOperationRailSegment == null)
            {
                return;
            }
            if (!SourceMotionAllowed())
            {
                StopSourceOperationAnimation();
                sourceOperationRail.Background = Blue;
                sourceOperationRailSegment.Visibility = Visibility.Collapsed;
                return;
            }

            sourceOperationRail.Background = BrushFrom("#25334A");
            sourceOperationRailSegment.Visibility = Visibility.Visible;
            sourceOperationRailSegment.Background = Teal;
            if (sourceOperationRailTransform == null)
            {
                sourceOperationRailTransform = new TranslateTransform(-56, 0);
                sourceOperationRailSegment.RenderTransform = sourceOperationRailTransform;
            }
            sourceOperationRailTransform.BeginAnimation(TranslateTransform.XProperty, null);
            sourceOperationRailTransform.X = -56;

            DoubleAnimationUsingKeyFrames travel = new DoubleAnimationUsingKeyFrames();
            travel.BeginTime = TimeSpan.FromSeconds(1);
            travel.Duration = TimeSpan.FromMilliseconds(1500);
            travel.RepeatBehavior = RepeatBehavior.Forever;
            travel.KeyFrames.Add(new DiscreteDoubleKeyFrame(-56, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            travel.KeyFrames.Add(new LinearDoubleKeyFrame(420, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(900))));
            travel.KeyFrames.Add(new DiscreteDoubleKeyFrame(-56, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(901))));
            travel.KeyFrames.Add(new DiscreteDoubleKeyFrame(-56, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(1500))));
            sourceOperationRailTransform.BeginAnimation(
                TranslateTransform.XProperty,
                travel,
                HandoffBehavior.SnapshotAndReplace);
        }

        private void AnnounceSourceOperation(string message, bool assertive)
        {
            if (string.IsNullOrWhiteSpace(message) ||
                string.Equals(message, lastSourceOperationAnnouncement, StringComparison.Ordinal))
            {
                return;
            }
            lastSourceOperationAnnouncement = message;
            FrameworkElement target = sourceOperationStatusText as FrameworkElement ?? sourceOperationItem;
            if (target == null)
            {
                return;
            }
            AutomationProperties.SetName(target, message);
            AutomationProperties.SetLiveSetting(
                target,
                assertive ? AutomationLiveSetting.Assertive : AutomationLiveSetting.Polite);
            Dispatcher.BeginInvoke(
                new Action(delegate
                {
                    AutomationPeer peer = UIElementAutomationPeer.FromElement(target) ??
                        UIElementAutomationPeer.CreatePeerForElement(target);
                    if (peer != null)
                    {
                        peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
                    }
                }),
                DispatcherPriority.Background);
        }

        private void SetSourceOperationStage(
            SourceOperationStage stage,
            string error,
            DateTime expiresUtc,
            bool rebuild,
            bool animate)
        {
            sourceOperationStage = stage;
            sourceOperationError = error ?? string.Empty;
            sourceOperationExpiresUtc = expiresUtc;
            if (rebuild)
            {
                sourceSignature = null;
                RefreshSources(true);
                PublishWebPresentationState();
                return;
            }
            RenderSourceOperationItem(animate, true);
            PublishWebPresentationState();
        }

        private void ResetSourceOperationState()
        {
            sourceOperationStage = SourceOperationStage.Idle;
            sourceOperationAction = string.Empty;
            sourceOperationPath = string.Empty;
            sourceOperationError = string.Empty;
            sourceOperationExpiresUtc = DateTime.MinValue;
            lastSourceOperationAnnouncement = string.Empty;
            animateNextSourceOperationEntry = false;
            animateNextResolvedSourceRow = false;
            sourceOperationGeneration++;
        }

        private async void OnRetrySourceOperationClick(object sender, RoutedEventArgs args)
        {
            if (sourceOperationInProgress ||
                !string.Equals(sourceOperationAction, "Add", StringComparison.Ordinal) ||
                string.IsNullOrWhiteSpace(sourceOperationPath))
            {
                return;
            }
            string path = sourceOperationPath;
            SourceConfiguration configuration = currentSourceConfiguration ?? SourceConfiguration.Load();
            if (configuration.ContainsUserSource(path))
            {
                sourceOperationStage = SourceOperationStage.Succeeded;
                sourceOperationExpiresUtc = DateTime.UtcNow.AddSeconds(4);
                animateNextResolvedSourceRow = true;
                RefreshSources(true);
                return;
            }
            if (BackupBlocksSourceChanges())
            {
                SetSourceOperationStage(
                    SourceOperationStage.Failed,
                    "A backup is starting or already running.",
                    DateTime.MaxValue,
                    false,
                    true);
                return;
            }
            await ApplySourceChange("Add", path);
        }

        private void OnDismissSourceOperationClick(object sender, RoutedEventArgs args)
        {
            if (sourceOperationInProgress)
            {
                return;
            }
            ResetSourceOperationState();
            sourceSignature = null;
            RefreshSources(true);
        }

        private UIElement BuildHistory()
        {
            historyLayout = new Grid();
            historyLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            Border tableCard = CreateCard();
            tableCard.MinHeight = 300;
            historyTable = tableCard;
            tableCard.Padding = new Thickness(16, 12, 16, 10);
            Grid tableGrid = new Grid();
            tableGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            tableGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            Grid tableHeader = new Grid();
            tableHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            tableHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock tableTitle = new TextBlock();
            tableTitle.Text = "Recent backups";
            tableTitle.FontSize = 15;
            tableTitle.FontWeight = FontWeights.SemiBold;
            tableHeader.Children.Add(tableTitle);
            StackPanel activityMeta = new StackPanel();
            activityMeta.Orientation = Orientation.Horizontal;
            activityMeta.VerticalAlignment = VerticalAlignment.Center;
            runChart = new RunChart(themeResolution.Palette);
            historyChart = runChart;
            runChart.Width = 150;
            runChart.Height = 28;
            runChart.Margin = new Thickness(0, 0, 12, 0);
            activityMeta.Children.Add(runChart);
            runCount = new TextBlock();
            runCount.Text = "0 runs";
            runCount.FontSize = 11;
            runCount.FontWeight = FontWeights.SemiBold;
            runCount.Foreground = MutedText;
            runCount.VerticalAlignment = VerticalAlignment.Center;
            activityMeta.Children.Add(runCount);
            viewRunDetailsButton = CreateButton("Open details");
            viewRunDetailsButton.MinHeight = 34;
            viewRunDetailsButton.Margin = new Thickness(12, 0, 0, 0);
            viewRunDetailsButton.IsEnabled = false;
            viewRunDetailsButton.Click += OnViewRunDetailsClick;
            AutomationProperties.SetAutomationId(
                viewRunDetailsButton,
                "ViewRunDetailsButton");
            AutomationProperties.SetName(
                viewRunDetailsButton,
                "Open details for the selected backup run");
            activityMeta.Children.Add(viewRunDetailsButton);
            exportDiagnosticsButton = CreateButton("Export diagnostics");
            exportDiagnosticsButton.MinHeight = 34;
            exportDiagnosticsButton.Margin = new Thickness(8, 0, 0, 0);
            exportDiagnosticsButton.Click += OnExportDiagnosticsClick;
            AutomationProperties.SetAutomationId(
                exportDiagnosticsButton,
                "ExportDiagnosticsButton");
            AutomationProperties.SetName(
                exportDiagnosticsButton,
                "Export a redacted diagnostic support bundle");
            AutomationProperties.SetHelpText(
                exportDiagnosticsButton,
                "Creates a new ZIP outside protected paths and removes personal paths, identities, commands, and credential-like values.");
            activityMeta.Children.Add(exportDiagnosticsButton);
            Grid.SetColumn(activityMeta, 1);
            tableHeader.Children.Add(activityMeta);
            tableGrid.Children.Add(tableHeader);

            historyGrid = CreateHistoryGrid();
            historyGrid.Margin = new Thickness(0, 8, 0, 0);
            historyGrid.SelectionChanged += OnHistorySelectionChanged;
            historyGrid.MouseDoubleClick += OnHistoryMouseDoubleClick;
            historyGrid.PreviewKeyDown += OnHistoryPreviewKeyDown;
            Grid.SetRow(historyGrid, 1);
            tableGrid.Children.Add(historyGrid);

            tableCard.Child = tableGrid;
            historyLayout.Children.Add(tableCard);
            return historyLayout;
        }

        private DataGrid CreateHistoryGrid()
        {
            DataGrid grid = new DataGrid();
            grid.AutoGenerateColumns = false;
            grid.IsReadOnly = true;
            grid.CanUserAddRows = false;
            grid.CanUserDeleteRows = false;
            grid.CanUserResizeRows = false;
            grid.HeadersVisibility = DataGridHeadersVisibility.Column;
            grid.GridLinesVisibility = DataGridGridLinesVisibility.Horizontal;
            grid.HorizontalGridLinesBrush = BrushFrom("#223149");
            grid.VerticalGridLinesBrush = Brushes.Transparent;
            grid.Background = Brushes.Transparent;
            grid.Foreground = PrimaryText;
            grid.BorderThickness = new Thickness(0);
            grid.RowBackground = Brushes.Transparent;
            grid.AlternatingRowBackground = BrushFrom("#0F1A2B");
            grid.AlternationCount = 2;
            grid.RowHeight = 36;
            grid.SelectionMode = DataGridSelectionMode.Single;
            grid.SelectionUnit = DataGridSelectionUnit.FullRow;
            grid.SelectionBrushCompat(
                themeResolution.Palette.Selection,
                themeResolution.Palette.TextPrimary,
                themeResolution.Palette.SelectionText);

            Style headerStyle = new Style(typeof(DataGridColumnHeader));
            headerStyle.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.Transparent));
            headerStyle.Setters.Add(new Setter(Control.ForegroundProperty, MutedText));
            headerStyle.Setters.Add(new Setter(Control.FontSizeProperty, 12.0));
            headerStyle.Setters.Add(new Setter(Control.FontWeightProperty, FontWeights.Bold));
            headerStyle.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(0, 0, 0, 1)));
            headerStyle.Setters.Add(new Setter(Control.BorderBrushProperty, CardBorderBrush));
            headerStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(5, 0, 5, 7)));
            grid.ColumnHeaderStyle = headerStyle;
            DashboardVisualStyle.ApplyDataGridChrome(grid, themeResolution.Palette);

            grid.Columns.Add(TextColumn("When", "StartedDisplay", 1.35));
            grid.Columns.Add(TextColumn("Result", "StateLabel", 1.0));
            grid.Columns.Add(TextColumn("Duration", "DurationDisplay", 0.9));
            grid.Columns.Add(TextColumn("Files", "FilesDisplay", 0.9));
            grid.Columns.Add(TextColumn("Processed", "ProcessedDisplay", 1.05));
            return grid;
        }

        private void OnHistorySelectionChanged(object sender, SelectionChangedEventArgs args)
        {
            UpdateActivityActions();
            if (historyRebindInProgress)
            {
                // The grid clears and restores its selection while ApplySnapshot gives it the same runs again. Nothing
                // was chosen, and the page is sent the finished state once, not the half-way ones.
                return;
            }
            PublishWebPresentationState();
        }

        private void OnHistoryMouseDoubleClick(object sender, MouseButtonEventArgs args)
        {
            if (historyGrid != null && historyGrid.SelectedItem is RunMetricView)
            {
                OpenSelectedRunDetails();
                args.Handled = true;
            }
        }

        private void OnHistoryPreviewKeyDown(object sender, KeyEventArgs args)
        {
            if ((args.Key == Key.Enter || args.Key == Key.Return) &&
                historyGrid != null && historyGrid.SelectedItem is RunMetricView)
            {
                OpenSelectedRunDetails();
                args.Handled = true;
            }
        }

        private void OnViewRunDetailsClick(object sender, RoutedEventArgs args)
        {
            OpenSelectedRunDetails();
        }

        private void OpenSelectedRunDetails()
        {
            RunMetricView run = historyGrid == null
                ? null
                : historyGrid.SelectedItem as RunMetricView;
            if (run == null)
            {
                UpdateActivityActions();
                return;
            }
            try
            {
                if (CanShowWebRunDetails())
                {
                    ShowWebRunDetails(run);
                    return;
                }
                SourceConfiguration configuration = currentSourceConfiguration ??
                    SourceConfiguration.Load();
                RunDetails details = RunDetailsReader.Load(configuration, run);
                RunDetailsWindow window = new RunDetailsWindow(
                    details,
                    themeResolution.Palette);
                window.Owner = this;
                window.ShowDialog();
            }
            catch (Exception error)
            {
                MessageBox.Show(
                    this,
                    "Run details could not be opened.\n\n" + error.Message,
                    "Run details unavailable",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        private async void OnExportDiagnosticsClick(object sender, RoutedEventArgs args)
        {
            UpdateActivityActions();
            if (diagnosticExportInProgress || currentSourceConfiguration == null ||
                exportDiagnosticsButton == null || !exportDiagnosticsButton.IsEnabled)
            {
                return;
            }

            SourceConfiguration exportConfiguration = currentSourceConfiguration;
            SaveFileDialog dialog = new SaveFileDialog();
            dialog.Title = "Export redacted Rewindle diagnostics";
            dialog.Filter = "ZIP archive (*.zip)|*.zip";
            dialog.DefaultExt = ".zip";
            dialog.AddExtension = true;
            dialog.CheckPathExists = true;
            dialog.CheckFileExists = false;
            dialog.OverwritePrompt = false;
            dialog.FileName = "rewindle-diagnostics-" +
                DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) +
                ".zip";
            string startFolder = ChooseDiagnosticsFolder(exportConfiguration);
            if (startFolder != null)
            {
                dialog.InitialDirectory = startFolder;
            }
            // The destination rules are applied before the dialog closes, so a refusal is read while another folder can still be
            // chosen. The export checks them again when it starts: the folder can change between the two, and nothing here is
            // relied on. A box with no owner is parented to the dialog itself, which is the window that is active.
            dialog.FileOk += delegate(object dialogSender, CancelEventArgs fileArgs)
            {
                string refusal = null;
                try
                {
                    string chosen = DiagnosticExporter.ValidateDestination(exportConfiguration, dialog.FileName);
                    if (File.Exists(chosen) || Directory.Exists(chosen))
                    {
                        refusal = "Choose a new ZIP filename. Existing files are never overwritten by diagnostic export.";
                    }
                }
                catch (Exception problem)
                {
                    refusal = problem.Message;
                }
                if (refusal != null)
                {
                    fileArgs.Cancel = true;
                    MessageBox.Show(
                        refusal,
                        "Choose another place",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                }
            };
            bool? accepted = dialog.ShowDialog(this);
            if (!accepted.HasValue || !accepted.Value)
            {
                return;
            }

            SourceConfiguration configuration = currentSourceConfiguration;
            TaskSchedule schedule = currentTaskSchedule;
            TelemetrySnapshot snapshot = lastSnapshot;
            diagnosticExportInProgress = true;
            UpdateActivityActions();
            DiagnosticExportResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return DiagnosticExporter.Export(
                        configuration,
                        schedule,
                        snapshot,
                        dialog.FileName);
                });
            }
            catch (Exception error)
            {
                result = DiagnosticExportResult.Failure(error.Message);
            }
            finally
            {
                diagnosticExportInProgress = false;
            }
            UpdateActivityActions();
            if (result.Succeeded)
            {
                MessageBoxResult show = MessageBox.Show(
                    this,
                    "A redacted, read-only support bundle was created.\n\n" +
                        result.ExportPath + "\n\n" +
                        "Personal paths, identities, command lines, and credential-like values were removed. " +
                        "manifest.json inside lists anything that could not be included.\n\n" +
                        "Show it in its folder?",
                    "Diagnostics exported",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information,
                    MessageBoxResult.Yes);
                if (show == MessageBoxResult.Yes)
                {
                    ShowDiagnosticsInFolder(result.ExportPath);
                }
            }
            else
            {
                MessageBox.Show(
                    this,
                    result.ErrorMessage ?? "The diagnostic bundle was not created.",
                    "Diagnostic export failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        // Selects the new bundle in File Explorer. The path is the one the export just wrote (and validated), and is quoted the
        // way the run log's location is.
        private static void ShowDiagnosticsInFolder(string exportPath)
        {
            if (string.IsNullOrWhiteSpace(exportPath))
            {
                return;
            }
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "/select,\"" + exportPath + "\"",
                    UseShellExecute = true
                });
            }
            catch (Exception error)
            {
                CrashLog.Write("Diagnostics: show in folder", error);
            }
        }

        // The folder the Save dialog opens in: the first of the Desktop, Documents, the temporary folder and the other fixed drives
        // where a bundle is accepted. The Desktop and Documents are common protected folders, and a bundle is refused inside one,
        // which the person only learned after choosing a name; this starts them somewhere it will be allowed. Null when no
        // candidate qualifies, and then the dialog opens where Windows chooses.
        private static string ChooseDiagnosticsFolder(SourceConfiguration configuration)
        {
            return FirstAcceptedDiagnosticsFolder(configuration, DiagnosticsFolderCandidates());
        }

        // The places to try, in order. The drives are listed only when none of the folders before them was accepted, so the usual
        // answer costs no more than a look at the Desktop.
        private static IEnumerable<string> DiagnosticsFolderCandidates()
        {
            yield return Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            yield return Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            yield return System.IO.Path.GetTempPath();
            DriveInfo[] drives;
            string systemRoot;
            try
            {
                systemRoot = System.IO.Path.GetPathRoot(Environment.SystemDirectory);
                drives = DriveInfo.GetDrives();
            }
            catch (Exception)
            {
                // A drive that cannot be listed is a drive that is not offered.
                yield break;
            }
            foreach (DriveInfo drive in drives)
            {
                // The system drive's root is not writable without elevation, so only the other fixed drives are offered.
                if (drive.DriveType == DriveType.Fixed &&
                    !string.Equals(drive.Name, systemRoot, StringComparison.OrdinalIgnoreCase))
                {
                    yield return drive.Name;
                }
            }
        }

        // The first folder where the export's own destination rules (DiagnosticExporter.ValidateDestination) accept a bundle, asked
        // with a placeholder name; nothing is created. A folder that overlaps a protected path, does not exist or is reached
        // through a link is skipped, and so is one that is blank.
        private static string FirstAcceptedDiagnosticsFolder(
            SourceConfiguration configuration,
            IEnumerable<string> candidates)
        {
            if (configuration == null || candidates == null)
            {
                return null;
            }
            foreach (string candidate in candidates)
            {
                if (string.IsNullOrWhiteSpace(candidate))
                {
                    continue;
                }
                try
                {
                    DiagnosticExporter.ValidateDestination(
                        configuration,
                        System.IO.Path.Combine(candidate, "rewindle-diagnostics.zip"));
                    return candidate;
                }
                catch (Exception)
                {
                    // Not here.
                }
            }
            return null;
        }

        private void UpdateActivityActions()
        {
            if (viewRunDetailsButton != null)
            {
                bool selected = historyGrid != null &&
                    historyGrid.SelectedItem is RunMetricView;
                viewRunDetailsButton.IsEnabled = selected;
                viewRunDetailsButton.ToolTip = selected
                    ? "Open structured details and bounded protected log events for this run."
                    : "Select a backup run first.";
            }
            if (exportDiagnosticsButton != null)
            {
                bool conflict = BackupBlocksSourceChanges();
                bool enabled = currentSourceConfiguration != null &&
                    !diagnosticExportInProgress && !conflict;
                exportDiagnosticsButton.Content = diagnosticExportInProgress
                    ? "Exporting..."
                    : "Export diagnostics";
                exportDiagnosticsButton.IsEnabled = enabled;
                string help = diagnosticExportInProgress
                    ? "The redacted diagnostic ZIP is being created."
                    : conflict
                        ? "Wait for the protected operation to finish before exporting a consistent bundle."
                        : currentSourceConfiguration == null
                            // The bundle is redacted and checked against the installed configuration, so without one it cannot
                            // be made safely; the reason is the same sentence the other disabled controls give.
                            ? (string.IsNullOrEmpty(sourceConfigurationNote)
                                ? "Rewindle is still reading the backup configuration."
                                : sourceConfigurationNote)
                            : "Create a new redacted support ZIP outside protected backup paths.";
                exportDiagnosticsButton.ToolTip = help;
                AutomationProperties.SetHelpText(exportDiagnosticsButton, help);
                AutomationProperties.SetItemStatus(exportDiagnosticsButton, help);
            }
        }

        private DataGridTextColumn TextColumn(string header, string path, double width)
        {
            DataGridTextColumn column = new DataGridTextColumn();
            column.Header = header;
            column.Binding = new Binding(path);
            column.Width = new DataGridLength(width, DataGridLengthUnitType.Star);
            ElementStyleHolder.Apply(column);
            return column;
        }

        private void ApplyWindowPalette()
        {
            DashboardVisualStyle.ApplyWindow(this, themeResolution.Palette);
        }

        private void OnWindowSizeChanged(object sender, SizeChangedEventArgs args)
        {
            ApplyResponsiveLayout();
        }

        private void OnDashboardPreviewKeyDown(object sender, KeyEventArgs args)
        {
            if (args.Key == Key.F5)
            {
                RefreshDashboard();
                args.Handled = true;
            }
        }

        private void ApplyResponsiveLayout()
        {
            if (headerLayout == null || shellLayout == null || navigationRail == null || footerLayout == null)
            {
                return;
            }

            double availableWidth = ActualWidth > 0 ? ActualWidth : Width;
            bool compact = availableWidth < 1320;
            if (compactLayout.HasValue && compactLayout.Value == compact)
            {
                return;
            }
            compactLayout = compact;
            shellLayout.ColumnDefinitions[0].Width = new GridLength(compact ? 56 : 216);
            navigationRail.Padding = compact
                ? new Thickness(6, 18, 6, 14)
                : new Thickness(18, 22, 18, 16);
            if (navigationBrand != null)
            {
                navigationBrand.Text = compact ? "R" : "REWINDLE";
                navigationBrand.HorizontalAlignment = compact
                    ? HorizontalAlignment.Center
                    : HorizontalAlignment.Left;
                navigationBrand.Margin = compact
                    ? new Thickness(0, 4, 0, 0)
                    : new Thickness(8, 2, 0, 0);
            }
            ConfigureNavigationButton(protectionNavButton, compact);
            ConfigureNavigationButton(activityNavButton, compact);
            ConfigureNavigationButton(restoreNavButton, compact);
            ConfigureNavigationButton(settingsNavButton, compact);

            footerLayout.ColumnDefinitions[0].Width = new GridLength(1, GridUnitType.Star);
            footerLayout.ColumnDefinitions[1].Width = GridLength.Auto;
            footerLayout.RowDefinitions[0].Height = GridLength.Auto;
            footerLayout.RowDefinitions[1].Height = new GridLength(0);
            Grid.SetColumn(footerDetails, 0);
            Grid.SetRow(footerDetails, 0);
            Grid.SetColumn(lastUpdated, 1);
            Grid.SetRow(lastUpdated, 0);
            lastUpdated.HorizontalAlignment = HorizontalAlignment.Right;
            lastUpdated.Margin = new Thickness(0);
        }

        private void ConfigureNavigationButton(Button button, bool compact)
        {
            if (button == null)
            {
                return;
            }
            string[] metadata = button.Tag as string[];
            if (metadata == null || metadata.Length < 3)
            {
                return;
            }
            button.Content = compact
                ? BuildIconLabel(metadata[1], string.Empty)
                : BuildIconLabel(metadata[1], metadata[2]);
            button.HorizontalContentAlignment = compact
                ? HorizontalAlignment.Center
                : HorizontalAlignment.Left;
            button.Padding = compact
                ? new Thickness(0, 8, 0, 8)
                : new Thickness(10, 8, 10, 8);
        }

        private void OnThemeSegmentClick(object sender, RoutedEventArgs args)
        {
            Button button = sender as Button;
            if (button == null || !(button.Tag is DashboardThemePreference))
            {
                return;
            }
            DashboardThemePreference preference = (DashboardThemePreference)button.Tag;
            if (preference == themePreference || themeChangeInProgress)
            {
                return;
            }

            themePreference = preference;
            themeResolution = DashboardThemeManager.Resolve(preference);
            DashboardThemeManager.TrySavePreference(preference);
            RebuildVisualTreeForTheme(preference);
            PublishWebPresentationState();
        }

        private void OnMotionSegmentClick(object sender, RoutedEventArgs args)
        {
            Button button = sender as Button;
            if (button == null || !(button.Tag is DashboardMotionPreference))
            {
                return;
            }
            DashboardMotionPreference preference = (DashboardMotionPreference)button.Tag;
            string error;
            if (!TrySetMotionPreference(preference, out error) && options.UseNativePresentation)
            {
                MessageBox.Show(
                    error,
                    "Rewindle",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private bool TrySetMotionPreference(
            DashboardMotionPreference preference,
            out string error)
        {
            error = string.Empty;
            if (preference == motionPreference)
            {
                return true;
            }
            if (!DashboardMotion.TrySavePreference(preference))
            {
                error = "The motion preference could not be saved. Your previous setting is still active.";
                return false;
            }

            motionPreference = preference;
            DashboardMotion.SetPreference(preference);
            motionResolution = DashboardMotion.Resolve(preference);
            foreach (KeyValuePair<DashboardMotionPreference, Button> entry in motionButtons)
            {
                StyleMotionSegment(entry.Value, entry.Key == motionPreference);
            }
            RefreshMotionEffects();
            PublishWebPresentationState();
            return true;
        }

        private bool RefreshEffectiveTheme()
        {
            if (themeChangeInProgress)
            {
                return false;
            }
            DashboardThemeResolution resolution = DashboardThemeManager.Resolve(themePreference);
            if (SameEffectiveTheme(resolution, themeResolution))
            {
                return false;
            }
            themeResolution = resolution;
            RebuildVisualTreeForTheme(null);
            return true;
        }

        private bool RefreshEffectiveMotion()
        {
            DashboardMotionResolution resolution = DashboardMotion.Resolve(motionPreference);
            bool changed = motionResolution == null ||
                motionResolution.MotionAllowed != resolution.MotionAllowed ||
                motionResolution.IsHighContrast != resolution.IsHighContrast;
            motionResolution = resolution;
            DashboardMotion.SetPreference(motionPreference);
            return changed;
        }

        private static bool SameEffectiveTheme(
            DashboardThemeResolution first,
            DashboardThemeResolution second)
        {
            if (first == null || second == null ||
                first.EffectiveKind != second.EffectiveKind ||
                first.IsHighContrast != second.IsHighContrast)
            {
                return false;
            }
            DashboardThemePalette firstPalette = first.Palette;
            DashboardThemePalette secondPalette = second.Palette;
            return firstPalette.BackgroundTop.Color == secondPalette.BackgroundTop.Color &&
                firstPalette.TextPrimary.Color == secondPalette.TextPrimary.Color &&
                firstPalette.ButtonBackground.Color == secondPalette.ButtonBackground.Color &&
                firstPalette.ButtonText.Color == secondPalette.ButtonText.Color &&
                firstPalette.Selection.Color == secondPalette.Selection.Color &&
                firstPalette.SelectionText.Color == secondPalette.SelectionText.Color &&
                firstPalette.Focus.Color == secondPalette.Focus.Color;
        }

        private void RebuildVisualTreeForTheme(
            DashboardThemePreference? themeToFocus)
        {
            if (themeChangeInProgress)
            {
                return;
            }

            ScrollViewer oldPage = Content as ScrollViewer;
            double oldOffset = oldPage == null ? 0 : oldPage.VerticalOffset;
            RunMetricView selectedRun = historyGrid == null ? null : historyGrid.SelectedItem as RunMetricView;
            string selectedRunId = selectedRun == null ? null : selectedRun.RunId;
            themeChangeInProgress = true;
            try
            {
                StopStatusPulse();
                ApplyWindowPalette();
                sourceSignature = null;
                Content = BuildInterface();
                RefreshDashboard();
                if (historyGrid != null && !string.IsNullOrEmpty(selectedRunId))
                {
                    RunMetricView matchingRun = historyGrid.Items.OfType<RunMetricView>()
                        .FirstOrDefault(run => string.Equals(run.RunId, selectedRunId, StringComparison.Ordinal));
                    if (matchingRun != null) historyGrid.SelectedItem = matchingRun;
                }
                DashboardVisualStyle.Reveal(shellLayout, DashboardVisualStyle.ExpandDuration, TimeSpan.Zero, 0.0);
                ScrollViewer newPage = Content as ScrollViewer;
                if (newPage != null && oldOffset > 0)
                {
                    Dispatcher.BeginInvoke(
                        new Action(delegate { newPage.ScrollToVerticalOffset(oldOffset); }),
                        DispatcherPriority.Loaded);
                }
                Button newThemeButton;
                if (themeToFocus.HasValue &&
                    themeButtons.TryGetValue(themeToFocus.Value, out newThemeButton))
                {
                    Dispatcher.BeginInvoke(
                        new Action(delegate { newThemeButton.Focus(); }),
                        DispatcherPriority.Input);
                }
            }
            finally
            {
                themeChangeInProgress = false;
            }
        }

        private void OnLoaded(object sender, RoutedEventArgs args)
        {
            if (hideAtLoad)
            {
                // The quiet start (--minimized): out of sight first, so nothing is seen while the first read runs. That read
                // waits until the dispatcher has nothing else to do, so it does not hold up the tray icon or the page's load,
                // and the one-second tick brings the rest of the data in as usual. Only the first load is quiet: a window the
                // person asked for before it finished loading (ShowDashboard clears the flag) stays up.
                hideAtLoad = false;
                HideToTray();
                ApplyResponsiveLayout();
                Dispatcher.BeginInvoke(new Action(RefreshDashboard), DispatcherPriority.ApplicationIdle);
                return;
            }
            ApplyResponsiveLayout();
            RefreshDashboard();
            DashboardVisualStyle.Reveal(shellLayout);
        }

        // A window that was hidden or minimized is not sent states (see PostWebPresentationState), so the one it missed is
        // sent as soon as it can be seen again instead of at the next refresh.
        private void OnWindowVisibilityChanged(object sender, DependencyPropertyChangedEventArgs args)
        {
            if (IsVisible)
            {
                PublishWebPresentationState();
            }
        }

        private void OnWindowStateChanged(object sender, EventArgs args)
        {
            if (WindowState != WindowState.Minimized)
            {
                PublishWebPresentationState();
            }
        }

        private async void OnRefreshTick(object sender, EventArgs args)
        {
            if (showEvent.WaitOne(0))
            {
                ShowDashboard();
            }
            CheckWebPresentationResponsive();
            if (refreshTickInFlight)
            {
                // The previous load is still reading; never queue another behind it.
                return;
            }
            refreshTickInFlight = true;
            int generation = refreshGeneration;
            TelemetrySnapshot snapshot = null;
            Exception loadFailure = null;
            try
            {
                snapshot = await Task.Run(delegate { return reader.Load(); });
            }
            catch (Exception error)
            {
                loadFailure = error;
            }
            finally
            {
                refreshTickInFlight = false;
            }
            if (webPresentationClosing || generation != refreshGeneration)
            {
                return;
            }
            RefreshRepositoryRecoveryStatus();
            RefreshSchedule(false);
            ApplyTelemetryRefresh(snapshot, loadFailure);
        }

        private void OnUserPreferenceChanged(
            object sender,
            UserPreferenceChangedEventArgs args)
        {
            QueueEffectiveThemeRefresh();
        }

        private void OnSystemParametersChanged(
            object sender,
            PropertyChangedEventArgs args)
        {
            QueueEffectiveThemeRefresh();
        }

        private void QueueEffectiveThemeRefresh()
        {
            if (Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
            {
                return;
            }
            Dispatcher.BeginInvoke(
                new Action(delegate
                {
                    bool rebuilt = RefreshEffectiveTheme();
                    bool motionChanged = RefreshEffectiveMotion();
                    if (!rebuilt)
                    {
                        RefreshMotionEffects();
                    }
                    if (rebuilt || motionChanged)
                    {
                        PublishWebPresentationState();
                    }
                }),
                DispatcherPriority.Background);
        }

        private void RefreshMotionEffects()
        {
            if (SourceMotionAllowed())
            {
                if (lastSnapshot != null &&
                    (lastSnapshot.IsActive || previewEnabled))
                {
                    StartShimmer();
                    StartStatusPulse();
                }
                else
                {
                    StopShimmer();
                }
                if (sourceOperationStage == SourceOperationStage.Applying ||
                    sourceOperationStage == SourceOperationStage.Verifying)
                {
                    StartSourceOperationActivity();
                }
                return;
            }
            StopShimmer();
            StopStatusPulse();
            StopSourceOperationAnimation();
            if (sourceOperationRail != null &&
                (sourceOperationStage == SourceOperationStage.Applying ||
                    sourceOperationStage == SourceOperationStage.Verifying))
            {
                sourceOperationRail.Background = Blue;
            }
            if (sourceOperationRailSegment != null)
            {
                sourceOperationRailSegment.Visibility = Visibility.Collapsed;
            }
        }

        private bool RepositoryRecoveryBlocksMutations()
        {
            return repositoryRecoveryInProgress ||
                (repositoryRecoveryStatus != null && repositoryRecoveryStatus.Exists);
        }

        private bool RepositoryRecoveryHasConflictingOperation()
        {
            return repositoryOperationInProgress ||
                sourceOperationInProgress ||
                scheduleOperationInProgress ||
                anomalyReviewInProgress ||
                backupStartInProgress ||
                CancellationBlocksMutations(lastSnapshot) ||
                DateTime.UtcNow < backupRequestPendingUntilUtc ||
                (lastSnapshot != null && lastSnapshot.IsActive);
        }

        private static bool RepositoryRecoveryManagerAvailable()
        {
            string managerPath;
            try
            {
                managerPath = EngineProfile.Current.ManagerPath(
                    EngineProfile.Current.RepositoryManagerFileName);
            }
            catch (InvalidOperationException)
            {
                return false;
            }
            return File.Exists(managerPath) && !Directory.Exists(managerPath);
        }

        private void RefreshRepositoryRecoveryStatus()
        {
            RepositoryRecoveryStatus status;
            try
            {
                status = RepositoryManagerLauncher.GetRecoveryStatus();
            }
            catch
            {
                status = RepositoryRecoveryStatus.Blocked(
                    "The interrupted-move journal could not be inspected. Backups remain paused until the protected installation is repaired.");
            }
            repositoryRecoveryStatus = status ?? RepositoryRecoveryStatus.Blocked(
                "The interrupted-move recovery status is unavailable. Backups remain paused.");
            if (!repositoryRecoveryInProgress && !repositoryRecoveryStatus.Exists)
            {
                repositoryRecoveryOperationMessage = string.Empty;
                repositoryRecoveryOperationPercent = null;
            }
            UpdateRepositoryRecoverySurface();
        }

        private void UpdateRepositoryRecoverySurface()
        {
            RepositoryRecoveryStatus status = repositoryRecoveryStatus ??
                RepositoryRecoveryStatus.None();
            bool visible = repositoryRecoveryInProgress || status.Exists;
            bool managerAvailable = RepositoryRecoveryManagerAvailable();
            bool conflict = RepositoryRecoveryHasConflictingOperation();
            bool canRepair = visible &&
                !repositoryRecoveryInProgress &&
                status.Exists &&
                status.IsRecoverable &&
                managerAvailable &&
                !previewEnabled &&
                !conflict;

            string message = status.Exists
                ? status.Message
                : "Protected repository recovery is completing.";
            string state;
            if (repositoryRecoveryInProgress)
            {
                state = string.IsNullOrWhiteSpace(repositoryRecoveryOperationMessage)
                    ? "Repairing the interrupted repository move..."
                    : repositoryRecoveryOperationMessage;
            }
            else if (!status.IsRecoverable)
            {
                state = string.IsNullOrWhiteSpace(repositoryRecoveryOperationMessage)
                    ? "Automatic and manual backups remain blocked. Repair the protected installation before continuing."
                    : repositoryRecoveryOperationMessage;
            }
            else if (!managerAvailable)
            {
                state = "The protected repository recovery helper is unavailable. Backups remain blocked.";
            }
            else if (previewEnabled)
            {
                state = "Stop the dashboard preview before starting protected recovery.";
            }
            else if (conflict)
            {
                state = "Wait for the current protected operation to finish, then repair the interrupted move.";
            }
            else if (!string.IsNullOrWhiteSpace(repositoryRecoveryOperationMessage))
            {
                state = repositoryRecoveryOperationMessage;
            }
            else
            {
                state = "Ready to repair. Windows approval is required; no backup will start.";
            }

            string label = repositoryRecoveryInProgress
                ? "Repairing..."
                : status.IsRecoverable
                    ? "Repair interrupted move"
                    : "Repair unavailable";
            string helpText = canRepair
                ? "Validate and repair the protected interrupted-move journal. No backup starts and no snapshot is deleted."
                : state;

            ApplyRepositoryRecoverySurface(
                protectionRepositoryRecoveryCard,
                protectionRepositoryRecoveryMessage,
                protectionRepositoryRecoveryState,
                protectionRepositoryRecoveryButton,
                protectionRepositoryRecoveryProgress,
                visible,
                message,
                state,
                label,
                helpText,
                canRepair);
            ApplyRepositoryRecoverySurface(
                settingsRepositoryRecoveryCard,
                settingsRepositoryRecoveryMessage,
                settingsRepositoryRecoveryState,
                settingsRepositoryRecoveryButton,
                settingsRepositoryRecoveryProgress,
                visible,
                message,
                state,
                label,
                helpText,
                canRepair);

            string announcement = visible ? message + " " + state : string.Empty;
            if (!string.Equals(
                announcement,
                lastRepositoryRecoveryAnnouncement,
                StringComparison.Ordinal))
            {
                lastRepositoryRecoveryAnnouncement = announcement;
                TextBlock announcementTarget = protectionRepositoryRecoveryState ??
                    settingsRepositoryRecoveryState;
                if (announcementTarget != null && visible)
                {
                    AutomationPeer peer = UIElementAutomationPeer.FromElement(announcementTarget) ??
                        UIElementAutomationPeer.CreatePeerForElement(announcementTarget);
                    if (peer != null)
                    {
                        peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
                    }
                }
            }
        }

        private void ApplyRepositoryRecoverySurface(
            Border card,
            TextBlock messageBlock,
            TextBlock stateBlock,
            Button repairButton,
            ProgressBar progress,
            bool visible,
            string message,
            string state,
            string label,
            string helpText,
            bool canRepair)
        {
            if (card == null)
            {
                return;
            }
            card.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            if (!visible)
            {
                return;
            }
            messageBlock.Text = message;
            stateBlock.Text = state;
            stateBlock.Foreground = repositoryRecoveryInProgress
                ? BlueText
                : repositoryRecoveryStatus != null && !repositoryRecoveryStatus.IsRecoverable
                    ? Rose
                    : PrimaryText;
            repairButton.Content = label;
            repairButton.IsEnabled = canRepair;
            repairButton.ToolTip = helpText;
            AutomationProperties.SetName(repairButton, label);
            AutomationProperties.SetHelpText(repairButton, helpText);
            AutomationProperties.SetItemStatus(repairButton, helpText);
            progress.Visibility = repositoryRecoveryInProgress
                ? Visibility.Visible
                : Visibility.Collapsed;
            progress.IsIndeterminate = !repositoryRecoveryOperationPercent.HasValue;
            if (repositoryRecoveryOperationPercent.HasValue)
            {
                progress.Value = Math.Max(
                    progress.Minimum,
                    Math.Min(progress.Maximum, repositoryRecoveryOperationPercent.Value));
                AutomationProperties.SetName(
                    progress,
                    "Repository recovery progress " +
                        progress.Value.ToString("0", CultureInfo.CurrentCulture) + " percent");
            }
            else
            {
                AutomationProperties.SetName(progress, "Repository recovery in progress");
            }
            AutomationProperties.SetName(
                card,
                "Action required. Backups paused. " + message + " " + state);
            AutomationProperties.SetHelpText(card, helpText);
        }

        private void SetRepositoryRecoveryOperationStatus(
            string message,
            double? percent)
        {
            repositoryRecoveryOperationMessage = message ?? string.Empty;
            repositoryRecoveryOperationPercent = percent;
            UpdateRepositoryRecoverySurface();
            PublishWebPresentationState();
        }

        private void ApplyRepositoryRecoveryProgress(RepositoryProgress progress)
        {
            if (!repositoryRecoveryInProgress || progress == null)
            {
                return;
            }
            string message = string.IsNullOrWhiteSpace(progress.Message)
                ? "Repairing protected repository state..."
                : progress.Message;
            if (progress.Percent.HasValue)
            {
                message += "  " + progress.Percent.Value.ToString("0", CultureInfo.CurrentCulture) + "%";
            }
            SetRepositoryRecoveryOperationStatus(message, progress.Percent);
        }

        // An explicit refresh (startup, F5, after an action): loads and applies inline so the caller sees
        // the new state immediately. The periodic tick loads in the background and applies the same way.
        private void RefreshDashboard()
        {
            refreshGeneration++;
            RefreshRepositoryRecoveryStatus();
            // A schedule that could not be read is read again on request, not after the usual 30 seconds, so that
            // "Check again" on the page does what it says.
            RefreshSchedule(currentTaskSchedule == null);
            TelemetrySnapshot snapshot = null;
            Exception loadFailure = null;
            try
            {
                snapshot = reader.Load();
            }
            catch (Exception error)
            {
                loadFailure = error;
            }
            ApplyTelemetryRefresh(snapshot, loadFailure);
        }

        private void ApplyTelemetryRefresh(TelemetrySnapshot snapshot, Exception loadFailure)
        {
            if (loadFailure != null)
            {
                ShowTelemetryUnavailable(loadFailure);
                UpdateTrayText(null);
            }
            else
            {
                try
                {
                    webTelemetryError = null;
                    lastSnapshot = snapshot;
                    ApplySnapshot(snapshot);
                    if (previewEnabled)
                    {
                        ApplyPreview(snapshot);
                    }
                    HandleStateTransition(snapshot);
                    UpdateTrayText(snapshot);
                }
                catch (Exception error)
                {
                    ShowTelemetryUnavailable(error);
                    UpdateTrayText(null);
                }
            }
            RefreshSources(false);
            PublishWebPresentationState();
        }

        private void ShowTelemetryUnavailable(Exception error)
        {
            heroTitle.Text = "Dashboard data is temporarily unavailable";
            webTelemetryError = error.Message;
            heroDetail.Text = error.Message;
            SetBadge("DATA RETRY", Amber, BrushFrom("#3A2F18"));
            lastUpdated.Text = "Retrying automatically";
        }

        private void RefreshSchedule(bool force)
        {
            if (scheduleOperationInProgress)
            {
                return;
            }
            if (!force && DateTime.UtcNow < nextScheduleRefreshUtc)
            {
                return;
            }
            if (!scheduleReadSeeded)
            {
                // The first read stays inline so the first frame already has real schedule data. Reading
                // in the background would briefly report "Schedule unavailable" (and announce it) at startup.
                scheduleReadSeeded = true;
                scheduleReadGeneration++;
                nextScheduleRefreshUtc = DateTime.UtcNow.AddSeconds(
                    cancellationAwaitingTerminal ? 1 : 30);
                ApplyScheduleReadResult(TaskScheduleReader.ReadInstalled());
                return;
            }
            if (scheduleReadInFlight)
            {
                return;
            }
            nextScheduleRefreshUtc = DateTime.UtcNow.AddSeconds(
                cancellationAwaitingTerminal ? 1 : 30);
            BeginScheduleRead();
        }

        private async void BeginScheduleRead()
        {
            scheduleReadInFlight = true;
            int generation = scheduleReadGeneration;
            TaskScheduleReadResult result;
            try
            {
                result = await Task.Run(delegate { return TaskScheduleReader.ReadInstalled(); });
            }
            catch (Exception error)
            {
                result = TaskScheduleReadResult.Failure(error.Message);
            }
            finally
            {
                scheduleReadInFlight = false;
            }
            if (generation != scheduleReadGeneration || scheduleOperationInProgress)
            {
                // A forced read or a schedule edit started after this one, so its result is the fresher one.
                return;
            }
            ApplyScheduleReadResult(result);
        }

        // For handlers that must act on a schedule read they just made. Reads off the UI thread and
        // supersedes any background read still in flight; the caller applies the result.
        private async Task<TaskScheduleReadResult> ReadScheduleOffUiThreadAsync()
        {
            scheduleReadGeneration++;
            try
            {
                return await Task.Run(delegate { return TaskScheduleReader.ReadInstalled(); });
            }
            catch (Exception error)
            {
                return TaskScheduleReadResult.Failure(error.Message);
            }
        }

        private void ApplyScheduleReadResult(TaskScheduleReadResult result)
        {
            if (result.Succeeded && result.Schedule != null)
            {
                SetCurrentTaskSchedule(result.Schedule);
                scheduleReadError = string.Empty;
                if (scheduleActionStatus != null)
                {
                    scheduleActionStatus.Text = result.Schedule.Enabled
                        ? "Installed: " + result.Schedule.Summary
                        : "Automatic backups paused";
                    scheduleActionStatus.Foreground = result.Schedule.Enabled ? MutedText : Amber;
                }
            }
            else
            {
                currentTaskSchedule = null;
                scheduleReadError = result.ErrorMessage ?? "The installed schedule could not be verified.";
                if (scheduleActionStatus != null)
                {
                    scheduleActionStatus.Text = "Schedule unavailable";
                    scheduleActionStatus.Foreground = Rose;
                    AutomationProperties.SetHelpText(scheduleActionStatus, scheduleReadError);
                }
            }
            UpdateHeaderSubtitle();
            UpdateScheduleButton();
            PublishWebPresentationState();
        }

        // Every change to the schedule the dashboard shows goes through here, so a change to when the backup runs is noticed
        // whether it was made in Rewindle or in Windows' Task Scheduler while Rewindle was open.
        private void SetCurrentTaskSchedule(TaskSchedule schedule)
        {
            NoteScheduleReplaced(currentTaskSchedule, schedule);
            currentTaskSchedule = schedule;
        }

        // Moving the backup's run times leaves the new schedule with slots earlier today (and on earlier days) that the task never
        // had: set the time to 18:00 at 21:00 and there was never going to be an 18:00 run today, but the freshness check would
        // call that slot missed until tomorrow's. When backups were current just before the change, they are taken to have been
        // current as of it, so those slots are not held against them, while the first slot after the change still has to be
        // met. A schedule that was already overdue, paused or unread gets no such allowance, nor does the first one read after
        // the app starts: a backup that fell behind is still reported as behind.
        private void NoteScheduleReplaced(TaskSchedule previous, TaskSchedule replacement)
        {
            if (previous == null || replacement == null ||
                BackupFreshnessEvaluator.SameRunTimes(previous, replacement))
            {
                return;
            }
            TelemetrySnapshot snapshot = lastSnapshot;
            if (snapshot == null || !snapshot.LastVerifiedFinishedUtc.HasValue)
            {
                return;
            }
            BackupFreshnessResult before = BackupFreshnessEvaluator.EvaluateNow(
                previous,
                snapshot.LastVerifiedFinishedUtc,
                scheduleCoveredThroughUtc);
            if (before.State == BackupFreshnessState.Healthy)
            {
                scheduleCoveredThroughUtc = DateTime.UtcNow;
            }
        }

        private void UpdateHeaderSubtitle()
        {
            if (headerSubtitle == null)
            {
                return;
            }
            int userSourceCount = currentSourceConfiguration == null
                ? 0
                : currentSourceConfiguration.Sources.Count(source => !source.IsProtectedCanary);
            bool hasCanarySource = currentSourceConfiguration != null &&
                currentSourceConfiguration.Sources.Any(source => source.IsProtectedCanary);
            string scope = currentSourceConfiguration == null
                ? "Loading backup scope"
                : userSourceCount.ToString(CultureInfo.CurrentCulture) +
                    (userSourceCount == 1 ? " protected folder" : " protected folders") +
                    (hasCanarySource ? " + restore canary" : " (restore canary missing)");
            string schedule = currentTaskSchedule == null
                ? "Schedule unavailable"
                : currentTaskSchedule.Summary;
            string repository = currentSourceConfiguration == null
                ? "Loading location"
                : currentSourceConfiguration.RepositoryPath;
            headerSubtitle.Text = scope + "  \u2022  " + repository + "  \u2022  " + schedule;
            if (repositoryValue != null)
            {
                repositoryValue.Text = repository;
                repositoryValue.ToolTip = currentSourceConfiguration == null
                    ? null
                    : currentSourceConfiguration.RepositoryPath;
                AutomationProperties.SetName(repositoryValue, "Backup location " + repository);
            }
            if (settingsRepositoryValue != null)
            {
                settingsRepositoryValue.Text = repository;
                settingsRepositoryValue.ToolTip = currentSourceConfiguration == null
                    ? null
                    : currentSourceConfiguration.RepositoryPath;
                AutomationProperties.SetName(
                    settingsRepositoryValue,
                    "Current backup location " + repository);
            }
            if (settingsRepositoryVolume != null)
            {
                settingsRepositoryVolume.Text = currentSourceConfiguration == null
                    ? "Storage volume unavailable"
                    : GetRepositoryVolumeText(currentSourceConfiguration.RepositoryPath);
            }
            UpdateRepositoryButtons();
        }

        // The last probed volume summary. The probe itself runs off the UI thread and refreshes the
        // header when it finishes; the UI thread never touches the drive.
        private string GetRepositoryVolumeText(string repositoryPath)
        {
            string path = repositoryPath ?? string.Empty;
            if (!string.Equals(path, repositoryVolumePath, StringComparison.OrdinalIgnoreCase))
            {
                repositoryVolumePath = path;
                repositoryVolumeText = "Checking storage volume\u2026";
                repositoryVolumeReady = true;
                repositoryVolumeCheckedUtc = DateTime.MinValue;
            }
            if (!repositoryVolumeProbeInFlight &&
                DateTime.UtcNow - repositoryVolumeCheckedUtc >= RepositoryVolumeRefreshInterval)
            {
                ProbeRepositoryVolumeAsync(path);
            }
            return repositoryVolumeText;
        }

        private async void ProbeRepositoryVolumeAsync(string repositoryPath)
        {
            repositoryVolumeProbeInFlight = true;
            string text;
            bool ready = true;
            try
            {
                Tuple<string, bool> probed = await Task.Run(delegate
                {
                    bool driveReady;
                    string described = DescribeRepositoryVolume(repositoryPath, out driveReady);
                    return Tuple.Create(described, driveReady);
                });
                text = probed.Item1;
                ready = probed.Item2;
            }
            catch
            {
                text = "Storage volume unavailable";
            }
            finally
            {
                repositoryVolumeProbeInFlight = false;
            }
            if (!string.Equals(repositoryPath, repositoryVolumePath, StringComparison.OrdinalIgnoreCase))
            {
                // The repository moved while this probed; the next header update probes the new path.
                return;
            }
            repositoryVolumeCheckedUtc = DateTime.UtcNow;
            if (string.Equals(text, repositoryVolumeText, StringComparison.Ordinal) &&
                ready == repositoryVolumeReady)
            {
                return;
            }
            repositoryVolumeText = text;
            repositoryVolumeReady = ready;
            UpdateHeaderSubtitle();
            PublishWebPresentationState();
        }

        // `ready` is false only for a drive that answered that it is not ready; every other failure to describe the volume
        // leaves it true, because it is not known that the storage is gone.
        private static string DescribeRepositoryVolume(string repositoryPath, out bool ready)
        {
            ready = true;
            try
            {
                string root = System.IO.Path.GetPathRoot(repositoryPath);
                if (string.IsNullOrWhiteSpace(root))
                {
                    return "Storage volume unavailable";
                }
                DriveInfo drive = new DriveInfo(root);
                if (!drive.IsReady)
                {
                    ready = false;
                    return root + "  •  Volume unavailable";
                }
                string label = string.IsNullOrWhiteSpace(drive.VolumeLabel)
                    ? DescribeDriveType(drive.DriveType)
                    : drive.VolumeLabel;
                return root + "  •  " + label + "  •  " +
                    FormatStorageBytes(drive.AvailableFreeSpace) + " free";
            }
            catch
            {
                return "Storage volume unavailable";
            }
        }

        private static string DescribeDriveType(DriveType type)
        {
            switch (type)
            {
                case DriveType.Fixed: return "Local disk";
                case DriveType.Removable: return "Removable drive";
                case DriveType.Network: return "Network drive";
                default: return type.ToString();
            }
        }

        private static string FormatStorageBytes(long value)
        {
            string[] units = { "B", "KiB", "MiB", "GiB", "TiB" };
            double amount = Math.Max(0, value);
            int unit = 0;
            while (amount >= 1024 && unit < units.Length - 1)
            {
                amount /= 1024;
                unit++;
            }
            return amount.ToString(unit == 0 ? "N0" : "N1", CultureInfo.CurrentCulture) +
                " " + units[unit];
        }

        private void RefreshSources(bool force)
        {
            if (!sourceOperationInProgress &&
                sourceOperationStage != SourceOperationStage.Idle &&
                sourceOperationExpiresUtc != DateTime.MinValue &&
                sourceOperationExpiresUtc != DateTime.MaxValue &&
                DateTime.UtcNow >= sourceOperationExpiresUtc)
            {
                ResetSourceOperationState();
                force = true;
            }
            try
            {
                SourceConfiguration configuration = SourceConfiguration.Load();
                bool managerAvailable = File.Exists(configuration.ManagerPath);
                string signature = string.Join(
                    "\u001f",
                    configuration.Sources.Select(source =>
                        (source.IsProtectedCanary ? "canary:" : "user:") + source.SourcePath).ToArray()) +
                    "\u001fmanager:" + (managerAvailable ? "1" : "0");

                currentSourceConfiguration = configuration;
                sourceConfigurationEverLoaded = true;
                sourceInstallationMissing = false;
                sourceInstallationMissCount = 0;
                sourceConfigurationNote = string.Empty;
                if (force || !string.Equals(signature, sourceSignature, StringComparison.Ordinal))
                {
                    sourceSignature = signature;
                    RebuildSourceList(configuration, managerAvailable);
                }

                int userSources = configuration.Sources.Count(source => !source.IsProtectedCanary);
                bool hasCanarySource = configuration.Sources.Any(source => source.IsProtectedCanary);
                UpdateHeaderSubtitle();
                sourceSummary.Text = userSources.ToString(CultureInfo.CurrentCulture) +
                    (userSources == 1 ? " folder" : " folders") +
                    (hasCanarySource ? "  |  protected restore canary" : "  |  restore canary missing");
                sourceSummary.Foreground = hasCanarySource ? MutedText : Rose;

                if (sourceOperationStage != SourceOperationStage.Idle &&
                    sourceOperationStage != SourceOperationStage.Succeeded)
                {
                    sourceStatus.Text = "Folder changes are shown inline below. No backup has started.";
                    sourceStatus.Foreground = MutedText;
                }
                else if (DateTime.UtcNow >= sourceNoticeExpiresUtc)
                {
                    if (!hasCanarySource)
                    {
                        sourceStatus.Text = "The required restore test file is missing; backups cannot be verified.";
                        sourceStatus.Foreground = Rose;
                    }
                    else if (!managerAvailable)
                    {
                        sourceStatus.Text = "Folder management is unavailable because the protected manager is missing.";
                        sourceStatus.Foreground = Rose;
                    }
                    else
                    {
                        sourceStatus.Text = "Windows approval is required to change protected folders.";
                        sourceStatus.Foreground = MutedText;
                    }
                }
            }
            catch (Exception error)
            {
                currentSourceConfiguration = null;
                sourceSignature = null;
                // Nothing installed is a first run, not a fault, and is told apart from a configuration that is there and cannot
                // be used. The sentence is fixed wording (see DescribeSourceConfigurationProblem), never the exception's own.
                bool notInstalled = error is BackupInstallationMissingException;
                sourceInstallationMissCount = notInstalled ? sourceInstallationMissCount + 1 : 0;
                sourceInstallationMissing = notInstalled &&
                    (!sourceConfigurationEverLoaded || sourceInstallationMissCount >= MissingInstallationRefreshes);
                sourceConfigurationNote = DescribeSourceConfigurationProblem(error);
                removeSourceButtons.Clear();
                sourceList.Children.Clear();
                TextBlock unavailable = new TextBlock();
                unavailable.Text = notInstalled
                    ? "Protected folders appear here once Rewindle finds an installed backup engine."
                    : "Protected folders are temporarily unavailable.";
                unavailable.FontSize = 12;
                unavailable.Foreground = notInstalled ? MutedText : Rose;
                unavailable.Margin = new Thickness(12, 14, 12, 14);
                sourceList.Children.Add(unavailable);
                sourceSummary.Text = notInstalled
                    ? "Engine not installed"
                    : "Protected configuration unavailable";
                if (DateTime.UtcNow >= sourceNoticeExpiresUtc)
                {
                    sourceStatus.Text = sourceConfigurationNote;
                    sourceStatus.Foreground = notInstalled ? MutedText : Rose;
                }
            }
            UpdateSourceButtons();
            UpdateActivityActions();
            UpdateRestoreReadiness();
            UpdateHeaderSubtitle();
            PublishWebPresentationState();
        }

        // What went wrong with the installed configuration, as one fixed sentence for the page and for a disabled control to give. It
        // never carries the exception's own words, which can name a path. The validation messages that SourceConfiguration.Load
        // writes itself (an invalid repository path, a duplicate source) hold none, so those are kept as they are.
        private static string DescribeSourceConfigurationProblem(Exception error)
        {
            if (error is BackupInstallationMissingException)
            {
                return "Engine not installed: Rewindle did not find the backup engine it reports on. Install or repair it, " +
                    "then refresh (see Requirements in the README).";
            }
            if (error is UnauthorizedAccessException)
            {
                return "Windows did not let Rewindle read the backup configuration (access denied).";
            }
            if (error is InvalidDataException)
            {
                return error.Message;
            }
            return "The backup configuration could not be read just now. Rewindle tries again every second.";
        }

        private void UpdateRestoreReadiness()
        {
            if (restoreReadinessTitle == null || restoreReadinessDetail == null ||
                openRestoreCenterButton == null || checkRecoveryReadinessButton == null)
            {
                return;
            }
            bool managerAvailable = currentSourceConfiguration != null &&
                File.Exists(System.IO.Path.Combine(
                    currentSourceConfiguration.InstallRoot,
                    EngineProfile.Current.RestoreManagerFileName)) &&
                File.Exists(System.IO.Path.Combine(
                    currentSourceConfiguration.InstallRoot,
                    "restore.py"));
            bool hasCanary = currentSourceConfiguration != null &&
                currentSourceConfiguration.Sources.Any(source => source.IsProtectedCanary);
            bool healthAvailable = currentSourceConfiguration != null &&
                File.Exists(System.IO.Path.Combine(
                    currentSourceConfiguration.InstallRoot,
                    "recovery_health.py"));
            bool blocked = BackupBlocksSourceChanges() || repositoryOperationInProgress ||
                repositoryRecoveryInProgress || repositoryRecoveryStatus.Exists;
            bool ready = managerAvailable && hasCanary && !blocked;
            openRestoreCenterButton.IsEnabled = ready;
            checkRecoveryReadinessButton.IsEnabled = healthAvailable && !blocked;
            if (currentSourceConfiguration == null)
            {
                restoreReadinessTitle.Text = "Protected configuration unavailable";
                restoreReadinessDetail.Text = "Repair or refresh the protected installation before browsing snapshots.";
                restoreReadinessTitle.Foreground = Rose;
            }
            else if (!managerAvailable)
            {
                restoreReadinessTitle.Text = "Restore Center is not installed";
                restoreReadinessDetail.Text = "The protected restore manager or backend is missing from the runtime manifest.";
                restoreReadinessTitle.Foreground = Rose;
            }
            else if (!hasCanary)
            {
                restoreReadinessTitle.Text = "Restore test file is missing";
                restoreReadinessDetail.Text = "A restore test file is required before app-guided recovery is trusted.";
                restoreReadinessTitle.Foreground = Rose;
            }
            else if (repositoryRecoveryStatus.Exists)
            {
                restoreReadinessTitle.Text = "Repair the interrupted repository move first";
                restoreReadinessDetail.Text = repositoryRecoveryStatus.Message;
                restoreReadinessTitle.Foreground = Amber;
            }
            else if (blocked)
            {
                restoreReadinessTitle.Text = "Restore access is temporarily paused";
                restoreReadinessDetail.Text = "Wait for the active backup or protected configuration change to finish.";
                restoreReadinessTitle.Foreground = Amber;
            }
            else
            {
                restoreReadinessTitle.Text = "Restore Center ready";
                restoreReadinessDetail.Text = "Plan " +
                    currentSourceConfiguration.PlanId.Substring(0, 8) + " · generation " +
                    currentSourceConfiguration.ConfigGeneration.ToString(CultureInfo.CurrentCulture) +
                    " · " + currentSourceConfiguration.RepositoryPath;
                restoreReadinessTitle.Foreground = Green;
            }
            AutomationProperties.SetHelpText(
                openRestoreCenterButton,
                ready
                    ? "Browse snapshots and restore to a separate destination. Windows approval is required."
                    : restoreReadinessDetail.Text);
            AutomationProperties.SetHelpText(
                checkRecoveryReadinessButton,
                checkRecoveryReadinessButton.IsEnabled
                    ? "Run read-only independent repository and recovery checks."
                    : restoreReadinessDetail.Text);
        }

        private void OnCheckRecoveryReadinessClick(object sender, RoutedEventArgs args)
        {
            UpdateRestoreReadiness();
            if (checkRecoveryReadinessButton == null || !checkRecoveryReadinessButton.IsEnabled)
            {
                return;
            }
            try
            {
                SourceConfiguration configuration = SourceConfiguration.Load();
                RecoveryReadinessWindow window = new RecoveryReadinessWindow(
                    configuration,
                    themeResolution.Palette);
                window.Owner = this;
                window.ShowDialog();
                RefreshDashboard();
            }
            catch (Exception error)
            {
                MessageBox.Show(
                    this,
                    "Recovery readiness could not open.\n\n" + error.Message,
                    "Recovery readiness unavailable",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        private void OnOpenRestoreCenterClick(object sender, RoutedEventArgs args)
        {
            UpdateRestoreReadiness();
            if (openRestoreCenterButton == null || !openRestoreCenterButton.IsEnabled)
            {
                return;
            }
            try
            {
                SourceConfiguration configuration = SourceConfiguration.Load();
                RestoreWindow window = new RestoreWindow(configuration, themeResolution.Palette);
                window.Owner = this;
                window.ShowDialog();
                RefreshDashboard();
            }
            catch (Exception error)
            {
                MessageBox.Show(
                    this,
                    "The Restore Center could not open.\n\n" + error.Message,
                    "Restore Center unavailable",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        private void RebuildSourceList(SourceConfiguration configuration, bool managerAvailable)
        {
            StopSourceOperationAnimation();
            sourceList.Children.Clear();
            removeSourceButtons.Clear();
            sourceRows.Clear();
            ResetSourceOperationVisualReferences();
            bool showPendingItem = ShouldShowPendingSourceItem(configuration);
            bool pendingInserted = false;
            for (int index = 0; index < configuration.Sources.Count; index++)
            {
                BackupSourceView source = configuration.Sources[index];
                FrameworkElement row = (FrameworkElement)BuildSourceRow(source, index, managerAvailable);
                FrameworkElement displayedRow = row;
                if (sourceOperationStage == SourceOperationStage.Succeeded &&
                    string.Equals(source.SourcePath, sourceOperationPath, StringComparison.OrdinalIgnoreCase))
                {
                    displayedRow = BuildResolvedSourceRow(row, source);
                }
                sourceRows[source.SourcePath] = displayedRow;
                sourceList.Children.Add(displayedRow);
                if (showPendingItem && source.IsProtectedCanary)
                {
                    sourceList.Children.Add(BuildSourceOperationItem());
                    pendingInserted = true;
                }
            }
            if (showPendingItem && !pendingInserted)
            {
                sourceList.Children.Insert(0, BuildSourceOperationItem());
            }
        }

        private void UpdateSourceButtons()
        {
            bool managerAvailable = currentSourceConfiguration != null &&
                File.Exists(currentSourceConfiguration.ManagerPath);
            bool backupConflict = scheduleOperationInProgress ||
                repositoryOperationInProgress ||
                RepositoryRecoveryBlocksMutations() ||
                CancellationBlocksMutations(lastSnapshot) ||
                anomalyReviewInProgress ||
                backupStartInProgress ||
                DateTime.UtcNow < backupRequestPendingUntilUtc ||
                (lastSnapshot != null && lastSnapshot.IsActive);
            if (addSourceButton != null)
            {
                addSourceButton.IsEnabled = !sourceOperationInProgress && !backupConflict && managerAvailable;
                // Say why the button is off; the dashboard shows this text where the button is.
                string addSourceHelp = currentSourceConfiguration == null && !string.IsNullOrEmpty(sourceConfigurationNote)
                    ? sourceConfigurationNote
                    : !managerAvailable
                        ? "Folder management is unavailable because the protected manager is missing."
                        : sourceOperationInProgress
                            ? "Wait for the current folder change to finish."
                            : backupConflict
                                ? "Folder changes unlock when the current backup or protected operation finishes."
                                : "Choose a folder to include in future backups. Windows will ask for approval.";
                addSourceButton.ToolTip = addSourceHelp;
                AutomationProperties.SetItemStatus(addSourceButton, addSourceHelp);
            }
            foreach (Button removeButton in removeSourceButtons)
            {
                BackupSourceView source = removeButton.Tag as BackupSourceView;
                removeButton.IsEnabled = !sourceOperationInProgress &&
                    !backupConflict &&
                    managerAvailable &&
                    source != null &&
                    !source.IsProtectedCanary;
            }
            UpdateBackupButton(lastSnapshot);
            UpdateCancelButton(lastSnapshot);
            UpdateAnomalyReviewButton(lastSnapshot);
            UpdateScheduleButton();
            UpdateRepositoryButtons();
            UpdateRepositoryRecoverySurface();
        }

        private void UpdateBackupButton(TelemetrySnapshot snapshot)
        {
            if (backupNowButton == null)
            {
                return;
            }

            string label;
            string helpText;
            bool enabled = false;
            bool hasCanary = currentSourceConfiguration != null &&
                currentSourceConfiguration.Sources.Any(source => source.IsProtectedCanary);
            bool pending = DateTime.UtcNow < backupRequestPendingUntilUtc;
            if (pending && HasNewerBackupTelemetry(snapshot))
            {
                backupRequestPendingUntilUtc = DateTime.MinValue;
                backupRequestBaselineRunId = string.Empty;
                pending = false;
            }
            else if (!pending && backupRequestPendingUntilUtc != DateTime.MinValue)
            {
                // The wait is over. Say once that nothing started, but only when the status is readable and shows no
                // run since the request: an unreadable status says nothing either way. It is worded as a possibility,
                // because the request was accepted and Windows does not say why a task did not start.
                if (snapshot != null && !snapshot.IsActive && !snapshot.IsStatusUnavailable &&
                    string.IsNullOrEmpty(webTelemetryError) && !HasNewerBackupTelemetry(snapshot))
                {
                    backupNotStartedText = BackupNotStartedNotice;
                    backupNotStartedBaselineRunId = backupRequestBaselineRunId;
                    ShowTrayMessage(
                        "Backup has not started",
                        BackupNotStartedNotice,
                        Forms.ToolTipIcon.Warning);
                }
                backupRequestPendingUntilUtc = DateTime.MinValue;
                backupRequestBaselineRunId = string.Empty;
            }
            // A run that appeared since (this one, or a scheduled one) answers the note.
            if (!string.IsNullOrEmpty(backupNotStartedText) && snapshot != null &&
                (snapshot.IsActive ||
                    (!string.IsNullOrWhiteSpace(snapshot.RunId) &&
                    !string.Equals(
                        snapshot.RunId,
                        backupNotStartedBaselineRunId,
                        StringComparison.OrdinalIgnoreCase))))
            {
                backupNotStartedText = string.Empty;
                backupNotStartedBaselineRunId = string.Empty;
            }

            if (previewEnabled)
            {
                label = "Stop preview first";
                helpText = "Stop the telemetry preview before starting a real backup.";
            }
            else if (backupStartInProgress)
            {
                label = "Waiting for approval…";
                helpText = "Waiting for Windows approval to request the installed backup task.";
            }
            else if (anomalyReviewInProgress)
            {
                label = "Reviewing changes...";
                helpText = "Wait for the exact anomaly-review approval to finish before starting a backup.";
            }
            else if (CancellationBlocksMutations(snapshot))
            {
                label = "Stopping backup…";
                helpText = "The backup is stopping safely. Nothing is being force-closed.";
            }
            else if (snapshot != null && snapshot.IsActive)
            {
                backupRequestPendingUntilUtc = DateTime.MinValue;
                label = "Backup running";
                helpText = "A backup is already running.";
            }
            else if (pending)
            {
                label = "Request sent…";
                helpText = "Windows accepted the request. Waiting for protected backup telemetry.";
            }
            else if (RepositoryRecoveryBlocksMutations())
            {
                label = repositoryRecoveryInProgress
                    ? "Repairing storage…"
                    : "Backup paused";
                helpText = repositoryRecoveryInProgress
                    ? "Wait for protected repository recovery to finish."
                    : "Repair the interrupted repository move before starting another backup.";
            }
            else if (scheduleOperationInProgress)
            {
                label = "Schedule updating…";
                helpText = "Wait for the protected schedule change to be verified before starting a backup.";
            }
            else if (sourceOperationInProgress)
            {
                label = "Folders updating…";
                helpText = "Wait for the protected folder change to finish before starting a backup.";
            }
            else if (repositoryOperationInProgress)
            {
                label = "Location change open";
                helpText = "Finish or close the location change dialog before starting a backup.";
            }
            else if (currentSourceConfiguration == null)
            {
                // No installed configuration to work with (nothing is installed, or it cannot be read just now): say which, in the
                // words RefreshSources chose, rather than blaming a restore test file that nobody has looked for.
                label = "Backup unavailable";
                helpText = string.IsNullOrEmpty(sourceConfigurationNote)
                    ? "Rewindle is still reading the backup configuration."
                    : sourceConfigurationNote;
            }
            else if (!hasCanary)
            {
                label = "Backup unavailable";
                helpText = "The required restore test file must be present before a backup can be requested.";
            }
            else
            {
                label = "Back up now";
                helpText = "Start a backup now. Windows will ask for approval.";
                if (!string.IsNullOrEmpty(backupNotStartedText))
                {
                    helpText += " " + backupNotStartedText;
                }
                enabled = true;
            }

            backupNowButton.Content = label;
            backupNowButton.IsEnabled = enabled;
            backupNowButton.ToolTip = helpText;
            AutomationProperties.SetName(backupNowButton, label);
            AutomationProperties.SetHelpText(backupNowButton, helpText);
            AutomationProperties.SetItemStatus(backupNowButton, helpText);
            UpdateCancelButton(snapshot);
        }

        private bool CancellationBlocksMutations(TelemetrySnapshot snapshot)
        {
            return cancellationRequestInProgress ||
                cancellationAwaitingTerminal ||
                (snapshot != null && string.Equals(
                    snapshot.StateKey,
                    "cancelling",
                    StringComparison.OrdinalIgnoreCase));
        }

        private void UpdateCancelButton(TelemetrySnapshot snapshot)
        {
            if (cancelBackupButton == null)
            {
                return;
            }

            bool hasActiveRun = !previewEnabled &&
                snapshot != null &&
                snapshot.IsActive &&
                !string.IsNullOrWhiteSpace(snapshot.RunId);
            bool unavailableForRun = hasActiveRun && string.Equals(
                cancellationUnavailableRunId,
                snapshot.RunId,
                StringComparison.OrdinalIgnoreCase);
            bool taskRunning = currentTaskSchedule != null &&
                currentTaskSchedule.State == BackupTaskState.Running;
            string label;
            string helpText;
            bool enabled = false;

            if (cancellationRequestInProgress)
            {
                label = "Waiting for approval…";
                helpText = "Waiting for Windows approval to signal only the exact active backup run.";
            }
            else if (scheduleConfirmationInProgress && hasActiveRun)
            {
                label = "Checking task\u2026";
                helpText = "Confirming that the protected backup task is still running before asking it to stop.";
            }
            else if (cancellationAwaitingTerminal ||
                (snapshot != null && string.Equals(
                    snapshot.StateKey,
                    "cancelling",
                    StringComparison.OrdinalIgnoreCase)))
            {
                label = snapshot != null && snapshot.IsCancelled
                    ? "Checking final state…"
                    : "Stopping safely…";
                helpText = "The backup is stopping safely. Nothing is being force-closed.";
            }
            else if (hasActiveRun && unavailableForRun)
            {
                label = "Cancellation unavailable";
                helpText = "The stop request could not be delivered. The backup is still running.";
            }
            else if (hasActiveRun)
            {
                label = "Cancel backup";
                if (!taskRunning)
                {
                    helpText = "Waiting for Windows to confirm the backup has started.";
                }
                else if (sourceOperationInProgress || scheduleOperationInProgress ||
                    repositoryOperationInProgress || backupStartInProgress)
                {
                    helpText = "Wait for the current protected operation to finish before requesting cancellation.";
                }
                else
                {
                    helpText = "Ask the exact active Restic run to stop cooperatively. Existing verified snapshots are not changed.";
                    enabled = true;
                }
            }
            else
            {
                label = "Cancel backup";
                helpText = "Available while an exact protected backup run is active.";
            }

            cancelBackupButton.Visibility = Visibility.Visible;
            cancelBackupButton.Content = label;
            cancelBackupButton.IsEnabled = enabled;
            cancelBackupButton.ToolTip = helpText;
            bool stopping = cancellationRequestInProgress || cancellationAwaitingTerminal ||
                (snapshot != null && string.Equals(
                    snapshot.StateKey,
                    "cancelling",
                    StringComparison.OrdinalIgnoreCase));
            cancelBackupButton.Background = enabled ? Brushes.Transparent : CardSoftBrush;
            cancelBackupButton.BorderBrush = enabled ? Rose : stopping ? Amber : CardBorderBrush;
            cancelBackupButton.Foreground = enabled ? Rose : stopping ? Amber : MutedText;
            AutomationProperties.SetName(cancelBackupButton, label);
            AutomationProperties.SetHelpText(cancelBackupButton, helpText);
            AutomationProperties.SetItemStatus(cancelBackupButton, helpText);

            if (cancelActionStatus != null)
            {
                if (!string.IsNullOrWhiteSpace(cancellationNotice) &&
                    (cancellationNoticeExpiresUtc == DateTime.MaxValue ||
                        DateTime.UtcNow < cancellationNoticeExpiresUtc))
                {
                    cancelActionStatus.Text = cancellationNotice;
                    cancelActionStatus.Foreground = cancellationNoticeColor ?? MutedText;
                    cancelActionStatus.Visibility = Visibility.Visible;
                }
                else
                {
                    cancellationNotice = string.Empty;
                    cancellationNoticeExpiresUtc = DateTime.MinValue;
                    cancelActionStatus.Visibility = Visibility.Collapsed;
                }
            }
        }

        private void UpdateAnomalyReviewButton(TelemetrySnapshot snapshot)
        {
            if (reviewChangesButton == null)
            {
                return;
            }

            bool needsReview = snapshot != null && snapshot.NeedsAnomalyReview;
            bool helperAvailable = currentSourceConfiguration != null &&
                File.Exists(System.IO.Path.Combine(
                    currentSourceConfiguration.InstallRoot,
                    "anomaly_review.py")) &&
                File.Exists(System.IO.Path.Combine(
                    currentSourceConfiguration.StateDirectory,
                    "last-success.json"));
            bool conflict = previewEnabled || backupStartInProgress ||
                CancellationBlocksMutations(snapshot) ||
                sourceOperationInProgress || scheduleOperationInProgress ||
                repositoryOperationInProgress || RepositoryRecoveryBlocksMutations() ||
                (snapshot != null && snapshot.IsActive);
            bool enabled = needsReview && !anomalyReviewInProgress &&
                helperAvailable && !conflict;
            string label = anomalyReviewInProgress
                ? "Waiting for approval..."
                : "Review changes";
            string helpText;
            if (anomalyReviewInProgress)
            {
                helpText = "Windows is recording a plan-bound approval for this exact verified generation.";
            }
            else if (!helperAvailable)
            {
                helpText = "The protected anomaly-review helper or latest verified evidence is unavailable.";
            }
            else if (conflict)
            {
                helpText = "Wait for the current protected operation to finish before reviewing this generation.";
            }
            else
            {
                helpText = EngineProfile.Current.AnomalyReview.ButtonHelp;
            }

            reviewChangesButton.Visibility = needsReview || anomalyReviewInProgress
                ? Visibility.Visible
                : Visibility.Collapsed;
            reviewChangesButton.Content = label;
            reviewChangesButton.IsEnabled = enabled;
            reviewChangesButton.ToolTip = helpText;
            reviewChangesButton.Background = enabled
                ? BrushFrom("#3A2F18")
                : CardSoftBrush;
            reviewChangesButton.BorderBrush = enabled ? Amber : CardBorderBrush;
            reviewChangesButton.Foreground = enabled ? Amber : MutedText;
            AutomationProperties.SetName(reviewChangesButton, label);
            AutomationProperties.SetHelpText(reviewChangesButton, helpText);
            AutomationProperties.SetItemStatus(reviewChangesButton, helpText);
        }

        private async void OnReviewChangesClick(object sender, RoutedEventArgs args)
        {
            TelemetrySnapshot snapshot = lastSnapshot;
            UpdateAnomalyReviewButton(snapshot);
            if (anomalyReviewInProgress || snapshot == null ||
                !snapshot.NeedsAnomalyReview || currentSourceConfiguration == null ||
                !reviewChangesButton.IsEnabled)
            {
                return;
            }

            string snapshotShort = snapshot.SnapshotId.Length > 12
                ? snapshot.SnapshotId.Substring(0, 12)
                : snapshot.SnapshotId;
            string detail = string.IsNullOrWhiteSpace(snapshot.MaintenanceHoldDetail)
                ? "Restic detected an unusually large change set."
                : snapshot.MaintenanceHoldDetail;
            AnomalyReviewWording wording = EngineProfile.Current.AnomalyReview;
            MessageBoxResult confirmation = MessageBox.Show(
                this,
                wording.ConfirmQuestion + "\n\n" +
                    detail + "\n\n" +
                    "Run: " + snapshot.RunId + "\n" +
                    "Snapshot: " + snapshotShort + "\n\n" +
                    wording.ConfirmEffects + "\n\n" +
                    "Windows approval is required.",
                "Review suspicious backup changes",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);
            if (confirmation != MessageBoxResult.Yes)
            {
                return;
            }

            if (lastSnapshot == null || !lastSnapshot.NeedsAnomalyReview ||
                !string.Equals(lastSnapshot.RunId, snapshot.RunId, StringComparison.Ordinal) ||
                !string.Equals(
                    lastSnapshot.SnapshotId,
                    snapshot.SnapshotId,
                    StringComparison.Ordinal) ||
                currentSourceConfiguration == null)
            {
                RefreshDashboard();
                return;
            }

            SourceConfiguration configuration = currentSourceConfiguration;
            anomalyReviewInProgress = true;
            UpdateSourceButtons();
            AnomalyReviewResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return AnomalyReviewLauncher.AcknowledgeReview(
                        configuration,
                        snapshot,
                        delegate
                        {
                            Dispatcher.BeginInvoke(
                                new Action(delegate
                                {
                                    if (anomalyReviewInProgress && reviewChangesButton != null)
                                    {
                                        reviewChangesButton.Content = wording.RecordingLabel;
                                        AutomationProperties.SetName(
                                            reviewChangesButton,
                                            wording.RecordingName);
                                    }
                                }),
                                DispatcherPriority.Background);
                        });
                });
            }
            catch (Exception error)
            {
                result = AnomalyReviewResult.Failure(error.Message);
            }
            finally
            {
                anomalyReviewInProgress = false;
            }

            RefreshDashboard();
            UpdateSourceButtons();
            if (result.UserCancelled)
            {
                MessageBox.Show(
                    this,
                    wording.CancelledMessage,
                    "Review cancelled",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            else if (!result.Succeeded)
            {
                MessageBox.Show(
                    this,
                    result.ErrorMessage ??
                        wording.NotRecordedMessage,
                    wording.NotRecordedTitle,
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
            else
            {
                ShowTrayMessage(
                    wording.RecordedTitle,
                    wording.RecordedDetail,
                    Forms.ToolTipIcon.Info);
            }
        }

        private void SetCancellationStatus(
            string message,
            Brush foreground,
            int visibleSeconds)
        {
            cancellationNotice = message ?? string.Empty;
            cancellationNoticeColor = foreground ?? MutedText;
            cancellationNoticeExpiresUtc = visibleSeconds > 0
                ? DateTime.UtcNow.AddSeconds(visibleSeconds)
                : DateTime.MaxValue;
            if (cancelActionStatus == null)
            {
                return;
            }
            cancelActionStatus.Text = cancellationNotice;
            cancelActionStatus.Foreground = cancellationNoticeColor;
            cancelActionStatus.Visibility = string.IsNullOrWhiteSpace(cancellationNotice)
                ? Visibility.Collapsed
                : Visibility.Visible;
            AutomationProperties.SetName(cancelActionStatus, cancellationNotice);
            AutomationProperties.SetLiveSetting(
                cancelActionStatus,
                foreground == Rose
                    ? AutomationLiveSetting.Assertive
                    : AutomationLiveSetting.Polite);
            if (SourceMotionAllowed() &&
                cancelActionStatus.Visibility == Visibility.Visible)
            {
                DoubleAnimation reveal = new DoubleAnimation(0.35, 1, TimeSpan.FromMilliseconds(260));
                cancelActionStatus.BeginAnimation(UIElement.OpacityProperty, reveal);
            }
            AutomationPeer peer = UIElementAutomationPeer.CreatePeerForElement(cancelActionStatus);
            if (peer != null)
            {
                peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
            }
            PublishWebPresentationState();
        }

        private void ObserveCancellationState(TelemetrySnapshot snapshot)
        {
            // A status that cannot be read says nothing about the run (and has no run id, which would read as "the protected run
            // changed"), so the wait for its final state simply goes on.
            if (!cancellationAwaitingTerminal || snapshot == null || snapshot.IsStatusUnavailable)
            {
                return;
            }

            if (!string.Equals(
                snapshot.RunId,
                cancellationRequestedRunId,
                StringComparison.OrdinalIgnoreCase))
            {
                cancellationAwaitingTerminal = false;
                cancellationRequestedRunId = string.Empty;
                SetCancellationStatus(
                    "The protected run changed before cancellation could be independently confirmed.",
                    Rose,
                    18);
                return;
            }

            if (string.Equals(
                snapshot.CancelOutcome,
                "ctrl_break_signal_failed",
                StringComparison.OrdinalIgnoreCase) && snapshot.IsActive)
            {
                cancellationAwaitingTerminal = false;
                cancellationUnavailableRunId = snapshot.RunId;
                cancellationRequestedRunId = string.Empty;
                SetCancellationStatus(
                    "The safe stop signal could not be delivered. The backup is still running and was not hard-killed.",
                    Rose,
                    0);
                return;
            }

            if (string.Equals(
                snapshot.StateKey,
                "cancelling",
                StringComparison.OrdinalIgnoreCase))
            {
                SetCancellationStatus(
                    "Restic is stopping safely…",
                    Amber,
                    0);
                return;
            }

            if (snapshot.IsCancelled)
            {
                nextScheduleRefreshUtc = DateTime.MinValue;
                if (currentTaskSchedule == null ||
                    currentTaskSchedule.State == BackupTaskState.Running ||
                    currentTaskSchedule.State == BackupTaskState.Unknown)
                {
                    SetCancellationStatus(
                        "Restic stopped. Checking that the protected task and process tree have exited…",
                        BlueText,
                        0);
                    return;
                }

                cancellationAwaitingTerminal = false;
                cancellationRequestedRunId = string.Empty;
                SetCancellationStatus(
                    "Backup cancelled safely. Previously verified snapshots remain available.",
                    Green,
                    18);
                ShowTrayMessage(
                    "Backup cancelled safely",
                    "The active run stopped cooperatively. Previously verified snapshots remain available.",
                    Forms.ToolTipIcon.Info);
                return;
            }

            if (snapshot.IsSuccess)
            {
                cancellationAwaitingTerminal = false;
                cancellationRequestedRunId = string.Empty;
                SetCancellationStatus(
                    "The backup finished and was verified before cancellation took effect.",
                    Green,
                    18);
                return;
            }

            if (snapshot.IsFailure)
            {
                cancellationAwaitingTerminal = false;
                cancellationRequestedRunId = string.Empty;
                SetCancellationStatus(
                    "The run stopped with an error and was not marked successful. Review the protected log.",
                    Rose,
                    0);
                return;
            }

            SetCancellationStatus(
                "Cancellation was requested. Waiting for Restic and the protected task to report their final state…",
                Amber,
                0);
        }

        private async void OnCancelBackupClick(object sender, RoutedEventArgs args)
        {
            TelemetrySnapshot snapshot = lastSnapshot;
            if (scheduleConfirmationInProgress ||
                cancellationRequestInProgress || cancellationAwaitingTerminal ||
                previewEnabled || sourceOperationInProgress || scheduleOperationInProgress ||
                backupStartInProgress || snapshot == null || !snapshot.IsActive ||
                string.IsNullOrWhiteSpace(snapshot.RunId))
            {
                UpdateCancelButton(snapshot);
                return;
            }

            // Confirm the protected task is still Running with a fresh read, off the UI thread. The flag
            // stops a second click from starting a second confirmation while this one is waiting.
            TaskScheduleReadResult scheduleCheck;
            scheduleConfirmationInProgress = true;
            UpdateCancelButton(snapshot);
            PublishWebPresentationState();
            try
            {
                scheduleCheck = await ReadScheduleOffUiThreadAsync();
            }
            finally
            {
                scheduleConfirmationInProgress = false;
            }
            snapshot = lastSnapshot;
            if (scheduleOperationInProgress)
            {
                UpdateCancelButton(snapshot);
                return;
            }
            nextScheduleRefreshUtc = DateTime.UtcNow.AddSeconds(30);
            ApplyScheduleReadResult(scheduleCheck);
            if (currentTaskSchedule == null ||
                currentTaskSchedule.State != BackupTaskState.Running)
            {
                SetCancellationStatus(
                    "Cancellation was not requested because the protected task is no longer confirmed as Running.",
                    Amber,
                    12);
                UpdateCancelButton(snapshot);
                return;
            }

            MessageBoxResult confirmation = MessageBox.Show(
                this,
                "Cancel this backup?\n\n" +
                    "Restic will be asked to stop cleanly. Previously verified snapshots are not changed, " +
                    "and this run will not be marked successful. A run that is already completing may finish " +
                    "before cancellation takes effect.",
                "Cancel running backup?",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);
            if (confirmation != MessageBoxResult.Yes)
            {
                return;
            }

            snapshot = lastSnapshot;
            if (cancellationRequestInProgress || cancellationAwaitingTerminal ||
                snapshot == null || !snapshot.IsActive ||
                string.IsNullOrWhiteSpace(snapshot.RunId))
            {
                UpdateCancelButton(snapshot);
                return;
            }

            string runId = snapshot.RunId;
            cancellationRequestInProgress = true;
            cancellationRequestedRunId = runId;
            SetCancellationStatus("Waiting for Windows approval…", BlueText, 0);
            UpdateSourceButtons();

            BackupCancellationResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return BackupCancellationController.RequestCancel(
                        runId,
                        delegate
                        {
                            Dispatcher.BeginInvoke(
                                new Action(delegate
                                {
                                    SetCancellationStatus(
                                        "Sending a protected cancellation request…",
                                        BlueText,
                                        0);
                                    UpdateCancelButton(lastSnapshot);
                                }),
                                DispatcherPriority.Background);
                        });
                });
            }
            catch (Exception error)
            {
                result = BackupCancellationResult.Failure(error.Message, -1);
            }

            cancellationRequestInProgress = false;
            if (result.UserCancelled)
            {
                cancellationRequestedRunId = string.Empty;
                SetCancellationStatus(
                    "Backup kept running — Windows approval was cancelled.",
                    MutedText,
                    10);
            }
            else if (result.AlreadyFinished)
            {
                cancellationRequestedRunId = string.Empty;
                SetCancellationStatus(
                    "The backup finished before cancellation could be requested.",
                    Green,
                    12);
            }
            else if (result.Requested)
            {
                cancellationAwaitingTerminal = true;
                nextScheduleRefreshUtc = DateTime.MinValue;
                SetCancellationStatus(
                    "Restic is stopping safely…",
                    Amber,
                    0);
            }
            else
            {
                cancellationRequestedRunId = string.Empty;
                SetCancellationStatus(
                    "Safe cancellation was not requested. The backup is still running.",
                    Rose,
                    15);
                MessageBox.Show(
                    this,
                    "The cooperative cancellation request was rejected. The backup was not hard-stopped.\n\n" +
                        (result.ErrorMessage ?? "The protected cancellation helper did not return a verified result."),
                    "Cancellation not requested",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
            UpdateSourceButtons();
            PublishWebPresentationState();
        }

        private void UpdateScheduleButton()
        {
            if (editScheduleButton == null)
            {
                return;
            }
            bool backupConflict = backupStartInProgress || anomalyReviewInProgress ||
                CancellationBlocksMutations(lastSnapshot) ||
                DateTime.UtcNow < backupRequestPendingUntilUtc ||
                (lastSnapshot != null && lastSnapshot.IsActive);
            string helpText;
            if (scheduleOperationInProgress)
            {
                helpText = "The protected schedule change is still being applied and verified.";
            }
            else if (scheduleConfirmationInProgress)
            {
                helpText = "Reading the installed schedule before it is edited.";
            }
            else if (previewEnabled)
            {
                helpText = "Stop the telemetry preview before changing the automatic schedule.";
            }
            else if (backupConflict)
            {
                helpText = "Wait for the current backup to finish before changing its schedule.";
            }
            else if (sourceOperationInProgress)
            {
                helpText = "Wait for the protected folder change to finish before changing the schedule.";
            }
            else if (RepositoryRecoveryBlocksMutations())
            {
                helpText = repositoryRecoveryInProgress
                    ? "Wait for protected repository recovery to finish before changing the schedule."
                    : "Repair the interrupted repository move before changing the schedule.";
            }
            else if (repositoryOperationInProgress)
            {
                helpText = "Finish or close the location change dialog before changing the schedule.";
            }
            else if (currentTaskSchedule == null)
            {
                // What Windows reported stays available to the web page (schedule.error) and to assistive
                // technology on the status line; this sentence is what a disabled button says on screen.
                helpText = "Rewindle could not read the installed backup schedule. Refresh to try again.";
            }
            else
            {
                helpText = "Change the protected Windows backup schedule. Saving does not start a backup.";
            }
            editScheduleButton.Content = scheduleOperationInProgress
                ? "Updating schedule…"
                : scheduleConfirmationInProgress
                    ? "Checking schedule\u2026"
                    : "Edit schedule";
            editScheduleButton.IsEnabled = !scheduleOperationInProgress &&
                !scheduleConfirmationInProgress &&
                !previewEnabled &&
                !backupConflict &&
                !sourceOperationInProgress &&
                !repositoryOperationInProgress &&
                !RepositoryRecoveryBlocksMutations() &&
                currentTaskSchedule != null;
            editScheduleButton.ToolTip = helpText;
            AutomationProperties.SetHelpText(editScheduleButton, helpText);
            AutomationProperties.SetItemStatus(editScheduleButton, helpText);
        }

        // `tone` is how the web surface words the outcome ("info", "success", "warning" or "error"). It is passed
        // on purpose rather than read back from the brush: the palette hands out the current theme's brushes, so
        // comparing brush instances would misread a status that was set before a theme switch.
        private void SetScheduleStatus(string message, Brush foreground, string tone)
        {
            scheduleNoticeText = message ?? string.Empty;
            scheduleNoticeTone = tone ?? "info";
            scheduleNoticeExpiresUtc = DateTime.UtcNow.AddSeconds(ScheduleNoticeSeconds);
            if (scheduleActionStatus == null)
            {
                PublishWebPresentationState();
                return;
            }
            scheduleActionStatus.Text = message;
            scheduleActionStatus.Foreground = foreground ?? MutedText;
            AutomationProperties.SetName(scheduleActionStatus, message);
            AutomationPeer peer = UIElementAutomationPeer.CreatePeerForElement(scheduleActionStatus);
            if (peer != null)
            {
                peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
            }
            PublishWebPresentationState();
        }

        private void UpdateRepositoryButtons()
        {
            string label = repositoryRecoveryInProgress
                ? "Repairing…"
                : repositoryOperationInProgress
                    ? "Location change open"
                    : "Change location";
            bool managerAvailable = currentSourceConfiguration != null &&
                File.Exists(System.IO.Path.Combine(
                    currentSourceConfiguration.InstallRoot,
                    EngineProfile.Current.RepositoryManagerFileName));
            bool backupConflict = backupStartInProgress || anomalyReviewInProgress ||
                CancellationBlocksMutations(lastSnapshot) ||
                DateTime.UtcNow < backupRequestPendingUntilUtc ||
                (lastSnapshot != null && lastSnapshot.IsActive);
            bool enabled = !repositoryOperationInProgress &&
                !RepositoryRecoveryBlocksMutations() &&
                !previewEnabled &&
                !sourceOperationInProgress &&
                !scheduleOperationInProgress &&
                !backupConflict &&
                managerAvailable;
            string helpText;
            if (repositoryRecoveryInProgress)
            {
                helpText = "The protected interrupted-move recovery is still running.";
            }
            else if (repositoryOperationInProgress)
            {
                helpText = "Finish or close the location change dialog. Its progress shows whether copying has started.";
            }
            else if (RepositoryRecoveryBlocksMutations())
            {
                helpText = repositoryRecoveryInProgress
                    ? "Wait for protected repository recovery to finish before changing storage."
                    : "Repair the interrupted repository move before changing storage.";
            }
            else if (previewEnabled)
            {
                helpText = "Stop the telemetry preview before changing backup storage.";
            }
            else if (backupConflict)
            {
                helpText = "Wait for the current backup operation to finish before changing storage.";
            }
            else if (sourceOperationInProgress)
            {
                helpText = "Wait for the protected folder change to finish before changing storage.";
            }
            else if (scheduleOperationInProgress)
            {
                helpText = "Wait for the protected schedule change to finish before changing storage.";
            }
            else if (currentSourceConfiguration == null)
            {
                helpText = "The protected backup configuration is unavailable.";
            }
            else if (!managerAvailable)
            {
                helpText = "The protected repository manager is not installed.";
            }
            else
            {
                helpText = "Copy and verify the Restic repository in a new location. " +
                    "The old repository is retained and no backup starts.";
            }
            ApplyRepositoryButtonState(changeRepositoryButton, label, enabled, helpText);
            ApplyRepositoryButtonState(settingsChangeRepositoryButton, label, enabled, helpText);
        }

        private static void ApplyRepositoryButtonState(
            Button button,
            string label,
            bool enabled,
            string helpText)
        {
            if (button == null)
            {
                return;
            }
            button.Content = label;
            button.IsEnabled = enabled;
            button.ToolTip = helpText;
            AutomationProperties.SetHelpText(button, helpText);
            AutomationProperties.SetItemStatus(button, helpText);
        }

        private async void OnRepairRepositoryClick(object sender, RoutedEventArgs args)
        {
            RefreshRepositoryRecoveryStatus();
            if (repositoryRecoveryInProgress ||
                repositoryOperationInProgress ||
                repositoryRecoveryStatus == null ||
                !repositoryRecoveryStatus.Exists ||
                !repositoryRecoveryStatus.IsRecoverable ||
                !RepositoryRecoveryManagerAvailable() ||
                previewEnabled ||
                RepositoryRecoveryHasConflictingOperation())
            {
                UpdateRepositoryRecoverySurface();
                return;
            }

            MessageBoxResult confirmation = MessageBox.Show(
                this,
                "Repair the interrupted repository move now?\n\n" +
                    "The protected recovery helper will validate the journal and restore a verified safe " +
                    "repository and configuration state. Backups remain paused until the protected journal " +
                    "is removed. No backup starts and no snapshot is deleted.",
                "Repair interrupted repository move?",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);
            if (confirmation != MessageBoxResult.Yes)
            {
                return;
            }

            RefreshRepositoryRecoveryStatus();
            if (repositoryRecoveryStatus == null ||
                !repositoryRecoveryStatus.Exists ||
                !repositoryRecoveryStatus.IsRecoverable ||
                !RepositoryRecoveryManagerAvailable() ||
                previewEnabled ||
                RepositoryRecoveryHasConflictingOperation())
            {
                SetRepositoryRecoveryOperationStatus(
                    "Protected recovery was not started because the recovery state changed. Review this warning and try again.",
                    null);
                UpdateSourceButtons();
                return;
            }

            repositoryRecoveryInProgress = true;
            repositoryOperationInProgress = true;
            SetRepositoryRecoveryOperationStatus(
                "Waiting for Windows approval...",
                null);
            UpdateSourceButtons();

            RepositoryManagerResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return RepositoryManagerLauncher.Recover(
                        delegate
                        {
                            Dispatcher.BeginInvoke(
                                new Action(delegate
                                {
                                    if (repositoryRecoveryInProgress)
                                    {
                                        SetRepositoryRecoveryOperationStatus(
                                            "Protected repository recovery is running...",
                                            null);
                                    }
                                }),
                                DispatcherPriority.Background);
                        },
                        delegate(RepositoryProgress progress)
                        {
                            Dispatcher.BeginInvoke(
                                new Action(delegate
                                {
                                    ApplyRepositoryRecoveryProgress(progress);
                                }),
                                DispatcherPriority.Background);
                        });
                });
            }
            catch (Exception error)
            {
                result = RepositoryManagerResult.Failure(error.Message, -1);
            }
            finally
            {
                repositoryRecoveryInProgress = false;
                repositoryOperationInProgress = false;
                repositoryRecoveryOperationPercent = null;
            }

            RefreshRepositoryRecoveryStatus();
            bool journalCleared = repositoryRecoveryStatus != null &&
                !repositoryRecoveryStatus.Exists;
            if (result.UserCancelled)
            {
                repositoryRecoveryOperationMessage =
                    "Windows approval was cancelled. Backups remain paused until repair completes.";
            }
            else if (!result.Succeeded)
            {
                string detail = string.IsNullOrWhiteSpace(result.ErrorMessage)
                    ? "The protected recovery helper did not return a verified result."
                    : result.ErrorMessage;
                repositoryRecoveryOperationMessage =
                    "Repair failed: " + detail + " Backups remain paused.";
            }
            else if (!journalCleared)
            {
                repositoryRecoveryOperationMessage =
                    "Protected recovery returned success, but the interruption journal still exists. Backups remain paused.";
            }
            else
            {
                repositoryRecoveryOperationMessage = string.Empty;
            }

            sourceSignature = null;
            nextScheduleRefreshUtc = DateTime.MinValue;
            RefreshDashboard();

            if (result.UserCancelled)
            {
                MessageBox.Show(
                    this,
                    "Windows approval was cancelled. Nothing was bypassed or dismissed; backups remain paused until repair succeeds.",
                    "Repository repair cancelled",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            else if (!result.Succeeded)
            {
                MessageBox.Show(
                    this,
                    repositoryRecoveryOperationMessage,
                    "Repository repair failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
            else if (!journalCleared)
            {
                MessageBox.Show(
                    this,
                    repositoryRecoveryOperationMessage,
                    "Repository repair not confirmed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
            else
            {
                ShowTrayMessage(
                    "Repository move repaired",
                    "The protected repository state was verified. Backup controls are available again.",
                    Forms.ToolTipIcon.Info);
            }
        }

        private void OnChangeRepositoryClick(object sender, RoutedEventArgs args)
        {
            UpdateRepositoryButtons();
            if (repositoryOperationInProgress || anomalyReviewInProgress || previewEnabled ||
                RepositoryRecoveryBlocksMutations() ||
                sourceOperationInProgress || scheduleOperationInProgress ||
                backupStartInProgress || CancellationBlocksMutations(lastSnapshot) ||
                DateTime.UtcNow < backupRequestPendingUntilUtc ||
                currentSourceConfiguration == null ||
                (lastSnapshot != null && lastSnapshot.IsActive))
            {
                return;
            }
            string managerPath = System.IO.Path.Combine(
                currentSourceConfiguration.InstallRoot,
                EngineProfile.Current.RepositoryManagerFileName);
            if (!File.Exists(managerPath))
            {
                UpdateRepositoryButtons();
                return;
            }

            repositoryOperationInProgress = true;
            UpdateSourceButtons();
            bool changed = false;
            try
            {
                RepositoryLocationWindow window = new RepositoryLocationWindow(
                    currentSourceConfiguration,
                    themeResolution.Palette);
                window.Owner = this;
                window.ShowDialog();
                changed = window.RepositoryChanged;
            }
            finally
            {
                repositoryOperationInProgress = false;
                sourceSignature = null;
                RefreshSources(true);
                UpdateSourceButtons();
            }
            if (changed)
            {
                ShowTrayMessage(
                    "Backup location changed",
                    "The new Restic repository is active. The previous repository was retained.",
                    Forms.ToolTipIcon.Info);
            }
        }

        private bool ScheduleEditBlocked()
        {
            return scheduleOperationInProgress || anomalyReviewInProgress || previewEnabled || sourceOperationInProgress ||
                repositoryOperationInProgress ||
                RepositoryRecoveryBlocksMutations() ||
                CancellationBlocksMutations(lastSnapshot) ||
                backupStartInProgress || DateTime.UtcNow < backupRequestPendingUntilUtc ||
                (lastSnapshot != null && lastSnapshot.IsActive);
        }

        private async void OnEditScheduleClick(object sender, RoutedEventArgs args)
        {
            if (scheduleConfirmationInProgress || ScheduleEditBlocked())
            {
                UpdateScheduleButton();
                return;
            }

            // Read the installed schedule fresh before offering to edit it, off the UI thread. The flag
            // keeps the button disabled (and a second click out) while the read is waiting.
            TaskScheduleReadResult scheduleCheck;
            scheduleConfirmationInProgress = true;
            UpdateScheduleButton();
            PublishWebPresentationState();
            try
            {
                scheduleCheck = await ReadScheduleOffUiThreadAsync();
            }
            finally
            {
                scheduleConfirmationInProgress = false;
            }
            if (ScheduleEditBlocked())
            {
                // A protected operation started while the schedule was being read.
                UpdateScheduleButton();
                return;
            }
            nextScheduleRefreshUtc = DateTime.UtcNow.AddSeconds(30);
            ApplyScheduleReadResult(scheduleCheck);
            if (currentTaskSchedule == null)
            {
                // One plain sentence first. What Windows reported follows it, for anyone who needs the reason.
                DashboardDialog.Notify(
                    this,
                    themeResolution.Palette,
                    "Schedule unavailable",
                    "Rewindle could not verify the installed backup schedule, so it cannot be edited right now. Nothing was changed.",
                    string.IsNullOrWhiteSpace(scheduleReadError)
                        ? null
                        : new[] { "What Windows reported: " + scheduleReadError },
                    "Close",
                    true);
                return;
            }

            ScheduleEditorWindow editor = new ScheduleEditorWindow(
                currentTaskSchedule,
                themeResolution.Palette);
            editor.Owner = this;
            bool? accepted = editor.ShowDialog();
            ScheduleChangeRequest requested = editor.RequestedChange;
            if (!accepted.HasValue || !accepted.Value || requested == null)
            {
                return;
            }

            if (scheduleOperationInProgress || anomalyReviewInProgress || sourceOperationInProgress ||
                repositoryOperationInProgress || RepositoryRecoveryBlocksMutations() ||
                backupStartInProgress ||
                CancellationBlocksMutations(lastSnapshot) ||
                DateTime.UtcNow < backupRequestPendingUntilUtc ||
                (lastSnapshot != null && lastSnapshot.IsActive))
            {
                SetScheduleStatus("Schedule not changed because a protected operation started.", Amber, "warning");
                UpdateScheduleButton();
                return;
            }

            scheduleOperationInProgress = true;
            scheduleReadGeneration++;
            SetScheduleStatus("Waiting for Windows approval…", BlueText, "info");
            UpdateSourceButtons();

            ScheduleManagerResult managerResult;
            try
            {
                managerResult = await Task.Run(delegate
                {
                    return ScheduleManagerLauncher.Run(
                        requested,
                        delegate
                        {
                            Dispatcher.BeginInvoke(
                                new Action(delegate
                                {
                                    SetScheduleStatus("Updating the protected Windows schedule…", BlueText, "info");
                                }),
                                DispatcherPriority.Background);
                        });
                });
            }
            catch (Exception error)
            {
                managerResult = ScheduleManagerResult.Failure(error.Message, -1);
            }

            if (managerResult.UserCancelled)
            {
                scheduleOperationInProgress = false;
                SetScheduleStatus("Schedule unchanged — Windows approval was cancelled.", MutedText, "info");
                nextScheduleRefreshUtc = DateTime.MinValue;
                RefreshSchedule(true);
                UpdateSourceButtons();
                return;
            }

            SetScheduleStatus("Verifying the installed schedule…", BlueText, "info");
            // A deliberate post-edit verification. It still runs, but off the UI thread, and the button
            // stays disabled (scheduleOperationInProgress) until the result has been judged below.
            TaskScheduleReadResult independentRead = await ReadScheduleOffUiThreadAsync();
            bool independentlyVerified = managerResult.Succeeded &&
                independentRead.Succeeded &&
                independentRead.Schedule != null &&
                independentRead.Schedule.Matches(requested);
            scheduleOperationInProgress = false;
            nextScheduleRefreshUtc = DateTime.UtcNow.AddSeconds(30);

            if (independentlyVerified)
            {
                SetCurrentTaskSchedule(independentRead.Schedule);
                scheduleReadError = string.Empty;
                SetScheduleStatus("Schedule updated and independently verified.", Green, "success");
            }
            else
            {
                string detail = !managerResult.Succeeded
                    ? managerResult.ErrorMessage
                    : !independentRead.Succeeded
                        ? independentRead.ErrorMessage
                        : "The installed task did not match the reviewed settings.";
                scheduleReadError = detail ?? "The schedule could not be verified.";
                SetCurrentTaskSchedule(independentRead.Succeeded
                    ? independentRead.Schedule
                    : null);
                SetScheduleStatus(
                    "Windows did not confirm the new schedule. Check it before relying on it.",
                    Rose,
                    "error");
                // One plain sentence first. What Windows reported follows it, for anyone who needs the reason.
                DashboardDialog.Notify(
                    this,
                    themeResolution.Palette,
                    "Schedule change failed",
                    "Windows did not confirm the new schedule. Check the schedule shown in Rewindle before relying on it.",
                    new[] { "What Windows reported: " + scheduleReadError },
                    "Close",
                    true);
            }

            UpdateHeaderSubtitle();
            if (lastSnapshot != null)
            {
                ApplySnapshot(lastSnapshot);
            }
            UpdateSourceButtons();
        }

        private bool HasNewerBackupTelemetry(TelemetrySnapshot snapshot)
        {
            if (snapshot == null)
            {
                return false;
            }
            if (!string.IsNullOrWhiteSpace(snapshot.RunId) &&
                !string.Equals(
                    snapshot.RunId,
                    backupRequestBaselineRunId,
                    StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            return false;
        }

        // True when this PC is running on battery while the installed task is set to wait for AC power. Task Scheduler stays
        // the authority on whether the task starts; this only lets the person know before they ask.
        private bool BackupTaskWaitsForAcPowerNow()
        {
            TaskSchedule schedule = currentTaskSchedule;
            if (schedule == null || schedule.AllowStartOnBatteries)
            {
                return false;
            }
            try
            {
                return Forms.SystemInformation.PowerStatus.PowerLineStatus == Forms.PowerLineStatus.Offline;
            }
            catch (Exception)
            {
                return false;
            }
        }

        private bool BackupBlocksSourceChanges()
        {
            return scheduleOperationInProgress ||
                repositoryOperationInProgress ||
                RepositoryRecoveryBlocksMutations() ||
                CancellationBlocksMutations(lastSnapshot) ||
                anomalyReviewInProgress ||
                backupStartInProgress ||
                DateTime.UtcNow < backupRequestPendingUntilUtc ||
                (lastSnapshot != null && lastSnapshot.IsActive);
        }

        private async void OnBackupNowClick(object sender, RoutedEventArgs args)
        {
            if (backupStartInProgress || anomalyReviewInProgress || previewEnabled || sourceOperationInProgress ||
                repositoryOperationInProgress ||
                RepositoryRecoveryBlocksMutations() ||
                CancellationBlocksMutations(lastSnapshot) ||
                scheduleOperationInProgress ||
                DateTime.UtcNow < backupRequestPendingUntilUtc ||
                currentSourceConfiguration == null ||
                !currentSourceConfiguration.Sources.Any(source => source.IsProtectedCanary) ||
                (lastSnapshot != null && lastSnapshot.IsActive))
            {
                return;
            }

            string question = "Start a real backup now?\n\n" +
                "This reads all protected folders and may take a while. " +
                "Your automatic schedule is unchanged.";
            if (BackupTaskWaitsForAcPowerNow())
            {
                // A hint only. The request is still made if the person says yes, and Task Scheduler decides.
                question += "\n\nThis PC is on battery and the backup task waits for AC power, so Windows may accept " +
                    "the request without starting it. Plug in, or allow battery use in Edit schedule.";
            }
            MessageBoxResult confirmation = MessageBox.Show(
                this,
                question,
                "Start backup now?",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question,
                MessageBoxResult.No);
            if (confirmation != MessageBoxResult.Yes)
            {
                return;
            }
            if (backupStartInProgress || anomalyReviewInProgress || previewEnabled || sourceOperationInProgress ||
                repositoryOperationInProgress ||
                RepositoryRecoveryBlocksMutations() ||
                CancellationBlocksMutations(lastSnapshot) ||
                scheduleOperationInProgress ||
                DateTime.UtcNow < backupRequestPendingUntilUtc ||
                currentSourceConfiguration == null ||
                !currentSourceConfiguration.Sources.Any(source => source.IsProtectedCanary) ||
                (lastSnapshot != null && lastSnapshot.IsActive))
            {
                UpdateBackupButton(lastSnapshot);
                return;
            }

            string baselineRunId = lastSnapshot == null ? string.Empty : lastSnapshot.RunId;
            backupStartInProgress = true;
            UpdateBackupButton(lastSnapshot);
            BackupTaskRequestResult result;
            try
            {
                result = await Task.Run(delegate { return BackupTaskController.RequestStart(); });
            }
            catch (Exception error)
            {
                result = BackupTaskRequestResult.Failure(error.Message, -1);
            }
            finally
            {
                backupStartInProgress = false;
            }

            if (result.UserCancelled)
            {
                MessageBox.Show(
                    this,
                    "Windows approval was cancelled. No backup was requested.",
                    "Backup request cancelled",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            else if (!result.Succeeded)
            {
                string detail = string.IsNullOrWhiteSpace(result.ErrorMessage)
                    ? "Windows Task Scheduler could not accept the request."
                    : result.ErrorMessage;
                MessageBox.Show(
                    this,
                    "The backup was not requested.\n\n" + detail,
                    "Backup request failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
            else
            {
                backupRequestBaselineRunId = baselineRunId ?? string.Empty;
                backupRequestPendingUntilUtc = DateTime.UtcNow.AddSeconds(45);
                // This request replaces the answer to the last one.
                backupNotStartedText = string.Empty;
                backupNotStartedBaselineRunId = string.Empty;
                ShowTrayMessage(
                    "Backup requested",
                    "Windows accepted the request. Live progress will appear when the task starts.",
                    Forms.ToolTipIcon.Info);
            }

            RefreshDashboard();
            UpdateBackupButton(lastSnapshot);
        }

        private async void OnAddSourceClick(object sender, RoutedEventArgs args)
        {
            if (sourceOperationInProgress || BackupBlocksSourceChanges() || currentSourceConfiguration == null)
            {
                return;
            }

            string sourcePath;
            using (Forms.FolderBrowserDialog dialog = new Forms.FolderBrowserDialog())
            {
                dialog.Description = "Choose a folder to include in future Restic backup runs.";
                dialog.RootFolder = Environment.SpecialFolder.MyComputer;
                dialog.ShowNewFolderButton = true;
                if (dialog.ShowDialog() != Forms.DialogResult.OK)
                {
                    return;
                }
                sourcePath = SourceConfiguration.NormalizePath(dialog.SelectedPath);
            }

            if (currentSourceConfiguration.ContainsUserSource(sourcePath))
            {
                SetSourceNotice("That folder is already backed up.", Amber, 8);
                return;
            }
            if (BackupBlocksSourceChanges())
            {
                SetSourceNotice("A backup is starting or already running. Try the folder change again afterward.", Amber, 10);
                return;
            }
            await ApplySourceChange("Add", sourcePath);
        }

        private async void OnRemoveSourceClick(object sender, RoutedEventArgs args)
        {
            if (sourceOperationInProgress || BackupBlocksSourceChanges() || currentSourceConfiguration == null)
            {
                return;
            }
            Button removeButton = sender as Button;
            BackupSourceView selected = removeButton == null
                ? null
                : removeButton.Tag as BackupSourceView;
            if (selected == null || selected.IsProtectedCanary)
            {
                SetSourceNotice("The folder that holds the restore test file cannot be removed.", Amber, 8);
                return;
            }

            if (!ConfirmSourceRemoval(selected))
            {
                return;
            }
            if (BackupBlocksSourceChanges())
            {
                SetSourceNotice("A backup is starting or already running. Try the folder change again afterward.", Amber, 10);
                return;
            }
            await ApplySourceChange("Remove", selected.SourcePath);
        }

        private bool ConfirmSourceRemoval(BackupSourceView source)
        {
            Window dialog = new Window();
            dialog.Title = "Remove folder from future backups?";
            dialog.Owner = this;
            dialog.Width = 530;
            dialog.SizeToContent = SizeToContent.Height;
            dialog.ResizeMode = ResizeMode.NoResize;
            dialog.WindowStartupLocation = WindowStartupLocation.CenterOwner;
            dialog.ShowInTaskbar = false;
            DashboardVisualStyle.ApplyWindow(dialog, themeResolution.Palette);
            dialog.Background = BackgroundTop;
            dialog.Foreground = PrimaryText;
            dialog.FontFamily = FontFamily;

            Border frame = new Border();
            frame.Background = CardBrush;
            frame.BorderBrush = CardBorderBrush;
            frame.BorderThickness = new Thickness(1);
            frame.Padding = new Thickness(24, 22, 24, 20);

            StackPanel content = new StackPanel();
            TextBlock title = new TextBlock();
            title.Text = "Remove folder from future backups?";
            title.FontSize = 20;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = PrimaryText;
            content.Children.Add(title);

            TextBlock warning = new TextBlock();
            warning.Text = "Removing a folder stops future backups. Existing snapshots remain intact.";
            warning.FontSize = 13;
            warning.Foreground = BrushFrom("#B7C5D1");
            warning.TextWrapping = TextWrapping.Wrap;
            warning.Margin = new Thickness(0, 8, 0, 16);
            content.Children.Add(warning);

            Border folder = new Border();
            folder.Background = CardSoftBrush;
            folder.BorderBrush = CardBorderBrush;
            folder.BorderThickness = new Thickness(1);
            folder.CornerRadius = new CornerRadius(10);
            folder.Padding = new Thickness(13, 10, 13, 10);
            StackPanel folderDetails = new StackPanel();
            TextBlock folderName = new TextBlock();
            folderName.Text = source.DisplayName;
            folderName.FontSize = 14;
            folderName.FontWeight = FontWeights.SemiBold;
            folderName.Foreground = PrimaryText;
            folderDetails.Children.Add(folderName);
            TextBlock folderPath = new TextBlock();
            folderPath.Text = source.SourcePath;
            folderPath.FontSize = 12;
            folderPath.Foreground = MutedText;
            folderPath.TextWrapping = TextWrapping.Wrap;
            folderPath.Margin = new Thickness(0, 3, 0, 0);
            folderDetails.Children.Add(folderPath);
            folder.Child = folderDetails;
            content.Children.Add(folder);

            StackPanel actions = new StackPanel();
            actions.Orientation = Orientation.Horizontal;
            actions.HorizontalAlignment = HorizontalAlignment.Right;
            actions.Margin = new Thickness(0, 19, 0, 0);

            Button keep = CreateButton("Keep folder");
            keep.MinHeight = 36;
            keep.IsCancel = true;
            keep.Click += delegate { dialog.DialogResult = false; };
            AutomationProperties.SetName(keep, "Keep folder");
            actions.Children.Add(keep);

            Button remove = CreateButton("Remove from future backups");
            remove.Margin = new Thickness(10, 0, 0, 0);
            remove.MinHeight = 36;
            remove.Background = Rose;
            remove.BorderBrush = BrushFrom("#FF9AAA");
            remove.Foreground = BrushFrom("#201016");
            remove.Click += delegate { dialog.DialogResult = true; };
            AutomationProperties.SetName(remove, "Remove from future backups");
            AutomationProperties.SetHelpText(remove, warning.Text);
            actions.Children.Add(remove);
            content.Children.Add(actions);

            frame.Child = content;
            dialog.Content = frame;
            DashboardVisualStyle.ApplyDialogEntrance(dialog);
            AutomationProperties.SetName(dialog, "Remove folder from future backups");
            bool? result = dialog.ShowDialog();
            return result.HasValue && result.Value;
        }

        private async Task ApplySourceChange(string action, string sourcePath)
        {
            if (BackupBlocksSourceChanges())
            {
                SetSourceNotice("A backup is starting or already running. No folder change was requested.", Amber, 10);
                return;
            }
            bool isAdd = string.Equals(action, "Add", StringComparison.Ordinal);
            SourceConfiguration configuration = currentSourceConfiguration;
            int operationGeneration = sourceOperationGeneration + 1;
            sourceOperationInProgress = true;
            if (isAdd)
            {
                sourceOperationGeneration = operationGeneration;
                sourceOperationAction = action;
                sourceOperationPath = sourcePath;
                sourceOperationError = string.Empty;
                sourceOperationStage = SourceOperationStage.AwaitingApproval;
                sourceOperationExpiresUtc = DateTime.MaxValue;
                animateNextSourceOperationEntry = true;
                sourceNoticeExpiresUtc = DateTime.MinValue;
                sourceSignature = null;
                RefreshSources(true);
            }
            else
            {
                SetSourceNotice("Waiting for Windows approval...", BlueText, 600);
            }
            UpdateSourceButtons();

            SourceManagerResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return SourceManagerLauncher.Run(
                        configuration,
                        action,
                        sourcePath,
                        delegate
                        {
                            if (!isAdd)
                            {
                                return;
                            }
                            Dispatcher.BeginInvoke(
                                new Action(delegate
                                {
                                    if (sourceOperationGeneration == operationGeneration &&
                                        sourceOperationInProgress &&
                                        sourceOperationStage == SourceOperationStage.AwaitingApproval)
                                    {
                                        SetSourceOperationStage(
                                            SourceOperationStage.Applying,
                                            string.Empty,
                                            DateTime.MaxValue,
                                            false,
                                            true);
                                    }
                                }),
                                DispatcherPriority.Background);
                        });
                });
            }
            catch (Exception error)
            {
                result = SourceManagerResult.Failure(error.Message, -1);
            }
            finally
            {
                if (!isAdd || sourceOperationGeneration == operationGeneration)
                {
                    sourceOperationInProgress = false;
                }
            }

            if (result.UserCancelled)
            {
                if (isAdd && sourceOperationGeneration == operationGeneration)
                {
                    SetSourceOperationStage(
                        SourceOperationStage.Cancelled,
                        string.Empty,
                        DateTime.UtcNow.AddSeconds(3),
                        false,
                        true);
                }
                else
                {
                    SetSourceNotice("Windows approval was cancelled. No folders were changed.", Amber, 12);
                    MessageBox.Show(
                        this,
                        "Windows approval was cancelled. The backup folder list was not changed.",
                        "Folder change cancelled",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }
                RefreshSources(false);
                return;
            }
            if (!result.Succeeded)
            {
                string detail = string.IsNullOrWhiteSpace(result.ErrorMessage)
                    ? "The protected source manager could not complete the request."
                    : result.ErrorMessage;
                if (isAdd && sourceOperationGeneration == operationGeneration)
                {
                    SetSourceOperationStage(
                        SourceOperationStage.Failed,
                        detail,
                        DateTime.MaxValue,
                        false,
                        true);
                }
                else
                {
                    SetSourceNotice("Folder change failed. The protected configuration was not updated.", Rose, 15);
                    MessageBox.Show(
                        this,
                        "The folder list was not changed.\n\n" + detail,
                        "Folder change failed",
                        MessageBoxButton.OK,
                        MessageBoxImage.Error);
                }
                RefreshSources(false);
                return;
            }

            if (isAdd && sourceOperationGeneration == operationGeneration)
            {
                SetSourceOperationStage(
                    SourceOperationStage.Verifying,
                    string.Empty,
                    DateTime.MaxValue,
                    false,
                    true);
                await Dispatcher.Yield(DispatcherPriority.Render);
            }
            RefreshSources(true);
            bool isPresent = currentSourceConfiguration != null &&
                currentSourceConfiguration.ContainsUserSource(sourcePath);
            bool planConfirmed = currentSourceConfiguration != null &&
                string.Equals(result.PlanId, configuration.PlanId, StringComparison.Ordinal) &&
                string.Equals(currentSourceConfiguration.PlanId, configuration.PlanId, StringComparison.Ordinal) &&
                result.PreviousConfigGeneration == configuration.ConfigGeneration &&
                configuration.ConfigGeneration < long.MaxValue &&
                result.ConfigGeneration == configuration.ConfigGeneration + 1 &&
                currentSourceConfiguration.ConfigGeneration == result.ConfigGeneration;
            bool confirmed = planConfirmed &&
                (isAdd
                    ? isPresent
                    : !isPresent);
            if (!confirmed)
            {
                string detail = "The manager finished, but the protected configuration did not confirm the change.";
                if (isAdd && sourceOperationGeneration == operationGeneration)
                {
                    SetSourceOperationStage(
                        SourceOperationStage.Failed,
                        detail,
                        DateTime.MaxValue,
                        true,
                        true);
                }
                else
                {
                    SetSourceNotice(detail, Rose, 15);
                    MessageBox.Show(
                        this,
                        "The protected configuration did not confirm the requested folder change. " +
                            "Refresh the dashboard and check the installation logs.",
                        "Folder change not confirmed",
                        MessageBoxButton.OK,
                        MessageBoxImage.Error);
                }
                return;
            }

            if (isAdd && sourceOperationGeneration == operationGeneration)
            {
                sourceOperationStage = SourceOperationStage.Succeeded;
                sourceOperationExpiresUtc = DateTime.UtcNow.AddSeconds(4);
                animateNextResolvedSourceRow = true;
                sourceSignature = null;
                RefreshSources(true);
                if (!IsVisible)
                {
                    ShowTrayMessage("Backup folder added", sourcePath, Forms.ToolTipIcon.Info);
                }
            }
            else
            {
                SetSourceNotice("Folder removed from future backups. Existing snapshots were not deleted.", Green, 12);
                ShowTrayMessage("Backup folder removed", sourcePath, Forms.ToolTipIcon.Info);
            }
            UpdateSourceButtons();
        }

        private void SetSourceNotice(string message, Brush color, int seconds)
        {
            sourceStatus.Text = message;
            sourceStatus.Foreground = color;
            sourceNoticeExpiresUtc = DateTime.UtcNow.AddSeconds(seconds);
            sourceNoticeText = message ?? string.Empty;
            sourceNoticeTone = color == Rose ? "error"
                : color == Amber ? "warning"
                : color == Green ? "success"
                : "info";
            AutomationProperties.SetName(sourceStatus, message);
            AutomationProperties.SetLiveSetting(
                sourceStatus,
                color == Rose ? AutomationLiveSetting.Assertive : AutomationLiveSetting.Polite);
            Dispatcher.BeginInvoke(
                new Action(delegate
                {
                    AutomationPeer peer = UIElementAutomationPeer.FromElement(sourceStatus) ??
                        UIElementAutomationPeer.CreatePeerForElement(sourceStatus);
                    if (peer != null)
                    {
                        peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
                    }
                }),
                DispatcherPriority.Background);
            PublishWebPresentationState();
        }

        // Everything about a run that the history list and chart show, so a run that changed is bound again and a
        // history that did not is left alone.
        private static string BuildHistoryContentSignature(IList<RunMetricView> runs)
        {
            System.Text.StringBuilder builder = new System.Text.StringBuilder(runs.Count * 56);
            foreach (RunMetricView run in runs)
            {
                builder.Append(run.RunId).Append('|')
                    .Append(run.StartedLocal.Ticks.ToString(CultureInfo.InvariantCulture)).Append('|')
                    .Append(run.TypeLabel).Append('|')
                    .Append(run.StateLabel).Append('|')
                    .Append(run.Success ? '1' : '0').Append('|')
                    .Append(run.DurationSeconds.ToString("R", CultureInfo.InvariantCulture)).Append('|')
                    .Append(run.Files.ToString(CultureInfo.InvariantCulture)).Append('|')
                    .Append(run.ProcessedBytes.ToString(CultureInfo.InvariantCulture)).Append('|')
                    .Append(run.StoredBytes.ToString(CultureInfo.InvariantCulture)).Append('|')
                    .Append(run.SnapshotShort).Append('\n');
            }
            return builder.ToString();
        }

        private void ApplySnapshot(TelemetrySnapshot snapshot)
        {
            ObserveCancellationState(snapshot);
            heroTitle.Text = snapshot.StatusLabel;
            heroDetail.Text = snapshot.StatusDetail;
            bool showLiveProgress = snapshot.IsActive || snapshot.IsFailure;
            activeProgressPanel.Visibility = showLiveProgress ? Visibility.Visible : Visibility.Collapsed;
            if (showLiveProgress && !activeProgressWasVisible)
            {
                DashboardVisualStyle.Reveal(
                    activeProgressPanel,
                    DashboardVisualStyle.PopDuration,
                    TimeSpan.Zero,
                    4.0);
            }
            activeProgressWasVisible = showLiveProgress;
            if (snapshot.IsActive)
            {
                StartShimmer();
            }
            else
            {
                StopShimmer();
            }
            bool showRunMetrics = snapshot.IsActive;
            metricsLayout.Visibility = showRunMetrics ? Visibility.Visible : Visibility.Collapsed;
            metricsContext.Visibility = showRunMetrics ? Visibility.Visible : Visibility.Collapsed;
            bool firstBackupPending = string.Equals(
                snapshot.StateKey,
                "ready",
                StringComparison.OrdinalIgnoreCase);
            progressPercent.Text = firstBackupPending
                ? "First backup pending"
                : (snapshot.Percent * 100).ToString("0.0", CultureInfo.CurrentCulture) + "%";
            estimateBadge.Text = firstBackupPending
                ? "DRY-RUN BASELINE  •  NOT YET BACKED UP"
                : string.Equals(snapshot.StateKey, "cancelling", StringComparison.OrdinalIgnoreCase)
                    ? "CANCELLATION REQUESTED  •  COOPERATIVE STOP"
                : snapshot.IsSuccess
                    ? "FINAL VERIFIED RESULT"
                : snapshot.ProgressIsEstimated
                    ? "ESTIMATED  •  " + snapshot.ConfidenceLabel.ToUpperInvariant()
                    : "RESTIC COUNTERS  •  COMPOSED OVERALL";
            estimateBadge.Foreground = firstBackupPending
                ? Amber
                : snapshot.ProgressIsEstimated ? Teal : BlueText;
            AnimateProgress(snapshot.Percent, true);

            if (string.Equals(snapshot.StateKey, "cancelling", StringComparison.OrdinalIgnoreCase))
            {
                etaTitle.Text = "Stopping safely";
                etaValue.Text = "Please wait";
                etaHint.Text = "Restic is finishing its current operation and releasing the repository lock";
            }
            else
            {
                etaTitle.Text = snapshot.ProgressIsEstimated
                    ? "Estimated time remaining"
                    : "Time remaining";
                if (snapshot.Eta.HasValue)
                {
                    etaValue.Text = FormatDuration(snapshot.Eta.Value);
                    string completion = snapshot.EstimatedCompletion.HasValue
                        ? "Likely around " + snapshot.EstimatedCompletion.Value.ToString("HH:mm", CultureInfo.CurrentCulture)
                        : "Updates as Restic advances";
                    etaHint.Text = snapshot.ProgressIsEstimated
                        ? snapshot.ConfidenceLabel + "  •  " + completion
                        : completion;
                }
                else if (snapshot.IsSuccess)
                {
                    if (snapshot.AnomalyReviewAcknowledged)
                    {
                        AnomalyReviewWording reviewWording = EngineProfile.Current.AnomalyReview;
                        heroTitle.Text = reviewWording.HeroTitle;
                        etaTitle.Text = reviewWording.HeroCaption;
                        etaValue.Text = reviewWording.HeroValue;
                        etaHint.Text = reviewWording.HeroHint;
                    }
                    else
                    {
                    heroTitle.Text = snapshot.NeedsAnomalyReview
                        ? "Backup verified — review changes"
                        : "Backup verified";
                    etaTitle.Text = snapshot.NeedsAnomalyReview
                        ? "Safety hold"
                        : "Next automatic run";
                    etaValue.Text = snapshot.NeedsAnomalyReview
                        ? "Review required"
                        : currentTaskSchedule == null
                            ? "Unavailable"
                            : currentTaskSchedule.NextRunDisplay;
                    etaHint.Text = snapshot.NeedsAnomalyReview
                        ? EngineProfile.Current.AnomalyReview.HoldHeroDetail
                        : currentTaskSchedule == null
                            ? "Installed schedule could not be verified"
                            : "Latest snapshot and restore test verified  •  " + currentTaskSchedule.Summary;
                }
                    }
                else if (snapshot.IsFailure)
                {
                    etaTitle.Text = "Backup result";
                    etaValue.Text = "Stopped";
                    etaHint.Text = "The incomplete run was recorded in Activity";
                }
                else if (snapshot.IsActive)
                {
                    etaValue.Text = "Calculating";
                    etaHint.Text = "Building an estimate from live progress and run history";
                }
                else
                {
                    etaTitle.Text = "Next automatic run";
                    etaValue.Text = currentTaskSchedule == null
                        ? "Unavailable"
                        : currentTaskSchedule.NextRunDisplay;
                    etaHint.Text = currentTaskSchedule == null
                        ? "Installed schedule could not be verified"
                        : currentTaskSchedule.SettingsSummary;
                }
            }

            bool hasActualFileCount = snapshot.FilesDone > 0 || snapshot.IsSuccess;
            bool hasActualByteCount = snapshot.BytesDone > 0 || snapshot.IsSuccess;
            filesValue.Text = hasActualFileCount ? FormatNumber(Math.Max(0, snapshot.FilesDone)) : "—";
            bytesValue.Text = hasActualByteCount ? FormatBytes(Math.Max(0, snapshot.BytesDone)) : "—";
            speedValue.Text = snapshot.TransferRateBytesPerSecond > 0
                ? FormatBytes(snapshot.TransferRateBytesPerSecond) + "/s"
                : "—";
            elapsedValue.Text = snapshot.Elapsed > TimeSpan.Zero ? FormatDuration(snapshot.Elapsed) : "—";
            errorsValue.Text = snapshot.ErrorCount.ToString("N0", CultureInfo.CurrentCulture);
            errorsValue.Foreground = snapshot.ErrorCount > 0 ? Rose : PrimaryText;
            if (metricsContext != null)
            {
                metricsContext.Text = snapshot.IsActive
                    ? "Current run"
                    : snapshot.IsSuccess
                        ? "Latest verified run"
                        : "Latest recorded run";
            }

            SetPhase(snapshot.PhaseIndex, snapshot.IsFailure);
            if (string.Equals(snapshot.StateKey, "cancelling", StringComparison.OrdinalIgnoreCase))
            {
                SetBadge("STOPPING SAFELY", Amber, BrushFrom("#3A2F18"));
                StartStatusPulse();
            }
            else if (snapshot.IsActive)
            {
                SetBadge("LIVE  •  " + snapshot.PhaseLabel.ToUpperInvariant(), Teal, BrushFrom("#12352F"));
                StartStatusPulse();
            }
            else if (snapshot.IsFailure)
            {
                SetBadge("NEEDS ATTENTION", Rose, BrushFrom("#3B1D2A"));
                StopStatusPulse();
            }
            else if (snapshot.IsStatusUnavailable)
            {
                // Not a failed run and not a ready plan: nothing could be read, and the badge says exactly that.
                SetBadge("STATUS UNAVAILABLE", Amber, BrushFrom("#3A2F18"));
                statusBadge.Visibility = Visibility.Visible;
                StopStatusPulse();
            }
            else if (snapshot.NeedsAnomalyReview)
            {
                SetBadge("REVIEW CHANGES", Amber, BrushFrom("#3A2F18"));
                statusBadge.Visibility = Visibility.Visible;
                StopStatusPulse();
            }
            else if (snapshot.AnomalyReviewAcknowledged)
            {
                SetBadge(EngineProfile.Current.AnomalyReview.RecordedBadge, Green, BrushFrom("#14352C"));
                statusBadge.Visibility = Visibility.Visible;
                StopStatusPulse();
            }
            else if (snapshot.IsSuccess)
            {
                SetBadge("VERIFIED", Green, BrushFrom("#14352C"));
                statusBadge.Visibility = Visibility.Visible;
                StopStatusPulse();
            }
            else if (snapshot.IsCancelled)
            {
                SetBadge("CANCELLED SAFELY", Blue, BrushFrom("#172B45"));
                statusBadge.Visibility = Visibility.Visible;
                StopStatusPulse();
            }
            else
            {
                SetBadge("READY", Blue, BrushFrom("#172B45"));
                statusBadge.Visibility = Visibility.Visible;
                StopStatusPulse();
            }

            if (snapshot.IsActive || snapshot.IsFailure)
            {
                statusBadge.Visibility = Visibility.Visible;
            }

            ApplyFreshnessStatus(snapshot);
            ApplyOffsiteStatus(snapshot);
            ApplyRepositoryRecoveryPrimaryStatus(snapshot);

            IList<RunMetricView> history = snapshot.History ?? new List<RunMetricView>();
            RunMetricView selectedRun = historyGrid.SelectedItem as RunMetricView;
            string selectedRunId = selectedRun == null ? string.Empty : selectedRun.RunId;
            IList<RunMetricView> orderedHistory = history
                .OrderByDescending(item => item.StartedLocal)
                .ToList();
            string newHistorySignature = string.Join(
                "|",
                orderedHistory.Select(item => item.RunId ?? string.Empty).ToArray());
            string historyContentSignature = BuildHistoryContentSignature(orderedHistory);
            if (!string.Equals(historyContentSignature, historyBindSignature, StringComparison.Ordinal))
            {
                // Giving the grid the same runs again clears its selection and puts it back, and the refresh does
                // that every second, so the list and the chart are only bound again when a run differs.
                historyRebindInProgress = true;
                try
                {
                    historyGrid.ItemsSource = orderedHistory;
                    if (!string.IsNullOrWhiteSpace(selectedRunId))
                    {
                        historyGrid.SelectedItem = orderedHistory.FirstOrDefault(item =>
                            string.Equals(
                                item.RunId,
                                selectedRunId,
                                StringComparison.OrdinalIgnoreCase));
                    }
                }
                finally
                {
                    historyRebindInProgress = false;
                }
                runChart.Runs = history.OrderBy(item => item.StartedLocal).ToList();
                historyBindSignature = historyContentSignature;
            }
            if (!string.IsNullOrWhiteSpace(historyAnimationSignature) &&
                !string.Equals(historyAnimationSignature, newHistorySignature, StringComparison.Ordinal))
            {
                DashboardVisualStyle.Reveal(
                    historyTable,
                    TimeSpan.FromMilliseconds(420),
                    TimeSpan.Zero,
                    8.0);
                DashboardVisualStyle.Reveal(
                    historyChart,
                    TimeSpan.FromMilliseconds(420),
                    TimeSpan.FromMilliseconds(60),
                    8.0);
            }
            historyAnimationSignature = newHistorySignature;
            runCount.Text = history.Count.ToString(CultureInfo.InvariantCulture) + (history.Count == 1 ? " run" : " runs");
            lastUpdated.Text = "Updated " + snapshot.LastUpdatedLocal.ToString("HH:mm:ss", CultureInfo.CurrentCulture);
            UpdateBackupButton(snapshot);
            UpdateActivityActions();
            WriteHeartbeat(snapshot, true);
        }

        private void ApplyOffsiteStatus(TelemetrySnapshot snapshot)
        {
            if (settingsOffsiteStatus == null
                || settingsOffsiteDetail == null
                || settingsOffsiteEvidence == null)
            {
                return;
            }

            OffsiteStatusView status = snapshot == null
                ? null
                : snapshot.OffsiteStatus;
            if (status == null)
            {
                status = new OffsiteStatusView();
            }

            settingsOffsiteStatus.Text = status.StatusLabel;
            settingsOffsiteDetail.Text = status.StatusDetail;
            if (status.Kind == OffsiteStatusKind.Failed)
            {
                settingsOffsiteStatus.Foreground = Rose;
            }
            else if (status.Kind == OffsiteStatusKind.StatusUnavailable)
            {
                settingsOffsiteStatus.Foreground = Amber;
            }
            else if (status.Kind == OffsiteStatusKind.InProgress)
            {
                settingsOffsiteStatus.Foreground = BlueText;
            }
            else if (status.Kind == OffsiteStatusKind.LocalVerifiedProviderPending)
            {
                settingsOffsiteStatus.Foreground = Amber;
            }
            else if (status.Kind == OffsiteStatusKind.ProviderConfirmed)
            {
                settingsOffsiteStatus.Foreground = Teal;
            }
            else if (status.Kind == OffsiteStatusKind.RestoreVerified)
            {
                settingsOffsiteStatus.Foreground = Green;
            }
            else
            {
                settingsOffsiteStatus.Foreground = MutedText;
            }

            List<string> evidence = new List<string>();
            if (!string.IsNullOrEmpty(status.SnapshotShort))
            {
                evidence.Add("Snapshot " + status.SnapshotShort);
            }
            if (status.ConfigGeneration > 0)
            {
                evidence.Add(
                    "Generation "
                    + status.ConfigGeneration.ToString(
                        CultureInfo.InvariantCulture));
            }
            if (status.FileCount >= 0)
            {
                evidence.Add(FormatNumber(status.FileCount) + " files");
            }
            if (status.ByteCount >= 0)
            {
                evidence.Add(FormatBytes(status.ByteCount));
            }
            if (status.LastUpdatedLocal.HasValue)
            {
                evidence.Add(
                    "Updated "
                    + status.LastUpdatedLocal.Value.ToString(
                        "yyyy-MM-dd HH:mm",
                        CultureInfo.CurrentCulture));
            }
            settingsOffsiteEvidence.Text = evidence.Count == 0
                ? "No verified off-site inventory or restore evidence is available yet."
                : string.Join("  \u2022  ", evidence);

            AutomationProperties.SetName(
                settingsOffsiteStatus,
                "Off-site copy status: " + status.StatusLabel);
            AutomationProperties.SetName(
                settingsOffsiteDetail,
                "Off-site copy detail: " + status.StatusDetail);
            AutomationProperties.SetName(
                settingsOffsiteEvidence,
                "Off-site copy evidence: " + settingsOffsiteEvidence.Text);
        }

        private void ApplyRepositoryRecoveryPrimaryStatus(TelemetrySnapshot snapshot)
        {
            if (!RepositoryRecoveryBlocksMutations() ||
                (snapshot != null && snapshot.IsActive) ||
                CancellationBlocksMutations(snapshot))
            {
                return;
            }

            string detail = repositoryRecoveryStatus == null
                ? "Protected recovery status is unavailable."
                : repositoryRecoveryStatus.Message;
            if (repositoryRecoveryInProgress)
            {
                heroTitle.Text = "Repairing interrupted repository move";
                heroDetail.Text = string.IsNullOrWhiteSpace(repositoryRecoveryOperationMessage)
                    ? "The protected recovery helper is validating repository state."
                    : repositoryRecoveryOperationMessage;
                etaTitle.Text = "Backup safety gate";
                etaValue.Text = "Repairing";
                etaHint.Text = "No backup can start until protected recovery completes and the journal disappears.";
                SetBadge("REPAIR IN PROGRESS", Blue, BrushFrom("#172B45"));
            }
            else
            {
                heroTitle.Text = "Repository repair required";
                heroDetail.Text = detail;
                etaTitle.Text = "Backup safety gate";
                etaValue.Text = "Paused";
                etaHint.Text = "Use Repair interrupted move. There is no dismiss or manual bypass.";
                SetBadge("BACKUPS PAUSED", Rose, BrushFrom("#3B1D2A"));
            }
            statusBadge.Visibility = Visibility.Visible;
            StopStatusPulse();
        }

        private void ApplyFreshnessStatus(TelemetrySnapshot snapshot)
        {
            BackupFreshnessResult freshness = BackupFreshnessEvaluator.EvaluateNow(
                currentTaskSchedule,
                snapshot.LastVerifiedFinishedUtc,
                scheduleCoveredThroughUtc);
            Brush tone = freshness.State == BackupFreshnessState.Healthy
                ? Green
                : freshness.State == BackupFreshnessState.Paused
                    ? Amber
                    : freshness.NeedsAttention
                        ? Rose
                        : MutedText;
            string shortStatus = "Backup freshness: " + freshness.StatusLabel;
            string accessibleStatus = shortStatus + ". " + freshness.Detail;

            if (protectionFreshnessStatus != null)
            {
                protectionFreshnessStatus.Text = shortStatus + "  \u2022  " + freshness.Detail;
                protectionFreshnessStatus.Foreground = tone;
                protectionFreshnessStatus.ToolTip = freshness.Detail;
                AutomationProperties.SetName(protectionFreshnessStatus, accessibleStatus);
                AutomationProperties.SetHelpText(protectionFreshnessStatus, freshness.Detail);
                AutomationProperties.SetLiveSetting(
                    protectionFreshnessStatus,
                    freshness.NeedsAttention
                        ? AutomationLiveSetting.Assertive
                        : AutomationLiveSetting.Polite);
            }
            if (settingsFreshnessStatus != null)
            {
                settingsFreshnessStatus.Text = freshness.StatusLabel;
                settingsFreshnessStatus.Foreground = tone;
                AutomationProperties.SetName(settingsFreshnessStatus, shortStatus);
                AutomationProperties.SetHelpText(settingsFreshnessStatus, freshness.Detail);
                AutomationProperties.SetLiveSetting(
                    settingsFreshnessStatus,
                    freshness.NeedsAttention
                        ? AutomationLiveSetting.Assertive
                        : AutomationLiveSetting.Polite);
            }
            if (settingsFreshnessDetail != null)
            {
                settingsFreshnessDetail.Text = freshness.Detail;
                AutomationProperties.SetName(settingsFreshnessDetail, freshness.Detail);
                AutomationProperties.SetHelpText(settingsFreshnessDetail, freshness.Detail);
            }

            if (!lastAnnouncedFreshnessState.HasValue ||
                lastAnnouncedFreshnessState.Value != freshness.State)
            {
                lastAnnouncedFreshnessState = freshness.State;
                FrameworkElement announcementTarget = settingsFreshnessStatus as FrameworkElement
                    ?? protectionFreshnessStatus as FrameworkElement;
                if (announcementTarget != null)
                {
                    AutomationPeer peer = UIElementAutomationPeer.FromElement(announcementTarget) ??
                        UIElementAutomationPeer.CreatePeerForElement(announcementTarget);
                    if (peer != null)
                    {
                        peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
                    }
                }
            }

            bool activeRunOwnsPrimaryStatus = snapshot.IsActive || string.Equals(
                snapshot.StateKey,
                "cancelling",
                StringComparison.OrdinalIgnoreCase);
            if (activeRunOwnsPrimaryStatus)
            {
                return;
            }
            if (snapshot.IsStatusUnavailable)
            {
                // The hero and badge already say the status cannot be read, which is the more useful thing to know first; what
                // the freshness found (above, from last-success.json) is still shown in its own places.
                return;
            }

            if (freshness.State == BackupFreshnessState.Overdue ||
                freshness.State == BackupFreshnessState.ClockAnomaly)
            {
                SetBadge("NEEDS ATTENTION", Rose, BrushFrom("#3B1D2A"));
                statusBadge.Visibility = Visibility.Visible;
                StopStatusPulse();
                if (!snapshot.IsFailure)
                {
                    heroTitle.Text = freshness.State == BackupFreshnessState.Overdue
                        ? "Backup overdue"
                        : "Backup clock needs attention";
                    heroDetail.Text = freshness.Detail;
                    etaTitle.Text = "Backup freshness";
                    etaValue.Text = freshness.StatusLabel;
                    etaHint.Text = currentTaskSchedule == null
                        ? freshness.Detail
                        : "Next automatic run: " + currentTaskSchedule.NextRunDisplay;
                }
            }
            else if (freshness.State == BackupFreshnessState.Paused && !snapshot.IsFailure)
            {
                heroTitle.Text = "Automatic backups paused";
                heroDetail.Text = freshness.Detail;
                etaTitle.Text = "Automatic schedule";
                etaValue.Text = "Paused";
                etaHint.Text = currentTaskSchedule == null
                    ? "Schedule unavailable"
                    : currentTaskSchedule.Summary;
                SetBadge("PAUSED", Amber, BrushFrom("#3A2F18"));
                statusBadge.Visibility = Visibility.Visible;
                StopStatusPulse();
            }
            else if (freshness.State == BackupFreshnessState.NoVerifiedBackup &&
                !snapshot.IsFailure)
            {
                heroTitle.Text = "First verified backup needed";
                heroDetail.Text = freshness.Detail;
                SetBadge("FIRST BACKUP NEEDED", Amber, BrushFrom("#3A2F18"));
                statusBadge.Visibility = Visibility.Visible;
                StopStatusPulse();
            }
        }

        private void ApplyPreview(TelemetrySnapshot snapshot)
        {
            activeProgressPanel.Visibility = Visibility.Visible;
            metricsLayout.Visibility = Visibility.Visible;
            metricsContext.Visibility = Visibility.Visible;
            metricsContext.Text = "Previewed live run";
            statusBadge.Visibility = Visibility.Visible;
            double seconds = (DateTime.Now - previewStarted).TotalSeconds;
            double cycle = seconds % 42.0;
            double fraction = Math.Min(0.985, 0.035 + cycle / 44.0);
            RunMetricView previewBaseline = (snapshot.History ?? new List<RunMetricView>())
                .Where(run => run.Success && run.Files > 0 && run.ProcessedBytes > 0)
                .OrderByDescending(run => run.StartedLocal).FirstOrDefault();
            long totalFiles = snapshot.EstimatedFiles > 0
                ? snapshot.EstimatedFiles : previewBaseline == null ? 0 : previewBaseline.Files;
            long totalBytes = snapshot.EstimatedBytes > 0
                ? snapshot.EstimatedBytes : previewBaseline == null ? 0 : previewBaseline.ProcessedBytes;
            long files = (long)(totalFiles * fraction);
            long bytes = (long)(totalBytes * Math.Min(1, fraction * 1.03));
            TimeSpan elapsed = TimeSpan.FromSeconds(cycle * 52);
            TimeSpan eta = TimeSpan.FromSeconds(Math.Max(20, elapsed.TotalSeconds * (1 - fraction) / Math.Max(0.02, fraction)));

            heroTitle.Text = "Backup animation preview";
            heroDetail.Text = previewBaseline == null
                ? "A simulation of backup stages. No backup or file operation is running."
                : "Animated stages based on your latest completed run. No backup is running.";
            progressPercent.Text = (fraction * 100).ToString("0.0", CultureInfo.CurrentCulture) + "%";
            estimateBadge.Text = "PREVIEW  •  ESTIMATED FROM VALIDATION";
            estimateBadge.Foreground = Amber;
            AnimateProgress(fraction, true);
            etaTitle.Text = "Time remaining";
            etaValue.Text = FormatDuration(eta);
            etaHint.Text = "Preview completion around " + DateTime.Now.Add(eta).ToString("HH:mm", CultureInfo.CurrentCulture);
            filesValue.Text = FormatNumber(files);
            bytesValue.Text = FormatBytes(bytes);
            speedValue.Text = FormatBytes(bytes / Math.Max(1, elapsed.TotalSeconds)) + "/s";
            elapsedValue.Text = FormatDuration(elapsed);
            errorsValue.Text = "0";
            errorsValue.Foreground = PrimaryText;
            SetPhase(fraction < 0.9 ? 0 : fraction < 0.94 ? 1 : fraction < 0.97 ? 2 : 3, false);
            SetBadge("PREVIEW ANIMATION", Amber, BrushFrom("#3A2F18"));
            StartShimmer();
            StartStatusPulse();
            UpdateBackupButton(snapshot);
        }

        private void HandleStateTransition(TelemetrySnapshot snapshot)
        {
            // A status that cannot be read is no news. It raises no message of its own, and it is not a state that a run left or
            // entered: the first readable snapshot after it is compared with the last readable one. A run that was already
            // announced is therefore not announced again (a file that could not be read for a second used to end in a second
            // "Backup verified"), while a run that really changed in the meantime still is.
            if (snapshot.IsStatusUnavailable)
            {
                statusWasUnreadable = true;
                return;
            }
            bool afterUnreadable = statusWasUnreadable;
            statusWasUnreadable = false;
            string previousRunId = lastTransitionRunId;
            lastTransitionRunId = snapshot.RunId ?? string.Empty;
            // Read and updated on every readable call, including the first (a dashboard opened in the middle of a run did not
            // see it start) and the ones that return early below.
            bool wasActive = lastSnapshotWasActive;
            lastSnapshotWasActive = snapshot.IsActive;
            if (lastStateKey == null)
            {
                lastStateKey = snapshot.StateKey;
                return;
            }
            // The same state of another run, after a spell when the status could not be read, is news too: that run finished (or
            // failed) while nobody could see it.
            bool runChangedWhileUnreadable = afterUnreadable &&
                !string.Equals(previousRunId, lastTransitionRunId, StringComparison.Ordinal);
            if (string.Equals(lastStateKey, snapshot.StateKey, StringComparison.OrdinalIgnoreCase) &&
                !runChangedWhileUnreadable)
            {
                return;
            }

            DashboardVisualStyle.Emphasize(protectionHero);

            if (snapshot.IsActive)
            {
                // The state key is the run's phase (starting, backing up, verifying, checking...), so every step of one run
                // lands here. Only the step from "not running" to "running" is a backup starting; the steps inside a run, and
                // a cancel being carried out, have nothing new to announce.
                if (!wasActive)
                {
                    ShowTrayMessage("Backup started", "Restic is now protecting your files.", Forms.ToolTipIcon.Info);
                }
            }
            else if (snapshot.NeedsAnomalyReview)
            {
                ShowTrayMessage("Backup verified — review changes", snapshot.StatusDetail, Forms.ToolTipIcon.Warning);
            }
            else if (snapshot.AnomalyReviewAcknowledged)
            {
                ShowTrayMessage(
                    EngineProfile.Current.AnomalyReview.RecordedTitle,
                    EngineProfile.Current.AnomalyReview.TrayDetail,
                    Forms.ToolTipIcon.Info);
            }
            else if (snapshot.IsSuccess)
            {
                ShowTrayMessage("Backup verified", "Snapshot, storage check, and restore test completed.", Forms.ToolTipIcon.Info);
            }
            else if (snapshot.IsFailure)
            {
                ShowTrayMessage("Backup needs attention", snapshot.StatusDetail, Forms.ToolTipIcon.Error);
            }
            lastStateKey = snapshot.StateKey;
        }

        private void AnimateProgress(double fraction, bool animate)
        {
            currentProgress = Math.Max(0, Math.Min(1, fraction));
            if (progressTrack == null || progressFill == null || progressTrack.ActualWidth <= 0)
            {
                return;
            }
            double target = progressTrack.ActualWidth * currentProgress;
            if (!animate || !SourceMotionAllowed())
            {
                progressFill.BeginAnimation(FrameworkElement.WidthProperty, null);
                progressFill.Width = target;
                return;
            }
            DashboardVisualStyle.AnimateDouble(
                progressFill,
                FrameworkElement.WidthProperty,
                target,
                TimeSpan.FromMilliseconds(250),
                false);
        }

        private void StartShimmer()
        {
            if (!SourceMotionAllowed() ||
                shimmerTransform == null)
            {
                return;
            }
            DoubleAnimation animation = new DoubleAnimation();
            animation.From = -190;
            animation.To = 1250;
            animation.Duration = TimeSpan.FromSeconds(1.4);
            animation.RepeatBehavior = RepeatBehavior.Forever;
            shimmerTransform.BeginAnimation(TranslateTransform.XProperty, animation);
        }

        private void StopShimmer()
        {
            if (shimmerTransform != null)
            {
                shimmerTransform.BeginAnimation(TranslateTransform.XProperty, null);
            }
        }

        private void StartStatusPulse()
        {
            if (!SourceMotionAllowed() ||
                statusDot == null)
            {
                return;
            }
            DoubleAnimation pulse = new DoubleAnimation();
            pulse.From = 1;
            pulse.To = 0.55;
            pulse.AutoReverse = true;
            pulse.Duration = TimeSpan.FromMilliseconds(850);
            pulse.RepeatBehavior = RepeatBehavior.Forever;
            statusDot.BeginAnimation(UIElement.OpacityProperty, pulse, HandoffBehavior.SnapshotAndReplace);
        }

        private void StopStatusPulse()
        {
            if (statusDot != null)
            {
                statusDot.BeginAnimation(UIElement.OpacityProperty, null);
                statusDot.Opacity = 1;
            }
        }

        private void SetPhase(int activeIndex, bool failed)
        {
            for (int index = 0; index < phaseMarkers.Count; index++)
            {
                bool complete = index < activeIndex;
                bool active = index == activeIndex;
                phaseMarkers[index].Background = complete
                    ? Green
                    : active ? (failed ? Rose : Teal) : BrushFrom("#25334A");
                TextBlock number = phaseMarkers[index].Child as TextBlock;
                if (number != null)
                {
                    number.Foreground = active && failed
                        ? PrimaryText
                        : (complete || active) ? BrushFrom("#07131E") : MutedText;
                }
                phaseLabels[index].Foreground = active
                    ? failed ? Rose : PrimaryText
                    : complete ? Green : MutedText;
                phaseLabels[index].FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
            }
            if (activeIndex >= 0 && activeIndex < phaseMarkers.Count && activeIndex != lastAnimatedPhase)
            {
                DashboardVisualStyle.Emphasize(phaseMarkers[activeIndex]);
                DashboardVisualStyle.Emphasize(phaseLabels[activeIndex]);
                lastAnimatedPhase = activeIndex;
            }
        }

        private void SetBadge(string text, Brush dot, Brush background)
        {
            statusBadgeText.Text = text;
            statusDot.Fill = dot;
            statusBadge.Background = background;
        }

        private Forms.NotifyIcon BuildTrayIcon()
        {
            Forms.NotifyIcon icon = new Forms.NotifyIcon();
            try
            {
                trayApplicationIcon = Drawing.Icon.ExtractAssociatedIcon(
                    System.Reflection.Assembly.GetExecutingAssembly().Location);
            }
            catch (Exception)
            {
                trayApplicationIcon = null;
            }
            icon.Icon = trayApplicationIcon ?? Drawing.SystemIcons.Shield;
            icon.Text = "Rewindle";
            icon.Visible = true;
            Forms.ContextMenuStrip menu = new Forms.ContextMenuStrip();
            menu.Items.Add("Open Rewindle", null, delegate { Dispatcher.BeginInvoke(new Action(ShowDashboard)); });
            menu.Items.Add("Open app data folder", null, delegate { OpenDataFolder(); });
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("Exit Rewindle", null, delegate { Dispatcher.BeginInvoke(new Action(ExitApplication)); });
            icon.ContextMenuStrip = menu;
            // A single click on the icon opens the window, as it does for most tray apps; the right button keeps the menu. The
            // double click the icon always answered to asks for the same thing, and a double click raises the click first, so
            // both go to ShowDashboard, which does nothing new to a window that is already showing.
            icon.MouseClick += delegate(object clicked, Forms.MouseEventArgs click)
            {
                if (click.Button == Forms.MouseButtons.Left)
                {
                    Dispatcher.BeginInvoke(new Action(ShowDashboard));
                }
            };
            icon.DoubleClick += delegate { Dispatcher.BeginInvoke(new Action(ShowDashboard)); };
            return icon;
        }

        // The hover text says where the backup stands, so the person can see it without opening the window. It is set from the
        // refresh on the UI thread and only when it changes. NotifyIcon.Text throws for 64 characters or more.
        private const int MaximumTrayTextLength = 63;

        private void UpdateTrayText(TelemetrySnapshot snapshot)
        {
            try
            {
                if (trayIcon == null)
                {
                    return;
                }
                string text = DescribeTrayStatus(snapshot);
                if (text.Length > MaximumTrayTextLength)
                {
                    text = text.Substring(0, MaximumTrayTextLength - 1) + "…";
                }
                if (string.Equals(text, lastTrayText, StringComparison.Ordinal))
                {
                    return;
                }
                lastTrayText = text;
                trayIcon.Text = text;
            }
            catch (Exception)
            {
                // A hover text is never worth failing a refresh over.
            }
        }

        private string DescribeTrayStatus(TelemetrySnapshot snapshot)
        {
            const string prefix = "Rewindle - ";
            if (snapshot == null || snapshot.IsStatusUnavailable)
            {
                return prefix + "status unavailable";
            }
            if (string.Equals(snapshot.StateKey, "cancelling", StringComparison.OrdinalIgnoreCase))
            {
                return prefix + "stopping backup";
            }
            if (snapshot.IsActive)
            {
                double percent = Math.Max(0.0, Math.Min(1.0, snapshot.Percent)) * 100.0;
                return prefix + "backup running " +
                    Math.Round(percent, MidpointRounding.AwayFromZero).ToString("0", CultureInfo.CurrentCulture) + "%";
            }
            if (snapshot.IsFailure)
            {
                return prefix + "last backup needs attention";
            }
            if (snapshot.NeedsAnomalyReview)
            {
                return prefix + "review changes";
            }
            BackupFreshnessResult freshness = BackupFreshnessEvaluator.EvaluateNow(
                currentTaskSchedule,
                snapshot.LastVerifiedFinishedUtc,
                scheduleCoveredThroughUtc);
            string verified = snapshot.LastVerifiedFinishedUtc.HasValue
                ? "verified " + FormatTrayAge(DateTime.UtcNow - snapshot.LastVerifiedFinishedUtc.Value)
                : "no verified backup yet";
            switch (freshness.State)
            {
                case BackupFreshnessState.Overdue:
                    return prefix + "backup overdue, " + verified;
                case BackupFreshnessState.Paused:
                    return prefix + "backups paused, " + verified;
                case BackupFreshnessState.ClockAnomaly:
                    return prefix + "check the PC's clock";
                default:
                    return prefix + verified;
            }
        }

        // "just now", "5 min ago", "2 h ago", "3 days ago": short enough for the 63 characters the tray allows.
        private static string FormatTrayAge(TimeSpan age)
        {
            if (age.TotalMinutes < 1)
            {
                return "just now";
            }
            if (age.TotalHours < 1)
            {
                return ((int)age.TotalMinutes).ToString(CultureInfo.CurrentCulture) + " min ago";
            }
            if (age.TotalDays < 1)
            {
                return ((int)age.TotalHours).ToString(CultureInfo.CurrentCulture) + " h ago";
            }
            int days = (int)age.TotalDays;
            return days.ToString(CultureInfo.CurrentCulture) + (days == 1 ? " day ago" : " days ago");
        }

        private void ShowTrayMessage(string title, string message, Forms.ToolTipIcon icon)
        {
            trayIcon.BalloonTipTitle = title;
            trayIcon.BalloonTipText = message.Length > 220 ? message.Substring(0, 220) : message;
            trayIcon.BalloonTipIcon = icon;
            trayIcon.ShowBalloonTip(4500);
        }

        private void OpenDataFolder()
        {
            // Runs straight from the tray menu, outside the dispatcher's own error handling, where an exception would otherwise
            // surface as WinForms' own "Unhandled exception" box. Say what happened, in one box, and keep the details.
            try
            {
                string directory = EngineProfile.Current.DashboardDataDirectory();
                Directory.CreateDirectory(directory);
                // Quoted, so a profile folder with a space in its name is one argument and not two.
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "\"" + directory + "\"",
                    UseShellExecute = true
                });
            }
            catch (Exception error)
            {
                CrashLog.Write("Tray menu: open data folder", error);
                MessageBox.Show(
                    "Rewindle could not open its data folder in File Explorer.\n\n" + error.Message,
                    "Rewindle",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private void ShowDashboard()
        {
            // A click and the double click that follows it both end up here, and so does a second launch: a window that is
            // already on screen is brought forward but not faded in again (that would make its page blink).
            bool alreadyShowing = IsVisible && WindowState != WindowState.Minimized && !startupPlacementPending;
            // Wanted now, so a quiet start (--minimized) that has not finished loading must not hide it afterwards.
            hideAtLoad = false;
            if (startupPlacementPending)
            {
                // The quiet start parked the window outside the desktop and kept it from taking focus; this is the first time
                // it is wanted, so it takes its usual place (the middle of the work area) and takes focus like any other.
                startupPlacementPending = false;
                ShowActivated = true;
                Rect workArea = SystemParameters.WorkArea;
                double width = ActualWidth > 0 ? ActualWidth : Width;
                double height = ActualHeight > 0 ? ActualHeight : Height;
                Left = workArea.Left + Math.Max(0, (workArea.Width - width) / 2);
                Top = workArea.Top + Math.Max(0, (workArea.Height - height) / 2);
            }
            ShowInTaskbar = true;
            Show();
            if (WindowState == WindowState.Minimized)
            {
                WindowState = WindowState.Normal;
            }
            // A first tray launch can show the WPF shell before the WebView2
            // host has received visible bounds. Arrange it after Show().
            if (webPresentation != null)
            {
                Dispatcher.BeginInvoke(
                    DispatcherPriority.Render,
                    new Action(delegate
                    {
                        if (webPresentationClosing || !IsVisible)
                        {
                            return;
                        }
                        ApplyResponsiveLayout();
                        shellLayout.InvalidateMeasure();
                        shellLayout.InvalidateArrange();
                        webPresentation.InvalidateMeasure();
                        webPresentation.InvalidateArrange();
                        UpdateLayout();
                        webPresentation.UpdateLayout();
                    }));
            }
            Activate();
            Topmost = true;
            Topmost = false;
            Focus();
            if (!alreadyShowing)
            {
                DashboardVisualStyle.Reveal(
                    shellLayout,
                    DashboardVisualStyle.DefaultDuration,
                    TimeSpan.Zero,
                    0.0);
            }
        }

        private void HideToTray()
        {
            ShowInTaskbar = false;
            Hide();
        }

        private void ExitApplication()
        {
            if (cancellationRequestInProgress || cancellationAwaitingTerminal)
            {
                MessageBoxResult choice = MessageBox.Show(
                    this,
                    "Cancellation is still in progress. Closing Rewindle will not stop or reverse it; " +
                        "the protected backup task will continue handling the request.\n\nExit Rewindle?",
                    "Cancellation still in progress",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information,
                    MessageBoxResult.No);
                if (choice != MessageBoxResult.Yes)
                {
                    return;
                }
            }
            allowClose = true;
            Close();
            Application.Current.Shutdown();
        }

        private void OnClosing(object sender, CancelEventArgs args)
        {
            if (!allowClose)
            {
                args.Cancel = true;
                HideToTray();
                ShowFirstHideHint();
            }
        }

        // Closing the window sends it to the tray, which looks like the app quitting. The first time that happens (the marker is
        // kept with the theme preference, so a restart does not say it again) Rewindle says it is still running there and how to
        // quit it. Looked at once per process, so a window closed again does not touch the disk again.
        private void ShowFirstHideHint()
        {
            if (trayHintChecked)
            {
                return;
            }
            trayHintChecked = true;
            if (DashboardThemeManager.TryClaimTrayHint())
            {
                ShowTrayMessage(
                    "Rewindle is still running",
                    "Backups are monitored from the system tray. Choose Exit Rewindle from the tray menu to quit.",
                    Forms.ToolTipIcon.Info);
            }
        }

        private void OnClosed(object sender, EventArgs args)
        {
            // A restore approval session ends with the app (its broker also notices the closed channel and this process exiting).
            CloseRestoreFlowApprovalSession();
            DisposeWebPresentation();
            WriteHeartbeat(lastSnapshot, false);
            refreshTimer.Stop();
            StopShimmer();
            StopStatusPulse();
            StopSourceOperationAnimation();
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            SystemParameters.StaticPropertyChanged -= OnSystemParametersChanged;
            trayIcon.Visible = false;
            trayIcon.Dispose();
            if (trayApplicationIcon != null)
            {
                trayApplicationIcon.Dispose();
                trayApplicationIcon = null;
            }
            // The window is gone, and with it the tray icon, so nothing is left to bring it back: the process ends with it.
            // ExitApplication asks for the same thing right after Close, which makes this a second, harmless request. It
            // matters for a close that was let through without ExitApplication: a sign-out or shutdown that was then cancelled
            // leaves allowClose set (see the SessionEnding handler), and the next close would otherwise leave the application
            // running with no window, holding the single-instance mutex so that starting Rewindle again only signals it.
            if (Application.Current != null)
            {
                Application.Current.Shutdown();
            }
        }

        private Border CreateCard()
        {
            Border border = new Border();
            border.Background = CardBrush;
            border.BorderBrush = CardBorderBrush;
            border.BorderThickness = new Thickness(1);
            border.CornerRadius = new CornerRadius(10);
            return border;
        }

        private void WriteHeartbeat(TelemetrySnapshot snapshot, bool running)
        {
            if (options != null && options.UseIsolatedPresentationStore)
            {
                return;
            }
            DateTime now = DateTime.UtcNow;
            if (running && lastHeartbeatUtc != DateTime.MinValue && now - lastHeartbeatUtc < TimeSpan.FromSeconds(15))
            {
                return;
            }
            try
            {
                string directory = EngineProfile.Current.DashboardDataDirectory();
                Directory.CreateDirectory(directory);
                string path = System.IO.Path.Combine(directory, "heartbeat.json");
                string temporary = path + "." + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) + ".tmp";
                Dictionary<string, object> value = new Dictionary<string, object>();
                value["schema_version"] = 1;
                value["updated_utc"] = now.ToString("o", CultureInfo.InvariantCulture);
                value["running"] = running;
                value["pid"] = Process.GetCurrentProcess().Id;
                value["executable"] = Process.GetCurrentProcess().MainModule.FileName;
                value["version"] = GetType().Assembly.GetName().Version.ToString();
                value["elevated"] = false;
                value["state"] = snapshot == null ? "closing" : snapshot.StateKey;
                value["run_id"] = snapshot == null ? null : snapshot.RunId;
                File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(value));
                if (File.Exists(path))
                {
                    AtomicFile.ReplaceExisting(temporary, path);
                }
                else
                {
                    File.Move(temporary, path);
                }
                lastHeartbeatUtc = now;
            }
            catch
            {
                // The monitor remains useful even if its presentation cache is unavailable.
            }
        }

        private Button CreateButton(string label)
        {
            Button button = new Button();
            button.Content = label;
            button.Foreground = themeResolution.Palette.ButtonText;
            button.Background = themeResolution.Palette.ButtonBackground;
            button.BorderBrush = CardBorderBrush;
            button.BorderThickness = new Thickness(1);
            button.Padding = new Thickness(13, 7, 13, 7);
            button.FontSize = 12.5;
            button.FontWeight = FontWeights.Medium;
            button.MinHeight = 34;
            button.Cursor = Cursors.Hand;
            ToolTipService.SetShowOnDisabled(button, true);
            ApplyButtonChrome(button);
            AutomationProperties.SetName(button, label);
            DashboardVisualStyle.ApplyFocusOutline(button, themeResolution.Palette.Focus);
            return button;
        }

        private static void ApplyButtonChrome(Button button)
        {
            DashboardVisualStyle.ApplyButtonChrome(button, 8.0);
        }

        private static string FormatNumber(long value)
        {
            return value.ToString("N0", CultureInfo.CurrentCulture);
        }

        private static string FormatBytes(double value)
        {
            string[] units = { "B", "KiB", "MiB", "GiB", "TiB" };
            double amount = Math.Max(0, value);
            int index = 0;
            while (amount >= 1024 && index < units.Length - 1)
            {
                amount /= 1024;
                index++;
            }
            string format = index == 0 ? "0" : amount >= 100 ? "0" : amount >= 10 ? "0.0" : "0.00";
            return amount.ToString(format, CultureInfo.CurrentCulture) + " " + units[index];
        }

        private static string FormatDuration(TimeSpan duration)
        {
            if (duration.TotalHours >= 1)
            {
                return ((int)duration.TotalHours).ToString(CultureInfo.CurrentCulture) + "h " + duration.Minutes.ToString("00", CultureInfo.CurrentCulture) + "m";
            }
            if (duration.TotalMinutes >= 1)
            {
                return ((int)duration.TotalMinutes).ToString(CultureInfo.CurrentCulture) + "m " + duration.Seconds.ToString("00", CultureInfo.CurrentCulture) + "s";
            }
            return Math.Max(0, (int)duration.TotalSeconds).ToString(CultureInfo.CurrentCulture) + "s";
        }

        private Brush BrushFrom(string value)
        {
            return themeResolution.Palette.BrushForLegacy(value);
        }
    }

    internal static class ElementStyleHolder
    {
        public static void Apply(DataGridTextColumn column)
        {
            Style style = new Style(typeof(TextBlock));
            Binding foreground = new Binding("Foreground");
            foreground.RelativeSource = new RelativeSource(
                RelativeSourceMode.FindAncestor,
                typeof(DataGridRow),
                1);
            style.Setters.Add(new Setter(TextBlock.ForegroundProperty, foreground));
            style.Setters.Add(new Setter(TextBlock.FontSizeProperty, 12.0));
            style.Setters.Add(new Setter(TextBlock.VerticalAlignmentProperty, VerticalAlignment.Center));
            style.Setters.Add(new Setter(TextBlock.PaddingProperty, new Thickness(5, 0, 5, 0)));
            column.ElementStyle = style;
        }

        public static void SelectionBrushCompat(
            this DataGrid grid,
            Brush brush,
            Brush foreground,
            Brush selectedForeground)
        {
            Style rowStyle = new Style(typeof(DataGridRow));
            rowStyle.Setters.Add(new Setter(Control.ForegroundProperty, foreground));
            Trigger selected = new Trigger();
            selected.Property = DataGridRow.IsSelectedProperty;
            selected.Value = true;
            selected.Setters.Add(new Setter(Control.BackgroundProperty, brush));
            selected.Setters.Add(new Setter(Control.ForegroundProperty, selectedForeground));
            rowStyle.Triggers.Add(selected);
            grid.RowStyle = rowStyle;
        }
    }

}
