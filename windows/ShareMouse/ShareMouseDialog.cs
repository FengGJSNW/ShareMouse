using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using System.Collections.Generic;
using System.Threading.Tasks;
namespace ShareMouse;

public sealed class ShareMouseDialog : Window
{
    private string result = "cancel";
    private bool asynchronous;
    private static readonly Dictionary<string, ShareMouseDialog> connections = new();
    public static void CompleteConnection(string peerID)
    {
        if (connections.TryGetValue(peerID, out var dialog))
        {
            dialog.result = "allow";
            dialog.Close();
        }
    }
    private static readonly Dictionary<string, Task<string>> decisions = new();
    public static Task<string> ChooseConnectionAsync(Window owner, string peerID, string title, string message, (string value, string label)[] choices)
    {
        if (decisions.TryGetValue(peerID, out var pending))
            return pending;
        var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        decisions[peerID] = completion.Task;
        var dialog = new ShareMouseDialog(title, message, choices, false, true) { Owner = owner };
        connections[peerID] = dialog;
        dialog.Closed += (_, _) => { connections.Remove(peerID); decisions.Remove(peerID); completion.TrySetResult(dialog.result); };
        dialog.Show();
        return completion.Task;
    }
    public static string Choose(Window owner, string title, string message, (string value, string label)[] choices, bool destructive = false)
    {
        var dialog = new ShareMouseDialog(title, message, choices, destructive) { Owner = owner };
        dialog.ShowDialog();
        return dialog.result;
    }
    public static Task<string> ChooseAsync(string title, string message, (string value, string label)[] choices, bool destructive = false, bool applyToRemaining = false)
    {
        var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var dialog = new ShareMouseDialog(title, message, choices, destructive, true, applyToRemaining) { ShowInTaskbar = false, Topmost = true, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        dialog.Closed += (_, _) => completion.TrySetResult(dialog.result);
        dialog.Show();
        return completion.Task;
    }
    private ShareMouseDialog(string title, string message, (string value, string label)[] choices, bool destructive, bool asynchronous = false, bool applyToRemaining = false)
    {
        this.asynchronous = asynchronous;
        if (asynchronous)
            PreviewKeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) { e.Handled = true; Close(); } };
        Title = "ShareMouse";
        Width = 540;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var body = new StackPanel { Margin = new Thickness(26) };
        Background = Theme.Brush("Canvas");
        Content = new Border { Background = Theme.Brush("Surface"), BorderBrush = Theme.Brush("Border"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Margin = new Thickness(12), Child = body };
        body.Children.Add(new TextBlock { Text = title, FontSize = 21, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 16) });
        body.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxHeight = 350 });
        var applyAll = new CheckBox { Content = "对后续文件执行相同操作", Margin = new Thickness(0, 16, 0, 0) };
        if (applyToRemaining)
            body.Children.Add(applyAll);
        var buttons = new WrapPanel { Margin = new Thickness(0, 24, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
        body.Children.Add(buttons);
        foreach (var choice in choices)
        {
            var button = new Button { Content = choice.label, Padding = new Thickness(14, 8, 14, 8), Margin = new Thickness(5), IsCancel = choice.value == "cancel" };
            button.Click += (_, _) => { result = choice.value + (applyToRemaining && applyAll.IsChecked == true && choice.value != "cancel" ? ":all" : ""); if (asynchronous) Close(); else DialogResult = true; };
            if (asynchronous)
                button.IsCancel = false;
            buttons.Children.Add(button);
            if (destructive && choice.value == "deleteAll")
            {
                button.Foreground = Theme.Brush("Danger");
                var left = 3;
                button.IsEnabled = false;
                button.Content = $"{choice.label} ({left})";
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
                timer.Tick += (_, _) => { left--; button.Content = left > 0 ? $"{choice.label} ({left})" : choice.label; if (left == 0) { button.IsEnabled = true; timer.Stop(); } };
                Closed += (_, _) => timer.Stop();
                timer.Start();
            }
        }
    }
}
