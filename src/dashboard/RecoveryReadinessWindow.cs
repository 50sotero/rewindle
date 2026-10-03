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
            headline = Text("Preparing independent checks", 15, palette.TextSecondary, FontWeights.SemiBold);
            headline.Margin = new Thickness(0, 8, 0, 0);
            headerCopy.Children.Add(headline);
            detail = Text(
                "Read-only inspection checks the repository, active credential, recovery key, recovery bundle, capacity, locks, and restore path separately.",
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
            AutomationProperties.SetHelpText(refreshButton, "Run the recovery readiness checks again.");
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
            AddFact(facts, 0, "REPOSITORY", repositoryValue);
            AddFact(facts, 2, "CAPACITY", capacityValue);
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
                "Indicates that the protected read-only readiness inspection is still running.");
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
                "Restores the latest verified plan-bound snapshot into a new protected folder, verifies the restore test file and a bounded sample of ordinary data, then records readiness evidence.");
            actionBar.Children.Add(drillButton);
            repairButton = Button(RepairLabel, false);
            repairButton.Margin = new Thickness(0, 0, 8, 0);
            repairButton.IsEnabled = false;
            repairButton.Click += async delegate { await RepairCredential(); };
            SetActionHelp(
                repairButton,
                "Available only when the recovery key works but the active CurrentUser credential does not.");
            actionBar.Children.Add(repairButton);
            lockRepairButton = Button(LockRepairLabel, false);
            lockRepairButton.Margin = new Thickness(0, 0, 8, 0);
            lockRepairButton.IsEnabled = false;
            lockRepairButton.Click += async delegate { await RepairStaleLocks(); };
            SetActionHelp(
                lockRepairButton,
                "Available only when repository locks are present and the active credential works.");
            actionBar.Children.Add(lockRepairButton);
            keyRotationButton = Button(RotateLabel, false);
            keyRotationButton.Margin = new Thickness(0, 0, 8, 0);
            keyRotationButton.IsEnabled = false;
            keyRotationButton.Click += async delegate { await RotateKey(); };
            SetActionHelp(
                keyRotationButton,
                "Adds and verifies a new key first, retains the prior repository and recovery keys, and resumes an interrupted rotation journal.");
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
                headline.Text = "Readiness inspection unavailable";
                headline.Foreground = palette.Danger;
                detail.Text = report == null ? "No health report was returned." : report.ErrorMessage;
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
                const string notInspected = "Unavailable until a readiness inspection completes. Choose Run checks again to retry.";
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
                headline.Text = "Recovery path independently verified";
                headline.Foreground = palette.Success;
                detail.Text = "All available readiness checks passed without changing the repository.";
            }
            else if (report.OverallStatus == "warning")
            {
                headline.Text = "Recovery is available, with items to review";
                headline.Foreground = palette.Warning;
                detail.Text = report.WarningCheckCount.ToString(CultureInfo.CurrentCulture) +
                    " readiness check(s) need review.";
            }
            else
            {
                headline.Text = "Recovery readiness needs attention";
                headline.Foreground = palette.Danger;
                detail.Text = report.FailedCheckCount.ToString(CultureInfo.CurrentCulture) +
                    " independent check(s) failed. Review each result before relying on recovery.";
            }
            repositoryValue.Text = string.IsNullOrWhiteSpace(report.RepositoryId)
                ? "ID unavailable"
                : "Format " + report.RepositoryFormat.ToString(CultureInfo.CurrentCulture) +
                    " · " + report.RepositoryId.Substring(0, Math.Min(10, report.RepositoryId.Length));
            capacityValue.Text = report.FreeBytes.HasValue
                ? FormatBytes(report.FreeBytes.Value) + " free · " + FormatBytes(report.ReserveBytes) + " reserve"
                : "Unavailable";
            lockValue.Text = report.ActiveLockCount.HasValue
                ? (report.ActiveLockCount.Value == 0
                    ? "No locks"
                    : report.ActiveLockCount.Value.ToString(CultureInfo.CurrentCulture) + " require review")
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
                    ? "Use the independently verified recovery key to replace only the broken CurrentUser DPAPI envelope."
                    : "Repair is available only when the recovery key passes and the active credential fails.");
            SetActionHelp(
                lockRepairButton,
                lockRepairEligible
                    ? "After Windows approval, block active backup work and ask Restic to remove only locks it classifies as stale."
                    : "Stale-lock repair is available only when locks are present and the active credential passes.");
            SetActionHelp(
                keyRotationButton,
                rotationJournalPending
                    ? "Resume and verify the protected interrupted key-rotation transaction."
                    : keyRotationEligible
                        ? "Add and prove a new repository key, publish matching active and recovery credentials, and retain the prior key for rollback."
                        : "Key rotation requires both credentials, no repository locks, and no unrelated pending transaction.");
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
                    ? "Restores the latest verified plan-bound snapshot into a new protected folder, verifies the restore test file and a bounded sample of ordinary data, then records readiness evidence."
                    : "A restore drill is available only when the restore-drill check asks for review, the recovery key, recovery bundle and last verification pass, and no locks or pending changes remain.");
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
                return "Actions are unavailable until a readiness inspection completes. Choose Run checks again to retry.";
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
                "Rewindle will restore a small sample of your latest verified backup into a new protected folder and check " +
                    "every restored file. Your original files, backups and keys are not touched.",
                new[]
                {
                    "The latest verified snapshot is used, with the restore test file plus a bounded sample of ordinary data.",
                    "The protected manager creates a new nonce-bound folder under ProgramData for it, verifies every restored file and records the evidence.",
                    "It never overwrites or deletes sources, repository data, keys, snapshots, or an existing restore folder. The restored sample is kept so you can inspect it."
                },
                DrillLabel,
                "Not now",
                true);
            if (!confirmed) return;

            SetInspecting(true);
            headline.Text = "Waiting for Windows approval";
            headline.Foreground = palette.TextPrimary;
            detail.Text = "The recovery key stays inside the elevated protected restore manager.";
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
                                headline.Text = "Restore drill approved";
                                detail.Text = "Restoring and independently verifying the bounded sample.";
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
                headline.Text = "Windows approval cancelled";
                headline.Foreground = palette.Warning;
                detail.Text = "No restore was started and no repository or protected evidence changed.";
                SetInspecting(false);
                Announce();
                return;
            }
            if (!result.Succeeded)
            {
                headline.Text = result.Report != null && result.Report.Verified
                    ? "Restore verified; evidence recording failed"
                    : "Restore drill did not complete";
                headline.Foreground = palette.Warning;
                detail.Text = (result.ErrorMessage ?? "The protected restore drill failed.") +
                    (result.Report == null || string.IsNullOrWhiteSpace(result.Report.Target)
                        ? string.Empty
                        : " Retained target: " + result.Report.Target);
                SetInspecting(false);
                Announce();
                return;
            }

            headline.Text = "Restore drill verified and recorded";
            headline.Foreground = palette.Success;
            detail.Text = "Retained protected sample: " + result.Report.Target;
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
            detail.Text = detail.Text + " Retained protected sample: " + retainedTarget;
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
                "Rewindle will replace the active Windows-protected credential, once your recovery key is proven to unlock " +
                    "the repository, so scheduled backups can unlock it again.",
                new[]
                {
                    "Only the CurrentUser DPAPI envelope is replaced, and only after the recovery key is authenticated.",
                    "The repository, repository keys, snapshots and the recovery-key file are not changed."
                },
                RepairLabel,
                "Cancel",
                true);
            if (!confirmed) return;
            SetInspecting(true);
            headline.Text = "Waiting for Windows approval";
            detail.Text = "Credential repair is protected and uses the shared backup-operation lock.";
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
                                headline.Text = "Credential repair approved";
                                detail.Text = "Authenticating the recovery key before replacing the active envelope.";
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
                headline.Text = "Windows approval cancelled";
                detail.Text = "No credential or repository data was changed.";
                headline.Foreground = palette.Warning;
                SetInspecting(false);
                Announce();
                return;
            }
            if (result.Succeeded && result.Health != null)
            {
                ApplyReport(result.Health);
                headline.Text = "Active credential repaired and independently verified";
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
                headline.Text = "Credential repair did not complete";
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
                "Remove stale repository locks?",
                "Rewindle will ask Restic to remove only the locks it considers stale, so a leftover lock stops blocking " +
                    "backups. Snapshots and repository data are not changed.",
                new[]
                {
                    "The protected helper first takes the shared operation lock and stops if any Restic process is running.",
                    "It never uses --remove-all, so locks Restic does not classify as stale are left alone."
                },
                LockRepairLabel,
                "Cancel",
                true);
            if (!confirmed) return;
            SetInspecting(true);
            headline.Text = "Waiting for Windows approval";
            detail.Text = "No lock will be removed until activity checks pass.";
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
                                headline.Text = "Stale-lock repair approved";
                                detail.Text = "Proving protected operations and Restic processes are inactive.";
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
                headline.Text = "Windows approval cancelled";
                headline.Foreground = palette.Warning;
                detail.Text = "No repository lock or data was changed.";
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
                headline.Text = "Stale repository locks repaired";
                headline.Foreground = palette.Success;
                detail.Text = "A fresh read-only inspection confirms that no repository locks remain.";
            }
            else
            {
                headline.Text = "Repository locks were not fully repaired";
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
                    "A key rotation was interrupted. Rewindle will finish it safely, or return to the last known-good keys.",
                    new[]
                    {
                        "The helper authenticates the staged key, then either completes the publish or restores the known-good prior state."
                    },
                    ResumeLabel,
                    "Cancel",
                    true)
                : DashboardDialog.Confirm(
                    this,
                    palette,
                    "Rotate keys?",
                    "Rewindle will add a new repository key and recovery key, check that both work, and only then switch " +
                        "over. Nothing you have backed up is deleted.",
                    new[]
                    {
                        "A new Restic key is added and authenticated before any local credential changes.",
                        "The previous repository key and a restricted copy of the previous recovery-key file are kept for rollback.",
                        "After rotating, store the new recovery key away from this computer."
                    },
                    RotateLabel,
                    "Cancel",
                    true);
            if (!confirmed) return;
            SetInspecting(true);
            headline.Text = "Waiting for Windows approval";
            detail.Text = resuming
                ? "The protected journal will be validated before recovery continues."
                : "The prior credential remains active until Restic proves the new repository key.";
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
                                    ? "Key-rotation recovery approved"
                                    : "Key rotation approved";
                                detail.Text = "Holding the shared operation lock while repository and recovery credentials are independently verified.";
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
                headline.Text = "Windows approval cancelled";
                headline.Foreground = palette.Warning;
                detail.Text = "No key rotation was started.";
                SetInspecting(false);
                Announce();
                return;
            }
            if (result.Health != null && result.Health.Loaded) ApplyReport(result.Health);
            if (result.Succeeded)
            {
                headline.Text = "New and rollback credentials independently verified";
                headline.Foreground = palette.Success;
                detail.Text = "The new active and recovery credentials work. The previous recovery file remains beside the configured key and the prior Restic key was not retired.";
            }
            else
            {
                headline.Text = "Key rotation needs attention";
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
