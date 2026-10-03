using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Media;

namespace ResticBackuper.Dashboard
{
    public sealed class RunChart : FrameworkElement
    {
        private IList<RunMetricView> runs = new List<RunMetricView>();
        private readonly Typeface typeface = new Typeface("Segoe UI");
        private readonly Brush muted;
        private readonly Brush grid;
        private readonly Brush durationBrush;
        private readonly Brush processedBrush;
        private readonly Brush successBrush;
        private readonly Brush failureBrush;
        private readonly Brush pointOutline;
        private readonly bool useFailureOutline;

        public RunChart(DashboardThemePalette palette)
        {
            if (palette == null)
            {
                throw new ArgumentNullException("palette");
            }
            muted = palette.ChartMuted;
            grid = palette.ChartGrid;
            durationBrush = palette.AccentPrimary;
            processedBrush = palette.AccentInfo;
            successBrush = palette.Success;
            failureBrush = palette.Danger;
            pointOutline = palette.ChartPointOutline;
            useFailureOutline = string.Equals(
                palette.Id,
                "windows-high-contrast",
                StringComparison.OrdinalIgnoreCase);
        }

        public IList<RunMetricView> Runs
        {
            get { return runs; }
            set
            {
                runs = value ?? new List<RunMetricView>();
                InvalidateVisual();
            }
        }

        protected override void OnRender(DrawingContext drawingContext)
        {
            base.OnRender(drawingContext);

            double width = Math.Max(0, ActualWidth);
            double height = Math.Max(0, ActualHeight);
            if (width < 80 || height < 20)
            {
                return;
            }

            IList<RunMetricView> visible = runs
                .OrderBy(item => item.StartedLocal)
                .TakeLastCompat(10)
                .ToList();

            if (height < 80)
            {
                DrawCompactTrend(drawingContext, visible, width, height);
                return;
            }

            if (visible.Count == 0)
            {
                DrawText(drawingContext, "Run trends will appear here", 14, muted, 22, height / 2 - 10);
                DrawText(drawingContext, "The verified dry run seeds the first estimate.", 11, muted, 22, height / 2 + 14);
                return;
            }

            const double left = 44;
            const double right = 20;
            const double top = 30;
            const double bottom = 34;
            Rect plot = new Rect(left, top, Math.Max(1, width - left - right), Math.Max(1, height - top - bottom));

            double maxDuration = Math.Max(1, visible.Max(item => item.DurationSeconds));
            double maxProcessed = Math.Max(1, visible.Max(item => item.ProcessedBytes));
            Pen gridPen = new Pen(grid, 1);
            gridPen.DashStyle = new DashStyle(new double[] { 3, 4 }, 0);

            for (int row = 0; row <= 3; row++)
            {
                double y = plot.Top + plot.Height * row / 3.0;
                drawingContext.DrawLine(gridPen, new Point(plot.Left, y), new Point(plot.Right, y));
                double seconds = maxDuration * (3 - row) / 3.0;
                DrawText(drawingContext, ShortDuration(seconds), 9, muted, 2, y - 7);
            }

            double slot = plot.Width / visible.Count;
            double barWidth = Math.Max(8, Math.Min(30, slot * 0.42));
            List<Point> processedPoints = new List<Point>();
            for (int index = 0; index < visible.Count; index++)
            {
                RunMetricView item = visible[index];
                double center = plot.Left + slot * index + slot / 2;
                double barHeight = Math.Max(2, plot.Height * item.DurationSeconds / maxDuration);
                Rect bar = new Rect(center - barWidth / 2, plot.Bottom - barHeight, barWidth, barHeight);
                Brush barBrush = item.Success
                    ? durationBrush
                    : useFailureOutline ? Brushes.Transparent : failureBrush;
                Pen barOutline = !item.Success && useFailureOutline
                    ? new Pen(failureBrush, 2)
                    : null;
                drawingContext.DrawRoundedRectangle(barBrush, barOutline, bar, 4, 4);

                double pointY = plot.Bottom - plot.Height * item.ProcessedBytes / maxProcessed;
                processedPoints.Add(new Point(center, pointY));

                string label = item.StartedLocal.ToString("ddd", CultureInfo.CurrentCulture);
                DrawCenteredText(drawingContext, label, 9, muted, center, plot.Bottom + 9);

                Brush dotBrush = item.Success ? successBrush : failureBrush;
                drawingContext.DrawEllipse(dotBrush, null, new Point(center, plot.Bottom + 2), 2.5, 2.5);
            }

            if (processedPoints.Count > 1)
            {
                StreamGeometry geometry = new StreamGeometry();
                using (StreamGeometryContext context = geometry.Open())
                {
                    context.BeginFigure(processedPoints[0], false, false);
                    context.PolyLineTo(processedPoints.Skip(1).ToList(), true, true);
                }
                geometry.Freeze();
                drawingContext.DrawGeometry(null, new Pen(processedBrush, 2), geometry);
            }
            foreach (Point point in processedPoints)
            {
                drawingContext.DrawEllipse(processedBrush, new Pen(pointOutline, 2), point, 4, 4);
            }

            drawingContext.DrawRoundedRectangle(durationBrush, null, new Rect(plot.Left, 7, 10, 10), 2, 2);
            DrawText(drawingContext, "Duration", 10, muted, plot.Left + 15, 4);
            drawingContext.DrawLine(new Pen(processedBrush, 2), new Point(plot.Left + 82, 12), new Point(plot.Left + 96, 12));
            DrawText(drawingContext, "Processed", 10, muted, plot.Left + 102, 4);
        }

