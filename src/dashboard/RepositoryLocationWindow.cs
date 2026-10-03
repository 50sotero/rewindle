using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace ResticBackuper.Dashboard
{
    internal enum RepositoryLocationStage
    {
        Selecting,
        Reviewing,
        WaitingForApproval,
        Copying,
        Verifying,
        Activating,
        Complete,
        Failed
    }

    internal sealed class RepositoryLocationWindow : Window
    {
        // The steps of a relocation, in the order they happen. Failed is not one of them: a failure marks the step it
        // stopped on.
        private static readonly RepositoryLocationStage[] StageOrder =
        {
            RepositoryLocationStage.Selecting,
            RepositoryLocationStage.Reviewing,
            RepositoryLocationStage.WaitingForApproval,
            RepositoryLocationStage.Copying,
            RepositoryLocationStage.Verifying,
            RepositoryLocationStage.Activating,
            RepositoryLocationStage.Complete
        };

        private readonly SourceConfiguration configuration;
        private readonly DashboardThemePalette palette;
        private readonly IDictionary<RepositoryLocationStage, TextBlock> stageItems =
            new Dictionary<RepositoryLocationStage, TextBlock>();
        private TextBlock stageBadge;
        private TextBlock headline;
        private TextBlock detail;
        private TextBlock currentPathValue;
        private TextBlock newPathValue;
        private TextBlock capacityValue;
        private TextBlock progressMetrics;
        private TextBlock closeNotice;
        private ProgressBar progressBar;
        private Button chooseButton;
        private Button primaryButton;
        private Button closeButton;
        private string selectedRepository;
        private bool operationStarted;
        private int estimateGeneration;
        private RepositoryLocationStage? animatedStage;
        // The last step that was not a failure, which is the one a failure is drawn on.
        private RepositoryLocationStage lastProgressStage = RepositoryLocationStage.Selecting;

        internal bool RepositoryChanged { get; private set; }

        internal RepositoryLocationWindow(
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

            Title = "Change backup location";
            Width = 780;
            Height = 640;
            MinWidth = 680;
            // The review card scrolls and the step list fits in this height, so the window can be much shorter than it was.
            MinHeight = 460;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ResizeMode = ResizeMode.CanResize;
            // Owned and modal, like the schedule editor: the dashboard's own taskbar button brings both back to the front.
            ShowInTaskbar = false;
            DashboardVisualStyle.ApplyWindow(this, palette);
            Content = BuildContent();
            DashboardVisualStyle.FitToWorkArea(this);
            DashboardVisualStyle.ApplyDialogEntrance(this);
            Loaded += delegate
            {
                Dispatcher.BeginInvoke(
                    new Action(delegate
                    {
                        if (chooseButton != null && chooseButton.IsEnabled)
                        {
                            chooseButton.Focus();
                        }
                    }),
                    DispatcherPriority.Input);
            };
            Closing += delegate(object sender, System.ComponentModel.CancelEventArgs args)
            {
                if (operationStarted)
                {
                    // The copy cannot be stopped part-way, so the window stays, and now says why.
                    args.Cancel = true;
                    ShowCloseNotice();
                }
            };
            PreviewKeyDown += delegate(object sender, System.Windows.Input.KeyEventArgs args)
            {
                if (operationStarted && args.Key == System.Windows.Input.Key.Escape)
                {
                    args.Handled = true;
                    ShowCloseNotice();
                }
            };
            AutomationProperties.SetName(this, "Change backup location");
        }

        private UIElement BuildContent()
        {
            Grid shell = new Grid();
            shell.Margin = new Thickness(24);
            shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(18) });
            shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(16) });
            shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            StackPanel heading = new StackPanel();
            stageBadge = new TextBlock();
            stageBadge.Text = "SELECTING";
            stageBadge.FontSize = 11;
            stageBadge.FontWeight = FontWeights.Bold;
            stageBadge.Foreground = palette.AccentInk;
            heading.Children.Add(stageBadge);
            headline = new TextBlock();
            headline.Text = "Choose where future backups are stored";
            headline.FontSize = 24;
            headline.FontWeight = FontWeights.SemiBold;
            headline.Foreground = palette.TextPrimary;
            headline.Margin = new Thickness(0, 5, 0, 0);
            heading.Children.Add(headline);
            detail = new TextBlock();
            detail.Text = "Select a folder, then review the copy before Windows asks for approval.";
            detail.FontSize = 13;
            detail.Foreground = palette.TextSecondary;
            detail.Margin = new Thickness(0, 5, 0, 0);
            detail.TextWrapping = TextWrapping.Wrap;
            AutomationProperties.SetLiveSetting(detail, AutomationLiveSetting.Polite);
            heading.Children.Add(detail);
            shell.Children.Add(heading);

            Grid body = new Grid();
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetRow(body, 2);
            shell.Children.Add(body);

            Border stageCard = CreateCard();
            stageCard.Padding = new Thickness(16, 15, 16, 15);
            StackPanel stages = new StackPanel();
            AddStage(stages, RepositoryLocationStage.Selecting, "Selecting");
            AddStage(stages, RepositoryLocationStage.Reviewing, "Reviewing");
            AddStage(stages, RepositoryLocationStage.WaitingForApproval, "Waiting for approval");
            AddStage(stages, RepositoryLocationStage.Copying, "Copying");
            AddStage(stages, RepositoryLocationStage.Verifying, "Verifying");
            AddStage(stages, RepositoryLocationStage.Activating, "Activating");
            AddStage(stages, RepositoryLocationStage.Complete, "Complete");
            stageCard.Child = stages;
            body.Children.Add(stageCard);

            Border reviewCard = CreateCard();
            reviewCard.Padding = new Thickness(18, 16, 18, 16);
            Grid.SetColumn(reviewCard, 2);
            StackPanel review = new StackPanel();
            // The card scrolls instead of clipping when a long path, the capacity line and the progress block do not all
            // fit, which is what lets the window be short.
            ScrollViewer reviewScroll = new ScrollViewer();
            reviewScroll.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            reviewScroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
            reviewScroll.Content = review;
            review.Children.Add(BuildPathField("Current location", configuration.RepositoryPath, out currentPathValue));
            FrameworkElement newField = BuildPathField("New location", "No folder selected", out newPathValue);
            newField.Margin = new Thickness(0, 14, 0, 0);
            review.Children.Add(newField);

            capacityValue = new TextBlock();
            capacityValue.Text = "Storage estimate appears after you choose a folder.";
            capacityValue.FontSize = 12;
            capacityValue.Foreground = palette.TextSecondary;
            capacityValue.TextWrapping = TextWrapping.Wrap;
            capacityValue.Margin = new Thickness(0, 14, 0, 0);
            AutomationProperties.SetLiveSetting(capacityValue, AutomationLiveSetting.Polite);
            review.Children.Add(capacityValue);

            Border safety = new Border();
            safety.Background = palette.SafetyBackground;
            safety.BorderBrush = palette.SafetyBorder;
            safety.BorderThickness = new Thickness(1);
            safety.CornerRadius = new CornerRadius(8);
            safety.Padding = new Thickness(12, 10, 12, 10);
            safety.Margin = new Thickness(0, 16, 0, 0);
            TextBlock safetyText = new TextBlock();
            safetyText.Text = "The repository is copied, verified, and only then activated. " +
                "The old repository is kept untouched for recovery. This does not start a backup.";
            safetyText.FontSize = 12;
            safetyText.Foreground = palette.SafetyText;
            safetyText.TextWrapping = TextWrapping.Wrap;
            safety.Child = safetyText;
            review.Children.Add(safety);

            progressBar = new ProgressBar();
            progressBar.Height = 8;
            progressBar.Minimum = 0;
            progressBar.Maximum = 100;
            progressBar.Value = 0;
            // The palette's accent on the palette's track, as in the readiness and restore windows; without them the
            // stock Windows green bar on a light grey track shows through for the longest operation in the app.
            progressBar.Foreground = palette.AccentPrimary;
            progressBar.Background = palette.ProgressTrack;
            progressBar.Visibility = Visibility.Collapsed;
            progressBar.Margin = new Thickness(0, 18, 0, 0);
            AutomationProperties.SetName(progressBar, "Repository relocation progress");
            AutomationProperties.SetHelpText(
                progressBar,
                "Progress for the protected copy, verification, and activation steps.");
            review.Children.Add(progressBar);
            progressMetrics = new TextBlock();
            progressMetrics.FontSize = 11;
            progressMetrics.Foreground = palette.TextSecondary;
            progressMetrics.Margin = new Thickness(0, 7, 0, 0);
            progressMetrics.TextWrapping = TextWrapping.Wrap;
            progressMetrics.Visibility = Visibility.Collapsed;
            AutomationProperties.SetLiveSetting(progressMetrics, AutomationLiveSetting.Polite);
            review.Children.Add(progressMetrics);

            // Shown only if someone tries to close the window while the copy runs, which would otherwise look like a dead
            // close button. It lives here rather than in the headline's detail, which carries the live progress messages.
            closeNotice = new TextBlock();
            closeNotice.Text = "Copying cannot be cancelled safely. Keep this window open until it finishes.";
            closeNotice.FontSize = 12;
            closeNotice.Foreground = palette.Warning;
            closeNotice.TextWrapping = TextWrapping.Wrap;
            closeNotice.Margin = new Thickness(0, 10, 0, 0);
            closeNotice.Visibility = Visibility.Collapsed;
            AutomationProperties.SetLiveSetting(closeNotice, AutomationLiveSetting.Assertive);
            review.Children.Add(closeNotice);
            reviewCard.Child = reviewScroll;
            body.Children.Add(reviewCard);

            Grid actions = new Grid();
            actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            chooseButton = CreateButton("Choose a folder", false);
            chooseButton.Click += delegate { SelectDestination(); };
            AutomationProperties.SetAutomationId(chooseButton, "ChooseRepositoryFolderButton");
            AutomationProperties.SetHelpText(
                chooseButton,
                "Choose the exact folder that will contain the copied Restic repository.");
            actions.Children.Add(chooseButton);

            closeButton = CreateButton("Cancel", false);
            closeButton.MinWidth = 86;
            closeButton.IsCancel = true;
            closeButton.Click += delegate { DialogResult = false; };
            Grid.SetColumn(closeButton, 2);
            actions.Children.Add(closeButton);

            primaryButton = CreateButton("Choose a folder first", true);
            primaryButton.MinWidth = 152;
            primaryButton.Margin = new Thickness(10, 0, 0, 0);
            primaryButton.IsEnabled = false;
            primaryButton.IsDefault = true;
            primaryButton.Click += OnPrimaryClick;
            AutomationProperties.SetAutomationId(primaryButton, "ConfirmRepositoryRelocationButton");
            AutomationProperties.SetHelpText(
                primaryButton,
                "Copy, verify, and activate the reviewed repository location. Windows approval is required.");
            Grid.SetColumn(primaryButton, 3);
            actions.Children.Add(primaryButton);
            Grid.SetRow(actions, 4);
            shell.Children.Add(actions);

            SetStage(RepositoryLocationStage.Selecting, null);
            return shell;
        }

        private FrameworkElement BuildPathField(
            string label,
            string value,
            out TextBlock valueBlock)
        {
            StackPanel field = new StackPanel();
            TextBlock caption = new TextBlock();
            caption.Text = label;
            caption.FontSize = 11;
            caption.FontWeight = FontWeights.SemiBold;
            caption.Foreground = palette.TextSecondary;
            field.Children.Add(caption);
            valueBlock = new TextBlock();
            valueBlock.Text = value;
            valueBlock.FontSize = 13;
            valueBlock.Foreground = palette.TextPrimary;
            valueBlock.TextWrapping = TextWrapping.Wrap;
            valueBlock.Margin = new Thickness(0, 3, 0, 0);
            AutomationProperties.SetName(valueBlock, label + " path");
            AutomationProperties.SetHelpText(
                valueBlock,
                "The full path is shown here so it can be reviewed before approval.");
            field.Children.Add(valueBlock);
            return field;
        }

        private void AddStage(Panel parent, RepositoryLocationStage stage, string label)
        {
            TextBlock item = new TextBlock();
            item.Tag = label;
            item.Text = "○  " + label;
            item.FontSize = 12;
            item.Foreground = palette.TextTertiary;
            item.Margin = new Thickness(0, stageItems.Count == 0 ? 0 : 10, 0, 0);
            stageItems[stage] = item;
            AutomationProperties.SetName(item, "Repository relocation stage " + StageLabel(stage));
            parent.Children.Add(item);
        }

        // The page's card radius (.surface), as the schedule and readiness dialogs draw theirs.
        private Border CreateCard()
        {
            return new Border
            {
                Background = palette.Surface,
                BorderBrush = palette.Border,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(14)
            };
        }

        // `primary` is the one button that does the work of the step (ink on the canvas, like the page's own); the others are quiet.
        private Button CreateButton(string label, bool primary)
        {
            Button button = new Button();
            button.Content = label;
            button.MinHeight = 38;
            button.Padding = new Thickness(14, 7, 14, 7);
            button.FontWeight = FontWeights.SemiBold;
            button.Cursor = System.Windows.Input.Cursors.Hand;
            ToolTipService.SetShowOnDisabled(button, true);
            if (primary)
            {
                DashboardVisualStyle.StylePrimaryButton(button, palette);
            }
            else
            {
                DashboardVisualStyle.StyleSecondaryButton(button, palette);
            }
            DashboardVisualStyle.ApplyFocusOutline(button, palette.Focus);
            AutomationProperties.SetName(button, label);
            return button;
        }

        // The accessible name follows the visible label, so a button that changes its words keeps a name that can be said.
        private static void SetButtonLabel(Button button, string label)
        {
            button.Content = label;
            AutomationProperties.SetName(button, label);
        }

        private void SelectDestination()
        {
            if (operationStarted)
            {
                return;
            }
            SetStage(
                RepositoryLocationStage.Selecting,
                "Select the exact folder that should contain the Restic repository.");
            string picked;
            try
            {
                // The Windows folder picker the rest of the app uses, owned by this window. The old tree dialog was small, had no
                // address bar to paste a path into, and opened with no owner, so it could slip behind this window. What it
                // returns is only a suggestion: ReviewDestination canonicalizes it and refuses anything unsafe, and the protected
                // manager checks it again.
                picked = DashboardWindow.PickFolder(
                    new WindowInteropHelper(this).Handle,
                    "Choose the new backup location",
                    "Use this folder",
                    "Choose the new Restic backup repository folder");
            }
            catch (Exception error)
            {
                // A picker that could not open leaves an earlier choice as it was.
                SetStage(
                    string.IsNullOrWhiteSpace(selectedRepository)
                        ? RepositoryLocationStage.Selecting
                        : RepositoryLocationStage.Reviewing,
                    "The folder picker could not open. " + error.Message);
                detail.Foreground = palette.Danger;
                return;
            }
            if (string.IsNullOrWhiteSpace(picked))
            {
                if (string.IsNullOrWhiteSpace(selectedRepository))
                {
                    detail.Text = "No folder selected. Your current repository is unchanged.";
                }
                else
                {
                    SetStage(RepositoryLocationStage.Reviewing, "Review the selected location before approval.");
                }
                return;
            }
            ReviewDestination(picked);
        }

        private async void ReviewDestination(string value)
        {
            string canonical;
            try
            {
                canonical = RepositoryManagerLauncher.CanonicalizeRepository(value);
                string current = RepositoryManagerLauncher.CanonicalizeRepository(configuration.RepositoryPath);
                if (string.Equals(canonical, current, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException("This is already the active repository.");
                }
                string currentPrefix = current + Path.DirectorySeparatorChar;
                string newPrefix = canonical + Path.DirectorySeparatorChar;
                if (canonical.StartsWith(currentPrefix, StringComparison.OrdinalIgnoreCase) ||
                    current.StartsWith(newPrefix, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        "The new and current repositories cannot contain one another.");
                }
            }
            catch (Exception error)
            {
                RejectDestination(error.Message);
                return;
            }

            selectedRepository = canonical;
            SetButtonLabel(chooseButton, "Choose another folder");
            newPathValue.Text = selectedRepository;
            newPathValue.ToolTip = selectedRepository;
            // Figures left over from an earlier attempt do not describe this folder.
            progressMetrics.Visibility = Visibility.Collapsed;
            SetButtonLabel(primaryButton, "Checking storage…");
            primaryButton.IsEnabled = false;
            // The folder button stays available while the size is measured, which can take a while on a large repository.
            // Choosing again starts a new check, and the generation below makes this one's late answer count for nothing.
            SetStage(
                RepositoryLocationStage.Reviewing,
                "Review the destination. Nothing changes until you approve the protected copy.");
            int generation = ++estimateGeneration;
            capacityValue.Text = "Calculating repository size and available space…";
            capacityValue.Foreground = palette.TextSecondary;
            ShowEstimateProgress();
            string destination = canonical;
            StorageEstimate estimate = await Task.Run(delegate
            {
                return StorageEstimate.Measure(configuration.RepositoryPath, destination);
            });
            if (generation != estimateGeneration || operationStarted)
            {
                return;
            }
            HideEstimateProgress();
            capacityValue.Text = estimate.DisplayText;
            capacityValue.Foreground = estimate.InsufficientSpace
                ? palette.Danger
                : palette.TextSecondary;
            SetButtonLabel(
                primaryButton,
                estimate.InsufficientSpace
                    ? "More space required"
                    : "Copy and use this location");
            primaryButton.IsEnabled = !estimate.InsufficientSpace;
        }

        // A folder that cannot be used leaves nothing selected. The window stays on its first step with the reason in red,
        // instead of reading FAILED over the details of an earlier pick that no longer applies.
        private void RejectDestination(string reason)
        {
            // A size check still running for the earlier pick must not come back and enable the copy for it.
            estimateGeneration++;
            selectedRepository = null;
            newPathValue.Text = "No folder selected";
            newPathValue.ToolTip = null;
            capacityValue.Text = "Storage estimate appears after you choose a folder.";
            capacityValue.Foreground = palette.TextSecondary;
            progressMetrics.Visibility = Visibility.Collapsed;
            HideEstimateProgress();
            SetButtonLabel(chooseButton, "Choose a folder");
            SetButtonLabel(primaryButton, "Choose a folder first");
            primaryButton.IsEnabled = false;
            SetStage(
                RepositoryLocationStage.Selecting,
                string.IsNullOrWhiteSpace(reason)
                    ? "That folder cannot be used as the new backup location."
                    : reason);
            // SetStage colors the message for a stage that is going well; this one is a refusal.
            detail.Foreground = palette.Danger;
        }

        // The size of the repository is measured off the UI thread, so the window shows that it is working.
        private void ShowEstimateProgress()
        {
            if (operationStarted)
            {
                return;
            }
            AutomationProperties.SetName(progressBar, "Measuring repository size");
            progressBar.Visibility = Visibility.Visible;
            DashboardVisualStyle.SetBusy(progressBar, true);
        }

        private void HideEstimateProgress()
        {
            if (operationStarted)
            {
                return;
            }
            DashboardVisualStyle.SetBusy(progressBar, false);
            progressBar.Visibility = Visibility.Collapsed;
        }

        private void ShowCloseNotice()
        {
            // The review card scrolls, so the reason is brought into view; below the fold it would look like a dead close button.
            if (closeNotice.Visibility == Visibility.Visible)
            {
                closeNotice.BringIntoView();
                DashboardVisualStyle.Emphasize(closeNotice);
                return;
            }
            closeNotice.Visibility = Visibility.Visible;
            closeNotice.BringIntoView();
            DashboardVisualStyle.Reveal(
                closeNotice,
                TimeSpan.FromMilliseconds(160),
                TimeSpan.Zero,
                -3.0);
        }

        private async void OnPrimaryClick(object sender, RoutedEventArgs args)
        {
            if (operationStarted || string.IsNullOrWhiteSpace(selectedRepository))
            {
                return;
            }
            operationStarted = true;
            chooseButton.IsEnabled = false;
            primaryButton.IsEnabled = false;
            closeButton.IsEnabled = false;
            AutomationProperties.SetName(progressBar, "Repository relocation progress");
            progressBar.Visibility = Visibility.Visible;
            DashboardVisualStyle.SetBusy(progressBar, true);
            DashboardVisualStyle.Reveal(
                progressBar,
                DashboardVisualStyle.DefaultDuration,
                TimeSpan.Zero,
                0.0);
            progressMetrics.Visibility = Visibility.Visible;
            progressMetrics.Text = "Waiting for Windows approval. No backup will start.";
            SetStage(
                RepositoryLocationStage.WaitingForApproval,
                "Approve the protected repository copy in the Windows prompt.");

            RepositoryManagerResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return RepositoryManagerLauncher.Run(
                        configuration,
                        selectedRepository,
                        delegate
                        {
                            Dispatcher.BeginInvoke(
                                new Action(delegate
                                {
                                    SetStage(
                                        RepositoryLocationStage.Copying,
                                        "Approval received. Preparing the verified copy.");
                                    progressMetrics.Text = "Preparing repository copy…";
                                }),
                                DispatcherPriority.Background);
                        },
                        delegate(RepositoryProgress progress)
                        {
                            Dispatcher.BeginInvoke(
                                new Action(delegate { ApplyProgress(progress); }),
                                DispatcherPriority.Background);
                        });
                });
            }
            catch (Exception error)
            {
                result = RepositoryManagerResult.Failure(error.Message, -1);
            }

            operationStarted = false;
            closeNotice.Visibility = Visibility.Collapsed;
            closeButton.IsEnabled = true;
            if (result.UserCancelled)
            {
                progressBar.Visibility = Visibility.Collapsed;
                DashboardVisualStyle.SetBusy(progressBar, false);
                progressMetrics.Visibility = Visibility.Collapsed;
                chooseButton.IsEnabled = true;
                primaryButton.IsEnabled = true;
                SetStage(
                    RepositoryLocationStage.Reviewing,
                    "Windows approval was cancelled. The active repository was not changed.");
                return;
            }

            SourceConfiguration independentlyRead = null;
            try { independentlyRead = SourceConfiguration.Load(); }
            catch { }
            bool independentlyVerified = result.Succeeded &&
                independentlyRead != null &&
                result.OldRepositoryRetained &&
                !string.IsNullOrWhiteSpace(result.OldRepository) &&
                Directory.Exists(result.OldRepository) &&
                string.Equals(result.PlanId, configuration.PlanId, StringComparison.Ordinal) &&
                string.Equals(independentlyRead.PlanId, configuration.PlanId, StringComparison.Ordinal) &&
                result.PreviousConfigGeneration == configuration.ConfigGeneration &&
                configuration.ConfigGeneration < long.MaxValue &&
                result.ConfigGeneration == configuration.ConfigGeneration + 1 &&
                independentlyRead.ConfigGeneration == result.ConfigGeneration &&
                string.Equals(
                    RepositoryManagerLauncher.CanonicalizeRepository(independentlyRead.RepositoryPath),
                    RepositoryManagerLauncher.CanonicalizeRepository(selectedRepository),
                    StringComparison.OrdinalIgnoreCase);
            if (independentlyVerified)
            {
                RepositoryChanged = true;
                DashboardVisualStyle.SetBusy(progressBar, false);
                DashboardVisualStyle.AnimateProgressValue(progressBar, 100);
                progressMetrics.Text = "Repository verified and active. The previous repository was retained.";
                SetStage(
                    RepositoryLocationStage.Complete,
                    "The new repository is active. The old copy remains untouched for recovery.");
                SetButtonLabel(primaryButton, "Done");
                primaryButton.IsEnabled = true;
                primaryButton.Click -= OnPrimaryClick;
                primaryButton.Click += delegate { DialogResult = true; };
                closeButton.Visibility = Visibility.Collapsed;
                return;
            }

            string failure = !result.Succeeded
                ? result.ErrorMessage
                : "The protected configuration did not independently confirm the new location.";
            DashboardVisualStyle.SetBusy(progressBar, false);
            DashboardVisualStyle.AnimateProgressValue(progressBar, 0);
            progressMetrics.Text = "No destination activation was accepted by the dashboard.";
            SetStage(
                RepositoryLocationStage.Failed,
                string.IsNullOrWhiteSpace(failure)
                    ? "The protected repository relocation failed."
                    : failure);
            chooseButton.IsEnabled = true;
            SetButtonLabel(primaryButton, "Try again");
            primaryButton.IsEnabled = true;
        }

        private void ApplyProgress(RepositoryProgress progress)
        {
            if (progress == null || !operationStarted)
            {
                return;
            }
            RepositoryLocationStage stage = RepositoryLocationStage.Copying;
            string message = string.IsNullOrWhiteSpace(progress.Message) ? null : progress.Message;
            string headlineText = null;
            if (string.Equals(progress.Stage, "verifying", StringComparison.OrdinalIgnoreCase))
            {
                stage = RepositoryLocationStage.Verifying;
            }
            else if (string.Equals(progress.Stage, "activating", StringComparison.OrdinalIgnoreCase))
            {
                stage = RepositoryLocationStage.Activating;
            }
            else if (string.Equals(progress.Stage, "complete", StringComparison.OrdinalIgnoreCase))
            {
                // The protected manager saying it finished is not the dashboard accepting the result. Success is shown only
                // after the independent check in OnPrimaryClick, so until then this reads as verifying. The step list stays
                // on the last step the manager reported, because moving it back would show activation as undone.
                stage = Array.IndexOf(StageOrder, lastProgressStage) > Array.IndexOf(StageOrder, RepositoryLocationStage.Verifying)
                    ? lastProgressStage
                    : RepositoryLocationStage.Verifying;
                headlineText = "Verifying the new location";
                message = "The protected copy finished. Rewindle is now confirming the result independently.";
            }
            else if (string.Equals(progress.Stage, "failed", StringComparison.OrdinalIgnoreCase))
            {
                stage = RepositoryLocationStage.Failed;
            }
            SetStage(stage, message, headlineText);

            if (progress.Percent.HasValue && progress.Percent.Value >= 0 && progress.Percent.Value <= 100)
            {
                DashboardVisualStyle.SetBusy(progressBar, false);
                DashboardVisualStyle.AnimateProgressValue(progressBar, progress.Percent.Value);
            }
            else
            {
                DashboardVisualStyle.SetBusy(progressBar, true);
            }

            List<string> metrics = new List<string>();
            if (progress.BytesCopied.HasValue)
            {
                string bytes = FormatBytes(progress.BytesCopied.Value);
                if (progress.BytesTotal.HasValue)
                {
                    bytes += " of " + FormatBytes(progress.BytesTotal.Value);
                }
                metrics.Add(bytes);
            }
            if (progress.FilesCopied.HasValue)
            {
                string files = progress.FilesCopied.Value.ToString("N0", CultureInfo.CurrentCulture) + " files";
                if (progress.FilesTotal.HasValue)
                {
                    files += " of " + progress.FilesTotal.Value.ToString("N0", CultureInfo.CurrentCulture);
                }
                metrics.Add(files);
            }
            if (progress.ThroughputBytesPerSecond.HasValue)
            {
                metrics.Add(FormatBytes((long)progress.ThroughputBytesPerSecond.Value) + "/s");
            }
            if (progress.EstimatedSecondsRemaining.HasValue)
            {
                metrics.Add(FormatDuration(progress.EstimatedSecondsRemaining.Value) + " remaining");
            }
            progressMetrics.Text = metrics.Count == 0
                ? (string.IsNullOrWhiteSpace(progress.Message) ? "Protected relocation in progress…" : progress.Message)
                : string.Join("  •  ", metrics.ToArray());
            AutomationProperties.SetName(progressMetrics, "Repository relocation progress: " + progressMetrics.Text);
        }

        private void SetStage(RepositoryLocationStage stage, string message)
        {
            SetStage(stage, message, null);
        }

        // Steps already passed show a check, the current one a dot, and the ones ahead a ring. A failure is drawn as a cross
        // on the step it stopped at (there is no step of its own for it), and the badge and message take the failure's color.
        private void SetStage(RepositoryLocationStage stage, string message, string headlineText)
        {
            bool failed = stage == RepositoryLocationStage.Failed;
            bool complete = stage == RepositoryLocationStage.Complete;
            if (!failed)
            {
                lastProgressStage = stage;
            }
            RepositoryLocationStage currentStage = failed ? lastProgressStage : stage;
            int current = Array.IndexOf(StageOrder, currentStage);
            foreach (KeyValuePair<RepositoryLocationStage, TextBlock> item in stageItems)
            {
                int index = Array.IndexOf(StageOrder, item.Key);
                string glyph;
                string status;
                Brush brush;
                FontWeight weight = FontWeights.Normal;
                if (index < current || (index == current && complete))
                {
                    glyph = "✓";
                    status = "Done";
                    brush = palette.Success;
                    if (index == current)
                    {
                        weight = FontWeights.SemiBold;
                    }
                }
                else if (index == current)
                {
                    glyph = failed ? "✕" : "●";
                    status = failed ? "Failed" : "In progress";
                    brush = failed ? (Brush)palette.Danger : palette.AccentInk;
                    weight = FontWeights.SemiBold;
                }
                else
                {
                    glyph = "○";
                    status = "Pending";
                    brush = palette.TextTertiary;
                }
                item.Value.Text = glyph + "  " + (string)item.Value.Tag;
                item.Value.Foreground = brush;
                item.Value.FontWeight = weight;
                AutomationProperties.SetItemStatus(item.Value, status);
            }
            stageBadge.Foreground = failed
                ? (Brush)palette.Danger
                : complete ? palette.Success : palette.AccentInk;
            stageBadge.Text = StageLabel(stage).ToUpperInvariant();
            headline.Text = string.IsNullOrWhiteSpace(headlineText) ? StageHeadline(stage) : headlineText;
            detail.Foreground = failed
                ? (Brush)palette.Danger
                : complete ? palette.Success : palette.TextSecondary;
            AutomationProperties.SetLiveSetting(stageBadge, AutomationLiveSetting.Polite);
            if (!string.IsNullOrWhiteSpace(message))
            {
                detail.Text = message;
            }
            AutomationProperties.SetName(stageBadge, "Repository relocation stage " + StageLabel(stage));
            if (!animatedStage.HasValue || animatedStage.Value != stage)
            {
                TextBlock activeItem;
                if (stageItems.TryGetValue(currentStage, out activeItem))
                {
                    DashboardVisualStyle.Emphasize(activeItem);
                }
                DashboardVisualStyle.Emphasize(stageBadge);
                animatedStage = stage;
            }
        }

        private static string StageLabel(RepositoryLocationStage stage)
        {
            switch (stage)
            {
                case RepositoryLocationStage.WaitingForApproval: return "Waiting for approval";
                default: return stage.ToString();
            }
        }

        private static string StageHeadline(RepositoryLocationStage stage)
        {
            switch (stage)
            {
                case RepositoryLocationStage.Reviewing: return "Review the new location";
                case RepositoryLocationStage.WaitingForApproval: return "Waiting for Windows approval";
                case RepositoryLocationStage.Copying: return "Copying your backups";
                case RepositoryLocationStage.Verifying: return "Verifying the copy";
                case RepositoryLocationStage.Activating: return "Switching to the new location";
                case RepositoryLocationStage.Complete: return "Backup location changed";
                // Said without claiming what did or did not change: when the protected configuration cannot confirm the new
                // location, the detail line is what carries the specifics.
                case RepositoryLocationStage.Failed: return "The location change did not finish";
                default: return "Choose where future backups are stored";
            }
        }

        private static string FormatBytes(long value)
        {
            string[] units = { "B", "KiB", "MiB", "GiB", "TiB" };
            double amount = Math.Max(0, value);
            int unit = 0;
            while (amount >= 1024 && unit < units.Length - 1)
            {
                amount /= 1024;
                unit++;
            }
            return amount.ToString(unit == 0 ? "N0" : "N1", CultureInfo.CurrentCulture) + " " + units[unit];
        }

        private static string FormatDuration(double seconds)
        {
            if (seconds < 60)
            {
                return Math.Max(0, Math.Round(seconds)).ToString("N0", CultureInfo.CurrentCulture) + "s";
            }
            TimeSpan duration = TimeSpan.FromSeconds(Math.Max(0, seconds));
            return duration.TotalHours >= 1
                ? ((int)duration.TotalHours).ToString(CultureInfo.CurrentCulture) + "h " + duration.Minutes + "m"
                : duration.Minutes.ToString(CultureInfo.CurrentCulture) + "m " + duration.Seconds + "s";
        }

        private sealed class StorageEstimate
        {
            internal string DisplayText { get; private set; }
            internal bool InsufficientSpace { get; private set; }

            internal static StorageEstimate Measure(string currentRepository, string newRepository)
            {
                long? required = TryMeasureDirectory(currentRepository);
                long? available = TryGetFreeSpace(newRepository);
                bool insufficient = required.HasValue && available.HasValue &&
                    available.Value < required.Value;
                string requiredText = required.HasValue
                    ? FormatBytes(required.Value)
                    : "Unavailable";
                string availableText = available.HasValue
                    ? FormatBytes(available.Value)
                    : "Unavailable";
                return new StorageEstimate
                {
                    InsufficientSpace = insufficient,
                    DisplayText = "Repository size: " + requiredText +
                        "  •  Free at destination: " + availableText +
                        (insufficient ? "  •  More free space is required." : string.Empty)
                };
            }

            private static long? TryMeasureDirectory(string root)
            {
                try
                {
                    long total = 0;
                    Stack<string> pending = new Stack<string>();
                    pending.Push(root);
                    while (pending.Count > 0)
                    {
                        string directory = pending.Pop();
                        foreach (string file in Directory.GetFiles(directory))
                        {
                            FileInfo item = new FileInfo(file);
                            if ((item.Attributes & FileAttributes.ReparsePoint) == 0)
                            {
                                checked { total += item.Length; }
                            }
                        }
                        foreach (string child in Directory.GetDirectories(directory))
                        {
                            DirectoryInfo item = new DirectoryInfo(child);
                            if ((item.Attributes & FileAttributes.ReparsePoint) == 0)
                            {
                                pending.Push(child);
                            }
                        }
                    }
                    return total;
                }
                catch
                {
                    return null;
                }
            }

            private static long? TryGetFreeSpace(string path)
            {
                try
                {
                    string root = Path.GetPathRoot(path);
                    if (string.IsNullOrWhiteSpace(root))
                    {
                        return null;
                    }
                    DriveInfo drive = new DriveInfo(root);
                    return drive.IsReady ? (long?)drive.AvailableFreeSpace : null;
                }
                catch
                {
                    return null;
                }
            }
        }
    }
}
