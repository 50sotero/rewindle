using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

namespace ResticBackuper.Dashboard
{
    internal sealed class RecoveryReadinessWindow : Window
    {
        // One name for each action everywhere it appears: the button, its accessible name, the line that lists what is
        // available and the confirmation that follows.
        private const string DrillLabel = "Run restore drill";
        private const string RepairLabel = "Repair active credential";
        private const string LockRepairLabel = "Repair stale locks";
        private const string RotateLabel = "Rotate keys";
        private const string ResumeLabel = "Resume key rotation";
        private const string InspectingHint = "Actions unlock after the independent inspection completes.";

        private readonly SourceConfiguration configuration;
        private readonly DashboardThemePalette palette;
        private TextBlock headline;
        private TextBlock detail;
        private TextBlock repositoryValue;
        private TextBlock capacityValue;
        private TextBlock lockValue;
        private TextBlock actionHint;
        private DataGrid checksGrid;
        private Button refreshButton;
        private Button repairButton;
        private Button lockRepairButton;
        private Button keyRotationButton;
        private Button drillButton;
        private Button closeButton;
        private ProgressBar progress;
        private RecoveryHealthReport lastReport;
        private bool inspecting;
        private bool repairEligible;
        private bool lockRepairEligible;
        private bool keyRotationEligible;
        private bool drillEligible;
        // Whether the key button currently resumes an interrupted rotation rather than starting one. It is set with the
        // button's label from the same report, so nothing has to read the label back to find out.
        private bool resumingRotation;

        internal RecoveryReadinessWindow(
            SourceConfiguration configuration,
            DashboardThemePalette palette)
        {
            if (configuration == null) throw new ArgumentNullException("configuration");
            if (palette == null) throw new ArgumentNullException("palette");
            this.configuration = configuration;
            this.palette = palette;
            Title = "Recovery readiness";
            Width = 1160;
            Height = 650;
            // Narrower than the default needs: the facts, the table and the action bar all reflow.
            MinWidth = 760;
            MinHeight = 520;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            // Owned and modal, like the other dialogs: the dashboard's own taskbar button brings both back to the front.
            ShowInTaskbar = false;
            DashboardVisualStyle.ApplyWindow(this, palette);
            Content = BuildInterface();
            DashboardVisualStyle.FitToWorkArea(this);
            DashboardVisualStyle.ApplyDialogEntrance(this);
            Loaded += async delegate { await RefreshHealth(); };
            Closing += OnClosing;
        }

