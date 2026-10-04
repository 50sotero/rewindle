using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Rewindle.Setup
{
    // One button of a StatusPanel.
    internal sealed class StatusButton
    {
        public string Text;
        public bool Primary;
        public bool Enabled = true;
        public Action Click;

        public StatusButton(string text, bool primary, Action click)
        {
            Text = text;
            Primary = primary;
            Click = click;
        }
    }

    // What a StatusPanel says. Progress is null for nothing, below zero for "working, no end in sight", or 0..1 for a fraction.
    internal sealed class StatusContent
    {
        public string Title;
        public string Body;
        public string Detail;
        public double? Progress;
        public readonly List<StatusButton> Buttons = new List<StatusButton>();
        public StatusButton Link;
    }

    // The colors of the native screens: Rewindle's own tokens (web/styles/app.css) for light and dark, and the system's colors in
    // High Contrast, so the plain screen shown before the wizard can start looks like the wizard and obeys Windows.
    internal sealed class StatusPalette
    {
        public Brush Page;
        public Brush Surface;
        public Brush Ink;
        public Brush InkSoft;
        public Brush InkFaint;
        public Brush Line;
        public Brush Accent;
        public Brush Danger;
        public Brush PrimaryFill;
        public Brush PrimaryHover;
        public Brush PrimaryText;
        public Brush SecondaryFill;
        public Brush SecondaryHover;
        public Brush SecondaryBorder;
        public Color PageColor;

        private static Brush Solid(string hex)
        {
            SolidColorBrush brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
            brush.Freeze();
            return brush;
        }

        private static Brush FromColor(Color color)
        {
            SolidColorBrush brush = new SolidColorBrush(color);
            brush.Freeze();
            return brush;
        }

        public static StatusPalette For(ThemeState theme)
        {
            StatusPalette palette = new StatusPalette();
            if (theme.HighContrast)
            {
                palette.PageColor = SystemColors.WindowColor;
                palette.Page = FromColor(SystemColors.WindowColor);
                palette.Surface = palette.Page;
                palette.Ink = FromColor(SystemColors.WindowTextColor);
                palette.InkSoft = palette.Ink;
                palette.InkFaint = palette.Ink;
                palette.Line = palette.Ink;
                palette.Accent = FromColor(SystemColors.HighlightColor);
                palette.Danger = palette.Ink;
                palette.PrimaryFill = FromColor(SystemColors.HighlightColor);
                palette.PrimaryHover = FromColor(SystemColors.HotTrackColor);
                palette.PrimaryText = FromColor(SystemColors.HighlightTextColor);
                palette.SecondaryFill = FromColor(SystemColors.ControlColor);
                palette.SecondaryHover = FromColor(SystemColors.ControlLightColor);
                palette.SecondaryBorder = FromColor(SystemColors.WindowTextColor);
            }
            else if (theme.Dark)
            {
                palette.PageColor = (Color)ColorConverter.ConvertFromString("#101927");
                palette.Page = Solid("#101927");
                palette.Surface = Solid("#1A2835");
                palette.Ink = Solid("#F6F4EE");
                palette.InkSoft = Solid("#B7C2CA");
                palette.InkFaint = Solid("#93A5B4");
                palette.Line = Solid("#2D3D4A");
                palette.Accent = Solid("#76D6C8");
                palette.Danger = Solid("#FF9C8F");
                palette.PrimaryFill = Solid("#F6F4EE");
                palette.PrimaryHover = Solid("#E4E0D5");
                palette.PrimaryText = Solid("#14202C");
                palette.SecondaryFill = Solid("#1A2835");
                palette.SecondaryHover = Solid("#2A3D4C");
                palette.SecondaryBorder = Solid("#405463");
            }
            else
            {
                palette.PageColor = (Color)ColorConverter.ConvertFromString("#F6F4EE");
                palette.Page = Solid("#F6F4EE");
                palette.Surface = Solid("#FFFFFF");
                palette.Ink = Solid("#101927");
                palette.InkSoft = Solid("#46535C");
                palette.InkFaint = Solid("#58656F");
                palette.Line = Solid("#E5E1D7");
                palette.Accent = Solid("#167C73");
                palette.Danger = Solid("#B3261E");
                palette.PrimaryFill = Solid("#101927");
                palette.PrimaryHover = Solid("#26313F");
                palette.PrimaryText = Solid("#EFEDE7");
                palette.SecondaryFill = Solid("#FFFFFF");
                palette.SecondaryHover = Solid("#E4E0D5");
                palette.SecondaryBorder = Solid("#D6D1C4");
            }
            return palette;
        }
    }

    // A plain, centered message with an optional progress bar and buttons: what Setup shows when the wizard cannot (yet) be
    // shown, namely while the Microsoft Edge WebView2 Runtime is missing or being installed, and when the web view fails. It is
    // WPF only, so it works with nothing else in place, and it is keyboard accessible: the first button takes the focus.
    internal sealed class StatusPanel : Grid
    {
        private readonly Image icon = new Image();
        private readonly TextBlock title = new TextBlock();
        private readonly TextBlock body = new TextBlock();
        private readonly TextBlock detail = new TextBlock();
        private readonly ProgressBar progress = new ProgressBar();
        private readonly StackPanel buttons = new StackPanel();
        private readonly Button link = new Button();
        private StatusPalette palette;
        private StatusContent content;

        public StatusPanel()
        {
            Focusable = false;
            StackPanel column = new StackPanel();
            column.MaxWidth = 540;
            column.VerticalAlignment = VerticalAlignment.Center;
            column.HorizontalAlignment = HorizontalAlignment.Stretch;
            column.Margin = new Thickness(32);

            icon.Width = 56;
            icon.Height = 56;
            icon.HorizontalAlignment = HorizontalAlignment.Left;
            icon.Margin = new Thickness(0, 0, 0, 22);
            RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);
            column.Children.Add(icon);

            title.FontSize = 24;
            title.FontWeight = FontWeights.SemiBold;
            title.TextWrapping = TextWrapping.Wrap;
            title.Margin = new Thickness(0, 0, 0, 10);
            AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1);
            column.Children.Add(title);

            body.FontSize = 15;
            body.LineHeight = 23;
            body.TextWrapping = TextWrapping.Wrap;
            body.Margin = new Thickness(0, 0, 0, 14);
            column.Children.Add(body);

            detail.FontSize = 13;
            detail.TextWrapping = TextWrapping.Wrap;
            detail.Margin = new Thickness(0, 0, 0, 14);
            column.Children.Add(detail);

            progress.Height = 6;
            progress.Margin = new Thickness(0, 4, 0, 18);
            progress.BorderThickness = new Thickness(0);
            column.Children.Add(progress);

            buttons.Orientation = Orientation.Horizontal;
            buttons.Margin = new Thickness(0, 8, 0, 0);
            column.Children.Add(buttons);

            link.Margin = new Thickness(0, 18, 0, 0);
            link.HorizontalAlignment = HorizontalAlignment.Left;
            column.Children.Add(link);

            Children.Add(column);
            ApplyTheme(SystemTheme.Read());
        }

        public ImageSource Icon
        {
            get { return icon.Source; }
            set { icon.Source = value; icon.Visibility = value == null ? Visibility.Collapsed : Visibility.Visible; }
        }

        public StatusPalette Palette
        {
            get { return palette; }
        }

        public void ApplyTheme(ThemeState theme)
        {
            palette = StatusPalette.For(theme);
            Background = palette.Page;
            title.Foreground = palette.Ink;
            body.Foreground = palette.InkSoft;
            detail.Foreground = palette.InkFaint;
            progress.Foreground = palette.Accent;
            progress.Background = palette.Line;
            if (content != null)
            {
                Show(content);
            }
        }

        public void Show(StatusContent next)
        {
            content = next;
            title.Text = next.Title ?? string.Empty;
            body.Text = next.Body ?? string.Empty;
            body.Visibility = string.IsNullOrEmpty(next.Body) ? Visibility.Collapsed : Visibility.Visible;
            detail.Text = next.Detail ?? string.Empty;
            detail.Foreground = palette.InkFaint;
            detail.Visibility = string.IsNullOrEmpty(next.Detail) ? Visibility.Collapsed : Visibility.Visible;

            if (next.Progress.HasValue)
            {
                progress.Visibility = Visibility.Visible;
                if (next.Progress.Value < 0)
                {
                    progress.IsIndeterminate = true;
                }
                else
                {
                    progress.IsIndeterminate = false;
                    progress.Minimum = 0;
                    progress.Maximum = 1;
                    progress.Value = Math.Max(0, Math.Min(1, next.Progress.Value));
                }
            }
            else
            {
                progress.IsIndeterminate = false;
                progress.Visibility = Visibility.Collapsed;
            }

            buttons.Children.Clear();
            Button first = null;
            foreach (StatusButton definition in next.Buttons)
            {
                Button button = MakeButton(definition);
                button.Margin = new Thickness(0, 0, 10, 0);
                buttons.Children.Add(button);
                if (first == null && definition.Enabled)
                {
                    first = button;
                }
            }
            buttons.Visibility = next.Buttons.Count == 0 ? Visibility.Collapsed : Visibility.Visible;

            if (next.Link == null)
            {
                link.Visibility = Visibility.Collapsed;
            }
            else
            {
                StyleLink(next.Link);
            }
            AutomationProperties.SetName(this, next.Title);
            if (first != null)
            {
                first.Dispatcher.BeginInvoke(new Action(delegate { first.Focus(); Keyboard.Focus(first); }));
            }
        }

        private void StyleLink(StatusButton definition)
        {
            link.Visibility = Visibility.Visible;
            link.Content = definition.Text;
            link.Cursor = Cursors.Hand;
            link.FontSize = 13;
            link.Foreground = palette.Accent;
            link.Background = Brushes.Transparent;
            link.BorderThickness = new Thickness(0);
            link.Padding = new Thickness(0, 2, 0, 2);
            ControlTemplate template = new ControlTemplate(typeof(Button));
            FrameworkElementFactory text = new FrameworkElementFactory(typeof(ContentPresenter));
            text.SetValue(ContentPresenter.RecognizesAccessKeyProperty, false);
            template.VisualTree = text;
            link.Template = template;
            link.Click -= OnLinkClick;
            link.Click += OnLinkClick;
            link.Tag = definition;
        }

        private void OnLinkClick(object sender, RoutedEventArgs args)
        {
            StatusButton definition = link.Tag as StatusButton;
            if (definition != null && definition.Click != null)
            {
                definition.Click();
            }
        }

        // A pill button in the wizard's style: dark ink on the light theme for the main action, a white one for the others. The
        // template is built here because the colors depend on the theme, and the buttons are made again whenever it changes.
        private Button MakeButton(StatusButton definition)
        {
            Brush fill = definition.Primary ? palette.PrimaryFill : palette.SecondaryFill;
            Brush hover = definition.Primary ? palette.PrimaryHover : palette.SecondaryHover;
            Brush text = definition.Primary ? palette.PrimaryText : palette.Ink;
            Brush border = definition.Primary ? Brushes.Transparent : palette.SecondaryBorder;

            Button button = new Button();
            button.Content = definition.Text;
            button.IsEnabled = definition.Enabled;
            button.Foreground = text;
            button.Background = fill;
            button.FontSize = 14;
            button.FontWeight = FontWeights.Medium;
            button.MinWidth = 96;
            button.Height = 38;
            button.Padding = new Thickness(20, 0, 20, 0);
            button.FocusVisualStyle = null;
            button.Cursor = Cursors.Hand;
            AutomationProperties.SetName(button, definition.Text);

            ControlTemplate template = new ControlTemplate(typeof(Button));
            FrameworkElementFactory ring = new FrameworkElementFactory(typeof(Border));
            ring.Name = "Ring";
            ring.SetValue(Border.CornerRadiusProperty, new CornerRadius(22));
            ring.SetValue(Border.BorderThicknessProperty, new Thickness(2));
            ring.SetValue(Border.BorderBrushProperty, Brushes.Transparent);
            ring.SetValue(Border.PaddingProperty, new Thickness(0));
            FrameworkElementFactory chrome = new FrameworkElementFactory(typeof(Border));
            chrome.Name = "Chrome";
            chrome.SetValue(Border.CornerRadiusProperty, new CornerRadius(19));
            chrome.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Button.BackgroundProperty));
            chrome.SetValue(Border.BorderBrushProperty, border);
            chrome.SetValue(Border.BorderThicknessProperty, new Thickness(definition.Primary ? 0 : 1));
            chrome.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Button.PaddingProperty));
            FrameworkElementFactory presenter = new FrameworkElementFactory(typeof(ContentPresenter));
            presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
            presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
            presenter.SetValue(ContentPresenter.RecognizesAccessKeyProperty, false);
            chrome.AppendChild(presenter);
            ring.AppendChild(chrome);
            template.VisualTree = ring;

            Trigger hovering = new Trigger();
            hovering.Property = UIElement.IsMouseOverProperty;
            hovering.Value = true;
            hovering.Setters.Add(new Setter(Border.BackgroundProperty, hover, "Chrome"));
            template.Triggers.Add(hovering);
            Trigger focused = new Trigger();
            focused.Property = UIElement.IsKeyboardFocusedProperty;
            focused.Value = true;
            focused.Setters.Add(new Setter(Border.BorderBrushProperty, palette.Accent, "Ring"));
            template.Triggers.Add(focused);
            Trigger disabled = new Trigger();
            disabled.Property = UIElement.IsEnabledProperty;
            disabled.Value = false;
            disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.5));
            template.Triggers.Add(disabled);
            button.Template = template;

            Action click = definition.Click;
            button.Click += delegate
            {
                if (click != null)
                {
                    click();
                }
            };
            return button;
        }
    }
}
