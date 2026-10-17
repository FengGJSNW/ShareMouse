using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using ShareMouse.Network;

namespace ShareMouse;

// Snapshot the real foreground target; SendInput success does not prove app response.
internal static class WindowsInputStatus
{
    public static bool IsElevated => Integrity(Environment.ProcessId) >= 0x3000;
    public static JsonObject Capture()
    {
        var window = GetForegroundWindow();
        GetWindowThreadProcessId(window, out var processId);
        var title = new StringBuilder(512);
        GetWindowTextW(window, title, title.Capacity);
        GetWindowRect(window, out var bounds);
        GetPhysicalCursorPos(out var cursor);
        var controller = Integrity(Environment.ProcessId);
        var target = Integrity((int)processId);
        string? processName = null;
        try
        {
            using var process = Process.GetProcessById((int)processId);
            processName = process.ProcessName;
        }
        catch (Exception ex) when (ex is ArgumentException or System.ComponentModel.Win32Exception or InvalidOperationException) { }
        return ComputerUseService.Obj(("controller_integrity", Level(controller)), ("foreground_integrity", Level(target)),
            ("input_injection_blocked", controller >= 0 && target > controller),
            ("foreground_window", ComputerUseService.Obj(("window_id", window == IntPtr.Zero ? null : "win:" + processId + ":" + window.ToInt64().ToString("X")), ("process_id", processId), ("process_name", processName), ("title", title.ToString()), ("left", bounds.Left), ("top", bounds.Top), ("right", bounds.Right), ("bottom", bounds.Bottom))),
            ("cursor_position", ComputerUseService.Obj(("x", cursor.X), ("y", cursor.Y), ("coordinate_space", "desktop_pixels"))));
    }
    private static readonly int controllerLevel = Integrity(Environment.ProcessId);
    private static uint cachedTargetPid; private static int cachedTargetLevel = -1; private static long cachedTargetAt;
    public static void EnsureCanInject()
    {
        GetWindowThreadProcessId(GetForegroundWindow(), out var processId);
        var now = Environment.TickCount64;
        if (processId != cachedTargetPid || now - cachedTargetAt >= 1000)
        {
            cachedTargetPid = processId;
            cachedTargetLevel = Integrity((int)processId);
            cachedTargetAt = now;
        }
        var controller = controllerLevel;
        var target = cachedTargetLevel;
        if (controller >= 0 && target > controller)
            throw new IOException("input_blocked_by_integrity_level:restart_ShareMouse_as_administrator");
    }
    private static string Level(int value) => value switch { < 0 => "unknown", < 0x1000 => "untrusted", < 0x2000 => "low", < 0x3000 => "medium", < 0x4000 => "high", _ => "system" };
    private static int Integrity(int processId)
    {
        var process = OpenProcess(0x1000, false, processId);
        if (process == IntPtr.Zero)
            return -1;
        IntPtr token = IntPtr.Zero, data = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(process, 8, out token))
                return -1;
            GetTokenInformation(token, 25, IntPtr.Zero, 0, out var size);
            if (size <= 0)
                return -1;
            data = Marshal.AllocHGlobal(size);
            if (!GetTokenInformation(token, 25, data, size, out _))
                return -1;
            var sid = Marshal.ReadIntPtr(data);
            var count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
            return count == 0 ? -1 : Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
        }
        finally { if (data != IntPtr.Zero) Marshal.FreeHGlobal(data); if (token != IntPtr.Zero) CloseHandle(token); CloseHandle(process); }
    }
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
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int size);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] private static extern bool GetPhysicalCursorPos(out Point point);
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("advapi32.dll")] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll")] private static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr data, int size, out int needed);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