        private UIElement BuildInterface()
        {
            Grid root = new Grid();
            root.Margin = new Thickness(22);
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(14) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(14) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(14) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            Grid header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel headerCopy = new StackPanel();
            TextBlock title = Text("Recovery readiness", 25, palette.TextPrimary, FontWeights.SemiBold);
            headerCopy.Children.Add(title);
            headline = Text("Checking your recovery setup", 15, palette.TextSecondary, FontWeights.SemiBold);
            headline.Margin = new Thickness(0, 8, 0, 0);
            headerCopy.Children.Add(headline);
            detail = Text(
                "These checks only look; they change nothing. They test that Rewindle's saved password and your recovery key each open your backups, that there is free space, that nothing is left locked, and that a restore works.",
                12,
                palette.TextSecondary,
                FontWeights.Normal);
            detail.TextWrapping = TextWrapping.Wrap;
            detail.Margin = new Thickness(0, 3, 18, 0);
            headerCopy.Children.Add(detail);
            header.Children.Add(headerCopy);
            refreshButton = Button("Run checks again", true);
            refreshButton.VerticalAlignment = VerticalAlignment.Center;
            refreshButton.Click += async delegate { await RefreshHealth(); };
            // The accessible name stays the visible label, so a voice command can say it; the longer sentence is the help.
            AutomationProperties.SetHelpText(refreshButton, "Run the recovery checks again.");
            Grid.SetColumn(refreshButton, 1);
            header.Children.Add(refreshButton);
            root.Children.Add(header);

            Grid facts = new Grid();
            facts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            facts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
            facts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            facts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
            facts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            repositoryValue = Text("Not checked", 14, palette.TextPrimary, FontWeights.SemiBold);
            capacityValue = Text("Not checked", 14, palette.TextPrimary, FontWeights.SemiBold);
            lockValue = Text("Not checked", 14, palette.TextPrimary, FontWeights.SemiBold);
            AddFact(facts, 0, "BACKUP LOCATION", repositoryValue);
            AddFact(facts, 2, "FREE SPACE", capacityValue);
            AddFact(facts, 4, "LOCKS", lockValue);
            Grid.SetRow(facts, 2);
            root.Children.Add(facts);

            Border checksCard = Card();
            checksCard.Padding = new Thickness(12);
            checksGrid = new DataGrid();
            checksGrid.AutoGenerateColumns = false;
            checksGrid.IsReadOnly = true;
            checksGrid.CanUserAddRows = false;
            checksGrid.CanUserDeleteRows = false;
            checksGrid.HeadersVisibility = DataGridHeadersVisibility.Column;
            checksGrid.GridLinesVisibility = DataGridGridLinesVisibility.Horizontal;
            checksGrid.HorizontalGridLinesBrush = palette.GridLine;
            checksGrid.VerticalGridLinesBrush = Brushes.Transparent;
            checksGrid.Background = Brushes.Transparent;
            checksGrid.Foreground = palette.TableText;
            checksGrid.RowBackground = palette.RowEven;
            checksGrid.AlternatingRowBackground = palette.AlternatingRow;
            checksGrid.SelectionMode = DataGridSelectionMode.Single;
            checksGrid.MinRowHeight = 32;
            checksGrid.CanUserResizeRows = false;
            // Status is colored as well as worded, and the text columns wrap: a detail can name a journal file or carry a
            // sentence of explanation, which a single clipped line hid.
            DataGridTextColumn statusColumn = Column("STATUS", "StatusDisplay", 1.0);
            statusColumn.ElementStyle = CreateStatusCellStyle();
            checksGrid.Columns.Add(statusColumn);
            DataGridTextColumn checkColumn = Column("CHECK", "Summary", 2.4);
            checkColumn.ElementStyle = CreateTextCellStyle();
            checksGrid.Columns.Add(checkColumn);
            DataGridTextColumn detailColumn = Column("DETAIL", "Detail", 3.2);
            detailColumn.ElementStyle = CreateDetailCellStyle();
            checksGrid.Columns.Add(detailColumn);
            DashboardVisualStyle.ApplyDataGridChrome(checksGrid, palette);
            AutomationProperties.SetName(checksGrid, "Recovery readiness check results");
            AutomationProperties.SetHelpText(
                checksGrid,
                "Use the arrow keys to review each readiness result and its detail.");
            checksCard.Child = checksGrid;
            Grid.SetRow(checksCard, 4);
            root.Children.Add(checksCard);

            StackPanel footer = new StackPanel();
            progress = new ProgressBar();
            progress.Width = 260;
            progress.Height = 5;
            progress.IsIndeterminate = true;
            progress.Visibility = Visibility.Collapsed;
            progress.Background = palette.ProgressTrack;
            progress.Foreground = palette.AccentPrimary;
            progress.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties.SetName(progress, "Recovery readiness check progress");
            AutomationProperties.SetHelpText(
                progress,
                "The recovery checks are still running.");
            Grid progressRow = new Grid();
            progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            progressRow.Children.Add(progress);
            // While the checks run it says why the actions are dimmed; afterwards it says which of them are available, or
            // why none is, so the dimmed buttons below are never left unexplained.
            actionHint = Text(InspectingHint, 11, palette.TextSecondary, FontWeights.Normal);
            actionHint.Margin = new Thickness(12, 0, 0, 0);
            actionHint.TextWrapping = TextWrapping.Wrap;
            actionHint.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties.SetLiveSetting(actionHint, AutomationLiveSetting.Polite);
            Grid.SetColumn(actionHint, 1);
            progressRow.Children.Add(actionHint);
            footer.Children.Add(progressRow);

            WrapPanel actionBar = new WrapPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(0, 10, 0, 0)
            };
            // Each action's accessible name is its visible label (so "Run restore drill" works as a voice command); what it does,
            // and what it needs while it is dimmed, is the help text and the tooltip, and ApplyReport keeps both current.
            drillButton = Button(DrillLabel, false);
            drillButton.Margin = new Thickness(0, 0, 8, 0);
            drillButton.IsEnabled = false;
            drillButton.Click += async delegate { await RunRestoreDrill(); };
            SetActionHelp(
                drillButton,
                "Restores the restore test file and a small sample of your files from the latest backup into a new folder, checks them and records the result. Nothing is overwritten.");
            actionBar.Children.Add(drillButton);
            repairButton = Button(RepairLabel, false);
            repairButton.Margin = new Thickness(0, 0, 8, 0);
            repairButton.IsEnabled = false;
            repairButton.Click += async delegate { await RepairCredential(); };
            SetActionHelp(
                repairButton,
                "Available only when your recovery key works but Rewindle's saved password for this Windows account doesn't.");
            actionBar.Children.Add(repairButton);
            lockRepairButton = Button(LockRepairLabel, false);
            lockRepairButton.Margin = new Thickness(0, 0, 8, 0);
            lockRepairButton.IsEnabled = false;
            lockRepairButton.Click += async delegate { await RepairStaleLocks(); };
            SetActionHelp(
                lockRepairButton,
                "Available only when leftover locks are present and Rewindle's saved password works.");
            actionBar.Children.Add(lockRepairButton);
            keyRotationButton = Button(RotateLabel, false);
            keyRotationButton.Margin = new Thickness(0, 0, 8, 0);
            keyRotationButton.IsEnabled = false;
            keyRotationButton.Click += async delegate { await RotateKey(); };
            SetActionHelp(
                keyRotationButton,
                "Creates a new recovery key and saved password and checks both first, keeps the old ones in case something goes wrong, and finishes an interrupted key change.");
            actionBar.Children.Add(keyRotationButton);
            closeButton = Button("Close", false);
            closeButton.IsCancel = true;
            closeButton.Click += delegate { Close(); };
            actionBar.Children.Add(closeButton);
            footer.Children.Add(actionBar);
            Grid.SetRow(footer, 6);
            root.Children.Add(footer);
            AutomationProperties.SetName(root, "Independent repository and recovery readiness report");
            return root;
        }

