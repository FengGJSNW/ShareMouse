using System;
using System.Collections.Concurrent;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Interop;
using System.Windows.Threading;

namespace ShareMouse;

// Caption-button tracking runs a native modal loop on the WPF thread. Posted
// Dispatcher work can wait until that loop ends, including the button-up needed
// to end it. Sent native messages remain dispatchable in that loop.
internal sealed class WindowsInputContext : SynchronizationContext, IDisposable
{
    private const int Wake = 0x8000 + 0x531;
    private readonly ConcurrentQueue<(SendOrPostCallback Callback, object? State)> pending = new();
    private readonly HwndSource source;
    private readonly IntPtr handle;
    private readonly Dispatcher dispatcher;
    private readonly Timer retry;
    private int signalled, disposed;
    private bool executing;
    public WindowsInputContext()
    {
        dispatcher = Dispatcher.CurrentDispatcher;
        source = new HwndSource(new HwndSourceParameters("ShareMouse input dispatch") { WindowStyle = 0, Width = 0, Height = 0 });
        handle = source.Handle;
        source.AddHook(Message);
        retry = new Timer(_ => Signal(), null, 5, 5);
    }
    public override void Post(SendOrPostCallback callback, object? state)
    {
        if (Volatile.Read(ref disposed) != 0)
            return;
        pending.Enqueue((callback, state));
        Signal();
    }
    private void Signal()
    {
        if (Volatile.Read(ref disposed) != 0 || pending.IsEmpty || Interlocked.Exchange(ref signalled, 1) != 0)
            return;
        // Same-thread SendNotifyMessage is synchronous: never enter application
        // input from Post itself, even when an async continuation posts on UI.
        if (dispatcher.CheckAccess())
        {
            ThreadPool.QueueUserWorkItem(_ => Notify());
            return;
        }
        Notify();
    }
    private void Notify()
    {
        if (Volatile.Read(ref disposed) != 0 || !SendNotifyMessageW(handle, Wake, IntPtr.Zero, IntPtr.Zero))
            Interlocked.Exchange(ref signalled, 0);
    }
    private IntPtr Message(IntPtr window, int message, IntPtr wp, IntPtr lp, ref bool handled)
    {
        if (message != Wake)
            return IntPtr.Zero;
        handled = true;
        Interlocked.Exchange(ref signalled, 0);
        // PeekMessage in SendInput's synchronous wait may deliver this message.
        // Do not mutate InputService while its previous injection is unfinished.
        if (executing || WindowsInputPump.IsSending || Volatile.Read(ref disposed) != 0)
            return IntPtr.Zero;
        executing = true;
        var previous = Current;
        SetSynchronizationContext(this);
        try
        {
            var began = System.Diagnostics.Stopwatch.GetTimestamp();
            for (var count = 0; count < 64 && pending.TryDequeue(out var work); count++)
            {
                try
                {
                    work.Callback(work.State);
                }
                catch (Exception error) { var failure = ExceptionDispatchInfo.Capture(error); dispatcher.BeginInvoke(() => failure.Throw()); }
                if (System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalMilliseconds >= 4)
                    break;
            }
        }
        finally { SetSynchronizationContext(previous); executing = false; Signal(); }
        return IntPtr.Zero;
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
            return;
        retry.Dispose();
        while (pending.TryDequeue(out _))
        {
        }
        source.RemoveHook(Message);
        source.Dispose();
    }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SendNotifyMessageW(IntPtr window, int message, IntPtr wp, IntPtr lp);
}
