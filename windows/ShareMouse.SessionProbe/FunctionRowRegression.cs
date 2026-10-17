using System.Collections;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using ShareMouse;
using ShareMouse.Core;

internal static class FunctionRowRegression
{
    public static void Run()
    {
        (int Offset, byte Mask)[] bits = [(4, 0x80), (5, 1), (5, 2), (5, 4), (5, 0x10), (5, 0x20), (5, 0x40), (5, 0x80), (6, 2), (6, 4), (6, 8), (6, 0x10)];
        var events = new List<CapturedInput>();
        using var raw = new WindowsRawFunctionInput(e => { events.Add(e); return false; }, Dispatcher.CurrentDispatcher);
        var deviceType = typeof(WindowsRawFunctionInput).GetNestedType("Device", BindingFlags.NonPublic)!;
        var device = Activator.CreateInstance(deviceType, nonPublic: true)!;
        deviceType.GetField("Name")!.SetValue(device, @"\\?\HID#VID_0B05&PID_19B6&Col04#fixture");
        deviceType.GetField("Page")!.SetValue(device, (ushort)0xff31);
        deviceType.GetField("Usage")!.SetValue(device, (ushort)0x79);
        var devices = (IDictionary)typeof(WindowsRawFunctionInput).GetField("devices", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(raw)!;
        var handle = new IntPtr(123);
        devices[handle] = device;
        var memory = Marshal.AllocHGlobal(40);
        try
        {
            void Report(byte[] report)
            {
                Marshal.WriteInt32(memory, 32);
                Marshal.WriteInt32(memory, 4, 1);
                Marshal.Copy(report, 0, IntPtr.Add(memory, 8), report.Length);
                raw.HID(handle, memory, 0, 40, 0);
            }
            byte[] Empty()
            {
                var report = new byte[32];
                report[0] = 0x5d;
                report[1] = 0x0a;
                return report;
            }
            for (var i = 0; i < bits.Length; i++)
            {
                events.Clear();
                var report = Empty();
                report[17] = 0x80;
                report[bits[i].Offset] = bits[i].Mask;
                if (!WindowsRawFunctionInput.DecodeFunctionRow(report).SequenceEqual(new[] { "F" + (i + 1) }))
                    throw new Exception("Wrong report slot");
                Report(report);
                Report(Empty());
                var expected = new[] { ("keyDown", "Fn", (string?)null), ("keyDown", KeyboardMapping.WindowsFunction("F" + (i + 1)), "F" + (i + 1)), ("keyUp", KeyboardMapping.WindowsFunction("F" + (i + 1)), "F" + (i + 1)), ("keyUp", "Fn", null) };
                if (!events.Select(e => (e.Type, e.Key, e.FunctionSlot)).SequenceEqual(expected))
                    throw new Exception("Incorrect down/up/slot order for F" + (i + 1));
            }
            var all = Empty();
            all[17] = 0x80;
            foreach (var bit in bits)
                all[bit.Offset] |= bit.Mask;
            Report(all);
            events.Clear();
            raw.RemoveDevice(handle);
            if (events.Count != 13 || events[^1].Key != "Fn" || events.Any(e => e.Type != "keyUp"))
                throw new Exception("Device removal left held keys");
            var repeating = (IDictionary)typeof(WindowsRawFunctionInput).GetField("repeating", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(raw)!;
            if (repeating.Count != 0)
                throw new Exception("Local input started remote repeat tasks");
            Console.WriteLine("PASS: verified ASUS reports capture all 12 slots, key-up order, device removal, and no local repeat work. No OS input injected.");
        }
        finally { Marshal.FreeHGlobal(memory); }
    }
}