        private async Task RefreshHealth()
        {
            if (inspecting) return;
            SetInspecting(true);
            RecoveryHealthReport report;
            try
            {
                report = await Task.Run(delegate { return RecoveryHealthLauncher.Inspect(configuration); });
            }
            catch (Exception error)
            {
                report = RecoveryHealthReport.Failure(error.Message);
            }
            ApplyReport(report);
            SetInspecting(false);
        }

        private void ApplyReport(RecoveryHealthReport report)
        {
            lastReport = report;
            if (report == null || !report.Loaded)
            {
                headline.Text = "The recovery checks couldn't run";
                headline.Foreground = palette.Danger;
                detail.Text = report == null ? "Rewindle got no result from the checks. Choose Run checks again." : report.ErrorMessage;
                checksGrid.ItemsSource = null;
                repositoryValue.Text = "Unavailable";
                capacityValue.Text = "Unavailable";
                lockValue.Text = "Unavailable";
                repairEligible = false;
                repairButton.IsEnabled = false;
                lockRepairEligible = false;
                lockRepairButton.IsEnabled = false;
                keyRotationEligible = false;
                keyRotationButton.IsEnabled = false;
                SetKeyRotationLabel(false);
                drillEligible = false;
                drillButton.IsEnabled = false;
                const string notInspected = "Unavailable until the checks finish. Choose Run checks again.";
                SetActionHelp(drillButton, notInspected);
                SetActionHelp(repairButton, notInspected);
                SetActionHelp(lockRepairButton, notInspected);
                SetActionHelp(keyRotationButton, notInspected);
                UpdateActionHint();
                Announce();
                return;
            }
            if (report.OverallStatus == "healthy")
            {
                headline.Text = "Your recovery setup checks out";
                headline.Foreground = palette.Success;
                detail.Text = "Every check passed, and nothing in your backups was changed.";
            }
            else if (report.OverallStatus == "warning")
            {
                headline.Text = "You can recover your files, with a few things to look at";
                headline.Foreground = palette.Warning;
                detail.Text = report.WarningCheckCount.ToString(CultureInfo.CurrentCulture) +
                    " check(s) need a look. See the list below.";
            }
            else
            {
                headline.Text = "Recovery needs attention";
                headline.Foreground = palette.Danger;
                detail.Text = report.FailedCheckCount.ToString(CultureInfo.CurrentCulture) +
                    " check(s) failed. Don't rely on recovery until they are fixed; see the list below.";
            }
            repositoryValue.Text = string.IsNullOrWhiteSpace(report.RepositoryId)
                ? "Not available"
                : "Format " + report.RepositoryFormat.ToString(CultureInfo.CurrentCulture) +
                    " · " + report.RepositoryId.Substring(0, Math.Min(10, report.RepositoryId.Length));
            capacityValue.Text = report.FreeBytes.HasValue
                ? FormatBytes(report.FreeBytes.Value) + " free · " + FormatBytes(report.ReserveBytes) + " reserve"
                : "Unavailable";
            lockValue.Text = report.ActiveLockCount.HasValue
                ? (report.ActiveLockCount.Value == 0
                    ? "None left over"
                    : report.ActiveLockCount.Value.ToString(CultureInfo.CurrentCulture) + " left over")
                : "Unavailable";
            checksGrid.ItemsSource = report.Checks;
            repairEligible = CheckPassed(report, "recovery_key") &&
                !CheckPassed(report, "active_credential");
            repairButton.IsEnabled = repairEligible && !inspecting;
            lockRepairEligible = report.ActiveLockCount.HasValue &&
                report.ActiveLockCount.Value > 0 && CheckPassed(report, "active_credential");
            lockRepairButton.IsEnabled = lockRepairEligible && !inspecting;
            bool rotationJournalPending = CheckDetailContains(
                report,
                "pending_transaction",
                "credential-rotation.journal.json");
            keyRotationEligible = CheckPassed(report, "active_credential") &&
                CheckPassed(report, "recovery_key") &&
                report.ActiveLockCount.HasValue && report.ActiveLockCount.Value == 0 &&
                (CheckPassed(report, "pending_transaction") || rotationJournalPending);
            keyRotationButton.IsEnabled = keyRotationEligible && !inspecting;
            SetKeyRotationLabel(rotationJournalPending);
            // The same sentence is the help text and the tooltip. Tooltips show on a dimmed button, so the reason a button is
            // unavailable is on the button, not only in the accessibility tree.
            SetActionHelp(
                repairButton,
                repairEligible
                    ? "Uses your recovery key to replace Rewindle's saved password for this Windows account. Nothing else changes."
                    : "Available only when your recovery key works but Rewindle's saved password for this Windows account doesn't.");
            SetActionHelp(
                lockRepairButton,
                lockRepairEligible
                    ? "Windows will ask for your permission. Rewindle then removes only locks left over from interrupted backups, and only while no backup is running."
                    : "Available only when leftover locks are present and Rewindle's saved password works.");
            SetActionHelp(
                keyRotationButton,
                rotationJournalPending
                    ? "Finishes the key change that was interrupted, and checks it."
                    : keyRotationEligible
                        ? "Creates a new recovery key and saved password, checks that both work, and keeps the old ones in case something goes wrong."
                        : "Available only when your recovery key and saved password both work, no locks are left over, and no other change is unfinished.");
            drillEligible = CheckNeedsReview(report, "restore_drill") &&
                CheckPassed(report, "recovery_key") &&
                CheckPassed(report, "recovery_bundle") &&
                CheckPassed(report, "last_verification") &&
                CheckPassed(report, "pending_transaction") &&
                report.ActiveLockCount.HasValue && report.ActiveLockCount.Value == 0;
            drillButton.IsEnabled = drillEligible && !inspecting;
            SetActionHelp(
                drillButton,
                drillEligible
                    ? "Restores the restore test file and a small sample of your files from the latest backup into a new folder, checks them and records the result. Nothing is overwritten."
                    : "Available only when a restore drill is due, your recovery key and recovery information check out, the latest backup was checked, and no locks or unfinished changes remain.");
            UpdateActionHint();
            Announce();
        }

