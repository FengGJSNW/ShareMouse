using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using ShareMouse.Core;
namespace ShareMouse;

public sealed class LatencyWindow : Window
{
    public LatencyWindow(LinkLatency[] links, string rates)
    {
        Title = "延迟抖动测试 · 10 秒";
        Width = 780;
        Height = 530;
        MinWidth = 780;
        MinHeight = 530;
        var body = new StackPanel { Margin = new Thickness(24) };
        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        body.Children.Add(new TextBlock { Text = Title, FontSize = 22, FontWeight = FontWeights.SemiBold });
        body.Children.Add(new TextBlock { Text = "各连接独立采样，后台历史同步暂时让路；仍包含系统排队和无线延迟。缺口表示等待后未收到回应。", Margin = new Thickness(0, 10, 0, 6), TextWrapping = TextWrapping.Wrap });
        var canvas = new Canvas { Width = 700, Height = 280, HorizontalAlignment = HorizontalAlignment.Left };
        body.Children.Add(new Border { Background = Theme.Brush("Surface"), BorderBrush = Theme.Brush("Border"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Margin = new Thickness(0, 10, 0, 10), Child = canvas });
        const double left = 65, top = 15, width = 610, height = 205;
        var maximum = Math.Max(10, Math.Ceiling(links.SelectMany(l => l.Values).DefaultIfEmpty(10).Max() / 10) * 10);
        void Text(string text, double x, double y)
        {
            var label = new TextBlock { Text = text, FontSize = 11 };
            Canvas.SetLeft(label, x);
            Canvas.SetTop(label, y);
            canvas.Children.Add(label);
        }
        for (var i = 0; i <= 4; i++)
        {
            var y = top + height * i / 4;
            canvas.Children.Add(new Line { X1 = left, Y1 = y, X2 = left + width, Y2 = y, Stroke = Theme.Brush("Border") });
            Text($"{maximum * (4 - i) / 4:F0}", 18, y - 6);
        }
        for (var i = 0; i <= 10; i += 2)
            Text(i.ToString(), left + width * i / 10 - 4, top + height + 8);
        Text("RTT（ms）", 5, 0);
        Text("时间（秒）", left + width / 2 - 30, top + height + 27);
        var colors = new[] { Theme.Brush("Accent"), Theme.Brush("Warning"), Theme.Brush("Good") };
        var colorIndex = 0;
        foreach (var link in links)
        {
            var color = colors[colorIndex++ % colors.Length];
            Polyline? line = null;
            foreach (var sample in link.Samples)
            {
                if (sample.Milliseconds is not { } rtt)
                {
                    line = null;
                    continue;
                }
                if (line is null)
                {
                    line = new Polyline { Stroke = color, StrokeThickness = 1.6 };
                    canvas.Children.Add(line);
                }
                line.Points.Add(new Point(left + sample.Seconds / 10 * width, top + height * (1 - rtt / maximum)));
            }
            body.Children.Add(new TextBlock { Text = link.Summary, Foreground = color, Margin = new Thickness(0, 4, 0, 4), TextWrapping = TextWrapping.Wrap });
        }
        body.Children.Add(new TextBlock { Text = rates, Foreground = Theme.Brush("Muted"), FontSize = 12, Margin = new Thickness(0, 10, 0, 0), TextWrapping = TextWrapping.Wrap });
    }
}
