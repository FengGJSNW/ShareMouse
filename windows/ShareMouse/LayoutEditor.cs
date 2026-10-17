using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ShareMouse.Core;

namespace ShareMouse;

public sealed class LayoutEditor : UserControl
{
    private readonly string localID;
    private readonly Func<Task<GroupEditLock>> begin;
    private readonly Func<ScreenGeometry[], GroupEditLock, Task> commit;
    private readonly Func<GroupEditLock, Task> release;
    private SharedGroup? current;
    private ScreenGeometry[] layout = [];
    private GroupEditLock? lease;
    private bool waiting, saving, blocked = true;
    private int editGeneration;
    private double zoom = 1, originX, originY, fitZoom = 1, viewScale = 1, panX, panY, contentWidth = 1, contentHeight = 1;
    private Point? panStart; private Point panOriginal;
    private readonly Slider zoomSlider = new() { Minimum = .25, Maximum = 4, Value = 1, Width = 120, SmallChange = .05, LargeChange = .25, ToolTip = "地图缩放" };
    private double OffsetX => (Math.Max(100, canvas.ActualWidth) - contentWidth * zoom) / 2 + panX;
    private double OffsetY => (350 - contentHeight * zoom) / 2 + panY;
    private readonly HashSet<int> invalidScales = new();
    private string? selectedID;
    private bool percent;
    private readonly CheckBox autoAlign = new() { Content = "尝试自动对齐边缘", IsChecked = true, Margin = new Thickness(0, 10, 0, 0) };
    private readonly Canvas canvas = new() { Height = 350, Background = Theme.Brush("Canvas"), ClipToBounds = true };
    private readonly StackPanel scales = new();
    private readonly TextBlock hint = new() { Margin = new Thickness(0, 0, 0, 14), TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock validation = new() { Margin = new Thickness(0, 12, 0, 12), TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, Foreground = Theme.Brush("Danger") };
    private readonly TextBlock nativeStatus = new() { TextWrapping = TextWrapping.Wrap, Foreground = Theme.Brush("Danger") };
    private readonly Button save = new() { Content = "保存排布", Padding = new Thickness(16, 8, 16, 8) };
    private readonly Button cancel = new() { Content = "取消修改", Padding = new Thickness(16, 8, 16, 8), Margin = new Thickness(0, 0, 12, 0) };
    public LayoutEditor(string localID, Func<Task<GroupEditLock>> begin,
        Func<ScreenGeometry[], GroupEditLock, Task> commit, Func<GroupEditLock, Task> release)
    {
        this.localID = localID;
        this.begin = begin;
        this.commit = commit;
        this.release = release;
        var content = new StackPanel { Margin = new Thickness(4) };
        Content = content;

        content.Children.Add(hint);
        var viewport = new Grid { Height = 350 };
        viewport.Children.Add(canvas);
        content.Children.Add(viewport);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Background = Theme.Brush("Surface"), Margin = new Thickness(8) };
        var toolChrome = new Border { Child = tools, Padding = new Thickness(4), CornerRadius = new CornerRadius(12), Background = Theme.Material(), BorderBrush = Theme.Brush("Border"), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(12), Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 12, ShadowDepth = 3, Opacity = .18 } };
        viewport.Children.Add(toolChrome);
        void Tool(string text, Action action)
        {
            var button = new Button { Content = text, Margin = new Thickness(3), Padding = new Thickness(8, 4, 8, 4) };
            button.Click += (_, _) => action();
            tools.Children.Add(button);
        }
        Tool("聚焦", () => { panX = panY = 0; SetZoom(1); });
        Tool("−", () => SetZoom(viewScale / 1.2));
        tools.Children.Add(zoomSlider);
        Tool("+", () => SetZoom(viewScale * 1.2));
        var zoomLabel = new TextBlock { Width = 46, VerticalAlignment = VerticalAlignment.Center, TextAlignment = TextAlignment.Center, Foreground = Theme.Brush("Muted") };
        zoomLabel.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding("Value") { Source = zoomSlider, StringFormat = "{0:0%}" });
        tools.Children.Add(zoomLabel);
        zoomSlider.ValueChanged += (_, _) => { viewScale = zoomSlider.Value; zoom = fitZoom * viewScale; BoundPan(); Draw(); };
        canvas.SizeChanged += (_, _) => { Fit(); Draw(); };
        canvas.MouseLeftButtonDown += (_, e) => { if (e.OriginalSource != canvas) return; panStart = e.GetPosition(canvas); panOriginal = new(panX, panY); canvas.CaptureMouse(); e.Handled = true; };
        canvas.MouseMove += (_, e) => { if (panStart is not { } start || !canvas.IsMouseCaptured) return; var at = e.GetPosition(canvas); panX = panOriginal.X + at.X - start.X; panY = panOriginal.Y + at.Y - start.Y; BoundPan(); Draw(); };
        canvas.MouseLeftButtonUp += (_, e) => { if (panStart is null) return; panStart = null; canvas.ReleaseMouseCapture(); e.Handled = true; };
        canvas.PreviewMouseWheel += (_, e) => { var at = e.GetPosition(canvas); var x = (at.X - OffsetX) / zoom; var y = (at.Y - OffsetY) / zoom; SetZoom(viewScale * (e.Delta > 0 ? 1.15 : 1 / 1.15)); panX += at.X - (OffsetX + x * zoom); panY += at.Y - (OffsetY + y * zoom); BoundPan(); Draw(); e.Handled = true; };
        content.Children.Add(new TextBlock { Text = "同色屏幕属于同一台电脑，须保持相连；保存后同步各电脑的系统屏幕位置。", TextWrapping = TextWrapping.Wrap, Foreground = Theme.Brush("Muted"), Margin = new Thickness(0, 6, 0, 0) });
        content.Children.Add(autoAlign);
        content.Children.Add(scales);
        content.Children.Add(validation);
        content.Children.Add(status);
        content.Children.Add(nativeStatus);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        actions.Children.Add(cancel);
        actions.Children.Add(save);
        content.Children.Add(actions);
        cancel.Click += async (_, _) => await Cancel();
        save.Click += async (_, _) =>
        {
            if (lease is not { } owned || blocked || !ScreenGeometry.ValidLayout(layout))
                return;
            saving = true;
            Validate();
            try
            {
                await commit(layout, owned);
                await release(owned);
                lease = null;
                status.Text = "";
                ResetDraft();
            }
            catch { await release(owned); lease = null; ResetDraft(); status.Text = "保存未完成，已刷新共享排布，请重新拖动屏幕。"; }
            finally { saving = false; Validate(); }
        };
        Unloaded += async (_, _) => await Cancel();
        Draw();
    }
    public void ShowStatus(string text)
    {
        status.Text = text;
    }
    public void ShowNativeStatus(string text)
    {
        nativeStatus.Text = text;
    }
    public void Update(SharedGroup? state, GroupEditLock[] locks, string[] online)
    {
        var changed = current?.Id != state?.Id;
        if (changed)
        {
            panX = panY = 0;
            viewScale = 1;
            zoomSlider.Value = 1;
        }
        current = state;
        blocked = online.Length < 2 || locks.Any(l => l.Resource == "layout" && l.OwnerPeerID != localID);
        if (changed)
        {
            editGeneration++;
            waiting = false;
            var old = lease;
            lease = null;
            if (old is not null)
                _ = release(old);
            ResetDraft();
        }
        else if (!saving && lease is { } held && (online.Length < 2 || state is null || state.Revision > held.BaseRevision && !locks.Contains(held)))
        {
            editGeneration++;
            waiting = false;
            lease = null;
            _ = release(held);
            ResetDraft();
            status.Text = "共享排布已更新，请重新拖动屏幕。";
        }
        else if (lease is null && !waiting && !saving)
            ResetDraft();
        hint.Text = layout.Length == 0 ? "配对成功后自动显示两端屏幕并启用键鼠共享。"
            : blocked ? "等待已配对电脑上线，或另一台电脑完成编辑。" : "选择屏幕后拖动或拉伸边缘；Shift 保持比例。修改后保存。";
        scales.IsEnabled = !blocked && !saving;
        Validate();
    }
    private async Task EnsureLease()
    {
        if (lease is not null || waiting || blocked || saving)
            return;
        waiting = true;
        var generation = editGeneration;
        Validate();
        try
        {
            var granted = await begin();
            if (generation != editGeneration || blocked || !IsLoaded)
                await release(granted);
            else
            {
                lease = granted;
                status.Text = "";
            }
        }
        catch { status.Text = "无法开始编辑，请等待另一台电脑完成编辑或重新连接。"; ResetDraft(); }
        finally { if (generation == editGeneration) waiting = false; Validate(); }
    }
    private async Task Cancel()
    {
        editGeneration++;
        waiting = false;
        var owned = lease;
        lease = null;
        status.Text = "";
        ResetDraft();
        if (owned is not null)
            await release(owned);
    }
    private void ResetDraft()
    {
        layout = current?.Layout.ToArray() ?? [];
        invalidScales.Clear();
        originX = layout.Select(s => s.X).DefaultIfEmpty(0).Min();
        originY = layout.Select(s => s.Y).DefaultIfEmpty(0).Min();
        var width = layout.Select(s => s.X + s.Width).DefaultIfEmpty(1).Max() - originX;
        var height = layout.Select(s => s.Y + s.Height).DefaultIfEmpty(1).Max() - originY;
        contentWidth = width;
        contentHeight = height;
        Fit();
        Draw();
        ShowSelectedSettings();
    }
    private void Fit()
    {
        fitZoom = Math.Min(Math.Max(100, canvas.ActualWidth - 48) / Math.Max(1, contentWidth), 300 / Math.Max(1, contentHeight));
        zoom = fitZoom * viewScale;
        BoundPan();
    }
    private void SetZoom(double value)
    {
        viewScale = Math.Clamp(value, .25, 4);
        zoomSlider.Value = viewScale;
        zoom = fitZoom * viewScale;
        BoundPan();
        Draw();
    }
    private void BoundPan()
    {
        var x = Math.Max(0, (Math.Max(100, canvas.ActualWidth) + contentWidth * zoom) / 2 - 24);
        var y = Math.Max(0, (350 + contentHeight * zoom) / 2 - 24);
        panX = Math.Clamp(panX, -x, x);
        panY = Math.Clamp(panY, -y, y);
    }
    private void ShowSelectedSettings()
    {
        scales.Children.Clear();
        invalidScales.Clear();
        var index = Array.FindIndex(layout, s => s.Id == selectedID);
        if (index < 0)
            return;
        var screen = layout[index];
        var body = new StackPanel { Margin = new Thickness(10) };
        scales.Children.Add(new GroupBox { Header = "所选屏幕 · " + screen.Name, Content = body, Margin = new Thickness(0, 12, 0, 0) });
        body.Children.Add(new TextBlock { Text = $"原生尺寸：{screen.Width:0} × {screen.Height:0} · {screen.Angle}° · 屏幕 {screen.Number}" + (screen.Primary ? " · 主屏" : ""), Foreground = Theme.Brush("Muted") });
        var row = new WrapPanel { Margin = new Thickness(0, 8, 0, 8) };
        body.Children.Add(row);
        var units = new ComboBox { ItemsSource = new[] { "像素", "百分比" }, SelectedIndex = percent ? 1 : 0, Width = 85 };
        row.Children.Add(units);
        units.SelectionChanged += (_, _) => { percent = units.SelectedIndex == 1; ShowSelectedSettings(); };
        void Dimension(string label, bool width)
        {
            row.Children.Add(new TextBlock { Text = "  " + label + " ", VerticalAlignment = VerticalAlignment.Center });
            var value = width ? screen.Width : screen.Height;
            var basis = width ? screen.BaseWidth : screen.BaseHeight;
            var field = new TextBox { Text = (percent ? value / basis * 100 : value).ToString("0.###", CultureInfo.CurrentCulture), Width = 85 };
            row.Children.Add(field);
            field.GotKeyboardFocus += async (_, _) => await EnsureLease();
            field.TextChanged += (_, _) => { if (lease is null && !waiting) return; if (double.TryParse(field.Text, out var number) && double.IsFinite(number) && number > 0) { invalidScales.Remove(index * 2 + (width ? 0 : 1)); var size = percent ? number / 100 * basis : number; layout[index] = layout[index].SetSize(width ? size : layout[index].Width, width ? layout[index].Height : size); Draw(); } else { invalidScales.Add(index * 2 + (width ? 0 : 1)); Validate(); } };
        }
        Dimension("宽", true);
        Dimension("高", false);
        var controls = new WrapPanel();
        body.Children.Add(controls);
        controls.Children.Add(new TextBlock { Text = "旋转 ", VerticalAlignment = VerticalAlignment.Center });
        var rotation = new ComboBox { ItemsSource = new[] { 0, 90, 180, 270 }, SelectedItem = screen.Angle, Width = 80 };
        controls.Children.Add(rotation);
        rotation.SelectionChanged += async (_, _) => { await EnsureLease(); if (lease is null) return; layout[index] = layout[index] with { Rotation = (int)rotation.SelectedItem }; Draw(); ShowSelectedSettings(); };
        var reset = new Button { Content = "还原设置", Margin = new Thickness(10, 0, 0, 0) };
        controls.Children.Add(reset);
        reset.Click += async (_, _) => { await EnsureLease(); if (lease is null) return; layout[index] = layout[index] with { Scale = 1, ScaleX = null, ScaleY = null, Rotation = null }; invalidScales.Clear(); Draw(); ShowSelectedSettings(); };
        body.Children.Add(new TextBlock { Text = "调整共享桌面的逻辑尺寸和方向", FontSize = 11, Foreground = Theme.Brush("Muted"), Margin = new Thickness(0, 8, 0, 0) });
    }
    private string Label(ScreenGeometry screen) => $"{current?.Members.FirstOrDefault(m => m.PeerID == screen.PeerID)?.Name ?? screen.Name} · {screen.Number}";
    private Color PeerColor(string peer)
    {
        var colors = new[] { Colors.Crimson, Colors.DarkOrange, Colors.Goldenrod, Colors.ForestGreen, Colors.DarkCyan, Colors.DodgerBlue, Colors.MediumPurple, Colors.HotPink, Colors.Gray };
        var peers = current?.Members.OrderBy(m => m.JoinOrder).ThenBy(m => m.PeerID, StringComparer.Ordinal).ToArray() ?? [];
        var index = Array.FindIndex(peers, m => m.PeerID == peer);
        return colors[Math.Max(0, index) % colors.Length];
    }
    private Brush PeerFill(string peer, bool selected)
    {
        var color = PeerColor(peer);
        var top = Color.FromArgb(selected ? (byte)92 : (byte)58, color.R, color.G, color.B);
        var bottom = Color.FromArgb(22, color.R, color.G, color.B);
        return new LinearGradientBrush(top, bottom, new Point(0, 0), new Point(1, 1));
    }
    private void Draw()
    {
        canvas.Children.Clear();
        var dots = new DrawingGroup();
        dots.Children.Add(new GeometryDrawing(Theme.Brush("Canvas"), null, new RectangleGeometry(new Rect(0, 0, 20, 20))));
        dots.Children.Add(new GeometryDrawing(Theme.Brush("Border"), null, new EllipseGeometry(new Point(1, 1), 1, 1)));
        canvas.Background = new DrawingBrush(dots) { TileMode = TileMode.Tile, ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(panX % 20, panY % 20, 20, 20), Stretch = Stretch.None };
        for (var index = 0; index < layout.Length; index++)
        {
            var selected = index;
            var screen = layout[index];
            var rectangle = new Border
            {
                Width = Math.Max(20, screen.Width * zoom),
                Height = Math.Max(20, screen.Height * zoom),
                Background = PeerFill(screen.PeerID, screen.Id == selectedID),
                CornerRadius = new CornerRadius(10),
                BorderBrush = new SolidColorBrush(PeerColor(screen.PeerID)),
                BorderThickness = new Thickness(selectedID == screen.Id ? 2 : 1),
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 10, ShadowDepth = 3, Opacity = .16 },
                Child = new TextBlock { Text = $"{Label(screen)}\n{screen.Name}\n{screen.Width:0} × {screen.Height:0} · {screen.Angle}°", TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis }
            };
            Canvas.SetLeft(rectangle, OffsetX + (screen.X - originX) * zoom);
            Canvas.SetTop(rectangle, OffsetY + (screen.Y - originY) * zoom);
            Point start = new();
            ScreenGeometry? original = null;
            string edge = "";
            string Edge(Point point)
            {
                if (selectedID != screen.Id)
                    return "";
                return (point.Y < 8 ? "n" : point.Y > rectangle.Height - 8 ? "s" : "") + (point.X < 8 ? "w" : point.X > rectangle.Width - 8 ? "e" : "");
            }
            rectangle.MouseLeftButtonDown += async (_, e) =>
            {
                if (blocked || saving)
                    return;
                edge = Edge(e.GetPosition(rectangle));
                selectedID = screen.Id;
                rectangle.Background = PeerFill(screen.PeerID, true);
                ShowSelectedSettings();
                original = layout[selected];
                start = e.GetPosition(canvas);
                rectangle.CaptureMouse();
                e.Handled = true;
                await EnsureLease();
            };
            rectangle.MouseMove += (_, e) =>
            {
                if (original is null)
                {
                    var hover = Edge(e.GetPosition(rectangle));
                    rectangle.Cursor = hover switch
                    {
                        "n" or "s" => Cursors.SizeNS,
                        "e" or "w" => Cursors.SizeWE,
                        "nw" or "se" => Cursors.SizeNWSE,
                        "ne" or "sw" => Cursors.SizeNESW,
                        _ => Cursors.Arrow
                    };
                    return;
                }
                if (!rectangle.IsMouseCaptured || blocked || saving)
                    return;
                var position = e.GetPosition(canvas);
                var dx = (position.X - start.X) / zoom;
                var dy = (position.Y - start.Y) / zoom;
                layout[selected] = edge.Length > 0 ? ScreenGeometry.Resize(original, dx, dy, edge, Keyboard.Modifiers.HasFlag(ModifierKeys.Shift), layout, autoAlign.IsChecked == true ? 10 / zoom : 0) : original with
                {
                    X = original.X + dx,
                    Y = original.Y + dy
                };
                if (edge.Length == 0 && autoAlign.IsChecked == true)
                    layout[selected] = ScreenGeometry.Snap(layout[selected], layout, 10 / zoom);
                Canvas.SetLeft(rectangle, OffsetX + (layout[selected].X - originX) * zoom);
                Canvas.SetTop(rectangle, OffsetY + (layout[selected].Y - originY) * zoom);
                rectangle.Width = Math.Max(20, layout[selected].Width * zoom);
                rectangle.Height = Math.Max(20, layout[selected].Height * zoom);
                Guides(layout[selected]);
                Validate();
            };
            rectangle.MouseLeftButtonUp += (_, e) => { if (original is null) return; rectangle.ReleaseMouseCapture(); original = null; Draw(); ShowSelectedSettings(); e.Handled = true; };
            canvas.Children.Add(rectangle);
        }
        Validate();
    }
    private void Guides(ScreenGeometry selected)
    {
        foreach (var old in canvas.Children.OfType<System.Windows.Shapes.Line>().ToArray())
            canvas.Children.Remove(old);
        if (autoAlign.IsChecked != true)
            return;
        void Line(double a, double b, bool vertical)
        {
            var line = new System.Windows.Shapes.Line { X1 = vertical ? a : 0, X2 = vertical ? a : Math.Max(700, canvas.ActualWidth), Y1 = vertical ? 0 : b, Y2 = vertical ? canvas.Height : b, Stroke = Theme.Brush("Warning"), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 4, 3 }, IsHitTestVisible = false };
            canvas.Children.Add(line);
        }
        foreach (var other in layout.Where(s => s.Id != selected.Id))
        {
            foreach (var x in new[] { selected.X, selected.X + selected.Width }.Where(x => new[] { other.X, other.X + other.Width }.Any(t => Math.Abs(t - x) < .01)))
                Line(OffsetX + (x - originX) * zoom, 0, true);
            foreach (var y in new[] { selected.Y, selected.Y + selected.Height }.Where(y => new[] { other.Y, other.Y + other.Height }.Any(t => Math.Abs(t - y) < .01)))
                Line(0, OffsetY + (y - originY) * zoom, false);
        }
    }
    private void Validate()
    {
        var valid = invalidScales.Count == 0 && ScreenGeometry.ValidLayout(layout);
        save.IsEnabled = valid && lease is not null && !blocked && !saving && !waiting;
        cancel.IsEnabled = (lease is not null || waiting) && !saving;
        validation.Text = invalidScales.Count > 0 ? "宽和高必须为有效正数" : layout.Length == 0 ? "" : !valid ? "请连接所有屏幕边缘、移除重叠，同色屏幕也须相连" : waiting ? "正在获取编辑权限…" : "布局有效";
        validation.Foreground = valid ? Theme.Brush("Muted") : Theme.Brush("Danger");
    }
}
