using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ShareMouse;

// ASUS 5A:C4/C5 are incoming hotkeys, not a SendInput VK or an output command.
// Backlight execution uses the device's 5A feature protocol, restricted to 0B05:19B6.
internal static class WindowsAsusKeyboard
{
    internal static byte[] BrightnessReport(int level, int length)
    {
        if (level is < 0 or > 3 || length is < 5 or > 1024)
            throw new ArgumentOutOfRangeException();
        var report = new byte[length];
        report[0] = 0x5a;
        report[1] = 0xba;
        report[2] = 0xc5;
        report[3] = 0xc4;
        report[4] = (byte)level;
        return report;
    }
    internal static int NextBrightness(int? current, int direction) => current is { } level ? Math.Clamp(level + direction, 0, 3) : direction > 0 ? 3 : 0;
    internal static int FeatureLength(string path, byte reportId = 0x5a)
    {
        using var handle = Open(path);
        return handle.IsInvalid ? 0 : ReportLength(handle, reportId, 2);
    }
    internal static int OutputLength(string path, byte reportId = 0x5d)
    {
        using var handle = Open(path);
        return handle.IsInvalid ? 0 : ReportLength(handle, reportId, 1);
    }
    private static SafeFileHandle Open(string path)
    {
        if (!path.Contains("VID_0B05&PID_19B6", StringComparison.OrdinalIgnoreCase))
            throw new NotSupportedException("Unknown ASUS keyboard");
        return CreateFileW(path, 0xc0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    }
    private static int ReportLength(SafeFileHandle handle, byte reportId, int reportType)
    {
        if (!HidD_GetPreparsedData(handle, out var preparsed))
            return 0;
        var caps = Marshal.AllocHGlobal(64);
        try
        {
            if (HidP_GetCaps(preparsed, caps) != 0x00110000)
                return 0;
            var length = (ushort)Marshal.ReadInt16(caps, reportType == 2 ? 8 : 6);
            if (length is < 5 or > 1024)
                return 0;
            // Check report 5A in the feature descriptor rather than trying writes on every HID collection.
            foreach (var button in new[] { false, true })
            {
                ushort count = (ushort)Marshal.ReadInt16(caps, reportType == 2 ? (button ? 58 : 60) : (button ? 52 : 54));
                if (count is 0 or > 64)
                    continue;
                var values = Marshal.AllocHGlobal(count * 72);
                try
                {
                    var code = button ? HidP_GetButtonCaps(reportType, values, ref count, preparsed) : HidP_GetValueCaps(reportType, values, ref count, preparsed);
                    if (code != 0x00110000)
                        continue;
                    for (var i = 0; i < count; i++)
                        if (Marshal.ReadByte(values, i * 72 + 2) == reportId)
                            return length;
                }
                finally { Marshal.FreeHGlobal(values); }
            }
            return 0;
        }
        finally { Marshal.FreeHGlobal(caps); HidD_FreePreparsedData(preparsed); }
    }
    internal static bool SetBrightness(string[] paths, int level, out int error)
    {
        return SendFeature(paths, BrightnessReport(level, 5), out error);
    }
    internal static bool ToggleTouchpad(string[] paths, out int error) => SendFeature(paths, [0x5a, 0xf4, 0x6b], out error);
    internal static byte[] AuraReport(int mode, int length)
    {
        if (mode is < 0 or > 3 || length is < 17 or > 1024)
            throw new ArgumentOutOfRangeException();
        var data = new byte[length];
        data[0] = 0x5d;
        data[1] = 0xb3;
        data[3] = (byte)mode;
        data[4] = data[5] = data[6] = 0xff;
        data[7] = 0xeb;
        data[9] = (byte)(mode == 1 ? 1 : 0);
        return data;
    }
    internal static bool SetAura(string[] paths, int mode, out int error)
    {
        error = 0;
        foreach (var path in paths)
        {
            using var handle = Open(path);
            if (handle.IsInvalid)
            {
                error = Marshal.GetLastWin32Error();
                continue;
            }
            var length = ReportLength(handle, 0x5d, 1);
            if (length < 17)
                continue;
            var set = new byte[length];
            set[0] = 0x5d;
            set[1] = 0xb5;
            var apply = new byte[length];
            apply[0] = 0x5d;
            apply[1] = 0xb4;
            var complete = true;
            foreach (var report in new[] { AuraReport(mode, length), set, apply })
            {
                if (!WriteFile(handle, report, (uint)report.Length, out var sent, IntPtr.Zero) || sent != report.Length)
                {
                    error = Marshal.GetLastWin32Error();
                    complete = false;
                    break;
                }
            }
            if (complete)
                return true;
        }
        return false;
    }
    private static bool SendFeature(string[] paths, byte[] payload, out int error)
    {
        error = 0;
        foreach (var path in paths)
        {
            using var handle = Open(path);
            if (handle.IsInvalid)
            {
                error = Marshal.GetLastWin32Error();
                continue;
            }
            var length = ReportLength(handle, 0x5a, 2);
            if (length == 0)
                continue;
            var report = new byte[length];
            Array.Copy(payload, report, payload.Length);
            if (HidD_SetFeature(handle, report, report.Length))
                return true;
            error = Marshal.GetLastWin32Error();
        }
        return false;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool WriteFile(SafeFileHandle handle, byte[] data, uint length, out uint sent, IntPtr overlapped);
    [DllImport("hid.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.U1)] private static extern bool HidD_SetFeature(SafeFileHandle handle, byte[] report, int length);
    [DllImport("hid.dll")][return: MarshalAs(UnmanagedType.U1)] private static extern bool HidD_GetPreparsedData(SafeFileHandle handle, out IntPtr data);
    [DllImport("hid.dll")][return: MarshalAs(UnmanagedType.U1)] private static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] private static extern int HidP_GetCaps(IntPtr data, IntPtr caps);
    [DllImport("hid.dll")] private static extern int HidP_GetValueCaps(int type, IntPtr caps, ref ushort count, IntPtr data);
    [DllImport("hid.dll")] private static extern int HidP_GetButtonCaps(int type, IntPtr caps, ref ushort count, IntPtr data);
}
