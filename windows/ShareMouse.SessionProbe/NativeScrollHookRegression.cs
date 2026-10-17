using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using System.Windows.Interop;
using ShareMouse;

internal static class NativeScrollHookRegression
{
    public static void Run(bool legacy = false)
    {
        ExceptionDispatchInfo? failure = null;
        var thread = new Thread(() => { try { Check(legacy); } catch (Exception e) { failure = ExceptionDispatchInfo.Capture(e); } }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(15000))
            throw new Exception("Native hook regression exceeded 15 seconds");
        failure?.Throw();
    }
    private static void Check(bool legacy)
    {
        _ = PeekMessageW(out _, IntPtr.Zero, 0, 0, 0);
        var dispatcher = Dispatcher.CurrentDispatcher;
        var hooks = 0;
        var posted = false;
        var sent = 0;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher, DispatcherPriority.Send));
        using var window = new HwndSource(new HwndSourceParameters("ShareMouse native sent-message regression") { WindowStyle = 0, Width = 1, Height = 1 });
        var windowHandle = window.Handle;
        window.AddHook((IntPtr handle, int message, IntPtr wp, IntPtr lp, ref bool handled) => { if (message == 0x8001) { sent++; handled = true; return new IntPtr(1); } return IntPtr.Zero; });
        Hook callback = (code, message, data) => { if (code >= 0 && Marshal.PtrToStructure<MouseHook>(data).Extra == new UIntPtr(0x534d494e)) hooks++; return CallNextHookEx(IntPtr.Zero, code, message, data); };
        var hook = SetWindowsHookExW(14, callback, GetModuleHandleW(null), 0);
        if (hook == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastPInvokeError());
        try
        {
            // Zero wheel quantity exercises real SendInput/WH_MOUSE_LL without scrolling
            // the user's foreground application or moving the physical pointer.
            var zero = new NativeInput { Mouse = new MouseInput { Flags = 0x800, Extra = new UIntPtr(0x534d494e) } };
            dispatcher.BeginInvoke(() => posted = true);
            var maximum = 0.0;
            for (var i = 0; i < 20; i++)
            {
                var started = Stopwatch.GetTimestamp();
                var result = legacy ? (SendInput(1, [zero], Marshal.SizeOf<NativeInput>()), Marshal.GetLastPInvokeError()) : WindowsInputPump.Send(() => SendInput(1, [zero], Marshal.SizeOf<NativeInput>()));
                if (result.Item1 != 1)
                    throw new Win32Exception(result.Item2);
                maximum = Math.Max(maximum, Stopwatch.GetElapsedTime(started).TotalMilliseconds);
                if (posted)
                    throw new Exception("Native wait dispatched queued WPF business work reentrantly");
            }
            if (legacy)
            {
                Console.WriteLine($"BASELINE: direct SendInput callbacks={hooks}/20 max={maximum:F2}ms");
                return;
            }
            if (maximum >= 150)
                throw new Exception($"Native send still waited near the hook timeout: {maximum:F1}ms");
            // Windows drops zero-quantity wheel events before WH_MOUSE_LL. Separately
            // prove that the waiting thread services native sent callbacks, without
            // synthesizing a real wheel movement in the user's application.
            for (var i = 0; i < 20; i++)
            {
                var result = WindowsInputPump.Send(() => SendMessageTimeoutW(windowHandle, 0x8001, IntPtr.Zero, IntPtr.Zero, 3, 100, out var response) != IntPtr.Zero ? (uint)response.ToUInt64() : 0);
                if (result.Count != 1)
                    throw new Exception("Native sent callback timed out while UI waited for the worker");
                if (posted)
                    throw new Exception("Sent callback dispatched queued WPF business work reentrantly");
            }
            if (sent != 20)
                throw new Exception("Sent native callbacks were lost");
            using var inputContext = new WindowsInputContext();
            var inputDispatched = false;
            _ = WindowsInputPump.Send(() =>
            {
                inputContext.Post(_ => inputDispatched = true, null);
                Thread.Sleep(25);
                return SendMessageTimeoutW(windowHandle, 0x8001, IntPtr.Zero, IntPtr.Zero, 3, 100, out var response) != IntPtr.Zero ? (uint)response.ToUInt64() : 0;
            });
            if (inputDispatched)
                throw new Exception("Native input context reentered an unfinished injection");
            var propagated = false;
            try
            {
                WindowsInputPump.Send(() => throw new IOException("native-fixture"));
            }
            catch (IOException e) when (e.Message == "native-fixture") { propagated = true; }
            if (!propagated)
                throw new Exception("Native failure was swallowed");
            var frame = new DispatcherFrame();
            _ = Task.Run(async () => { await Task.Delay(50); _ = dispatcher.BeginInvoke(() => frame.Continue = false); });
            Dispatcher.PushFrame(frame);
            if (!posted)
                throw new Exception("Queued WPF work was lost");
            if (!inputDispatched)
                throw new Exception("Deferred native input work was lost");
            Console.WriteLine($"PASS: 20 real zero-wheel SendInput returns (hook callbacks={hooks}, max={maximum:F2}ms), 20 native sent callbacks; no queued WPF work reentered; native errors propagated.");
        }
        finally { UnhookWindowsHookEx(hook); GC.KeepAlive(callback); }
    }
    private delegate IntPtr Hook(int code, IntPtr message, IntPtr data);
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInput
    {
        public uint Type; public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseHook
    {
        public int X, Y; public uint MouseData, Flags, Time; public UIntPtr Extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Message
    {
        public IntPtr Window; public uint ID; public UIntPtr WParam; public IntPtr LParam; public uint Time; public int X, Y; public uint Private;
    }
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookExW(int hook, Hook callback, IntPtr module, uint thread);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string? module);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, NativeInput[] inputs, int size);
    [DllImport("user32.dll")] private static extern bool PeekMessageW(out Message message, IntPtr window, uint first, uint last, uint remove);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
}
