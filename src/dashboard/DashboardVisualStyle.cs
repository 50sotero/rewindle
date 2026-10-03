using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Interop;
using System.Runtime.InteropServices;

namespace ResticBackuper.Dashboard
{
    /// <summary>
    /// Shared Beautiful UI presentation and motion primitives. This class deliberately owns
    /// appearance only: protected commands, state transitions, focus, and dialog results remain
    /// synchronous in the controls that use it.
    /// </summary>
    internal static class DashboardVisualStyle
    {
        private static readonly KeySpline DefaultSpline = new KeySpline(0.4, 0.0, 0.2, 1.0);
        private static readonly KeySpline StrongSpline = new KeySpline(0.23, 1.0, 0.32, 1.0);

        // DWM's non-client colors are intentionally kept here with the web shell's
        // semantic tokens. The WPF client area and the WebView2 page can therefore
        // meet at the title bar without introducing a custom/frameless chrome layer.
        private const int DwmwaUseImmersiveDarkMode = 20;
        private const int DwmwaBorderColor = 34;
        private const int DwmwaCaptionColor = 35;
        private const int DwmwaTextColor = 36;
        private const int DwmColorDefault = unchecked((int)0xFFFFFFFF);
        private static readonly Color DarkChromeBackground = Color.FromRgb(0x10, 0x19, 0x27);
        private static readonly Color DarkChromeText = Color.FromRgb(0xF6, 0xF4, 0xEE);
        private static readonly Color DarkChromeBorder = Color.FromRgb(0x2D, 0x3D, 0x4A);
        private static readonly Color LightChromeBackground = Color.FromRgb(0xF6, 0xF4, 0xEE);
        private static readonly Color LightChromeText = Color.FromRgb(0x10, 0x19, 0x27);

        [DllImport("dwmapi.dll", EntryPoint = "DwmSetWindowAttribute")]
        private static extern int DwmSetWindowAttribute(
            IntPtr hwnd,
            int attribute,
            ref int value,
            int valueSize);

        public static readonly TimeSpan FastDuration = TimeSpan.FromMilliseconds(100);
        public static readonly TimeSpan DefaultDuration = TimeSpan.FromMilliseconds(150);
        public static readonly TimeSpan StrongDuration = TimeSpan.FromMilliseconds(220);
        public static readonly TimeSpan PopDuration = TimeSpan.FromMilliseconds(240);
        public static readonly TimeSpan ExpandDuration = TimeSpan.FromMilliseconds(340);
        public static readonly TimeSpan SectionDuration = TimeSpan.FromMilliseconds(600);

        public static FontFamily UiFont
        {
            get { return new FontFamily("Segoe UI Variable Text"); }
        }

        public static bool MotionAllowed()
        {
            return DashboardMotion.MotionAllowed();
        }

        public static void ApplyWindow(Window window, DashboardThemePalette palette)
        {
            if (window == null || palette == null)
            {
                return;
            }

            window.FontFamily = UiFont;
            window.Background = palette.BackgroundTop;
            window.Foreground = palette.TextPrimary;
            window.UseLayoutRounding = true;
            window.SnapsToDevicePixels = true;
            window.Resources[SystemColors.HighlightBrushKey] = palette.Selection;
            window.Resources[SystemColors.HighlightTextBrushKey] = palette.SelectionText;
            window.Resources[SystemColors.InactiveSelectionHighlightBrushKey] = palette.Selection;
            window.Resources[SystemColors.InactiveSelectionHighlightTextBrushKey] = palette.SelectionText;
            if (SystemParameters.HighContrast)
            {
                // Let Windows own the scrollbar colors in high contrast. The
                // resource is removed so the normal WPF theme can provide its
                // system ScrollBar template and brushes. The same goes for the
                // check boxes, radio buttons, tool tips and focus rectangle that
                // ApplyThemedControlResources themes.
                window.Resources.Remove(typeof(ScrollBar));
                RemoveThemedControlResources(window);
            }
            else
            {
                window.Resources[typeof(ScrollBar)] = CreateScrollBarStyle(palette);
                ApplyThemedControlResources(window, palette);
            }
            TextOptions.SetTextFormattingMode(window, TextFormattingMode.Display);
            TextOptions.SetTextRenderingMode(window, TextRenderingMode.Auto);
            RenderOptions.SetClearTypeHint(window, ClearTypeHint.Enabled);

            // WPF creates the HWND lazily. Apply immediately when a dialog is
            // already open (this is also how the main window updates after a
            // theme switch), and repeat from SourceInitialized for first show.
            if (new WindowInteropHelper(window).Handle == IntPtr.Zero)
            {
                EventHandler initialized = null;
                initialized = delegate
                {
                    window.SourceInitialized -= initialized;
                    ApplyNativeWindowChrome(window, palette);
                };
                window.SourceInitialized += initialized;
            }
            ApplyNativeWindowChrome(window, palette);
        }

        private static void ApplyNativeWindowChrome(
            Window window,
            DashboardThemePalette palette)
        {
            if (window == null || palette == null)
            {
                return;
            }

            IntPtr hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero)
            {
                return;
            }

            // High contrast owns the non-client colors. Reset any previously
            // applied values so switching into high contrast cannot leave a
            // stale branded caption behind.
            if (SystemParameters.HighContrast)
            {
                SetDwmBoolean(hwnd, DwmwaUseImmersiveDarkMode, false);
                SetDwmColor(hwnd, DwmwaBorderColor, DwmColorDefault);
                SetDwmColor(hwnd, DwmwaCaptionColor, DwmColorDefault);
                SetDwmColor(hwnd, DwmwaTextColor, DwmColorDefault);
                return;
            }

            bool dark = palette.IsDark;
            Color caption = dark ? DarkChromeBackground : LightChromeBackground;
            Color text = dark ? DarkChromeText : LightChromeText;
            // The dark shell defines its border explicitly. The light shell
            // inherits the native palette's light border token so dialogs keep
            // the same separation as their client surfaces.
            Color border = dark ? DarkChromeBorder : palette.Border.Color;

