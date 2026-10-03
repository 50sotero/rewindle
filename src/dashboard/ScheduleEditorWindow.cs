using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace ResticBackuper.Dashboard
{
    internal sealed class ScheduleEditorWindow : Window
    {
        // Whole sentences, so they read the same beside the field, in the status line and in the summary of a refused review.
        private const string TimeErrorText = "Enter a valid 24-hour time, for example 02:00 or 18:30.";
        private const string DaysErrorText = "Select at least one day, or choose Every day.";

        private readonly TaskSchedule installed;
        private readonly DashboardThemePalette palette;
        private readonly RadioButton dailyRadio;
        private readonly RadioButton selectedDaysRadio;
        private readonly TextBox timeText;
        private readonly WrapPanel dayPanel;
        private readonly Dictionary<DayOfWeek, CheckBox> dayChecks;
        private readonly CheckBox enabledCheck;
        private readonly CheckBox startWhenAvailableCheck;
        private readonly CheckBox wakeCheck;
        private readonly CheckBox allowBatteryCheck;
        private readonly CheckBox finishOnBatteryCheck;
        private readonly TextBlock validationText;
        private readonly TextBlock changeSummaryText;
        private readonly TextBlock timeError;
        private readonly TextBlock daysError;
        private readonly TextBlock daysHint;
        private readonly Button reviewButton;
        // The time field only reports a problem once the user has left it (or pressed Review), so typing "2" on the way to
        // "20:00" is not an error. The day boxes are deliberate clicks, so their problem shows at once.
        private bool timeTouched;
        private bool valuesLoaded;

        public ScheduleEditorWindow(TaskSchedule installed, DashboardThemePalette palette)
        {
            if (installed == null)
            {
                throw new ArgumentNullException("installed");
            }
            if (palette == null)
            {
                throw new ArgumentNullException("palette");
            }

            this.installed = installed;
            this.palette = palette;
            this.dayChecks = new Dictionary<DayOfWeek, CheckBox>();

            Title = "Backup schedule";
            Width = 780;
            Height = 690;
            MinWidth = 680;
            // The cards scroll and the footer sits outside the scroll area, so the window can be short.
            MinHeight = 440;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ResizeMode = ResizeMode.CanResize;
            ShowInTaskbar = false;
            DashboardVisualStyle.ApplyWindow(this, palette);
            AutomationProperties.SetName(this, "Edit automatic backup schedule");

            // Heading, scrolling cards, then the status line and the footer, which are always on screen.
            Grid root = new Grid { Margin = new Thickness(28, 24, 28, 20) };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            StackPanel heading = new StackPanel();
            TextBlock title = new TextBlock
            {
                Text = "Backup schedule",
                FontSize = 24,
                FontWeight = FontWeights.SemiBold,
                Foreground = palette.TextPrimary
            };
            heading.Children.Add(title);
            TextBlock intro = new TextBlock
            {
                Text = "Choose when Windows should run the protected backup. Saving a schedule never starts a backup immediately.",
                FontSize = 12,
                Foreground = palette.TextSecondary,
                Margin = new Thickness(0, 5, 0, 18),
                TextWrapping = TextWrapping.Wrap
            };
            heading.Children.Add(intro);
            root.Children.Add(heading);

            ScrollViewer scroll = new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
            };
            Grid.SetRow(scroll, 1);
            root.Children.Add(scroll);

            StackPanel content = new StackPanel();
            scroll.Content = content;

            Border installedCard = CreateSection();
            StackPanel installedPanel = new StackPanel();
            installedPanel.Children.Add(CreateSectionTitle("Installed schedule"));
            installedPanel.Children.Add(new TextBlock
            {
                Text = installed.Summary,
                FontSize = 16,
                FontWeight = FontWeights.SemiBold,
                Foreground = palette.TextPrimary,
                Margin = new Thickness(0, 4, 0, 3)
            });
            installedPanel.Children.Add(new TextBlock
            {
                Text = "Next run: " + installed.NextRunDisplay + "\n" + installed.SettingsSummary,
                FontSize = 12,
                Foreground = palette.TextSecondary,
                TextWrapping = TextWrapping.Wrap
            });
            installedCard.Child = installedPanel;
            content.Children.Add(installedCard);

            Border frequencyCard = CreateSection();
            frequencyCard.Margin = new Thickness(0, 12, 0, 0);
            StackPanel frequencyPanel = new StackPanel();
            frequencyPanel.Children.Add(CreateSectionTitle("Frequency and time"));

            dailyRadio = CreateRadio("Every day", "ScheduleFrequency");
            dailyRadio.Margin = new Thickness(0, 10, 0, 0);
            selectedDaysRadio = CreateRadio("Selected days", "ScheduleFrequency");
            selectedDaysRadio.Margin = new Thickness(0, 7, 0, 0);
            dailyRadio.Checked += delegate
            {
                UpdateDayAvailability();
                UpdateChangePreview();
            };
            selectedDaysRadio.Checked += delegate
            {
                // Choosing selected days over a daily schedule starts from the working week. An empty selection is not a
                // schedule, so the first click on this option used to produce an invalid form.
                if (valuesLoaded)
                {
                    TickWorkWeekIfNoneSelected();
                }
                UpdateDayAvailability();
                UpdateChangePreview();
            };
            frequencyPanel.Children.Add(dailyRadio);
            frequencyPanel.Children.Add(selectedDaysRadio);

            dayPanel = new WrapPanel
            {
                Margin = new Thickness(24, 9, 0, 2)
            };
            AddDay(dayPanel, DayOfWeek.Monday, "Mon");
            AddDay(dayPanel, DayOfWeek.Tuesday, "Tue");
            AddDay(dayPanel, DayOfWeek.Wednesday, "Wed");
            AddDay(dayPanel, DayOfWeek.Thursday, "Thu");
            AddDay(dayPanel, DayOfWeek.Friday, "Fri");
            AddDay(dayPanel, DayOfWeek.Saturday, "Sat");
            AddDay(dayPanel, DayOfWeek.Sunday, "Sun");
            frequencyPanel.Children.Add(dayPanel);
            daysError = new TextBlock
            {
                Text = DaysErrorText,
                FontSize = 11,
                Foreground = palette.Danger,
                Margin = new Thickness(24, 2, 0, 0),
                TextWrapping = TextWrapping.Wrap,
                Visibility = Visibility.Collapsed
            };
            AutomationProperties.SetLiveSetting(daysError, AutomationLiveSetting.Assertive);
            frequencyPanel.Children.Add(daysError);
            // The same requirement, said before it is broken. It gives way to the error that says it after.
            daysHint = new TextBlock
            {
                Text = "Selected days must include at least one day.",
                FontSize = 11,
                Foreground = palette.TextTertiary,
                Margin = new Thickness(24, 3, 0, 0),
                TextWrapping = TextWrapping.Wrap
            };
            frequencyPanel.Children.Add(daysHint);

            Grid timeRow = new Grid { Margin = new Thickness(0, 14, 0, 0) };
            timeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            timeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock timeLabel = new TextBlock
            {
                Text = "Start time",
                FontSize = 12,
                Foreground = palette.TextPrimary,
                VerticalAlignment = VerticalAlignment.Center
            };
            timeRow.Children.Add(timeLabel);
            timeText = new TextBox
            {
                Text = TaskScheduleCanonicalizer.FormatTime(installed.TimeOfDay),
                Width = 92,
                MinHeight = 34,
                Padding = new Thickness(9, 5, 9, 5),
                FontSize = 13,
                MaxLength = 5,
                VerticalContentAlignment = VerticalAlignment.Center,
                // An inset field on the card, as the page draws its inputs.
                Background = palette.SurfaceSoft,
                Foreground = palette.TextPrimary,
                BorderBrush = palette.Border,
                ToolTip = "24-hour time, for example 02:00 or 18:30"
            };
            AutomationProperties.SetName(timeText, "Backup start time in 24-hour HH:mm format");
            timeText.LostKeyboardFocus += delegate
            {
                timeTouched = true;
                NormalizeTimeIfValid();
                UpdateChangePreview();
            };
            timeText.PreviewKeyDown += OnTimePreviewKeyDown;
            timeText.TextChanged += delegate { UpdateChangePreview(); };
            Grid.SetColumn(timeText, 1);
            timeRow.Children.Add(timeText);
            frequencyPanel.Children.Add(timeRow);
            timeError = new TextBlock
            {
                Text = TimeErrorText,
                FontSize = 11,
                Foreground = palette.Danger,
                Margin = new Thickness(150, 4, 0, 0),
                TextWrapping = TextWrapping.Wrap,
                Visibility = Visibility.Collapsed
            };
            AutomationProperties.SetLiveSetting(timeError, AutomationLiveSetting.Assertive);
            frequencyPanel.Children.Add(timeError);
            TextBlock timeHelp = new TextBlock
            {
                Text = "Use 24-hour time, such as 02:00 or 18:30; the up and down arrow keys move in 15-minute steps. " +
                    "Windows may delay a run slightly after resume or sign-in.",
                FontSize = 11,
                Foreground = palette.TextTertiary,
                Margin = new Thickness(150, 4, 0, 0),
                TextWrapping = TextWrapping.Wrap
            };
            frequencyPanel.Children.Add(timeHelp);
            frequencyCard.Child = frequencyPanel;
            content.Children.Add(frequencyCard);

            Border behaviorCard = CreateSection();
            behaviorCard.Margin = new Thickness(0, 12, 0, 0);
            StackPanel behaviorPanel = new StackPanel();
            behaviorPanel.Children.Add(CreateSectionTitle("Automatic run behavior"));
            enabledCheck = CreateCheck("Automatic backups enabled", "Pause or resume this automatic schedule.");
            enabledCheck.Margin = new Thickness(0, 10, 0, 0);
            // The labels of the first, second and fourth options are the words the review and the Settings summary use for them too.
            startWhenAvailableCheck = CreateCheck(
                ScheduleOptionText.RunMissed,
                "Runs a missed backup after the PC becomes available again.");
            wakeCheck = CreateCheck(
                ScheduleOptionText.Wake,
                "May wake the PC from sleep. It cannot power on a shut-down PC.");
            allowBatteryCheck = CreateCheck(
                "Allow a backup to start on battery",
                "When off, Windows waits for AC power before starting.");
            finishOnBatteryCheck = CreateCheck(
                ScheduleOptionText.FinishIfUnplugged,
                "When off, Windows may stop the task after switching to battery.");
            behaviorPanel.Children.Add(enabledCheck);
            behaviorPanel.Children.Add(startWhenAvailableCheck);
            behaviorPanel.Children.Add(wakeCheck);
            behaviorPanel.Children.Add(allowBatteryCheck);
            behaviorPanel.Children.Add(finishOnBatteryCheck);
            behaviorCard.Child = behaviorPanel;
            content.Children.Add(behaviorCard);

            // What the form will do, or what is wrong with it. It sits between the scroll area and the footer rather than at
            // the end of the cards, where it was off screen at the default size exactly when it explained a dimmed button.
            changeSummaryText = new TextBlock
            {
                FontSize = 12,
                Foreground = palette.AccentInk,
                TextWrapping = TextWrapping.Wrap
            };
            AutomationProperties.SetLiveSetting(changeSummaryText, AutomationLiveSetting.Polite);

            validationText = new TextBlock
            {
                FontSize = 12,
                Foreground = palette.Danger,
                TextWrapping = TextWrapping.Wrap,
                Visibility = Visibility.Collapsed
            };
            AutomationProperties.SetLiveSetting(validationText, AutomationLiveSetting.Assertive);

            StackPanel status = new StackPanel { Margin = new Thickness(2, 12, 0, 0) };
            status.Children.Add(changeSummaryText);
            status.Children.Add(validationText);
            Grid.SetRow(status, 2);
            root.Children.Add(status);

            Grid footer = new Grid { Margin = new Thickness(0, 14, 0, 0) };
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetRow(footer, 3);
            root.Children.Add(footer);

            TextBlock safety = new TextBlock
            {
                Text = "Windows approval is required to save. The installed task is re-read and verified after saving.",
                FontSize = 11,
                Foreground = palette.TextSecondary,
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 18, 0)
            };
            footer.Children.Add(safety);

            StackPanel footerButtons = new StackPanel { Orientation = Orientation.Horizontal };
            Button cancel = CreateButton("Cancel", false);
            cancel.IsCancel = true;
            cancel.Click += delegate { DialogResult = false; };
            footerButtons.Children.Add(cancel);
            // "Review schedule", not "Review changes": that is the name of the Protection button that approves a held change set.
            reviewButton = CreateButton("Review schedule", true);
            reviewButton.Margin = new Thickness(10, 0, 0, 0);
            reviewButton.IsDefault = true;
            reviewButton.Click += OnReviewClick;
            AutomationProperties.SetHelpText(
                reviewButton,
                "Review the requested schedule before asking for Windows approval.");
            footerButtons.Children.Add(reviewButton);
            Grid.SetColumn(footerButtons, 1);
            footer.Children.Add(footerButtons);

            Content = root;
            LoadInstalledValues();
            valuesLoaded = true;
            UpdateChangePreview();
            DashboardVisualStyle.FitToWorkArea(this);
            DashboardVisualStyle.ApplyDialogEntrance(this);
            // The time is the field people come here to change, so it has the focus (and is selected) when the window opens.
            Loaded += delegate
            {
                Dispatcher.BeginInvoke(
                    new Action(delegate
                    {
                        timeText.Focus();
                        timeText.SelectAll();
                    }),
                    DispatcherPriority.Input);
            };
        }

        public ScheduleChangeRequest RequestedChange { get; private set; }

        // The page's card: the surface color and the card radius (.surface), as the other dialogs draw theirs. The softer fill used here
        // was all but invisible against the window in Daylight, which left only a hairline between one section and the next.
        private Border CreateSection()
        {
            return new Border
            {
                Background = palette.Surface,
                BorderBrush = palette.Border,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(18, 15, 18, 16)
            };
        }

        private TextBlock CreateSectionTitle(string text)
        {
            return new TextBlock
            {
                Text = text,
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
                Foreground = palette.TextPrimary
            };
        }

        private RadioButton CreateRadio(string text, string group)
        {
            RadioButton radio = new RadioButton
            {
                Content = text,
                GroupName = group,
                FontSize = 12,
                Foreground = palette.TextPrimary,
                MinHeight = 28,
                ToolTip = text == "Every day"
                    ? "Run the protected backup every day at the selected time."
                    : "Run the protected backup only on the days selected below."
            };
            AutomationProperties.SetName(radio, text);
            AutomationProperties.SetHelpText(radio, Convert.ToString(radio.ToolTip, CultureInfo.InvariantCulture));
            return radio;
        }

        private CheckBox CreateCheck(string text, string help)
        {
            CheckBox check = new CheckBox
            {
                Content = text,
                FontSize = 12,
                Foreground = palette.TextPrimary,
                MinHeight = 27,
                Margin = new Thickness(0, 7, 0, 0),
                ToolTip = help
            };
            AutomationProperties.SetName(check, text);
            AutomationProperties.SetHelpText(check, help);
            check.Checked += delegate { UpdateChangePreview(); };
            check.Unchecked += delegate { UpdateChangePreview(); };
            return check;
        }

        private Button CreateButton(string text, bool primary)
        {
            Button button = new Button
            {
                Content = text,
                MinHeight = 36,
                MinWidth = primary ? 132 : 88,
                Padding = new Thickness(14, 5, 14, 5),
                FontSize = 12,
                FontWeight = FontWeights.SemiBold
            };
            button.Cursor = Cursors.Hand;
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

        private void AddDay(Panel parent, DayOfWeek day, string label)
        {
            CheckBox check = new CheckBox
            {
                Content = label,
                Tag = day,
                FontSize = 11,
                Foreground = palette.TextPrimary,
                Margin = new Thickness(0, 0, 12, 0),
                MinHeight = 28,
                ToolTip = day.ToString() + ", selectable backup day."
            };
            AutomationProperties.SetName(check, label);
            AutomationProperties.SetHelpText(check, day.ToString());
            check.Checked += delegate { UpdateChangePreview(); };
            check.Unchecked += delegate { UpdateChangePreview(); };
            dayChecks[day] = check;
            parent.Children.Add(check);
        }

        private void LoadInstalledValues()
        {
            dailyRadio.IsChecked = installed.Cadence == BackupScheduleCadence.Daily;
            selectedDaysRadio.IsChecked = installed.Cadence == BackupScheduleCadence.SelectedDays;
            foreach (KeyValuePair<DayOfWeek, CheckBox> item in dayChecks)
            {
                item.Value.IsChecked = installed.Days.Contains(item.Key);
            }
            enabledCheck.IsChecked = installed.Enabled;
            startWhenAvailableCheck.IsChecked = installed.StartWhenAvailable;
            wakeCheck.IsChecked = installed.WakeToRun;
            allowBatteryCheck.IsChecked = installed.AllowStartOnBatteries;
            finishOnBatteryCheck.IsChecked = !installed.StopIfGoingOnBatteries;
            UpdateDayAvailability();
        }

        private void UpdateChangePreview()
        {
            if (changeSummaryText == null || dailyRadio == null || validationText == null ||
                timeError == null || daysError == null || daysHint == null)
            {
                return;
            }

            ScheduleChangeRequest request;
            string error;
            bool valid = TryBuildRequest(out request, out error);
            UpdateFieldErrors();
            if (!valid)
            {
                // Review stays available, so pressing it names the problem and moves to the field to fix. A dimmed button
                // gave no reason and could not be reached by keyboard.
                SetReviewState(true, null);
                changeSummaryText.Text = "Can't review yet. " + error;
                changeSummaryText.Foreground = palette.Warning;
                if (validationText.Visibility == Visibility.Visible)
                {
                    SetValidation(error);
                }
                return;
            }

            SetValidation(null);
            if (installed.Matches(request))
            {
                SetReviewState(false, "No schedule settings have changed yet.");
                changeSummaryText.Text = "No changes yet. The installed Windows task will remain unchanged.";
                changeSummaryText.Foreground = palette.TextSecondary;
                return;
            }

            SetReviewState(true, null);
            changeSummaryText.Text = "Pending update: " + request.Summary +
                ". Review schedule to see every setting before it is applied.";
            changeSummaryText.Foreground = palette.AccentInk;
        }

        // Review is dimmed only when there is nothing to apply, and then its tooltip says so (tooltips show on a dimmed button).
        private void SetReviewState(bool enabled, string reason)
        {
            if (reviewButton == null)
            {
                return;
            }
            reviewButton.IsEnabled = enabled;
            reviewButton.ToolTip = reason;
        }

        // Marks the field a problem belongs to: a red border and a message under the time, a message under the days.
        private void UpdateFieldErrors()
        {
            TimeSpan ignored;
            bool showTime = timeTouched && !TryParseTime(timeText.Text, out ignored);
            timeError.Visibility = showTime ? Visibility.Visible : Visibility.Collapsed;
            timeText.BorderBrush = showTime ? palette.Danger : palette.Border;
            AutomationProperties.SetItemStatus(timeText, showTime ? TimeErrorText : string.Empty);

            bool showDays = selectedDaysRadio.IsChecked == true && !AnyDaySelected();
            daysError.Visibility = showDays ? Visibility.Visible : Visibility.Collapsed;
            daysHint.Visibility = showDays ? Visibility.Collapsed : Visibility.Visible;
        }

        private bool AnyDaySelected()
        {
            return dayChecks.Values.Any(check => check.IsChecked == true);
        }

        private void TickWorkWeekIfNoneSelected()
        {
            if (AnyDaySelected())
            {
                return;
            }
            DayOfWeek[] workWeek =
            {
                DayOfWeek.Monday,
                DayOfWeek.Tuesday,
                DayOfWeek.Wednesday,
                DayOfWeek.Thursday,
                DayOfWeek.Friday
            };
            foreach (DayOfWeek day in workWeek)
            {
                dayChecks[day].IsChecked = true;
            }
        }

        private void UpdateDayAvailability()
        {
            bool enabled = selectedDaysRadio != null && selectedDaysRadio.IsChecked == true;
            if (dayPanel != null)
            {
                dayPanel.IsEnabled = enabled;
                // The themed check boxes dim themselves when disabled, so dimming the panel as well would leave the days
                // all but invisible. It only dims for the stock check boxes, which a local text color keeps looking enabled.
                bool dimsItself = Resources.Contains(typeof(CheckBox));
                DashboardVisualStyle.AnimateDouble(
                    dayPanel,
                    UIElement.OpacityProperty,
                    enabled || SystemParameters.HighContrast || dimsItself ? 1.0 : 0.55,
                    TimeSpan.FromMilliseconds(140),
                    false);
            }
        }

        private void OnTimePreviewKeyDown(object sender, KeyEventArgs args)
        {
            if (args.Key != Key.Up && args.Key != Key.Down)
            {
                return;
            }
            TimeSpan current;
            if (!TryParseTime(timeText.Text, out current))
            {
                current = installed.TimeOfDay;
            }
            int delta = args.Key == Key.Up ? 15 : -15;
            int minutes = ((int)current.TotalMinutes + delta + (24 * 60)) % (24 * 60);
            timeText.Text = string.Format(
                CultureInfo.InvariantCulture,
                "{0:00}:{1:00}",
                minutes / 60,
                minutes % 60);
            timeText.SelectAll();
            args.Handled = true;
        }

        private void NormalizeTimeIfValid()
        {
            TimeSpan value;
            if (TryParseTime(timeText.Text, out value))
            {
                timeText.Text = TaskScheduleCanonicalizer.FormatTime(value);
            }
        }

        // Accepts 2:00 as well as 02:00, and a dot for the colon (2.30), which is how many keyboards and regions write a time.
        // The field is rewritten as HH:mm when it loses focus, and what leaves this window is a plain TimeSpan that the
        // request formats as HH:mm before it is signed and handed to the protected manager, so nothing there changes.
        private static bool TryParseTime(string text, out TimeSpan value)
        {
            string normalized = (text ?? string.Empty).Trim().Replace('.', ':');
            return TimeSpan.TryParseExact(
                normalized,
                new[] { @"h\:mm", @"hh\:mm" },
                CultureInfo.InvariantCulture,
                out value) && value.TotalHours >= 0 && value.TotalHours < 24;
        }

        private void OnReviewClick(object sender, RoutedEventArgs args)
        {
            ScheduleChangeRequest request;
            string error;
            if (!TryBuildRequest(out request, out error))
            {
                // Say what is wrong, mark the field, and put the cursor where the fix goes.
                timeTouched = true;
                UpdateFieldErrors();
                SetValidation(error);
                TimeSpan ignored;
                if (!TryParseTime(timeText.Text, out ignored))
                {
                    timeText.Focus();
                    timeText.SelectAll();
                }
                else if (selectedDaysRadio.IsChecked == true && !AnyDaySelected())
                {
                    dayChecks[DayOfWeek.Monday].Focus();
                }
                return;
            }

            SetValidation(null);
            if (installed.Matches(request))
            {
                SetValidation("No schedule settings have changed.");
                return;
            }

            // Cancel is the default button of this confirmation, as the old Yes/No box defaulted to No.
            bool confirmed = DashboardDialog.Confirm(
                this,
                palette,
                "Save this schedule?",
                BuildReviewSummary(request),
                BuildReviewDetails(request),
                "Save schedule",
                "Keep editing",
                true);
            if (!confirmed)
            {
                return;
            }

            RequestedChange = request;
            DialogResult = true;
        }

        private bool TryBuildRequest(
            out ScheduleChangeRequest request,
            out string error)
        {
            TimeSpan time;
            if (!TryParseTime(timeText.Text, out time))
            {
                request = null;
                error = TimeErrorText;
                return false;
            }

            BackupScheduleCadence cadence = selectedDaysRadio.IsChecked == true
                ? BackupScheduleCadence.SelectedDays
                : BackupScheduleCadence.Daily;
            if (cadence == BackupScheduleCadence.SelectedDays && !AnyDaySelected())
            {
                request = null;
                error = DaysErrorText;
                return false;
            }
            IEnumerable<DayOfWeek> days = cadence == BackupScheduleCadence.SelectedDays
                ? dayChecks.Where(item => item.Value.IsChecked == true).Select(item => item.Key)
                : Enumerable.Empty<DayOfWeek>();
            return ScheduleChangeRequest.TryCreate(
                cadence,
                time,
                days,
                enabledCheck.IsChecked == true,
                startWhenAvailableCheck.IsChecked == true,
                wakeCheck.IsChecked == true,
                allowBatteryCheck.IsChecked == true,
                finishOnBatteryCheck.IsChecked != true,
                out request,
                out error);
        }

        // The outcome first, in one sentence; the individual settings follow as secondary detail.
        private static string BuildReviewSummary(ScheduleChangeRequest request)
        {
            return "New schedule: " + request.Summary + ". Windows asks for your approval first, " +
                "and no backup starts now.";
        }

        // One line for each option, in the words the editor and the Settings summary use for it (ScheduleOptionText).
        private static IList<string> BuildReviewDetails(ScheduleChangeRequest request)
        {
            List<string> details = new List<string>();
            details.Add(request.StartWhenAvailable
                ? ScheduleOptionText.RunMissed
                : ScheduleOptionText.WaitForNextRun);
            details.Add(request.WakeToRun
                ? ScheduleOptionText.Wake
                : ScheduleOptionText.NoWake);
            details.Add(request.AllowStartOnBatteries
                ? ScheduleOptionText.StartOnBattery
                : ScheduleOptionText.WaitForAc);
            details.Add(request.StopIfGoingOnBatteries
                ? ScheduleOptionText.StopIfUnplugged
                : ScheduleOptionText.FinishIfUnplugged);
            details.Add("This updates the protected Windows scheduled task. Rewindle re-reads it afterwards to confirm the change.");
            return details;
        }

        // One message at a time in the status line: while a problem is shown it stands in for the summary, and the summary
        // returns as soon as the form is valid again.
        private void SetValidation(string message)
        {
            bool hasMessage = !string.IsNullOrWhiteSpace(message);
            bool wasVisible = validationText.Visibility == Visibility.Visible;
            validationText.Text = message ?? string.Empty;
            validationText.Visibility = hasMessage ? Visibility.Visible : Visibility.Collapsed;
            changeSummaryText.Visibility = hasMessage ? Visibility.Collapsed : Visibility.Visible;
            if (hasMessage)
            {
                if (!wasVisible)
                {
                    DashboardVisualStyle.Reveal(
                        validationText,
                        TimeSpan.FromMilliseconds(160),
                        TimeSpan.Zero,
                        -3.0);
                }
                AutomationProperties.SetName(validationText, message);
            }
        }
    }
}
