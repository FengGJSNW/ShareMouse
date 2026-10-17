using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using ShareMouse;

internal static class ClipboardReaderRegression
{
    internal static async Task Run()
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "ShareMouse.SessionProbe.exe");
        var normal = await WindowsClipboardReader.ReadAsync(42, CancellationToken.None, executable);
        if (normal.Content?.Kind != "text" || Encoding.UTF8.GetString(normal.Content.Data) != "clipboard-qa🙂")
            throw new Exception("Materialized content lost");
        try
        {
            await WindowsClipboardReader.ReadAsync(43, CancellationToken.None, executable);
            throw new Exception("Stale read accepted");
        }
        catch (IOException error) when (error.Message.Contains("changed", StringComparison.Ordinal)) { }
        using var context = new FixtureInputContext();
        var beats = 0;
        var childId = 0;
        var watch = Stopwatch.StartNew();
        using var heartbeat = new System.Threading.Timer(_ => context.Post(_ => beats++, null), null, 0, 20);
        try
        {
            await context.Invoke(() => WindowsClipboardReader.ReadAsync(42, CancellationToken.None, executable,
                WindowsClipboardReader.HelperArgument + " --blocked-fixture", 500, id => childId = id));
            throw new Exception("Blocked clipboard owner was not stopped");
        }
        catch (TimeoutException) { }
        if (watch.Elapsed.TotalSeconds > 4 || context.Invoke(() => beats) < 5)
            throw new Exception("Clipboard read blocked input context");
        AssertStopped(childId);
        using var cancel = new CancellationTokenSource(200);
        childId = 0;
        try
        {
            await WindowsClipboardReader.ReadAsync(42, cancel.Token, executable, WindowsClipboardReader.HelperArgument + " --blocked-fixture", 2000, id => childId = id);
            throw new Exception("Cancelled read continued");
        }
        catch (OperationCanceledException) { }
        AssertStopped(childId);
        CheckConflictDialog();
        Console.WriteLine("PASS: blocked clipboard provider cannot block input context; helper timeout/cancellation leave no child; materialized UTF8 and stale sequence checks; actual conflict checkbox and apply-all result");
    }
    private static void AssertStopped(int id)
    {
        if (id == 0)
            throw new Exception("Helper did not start");
        try
        {
            using var process = Process.GetProcessById(id);
            if (!process.HasExited)
                throw new Exception("Clipboard helper still running");
        }
        catch (ArgumentException) { }
    }
    private static void CheckConflictDialog()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                var constructor = typeof(ShareMouseDialog).GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single();
                var dialog = (ShareMouseDialog)constructor.Invoke(["目标已存在", "测试文件", new (string, string)[] { ("overwrite", "覆盖"), ("keepBoth", "保留两者"), ("skip", "跳过"), ("cancel", "取消") }, false, true, true]);
                var body = (StackPanel)dialog.Content;
                body.Measure(new Size(540, double.PositiveInfinity));
                body.Arrange(new Rect(0, 0, 540, body.DesiredSize.Height));
                var checkbox = body.Children.OfType<CheckBox>().Single();
                if ((string)checkbox.Content != "对后续文件执行相同操作" || checkbox.TransformToAncestor(body).Transform(new Point()).Y + checkbox.ActualHeight > body.ActualHeight)
                    throw new Exception("Conflict option missing/clipped");
                checkbox.IsChecked = true;
                body.Children.OfType<WrapPanel>().Single().Children.OfType<Button>().First().RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                if ((string?)typeof(ShareMouseDialog).GetField("result", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(dialog) != "overwrite:all")
                    throw new Exception("Conflict selection did not apply all");
            }
            catch (Exception error) { failure = error; }
        })
        {
            IsBackground = true
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(5000))
            throw new TimeoutException("Conflict UI regression timed out");
        if (failure is not null)
            throw failure;
    }
}