            SetDwmBoolean(hwnd, DwmwaUseImmersiveDarkMode, dark);
            SetDwmColor(hwnd, DwmwaBorderColor, ToColorRef(border));
            SetDwmColor(hwnd, DwmwaCaptionColor, ToColorRef(caption));
            SetDwmColor(hwnd, DwmwaTextColor, ToColorRef(text));
        }

        private static void SetDwmBoolean(IntPtr hwnd, int attribute, bool enabled)
        {
            int value = enabled ? 1 : 0;
            TrySetDwmAttribute(hwnd, attribute, ref value);
        }

        private static void SetDwmColor(IntPtr hwnd, int attribute, int colorRef)
        {
            int value = colorRef;
            TrySetDwmAttribute(hwnd, attribute, ref value);
        }

        private static void TrySetDwmAttribute(IntPtr hwnd, int attribute, ref int value)
        {
            try
            {
                // Unsupported attributes return a failing HRESULT on older
                // Windows builds; the normal WPF frame remains the fallback.
                DwmSetWindowAttribute(hwnd, attribute, ref value, sizeof(int));
            }
            catch (DllNotFoundException)
            {
            }
            catch (EntryPointNotFoundException)
            {
            }
            catch (BadImageFormatException)
            {
            }
            catch (SEHException)
            {
            }
        }

        private static int ToColorRef(Color color)
        {
            return color.R | (color.G << 8) | (color.B << 16);
        }

        // Check boxes, radio buttons, tool tips and the default focus rectangle follow the palette. The stock
        // templates hard-code a white box, a dark mark and a blue hover, and the tool tip uses the system's pale
        // yellow, so on the Midnight card the boxes were bright white and a Tab left black dots on navy.
        private static void ApplyThemedControlResources(Window window, DashboardThemePalette palette)
        {
            try
            {
                Style checkBox = CreateToggleStyle(typeof(CheckBox), palette, false);
                Style radioButton = CreateToggleStyle(typeof(RadioButton), palette, true);
                // Seal both now. WPF validates a template when it seals it, and a template it rejects would
                // otherwise throw from the layout pass of the dialog that happens to hold the control.
                checkBox.Seal();
                radioButton.Seal();
                window.Resources[typeof(CheckBox)] = checkBox;
                window.Resources[typeof(RadioButton)] = radioButton;
            }
            catch (Exception)
            {
                // The stock controls stay as the fallback: plain, but they work.
                window.Resources.Remove(typeof(CheckBox));
                window.Resources.Remove(typeof(RadioButton));
            }
            window.Resources[SystemColors.InfoBrushKey] = palette.Surface;
            window.Resources[SystemColors.InfoTextBrushKey] = palette.TextPrimary;
            window.Resources[SystemColors.ControlTextBrushKey] = palette.TextPrimary;
        }

        private static void RemoveThemedControlResources(Window window)
        {
            window.Resources.Remove(typeof(CheckBox));
            window.Resources.Remove(typeof(RadioButton));
            window.Resources.Remove(SystemColors.InfoBrushKey);
            window.Resources.Remove(SystemColors.InfoTextBrushKey);
            window.Resources.Remove(SystemColors.ControlTextBrushKey);
        }

        private static Style CreateToggleStyle(
            Type controlType,
            DashboardThemePalette palette,
            bool radio)
        {
            Style style = new Style(controlType);
            // The template draws its own focus ring, so the stock dotted rectangle is switched off.
            style.Setters.Add(new Setter(
                FrameworkElement.FocusVisualStyleProperty,
                null));
            style.Setters.Add(new Setter(
                Control.TemplateProperty,
                CreateToggleTemplate(controlType, palette, radio)));
            return style;
        }

        // One template for both: a 16px box (round for a radio button) on the palette's surface with a visible
        // border, an accent mark when checked, a stronger border on hover, a 2px palette focus ring just outside
        // the box (so showing it moves nothing), and the whole row dimmed when disabled.
        private static ControlTemplate CreateToggleTemplate(
            Type controlType,
            DashboardThemePalette palette,
            bool radio)
        {
            ControlTemplate template = new ControlTemplate(controlType);

            FrameworkElementFactory root = new FrameworkElementFactory(typeof(DockPanel));
            root.Name = "Root";
            root.SetValue(DockPanel.LastChildFillProperty, true);
            // A transparent background keeps the whole row clickable, as it is in the stock control.
            root.SetValue(Panel.BackgroundProperty, Brushes.Transparent);
            root.SetValue(UIElement.SnapsToDevicePixelsProperty, true);

            FrameworkElementFactory host = new FrameworkElementFactory(typeof(Grid));
            host.SetValue(DockPanel.DockProperty, Dock.Left);
            host.SetValue(FrameworkElement.WidthProperty, 16.0);
            host.SetValue(FrameworkElement.HeightProperty, 16.0);
            host.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);

            FrameworkElementFactory ring = new FrameworkElementFactory(typeof(Border));
            ring.Name = "FocusRing";
            ring.SetValue(FrameworkElement.MarginProperty, new Thickness(-3));
            ring.SetValue(Border.BorderThicknessProperty, new Thickness(2));
            ring.SetValue(Border.BorderBrushProperty, palette.Focus);
            ring.SetValue(Border.CornerRadiusProperty, radio ? new CornerRadius(11) : new CornerRadius(7));
            ring.SetValue(UIElement.IsHitTestVisibleProperty, false);
            ring.SetValue(UIElement.VisibilityProperty, Visibility.Collapsed);
            host.AppendChild(ring);

            FrameworkElementFactory box = new FrameworkElementFactory(typeof(Border));
            box.Name = "Box";
            box.SetValue(Border.BackgroundProperty, palette.Surface);
            box.SetValue(Border.BorderBrushProperty, palette.TextTertiary);
            box.SetValue(Border.BorderThicknessProperty, new Thickness(1));
            box.SetValue(Border.CornerRadiusProperty, radio ? new CornerRadius(8) : new CornerRadius(4));

