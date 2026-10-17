using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using ShareMouse.Core;
namespace ShareMouse;

public sealed class ConfigEditor : Window
{
    private sealed record Key(string Id, string Mac, string Windows, string Shift, string Side, string Category, string? Icon, bool Supported, string? MacFunction = null, string? WindowsFunction = null);
    private sealed record Position(string Key, double X, double Y, double W, double H);
    private sealed record Catalog(Key[] Keys, Dictionary<string, Position[]> Layouts, Dictionary<string, string> Icons);
    private readonly Catalog catalog;
    private KeyboardConfig[] configs;
    private readonly string owner;
    private readonly Func<KeyboardConfig[], string, Task> commit;
    private readonly ComboBox selection = new() { DisplayMemberPath = "Name", SelectedValuePath = "Id", Width = 245 };
    private readonly ComboBox source = new() { ItemsSource = new[] { "macOS", "Windows" }, SelectedIndex = 1, Width = 135 };
    private readonly ComboBox target = new() { ItemsSource = new[] { "macOS", "Windows" }, SelectedIndex = 0, Width = 135 };
    private readonly TextBox name = new() { Width = 245 }, search = new() { Margin = new Thickness(0, 8, 0, 8) };
    private readonly Canvas reference = new(), mapping = new();
    private readonly StackPanel library = new();
    private readonly TextBlock details = new(), status = new() { Foreground = Theme.Brush("Muted"), Margin = new Thickness(0, 10, 0, 0) };
    private readonly Dictionary<string, Border> referenceKeys = new(), mappingKeys = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private bool loading, saving, pending;
    private string? selectedKey, hovered, highlightedKey;
    private string Source => source.SelectedIndex == 0 ? "macos" : "windows";
    private string Target => Source == "macos" ? "windows" : "macos";
    private string Selected => (string?)selection.SelectedValue ?? configs[0].Id;
    private KeyboardConfig Config => configs.First(c => c.Id == Selected);
    private Dictionary<string, string> Overrides => Source == "macos" ? Config.MacToWindows : Config.WindowsToMac;
    public ConfigEditor(KeyboardConfig[] values, string selected, string owner, Func<KeyboardConfig[], string, Task> commit)
    {
        this.owner = owner;
        this.commit = commit;
        configs = values.Select(Clone).ToArray();
        catalog = JsonSerializer.Deserialize<Catalog>(File.ReadAllText(System.IO.Path.Combine(AppContext.BaseDirectory, "keyboard-layouts.json")), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException("Missing keyboard catalog");
        Title = "共享键盘配置";
        Width = 1170;
        Height = 850;
        MinWidth = 980;
        MinHeight = 690;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var root = new DockPanel { Margin = new Thickness(20) };
        Content = root;
        var header = new StackPanel();
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        var management = new WrapPanel { Margin = new Thickness(0, 0, 0, 12) };
        header.Children.Add(management);
        management.Children.Add(selection);
        Button Action(string text, Action action)
        {
            var b = new Button { Content = text, Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 5, 12, 5) };
            b.Click += (_, _) => action();
            management.Children.Add(b);
            return b;
        }
        Action("新建", () => { if (configs.Length >= 64) return; var c = new KeyboardConfig(Guid.NewGuid().ToString("D"), owner, "新配置", new(), new(), 1); configs = configs.Append(c).ToArray(); Select(c.Id); Changed(); });
        Action("复制", () => { if (configs.Length >= 64) return; var c = Clone(Config) with { Id = Guid.NewGuid().ToString("D"), OwnerPeerID = owner, Name = Config.Name + "（副本）", Revision = 1 }; configs = configs.Append(c).ToArray(); Select(c.Id); Changed(); });
        Action("删除", async () => { if (configs.Length < 2) return; var id = Selected; if (await ShareMouseDialog.ChooseAsync("删除键盘配置", "删除此配置？", [("cancel", "取消"), ("delete", "删除")]) != "delete" || configs.Length < 2) return; configs = configs.Where(c => c.Id != id).ToArray(); Select(configs[0].Id); Changed(); });
        var direction = new WrapPanel { Margin = new Thickness(0, 0, 0, 12) };
        header.Children.Add(direction);
        direction.Children.Add(name);
        direction.Children.Add(new TextBlock { Text = " 来源 ", VerticalAlignment = VerticalAlignment.Center });
        direction.Children.Add(source);
        direction.Children.Add(new TextBlock { Text = " → 目标 ", VerticalAlignment = VerticalAlignment.Center });
        direction.Children.Add(target);
        DockPanel.SetDock(status, Dock.Bottom);
        root.Children.Add(status);
        var body = new Grid();
        body.ColumnDefinitions.Add(new()
        {
            Width = new GridLength(1, GridUnitType.Star)
        });
        body.ColumnDefinitions.Add(new()
        {
            Width = new GridLength(240)
        });
        root.Children.Add(body);
        var keyboards = new StackPanel();
        var scroll = new ScrollViewer { Content = keyboards, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 0, 18, 0) };
        body.Children.Add(scroll);
        keyboards.Children.Add(new TextBlock { Text = "来源键盘 · 只读参考", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        keyboards.Children.Add(KeyboardTray(reference));
        keyboards.Children.Add(new TextBlock { Text = "目标映射 · 保持来源键盘的位置与形状", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 18, 0, 8) });
        keyboards.Children.Add(KeyboardTray(mapping));
        keyboards.Children.Add(details);
        var reset = new Button { Content = "恢复所选按键默认映射", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
        reset.Click += (_, _) => { if (selectedKey is { } key) { SetMapping(key, null); Changed(); Draw(); } };
        keyboards.Children.Add(reset);
        var resetAll = new Button { Content = "恢复此方向全部默认映射", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
        resetAll.Click += (_, _) => { Overrides.Clear(); Changed(); Draw(); };
        keyboards.Children.Add(resetAll);
        keyboards.Children.Add(new TextBlock { Text = "Mac→Windows：不按来源 Fn 的顶行按目标同号功能执行；按来源 Fn 输出普通 F1–F12，暂时释放它映射的修饰键。Fn／Command 的位置使用系统当前设置，不重复交换。", Foreground = Theme.Brush("Muted"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 0) });
        var lib = new DockPanel();
        Grid.SetColumn(lib, 1);
        body.Children.Add(lib);
        var title = new StackPanel();
        title.Children.Add(new TextBlock { Text = "目标按键库", FontWeight = FontWeights.SemiBold });
        title.Children.Add(search);
        DockPanel.SetDock(title, Dock.Top);
        lib.Children.Add(title);
        var help = new TextBlock { Text = "可重复拖入；也可选中下方按键后点击库中按键。", TextWrapping = TextWrapping.Wrap, Foreground = Theme.Brush("Muted") };
        DockPanel.SetDock(help, Dock.Bottom);
        lib.Children.Add(help);
        lib.Children.Add(new ScrollViewer { Content = library, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        selection.SelectionChanged += (_, _) => { if (!loading) { Draw(); Changed(); } };
        name.TextChanged += (_, _) => { if (!loading && !string.IsNullOrWhiteSpace(name.Text)) { var i = Array.FindIndex(configs, c => c.Id == Selected); configs[i] = configs[i] with { Name = name.Text.Length <= 40 ? name.Text : name.Text[..40] }; var id = Selected; loading = true; selection.ItemsSource = configs.ToArray(); selection.SelectedValue = id; loading = false; Changed(); } };
        source.SelectionChanged += (_, _) => { if (loading) return; loading = true; target.SelectedIndex = 1 - source.SelectedIndex; loading = false; selectedKey = null; Draw(); };
        target.SelectionChanged += (_, _) => { if (loading) return; loading = true; source.SelectedIndex = 1 - target.SelectedIndex; loading = false; selectedKey = null; Draw(); };
        search.TextChanged += (_, _) => DrawLibrary();
        timer.Tick += async (_, _) => { timer.Stop(); await Save(); };
        Closed += async (_, _) => { timer.Stop(); if (pending) await Save(); };
        Select(selected);
        status.Text = "自动保存；拖动右侧按键到下方键盘。";
    }
    private static Border KeyboardTray(Canvas keyboard) => new() { Child = keyboard, Padding = new Thickness(12), CornerRadius = new CornerRadius(12), Background = Theme.Brush("Well"), BorderBrush = Theme.Brush("Border"), BorderThickness = new Thickness(1) };
    private static KeyboardConfig Clone(KeyboardConfig c) => c with { WindowsToMac = new(c.WindowsToMac), MacToWindows = new(c.MacToWindows) };
    private void SetMapping(string key, string? targetKey)
    {
        if (Source == "macos" && KeyboardMapping.MacFunction(key) is { } function)
            Overrides.Remove(function);
        if (targetKey is null)
            Overrides.Remove(key);
        else
            Overrides[key] = targetKey;
    }
    private void Select(string id)
    {
        loading = true;
        selection.ItemsSource = configs;
        selection.SelectedValue = configs.Any(c => c.Id == id) ? id : configs[0].Id;
        loading = false;
        Draw();
    }
    private bool Enabled(string key, string platform, bool forInjection = false) => key == KeyboardMapping.NoAction || catalog.Keys.Any(k => k.Id == key && k.Supported) && (!forInjection || KeyboardMapping.CanInject(key, platform));
    private string Label(string id, string platform)
    {
        var k = catalog.Keys.FirstOrDefault(k => k.Id == id);
        return id == KeyboardMapping.NoAction ? "No Action" : k is null ? id : (platform == "macos" ? k.Mac : k.Windows) + (k.Side.Length > 0 ? " · " + k.Side : "");
    }
    private FrameworkElement Face(string id, string platform)
    {
        var k = catalog.Keys.FirstOrDefault(k => k.Id == id);
        var panel = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        var icon = id == "Fn" || k?.Category == "功能键" ? null : k?.Icon;
        if (icon == "command" && platform == "windows")
            icon = "windows";
        if (icon is not null && catalog.Icons.TryGetValue(icon, out var svg))
            panel.Children.Add(new Viewbox { Width = 17, Height = 17, Child = new System.Windows.Shapes.Path { Data = Geometry.Parse(svg), Stroke = Theme.Brush("Text"), StrokeThickness = 1.4 } });
        else
            panel.Children.Add(new TextBlock { Text = id == KeyboardMapping.NoAction ? "∅" : k is null ? id : platform == "macos" ? k.Mac : k.Windows, FontSize = 11, FontWeight = FontWeights.Medium, TextAlignment = TextAlignment.Center });
        if (k?.Shift.Length > 0)
            panel.Children.Add(new TextBlock { Text = k.Shift, FontSize = 9, Foreground = Theme.Brush("Muted"), TextAlignment = TextAlignment.Center });
        if (k?.Side.Length > 0)
            panel.Children.Add(new TextBlock { Text = k.Side, FontSize = 8, Foreground = Theme.Brush("Muted"), TextAlignment = TextAlignment.Center });
        return panel;
    }
    private void Draw()
    {
        loading = true;
        name.Text = Config.Name;
        loading = false;
        DrawKeyboard(reference, false, referenceKeys);
        DrawKeyboard(mapping, true, mappingKeys);
        DrawLibrary();
        Highlight();
    }
    private void DrawKeyboard(Canvas canvas, bool editable, Dictionary<string, Border> registry)
    {
        canvas.Children.Clear();
        registry.Clear();
        var positions = catalog.Layouts[Source];
        double unit = Source == "macos" ? 51 : 44;
        canvas.Width = positions.Max(p => p.X + p.W) * unit;
        canvas.Height = positions.Max(p => p.Y + p.H) * unit;
        foreach (var p in positions)
        {
            var key = p.Key;
            var enabled = Enabled(key, Source);
            var mapped = editable ? KeyboardMapping.Map(key, Source, Target, Config) : key;
            var b = new Border { Width = p.W * unit - 4, Height = p.H * unit - 4, CornerRadius = new CornerRadius(5), BorderThickness = new Thickness(1), Background = Theme.Brush("Surface"), Child = Face(mapped, editable ? Target : Source), Opacity = enabled ? 1 : .35, ToolTip = enabled ? Label(key, Source) + (editable ? " → " + Label(mapped, Target) : "") : "此平台无法可靠捕获该按键" };
            Theme.Keycap(b);
            registry[key] = b;
            Paint(b, key, editable);
            b.MouseEnter += (_, _) => { hovered = key; Highlight(); };
            b.MouseLeave += (_, _) => { hovered = null; Highlight(); };
            b.MouseLeftButtonUp += (_, _) => { selectedKey = key; Highlight(); };
            if (editable && enabled)
            {
                b.AllowDrop = true;
                b.DragOver += (_, e) => { var id = e.Data.GetData("ShareMouse.KeyID") as string; e.Effects = id is not null && Enabled(id, Target, true) ? DragDropEffects.Copy : DragDropEffects.None; b.BorderBrush = e.Effects == DragDropEffects.Copy ? Theme.Brush("Good") : Theme.Brush("Danger"); b.BorderThickness = new Thickness(2); e.Handled = true; };
                b.DragLeave += (_, _) => Paint(b, key, true);
                b.Drop += (_, e) => { if (e.Data.GetData("ShareMouse.KeyID") is string id && Enabled(id, Target, true)) { SetMapping(key, id); selectedKey = key; Changed(); Draw(); } e.Handled = true; };
            }
            Canvas.SetLeft(b, p.X * unit);
            Canvas.SetTop(b, p.Y * unit);
            canvas.Children.Add(b);
        }
    }
    private void DrawLibrary()
    {
        library.Children.Clear();
        void Add(string id, WrapPanel? row = null)
        {
            var enabled = Enabled(id, Target, true);
            var b = new Border { Width = id == KeyboardMapping.NoAction ? 215 : 65, Height = 44, Margin = new Thickness(3), CornerRadius = new CornerRadius(5), BorderBrush = Theme.Brush("Border"), BorderThickness = new Thickness(1), Background = Theme.Brush("Surface"), Child = Face(id, Target), Opacity = enabled ? 1 : .35, ToolTip = Label(id, Target) };
            Theme.Keycap(b);
            AttachLibraryDrag(b, id, enabled);
            if (row is null)
                library.Children.Add(b);
            else
                row.Children.Add(b);
        }
        Add(KeyboardMapping.NoAction);
        foreach (var category in new[] { "字母", "数字与符号", "修饰键", "导航与编辑", "F1-F24", "特殊" })
        {
            var items = catalog.Keys.Where(k => k.Category == category && (category != "F1-F24" || (int.TryParse(k.Id.AsSpan(1), out var number) && number <= 12)) && (search.Text.Length == 0 || (k.Id + " " + k.Mac + " " + k.Windows).Contains(search.Text, StringComparison.OrdinalIgnoreCase))).ToArray();
            if (items.Length == 0)
                continue;
            library.Children.Add(new TextBlock { Text = category == "F1-F24" ? "F1–F12" : category, Foreground = Theme.Brush("Muted"), FontSize = 11, Margin = new Thickness(3, 10, 0, 3) });
            var row = new WrapPanel();
            library.Children.Add(row);
            foreach (var key in items)
                Add(key.Id, row);
        }
    }
    private void AttachLibraryDrag(Border tile, string id, bool enabled)
    {
        Point start = new();
        bool armed = false, dragging = false;
        tile.PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (!enabled)
                return;
            start = e.GetPosition(this);
            armed = tile.CaptureMouse();
            e.Handled = true;
        };
        tile.PreviewMouseMove += (_, e) =>
        {
            if (!armed || dragging || e.LeftButton != MouseButtonState.Pressed)
                return;
            var at = e.GetPosition(this);
            if (Math.Abs(at.X - start.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(at.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance)
                return;
            armed = false;
            dragging = true;
            tile.ReleaseMouseCapture();
            try
            {
                DragDrop.DoDragDrop(tile, new DataObject("ShareMouse.KeyID", id), DragDropEffects.Copy);
            }
            finally { dragging = false; if (tile.IsMouseCaptured) tile.ReleaseMouseCapture(); }
            e.Handled = true;
        };
        tile.PreviewMouseLeftButtonUp += (_, e) =>
        {
            var clicked = armed;
            armed = false;
            if (tile.IsMouseCaptured)
                tile.ReleaseMouseCapture();
            if (clicked && !dragging && enabled && selectedKey is { } key && Enabled(key, Source))
            {
                SetMapping(key, id);
                Changed();
                Draw();
            }
            e.Handled = true;
        };
        tile.LostMouseCapture += (_, _) => armed = false;
    }
    private void Highlight()
    {
        var next = hovered ?? selectedKey;
        // Only the previously highlighted and newly highlighted positions change.
        foreach (var key in new[] { highlightedKey, next }.Where(k => k is not null).Distinct())
        {
            if (referenceKeys.TryGetValue(key!, out var referenceKey))
                Paint(referenceKey, key!, false);
            if (mappingKeys.TryGetValue(key!, out var mappedKey))
                Paint(mappedKey, key!, true);
        }
        highlightedKey = next;
        details.Text = selectedKey is { } selected ? Label(selected, Source) + " → " + Label(KeyboardMapping.Map(selected, Source, Target, Config), Target) : "点击下方键位以查看映射";
    }
    private void Paint(Border b, string key, bool editable)
    {
        var linked = key == (hovered ?? selectedKey);
        b.BorderBrush = linked ? Theme.Brush("Accent") : editable && Overrides.ContainsKey(key) ? Theme.Brush("Warning") : Theme.Brush("Border");
        b.BorderThickness = new Thickness(linked ? 2 : 1);
        Theme.KeycapSelection(b, linked);
    }
    private void Changed()
    {
        pending = true;
        timer.Stop();
        timer.Start();
    }
    private async Task Save()
    {
        if (saving)
            return;
        saving = true;
        try
        {
            while (pending)
            {
                pending = false;
                var i = Array.FindIndex(configs, c => c.Id == Selected);
                configs[i] = configs[i] with
                {
                    Modified = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
                };
                var snapshot = configs.Select(Clone).ToArray();
                var id = Selected;
                try
                {
                    await commit(snapshot, id);
                    status.Text = "已自动保存";
                }
                catch { status.Text = "保存／同步未完成；编辑内容仍在窗口中，下一次编辑将重试。"; }
            }
        }
        finally { saving = false; }
    }
}
