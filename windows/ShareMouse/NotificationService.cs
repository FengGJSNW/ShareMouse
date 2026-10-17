using System;
using System.Collections.Generic;
using System.Linq;
using System.Security;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;
using ShareMouse.Core;
namespace ShareMouse;

internal interface NotificationRenderer
{
    void Show(string id, string title, string message, double? progress, bool persistent); void Hide(string id); void Stop();
}
internal sealed class NativeRenderer : NotificationRenderer
{
    private ToastNotifier? notifier;
    private readonly Dictionary<string, uint> sequences = new(); private readonly HashSet<string> hidden = new();
    public bool Available => notifier is not null;
    public bool Enable()
    {
        try
        {
            WindowsNotificationRegistration.Prepare();
            var value = ToastNotificationManager.CreateToastNotifier(WindowsNotificationRegistration.AppID);
            if (value.Setting != NotificationSetting.Enabled)
                return false;
            notifier = value;
            return true;
        }
        catch { return false; }
    }
    private static string Tag(string id) => id.Replace("-", "")[..Math.Min(16, id.Replace("-", "").Length)];
    public void Show(string id, string title, string message, double? progress, bool persistent)
    {
        if (notifier is null || hidden.Contains(id))
            return;
        var tag = Tag(id);
        var data = new NotificationData { SequenceNumber = sequences.GetValueOrDefault(id) + 1 };
        data.Values["progress"] = (progress ?? 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
        data.Values["label"] = $"{(int)((progress ?? 1) * 100)}%";
        data.Values["status"] = title;
        data.Values["title"] = title;
        data.Values["message"] = message;
        if (progress is not null && sequences.ContainsKey(id) && notifier.Update(data, tag, "ShareMouse") == NotificationUpdateResult.Succeeded)
        {
            sequences[id] = data.SequenceNumber;
            return;
        }
        var xml = new XmlDocument();
        xml.LoadXml("<toast><visual><binding template=\"ToastGeneric\"><text>{title}</text><text>{message}</text>" + (progress is null ? "" : "<progress value=\"{progress}\" valueStringOverride=\"{label}\" status=\"{status}\"/>") + "</binding></visual></toast>");
        var toast = new ToastNotification(xml) { Tag = tag, Group = "ShareMouse", Data = data };
        if (!persistent)
            toast.ExpirationTime = DateTimeOffset.UtcNow.AddSeconds(10);
        toast.Dismissed += (_, e) => { if (e.Reason == ToastDismissalReason.UserCanceled) Application.Current.Dispatcher.BeginInvoke(() => hidden.Add(id)); };
        sequences[id] = data.SequenceNumber;
        notifier.Show(toast);
    }
    public void Hide(string id)
    {
        try
        {
            ToastNotificationManager.History.Remove(Tag(id), "ShareMouse", WindowsNotificationRegistration.AppID);
        }
        catch { }
        sequences.Remove(id);
    }
    public void Stop()
    {
        foreach (var id in sequences.Keys.ToArray())
            Hide(id);
        hidden.Clear();
    }
}
internal sealed class CustomRenderer : NotificationRenderer
{
    private const double CardWidth = 340;
    private static readonly Brush Orange = new SolidColorBrush(Color.FromRgb(255, 149, 0));
    public string Corner = "bottomRight";
    private readonly Dictionary<string, Window> windows = new();
    private readonly HashSet<string> hidden = new();
    private readonly Dictionary<string, DispatcherTimer> timers = new();
    private readonly List<string> order = new();
    private readonly Dictionary<string, string> monitorNames = new();
    private Window GetWindow(string id)
    {
        if (windows.TryGetValue(id, out var existing))
            return existing;
        var window = new Window
        {
            Width = CardWidth + 16,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ShowInTaskbar = false,
            ShowActivated = false,
            Focusable = false,
            Topmost = true,
            Tag = "notification"
        };
        window.SourceInitialized += (_, _) => HwndSource.FromHwnd(new WindowInteropHelper(window).Handle)?.AddHook(PreventActivation);
        windows[id] = window;
        order.Add(id);
        return window;
    }
    private static IntPtr PreventActivation(IntPtr handle, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == 0x21)
        {
            handled = true;
            return new IntPtr(3);
        } // MA_NOACTIVATE keeps clicks without taking focus.
        return IntPtr.Zero;
    }
    private static TextBlock Label(string text, double size = 12, bool secondary = false)
    {
        var label = new TextBlock { Text = text, FontSize = size, TextTrimming = TextTrimming.CharacterEllipsis };
        label.SetResourceReference(TextBlock.ForegroundProperty, secondary ? "MutedBrush" : "TextBrush");
        return label;
    }
    private static string Symbol(string title) => title.Contains("失败") ? "\uE7BA" : title.Contains("发送") ? "\uE898" : title.Contains("接收") ? "\uE896" : title.Contains("链路") || title.Contains("重连") ? "\uE701" : title.StartsWith("AI", StringComparison.Ordinal) ? "\uE950" : "\uE946";
    private static Button PlainButton(string text, Action action)
    {
        var button = new Button { Content = text, Focusable = false, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(2), Margin = new Thickness(0) };
        button.Click += (_, _) => action();
        return button;
    }
    private static Border Card(UIElement content, bool control = false)
    {
        var card = new Border { Width = CardWidth, Margin = new Thickness(8), Padding = new Thickness(14), CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(control ? 1.5 : 0.5), Child = content };
        card.SetResourceReference(Border.BackgroundProperty, control ? "CanvasBrush" : "SurfaceBrush");
        if (control)
            card.BorderBrush = Orange;
        else
            card.SetResourceReference(Border.BorderBrushProperty, "BorderBrush");
        if (!SystemParameters.HighContrast)
            card.Effect = new DropShadowEffect { BlurRadius = 14, ShadowDepth = 2, Opacity = 0.16 };
        return card;
    }
    private void Standard(string id, string title, string message, double? progress, bool persistent, Action hide)
    {
        var body = new StackPanel();
        var heading = new DockPanel();
        var close = PlainButton("×", hide);
        close.Width = 18;
        close.Height = 18;
        close.FontSize = 14;
        System.Windows.Automation.AutomationProperties.SetName(close, "关闭");
        DockPanel.SetDock(close, Dock.Right);
        heading.Children.Add(close);
        var glyph = Label(Symbol(title), 13);
        glyph.FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets");
        glyph.Width = 16;
        glyph.Margin = new Thickness(0, 0, 8, 0);
        glyph.Foreground = title.Contains("失败") ? Orange : Theme.Brush("Accent");
        heading.Children.Add(glyph);
        var caption = Label(title, 13);
        caption.FontWeight = FontWeights.SemiBold;
        heading.Children.Add(caption);
        body.Children.Add(heading);
        var text = Label(message, 12, true);
        text.TextWrapping = TextWrapping.Wrap;
        text.LineHeight = 17;
        text.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        text.MaxHeight = 68;
        text.Margin = new Thickness(0, 6, 0, 0);
        body.Children.Add(text);
        if (progress is not null)
            body.Children.Add(new ProgressBar { Value = progress.Value, Maximum = 1, Height = 4, Margin = new Thickness(0, 8, 0, 0) });
        Present(id, Card(body), persistent);
    }
    public void Show(string id, string title, string message, double? progress, bool persistent)
    {
        if (hidden.Contains(id))
            return;
        Standard(id, title, message, progress, persistent, () => { hidden.Add(id); Hide(id); });
    }
    public void ShowMCP(string id, string title, string message, bool persistent, Action? exit, Action hide, bool textOnly = false)
    {
        if (!textOnly && exit is null)
        {
            Standard(id, title, message, null, persistent, hide);
            return;
        }
        var body = new StackPanel();
        var heading = new DockPanel();
        if (textOnly)
        {
            var hideLink = TextLink("隐藏", hide);
            DockPanel.SetDock(hideLink, Dock.Right);
            heading.Children.Add(hideLink);
            if (exit is not null)
            {
                var exitLink = TextLink("退出接管", exit);
                DockPanel.SetDock(exitLink, Dock.Right);
                heading.Children.Add(exitLink);
            }
            var caption = MCPText(title, 13);
            caption.FontWeight = FontWeights.SemiBold;
            heading.Children.Add(caption);
        }
        else
        {
            var icon = Label("\uE950", 14);
            icon.Foreground = Orange;
            icon.Width = 16;
            icon.Margin = new Thickness(0, 0, 8, 0);
            icon.FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets");
            heading.Children.Add(icon);
            var caption = Label(title, 13);
            caption.FontWeight = FontWeights.SemiBold;
            heading.Children.Add(caption);
        }
        body.Children.Add(heading);
        foreach (var line in message.Split('\n'))
        {
            var text = textOnly ? MCPText(line, 12) : Label(line, 12, true);
            text.Margin = new Thickness(0, 4, 0, 0);
            body.Children.Add(text);
        }
        if (!textOnly && exit is not null)
        {
            var button = new Button { Content = "退出接管", Focusable = false, HorizontalAlignment = HorizontalAlignment.Right, Background = Orange, Foreground = Brushes.White, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 8, 0, 0) };
            button.Click += (_, _) => exit();
            body.Children.Add(button);
        }
        if (textOnly)
        {
            body.Margin = new Thickness(2);
            Present(id, body, persistent);
        }
        else
            Present(id, Card(body, true), persistent);
    }
    private static TextBlock MCPText(string text, double size) => new() { Text = text, FontSize = size, Foreground = Brushes.White, TextTrimming = TextTrimming.CharacterEllipsis, Effect = new DropShadowEffect { Color = Colors.Black, BlurRadius = 2, ShadowDepth = 0, Opacity = 1 } };
    private static Button TextLink(string title, Action action)
    {
        var label = MCPText(title, 12);
        label.TextDecorations = TextDecorations.Underline;
        label.Margin = new Thickness(8, 0, 0, 0);
        var button = PlainButton("", action);
        button.Content = label;
        button.Template = new ControlTemplate(typeof(Button)) { VisualTree = new FrameworkElementFactory(typeof(ContentPresenter)) };
        return button;
    }
    private void Present(string id, FrameworkElement content, bool persistent)
    {
        var window = GetWindow(id);
        var first = !window.IsVisible;
        window.Content = content;
        content.Measure(new Size(window.Width, double.PositiveInfinity));
        window.Height = Math.Max(36, content.DesiredSize.Height);
        if (first)
            window.Opacity = Theme.Motion ? 0 : 1;
        Arrange();
        window.Show();
        if (first && Theme.Motion)
        {
            var animation = new System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames();
            animation.KeyFrames.Add(new System.Windows.Media.Animation.SplineDoubleKeyFrame(1, System.Windows.Media.Animation.KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(220)), new System.Windows.Media.Animation.KeySpline(0.16, 1, 0.3, 1)));
            window.BeginAnimation(UIElement.OpacityProperty, animation);
        }
        if (persistent && timers.Remove(id, out var previous))
            previous.Stop();
        if (!persistent && !timers.ContainsKey(id))
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
            timers[id] = timer;
            timer.Tick += (_, _) => Hide(id);
            timer.Start();
        }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    private void Arrange()
    {
        var display = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Control.MousePosition);
        var area = display.WorkingArea;
        var offset = 20.0;
        foreach (var id in order)
        {
            var window = windows[id];
            var handle = new WindowInteropHelper(window).EnsureHandle();
            // Move onto the cursor's monitor before reading this notification's own DPI.
            if (monitorNames.GetValueOrDefault(id) != display.DeviceName)
            {
                _ = SetWindowPos(handle, new IntPtr(-1), area.X + 20, area.Y + 20, 0, 0, 0x211);
                monitorNames[id] = display.DeviceName;
            }
            var dpi = GetDpiForWindow(handle);
            var scale = (dpi == 0 ? 96 : dpi) / 96.0;
            var width = (int)Math.Ceiling(window.Width * scale);
            var height = (int)Math.Ceiling(window.Height * scale);
            var x = Corner.EndsWith("Right", StringComparison.Ordinal) ? area.Right - width - (int)(20 * scale) : area.X + (int)(20 * scale);
            var y = Corner.StartsWith("top", StringComparison.Ordinal) ? area.Y + (int)(offset * scale) : area.Bottom - height - (int)(offset * scale);
            _ = SetWindowPos(handle, new IntPtr(-1), x, y, width, height, 0x210);
            offset += window.Height + 10;
        }
    }
    public void Hide(string id)
    {
        if (windows.Remove(id, out var window))
            window.Close();
        order.Remove(id);
        monitorNames.Remove(id);
        if (timers.Remove(id, out var timer))
            timer.Stop();
        Arrange();
    }
    public void Stop()
    {
        foreach (var id in windows.Keys.ToArray())
            Hide(id);
        hidden.Clear();
    }
}
public sealed class NotificationService : IDisposable
{
    private readonly NativeRenderer native = new(); private readonly CustomRenderer custom = new(); private readonly LocalPreferences preferences; private readonly Dictionary<string, string> signatures = new();
    public NotificationService(LocalPreferences preferences)
    {
        this.preferences = preferences;
        ticker.Tick += (_, _) => RefreshTransfers();
    }
    public bool Configure()
    {
        native.Stop();
        custom.Stop();
        signatures.Clear();
        custom.Corner = preferences.Corner;
        RefreshMCPPresentation();
        return preferences.Renderer != "native" || native.Enable();
    }
    private NotificationRenderer Renderer => preferences.Renderer == "native" && native.Available ? native : custom;
    private readonly Dictionary<string, HashSet<string>> previousLinks = new(), seenLinks = new();
    private readonly Dictionary<string, (string Name, HashSet<string> Labels)> pendingLinks = new();
    private readonly Dictionary<string, DispatcherTimer> linkTimers = new();
    public void Connections(SessionInfo[] sessions)
    {
        var alive = sessions.Select(s => s.PeerID).ToHashSet();
        foreach (var peer in previousLinks.Keys.Where(p => !alive.Contains(p)).ToArray())
            previousLinks[peer] = [];
        foreach (var item in sessions)
        {
            HashSet<string> current = [];
            if (item.Capabilities.Contains("tcp") || item.Capabilities.Contains("quic"))
                current.Add("Wi-Fi");
            if (item.Capabilities.Contains("ble"))
                current.Add("蓝牙");
            previousLinks.TryGetValue(item.PeerID, out var previous);
            var seen = seenLinks.GetValueOrDefault(item.PeerID) ?? [];
            previousLinks[item.PeerID] = current;
            seenLinks[item.PeerID] = seen.Union(current).ToHashSet();
            if (previous is null)
                continue;
            var labels = current.Except(previous).Select(k => k + " 链路" + (seen.Contains(k) ? "已重连" : "已连接")).ToHashSet();
            if (labels.Count == 0)
                continue;
            if (pendingLinks.TryGetValue(item.PeerID, out var pending))
                labels.UnionWith(pending.Labels);
            pendingLinks[item.PeerID] = (item.Name, labels);
            if (linkTimers.Remove(item.PeerID, out var old))
                old.Stop();
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
            linkTimers[item.PeerID] = timer;
            timer.Tick += (_, _) => { timer.Stop(); linkTimers.Remove(item.PeerID); if (pendingLinks.Remove(item.PeerID, out var value)) Toast("设备链路", value.Name + "\n" + string.Join(" · ", value.Labels.Order())); };
            timer.Start();
        }
    }
    public void InputReconnected(SessionInfo[] sessions, bool bluetoothPreferred)
    {
        var lines = sessions.Select(item => item.Name + " · " + (bluetoothPreferred && item.Capabilities.Contains("ble") ? "蓝牙" : item.Capabilities.Contains("quic") ? "Wi-Fi（QUIC）" : item.Capabilities.Contains("tcp") ? "Wi-Fi（TCP）" : "蓝牙") + " 链路").ToArray();
        if (lines.Length > 0)
            Toast("键鼠重连完成", string.Join("\n", lines));
    }
    public void Toast(string title, string message)
    {
        custom.Corner = preferences.Corner;
        try
        {
            Renderer.Show(Guid.NewGuid().ToString("D"), title, message, null, false);
        }
        catch { custom.Show(Guid.NewGuid().ToString("D"), title, message, null, false); }
    }
    private string? mcpControlID, mcpNoticeID;
    public Action ExitMCPControl { get; set; } = () => { };
    public Action HideMCPToast { get; set; } = () => { };
    private long? lastMCPNotice;
    private long mcpNoticeShownAt;
    private string mcpNoticeTitle = "", mcpNoticeMessage = "";
    public void RefreshMCPPresentation()
    {
        custom.Corner = preferences.Corner;
        if (mcpControlID is { } control)
        {
            custom.Hide(control);
            if (preferences.McpToastStyle != "hidden")
                custom.ShowMCP(control, "AI 正在控制这台电脑", "正在截图并操作键鼠。\n误碰键鼠不会结束接管。", true, ExitMCPControl, HideMCPToast, preferences.McpToastStyle == "text");
        }
        if (mcpNoticeID is { } notice)
        {
            custom.Hide(notice);
            if (preferences.McpToastStyle != "hidden" && mcpControlID is null && System.Diagnostics.Stopwatch.GetElapsedTime(mcpNoticeShownAt).TotalSeconds < 5)
                custom.ShowMCP(notice, mcpNoticeTitle, mcpNoticeMessage, false, null, HideMCPToast, preferences.McpToastStyle == "text");
            else
                mcpNoticeID = null;
        }
    }
    private void ShowMCPNotice(string title, string message)
    {
        if (mcpNoticeID is { } previous)
            custom.Hide(previous);
        mcpNoticeID = null;
        if (preferences.McpToastStyle == "hidden")
            return;
        mcpNoticeID = Guid.NewGuid().ToString("D");
        mcpNoticeTitle = title;
        mcpNoticeMessage = message;
        mcpNoticeShownAt = System.Diagnostics.Stopwatch.GetTimestamp();
        custom.Corner = preferences.Corner;
        custom.ShowMCP(mcpNoticeID, title, message, false, null, HideMCPToast, preferences.McpToastStyle == "text");
    }
    public void MCPActivity()
    {
        var now = System.Diagnostics.Stopwatch.GetTimestamp();
        if (preferences.McpToastStyle == "hidden" || mcpControlID is not null || lastMCPNotice is { } previous && System.Diagnostics.Stopwatch.GetElapsedTime(previous, now).TotalSeconds < 30)
            return;
        lastMCPNotice = now;
        ShowMCPNotice("AI 正在读取这台电脑", "通过 ShareMouse 的 AI 接口读取本机信息。");
    }
    public void MCPControl(bool active, string reason)
    {
        if (mcpNoticeID is { } notice)
        {
            custom.Hide(notice);
            mcpNoticeID = null;
        }
        if (active)
        {
            mcpControlID ??= Guid.NewGuid().ToString("D");
            RefreshMCPPresentation();
            return;
        }
        if (mcpControlID is { } old)
        {
            custom.Hide(old);
            mcpControlID = null;
        }
        if (reason != "server_stopped")
        {
            var message = reason switch
            {
                "user_exit" => "你已退出 MCP 接管，本机输入已恢复",
                "lease_expired" => "控制会话空闲到期，已恢复键鼠共享",
                "peer_disconnected" => "远端设备已断开",
                "screen_changed" => "屏幕配置已变化",
                "computer_access_disabled" => "电脑操控权限已关闭",
                "input_permission_or_desktop_unavailable" => "输入权限丢失或桌面已锁定",
                "capture_failed" => "截图未能完成",
                "closed" => "AI 已释放电脑控制",
                _ => "控制会话已结束"
            };
            ShowMCPNotice("AI 已结束控制", message);
        }
    }
    private sealed record Sample(long Bytes, long Time, string State, double Rate = 0);
    private readonly Dictionary<string, Sample> samples = new();
    private readonly Dictionary<string, long> shownAt = new();
    private readonly Dictionary<string, string> restoredStates = new();
    public void RestoreTransfers(TransferTask[] tasks)
    {
        latest = tasks;
        restoredStates.Clear();
        foreach (var task in tasks)
            restoredStates[task.Id] = task.State;
    }
    private TransferTask[] latest = [];
    private readonly DispatcherTimer ticker = new() { Interval = TimeSpan.FromSeconds(1) };
    public void Transfers(TransferTask[] tasks)
    {
        latest = tasks;
        RefreshTransfers();
        if (tasks.Any(t => t.State == "running"))
            ticker.Start();
        else
            ticker.Stop();
    }
    private void RefreshTransfers()
    {
        custom.Corner = preferences.Corner;
        foreach (var task in latest)
        {
            if (restoredStates.TryGetValue(task.Id, out var restored))
            {
                if (task.State == restored)
                    continue;
                restoredStates.Remove(task.Id);
            }
            var active = task.State is "running" or "queued" or "paused";
            if (!signatures.ContainsKey(task.Id) && !active)
                continue;
            var now = System.Diagnostics.Stopwatch.GetTimestamp();
            var sample = samples.GetValueOrDefault(task.Id) ?? new(task.Received, now, task.State);
            if (task.State != "running" || sample.State != "running" || task.Received < sample.Bytes)
                sample = new(task.Received, now, task.State);
            else
            {
                var elapsed = System.Diagnostics.Stopwatch.GetElapsedTime(sample.Time, now).TotalSeconds;
                if (elapsed >= 1)
                    sample = new(task.Received, now, task.State, Math.Max(0, task.Received - sample.Bytes) / elapsed);
            }
            samples[task.Id] = sample;
            var state = task.State switch
            {
                "running" => "正在传输",
                "queued" => "排队中",
                "paused" => "已暂停",
                "completed" => "已完成",
                "failed" => "传输失败",
                "cancelled" => "已取消",
                _ => task.State
            };
            var title = (task.Direction == "send" ? "发送文件" : "接收文件") + " · " + state;
            var current = task.Files.FirstOrDefault(f => !f.Item.Directory && !f.Completed && !f.Skipped) ?? task.Files.FirstOrDefault(f => f.Item.Id == f.Item.RootID);
            var name = current is null ? "正在获取文件清单…" : System.IO.Path.GetFileName(current.Item.RelativePath.Replace('/', System.IO.Path.DirectorySeparatorChar));
            var percent = Math.Clamp((int)((double)task.Received / Math.Max(1, task.Total) * 100), 0, 100);
            var transport = task.Transport switch
            {
                "tcp" => "网络 TCP",
                "quic" => "网络 QUIC",
                "ble" => "蓝牙 BLE",
                _ => "等待链路"
            };
            var message = name + "\n" + Bytes(task.Received) + " / " + Bytes(task.Total) + $" · {percent}%\n" + Bytes(sample.Rate) + "/s · " + transport + (task.Error is null ? "" : "\n" + task.Error);
            var signature = task.State + ":" + message;
            if (signatures.GetValueOrDefault(task.Id) == signature)
                continue;
            if (signatures.GetValueOrDefault(task.Id)?.StartsWith(task.State + ":", StringComparison.Ordinal) == true && shownAt.TryGetValue(task.Id, out var shown) && System.Diagnostics.Stopwatch.GetElapsedTime(shown, now).TotalSeconds < 1)
                continue;
            signatures[task.Id] = signature;
            shownAt[task.Id] = now;
            try
            {
                Renderer.Show(task.Id, title, message, active ? percent / 100.0 : null, active);
            }
            catch { custom.Show(task.Id, title, message, active ? percent / 100.0 : null, active); }
        }
    }
    private static string Bytes(double value) => value >= 1_000_000_000 ? $"{value / 1_000_000_000:F1} GB" : value >= 1_000_000 ? $"{value / 1_000_000:F1} MB" : value >= 1_000 ? $"{value / 1_000:F1} KB" : $"{value:F0} B";
    public void Dispose()
    {
        foreach (var timer in linkTimers.Values)
            timer.Stop();
        linkTimers.Clear();
        pendingLinks.Clear();
        ticker.Stop();
        native.Stop();
        custom.Stop();
    }
}
