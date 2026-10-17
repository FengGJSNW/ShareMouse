using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Threading;
using System.Threading;
using ShareMouse.Core;

namespace ShareMouse;

// Raw HID is used only for verified function-key reports, never as a second ordinary-key pipeline.
internal sealed class WindowsRawFunctionInput : IDisposable
{
    private sealed class Device
    {
        public string Name = ""; public ushort Page, Usage; public IntPtr Preparsed;
        public bool Fn, WinLockReport, HotkeyEmitted; public string? Hotkey; public HashSet<string> Consumer = []; public HashSet<string> FunctionSlots = [];
    }
    private readonly Dictionary<IntPtr, Device> devices = [];
    private readonly Dictionary<(string, bool), (uint Stamp, long At)> hooks = [];
    private readonly Dictionary<(string, bool), long> semantics = [];
    private readonly Dictionary<string, int> repeating = [];
    private readonly Dictionary<string, string> repeatSlots = [];
    public Func<string, string?, string>? RepeatTarget
    {
        get; set;
    }
    private int repeatSequence;
    private int generation;
    private readonly Func<CapturedInput, bool> capture;
    private readonly Dispatcher dispatcher;
    private readonly Action<string> diagnostic;
    private int physicalFn;
    public bool PhysicalFnDown => Volatile.Read(ref physicalFn) != 0;
    public WindowsRawFunctionInput(Func<CapturedInput, bool> capture, Dispatcher dispatcher, Action<string>? diagnostic = null)
    {
        this.capture = capture;
        this.dispatcher = dispatcher;
        this.diagnostic = diagnostic ?? (_ => { });
    }
    public bool HasAsusFunctionKeyboard
    {
        get; private set;
    }
    public string[] AsusFeaturePaths { get; private set; } = [];
    [StructLayout(LayoutKind.Sequential)]
    private struct RawDeviceEntry
    {
        public IntPtr Handle; public uint Type;
    }
    public void RefreshFunctionKeyboard()
    {
        HasAsusFunctionKeyboard = false;
        AsusFeaturePaths = [];
        var paths = new List<string>();
        uint count = 0;
        var size = (uint)Marshal.SizeOf<RawDeviceEntry>();
        if (GetRawInputDeviceList(IntPtr.Zero, ref count, size) == uint.MaxValue || count is 0 or > 256)
            return;
        var entries = Marshal.AllocHGlobal(checked((int)(count * size)));
        try
        {
            var total = GetRawInputDeviceList(entries, ref count, size);
            if (total == uint.MaxValue)
                return;
            for (var i = 0; i < total; i++)
            {
                var entry = Marshal.PtrToStructure<RawDeviceEntry>(IntPtr.Add(entries, checked((int)(i * size))));
                if (entry.Type != 2)
                    continue;
                var device = Describe(entry.Handle);
                try
                {
                    if (!device.Name.Contains("VID_0B05&PID_19B6", StringComparison.OrdinalIgnoreCase))
                        continue;
                    paths.Add(device.Name);
                    if (device.Name.Contains("&Col04", StringComparison.OrdinalIgnoreCase) && device.Page == 0xff31 && device.Usage == 0x79)
                        HasAsusFunctionKeyboard = true;
                }
                finally { if (device.Preparsed != IntPtr.Zero) Marshal.FreeHGlobal(device.Preparsed); }
            }
            AsusFeaturePaths = paths.ToArray();
        }
        finally { Marshal.FreeHGlobal(entries); }
    }
    // This row was verified from this ASUS keyboard's reports and photo, not a Windows-wide convention.
    public string? FunctionKey(string slot) => HasAsusFunctionKeyboard ? AsusFunctionKey(slot) : null;
    internal static string? AsusFunctionKey(string slot) => KeyboardMapping.WindowsFunction(slot);
    public void Hook(string key, bool down, uint stamp)
    {
        hooks[(key, down)] = (stamp, Environment.TickCount64);
        RememberSemantic(key, down);
    }
    public bool UsesFunctionRow(string key) => HasAsusFunctionKeyboard && PhysicalFnDown &&
        (KeyboardMapping.WindowsFunctions.Values.Contains(key) || KeyboardMapping.WindowsFunctions.ContainsKey(key));
    private static readonly (int Byte, int Mask)[] rowBits = [(4, 0x80), (5, 1), (5, 2), (5, 4), (5, 0x10), (5, 0x20), (5, 0x40), (5, 0x80), (6, 2), (6, 4), (6, 8), (6, 0x10)];
    // Only call after descriptor, vendor, collection, report ID and length checks.
    internal static string[] DecodeFunctionRow(byte[] report) => rowBits.Select((bit, i) => (bit, i)).Where(p => (report[p.bit.Byte] & p.bit.Mask) != 0).Select(p => "F" + (p.i + 1)).ToArray();
    private static string? SourceSlot(string key) => KeyboardMapping.WindowsFunctions.FirstOrDefault(p => p.Value == key).Key;
    private void RememberSemantic(string key, bool down)
    {
        var position = key switch
        {
            "VolumeMute" => "F1",
            "KeyboardBrightnessDown" => "F2",
            "KeyboardBrightnessUp" => "F3",
            "AuraCycle" => "F4",
            "PerformanceMode" => "F5",
            "Screenshot" => "F6",
            "BrightnessDown" => "F7",
            "BrightnessUp" => "F8",
            "DisplaySwitch" => "F9",
            "TouchpadToggle" => "F10",
            "DoNotDisturb" => "F11",
            "AirplaneMode" => "F12",
            _ => null
        };
        if (position is not null)
            semantics[(position, down)] = Environment.TickCount64;
    }
    private void Edge(string key, bool down, uint stamp, bool canHaveHook, string? functionSlot = null)
    {
        RememberSemantic(key, down);
        if (!down)
        {
            repeating.Remove(key);
            repeatSlots.Remove(key);
        }
        if (canHaveHook && hooks.TryGetValue((key, down), out var recent) && (recent.Stamp == stamp || Environment.TickCount64 - recent.At < 25))
            return;
        var handled = capture(new(down ? "keyDown" : "keyUp", key, FunctionSlot: functionSlot));
        var target = RepeatTarget?.Invoke(key, functionSlot) ?? key;
        var continuous = target is "VolumeUp" or "VolumeDown" or "BrightnessUp" or "BrightnessDown" or "KeyboardBrightnessUp" or "KeyboardBrightnessDown" or "MediaRewind" or "MediaFastForward"
            || target != KeyboardMapping.NoAction && !KeyboardMapping.FunctionKeys.Contains(target) && !KeyboardMapping.Modifiers.Contains(target);
        if (down && handled && continuous && !repeating.ContainsKey(key))
        {
            if (functionSlot is not null)
                repeatSlots[key] = functionSlot;
            var ticket = ++repeatSequence;
            repeating[key] = ticket;
            _ = Repeat(key, generation, ticket);
        }
    }
    private async Task Repeat(string key, int round, int ticket)
    {
        await Task.Delay(350).ConfigureAwait(false);
        try
        {
            while (!dispatcher.HasShutdownStarted)
            {
                var active = await dispatcher.InvokeAsync(() =>
                {
                    if (round != generation || !repeating.TryGetValue(key, out var live) || live != ticket)
                        return false;
                    if (!hooks.TryGetValue((key, true), out var hook) || Environment.TickCount64 - hook.At > 150)
                    {
                        if (!capture(new("keyDown", key, FunctionSlot: repeatSlots.GetValueOrDefault(key))))
                        {
                            repeating.Remove(key);
                            repeatSlots.Remove(key);
                            return false;
                        }
                    }
                    return true;
                });
                if (!active)
                    break;
                await Task.Delay(90).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { }
    }
    public void Keyboard(IntPtr handle, IntPtr data, int offset, uint stamp)
    {
        var vk = (ushort)Marshal.ReadInt16(data, offset + 6);
        if (vk < 0x70 || vk > 0x87)
            return;
        if (unchecked((uint)Marshal.ReadInt32(data, offset + 12)) == 0x534d494e)
            return;
        if (!devices.TryGetValue(handle, out var device))
        {
            device = Describe(handle);
            devices[handle] = device;
        }
        var key = "F" + (vk - 0x6f);
        var down = (Marshal.ReadInt16(data, offset + 2) & 1) == 0;
        _ = KeyboardFallback(key, down, stamp, device.Name.Contains("VID_0B05&PID_19B6", StringComparison.OrdinalIgnoreCase), generation);
    }
    private async Task KeyboardFallback(string key, bool down, uint stamp, bool asus, int round)
    {
        await Task.Delay(10).ConfigureAwait(false);
        if (dispatcher.HasShutdownStarted)
            return;
        try
        {
            await dispatcher.InvokeAsync(() =>
            {
                if (round != generation)
                    return;
                if (asus && semantics.TryGetValue((key, down), out var observed) && Environment.TickCount64 - observed < 40)
                    return;
                Edge(key, down, stamp, true);
            });
        }
        catch (OperationCanceledException) { }
    }
    public void HID(IntPtr handle, IntPtr data, int offset, int bytes, uint stamp)
    {
        var length = Marshal.ReadInt32(data, offset);
        var count = Marshal.ReadInt32(data, offset + 4);
        if (length <= 0 || length > 1024 || count <= 0 || count > 64 || (long)length * count > bytes - 8)
            return;
        if (!devices.TryGetValue(handle, out var device))
        {
            device = Describe(handle);
            devices[handle] = device;
        }
        var asus = device.Name.Contains("VID_0B05&PID_19B6", StringComparison.OrdinalIgnoreCase);
        for (var n = 0; n < count; n++)
        {
            var report = new byte[length];
            Marshal.Copy(IntPtr.Add(data, offset + 8 + n * length), report, 0, length);
            if (asus && device.Page == 0xff31 && device.Usage == 0x79 && device.Name.Contains("&Col04", StringComparison.OrdinalIgnoreCase)
                && length == 32 && report[0] == 0x5d && report[1] == 0x0a)
            {
                var down = (report[17] & 0x80) != 0;
                if (!down && !device.Fn && device.FunctionSlots.Count == 0)
                    continue;
                var nextSlots = down ? DecodeFunctionRow(report).ToHashSet() : new HashSet<string>();
                foreach (var slot in device.FunctionSlots.Except(nextSlots))
                    Edge(AsusFunctionKey(slot)!, false, stamp, false, slot);
                if (device.Fn != down)
                {
                    device.Fn = down;
                    Volatile.Write(ref physicalFn, devices.Values.Any(d => d.Fn) ? 1 : 0);
                    Edge("Fn", down, stamp, false);
                }
                foreach (var slot in nextSlots.Except(device.FunctionSlots))
                    Edge(AsusFunctionKey(slot)!, true, stamp, false, slot);
                device.FunctionSlots = nextSlots;
            }
            else if (asus && device.Page == 0xff31 && device.Usage == 0x76 && device.Name.Contains("&Col03", StringComparison.OrdinalIgnoreCase)
                && length == 6 && report[0] == 0x5a)
            {
                var winLock = report[1] == 0x4f;
                if (winLock && !device.WinLockReport)
                    diagnostic($"SourceWinLockReport code=5A4F physicalFn={PhysicalFnDown}");
                device.WinLockReport = winLock;
                var next = report[1] switch
                {
                    0x10 => "BrightnessDown",
                    0x20 => "BrightnessUp",
                    0xc5 => "KeyboardBrightnessDown",
                    0xc4 => "KeyboardBrightnessUp",
                    0x4e => "FnLock",
                    0xb3 => "AuraCycle",
                    0xae => "PerformanceMode",
                    0x6b => "TouchpadToggle",
                    _ => null
                };
                if (device.Hotkey != next)
                {
                    if (device.Hotkey is { } old && device.HotkeyEmitted)
                        Edge(old, false, stamp, false, SourceSlot(old));
                    device.Hotkey = next;
                    device.HotkeyEmitted = next is not null && (!PhysicalFnDown || SourceSlot(next) is null);
                    if (device.HotkeyEmitted)
                        Edge(next!, true, stamp, false, SourceSlot(next!));
                }
            }
            else if (device.Page == 0x0c && device.Preparsed != IntPtr.Zero)
            {
                var usages = new ushort[32];
                uint total = 32;
                if (HidP_GetUsages(0, 0x0c, 0, usages, ref total, device.Preparsed, report, (uint)length) != 0x00110000)
                    continue;
                var next = usages.Take((int)Math.Min(total, 32)).Select(ConsumerKey).Where(k => k is not null).Select(k => k!).ToHashSet();
                foreach (var key in device.Consumer.Except(next))
                    if (!(asus && PhysicalFnDown && SourceSlot(key) is not null))
                        Edge(key, false, stamp, true);
                foreach (var key in next.Except(device.Consumer))
                    if (!(asus && PhysicalFnDown && SourceSlot(key) is not null))
                        Edge(key, true, stamp, true);
                device.Consumer = next;
            }
        }
    }
    private static string? ConsumerKey(ushort usage) => usage switch { 0xe2 => "VolumeMute", 0xe9 => "VolumeUp", 0xea => "VolumeDown", 0xcd => "MediaPlayPause", 0xb5 => "MediaNext", 0xb6 => "MediaPrevious", 0xb3 => "MediaFastForward", 0xb4 => "MediaRewind", 0xb7 => "MediaStop", 0x6f => "BrightnessUp", 0x70 => "BrightnessDown", _ => null };
    private static Device Describe(IntPtr handle)
    {
        var value = new Device();
        uint count = 0;
        GetRawInputDeviceInfoW(handle, 0x20000007, IntPtr.Zero, ref count);
        if (count is > 0 and < 2048)
        {
            var text = Marshal.AllocHGlobal((int)(count + 1) * 2);
            try
            {
                if (GetRawInputDeviceInfoW(handle, 0x20000007, text, ref count) != uint.MaxValue)
                    value.Name = Marshal.PtrToStringUni(text) ?? "";
            }
            finally { Marshal.FreeHGlobal(text); }
        }
        var info = Marshal.AllocHGlobal(32);
        try
        {
            count = 32;
            Marshal.WriteInt32(info, 32);
            if (GetRawInputDeviceInfoW(handle, 0x2000000b, info, ref count) != uint.MaxValue && Marshal.ReadInt32(info, 4) == 2)
            {
                value.Page = (ushort)Marshal.ReadInt16(info, 20);
                value.Usage = (ushort)Marshal.ReadInt16(info, 22);
            }
        }
        finally { Marshal.FreeHGlobal(info); }
        if (value.Page == 0x0c)
        {
            count = 0;
            GetRawInputDeviceInfoW(handle, 0x20000005, IntPtr.Zero, ref count);
            if (count is > 0 and <= 65536)
            {
                value.Preparsed = Marshal.AllocHGlobal((int)count);
                if (GetRawInputDeviceInfoW(handle, 0x20000005, value.Preparsed, ref count) == uint.MaxValue)
                {
                    Marshal.FreeHGlobal(value.Preparsed);
                    value.Preparsed = IntPtr.Zero;
                }
            }
        }
        return value;
    }
    public void RemoveDevice(IntPtr handle)
    {
        if (!devices.Remove(handle, out var d))
            return;
        foreach (var slot in d.FunctionSlots)
            Edge(AsusFunctionKey(slot)!, false, 0, false, slot);
        if (d.Fn)
            Edge("Fn", false, 0, false);
        Volatile.Write(ref physicalFn, devices.Values.Any(v => v.Fn) ? 1 : 0);
        if (d.Hotkey is { } key && d.HotkeyEmitted)
            Edge(key, false, 0, false, SourceSlot(key));
        foreach (var consumer in d.Consumer)
            Edge(consumer, false, 0, false);
        if (d.Preparsed != IntPtr.Zero)
            Marshal.FreeHGlobal(d.Preparsed);
    }
    public void Reset()
    {
        generation++;
        repeating.Clear();
        repeatSlots.Clear();
        foreach (var d in devices.Values)
        {
            if (d.Preparsed != IntPtr.Zero)
                Marshal.FreeHGlobal(d.Preparsed);
        }
        devices.Clear();
        hooks.Clear();
        semantics.Clear();
        Volatile.Write(ref physicalFn, 0);
    }
    public void Dispose() => Reset();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetRawInputDeviceInfoW(IntPtr device, uint command, IntPtr data, ref uint size);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint GetRawInputDeviceList(IntPtr entries, ref uint count, uint size);
    [DllImport("hid.dll")] private static extern uint HidP_GetUsages(int type, ushort page, ushort collection, [Out] ushort[] usages, ref uint count, IntPtr preparsed, byte[] report, uint length);
}
