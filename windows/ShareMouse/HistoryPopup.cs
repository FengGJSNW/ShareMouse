using System;
using System.Linq;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Interop;
using ShareMouse.Core;
using ShareMouse.Network;
namespace ShareMouse;

public sealed class HistoryPopup : Window
{
    private readonly HistoryService history;
    private readonly Action<HistoryEntry, IntPtr> selected;
    private readonly IntPtr previous;
    private readonly HashSet<string> consumed = [];
    private readonly TextBox search = new() { MinWidth = 90, VerticalContentAlignment = VerticalAlignment.Center };
    private readonly ToggleButton favorites = new() { Content = "收藏", Padding = new Thickness(5, 3, 5, 3) };
    private readonly StackPanel list = new() { Focusable = true };
    private readonly TextBlock pageLabel = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
    private HistoryEntry[] entries = [];
    private int selection;
    private bool chosen;
    public HistoryPopup(HistoryService history, Action<HistoryEntry, IntPtr> selected, Action settings)
    {
        this.history = history;
        this.selected = selected;
        previous = GetForegroundWindow();
        Title = "剪贴板历史";
        Width = 400;
        Height = history.VisibleCount * 36 + 88;
        ResizeMode = ResizeMode.NoResize;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        var body = new DockPanel { Margin = new Thickness(9) };
        Content = new Border { Background = Theme.Brush("Surface"), BorderBrush = Theme.Brush("Border"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Child = body };
        var bottom = new StackPanel();
        DockPanel.SetDock(bottom, Dock.Bottom);
        body.Children.Add(bottom);
        var toolbar = new DockPanel { Margin = new Thickness(0, 7, 0, 4) };
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(actions, Dock.Right);
        toolbar.Children.Add(actions);
        Button Action(string label, Action run)
        {
            var button = new Button { Content = label, Padding = new Thickness(5, 3, 5, 3), Margin = new Thickness(4, 0, 0, 0) };
            button.Click += (_, _) => run();
            actions.Children.Add(button);
            return button;
        }
        Action("同步", () => _ = history.Sync());
        actions.Children.Add(favorites);
        Action("设置", () => { chosen = true; Close(); RestoreTarget(); settings(); });
        Action("详细", () => { chosen = true; Close(); RestoreTarget(); new HistoryDetailsPopup(history, (entry) => { RestoreTarget(); selected(entry, previous); }, search.Text, favorites.IsChecked == true).Show(); });
        toolbar.Children.Add(search);
        bottom.Children.Add(toolbar);
        var footer = new DockPanel();
        var pages = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(pages, Dock.Left);
        footer.Children.Add(pages);
        var back = new Button { Content = "‹", Padding = new Thickness(6, 0, 6, 0) };
        back.Click += (_, _) => Move(-history.VisibleCount);
        pages.Children.Add(back);
        pages.Children.Add(pageLabel);
        var next = new Button { Content = "›", Padding = new Thickness(6, 0, 6, 0) };
        next.Click += (_, _) => Move(history.VisibleCount);
        pages.Children.Add(next);
        footer.Children.Add(new TextBlock { Text = "↑↓ 选择 · ←→ 翻页 · 1–9 / Enter 粘贴", FontSize = 10, Foreground = Theme.Brush("Muted"), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center });
        bottom.Children.Add(footer);
        var scroll = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        body.Children.Add(scroll);
        scroll.PreviewMouseWheel += (_, e) => { Move(e.Delta < 0 ? history.VisibleCount : -history.VisibleCount); e.Handled = true; };
        search.TextChanged += (_, _) => { selection = 0; Refresh(); };
        favorites.Checked += (_, _) => { selection = 0; Refresh(); };
        favorites.Unchecked += (_, _) => { selection = 0; Refresh(); };
        history.Changed += Refresh;
        Closed += (_, _) => history.Changed -= Refresh;
        Deactivated += (_, _) => { if (IsVisible && !chosen) Close(); };
        PreviewKeyDown += (_, e) =>
        {
            var key = KeyName(e.Key);
            if (key is null || Keyboard.FocusedElement is TextBox { IsReadOnly: false } && key is not ("Escape" or "Enter"))
                return;
            if (Capture(new("keyDown", key)))
                e.Handled = true;
        };
        ReleaseSearchOnClick(this, search, list);
        Loaded += (_, _) => { Place(history.PreferredSide); list.Focus(); };
        Refresh();
    }
    internal static void ReleaseSearchOnClick(Window window, TextBox search, UIElement target)
    {
        window.PreviewMouseDown += (_, e) =>
        {
            var element = e.OriginalSource as DependencyObject;
            while (element is not null)
            {
                if (ReferenceEquals(element, search))
                    return;
                element = element is Visual || element is System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(element) : LogicalTreeHelper.GetParent(element);
            }
            if (search.IsKeyboardFocusWithin)
                target.Focus();
        };
    }
    internal static string? KeyName(Key key) => key switch
    {
        Key.Escape => "Escape",
        Key.Return => "Enter",
        Key.Up => "ArrowUp",
        Key.Down => "ArrowDown",
        Key.Left => "ArrowLeft",
        Key.Right => "ArrowRight",
        >= Key.D1 and <= Key.D9 => "Digit" + ((int)key - (int)Key.D0),
        >= Key.NumPad1 and <= Key.NumPad9 => "Numpad" + ((int)key - (int)Key.NumPad0),
        _ => null
    };
    private int Page => selection / history.VisibleCount;
    private void Refresh()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(Refresh);
            return;
        }
        entries = history.Entries.Where(e => (favorites.IsChecked != true || e.Favorite) && e.Text.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase)).ToArray();
        selection = Math.Clamp(selection, 0, Math.Max(0, entries.Length - 1));
        list.Children.Clear();
        favorites.Background = favorites.IsChecked == true ? Theme.Brush("Selection") : Brushes.Transparent;
        pageLabel.Text = $" {Page + 1}/{Math.Max(1, (entries.Length + history.VisibleCount - 1) / history.VisibleCount)} 页 ";
        var visible = entries.Skip(Page * history.VisibleCount).Take(history.VisibleCount).ToArray();
        if (visible.Length == 0)
            list.Children.Add(new TextBlock { Text = "没有匹配的文本历史", Margin = new Thickness(8), Foreground = Theme.Brush("Muted") });
        for (var index = 0; index < visible.Length; index++)
        {
            var entry = visible[index];
            var row = new DockPanel { Margin = new Thickness(6, 0, 6, 0) };
            var star = new Button { Content = entry.Favorite ? "★" : "☆", Width = 25, Padding = new Thickness(0), Foreground = entry.Favorite ? Theme.Brush("Warning") : Theme.Brush("Muted"), Background = Brushes.Transparent, BorderThickness = new Thickness(0), ToolTip = "收藏／取消收藏" };
            star.Click += (_, _) => history.Favorite(entry.Id);
            row.Children.Add(star);
            var content = new DockPanel();
            content.Children.Add(new TextBlock { Text = (index + 1).ToString(), Width = 19, Foreground = Theme.Brush("Muted"), VerticalAlignment = VerticalAlignment.Center });
            content.Children.Add(new TextBlock { Text = entry.Text.Length == 0 ? "（空文本）" : entry.Text.Replace('\r', ' ').Replace('\n', ' '), TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
            var choose = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0) };
            choose.Click += (_, _) => Choose(entry);
            row.Children.Add(choose);
            list.Children.Add(new Border { Height = 32, Margin = new Thickness(0, 0, 0, 4), CornerRadius = new CornerRadius(7), Background = selection == Page * history.VisibleCount + index ? Theme.Brush("Selection") : Theme.Brush("Hover"), Child = row });
        }
    }
    private void Move(int amount)
    {
        selection = Math.Clamp(selection + amount, 0, Math.Max(0, entries.Length - 1));
        Refresh();
    }
    public bool Capture(CapturedInput input)
    {
        if (input.Key is not { } key || input.Type is not ("keyDown" or "keyUp"))
            return false;
        if (input.Type == "keyUp")
            return consumed.Remove(key);
        if (consumed.Contains(key))
            return true;
        if (!IsVisible || !IsActive || new[] { "Control", "Alt", "Shift", "Meta" }.Any(m => key.StartsWith(m, StringComparison.Ordinal)))
            return false;
        if (Keyboard.FocusedElement is TextBox { IsReadOnly: false } && key is not ("Escape" or "Enter"))
            return false;
        if (KeyNameFromInput(key) is null)
            return false;
        consumed.Add(key);
        switch (key)
        {
            case "Escape":
                chosen = true;
                Close();
                RestoreTarget();
                break;
            case "ArrowUp":
                Move(-1);
                break;
            case "ArrowDown":
                Move(1);
                break;
            case "ArrowLeft":
                Move(-history.VisibleCount);
                break;
            case "ArrowRight":
                Move(history.VisibleCount);
                break;
            case "Enter":
                if (entries.Length > 0)
                    Choose(entries[selection]);
                break;
            default:
                if ((key.StartsWith("Digit", StringComparison.Ordinal) || key.StartsWith("Numpad", StringComparison.Ordinal)) && int.TryParse(key[^1..], out var digit) && digit >= 1 && digit <= history.VisibleCount)
                {
                    var index = Page * history.VisibleCount + digit - 1;
                    if (index < entries.Length)
                        Choose(entries[index]);
                }
                break;
        }
        return true;
    }
    private static string? KeyNameFromInput(string key) => key is "Escape" or "Enter" or "ArrowUp" or "ArrowDown" or "ArrowLeft" or "ArrowRight" || (key.StartsWith("Digit", StringComparison.Ordinal) || key.StartsWith("Numpad", StringComparison.Ordinal)) && int.TryParse(key[^1..], out var digit) && digit is >= 1 and <= 9 ? key : null;
    private void Choose(HistoryEntry entry)
    {
        if (chosen)
            return;
        chosen = true;
        Close();
        RestoreTarget();
        selected(entry, previous);
    }
    private void RestoreTarget()
    {
        if (previous != IntPtr.Zero && IsWindow(previous))
            SetForegroundWindow(previous);
    }
    private void Place(string side)
    {
        var point = System.Windows.Forms.Control.MousePosition;
        var area = System.Windows.Forms.Screen.FromPoint(point).WorkingArea;
        var monitor = MonitorFromPoint(new NativePoint { X = point.X, Y = point.Y }, 2);
        var scale = GetDpiForMonitor(monitor, 0, out var dpi, out _) == 0 ? dpi / 96.0 : 1;
        var width = Math.Min((int)Math.Ceiling(Width * scale), area.Width);
        var height = Math.Min((int)Math.Ceiling(Height * scale), area.Height);
        var right = point.X + 12;
        var left = point.X - 12 - width;
        var preferred = side == "left" ? left : right;
        var alternate = side == "left" ? right : left;
        var x = preferred >= area.Left && preferred + width <= area.Right ? preferred : alternate;
        SetWindowPos(new WindowInteropHelper(this).Handle, new IntPtr(-1), Math.Clamp(x, area.Left, area.Right - width), Math.Clamp(point.Y - 16, area.Top, area.Bottom - height), width, height, 0x10);
    }
    public static bool IsTargetForeground(IntPtr target) => target != IntPtr.Zero && IsWindow(target) && GetForegroundWindow() == target;
    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X, Y;
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(NativePoint point, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
}
public sealed class HistoryManagementPopup : Window
{
    public HistoryManagementPopup(HistoryService history)
    {
        Title = "剪贴板设置";
        Width = 440;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var body = new StackPanel { Margin = new Thickness(18) };
        Content = body;
        var status = new TextBlock { FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0) };
        var popup = new StackPanel { Margin = new Thickness(10) };
        body.Children.Add(new GroupBox { Header = "快捷面板", Content = popup });
        var count = new ComboBox { ItemsSource = Enumerable.Range(1, 9), SelectedItem = history.VisibleCount, Width = 65 };
        var side = new ComboBox { ItemsSource = new[] { "右侧", "左侧" }, SelectedIndex = history.PreferredSide == "left" ? 1 : 0, Width = 80 };
        var display = new WrapPanel();
        display.Children.Add(new TextBlock { Text = "每页条目 ", VerticalAlignment = VerticalAlignment.Center });
        display.Children.Add(count);
        display.Children.Add(new TextBlock { Text = "  偏好位置 ", VerticalAlignment = VerticalAlignment.Center });
        display.Children.Add(side);
        popup.Children.Add(display);
        popup.Children.Add(new TextBlock { Text = "每页 1–9 条；其余历史可翻页查看，不会被删除。", FontSize = 11, Margin = new Thickness(0, 8, 0, 0) });
        var storage = new StackPanel { Margin = new Thickness(10) };
        body.Children.Add(new GroupBox { Header = "存储与快捷键", Content = storage, Margin = new Thickness(0, 12, 0, 0) });
        var capacity = new TextBox { Text = history.Capacity.ToString(), Width = 65 };
        var key = new ComboBox { ItemsSource = new[] { "KeyV", "KeyH", "KeyB" }, SelectedItem = history.ShortcutKey, Width = 80 };
        var modifiers = new ComboBox { ItemsSource = new[] { "Control+Alt", "Meta+Alt", "Control+Shift", "Meta+Shift" }, SelectedItem = string.Join("+", history.Modifiers), Width = 135 };
        var row = new WrapPanel();
        row.Children.Add(new TextBlock { Text = "历史容量 ", VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(capacity);
        row.Children.Add(key);
        row.Children.Add(modifiers);
        storage.Children.Add(row);
        var actions = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        var save = new Button { Content = "保存设置", Padding = new Thickness(8, 4, 8, 4) };
        save.Click += (_, _) => { try { history.Configure(int.Parse(capacity.Text), (string)key.SelectedItem, ((string)modifiers.SelectedItem).Split('+')); history.ConfigurePopup((int)count.SelectedItem, side.SelectedIndex == 1 ? "left" : "right"); status.Text = "设置已保存"; } catch { status.Text = "容量需为 1–1000，每页 1–9 条，快捷键需包含修饰键。"; } };
        actions.Children.Add(save);
        var share = new Button { Content = "分享收藏", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(8, 4, 8, 4) };
        share.Click += async (_, _) => await history.ShareFavorites();
        actions.Children.Add(share);
        storage.Children.Add(actions);
        body.Children.Add(status);
        body.Children.Add(new TextBlock { Text = "收藏长期保留；显示、容量和快捷键设置只保存在本机。", FontSize = 11, Foreground = Theme.Brush("Muted"), Margin = new Thickness(0, 8, 0, 0), TextWrapping = TextWrapping.Wrap });
    }
}
public sealed class HistoryDetailsPopup : Window
{
    private readonly HistoryService history; private readonly Action<HistoryEntry> selected;
    private readonly TextBox search = new(); private readonly ToggleButton favorites = new() { Content = "收藏" };
    private readonly StackPanel list = new() { Focusable = true }; private readonly HashSet<string> expanded = [];
    private HistoryEntry[] entries = []; private int selection;
    private readonly HashSet<string> consumed = [];
    public bool Capture(CapturedInput input)
    {
        if (input.Key is not { } key || input.Type is not ("keyDown" or "keyUp"))
            return false;
        if (input.Type == "keyUp")
            return consumed.Remove(key);
        if (consumed.Contains(key))
            return true;
        if (!IsVisible || !IsActive || Keyboard.FocusedElement is TextBox { IsReadOnly: false } && key is not ("Escape" or "Enter"))
            return false;
        if (key is not ("Escape" or "Enter" or "ArrowUp" or "ArrowDown" or "ArrowLeft" or "ArrowRight"))
            return false;
        consumed.Add(key);
        switch (key)
        {
            case "Escape":
                Close();
                return true;
            case "Enter":
                if (entries.Length > 0)
                {
                    var entry = entries[selection];
                    Close();
                    selected(entry);
                }
                return true;
            case "ArrowUp":
                selection = Math.Max(0, selection - 1);
                break;
            case "ArrowDown":
                selection = Math.Min(Math.Max(0, entries.Length - 1), selection + 1);
                break;
            case "ArrowLeft":
                selection = Math.Max(0, selection - history.VisibleCount);
                break;
            case "ArrowRight":
                selection = Math.Min(Math.Max(0, entries.Length - 1), selection + history.VisibleCount);
                break;
            default:
                return false;
        }
        Refresh();
        if (list.Children.Count > selection)
            ((FrameworkElement)list.Children[selection]).BringIntoView();
        return true;
    }
    public HistoryDetailsPopup(HistoryService history, Action<HistoryEntry> selected, string query, bool favoriteOnly)
    {
        this.history = history;
        this.selected = selected;
        Title = "剪贴板详细记录";
        Width = 500;
        Height = 580;
        ShowInTaskbar = false;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var body = new DockPanel { Margin = new Thickness(16) };
        Content = body;
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        DockPanel.SetDock(top, Dock.Top);
        body.Children.Add(top);
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(actions, Dock.Right);
        top.Children.Add(actions);
        var sync = new Button { Content = "同步", Padding = new Thickness(8, 4, 8, 4) };
        sync.Click += async (_, _) => await history.Sync();
        actions.Children.Add(sync);
        actions.Children.Add(favorites);
        search.Text = query;
        favorites.IsChecked = favoriteOnly;
        top.Children.Add(search);
        var footer = new TextBlock { Text = "默认最多 10 行；展开可查看全文，粘贴保留完整内容。", FontSize = 11, Foreground = Theme.Brush("Muted"), Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(footer, Dock.Bottom);
        body.Children.Add(footer);
        body.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        HistoryPopup.ReleaseSearchOnClick(this, search, list);
        Loaded += (_, _) => list.Focus();
        PreviewKeyDown += (_, e) => { if (HistoryPopup.KeyName(e.Key) is { } key && Capture(new("keyDown", key))) e.Handled = true; };
        search.TextChanged += (_, _) => { selection = 0; Refresh(); };
        favorites.Checked += (_, _) => Refresh();
        favorites.Unchecked += (_, _) => Refresh();
        history.Changed += Refresh;
        Closed += (_, _) => history.Changed -= Refresh;
        Refresh();
    }
    private void Refresh()
    {
        list.Children.Clear();
        favorites.Background = favorites.IsChecked == true ? Theme.Brush("Selection") : Brushes.Transparent;
        entries = history.Entries.Where(e => (favorites.IsChecked != true || e.Favorite) && e.Text.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase)).ToArray();
        selection = Math.Clamp(selection, 0, Math.Max(0, entries.Length - 1));
        foreach (var entry in entries)
        {
            var body = new StackPanel { Margin = new Thickness(12) };
            var actions = new DockPanel();
            var star = new Button { Content = entry.Favorite ? "★" : "☆" };
            star.Click += (_, _) => history.Favorite(entry.Id);
            actions.Children.Add(star);
            var choose = new Button { Content = "粘贴", HorizontalAlignment = HorizontalAlignment.Right };
            DockPanel.SetDock(choose, Dock.Right);
            choose.Click += (_, _) => { Close(); selected(entry); };
            actions.Children.Add(choose);
            var expand = new Button { Content = expanded.Contains(entry.Id) ? "收起" : "展开全文", Margin = new Thickness(8, 0, 8, 0), HorizontalAlignment = HorizontalAlignment.Right };
            expand.Click += (_, _) => { if (!expanded.Add(entry.Id)) expanded.Remove(entry.Id); Refresh(); };
            actions.Children.Add(expand);
            body.Children.Add(actions);
            body.Children.Add(new TextBlock { Text = entry.Text.Length == 0 ? "（空文本）" : entry.Text, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis, LineHeight = 16, MaxHeight = expanded.Contains(entry.Id) ? double.PositiveInfinity : 160, Margin = new Thickness(0, 8, 0, 0) });
            list.Children.Add(new Border { CornerRadius = new CornerRadius(9), Background = entries.Length > 0 && entries[selection].Id == entry.Id ? Theme.Brush("Selection") : Theme.Brush("Surface"), Child = body, Margin = new Thickness(0, 0, 0, 10) });
        }
    }
}
