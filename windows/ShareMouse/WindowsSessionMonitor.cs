using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace ShareMouse;

internal sealed class WindowsSessionMonitor : IDisposable
{
    private readonly HwndSource source;
    private IntPtr powerNotification;
    private readonly bool sessionRegistered;
    private bool disposed;
    internal bool? LidClosed { get; private set; }
    internal bool ScreenLocked { get; private set; }
    internal Action? Changed { get; set; }
    private static readonly Guid LidSetting = new("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
    internal WindowsSessionMonitor(HwndSource source, Action<string> log)
    {
        this.source = source;
        source.AddHook(Message);
        var setting = LidSetting;
        powerNotification = RegisterPowerSettingNotification(source.Handle, ref setting, 0);
        sessionRegistered = WTSRegisterSessionNotification(source.Handle, 0);
        RefreshSession();
        log($"InputSessionMonitor powerRegistered={powerNotification != IntPtr.Zero} sessionRegistered={sessionRegistered} locked={ScreenLocked}");
    }
    private void RefreshSession()
    {
        var state = WindowsComputerAdapter.DesktopSession();
        if (state.locked is not null && state.active is not null)
            ScreenLocked = state.locked == true || state.active == false;
    }
    private IntPtr Message(IntPtr window, int message, IntPtr wp, IntPtr lp, ref bool handled)
    {
        if (disposed) return IntPtr.Zero;
        var lid = LidClosed; var locked = ScreenLocked;
        if (message == 0x02B1) // WM_WTSSESSION_CHANGE, registered for this session only.
        {
            if (wp.ToInt32() == 7) ScreenLocked = true;
            else if (wp.ToInt32() == 8) ScreenLocked = false;
            else RefreshSession();
        }
        else if (message == 0x0218) // WM_POWERBROADCAST
        {
            if (wp.ToInt32() == 0x8013 && lp != IntPtr.Zero
                && Marshal.PtrToStructure<Guid>(lp) == LidSetting && Marshal.ReadInt32(lp, 16) == 4)
            {
                var value = Marshal.ReadInt32(lp, 20);
                if (value is 0 or 1) LidClosed = value == 0;
            }
            else if (wp.ToInt32() is 7 or 18) RefreshSession(); // Resume.
        }
        if (lid != LidClosed || locked != ScreenLocked) Changed?.Invoke();
        return IntPtr.Zero;
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        source.RemoveHook(Message);
        if (powerNotification != IntPtr.Zero) UnregisterPowerSettingNotification(powerNotification);
        powerNotification = IntPtr.Zero;
        if (sessionRegistered) WTSUnRegisterSessionNotification(source.Handle);
    }
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterPowerSettingNotification(IntPtr handle);
    [DllImport("wtsapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WTSRegisterSessionNotification(IntPtr window, uint flags);
    [DllImport("wtsapi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WTSUnRegisterSessionNotification(IntPtr window);
}
