using System.Diagnostics;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using ShareMouse;

internal static class NativeClickRegression
{
    public static void Run(bool legacy = false)
    {
        _ = SetProcessDpiAwarenessContext(new IntPtr(-4));
        ExceptionDispatchInfo? failure = null;
        var thread = new Thread(() => { try { foreach (var button in legacy ? new[] { 8 } : new[] { 8, 20, 8, 20 }) Check(legacy, button); } catch (Exception e) { failure = ExceptionDispatchInfo.Capture(e); } }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(12000))
            throw new Exception("Caption click regression exceeded 12 seconds");
        failure?.Throw();
    }
    private static void Check(bool legacy, int captionButton)
    {
        var previous = GetForegroundWindow();
        GetCursorPos(out var cursor);
        var dispatcher = Dispatcher.CurrentDispatcher;
        using var nativeContext = new WindowsInputContext();
        SynchronizationContext context = legacy ? new DispatcherSynchronizationContext(dispatcher, DispatcherPriority.Send) : nativeContext;
        SynchronizationContext.SetSynchronizationContext(context);
        var window = new Window { Title = "ShareMouse caption click regression", Width = 360, Height = 180, Left = 300, Top = 300, ShowInTaskbar = false };
        System.ComponentModel.CancelEventHandler hide = (_, e) => { e.Cancel = true; window.Hide(); };
        if (captionButton == 20)
            window.Closing += hide;
        window.Show();
        var handle = new WindowInteropHelper(window).Handle;
        HwndSource.FromHwnd(handle)?.AddHook((IntPtr h, int message, IntPtr wp, IntPtr lp, ref bool handled) => { if (message == 0xa1) Console.WriteLine($"caption down hit={wp} position=0x{lp.ToInt64():X}"); return IntPtr.Zero; });
        Hook callback = (code, msg, data) => CallNextHookEx(IntPtr.Zero, code, msg, data);
        var hook = SetWindowsHookExW(14, callback, GetModuleHandleW(null), 0);
        if (hook == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
        var frame = new DispatcherFrame();
        var released = false;
        var completed = false;
        var failed = false;
        var ticks = 0;
        long pressedAt = 0;
        double releaseMs = 0;
        var timer = new DispatcherTimer(DispatcherPriority.Send) { Interval = TimeSpan.FromMilliseconds(20) };
        timer.Tick += (_, _) => ticks++;
        timer.Start();
        var watch = Stopwatch.StartNew();
        var timeout = Task.Run(async () =>
        {
            await Task.Delay(2500);
            if (completed)
                return;
            failed = true;
            // Rescue only this fixture's held button; no lingering native work.
            SendInput(1, [new Input { Mouse = new Mouse { Flags = 4, Extra = new(0x534d494e) } }], Marshal.SizeOf<Input>());
            context.Post(_ => frame.Continue = false, null);
        });
        try
        {
            var ready = new DispatcherFrame();
            _ = Task.Run(async () => { await Task.Delay(250); _ = dispatcher.BeginInvoke(() => ready.Continue = false); });
            Dispatcher.PushFrame(ready);
            SetForegroundWindow(handle);
            GetWindowRect(handle, out var bounds);
            if (DwmGetWindowAttribute(handle, 5, out var caption, Marshal.SizeOf<Rect>()) != 0 || caption.Right <= caption.Left)
                throw new Exception("Fixture caption button bounds unavailable");
            var hitX = bounds.Left + caption.Left + (caption.Right - caption.Left) * (captionButton == 8 ? 1 : 5) / 6;
            var hitY = bounds.Top + (caption.Top + caption.Bottom) / 2;
            var move = WindowsInputPump.Send(() => SendInput(1, [new Input { Mouse = new Mouse { X = (int)((hitX - GetSystemMetrics(76)) * 65535.0 / Math.Max(1, GetSystemMetrics(78) - 1)), Y = (int)((hitY - GetSystemMetrics(77)) * 65535.0 / Math.Max(1, GetSystemMetrics(79) - 1)), Flags = 0x8000 | 0x4000 | 1, Extra = new(0x534d494e) } }], Marshal.SizeOf<Input>()));
            if (move.Count != 1)
                throw new System.ComponentModel.Win32Exception(move.Error);
            GetCursorPos(out var actual);
            Console.WriteLine($"fixture bounds={bounds.Left},{bounds.Top},{bounds.Right},{bounds.Bottom} requested={hitX},{hitY} actual={actual.X},{actual.Y} hit={SendMessageW(handle, 0x84, IntPtr.Zero, new IntPtr((actual.Y << 16) | (actual.X & 0xffff)))} metrics={GetSystemMetrics(76)},{GetSystemMetrics(77)},{GetSystemMetrics(78)},{GetSystemMetrics(79)}");
            context.Post(_ =>
            {
                pressedAt = Stopwatch.GetTimestamp();
                var result = WindowsInputPump.Send(() => SendInput(1, [new Input { Mouse = new Mouse { Flags = 2, Extra = new(0x534d494e) } }], Marshal.SizeOf<Input>()));
                if (result.Count != 1)
                    throw new System.ComponentModel.Win32Exception(result.Error);
                _ = Task.Run(async () =>
                {
                    await Task.Delay(60);
                    context.Post(_ =>
                    {
                        var up = WindowsInputPump.Send(() => SendInput(1, [new Input { Mouse = new Mouse { Flags = 4, Extra = new(0x534d494e) } }], Marshal.SizeOf<Input>()));
                        released = up.Count == 1;
                        releaseMs = Stopwatch.GetElapsedTime(pressedAt).TotalMilliseconds;
                        _ = Task.Run(async () => { await Task.Delay(200); context.Post(_ => { completed = true; frame.Continue = false; }, null); });
                    }, null);
                });
            }, null);
            Dispatcher.PushFrame(frame);
            var activated = captionButton == 8 ? window.WindowState == WindowState.Minimized : !window.IsVisible;
            if (failed || !released || !activated || releaseMs >= 300)
                throw new Exception($"Caption click failed: legacy={legacy} button={captionButton} rescue={failed} released={released} state={window.WindowState} visible={window.IsVisible} ticks={ticks} releaseMs={releaseMs:F1} elapsedMs={watch.ElapsedMilliseconds}");
            Console.WriteLine($"PASS caption {(captionButton == 8 ? "minimize" : "close-to-hide")} click: released={released} ticks={ticks} releaseMs={releaseMs:F1} elapsedMs={watch.ElapsedMilliseconds}");
        }
        finally
        {
            completed = true;
            timer.Stop();
            UnhookWindowsHookEx(hook);
            window.Closing -= hide;
            window.Close();
            SetCursorPos(cursor.X, cursor.Y);
            if (previous != IntPtr.Zero)
                SetForegroundWindow(previous);
            GC.KeepAlive(callback);
        }
    }
    private delegate IntPtr Hook(int code, IntPtr message, IntPtr data);
    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X, Y;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Mouse
    {
        public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type; public Mouse Mouse;
    }
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr handle, out Rect rect);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr handle);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookExW(int hook, Hook callback, IntPtr module, uint thread);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string? module);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect value, int size);
}