            FrameworkElementFactory mark;
            if (radio)
            {
                mark = new FrameworkElementFactory(typeof(System.Windows.Shapes.Ellipse));
                mark.SetValue(FrameworkElement.WidthProperty, 8.0);
                mark.SetValue(FrameworkElement.HeightProperty, 8.0);
                mark.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
                mark.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
                mark.SetValue(System.Windows.Shapes.Shape.FillProperty, palette.AccentPrimary);
            }
            else
            {
                // Drawn in the 14px inside the border, and centred there: it spans x 2.2 to 11.8 and y 3.2 to 10.6.
                mark = new FrameworkElementFactory(typeof(System.Windows.Shapes.Path));
                mark.SetValue(
                    System.Windows.Shapes.Path.DataProperty,
                    Geometry.Parse("M 3.2,7 L 5.8,9.6 L 10.8,4.2"));
                mark.SetValue(System.Windows.Shapes.Shape.StrokeProperty, palette.AccentPrimary);
                mark.SetValue(System.Windows.Shapes.Shape.StrokeThicknessProperty, 2.0);
                mark.SetValue(System.Windows.Shapes.Shape.StrokeStartLineCapProperty, PenLineCap.Round);
                mark.SetValue(System.Windows.Shapes.Shape.StrokeEndLineCapProperty, PenLineCap.Round);
                mark.SetValue(System.Windows.Shapes.Shape.StrokeLineJoinProperty, PenLineJoin.Round);
            }
            mark.Name = "Mark";
            mark.SetValue(UIElement.VisibilityProperty, Visibility.Collapsed);
            box.AppendChild(mark);
            host.AppendChild(box);
            root.AppendChild(host);