        // The key button starts a rotation, or resumes one that was interrupted. The flag is what RotateKey consults.
        private void SetKeyRotationLabel(bool resuming)
        {
            resumingRotation = resuming;
            string label = resuming ? ResumeLabel : RotateLabel;
            keyRotationButton.Content = label;
            AutomationProperties.SetName(keyRotationButton, label);
        }

        // The help text and the tooltip carry the same sentence. The tooltip is a wrapping text block: a plain string would
        // run along one line as wide as the sentence is long.
        private static void SetActionHelp(Button button, string text)
        {
            AutomationProperties.SetHelpText(button, text);
            TextBlock tip = new TextBlock();
            tip.Text = text;
            tip.TextWrapping = TextWrapping.Wrap;
            tip.MaxWidth = 360;
            button.ToolTip = tip;
        }

        // One line above the action bar: why the actions are dimmed while the checks run, then which of them are available,
        // or why none is.
        private void UpdateActionHint()
        {
            if (actionHint == null)
            {
                return;
            }
            if (inspecting)
            {
                actionHint.Margin = new Thickness(12, 0, 0, 0);
                actionHint.Text = InspectingHint;
                return;
            }
            actionHint.Margin = new Thickness(0);
            actionHint.Text = DescribeActions(lastReport);
        }