        private void DrawCompactTrend(
            DrawingContext drawingContext,
            IList<RunMetricView> visible,
            double width,
            double height)
        {
            if (visible.Count == 0)
            {
                DrawText(drawingContext, "No trend yet", 10, muted, 4, height / 2 - 7);
                return;
            }

            Rect plot = new Rect(4, 5, Math.Max(1, width - 8), Math.Max(1, height - 10));
            double maxDuration = Math.Max(1, visible.Max(item => item.DurationSeconds));
            double maxProcessed = Math.Max(1, visible.Max(item => item.ProcessedBytes));
            double slot = plot.Width / visible.Count;
            double barWidth = Math.Max(4, Math.Min(12, slot * 0.34));
            List<Point> processedPoints = new List<Point>();

            for (int index = 0; index < visible.Count; index++)
            {
                RunMetricView item = visible[index];
                double center = plot.Left + slot * index + slot / 2;
                double barHeight = Math.Max(2, plot.Height * item.DurationSeconds / maxDuration);
                Rect bar = new Rect(center - barWidth / 2, plot.Bottom - barHeight, barWidth, barHeight);
                Brush barBrush = item.Success
                    ? durationBrush
                    : useFailureOutline ? Brushes.Transparent : failureBrush;
                Pen barOutline = !item.Success && useFailureOutline
                    ? new Pen(failureBrush, 1.5)
                    : null;
                drawingContext.DrawRoundedRectangle(barBrush, barOutline, bar, 2, 2);
                processedPoints.Add(new Point(
                    center,
                    plot.Bottom - plot.Height * item.ProcessedBytes / maxProcessed));
            }

            if (processedPoints.Count > 1)
            {
                StreamGeometry geometry = new StreamGeometry();
                using (StreamGeometryContext context = geometry.Open())
                {
                    context.BeginFigure(processedPoints[0], false, false);
                    context.PolyLineTo(processedPoints.Skip(1).ToList(), true, true);
                }
                geometry.Freeze();
                drawingContext.DrawGeometry(null, new Pen(processedBrush, 1.5), geometry);
            }
        }

        private void DrawText(DrawingContext context, string text, double size, Brush brush, double x, double y)
        {
            FormattedText formatted = new FormattedText(
                text,
                CultureInfo.CurrentCulture,
                FlowDirection.LeftToRight,
                typeface,
                size,
                brush,
                VisualTreeHelper.GetDpi(this).PixelsPerDip);
            context.DrawText(formatted, new Point(x, y));
        }

        private void DrawCenteredText(DrawingContext context, string text, double size, Brush brush, double x, double y)
        {
            FormattedText formatted = new FormattedText(
                text,
                CultureInfo.CurrentCulture,
                FlowDirection.LeftToRight,
                typeface,
                size,
                brush,
                VisualTreeHelper.GetDpi(this).PixelsPerDip);
            context.DrawText(formatted, new Point(x - formatted.Width / 2, y));
        }

        private static string ShortDuration(double seconds)
        {
            if (seconds >= 3600)
            {
                return (seconds / 3600.0).ToString("0.#", CultureInfo.InvariantCulture) + "h";
            }
            if (seconds >= 60)
            {
                return (seconds / 60.0).ToString("0", CultureInfo.InvariantCulture) + "m";
            }
            return seconds.ToString("0", CultureInfo.InvariantCulture) + "s";
        }

    }

    internal static class EnumerableCompatibility
    {
        public static IEnumerable<T> TakeLastCompat<T>(this IEnumerable<T> source, int count)
        {
            Queue<T> queue = new Queue<T>();
            foreach (T item in source)
            {
                if (queue.Count == count)
                {
                    queue.Dequeue();
                }
                queue.Enqueue(item);
            }
            return queue;
        }
    }
}