            FrameworkElementFactory content = new FrameworkElementFactory(typeof(ContentPresenter));
            content.SetValue(FrameworkElement.MarginProperty, new Thickness(8, 0, 0, 0));
            content.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
            content.SetValue(ContentPresenter.RecognizesAccessKeyProperty, true);
            content.SetBinding(
                ContentPresenter.ContentProperty,
                new Binding("Content")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            root.AppendChild(content);
            template.VisualTree = root;

            // Later triggers win over earlier ones, so a checked box keeps its accent border under the pointer.
            Trigger hover = new Trigger
            {
                Property = UIElement.IsMouseOverProperty,
                Value = true
            };
            hover.Setters.Add(new Setter(Border.BorderBrushProperty, palette.TextSecondary, "Box"));
            template.Triggers.Add(hover);

            Trigger isChecked = new Trigger
            {
                Property = ToggleButton.IsCheckedProperty,
                Value = true
            };
            isChecked.Setters.Add(new Setter(Border.BorderBrushProperty, palette.AccentPrimary, "Box"));
            isChecked.Setters.Add(new Setter(UIElement.VisibilityProperty, Visibility.Visible, "Mark"));
            template.Triggers.Add(isChecked);

            Trigger focused = new Trigger
            {
                Property = UIElement.IsKeyboardFocusedProperty,
                Value = true
            };
            focused.Setters.Add(new Setter(UIElement.VisibilityProperty, Visibility.Visible, "FocusRing"));
            template.Triggers.Add(focused);

            Trigger disabled = new Trigger
            {
                Property = UIElement.IsEnabledProperty,
                Value = false
            };
            disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.46, "Root"));
            template.Triggers.Add(disabled);
            return template;
        }

        private static Style CreateScrollBarStyle(DashboardThemePalette palette)
        {
            Style style = new Style(typeof(ScrollBar));
            style.Resources[typeof(Thumb)] = CreateScrollBarThumbStyle(palette);
            style.Setters.Add(new Setter(
                Control.BackgroundProperty,
                palette.SurfaceSoft));
            style.Setters.Add(new Setter(
                Control.BorderBrushProperty,
                palette.Border));
            style.Setters.Add(new Setter(
                Control.BorderThicknessProperty,
                new Thickness(1)));
            style.Setters.Add(new Setter(
                Control.TemplateProperty,
                CreateScrollBarTemplate()));

            Trigger vertical = new Trigger
            {
                Property = ScrollBar.OrientationProperty,
                Value = Orientation.Vertical
            };
            vertical.Setters.Add(new Setter(
                FrameworkElement.WidthProperty,
                12.0));
            vertical.Setters.Add(new Setter(
                FrameworkElement.HeightProperty,
                double.NaN));
            style.Triggers.Add(vertical);

            Trigger horizontal = new Trigger
            {
                Property = ScrollBar.OrientationProperty,
                Value = Orientation.Horizontal
            };
            horizontal.Setters.Add(new Setter(
                FrameworkElement.WidthProperty,
                double.NaN));
            horizontal.Setters.Add(new Setter(
                FrameworkElement.HeightProperty,
                12.0));
            style.Triggers.Add(horizontal);
            return style;
        }

        private static ControlTemplate CreateScrollBarTemplate()
        {
            ControlTemplate template = new ControlTemplate(typeof(ScrollBar));

            FrameworkElementFactory chrome = new FrameworkElementFactory(typeof(Border));
            chrome.Name = "Chrome";
            chrome.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
            chrome.SetValue(Border.PaddingProperty, new Thickness(2));
            chrome.SetValue(UIElement.SnapsToDevicePixelsProperty, true);
            chrome.SetBinding(
                Border.BackgroundProperty,
                new Binding("Background")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            chrome.SetBinding(
                Border.BorderBrushProperty,
                new Binding("BorderBrush")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            chrome.SetBinding(
                Border.BorderThicknessProperty,
                new Binding("BorderThickness")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });

            FrameworkElementFactory track = new FrameworkElementFactory(typeof(ThemedScrollTrack));
            track.Name = "PART_Track";
            track.SetValue(FrameworkElement.FocusableProperty, false);
            track.SetBinding(
                Track.OrientationProperty,
                new Binding("Orientation")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            track.SetBinding(
                Track.MinimumProperty,
                new Binding("Minimum")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            track.SetBinding(
                Track.MaximumProperty,
                new Binding("Maximum")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            track.SetBinding(
                Track.ValueProperty,
                new Binding("Value")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            track.SetBinding(
                Track.ViewportSizeProperty,
                new Binding("ViewportSize")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            chrome.AppendChild(track);
            template.VisualTree = chrome;
            return template;
        }

        internal static RepeatButton CreateScrollBarRepeatButton(ICommand command)
        {
            RepeatButton button = new RepeatButton
            {
                Focusable = false,
                BorderThickness = new Thickness(0),
                Background = Brushes.Transparent,
                Delay = 300,
                Interval = 40,
                Command = command,
                Template = CreateScrollBarRepeatButtonTemplate()
            };
            button.SetBinding(
                ButtonBase.CommandTargetProperty,
                new Binding
                {
                    RelativeSource = new RelativeSource(
                        RelativeSourceMode.FindAncestor,
                        typeof(ScrollBar),
                        1)
                });
            return button;
        }

        internal static ControlTemplate CreateScrollBarRepeatButtonTemplate()
        {
            ControlTemplate template = new ControlTemplate(typeof(RepeatButton));
            FrameworkElementFactory button = new FrameworkElementFactory(typeof(Border));
            button.SetBinding(
                Border.BackgroundProperty,
                new Binding("Background")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            button.SetBinding(
                Border.BorderBrushProperty,
                new Binding("BorderBrush")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            button.SetBinding(
                Border.BorderThicknessProperty,
                new Binding("BorderThickness")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            template.VisualTree = button;
            return template;
        }

        private static Style CreateScrollBarThumbStyle(DashboardThemePalette palette)
        {
            Style style = new Style(typeof(Thumb));
            style.Setters.Add(new Setter(
                Control.BackgroundProperty,
                palette.PhaseInactive));
            style.Setters.Add(new Setter(
                Control.BorderBrushProperty,
                palette.Border));
            style.Setters.Add(new Setter(
                Control.BorderThicknessProperty,
                new Thickness(1)));
            style.Setters.Add(new Setter(
                Control.TemplateProperty,
                CreateScrollBarThumbTemplate()));

            Trigger hover = new Trigger
            {
                Property = UIElement.IsMouseOverProperty,
                Value = true
            };
            hover.Setters.Add(new Setter(
                Control.BackgroundProperty,
                palette.TextTertiary));
            style.Triggers.Add(hover);

            Trigger dragging = new Trigger
            {
                Property = Thumb.IsDraggingProperty,
                Value = true
            };
            dragging.Setters.Add(new Setter(
                Control.BackgroundProperty,
                palette.AccentPrimary));
            style.Triggers.Add(dragging);
            return style;
        }

        private static ControlTemplate CreateScrollBarThumbTemplate()
        {
            ControlTemplate template = new ControlTemplate(typeof(Thumb));
            FrameworkElementFactory thumb = new FrameworkElementFactory(typeof(Border));
            thumb.SetValue(Border.CornerRadiusProperty, new CornerRadius(5));
            thumb.SetValue(UIElement.SnapsToDevicePixelsProperty, true);
            thumb.SetBinding(
                Border.BackgroundProperty,
                new Binding("Background")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            thumb.SetBinding(
                Border.BorderBrushProperty,
                new Binding("BorderBrush")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            thumb.SetBinding(
                Border.BorderThicknessProperty,
                new Binding("BorderThickness")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            template.VisualTree = thumb;
            return template;
        }

        public static void ApplyButtonChrome(Button button, double cornerRadius)
        {
            if (button == null)
            {
                return;
            }

            ControlTemplate template = new ControlTemplate(typeof(Button));
            FrameworkElementFactory border = new FrameworkElementFactory(typeof(Border));
            border.Name = "Chrome";
            border.SetValue(Border.CornerRadiusProperty, new CornerRadius(cornerRadius));
            border.SetBinding(
                Border.BackgroundProperty,
                new Binding("Background")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            border.SetBinding(
                Border.BorderBrushProperty,
                new Binding("BorderBrush")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            border.SetBinding(
                Border.BorderThicknessProperty,
                new Binding("BorderThickness")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            border.SetBinding(
                Border.PaddingProperty,
                new Binding("Padding")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });

            FrameworkElementFactory presenter = new FrameworkElementFactory(typeof(ContentPresenter));
            presenter.SetBinding(
                FrameworkElement.HorizontalAlignmentProperty,
                new Binding("HorizontalContentAlignment")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            presenter.SetBinding(
                FrameworkElement.VerticalAlignmentProperty,
                new Binding("VerticalContentAlignment")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            presenter.SetValue(ContentPresenter.RecognizesAccessKeyProperty, true);
            presenter.SetBinding(
                ContentPresenter.ContentProperty,
                new Binding("Content")
                {
                    RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
                });
            border.AppendChild(presenter);
            template.VisualTree = border;

            Style style = new Style(typeof(Button));
            style.Setters.Add(new Setter(Control.TemplateProperty, template));
            button.Style = style;

            ScaleTransform scale = new ScaleTransform(1.0, 1.0);
            button.RenderTransformOrigin = new Point(0.5, 0.5);
            button.RenderTransform = scale;

            Action<bool> setPressed = delegate(bool pressed)
            {
                double target = pressed && button.IsEnabled && MotionAllowed() ? 0.96 : 1.0;
                TimeSpan duration = pressed ? FastDuration : DefaultDuration;
                AnimateDouble(scale, ScaleTransform.ScaleXProperty, target, duration, false);
                AnimateDouble(scale, ScaleTransform.ScaleYProperty, target, duration, false);
            };
            Action updateOpacity = delegate
            {
                double target = !button.IsEnabled
                    ? (SystemParameters.HighContrast ? 1.0 : 0.46)
                    : SystemParameters.HighContrast
                        ? 1.0
                        : button.IsMouseOver ? 0.94 : 1.0;
                AnimateDouble(button, UIElement.OpacityProperty, target, DefaultDuration, false);
            };

            button.MouseEnter += delegate { updateOpacity(); };
            button.MouseLeave += delegate
            {
                setPressed(false);
                updateOpacity();
            };
            button.PreviewMouseDown += delegate(object sender, MouseButtonEventArgs args)
            {
                if (args.ChangedButton == MouseButton.Left)
                {
                    setPressed(true);
                }
            };
            button.PreviewMouseUp += delegate(object sender, MouseButtonEventArgs args)
            {
                if (args.ChangedButton == MouseButton.Left)
                {
                    setPressed(false);
                }
            };
            button.PreviewKeyDown += delegate(object sender, KeyEventArgs args)
            {
                if (args.Key == Key.Space || args.Key == Key.Enter || args.Key == Key.Return)
                {
                    setPressed(true);
                }
            };
            button.PreviewKeyUp += delegate(object sender, KeyEventArgs args)
            {
                if (args.Key == Key.Space || args.Key == Key.Enter || args.Key == Key.Return)
                {
                    setPressed(false);
                }
            };
            button.IsEnabledChanged += delegate
            {
                setPressed(false);
                updateOpacity();
            };
            updateOpacity();
        }

        // The two button looks of every dialog, drawn from the palette's tokens so they follow the page's own buttons: the primary is ink on
        // the canvas and the secondary a quiet surface, both pills. They set the colors and the chrome together, so a dialog's own button
        // helper calls one of them in place of ApplyButtonChrome (which each of them calls once, with the pill radius for the button's height).
        public static void StylePrimaryButton(Button button, DashboardThemePalette palette)
        {
            if (button == null || palette == null)
            {
                return;
            }
            button.Background = palette.PrimaryButton;
            button.Foreground = palette.PrimaryButtonText;
            button.BorderBrush = palette.PrimaryButtonBorder;
            // Windows High Contrast has no fill to set the primary button apart (it uses the system button colors), so its border is heavier.
            button.BorderThickness = new Thickness(SystemParameters.HighContrast ? 2 : 1);
            ApplyButtonChrome(button, PillRadius(button));
        }

        public static void StyleSecondaryButton(Button button, DashboardThemePalette palette)
        {
            if (button == null || palette == null)
            {
                return;
            }
            button.Background = palette.ButtonBackground;
            button.Foreground = palette.ButtonText;
            button.BorderBrush = palette.Border;
            button.BorderThickness = new Thickness(1);
            ApplyButtonChrome(button, PillRadius(button));
        }

        // Half the button's height, so its ends are round. The height is the one the button is built with (its minimum), which is never
        // taller than the button is drawn, so the radius never exceeds half of it.
        private static double PillRadius(Button button)
        {
            double height = button.Height > 0 ? button.Height : button.MinHeight;
            return height > 0 ? height / 2.0 : 18.0;
        }

        public static void ApplyFocusOutline(Button button, Brush focusBrush)
        {
            if (button == null || focusBrush == null)
            {
                return;
            }

            Brush borderBeforeFocus = null;
            Thickness thicknessBeforeFocus = new Thickness(1);
            button.GotKeyboardFocus += delegate
            {
                borderBeforeFocus = button.BorderBrush;
                thicknessBeforeFocus = button.BorderThickness;
                button.BorderBrush = focusBrush;
                button.BorderThickness = new Thickness(2);
            };
            button.LostKeyboardFocus += delegate
            {
                if (borderBeforeFocus != null)
                {
                    button.BorderBrush = borderBeforeFocus;
                    button.BorderThickness = thicknessBeforeFocus;
                }
            };
        }

        public static void ApplyDataGridChrome(DataGrid grid, DashboardThemePalette palette)
        {
            if (grid == null || palette == null)
            {
                return;
            }

            Style headerStyle = new Style(typeof(DataGridColumnHeader));
            headerStyle.Setters.Add(new Setter(Control.BackgroundProperty, palette.SurfaceSoft));
            headerStyle.Setters.Add(new Setter(Control.ForegroundProperty, palette.TextSecondary));
            headerStyle.Setters.Add(new Setter(Control.FontSizeProperty, 12.0));
            headerStyle.Setters.Add(new Setter(Control.FontWeightProperty, FontWeights.SemiBold));
            headerStyle.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(0, 0, 0, 1)));
            headerStyle.Setters.Add(new Setter(Control.BorderBrushProperty, palette.Border));
            headerStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(10, 9, 10, 9)));
            headerStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Left));
            grid.ColumnHeaderStyle = headerStyle;
            grid.FontSize = 12.0;
            grid.MinRowHeight = 34;
            grid.CanUserResizeRows = false;
            grid.HorizontalGridLinesBrush = palette.Border;
            grid.GridLinesVisibility = DataGridGridLinesVisibility.Horizontal;
        }

        public static void Reveal(FrameworkElement element)
        {
            Reveal(element, SectionDuration, TimeSpan.Zero, 8.0);
        }

        public static void Reveal(
            FrameworkElement element,
            TimeSpan duration,
            TimeSpan delay,
            double offset)
        {
            if (element == null)
            {
                return;
            }
            if (!MotionAllowed())
            {
                element.BeginAnimation(UIElement.OpacityProperty, null);
                element.Opacity = 1.0;
                TranslateTransform immediate = EnsureTranslate(element);
                immediate.BeginAnimation(TranslateTransform.YProperty, null);
                immediate.Y = 0.0;
                return;
            }

            TranslateTransform translate = EnsureTranslate(element);
            element.BeginAnimation(UIElement.OpacityProperty, null);
            translate.BeginAnimation(TranslateTransform.YProperty, null);
            element.Opacity = 0.0;
            translate.Y = offset;
            element.Dispatcher.BeginInvoke(
                new Action(delegate
                {
                    AnimateDouble(element, UIElement.OpacityProperty, 1.0, duration, true, delay);
                    AnimateDouble(translate, TranslateTransform.YProperty, 0.0, duration, true, delay);
                }),
                System.Windows.Threading.DispatcherPriority.Loaded);
        }

        public static void PopIn(FrameworkElement element)
        {
            if (element == null)
            {
                return;
            }
            if (!MotionAllowed())
            {
                element.Opacity = 1.0;
                return;
            }

            ScaleTransform scale = new ScaleTransform(0.95, 0.95);
            element.RenderTransformOrigin = new Point(0.5, 0.5);
            element.RenderTransform = scale;
            element.Opacity = 0.0;
            element.Dispatcher.BeginInvoke(
                new Action(delegate
                {
                    AnimateDouble(element, UIElement.OpacityProperty, 1.0, PopDuration, true);
                    AnimateDouble(scale, ScaleTransform.ScaleXProperty, 1.0, PopDuration, true);
                    AnimateDouble(scale, ScaleTransform.ScaleYProperty, 1.0, PopDuration, true);
                }),
                System.Windows.Threading.DispatcherPriority.Loaded);
        }

        public static void Emphasize(FrameworkElement element)
        {
            if (element == null || !MotionAllowed())
            {
                return;
            }

            ScaleTransform scale = element.RenderTransform as ScaleTransform;
            if (scale == null)
            {
                scale = new ScaleTransform(0.985, 0.985);
                element.RenderTransformOrigin = new Point(0.5, 0.5);
                element.RenderTransform = scale;
            }
            else
            {
                scale.ScaleX = 0.985;
                scale.ScaleY = 0.985;
            }
            AnimateDouble(scale, ScaleTransform.ScaleXProperty, 1.0, StrongDuration, true);
            AnimateDouble(scale, ScaleTransform.ScaleYProperty, 1.0, StrongDuration, true);
        }

        public static void ApplyDialogEntrance(Window window)
        {
            if (window == null)
            {
                return;
            }
            FrameworkElement content = window.Content as FrameworkElement;
            if (content == null || !MotionAllowed())
            {
                return;
            }
            PopIn(content);
        }

        // Room kept clear of the screen edge and the taskbar when a dialog is fitted to a work area.
        private const double DialogScreenMargin = 24.0;

        // Sizes a fixed-size dialog to the monitor it opens on. The dialogs are laid out in DIPs (780x690 and the like), which
        // is taller than the work area of a 1080p screen at 150% (about 672 DIPs) or a 1366x768 laptop at 125%, so their
        // footer buttons slid under the taskbar and a large minimum height stopped the window from shrinking to fit. The width
        // and height shrink to the work area, the minimums follow them (WPF honours MinHeight over Height, so they are lowered
        // after it), and Max* keep a later resize on the screen. Nothing grows: a dialog that already fits is left alone.
        public static void FitToWorkArea(Window window)
        {
            if (window == null)
            {
                return;
            }

            Rect area = DialogWorkArea(window);
            double maxWidth = Math.Max(320.0, area.Width - DialogScreenMargin);
            double maxHeight = Math.Max(240.0, area.Height - DialogScreenMargin);
            window.MaxWidth = maxWidth;
            window.MaxHeight = maxHeight;
            if (!double.IsNaN(window.Width))
            {
                window.Width = Math.Min(window.Width, maxWidth);
                window.MinWidth = Math.Min(window.MinWidth, window.Width);
            }
            if (!double.IsNaN(window.Height))
            {
                window.Height = Math.Min(window.Height, maxHeight);
                window.MinHeight = Math.Min(window.MinHeight, window.Height);
            }
        }

        // The work area, in DIPs, of the monitor the dialog will open on: its owner's, or else the dashboard's own window
        // (the dialogs are constructed before their owner is assigned), or else the primary monitor.
        private static Rect DialogWorkArea(Window window)
        {
            Rect primary = SystemParameters.WorkArea;
            try
            {
                Window anchor = window.Owner;
                if (anchor == null && Application.Current != null)
                {
                    anchor = Application.Current.MainWindow;
                }
                if (anchor == null || object.ReferenceEquals(anchor, window))
                {
                    return primary;
                }
                IntPtr handle = new WindowInteropHelper(anchor).Handle;
                if (handle == IntPtr.Zero)
                {
                    return primary;
                }
                PresentationSource source = PresentationSource.FromVisual(anchor);
                if (source == null || source.CompositionTarget == null)
                {
                    return primary;
                }
                System.Drawing.Rectangle pixels = System.Windows.Forms.Screen.FromHandle(handle).WorkingArea;
                Matrix fromDevice = source.CompositionTarget.TransformFromDevice;
                Point topLeft = fromDevice.Transform(new Point(pixels.Left, pixels.Top));
                Point bottomRight = fromDevice.Transform(new Point(pixels.Right, pixels.Bottom));
                Rect area = new Rect(topLeft, bottomRight);
                // A work area too small to be real (a monitor that is going away, say) would squash every dialog.
                return area.IsEmpty || area.Width < 400.0 || area.Height < 300.0 ? primary : area;
            }
            catch (Exception)
            {
                // The monitor of another window is a refinement. The primary work area is always a safe answer.
                return primary;
            }
        }

        public static void AnimateProgressValue(ProgressBar progress, double value)
        {
            if (progress == null)
            {
                return;
            }
            double target = Math.Max(progress.Minimum, Math.Min(progress.Maximum, value));
            if (target < progress.Value)
            {
                // Progress only moves forward within one operation, so a lower value is the bar starting over (a new operation, or a
                // failure putting it back to zero). That is set in place: easing down from where the last operation ended would
                // sweep the bar backwards, which is now seen because controls animate.
                progress.BeginAnimation(ProgressBar.ValueProperty, null);
                progress.Value = target;
                return;
            }
            AnimateDouble(progress, ProgressBar.ValueProperty, target, TimeSpan.FromMilliseconds(250), false);
        }

        public static void SetBusy(ProgressBar progress, bool busy)
        {
            if (progress == null)
            {
                return;
            }
            if (!busy)
            {
                progress.IsIndeterminate = false;
                AutomationProperties.SetItemStatus(progress, string.Empty);
                return;
            }
            progress.IsIndeterminate = MotionAllowed();
            if (!progress.IsIndeterminate)
            {
                // Without motion the bar is empty, not mid-way through an animation toward the last operation's value.
                progress.BeginAnimation(ProgressBar.ValueProperty, null);
                progress.Value = progress.Minimum;
            }
            AutomationProperties.SetItemStatus(progress, "Busy; progress is indeterminate");
        }

        public static void AnimateDouble(
            DependencyObject target,
            DependencyProperty property,
            double value,
            TimeSpan duration,
            bool strong)
        {
            AnimateDouble(target, property, value, duration, strong, TimeSpan.Zero);
        }

        public static void AnimateDouble(
            DependencyObject target,
            DependencyProperty property,
            double value,
            TimeSpan duration,
            bool strong,
            TimeSpan delay)
        {
            // Controls (UIElement) and freezables such as the transforms both take animations through IAnimatable, but only the
            // freezables derive from Animatable. Asking for an Animatable sent every control straight to its end value, so the
            // opacity, height and progress animations of controls (dialog entrances, button hover fades, the dimmed day list)
            // never ran, and only the ones on transforms did.
            IAnimatable animatable = target as IAnimatable;
            if (animatable == null)
            {
                target.SetValue(property, value);
                return;
            }

            double current = Convert.ToDouble(target.GetValue(property));
            animatable.BeginAnimation(property, null);
            target.SetValue(property, value);
            // NaN is "Auto" for a size, which has nothing to ease from, and an end value that is already showing needs no animation.
            if (!MotionAllowed() ||
                duration <= TimeSpan.Zero ||
                double.IsNaN(current) ||
                double.IsInfinity(current) ||
                current == value)
            {
                return;
            }

            if (delay < TimeSpan.Zero)
            {
                delay = TimeSpan.Zero;
            }
            // The start value is held through the delay by a key frame, not by BeginTime: an animation applies nothing before
            // its BeginTime, so the end value set above showed for the whole delay and then jumped back to the start. An element
            // that is revealed would have flashed fully visible, vanished, and only then faded in.
            DoubleAnimationUsingKeyFrames animation = new DoubleAnimationUsingKeyFrames();
            animation.Duration = new Duration(delay + duration);
            animation.FillBehavior = FillBehavior.Stop;
            animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(current, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            if (delay > TimeSpan.Zero)
            {
                animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(current, KeyTime.FromTimeSpan(delay)));
            }
            animation.KeyFrames.Add(
                new SplineDoubleKeyFrame(
                    value,
                    KeyTime.FromTimeSpan(delay + duration),
                    strong ? StrongSpline : DefaultSpline));
            animatable.BeginAnimation(property, animation, HandoffBehavior.SnapshotAndReplace);
        }

        private static TranslateTransform EnsureTranslate(FrameworkElement element)
        {
            TranslateTransform translate = element.RenderTransform as TranslateTransform;
            if (translate == null)
            {
                translate = new TranslateTransform();
                element.RenderTransform = translate;
            }
            return translate;
        }
    }

    /// <summary>
    /// The themed stand-in for the system MessageBox. The Win32 box ignores the app theme (light chrome over Midnight), pairs
    /// Yes/No in one place with OK/Cancel in another, and cannot make the safe button both the default and the focused one.
    /// This dialog follows the palette, names its buttons after what they do, leads with the outcome in one sentence and keeps
    /// the technical assurances in a secondary Details block. It is presentation only: a confirmation returns true solely when
    /// the confirm button is pressed, and closing the window any other way (Esc, the close button, Alt+F4) is a cancel.
    /// </summary>
    internal static class DashboardDialog
    {
        private const double DialogWidth = 540.0;

        // Asks the user to confirm before something changes. With `caution` the cancel button is the default and the focused
        // one, so Enter and Space do the safe thing; the confirm button always needs an explicit click or a Tab to reach it.
        public static bool Confirm(
            Window owner,
            DashboardThemePalette palette,
            string title,
            string summary,
            IList<string> detailLines,
            string confirmLabel,
            string cancelLabel,
            bool caution)
        {
            if (string.IsNullOrWhiteSpace(confirmLabel))
            {
                throw new ArgumentException("A confirmation needs a label for its confirm button.", "confirmLabel");
            }
            return Show(owner, palette, title, summary, detailLines, confirmLabel, cancelLabel, caution, false);
        }

        // Tells the user how something went. One button closes it.
        public static void Notify(
            Window owner,
            DashboardThemePalette palette,
            string title,
            string summary,
            IList<string> detailLines,
            string closeLabel,
            bool error)
        {
            Show(owner, palette, title, summary, detailLines, null, closeLabel, false, error);
        }

        private static bool Show(
            Window owner,
            DashboardThemePalette palette,
            string title,
            string summary,
            IList<string> detailLines,
            string confirmLabel,
            string cancelLabel,
            bool caution,
            bool error)
        {
            if (palette == null)
            {
                throw new ArgumentNullException("palette");
            }
            bool confirming = !string.IsNullOrEmpty(confirmLabel);
            bool confirmed = false;

            Window dialog = new Window();
            dialog.Title = title ?? string.Empty;
            dialog.Width = DialogWidth;
            dialog.SizeToContent = SizeToContent.Height;
            dialog.ResizeMode = ResizeMode.NoResize;
            // Owned, and centred on its owner, while that window is on screen. A window that is minimized or hidden in the
            // tray (a result can arrive after the dashboard was put away) is nothing to centre on, and an owned dialog would
            // follow it out of sight, so the dialog then stands alone in the middle of the screen. With no owner to bring it
            // back, it gets a taskbar button of its own, so it cannot be lost behind other windows.
            bool anchored = owner != null &&
                new WindowInteropHelper(owner).Handle != IntPtr.Zero &&
                owner.IsVisible &&
                owner.WindowState != WindowState.Minimized;
            dialog.ShowInTaskbar = !anchored;
            if (anchored)
            {
                dialog.Owner = owner;
                dialog.WindowStartupLocation = WindowStartupLocation.CenterOwner;
            }
            else
            {
                dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
            }
            DashboardVisualStyle.ApplyWindow(dialog, palette);

            Border frame = new Border();
            frame.Background = palette.Surface;
            frame.BorderBrush = palette.Border;
            frame.BorderThickness = new Thickness(1);
            frame.Padding = new Thickness(24, 22, 24, 20);

            // The text scrolls if a small or scaled display leaves too little height; the buttons never scroll away.
            Grid layout = new Grid();
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            frame.Child = layout;

            ScrollViewer scroll = new ScrollViewer();
            scroll.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            scroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
            layout.Children.Add(scroll);
            StackPanel body = new StackPanel();
            scroll.Content = body;

            TextBlock heading = new TextBlock();
            heading.Text = title ?? string.Empty;
            heading.FontSize = 20;
            heading.FontWeight = FontWeights.SemiBold;
            heading.Foreground = error ? palette.Danger : palette.TextPrimary;
            heading.TextWrapping = TextWrapping.Wrap;
            body.Children.Add(heading);

            if (!string.IsNullOrWhiteSpace(summary))
            {
                TextBlock outcome = new TextBlock();
                outcome.Text = summary;
                outcome.FontSize = 13;
                outcome.Foreground = palette.TextSecondary;
                outcome.TextWrapping = TextWrapping.Wrap;
                outcome.Margin = new Thickness(0, 8, 0, 0);
                body.Children.Add(outcome);
            }

            StackPanel lines = new StackPanel();
            if (detailLines != null)
            {
                foreach (string line in detailLines)
                {
                    if (string.IsNullOrWhiteSpace(line))
                    {
                        continue;
                    }
                    TextBlock detail = new TextBlock();
                    detail.Text = line;
                    detail.FontSize = 12;
                    detail.Foreground = palette.TextSecondary;
                    detail.TextWrapping = TextWrapping.Wrap;
                    detail.Margin = new Thickness(0, lines.Children.Count == 0 ? 7 : 5, 0, 0);
                    lines.Children.Add(detail);
                }
            }
            if (lines.Children.Count > 0)
            {
                Border details = new Border();
                details.Background = palette.SurfaceSoft;
                details.BorderBrush = palette.Border;
                details.BorderThickness = new Thickness(1);
                details.CornerRadius = new CornerRadius(10);
                details.Padding = new Thickness(13, 10, 13, 12);
                details.Margin = new Thickness(0, 16, 0, 0);
                StackPanel detailBody = new StackPanel();
                TextBlock detailLabel = new TextBlock();
                detailLabel.Text = "Details";
                detailLabel.FontSize = 11;
                detailLabel.FontWeight = FontWeights.SemiBold;
                detailLabel.Foreground = palette.TextPrimary;
                detailBody.Children.Add(detailLabel);
                detailBody.Children.Add(lines);
                details.Child = detailBody;
                body.Children.Add(details);
            }

            StackPanel actions = new StackPanel();
            actions.Orientation = Orientation.Horizontal;
            actions.HorizontalAlignment = HorizontalAlignment.Right;
            actions.Margin = new Thickness(0, 19, 0, 0);
            Grid.SetRow(actions, 1);
            layout.Children.Add(actions);

            // The cancel button is the way out of every dialog; for a notice it is the only button.
            Button cancel = CreateButton(palette, string.IsNullOrWhiteSpace(cancelLabel) ? "Close" : cancelLabel, false);
            cancel.IsCancel = true;
            cancel.Click += delegate { dialog.DialogResult = false; };
            actions.Children.Add(cancel);

            Button confirm = null;
            if (confirming)
            {
                confirm = CreateButton(palette, confirmLabel, true);
                confirm.Margin = new Thickness(10, 0, 0, 0);
                confirm.Click += delegate
                {
                    confirmed = true;
                    dialog.DialogResult = true;
                };
                actions.Children.Add(confirm);
            }

            // Enter presses the default button, and the focused button gets Space and Enter as well, so a cautious dialog
            // makes Cancel both.
            bool cancelLeads = caution || confirm == null;
            cancel.IsDefault = cancelLeads;
            if (confirm != null)
            {
                confirm.IsDefault = !cancelLeads;
            }
            Button focusTarget = cancelLeads ? cancel : confirm;
            FocusManager.SetFocusedElement(dialog, focusTarget);
            dialog.Loaded += delegate { focusTarget.Focus(); };

            dialog.Content = frame;
            AutomationProperties.SetName(dialog, title ?? string.Empty);
            DashboardVisualStyle.FitToWorkArea(dialog);
            DashboardVisualStyle.ApplyDialogEntrance(dialog);
            dialog.ShowDialog();
            return confirmed;
        }

        private static Button CreateButton(DashboardThemePalette palette, string text, bool primary)
        {
            Button button = new Button();
            button.Content = text;
            button.MinHeight = 36;
            button.MinWidth = primary ? 132 : 88;
            button.Padding = new Thickness(14, 5, 14, 5);
            button.FontSize = 12;
            button.FontWeight = FontWeights.SemiBold;
            button.Cursor = Cursors.Hand;
            // The same two looks as the dialogs this one is shown from, so a confirmation does not change the button's style in mid-flow.
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
    }

    // This is a real Track so WPF keeps its normal range math and input
    // behavior. It owns the two page buttons and thumb because Track exposes
    // those as CLR properties rather than dependency properties, which cannot
    // be assigned from a FrameworkElementFactory template.
    public sealed class ThemedScrollTrack : Track
    {
        private readonly RepeatButton decreaseRepeatButton;
        private readonly RepeatButton increaseRepeatButton;

        public ThemedScrollTrack()
        {
            decreaseRepeatButton = DashboardVisualStyle.CreateScrollBarRepeatButton(
                ScrollBar.PageUpCommand);
            increaseRepeatButton = DashboardVisualStyle.CreateScrollBarRepeatButton(
                ScrollBar.PageDownCommand);
            DecreaseRepeatButton = decreaseRepeatButton;
            IncreaseRepeatButton = increaseRepeatButton;
            Thumb = new Thumb();
            ConfigureOrientation();
        }

        protected override void OnPropertyChanged(
            DependencyPropertyChangedEventArgs args)
        {
            base.OnPropertyChanged(args);
            if (args.Property == Track.OrientationProperty)
            {
                ConfigureOrientation();
            }
        }

        private void ConfigureOrientation()
        {
            bool horizontal = Orientation == Orientation.Horizontal;
            IsDirectionReversed = !horizontal;
            decreaseRepeatButton.Command = horizontal
                ? ScrollBar.PageLeftCommand
                : ScrollBar.PageUpCommand;
            increaseRepeatButton.Command = horizontal
                ? ScrollBar.PageRightCommand
                : ScrollBar.PageDownCommand;
        }
    }
}