        private string DescribeActions(RecoveryHealthReport report)
        {
            if (report == null || !report.Loaded)
            {
                return "Actions are unavailable until the checks finish. Choose Run checks again.";
            }
            List<string> available = new List<string>();
            if (drillEligible) available.Add(DrillLabel);
            if (repairEligible) available.Add(RepairLabel);
            if (lockRepairEligible) available.Add(LockRepairLabel);
            if (keyRotationEligible) available.Add(resumingRotation ? ResumeLabel : RotateLabel);
            bool healthy = report.OverallStatus == "healthy";
            if (available.Count > 0)
            {
                return (healthy ? "Nothing to repair: all checks passed. " : string.Empty) +
                    "Available now: " + string.Join(", ", available.ToArray()) + ".";
            }
            return healthy
                ? "Nothing to repair: all checks passed."
                : "No repair here applies to the current results. Each dimmed action says what it needs when you point at it.";
        }

        // Status in a color as well as in words, so Ready, Review and Action needed are not told apart by wording alone.
        private Style CreateStatusCellStyle()
        {
            Style style = CreateTextCellStyle();
            style.Setters.Add(new Setter(TextBlock.FontWeightProperty, FontWeights.SemiBold));
            // Anything that is neither Ready nor Review reads "Action needed" (see RecoveryHealthCheck.StatusDisplay).
            style.Setters.Add(new Setter(TextBlock.ForegroundProperty, palette.Danger));
            DataTrigger ready = new DataTrigger();
            ready.Binding = new Binding("Status");
            ready.Value = "pass";
            ready.Setters.Add(new Setter(TextBlock.ForegroundProperty, palette.Success));
            style.Triggers.Add(ready);
            DataTrigger review = new DataTrigger();
            review.Binding = new Binding("Status");
            review.Value = "warn";
            review.Setters.Add(new Setter(TextBlock.ForegroundProperty, palette.Warning));
            style.Triggers.Add(review);
            // Last, so it wins: a selected row paints its text in the selection's own color, and a status color set on the text
            // itself would sit on that fill instead (in high contrast all three are the window text color, which can be
            // unreadable on the highlight). The words say the status either way.
            DataTrigger selected = new DataTrigger();
            selected.Binding = new Binding("IsSelected")
            {
                RelativeSource = new RelativeSource(RelativeSourceMode.FindAncestor, typeof(DataGridCell), 1)
            };
            selected.Value = true;
            selected.Setters.Add(new Setter(
                TextBlock.ForegroundProperty,
                new Binding("Foreground")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.FindAncestor, typeof(DataGridCell), 1)
                }));
            style.Triggers.Add(selected);
            return style;
        }

        // A detail can name a journal file or run to a sentence. The cell wraps, and the whole text is also its tooltip for a
        // window narrow enough to cut a very long one short. An empty detail has no tooltip, rather than an empty bubble.
        private static Style CreateDetailCellStyle()
        {
            Style style = CreateTextCellStyle();
            style.Setters.Add(new Setter(FrameworkElement.ToolTipProperty, new Binding("Detail")));
            DataTrigger empty = new DataTrigger();
            empty.Binding = new Binding("Detail");
            empty.Value = string.Empty;
            empty.Setters.Add(new Setter(FrameworkElement.ToolTipProperty, null));
            style.Triggers.Add(empty);
            return style;
        }

        // Cell text wraps, sits in the middle of its row and lines up with the column header's text.
        private static Style CreateTextCellStyle()
        {
            Style style = new Style(typeof(TextBlock));
            style.Setters.Add(new Setter(TextBlock.TextWrappingProperty, TextWrapping.Wrap));
            style.Setters.Add(new Setter(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center));
            style.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(8, 6, 8, 6)));
            return style;
        }

        private async Task RunRestoreDrill()
        {
            if (inspecting || !drillEligible) return;
            // A real restore, so it is asked for like the other repairs: Cancel is the default and the focused button.
            bool confirmed = DashboardDialog.Confirm(
                this,
                palette,
                "Run a restore drill?",
                "Rewindle will restore a small sample of your latest backup into a new folder and check " +
                    "every restored file. Your original files, backups and keys are not touched.",
                new[]
                {
                    "It uses your latest checked backup: the restore test file plus a small sample of your files.",
                    "Rewindle puts them in a new folder in its own data folder, checks every restored file and records the result.",
                    "Nothing is overwritten or deleted: not your files, your backups, your keys or an earlier restore folder. The restored sample is kept so you can look at it."
                },
                DrillLabel,
                "Not now",
                true);
            if (!confirmed) return;

            SetInspecting(true);
            headline.Text = "Waiting for the Windows permission prompt";
            headline.Foreground = palette.TextPrimary;
            detail.Text = "Choose Yes in the Windows permission prompt to continue. Your recovery key stays inside Rewindle's restore tool.";
            Announce();
            RestoreManagerResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return RestoreManagerLauncher.RunRecoveryDrill(
                        configuration,
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                headline.Text = "Restore drill started";
                                detail.Text = "Restoring a small sample of your files and checking it.";
                                Announce();
                            }));
                        },
                        delegate(RestoreManagerProgress value)
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                detail.Text = value.Message;
                                Announce();
                            }));
                        });
                });
            }
            catch (Exception error)
            {
                result = RestoreManagerResult.Failure(error.Message, -1);
            }
            if (result.UserCancelled)
            {
                headline.Text = "Permission not given";
                headline.Foreground = palette.Warning;
                detail.Text = "You didn't allow the change in the Windows permission prompt. Nothing was restored or changed.";
                SetInspecting(false);
                Announce();
                return;
            }
            if (!result.Succeeded)
            {
                headline.Text = result.Report != null && result.Report.Verified
                    ? "The restore worked, but the result wasn't saved"
                    : "The restore drill didn't finish";
                headline.Foreground = palette.Warning;
                detail.Text = (result.ErrorMessage ?? "The restore drill failed.") +
                    (result.Report == null || string.IsNullOrWhiteSpace(result.Report.Target)
                        ? string.Empty
                        : " The restored files are in: " + result.Report.Target);
                SetInspecting(false);
                Announce();
                return;
            }

            headline.Text = "Restore drill passed";
            headline.Foreground = palette.Success;
            detail.Text = "The restored sample is kept in: " + result.Report.Target;
            Announce();
            RecoveryHealthReport health;
            try
            {
                health = await Task.Run(delegate { return RecoveryHealthLauncher.Inspect(configuration); });
            }
            catch (Exception error)
            {
                health = RecoveryHealthReport.Failure(error.Message);
            }
            string retainedTarget = result.Report.Target;
            ApplyReport(health);
            detail.Text = detail.Text + " The restored sample is kept in: " + retainedTarget;
            SetInspecting(false);
            Announce();
        }

        private async Task RepairCredential()
        {
            if (inspecting || !repairEligible) return;
            bool confirmed = DashboardDialog.Confirm(
                this,
                palette,
                "Repair the active credential?",
                "Rewindle will replace its saved password for this Windows account, once your recovery key is proven to open " +
                    "your backups, so scheduled backups can open them again.",
                new[]
                {
                    "Only the saved password is replaced, and only after your recovery key has been checked.",
                    "The repository, repository keys, snapshots and the recovery-key file are not changed."
                },
                RepairLabel,
                "Cancel",
                true);
            if (!confirmed) return;
            SetInspecting(true);
            headline.Text = "Waiting for the Windows permission prompt";
            detail.Text = "Choose Yes in the Windows permission prompt to continue. Rewindle makes sure no backup is running first.";
            Announce();
            CredentialRepairResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return CredentialRepairLauncher.Repair(
                        configuration,
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                headline.Text = "Repair started";
                                detail.Text = "Checking your recovery key before replacing the saved password.";
                                Announce();
                            }));
                        });
                });
            }
            catch (Exception error)
            {
                result = CredentialRepairResult.Failure(error.Message, null);
            }
            if (result.UserCancelled)
            {
                headline.Text = "Permission not given";
                detail.Text = "You didn't allow the change in the Windows permission prompt. Nothing was changed.";
                headline.Foreground = palette.Warning;
                SetInspecting(false);
                Announce();
                return;
            }
            if (result.Succeeded && result.Health != null)
            {
                ApplyReport(result.Health);
                headline.Text = "Saved password repaired and checked";
                headline.Foreground = palette.Success;
                detail.Text = "The recovery key and the replacement CurrentUser credential both unlock the same repository.";
                SetInspecting(false);
                Announce();
                return;
            }
            if (result.Health != null && result.Health.Loaded)
            {
                ApplyReport(result.Health);
            }
            else
            {
                headline.Text = "The repair didn't finish";
                headline.Foreground = palette.Danger;
                detail.Text = result.ErrorMessage;
            }
            SetInspecting(false);
            Announce();
        }

        private async Task RepairStaleLocks()
        {
            if (inspecting || !lockRepairEligible) return;
            bool confirmed = DashboardDialog.Confirm(
                this,
                palette,
                "Remove leftover locks?",
                "Rewindle will remove only locks left over from interrupted backups, so they stop blocking new " +
                    "backups. None of your backups is changed.",
                new[]
                {
                    "Rewindle first makes sure no backup is running, and stops if one is.",
                    "It never uses --remove-all, so locks Restic does not classify as stale are left alone."
                },
                LockRepairLabel,
                "Cancel",
                true);
            if (!confirmed) return;
            SetInspecting(true);
            headline.Text = "Waiting for the Windows permission prompt";
            detail.Text = "Choose Yes in the Windows permission prompt to continue. No lock is removed until Rewindle has checked that no backup is running.";
            Announce();
            StaleLockRepairResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return StaleLockRepairLauncher.Repair(
                        configuration,
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                headline.Text = "Lock repair started";
                                detail.Text = "Checking that no backup is running.";
                                Announce();
                            }));
                        });
                });
            }
            catch (Exception error)
            {
                result = StaleLockRepairResult.Failure(error.Message, null);
            }
            if (result.UserCancelled)
            {
                headline.Text = "Permission not given";
                headline.Foreground = palette.Warning;
                detail.Text = "You didn't allow the change in the Windows permission prompt. Nothing was changed.";
                SetInspecting(false);
                Announce();
                return;
            }
            if (result.Health != null && result.Health.Loaded)
            {
                ApplyReport(result.Health);
            }
            if (result.Succeeded)
            {
                headline.Text = "Leftover locks removed";
                headline.Foreground = palette.Success;
                detail.Text = "A fresh check confirms that no locks remain.";
            }
            else
            {
                headline.Text = "The locks weren't fully removed";
                headline.Foreground = palette.Warning;
                detail.Text = result.ErrorMessage;
            }
            SetInspecting(false);
            Announce();
        }

        private async Task RotateKey()
        {
            if (inspecting || !keyRotationEligible) return;
            // Set from the same report as the button's label, so the confirmation always matches what the button said.
            bool resuming = resumingRotation;
            bool confirmed = resuming
                ? DashboardDialog.Confirm(
                    this,
                    palette,
                    "Resume key rotation?",
                    "A key change was interrupted. Rewindle will finish it safely, or go back to the last keys that worked.",
                    new[]
                    {
                        "Rewindle checks the new key first, then either finishes the change or puts the previous keys back."
                    },
                    ResumeLabel,
                    "Cancel",
                    true)
                : DashboardDialog.Confirm(
                    this,
                    palette,
                    "Rotate keys?",
                    "Rewindle will create a new recovery key and saved password, check that both work, and only then switch " +
                        "over. Nothing you have backed up is deleted.",
                    new[]
                    {
                        "The new key is created and tested before anything on this computer changes.",
                        "The previous repository key and a restricted copy of the previous recovery-key file are kept for rollback.",
                        "After rotating, store the new recovery key away from this computer."
                    },
                    RotateLabel,
                    "Cancel",
                    true);
            if (!confirmed) return;
            SetInspecting(true);
            headline.Text = "Waiting for the Windows permission prompt";
            detail.Text = resuming
                ? "Rewindle will check the record of the interrupted change before it continues."
                : "Your current password and key stay in use until the new key has been tested.";
            Announce();
            KeyRotationResult result;
            try
            {
                result = await Task.Run(delegate
                {
                    return KeyRotationLauncher.Rotate(
                        configuration,
                        delegate
                        {
                            Dispatcher.BeginInvoke(new Action(delegate
                            {
                                headline.Text = resuming
                                    ? "Finishing the key change"
                                    : "Key change started";
                                detail.Text = "Checking the new key and recovery key. No backup can run until this finishes.";
                                Announce();
                            }));
                        });
                });
            }
            catch (Exception error)
            {
                result = KeyRotationResult.Failure(error.Message, null);
            }
            if (result.UserCancelled)
            {
                headline.Text = "Permission not given";
                headline.Foreground = palette.Warning;
                detail.Text = "You didn't allow the change in the Windows permission prompt. No key was changed.";
                SetInspecting(false);
                Announce();
                return;
            }
            if (result.Health != null && result.Health.Loaded) ApplyReport(result.Health);
            if (result.Succeeded)
            {
                headline.Text = "New key created and checked";
                headline.Foreground = palette.Success;
                detail.Text = "The new saved password and recovery key both work. The old recovery key file is still beside the new one, and the old key still works, so you can go back if needed.";
            }
            else
            {
                headline.Text = "The key change needs attention";
                headline.Foreground = palette.Warning;
                detail.Text = result.ErrorMessage;
            }
            SetInspecting(false);
            Announce();
        }

        private void Announce()
        {
            AutomationProperties.SetName(headline, headline.Text + ". " + detail.Text);
            AutomationProperties.SetLiveSetting(
                headline,
                headline.Foreground == palette.Danger
                    ? AutomationLiveSetting.Assertive
                    : AutomationLiveSetting.Polite);
        }

        private void SetInspecting(bool value)
        {
            inspecting = value;
            refreshButton.IsEnabled = !value;
            repairButton.IsEnabled = !value && repairEligible;
            lockRepairButton.IsEnabled = !value && lockRepairEligible;
            keyRotationButton.IsEnabled = !value && keyRotationEligible;
            drillButton.IsEnabled = !value && drillEligible;
            closeButton.IsEnabled = !value;
            bool wasVisible = progress.Visibility == Visibility.Visible;
            progress.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            DashboardVisualStyle.SetBusy(progress, value);
            if (value && !wasVisible)
            {
                DashboardVisualStyle.Reveal(
                    progress,
                    DashboardVisualStyle.DefaultDuration,
                    TimeSpan.Zero,
                    0.0);
            }
            UpdateActionHint();
            if (value)
            {
                headline.Text = "Running independent checks";
                headline.Foreground = palette.TextPrimary;
                detail.Text = "Authenticating both recovery paths and validating protected artifacts.";
                Announce();
            }
        }

        private void OnClosing(object sender, CancelEventArgs args)
        {
            if (!inspecting) return;
            args.Cancel = true;
            headline.Text = "Readiness checks still running";
            detail.Text = "Keep this window open until the read-only inspection finishes.";
            Announce();
        }

        private void AddFact(Grid grid, int column, string label, TextBlock value)
        {
            Border card = Card();
            card.Padding = new Thickness(14, 12, 14, 12);
            StackPanel copy = new StackPanel();
            copy.Children.Add(Text(label, 10, palette.AccentInk, FontWeights.Bold));
            value.Margin = new Thickness(0, 6, 0, 0);
            value.TextWrapping = TextWrapping.Wrap;
            copy.Children.Add(value);
            card.Child = copy;
            Grid.SetColumn(card, column);
            grid.Children.Add(card);
        }

        // The page's card radius (.surface), as the schedule and location dialogs draw theirs.
        private Border Card()
        {
            return new Border
            {
                Background = palette.Surface,
                BorderBrush = palette.Border,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(14)
            };
        }

        // The primary button is ink on the canvas, like the page's own, and the others are quiet; both are pills.
        private Button Button(string text, bool primary)
        {
            Button button = new Button();
            button.Content = text;
            button.Padding = new Thickness(14, 8, 14, 8);
            button.MinHeight = 36;
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
            AutomationProperties.SetName(button, text);
            return button;
        }

        private static TextBlock Text(string value, double size, Brush brush, FontWeight weight)
        {
            return new TextBlock
            {
                Text = value,
                FontSize = size,
                Foreground = brush,
                FontWeight = weight
            };
        }

        private static DataGridTextColumn Column(string header, string property, double width)
        {
            return new DataGridTextColumn
            {
                Header = header,
                Binding = new Binding(property),
                Width = new DataGridLength(width, DataGridLengthUnitType.Star)
            };
        }

        private static string FormatBytes(long value)
        {
            string[] units = { "B", "KiB", "MiB", "GiB", "TiB" };
            double amount = Math.Max(0, value);
            int index = 0;
            while (amount >= 1024 && index < units.Length - 1)
            {
                amount /= 1024;
                index++;
            }
            return amount.ToString(index == 0 ? "0" : "0.0", CultureInfo.CurrentCulture) + " " + units[index];
        }

        private static bool CheckPassed(RecoveryHealthReport report, string id)
        {
            if (report == null || report.Checks == null) return false;
            foreach (RecoveryHealthCheck check in report.Checks)
            {
                if (check.Id == id && check.Status == "pass") return true;
            }
            return false;
        }

        private static bool CheckNeedsReview(RecoveryHealthReport report, string id)
        {
            if (report == null || report.Checks == null) return false;
            foreach (RecoveryHealthCheck check in report.Checks)
            {
                if (check.Id == id && check.Status == "warn") return true;
            }
            return false;
        }

        private static bool CheckDetailContains(
            RecoveryHealthReport report,
            string id,
            string value)
        {
            if (report == null || report.Checks == null) return false;
            foreach (RecoveryHealthCheck check in report.Checks)
            {
                if (check.Id == id && !string.IsNullOrEmpty(check.Detail) &&
                    check.Detail.IndexOf(value, StringComparison.OrdinalIgnoreCase) >= 0)
                    return true;
            }
            return false;
        }
    }
}
