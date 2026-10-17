using System.ComponentModel;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace ShareMouse;

// SendInput can wait for a low-level hook installed on the calling UI thread.
// Keep that thread able to answer sent hook messages until the native call finishes.
// Posted WPF work, input packets and timers are not dispatched inside this wait.
internal static class WindowsInputPump
{
    [System.ThreadStatic] private static int sendingDepth;
    internal static bool IsSending => sendingDepth != 0;
    public static (uint Count, int Error) Send(System.Func<uint> nativeSend)
    {
        sendingDepth++;
        try
        {
            return SendCore(nativeSend);
        }
        finally { sendingDepth--; }
    }
    private static (uint Count, int Error) SendCore(System.Func<uint> nativeSend)
    {
        using var completed = new ManualResetEvent(false);
        uint count = 0;
        int error = 0;
        ExceptionDispatchInfo? failure = null;
        _ = Task.Run(() =>
        {
            try
            {
                count = nativeSend();
                error = Marshal.GetLastPInvokeError();
            }
            catch (System.Exception exception) { failure = ExceptionDispatchInfo.Capture(exception); }
            finally { completed.Set(); }
        });
        var handles = new[] { completed.SafeWaitHandle.DangerousGetHandle() };
        while (true)
        {
            var result = MsgWaitForMultipleObjectsEx(1, handles, uint.MaxValue, 0x40, 4); // QS_SENDMESSAGE, MWMO_INPUTAVAILABLE
            if (result == 0)
                break;
            if (result == 1)
                _ = PeekMessageW(out _, System.IntPtr.Zero, 0, 0, 0x00400000); // PM_NOREMOVE | PM_QS_SENDMESSAGE
            else if (result == uint.MaxValue)
            {
                // Do not return while native input may still be running on the worker.
                var waitError = Marshal.GetLastPInvokeError();
                _ = WaitForSingleObject(handles[0], uint.MaxValue);
                throw new Win32Exception(waitError);
            }
        }
        Thread.MemoryBarrier();
        failure?.Throw();
        return (count, error);
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Message
    {
        public System.IntPtr Window; public uint ID; public System.UIntPtr WParam; public System.IntPtr LParam; public uint Time; public int X, Y; public uint Private;
    }
    [DllImport("user32.dll", SetLastError = true)] private static extern uint MsgWaitForMultipleObjectsEx(uint count, System.IntPtr[] handles, uint milliseconds, uint wakeMask, uint flags);
    [DllImport("user32.dll")] private static extern bool PeekMessageW(out Message message, System.IntPtr window, uint first, uint last, uint remove);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(System.IntPtr handle, uint milliseconds);
}
