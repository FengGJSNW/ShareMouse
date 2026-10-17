using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ShareMouse;

internal static class WindowsAsusPerformance
{
    private const uint performance = 0x00120075;
    private static readonly object gate = new();
    private static SafeFileHandle? driver;
    private static int? lastRequestedMode;
    internal static int NextMode(int current, bool battery) => battery ? current == 2 ? 0 : 2 : current is >= 0 and <= 2 ? (current + 1) % 3 : 0;
    internal static uint ReadCapabilities()
    {
        lock (gate)
        {
            return Call(Open(), 0x53545344, performance, 0);
        }
    }
    internal static int Cycle(bool battery)
    {
        lock (gate)
        {
            var handle = Open();
            var support = Call(handle, 0x53545344, performance, 0);
            return CycleAccepted(ref lastRequestedMode, support, battery, next => Call(handle, 0x53564544, performance, (uint)next), WindowsPowerMode.Mode(WindowsPowerMode.Read()));
        }
    }
    internal static int CycleAccepted(ref int? previous, uint support, bool battery, Func<int, uint> write, int? initialPowerMode = null)
    {
        if ((support & 0x10000) == 0)
            throw new NotSupportedException("ASUS performance control unavailable");
        // DSTS is capability metadata on this device (always 0x10003), not
        // the selected profile. Reading it as a mode kept writing Balanced.
        // Start explicitly at Balanced; advance only after the driver accepts.
        var next = (previous ?? initialPowerMode) is { } mode ? NextMode(mode, battery) : 0;
        if (write(next) != 1)
            throw new InvalidOperationException("ASUS driver rejected performance mode");
        previous = next;
        return next;
    }
    private static SafeFileHandle Open()
    {
        if (driver is not null && !driver.IsInvalid && !driver.IsClosed)
            return driver;
        var handle = CreateFileW(@"\\.\ATKACPI", 0xc0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try
        {
            if (Call(handle, 0x54494e49, 0, 0) != 1)
                throw new NotSupportedException("ASUS driver initialization failed");
            driver = handle;
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }
    private static uint Call(SafeFileHandle handle, uint method, uint device, uint value)
    {
        var input = new byte[16];
        BitConverter.GetBytes(method).CopyTo(input, 0);
        BitConverter.GetBytes(8u).CopyTo(input, 4);
        BitConverter.GetBytes(device).CopyTo(input, 8);
        BitConverter.GetBytes(value).CopyTo(input, 12);
        var output = new byte[16];
        if (!DeviceIoControl(handle, 0x22240c, input, 16, output, 16, out var count, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (count < 4)
            throw new InvalidOperationException("ASUS driver returned no status");
        return BitConverter.ToUInt32(output, 0);
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputLength, byte[] output, uint outputLength, out uint returned, IntPtr overlapped);
}
