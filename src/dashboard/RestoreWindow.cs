using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace ResticBackuper.Dashboard
{
    internal sealed class RestoreWindow : Window
    {
        private readonly SourceConfiguration configuration;
        private readonly DashboardThemePalette palette;
        private DataGrid snapshotGrid;
        private DataGrid treeGrid;
        private TextBox treePathBox;
        private TextBox targetBox;
        private TextBox includesBox;
        private TextBlock statusTitle;
        private TextBlock statusDetail;
        private TextBlock selectedSnapshotDetail;
        private TextBlock snapshotCountText;
        private TextBlock treeSelectionSummary;
        private TextBlock targetValidationText;
        private ProgressBar progressBar;
        private Button refreshButton;
        private Button browseTreeButton;
        private Button upButton;
        private Button useSelectionButton;
        private Button chooseTargetButton;
        private Button restoreButton;
        private Button openTargetButton;
        private Button closeButton;
        private CheckBox wholeSnapshotCheckBox;
        private bool operationInProgress;
        private string completedTarget = string.Empty;
        private string selectedSnapshotId = string.Empty;
        private bool suppressSnapshotSelectionChange;
        private DispatcherTimer destinationValidationTimer;
        private int destinationValidationGeneration;
        private bool destinationValidationReady;
        private bool destinationValidationValid;
        private bool destinationValidationError;
        private string destinationValidationMessage = "Choose a new or empty folder before restoring.";

        private sealed class DestinationInspection
        {
            internal bool Valid;
            internal bool Error;
            internal string Message;
        }

        internal RestoreWindow(
            SourceConfiguration configuration,
            DashboardThemePalette palette)
        {
            if (configuration == null)
            {
                throw new ArgumentNullException("configuration");
            }
            if (palette == null)
            {
                throw new ArgumentNullException("palette");
            }
            this.configuration = configuration;
            this.palette = palette;
            Title = "Restore Center";
            Width = 1120;
            Height = 760;
            MinWidth = 920;
            MinHeight = 640;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            DashboardVisualStyle.ApplyWindow(this, palette);
            Content = BuildInterface();
            UpdateActionAffordance();
            DashboardVisualStyle.ApplyDialogEntrance(this);
            Loaded += OnLoaded;
            Closing += OnClosing;
        }

        private UIElement BuildInterface()
        {
            Grid root = new Grid();
            root.Margin = new Thickness(22, 18, 22, 18);
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(12) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(12) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(14) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            Grid header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel heading = new StackPanel();
            TextBlock title = CreateText("Restore Center", 25, palette.TextPrimary, FontWeights.SemiBold);
            heading.Children.Add(title);
            TextBlock subtitle = CreateText(
                "Browse plan-bound and safely matched legacy snapshots, then restore to a separate verified destination.",
                12,
                palette.TextSecondary,
                FontWeights.Normal);
            subtitle.Margin = new Thickness(0, 3, 0, 0);
            heading.Children.Add(subtitle);
            header.Children.Add(heading);
            refreshButton = CreateButton("Refresh snapshots", false);
            refreshButton.MinWidth = 132;
            refreshButton.VerticalAlignment = VerticalAlignment.Center;
            refreshButton.Click += async delegate { await LoadSnapshots(); };
            Grid.SetColumn(refreshButton, 1);
            header.Children.Add(refreshButton);
            root.Children.Add(header);

            Border statusCard = CreateCard();
            statusCard.Padding = new Thickness(16, 12, 16, 12);
            Grid statusLayout = new Grid();
            statusLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            statusLayout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(230) });
            StackPanel statusCopy = new StackPanel();
            statusTitle = CreateText("Ready to read snapshot history", 14, palette.TextPrimary, FontWeights.SemiBold);
            statusCopy.Children.Add(statusTitle);
            statusDetail = CreateText(
                "Windows approval protects repository access. Reading snapshots does not change them.",
                11,
                palette.TextSecondary,
                FontWeights.Normal);
            statusDetail.Margin = new Thickness(0, 3, 0, 0);
            statusDetail.TextWrapping = TextWrapping.Wrap;
            statusCopy.Children.Add(statusDetail);
            statusLayout.Children.Add(statusCopy);
            progressBar = new ProgressBar();
            progressBar.Height = 8;
            progressBar.Minimum = 0;
            progressBar.Maximum = 100;
            progressBar.Visibility = Visibility.Collapsed;
            progressBar.VerticalAlignment = VerticalAlignment.Center;
            progressBar.Foreground = palette.AccentPrimary;
            progressBar.Background = palette.ProgressTrack;
            Grid.SetColumn(progressBar, 1);
            statusLayout.Children.Add(progressBar);
            statusCard.Child = statusLayout;
            Grid.SetRow(statusCard, 2);
            root.Children.Add(statusCard);

            Grid workspace = new Grid();
            workspace.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.92, GridUnitType.Star) });
            workspace.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
            workspace.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.08, GridUnitType.Star) });
            workspace.Children.Add(BuildSnapshotCard());
            UIElement restoreCard = BuildRestoreCard();
            Grid.SetColumn(restoreCard, 2);
            workspace.Children.Add(restoreCard);
            Grid.SetRow(workspace, 4);
            root.Children.Add(workspace);

            Grid footer = new Grid();
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock safety = CreateText(
                "Safety contract: exact snapshot · new or empty target · never overwrite · verify after restore",
                11,
                palette.SafetyText,
                FontWeights.SemiBold);
            safety.VerticalAlignment = VerticalAlignment.Center;
            safety.TextWrapping = TextWrapping.Wrap;
            footer.Children.Add(safety);
            StackPanel footerActions = new StackPanel { Orientation = Orientation.Horizontal };
            openTargetButton = CreateButton("Open restored folder", false);
            openTargetButton.Visibility = Visibility.Collapsed;
            openTargetButton.Click += OnOpenTargetClick;
            footerActions.Children.Add(openTargetButton);
            closeButton = CreateButton("Close", false);
            closeButton.Margin = new Thickness(8, 0, 0, 0);
            closeButton.Click += delegate { Close(); };
            footerActions.Children.Add(closeButton);
            Grid.SetColumn(footerActions, 1);
            footer.Children.Add(footerActions);
            Grid.SetRow(footer, 6);
            root.Children.Add(footer);
            AutomationProperties.SetName(root, "Protected snapshot restore center");
            return root;
        }

        private UIElement BuildSnapshotCard()
        {
            Border card = CreateCard();
            card.Padding = new Thickness(16, 14, 16, 14);
            Grid layout = new Grid();
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(8) });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            StackPanel heading = new StackPanel();
            heading.Children.Add(CreateText("Snapshots", 17, palette.TextPrimary, FontWeights.SemiBold));
            TextBlock hint = CreateText(
                "Plan generations and exact configuration-matched legacy snapshots, newest first",
                11,
                palette.TextSecondary,
                FontWeights.Normal);
            hint.Margin = new Thickness(0, 2, 0, 0);
            heading.Children.Add(hint);
            snapshotCountText = CreateText(
                "Select one exact snapshot to begin.",
                11,
                palette.AccentInfoText,
                FontWeights.SemiBold);
            snapshotCountText.Margin = new Thickness(0, 7, 0, 0);
            heading.Children.Add(snapshotCountText);
            layout.Children.Add(heading);

            snapshotGrid = CreateGrid();
            snapshotGrid.SelectionMode = DataGridSelectionMode.Single;
            snapshotGrid.SelectionChanged += OnSnapshotSelectionChanged;
            snapshotGrid.KeyDown += OnSnapshotGridKeyDown;
            snapshotGrid.RowHeight = 36;
            snapshotGrid.Columns.Add(CreateColumn("When", "WhenDisplay", 1.35));
            snapshotGrid.Columns.Add(CreateColumn("ID", "ShortId", 0.75));
            snapshotGrid.Columns.Add(CreateColumn("Binding", "GenerationDisplay", 1.0));
            snapshotGrid.Columns.Add(CreateColumn("Data", "SizeDisplay", 0.75));
            Grid.SetRow(snapshotGrid, 2);
            layout.Children.Add(snapshotGrid);

            selectedSnapshotDetail = CreateText(
                "Select a snapshot to browse or restore.",
                11,
                palette.TextSecondary,
                FontWeights.Normal);
            selectedSnapshotDetail.Margin = new Thickness(0, 10, 0, 0);
            selectedSnapshotDetail.TextWrapping = TextWrapping.Wrap;
            Grid.SetRow(selectedSnapshotDetail, 3);
            layout.Children.Add(selectedSnapshotDetail);
            card.Child = layout;
            return card;
        }

        private UIElement BuildRestoreCard()
        {
            Border card = CreateCard();
            card.Padding = new Thickness(16, 14, 16, 14);
            Grid layout = new Grid();
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(10) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(8) });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(10) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(8) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.Children.Add(CreateText("Browse and restore", 17, palette.TextPrimary, FontWeights.SemiBold));

            Grid browserControls = new Grid();
            browserControls.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            browserControls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            browserControls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            treePathBox = CreateTextBox("/");
            AutomationProperties.SetName(treePathBox, "Snapshot folder path");
            AutomationProperties.SetHelpText(
                treePathBox,
                "Enter a slash-prefixed snapshot path and press Enter to browse.");
            treePathBox.ToolTip = "Press Enter to browse this snapshot folder.";
            treePathBox.KeyDown += async delegate(object sender, KeyEventArgs args)
            {
                if (args.Key == Key.Enter || args.Key == Key.Return)
                {
                    args.Handled = true;
                    await LoadTree();
                }
            };
            browserControls.Children.Add(treePathBox);
            upButton = CreateButton("Up", false);
            upButton.Margin = new Thickness(6, 0, 0, 0);
            upButton.Click += OnUpClick;
            Grid.SetColumn(upButton, 1);
            browserControls.Children.Add(upButton);
            browseTreeButton = CreateButton("Browse", false);
            browseTreeButton.Margin = new Thickness(6, 0, 0, 0);
            browseTreeButton.Click += async delegate { await LoadTree(); };
            Grid.SetColumn(browseTreeButton, 2);
            browserControls.Children.Add(browseTreeButton);
            Grid.SetRow(browserControls, 2);
            layout.Children.Add(browserControls);

            treeGrid = CreateGrid();
            treeGrid.SelectionMode = DataGridSelectionMode.Extended;
            treeGrid.MouseDoubleClick += OnTreeDoubleClick;
            treeGrid.SelectionChanged += OnTreeSelectionChanged;
            treeGrid.RowHeight = 34;
            treeGrid.Columns.Add(CreateColumn("Name", "Name", 1.35));
            treeGrid.Columns.Add(CreateColumn("Type", "EntryType", 0.55));
            treeGrid.Columns.Add(CreateColumn("Size", "SizeDisplay", 0.65));
            Grid.SetRow(treeGrid, 4);
            layout.Children.Add(treeGrid);

            Grid selectionControls = new Grid();
            selectionControls.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            selectionControls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel includesPanel = new StackPanel();
            includesPanel.Children.Add(CreateText(
                "Restore scope",
                11,
                palette.TextSecondary,
                FontWeights.SemiBold));
            includesBox = CreateTextBox(string.Empty);
            includesBox.AcceptsReturn = true;
            includesBox.Height = 58;
            includesBox.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            includesBox.Margin = new Thickness(0, 4, 0, 0);
            AutomationProperties.SetName(includesBox, "Paths to restore, one per line");
            AutomationProperties.SetHelpText(
                includesBox,
                "Optional selected paths, one per line, up to 64 paths. Choose the entire snapshot explicitly below for a full restore.");
            includesBox.ToolTip = "Use one snapshot path per line, or explicitly choose the entire snapshot below.";
            includesPanel.Children.Add(includesBox);
            treeSelectionSummary = CreateText(
                "No snapshot entries selected.",
                11,
                palette.TextTertiary,
                FontWeights.Normal);
            treeSelectionSummary.Margin = new Thickness(0, 5, 0, 0);
            includesPanel.Children.Add(treeSelectionSummary);
            wholeSnapshotCheckBox = new CheckBox();
            wholeSnapshotCheckBox.Content = "Restore the entire snapshot";
            wholeSnapshotCheckBox.Foreground = palette.TextSecondary;
            wholeSnapshotCheckBox.Margin = new Thickness(0, 8, 0, 0);
            wholeSnapshotCheckBox.ToolTip = "Explicitly choose the whole immutable snapshot. An empty path list alone is not enough to start a restore.";
            AutomationProperties.SetName(wholeSnapshotCheckBox, "Restore the entire snapshot");
            AutomationProperties.SetHelpText(
                wholeSnapshotCheckBox,
                "Select this explicitly to restore every path in the selected snapshot.");
            wholeSnapshotCheckBox.Checked += delegate
            {
                includesBox.Text = string.Empty;
                treeSelectionSummary.Text = "Entire snapshot selected explicitly.";
                treeSelectionSummary.Foreground = palette.Success;
                UpdateActionAffordance();
            };
            wholeSnapshotCheckBox.Unchecked += delegate
            {
                if (string.IsNullOrWhiteSpace(includesBox.Text))
                {
                    treeSelectionSummary.Text = "No snapshot entries selected.";
                    treeSelectionSummary.Foreground = palette.TextTertiary;
                }
                UpdateActionAffordance();
            };
            includesBox.TextChanged += delegate
            {
                if (!string.IsNullOrWhiteSpace(includesBox.Text) &&
                    wholeSnapshotCheckBox.IsChecked == true)
                {
                    wholeSnapshotCheckBox.IsChecked = false;
                }
            };
            includesPanel.Children.Add(wholeSnapshotCheckBox);
            selectionControls.Children.Add(includesPanel);
            useSelectionButton = CreateButton("Use selection", false);
            useSelectionButton.Margin = new Thickness(8, 20, 0, 0);
            useSelectionButton.VerticalAlignment = VerticalAlignment.Top;
            useSelectionButton.Click += OnUseSelectionClick;
            Grid.SetColumn(useSelectionButton, 1);
            selectionControls.Children.Add(useSelectionButton);
            Grid.SetRow(selectionControls, 6);
            layout.Children.Add(selectionControls);

            Grid destination = new Grid();
            destination.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            destination.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel destinationCopy = new StackPanel();
            destinationCopy.Children.Add(CreateText(
                "New or empty destination folder",
                11,
                palette.TextSecondary,
                FontWeights.SemiBold));
            targetBox = CreateTextBox(string.Empty);
            targetBox.Margin = new Thickness(0, 4, 0, 0);
            AutomationProperties.SetName(targetBox, "Restore destination folder");
            AutomationProperties.SetHelpText(
                targetBox,
                "The destination must be a new or empty folder. Existing files are never overwritten.");
            targetBox.ToolTip = "New or empty folder only. Existing files are never overwritten.";
            destinationValidationTimer = new DispatcherTimer(DispatcherPriority.Background)
            {
                Interval = TimeSpan.FromMilliseconds(300)
            };
            destinationValidationTimer.Tick += delegate
            {
                destinationValidationTimer.Stop();
                BeginDestinationValidation();
            };
            targetBox.TextChanged += delegate { ScheduleDestinationValidation(); };
            targetBox.LostKeyboardFocus += delegate
            {
                if (destinationValidationTimer != null)
                {
                    destinationValidationTimer.Stop();
                }
                BeginDestinationValidation();
            };
            destinationCopy.Children.Add(targetBox);
            targetValidationText = CreateText(
                "Choose a new or empty folder before restoring.",
                11,
                palette.TextTertiary,
                FontWeights.Normal);
            targetValidationText.Margin = new Thickness(0, 5, 0, 0);
            targetValidationText.TextWrapping = TextWrapping.Wrap;
            destinationCopy.Children.Add(targetValidationText);
            destination.Children.Add(destinationCopy);
            chooseTargetButton = CreateButton("Choose folder", false);
            chooseTargetButton.Margin = new Thickness(8, 20, 0, 0);
            chooseTargetButton.VerticalAlignment = VerticalAlignment.Top;
            chooseTargetButton.Click += OnChooseTargetClick;
            Grid.SetColumn(chooseTargetButton, 1);
            destination.Children.Add(chooseTargetButton);
            Grid.SetRow(destination, 8);
            layout.Children.Add(destination);

            restoreButton = CreateButton("Restore and verify", true);
            restoreButton.HorizontalAlignment = HorizontalAlignment.Right;
            restoreButton.MinWidth = 144;
            restoreButton.Margin = new Thickness(0, 10, 0, 0);
            restoreButton.Click += async delegate { await RestoreSelectedSnapshot(); };
            Grid.SetRow(restoreButton, 9);
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.Children.Add(restoreButton);
            card.Child = layout;
            return card;
        }

        private async void OnLoaded(object sender, RoutedEventArgs args)
        {
            await LoadSnapshots();
        }

        private async Task LoadSnapshots()
        {
            if (operationInProgress)
            {
                return;
            }
            RestoreSnapshot previousSnapshot = snapshotGrid.SelectedItem as RestoreSnapshot;
            if (previousSnapshot != null)
            {
                selectedSnapshotId = previousSnapshot.Id;
            }
            else if (string.IsNullOrWhiteSpace(selectedSnapshotId))
            {
                selectedSnapshotId = string.Empty;
            }
            SetBusy(true, "Waiting for Windows approval", "Repository access is protected.", null);
            RestoreManagerResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return RestoreManagerLauncher.ListSnapshots(
                        configuration,
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                SetBusy(true, "Reading snapshots", "Loading this backup plan's history.", null);
                            }));
                        },
                        OnProtectedProgress);
                });
            }
            catch (Exception error)
            {
                result = RestoreManagerResult.Failure(error.Message, -1);
            }
            if (result.UserCancelled)
            {
                SetBusy(false, "Windows approval cancelled", "No repository data was read.", false);
                return;
            }
            if (!result.Succeeded)
            {
                snapshotCountText.Text = "Snapshot history could not be loaded.";
                SetBusy(false, "Snapshots unavailable", result.ErrorMessage, false);
                return;
            }
            suppressSnapshotSelectionChange = true;
            snapshotGrid.ItemsSource = result.Snapshots;
            snapshotCountText.Text = result.Snapshots.Count == 0
                ? "No exact snapshots matched this protected backup plan."
                : result.Snapshots.Count.ToString() + " exact snapshot" +
                    (result.Snapshots.Count == 1 ? string.Empty : "s") +
                    " available · select one to browse its files.";
            int legacyCount = 0;
            foreach (RestoreSnapshot snapshot in result.Snapshots)
            {
                if (snapshot.IsLegacyUnbound)
                {
                    legacyCount++;
                }
            }
            if (result.Snapshots.Count > 0)
            {
                RestoreSnapshot matchingSnapshot = null;
                foreach (RestoreSnapshot candidate in result.Snapshots)
                {
                    if (!string.IsNullOrWhiteSpace(selectedSnapshotId) &&
                        string.Equals(candidate.Id, selectedSnapshotId, StringComparison.OrdinalIgnoreCase))
                    {
                        matchingSnapshot = candidate;
                        break;
                    }
                }
                snapshotGrid.SelectedItem = matchingSnapshot ?? result.Snapshots[0];
                RestoreSnapshot activeSnapshot = snapshotGrid.SelectedItem as RestoreSnapshot;
                selectedSnapshotId = activeSnapshot == null ? string.Empty : activeSnapshot.Id;
            }
            suppressSnapshotSelectionChange = false;
            OnSnapshotSelectionChanged(snapshotGrid, null);
            if (result.Snapshots.Count == 0)
            {
                selectedSnapshotId = string.Empty;
                SetBusy(
                    false,
                    "No matching snapshots found",
                    "No plan-bound or exact configuration-matched legacy snapshots are available.",
                    null);
                statusTitle.Foreground = palette.TextSecondary;
            }
            else if (legacyCount > 0)
            {
                int planCount = result.Snapshots.Count - legacyCount;
                string detail = planCount == 0
                    ? legacyCount.ToString() +
                        " legacy / unbound snapshots matched this repository, computer, scheduled tag, and exact source set."
                    : planCount.ToString() + " plan-bound and " + legacyCount.ToString() +
                        " legacy / unbound snapshots are available.";
                SetBusy(false, "Snapshots ready - legacy history included", detail, true);
                statusTitle.Foreground = palette.Warning;
            }
            else
            {
                SetBusy(
                    false,
                    "Snapshots ready",
                    result.Snapshots.Count.ToString() + " plan-bound snapshots are available to browse.",
                    true);
            }
        }

        private async Task LoadTree()
        {
            RestoreSnapshot snapshot = snapshotGrid.SelectedItem as RestoreSnapshot;
            if (snapshot == null || operationInProgress)
            {
                SetBusy(false, "Choose a snapshot", "Select one snapshot before browsing files.", false);
                return;
            }
            string path = (treePathBox.Text ?? string.Empty).Trim();
            if (path.Length == 0)
            {
                path = "/";
            }
            SetBusy(true, "Waiting for Windows approval", "Preparing the protected snapshot browser.", null);
            RestoreManagerResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return RestoreManagerLauncher.ListTree(
                        configuration,
                        snapshot.Id,
                        path,
                        snapshot.IsLegacyUnbound,
                        null,
                        OnProtectedProgress);
                });
            }
            catch (Exception error)
            {
                result = RestoreManagerResult.Failure(error.Message, -1);
            }
            if (result.UserCancelled)
            {
                SetBusy(false, "Windows approval cancelled", "The snapshot folder was not read.", false);
                return;
            }
            if (!result.Succeeded)
            {
                SetBusy(false, "Folder unavailable", result.ErrorMessage, false);
                return;
            }
            treeGrid.ItemsSource = result.Entries;
            treeGrid.SelectedItems.Clear();
            treeSelectionSummary.Text = result.Entries.Count == 0
                ? "This snapshot folder is empty."
                : "Select files or folders, then use selection below.";
            treeSelectionSummary.Foreground = result.Entries.Count == 0
                ? palette.TextTertiary
                : palette.TextSecondary;
            SetBusy(
                false,
                "Snapshot folder ready",
                result.Entries.Count.ToString() + " entries loaded from " + path + ".",
                true);
        }

        private async Task RestoreSelectedSnapshot()
        {
            RestoreSnapshot snapshot = snapshotGrid.SelectedItem as RestoreSnapshot;
            if (snapshot == null || operationInProgress)
            {
                SetBusy(false, "Choose a snapshot", "Select one immutable snapshot first.", false);
                return;
            }
            string target;
            try
            {
                string rawTarget = (targetBox.Text ?? string.Empty).Trim();
                if (!IsAbsoluteLocalPathInput(rawTarget))
                {
                    throw new InvalidDataException("The restore destination must be an absolute local path.");
                }
                target = SourceConfiguration.NormalizePath(rawTarget);
                DestinationInspection destinationInspection = InspectDestination(target);
                if (!destinationInspection.Valid)
                {
                    throw new InvalidDataException(destinationInspection.Message);
                }
                if (File.Exists(target))
                {
                    throw new InvalidDataException("The restore destination must be a folder, not an existing file.");
                }
                if (Directory.Exists(target) && Directory.EnumerateFileSystemEntries(target).Any())
                {
                    throw new InvalidDataException("The restore destination must be empty.");
                }
            }
            catch (Exception error)
            {
                SetBusy(false, "Choose a safe destination", error.Message, false);
                return;
            }
            IList<string> includes;
            try
            {
                includes = ParseIncludes(includesBox.Text);
            }
            catch (Exception error)
            {
                SetBusy(false, "Review selected paths", error.Message, false);
                return;
            }
            bool wholeSnapshot = wholeSnapshotCheckBox != null &&
                wholeSnapshotCheckBox.IsChecked == true;
            if (includes.Count == 0 && !wholeSnapshot)
            {
                SetBusy(
                    false,
                    "Choose a restore scope",
                    "Select one or more snapshot entries, or explicitly choose Restore the entire snapshot.",
                    false);
                return;
            }
            string scope = includes.Count == 0
                ? "the entire snapshot"
                : includes.Count.ToString() + " selected path(s)";
            if (snapshot.IsLegacyUnbound)
            {
                MessageBoxResult legacyConfirmation = MessageBox.Show(
                    this,
                    "This snapshot predates backup plan IDs and is labelled Legacy / unbound.\n\n" +
                    "It matched this repository, computer, scheduled tag, and exact source-path set, " +
                    "but it is not bound to the current plan ID.\n\n" +
                    "Exact immutable snapshot ID:\n" + snapshot.Id +
                    "\n\nContinue with this legacy snapshot?",
                    "Confirm legacy / unbound snapshot",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Warning);
                if (legacyConfirmation != MessageBoxResult.Yes)
                {
                    return;
                }
            }
            MessageBoxResult confirmation = MessageBox.Show(
                this,
                "Restore " + scope + " to:\n\n" + target +
                "\n\nLive files and the repository will not be overwritten. " +
                "If Restic stops, partial files remain in this alternate folder for inspection.",
                "Restore and verify",
                MessageBoxButton.OKCancel,
                MessageBoxImage.Information);
            if (confirmation != MessageBoxResult.OK)
            {
                return;
            }
            completedTarget = string.Empty;
            openTargetButton.Visibility = Visibility.Collapsed;
            SetBusy(true, "Waiting for Windows approval", "The restore will write only to the alternate destination.", null);
            RestoreManagerResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return RestoreManagerLauncher.Restore(
                        configuration,
                        snapshot.Id,
                        target,
                        includes,
                        snapshot.IsLegacyUnbound,
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                SetBusy(true, "Restore approved", "Restoring and verifying the selected snapshot.", null);
                            }));
                        },
                        OnProtectedProgress);
                });
            }
            catch (Exception error)
            {
                result = RestoreManagerResult.Failure(error.Message, -1);
            }
            if (result.UserCancelled)
            {
                SetBusy(false, "Windows approval cancelled", "No restore was started.", false);
                return;
            }
            if (result.Succeeded && result.Report != null && result.Report.Verified)
            {
                completedTarget = result.Report.Target;
                openTargetButton.Visibility = Visibility.Visible;
                SetBusy(
                    false,
                    "Restore complete and verified",
                    "The restored copy is ready at " + result.Report.Target + ".",
                    true);
                return;
            }
            if (result.Partial && result.Report != null)
            {
                completedTarget = result.Report.Target;
                openTargetButton.Visibility = Directory.Exists(completedTarget)
                    ? Visibility.Visible
                    : Visibility.Collapsed;
                SetBusy(
                    false,
                    "Restore incomplete — partial files retained",
                    result.ErrorMessage + " Inspect the alternate destination; live files were not changed.",
                    false);
                return;
            }
            SetBusy(false, "Restore did not start", result.ErrorMessage, false);
        }

        private void OnProtectedProgress(RestoreManagerProgress progress)
        {
            if (progress == null)
            {
                return;
            }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                if (!operationInProgress)
                {
                    return;
                }
                statusTitle.Text = FriendlyStage(progress.Stage);
                statusDetail.Text = progress.Message;
                bool indeterminate = progress.Percent <= 5 ||
                    string.Equals(progress.Stage, "restoring", StringComparison.Ordinal);
                DashboardVisualStyle.SetBusy(progressBar, indeterminate);
                if (!indeterminate)
                {
                    DashboardVisualStyle.AnimateProgressValue(progressBar, progress.Percent);
                }
            }), DispatcherPriority.Background);
        }

        private void SetBusy(
            bool busy,
            string title,
            string detail,
            bool? success)
        {
            operationInProgress = busy;
            statusTitle.Text = title ?? string.Empty;
            statusDetail.Text = detail ?? string.Empty;
            statusTitle.Foreground = success.HasValue
                ? (success.Value ? palette.Success : palette.Danger)
                : palette.TextPrimary;
            bool wasVisible = progressBar.Visibility == Visibility.Visible;
            progressBar.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            DashboardVisualStyle.SetBusy(progressBar, busy);
            if (busy && !wasVisible)
            {
                DashboardVisualStyle.Reveal(
                    progressBar,
                    DashboardVisualStyle.DefaultDuration,
                    TimeSpan.Zero,
                    0.0);
            }
            refreshButton.IsEnabled = !busy;
            browseTreeButton.IsEnabled = !busy;
            upButton.IsEnabled = !busy;
            useSelectionButton.IsEnabled = !busy;
            chooseTargetButton.IsEnabled = !busy;
            restoreButton.IsEnabled = !busy && snapshotGrid.SelectedItem is RestoreSnapshot;
            closeButton.IsEnabled = !busy;
            snapshotGrid.IsEnabled = !busy;
            treeGrid.IsEnabled = !busy;
            targetBox.IsEnabled = !busy;
            includesBox.IsEnabled = !busy;
            AutomationProperties.SetName(statusTitle, title + ". " + detail);
            AutomationProperties.SetLiveSetting(
                statusTitle,
                success.HasValue && !success.Value
                    ? AutomationLiveSetting.Assertive
                    : AutomationLiveSetting.Polite);
            UpdateActionAffordance();
        }

        private void UpdateActionAffordance()
        {
            if (snapshotGrid == null || treeGrid == null || targetBox == null ||
                targetValidationText == null || restoreButton == null)
            {
                return;
            }

            bool busy = operationInProgress;
            bool hasSnapshot = snapshotGrid.SelectedItem is RestoreSnapshot;
            bool hasTreeSelection = treeGrid.SelectedItems.Count > 0;
            browseTreeButton.IsEnabled = !busy && hasSnapshot;
            upButton.IsEnabled = !busy && hasSnapshot;
            treePathBox.IsEnabled = !busy && hasSnapshot;
            useSelectionButton.IsEnabled = !busy && hasTreeSelection;
            restoreButton.IsEnabled = !busy && hasSnapshot &&
                destinationValidationReady && destinationValidationValid;
            targetValidationText.Text = destinationValidationMessage;
            targetValidationText.Foreground = destinationValidationError
                ? palette.Danger
                : destinationValidationValid
                    ? palette.Success
                    : palette.TextTertiary;
        }

        private void ScheduleDestinationValidation()
        {
            destinationValidationGeneration++;
            destinationValidationReady = false;
            destinationValidationValid = false;
            destinationValidationError = false;
            string rawTarget = (targetBox == null ? string.Empty : targetBox.Text ?? string.Empty).Trim();
            if (rawTarget.Length == 0)
            {
                destinationValidationReady = true;
                destinationValidationMessage = "Choose a new or empty folder before restoring.";
            }
            else if (!IsAbsoluteLocalPathInput(rawTarget))
            {
                destinationValidationReady = true;
                destinationValidationError = true;
                destinationValidationMessage =
                    "Use an absolute local path, such as C:\\Restores\\2026-09-13.";
            }
            else
            {
                destinationValidationMessage = "Checking that this destination is a new or empty folder…";
                if (destinationValidationTimer != null)
                {
                    destinationValidationTimer.Stop();
                    destinationValidationTimer.Start();
                }
            }
            UpdateActionAffordance();
        }

        private async void BeginDestinationValidation()
        {
            if (targetBox == null)
            {
                return;
            }
            string rawTarget = (targetBox.Text ?? string.Empty).Trim();
            int generation = destinationValidationGeneration;
            if (rawTarget.Length == 0 || !IsAbsoluteLocalPathInput(rawTarget))
            {
                ScheduleDestinationValidation();
                return;
            }

            string normalizedTarget;
            try
            {
                // Normalize only after the raw value has passed the absolute-local-path check.
                normalizedTarget = SourceConfiguration.NormalizePath(rawTarget);
            }
            catch (Exception error)
            {
                ApplyDestinationInspection(
                    generation,
                    rawTarget,
                    new DestinationInspection
                    {
                        Valid = false,
                        Error = true,
                        Message = "The destination path is invalid: " + error.Message
                    });
                return;
            }

            destinationValidationReady = false;
            destinationValidationValid = false;
            destinationValidationError = false;
            destinationValidationMessage = "Checking that this destination is a new or empty folder…";
            UpdateActionAffordance();
            DestinationInspection inspection;
            try
            {
                inspection = await Task.Run(delegate
                {
                    return InspectDestination(normalizedTarget);
                });
            }
            catch (Exception error)
            {
                inspection = new DestinationInspection
                {
                    Valid = false,
                    Error = true,
                    Message = "Cannot inspect this destination yet: " + error.Message
                };
            }
            ApplyDestinationInspection(generation, rawTarget, inspection);
        }

        private void ApplyDestinationInspection(
            int generation,
            string rawTarget,
            DestinationInspection inspection)
        {
            if (generation != destinationValidationGeneration ||
                !string.Equals(
                    rawTarget,
                    (targetBox.Text ?? string.Empty).Trim(),
                    StringComparison.Ordinal))
            {
                return;
            }
            destinationValidationReady = true;
            destinationValidationValid = inspection != null && inspection.Valid;
            destinationValidationError = inspection != null && inspection.Error;
            destinationValidationMessage = inspection == null
                ? "Cannot inspect this destination yet."
                : inspection.Message;
            UpdateActionAffordance();
        }

        private static DestinationInspection InspectDestination(string normalizedTarget)
        {
            try
            {
                if (!HasNormalDestinationDirectoryChain(normalizedTarget))
                {
                    return new DestinationInspection
                    {
                        Valid = false,
                        Error = true,
                        Message = "This destination uses a reparse point or link. Choose a normal local folder."
                    };
                }
                string root = Path.GetPathRoot(normalizedTarget);
                DriveInfo drive = new DriveInfo(root);
                if (!drive.IsReady ||
                    (drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable))
                {
                    return new DestinationInspection
                    {
                        Valid = false,
                        Error = true,
                        Message = "The destination must be on a ready local fixed or removable drive."
                    };
                }
                if (File.Exists(normalizedTarget))
                {
                    return new DestinationInspection
                    {
                        Valid = false,
                        Error = true,
                        Message = "This path is an existing file. Choose a folder; existing files are never overwritten."
                    };
                }
                if (Directory.Exists(normalizedTarget) &&
                    Directory.EnumerateFileSystemEntries(normalizedTarget).Any())
                {
                    return new DestinationInspection
                    {
                        Valid = false,
                        Error = true,
                        Message = "This folder is not empty. Choose an empty folder; existing files are never overwritten."
                    };
                }
                return new DestinationInspection
                {
                    Valid = true,
                    Error = false,
                    Message = Directory.Exists(normalizedTarget)
                        ? "Ready · existing folder is empty. Existing files will not be overwritten."
                        : "Ready · this new folder will be used as the alternate restore destination."
                };
            }
            catch (Exception error)
            {
                return new DestinationInspection
                {
                    Valid = false,
                    Error = true,
                    Message = "Cannot inspect this destination yet: " + error.Message
                };
            }
        }

        private static bool IsAbsoluteLocalPathInput(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return false;
            }
            string trimmed = value.Trim();
            if (trimmed.StartsWith("\\\\", StringComparison.Ordinal))
            {
                return false;
            }
            return trimmed.Length >= 3 &&
                char.IsLetter(trimmed[0]) &&
                trimmed[1] == ':' &&
                (trimmed[2] == '\\' || trimmed[2] == '/');
        }

        private static bool HasNormalDestinationDirectoryChain(string path)
        {
            try
            {
                DirectoryInfo current = new DirectoryInfo(path);
                while (current != null)
                {
                    if (current.Exists &&
                        (current.Attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        return false;
                    }
                    current = current.Parent;
                }
                return true;
            }
            catch
            {
                return false;
            }
        }

        private void OnSnapshotSelectionChanged(object sender, SelectionChangedEventArgs args)
        {
            if (suppressSnapshotSelectionChange)
            {
                return;
            }
            RestoreSnapshot snapshot = snapshotGrid.SelectedItem as RestoreSnapshot;
            selectedSnapshotId = snapshot == null ? string.Empty : snapshot.Id;
            treeGrid.ItemsSource = null;
            treePathBox.Text = "/";
            includesBox.Text = string.Empty;
            if (wholeSnapshotCheckBox != null)
            {
                wholeSnapshotCheckBox.IsChecked = false;
            }
            treeSelectionSummary.Text = "No snapshot entries selected.";
            treeSelectionSummary.Foreground = palette.TextTertiary;
            if (snapshot == null)
            {
                selectedSnapshotDetail.Text = "Select a snapshot to browse or restore.";
                selectedSnapshotDetail.Foreground = palette.TextSecondary;
                UpdateActionAffordance();
                return;
            }
            selectedSnapshotDetail.Text = "Selected snapshot · " + snapshot.WhenDisplay + " - " +
                snapshot.GenerationDisplay + " - " + snapshot.FileCount.ToString() +
                " files - " + snapshot.SizeDisplay + "\n" + snapshot.SourceSummary;
            selectedSnapshotDetail.Foreground = snapshot.IsLegacyUnbound
                ? palette.Warning
                : palette.TextSecondary;
            if (snapshot.IsLegacyUnbound)
            {
                selectedSnapshotDetail.Text +=
                    "\nLegacy / unbound: exact repository, computer, scheduled-tag, and source-set match; explicit confirmation required.";
            }
            UpdateActionAffordance();
        }

        private void OnSnapshotGridKeyDown(object sender, KeyEventArgs args)
        {
            if ((args.Key == Key.Enter || args.Key == Key.Return) &&
                snapshotGrid.SelectedItem is RestoreSnapshot)
            {
                args.Handled = true;
                treePathBox.Focus();
                treePathBox.SelectAll();
            }
        }

        private void OnTreeSelectionChanged(object sender, SelectionChangedEventArgs args)
        {
            UpdateActionAffordance();
        }

        private async void OnTreeDoubleClick(object sender, MouseButtonEventArgs args)
        {
            RestoreTreeEntry entry = treeGrid.SelectedItem as RestoreTreeEntry;
            if (entry == null || entry.EntryType != "dir" || operationInProgress)
            {
                return;
            }
            treePathBox.Text = entry.EntryPath;
            await LoadTree();
        }

        private async void OnUpClick(object sender, RoutedEventArgs args)
        {
            if (operationInProgress)
            {
                return;
            }
            string value = (treePathBox.Text ?? "/").TrimEnd('/');
            int separator = value.LastIndexOf('/');
            treePathBox.Text = separator <= 0 ? "/" : value.Substring(0, separator);
            await LoadTree();
        }

        private void OnUseSelectionClick(object sender, RoutedEventArgs args)
        {
            List<string> paths = new List<string>();
            foreach (object item in treeGrid.SelectedItems)
            {
                RestoreTreeEntry entry = item as RestoreTreeEntry;
                if (entry != null && !string.IsNullOrWhiteSpace(entry.EntryPath) &&
                    !paths.Contains(entry.EntryPath))
                {
                    paths.Add(entry.EntryPath);
                }
            }
            if (paths.Count == 0)
            {
                SetBusy(false, "Select files or folders", "Choose one or more snapshot entries first.", false);
                return;
            }
            includesBox.Text = string.Join(Environment.NewLine, paths.ToArray());
            if (wholeSnapshotCheckBox != null)
            {
                wholeSnapshotCheckBox.IsChecked = false;
            }
            treeSelectionSummary.Text = paths.Count.ToString() +
                " snapshot path" + (paths.Count == 1 ? string.Empty : "s") +
                " added to the restore scope.";
            treeSelectionSummary.Foreground = palette.Success;
            SetBusy(false, "Restore selection updated", paths.Count.ToString() + " path(s) selected.", true);
        }

        private void OnChooseTargetClick(object sender, RoutedEventArgs args)
        {
            using (System.Windows.Forms.FolderBrowserDialog dialog =
                new System.Windows.Forms.FolderBrowserDialog())
            {
                dialog.Description = "Choose an existing empty folder, or create a new restore folder.";
                dialog.ShowNewFolderButton = true;
                if (Directory.Exists(targetBox.Text))
                {
                    dialog.SelectedPath = targetBox.Text;
                }
                if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
                {
                    targetBox.Text = dialog.SelectedPath;
                }
            }
        }

        private void OnOpenTargetClick(object sender, RoutedEventArgs args)
        {
            if (string.IsNullOrWhiteSpace(completedTarget) || !Directory.Exists(completedTarget))
            {
                return;
            }
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "\"" + completedTarget.Replace("\"", string.Empty) + "\"",
                    UseShellExecute = true
                });
            }
            catch (Exception error)
            {
                SetBusy(false, "Could not open the folder", error.Message, false);
            }
        }

        private void OnClosing(object sender, CancelEventArgs args)
        {
            if (!operationInProgress)
            {
                return;
            }
            args.Cancel = true;
            statusTitle.Text = "Restore operation still running";
            statusDetail.Text = "Keep this window open until the protected operation reaches a final state.";
        }

        private static IList<string> ParseIncludes(string value)
        {
            List<string> result = new List<string>();
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (string line in (value ?? string.Empty).Replace("\r", string.Empty).Split('\n'))
            {
                string item = line.Trim();
                if (item.Length == 0)
                {
                    continue;
                }
                if (item.Length > 1024 || item.IndexOf('\0') >= 0)
                {
                    throw new InvalidDataException("A selected snapshot path is invalid or too long.");
                }
                if (seen.Add(item))
                {
                    result.Add(item);
                }
            }
            if (result.Count > 64)
            {
                throw new InvalidDataException("Select at most 64 paths for one restore.");
            }
            return result;
        }

        private static string FriendlyStage(string stage)
        {
            switch ((stage ?? string.Empty).ToLowerInvariant())
            {
                case "preflight": return "Validating restore safety";
                case "reading": return "Reading protected snapshot data";
                case "restoring": return "Restoring and verifying";
                case "complete": return "Protected operation complete";
                case "failed": return "Protected operation needs attention";
                default: return "Protected restore operation";
            }
        }

        private Border CreateCard()
        {
            return new Border
            {
                Background = palette.Surface,
                BorderBrush = palette.Border,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10)
            };
        }

        private Button CreateButton(string text, bool primary)
        {
            Button button = new Button();
            button.Content = text;
            button.Padding = new Thickness(14, 8, 14, 8);
            button.MinHeight = 36;
            button.Background = primary ? palette.AccentInfo : palette.ButtonBackground;
            button.Foreground = primary ? palette.TextOnAccent : palette.ButtonText;
            button.BorderBrush = primary ? palette.AccentInfo : palette.Border;
            button.BorderThickness = new Thickness(1);
            button.Cursor = Cursors.Hand;
            ToolTipService.SetShowOnDisabled(button, true);
            DashboardVisualStyle.ApplyButtonChrome(button, 8.0);
            DashboardVisualStyle.ApplyFocusOutline(button, palette.Focus);
            AutomationProperties.SetName(button, text);
            return button;
        }

        private TextBox CreateTextBox(string text)
        {
            TextBox box = new TextBox();
            box.Text = text;
            box.Padding = new Thickness(9, 7, 9, 7);
            box.MinHeight = 34;
            box.Background = palette.SurfaceSoft;
            box.Foreground = palette.TextPrimary;
            box.BorderBrush = palette.Border;
            box.CaretBrush = palette.TextPrimary;
            return box;
        }

        private DataGrid CreateGrid()
        {
            DataGrid grid = new DataGrid();
            grid.AutoGenerateColumns = false;
            grid.IsReadOnly = true;
            grid.CanUserAddRows = false;
            grid.CanUserDeleteRows = false;
            grid.CanUserResizeRows = false;
            grid.HeadersVisibility = DataGridHeadersVisibility.Column;
            grid.GridLinesVisibility = DataGridGridLinesVisibility.Horizontal;
            grid.HorizontalGridLinesBrush = palette.GridLine;
            grid.VerticalGridLinesBrush = Brushes.Transparent;
            grid.Background = Brushes.Transparent;
            grid.Foreground = palette.TableText;
            grid.BorderBrush = palette.Border;
            grid.RowBackground = palette.RowEven;
            grid.AlternatingRowBackground = palette.AlternatingRow;
            grid.SelectionMode = DataGridSelectionMode.Single;
            grid.SelectionUnit = DataGridSelectionUnit.FullRow;
            DashboardVisualStyle.ApplyDataGridChrome(grid, palette);
            return grid;
        }

        private static DataGridTextColumn CreateColumn(
            string header,
            string property,
            double width)
        {
            return new DataGridTextColumn
            {
                Header = header,
                Binding = new Binding(property),
                Width = new DataGridLength(width, DataGridLengthUnitType.Star)
            };
        }

        private static TextBlock CreateText(
            string text,
            double size,
            Brush foreground,
            FontWeight weight)
        {
            return new TextBlock
            {
                Text = text,
                FontSize = size,
                Foreground = foreground,
                FontWeight = weight
            };
        }
    }
}
