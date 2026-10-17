using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.IO;

namespace ShareMouse;

// System functions without a keyboard VK. Keep potentially slow WMI work off input dispatch.
internal sealed class WindowsFunctionKeys
{
    private readonly Action<string> result;
    private readonly Action<string, string> notify;
    private readonly object performanceGate = new();
    private int brightnessDelta, brightnessWorker;
    private int keyboardDelta, keyboardWorker;
    private int? keyboardLevel;
    private string[] keyboardPaths = [];
    private readonly object auraGate = new();
    private int auraMode = -1;
    public WindowsFunctionKeys(Action<string> result, Action<string, string>? notify = null)
    {
        this.result = result;
        this.notify = notify ?? ((_, _) => { });
    }
    public void SetKeyboardPaths(string[] paths)
    {
        Volatile.Write(ref keyboardPaths, paths);
    }
    public void KeyboardBrightness(int direction)
    {
        Interlocked.Add(ref keyboardDelta, direction);
        if (Interlocked.CompareExchange(ref keyboardWorker, 1, 0) == 0)
            _ = Task.Run(DrainKeyboardBrightness);
    }
    public void ToggleTouchpad()
    {
        _ = Task.Run(() =>
        {
            try
            {
                var applied = WindowsAsusKeyboard.ToggleTouchpad(Volatile.Read(ref keyboardPaths), out var error);
                result(applied ? "FunctionApplied key=TouchpadToggle" : "FunctionUnavailable key=TouchpadToggle error=" + error);
            }
            catch (Exception error) { result("FunctionUnavailable key=TouchpadToggle error=" + error.GetType().Name); }
        });
    }
    public void SystemFunction(string key)
    {
        _ = Task.Run(() =>
        {
            try
            {
                if (key == "AirplaneMode")
                {
                    var enabled = WindowsRadioMode.Toggle();
                    result($"FunctionApplied key=AirplaneMode enabled={enabled == 0}");
                }
                else if (key == "PerformanceMode")
                {
                    lock (performanceGate)
                    {
                        var battery = System.Windows.Forms.SystemInformation.PowerStatus.PowerLineStatus != System.Windows.Forms.PowerLineStatus.Online;
                        var mode = WindowsAsusPerformance.Cycle(battery);
                        var label = mode == 0 ? "平衡" : mode == 1 ? "增强" : "静音";
                        try
                        {
                            var confirmed = WindowsPowerMode.Apply(mode);
                            result($"Function{(confirmed ? "Applied" : "Partial")} key=PerformanceMode requestedMode={mode} driverAccepted=True systemPowerConfirmed={confirmed} armouryCrateStateReadback=False");
                            notify(confirmed ? "性能模式：" + label : "性能模式未完成", confirmed ? "Windows 电源模式已确认；华硕驱动已接受请求" : "华硕驱动已接受请求；Windows 电源模式没有变到目标档位");
                        }
                        catch (Exception error) { result($"FunctionPartial key=PerformanceMode requestedMode={mode} driverAccepted=True systemPowerConfirmed=False hresult={error.HResult:X8}"); notify("性能模式未完成", "华硕驱动已接受请求；Windows 电源模式接口未完成切换"); }
                    }
                }
                else if (key == "AuraCycle")
                {
                    lock (auraGate)
                    {
                        var next = (auraMode + 1) % 4;
                        var applied = WindowsAsusKeyboard.SetAura(Volatile.Read(ref keyboardPaths), next, out var error);
                        if (applied)
                            auraMode = next;
                        result(applied ? $"FunctionApplied key=AuraCycle mode={next}" : $"FunctionUnavailable key=AuraCycle error={error}");
                    }
                }
                else if (key == "DisplaySwitch")
                {
                    var program = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "DisplaySwitch.exe");
                    if (!File.Exists(program))
                        throw new NotSupportedException("Projection entry unavailable");
                    Process.Start(new ProcessStartInfo(program) { UseShellExecute = false });
                    result("FunctionApplied key=DisplaySwitch entry=system_program");
                }
            }
            catch (Exception error) { result($"FunctionUnavailable key={key} error={error.GetType().Name} hresult={error.HResult:X8}"); if (key == "PerformanceMode") notify("性能模式未完成", "目标电脑的性能接口不可用；键鼠共享继续运行"); }
        });
    }
    private void DrainKeyboardBrightness()
    {
        try
        {
            while (true)
            {
                var delta = Interlocked.Exchange(ref keyboardDelta, 0);
                if (delta == 0)
                    break;
                var unknown = keyboardLevel is null;
                var next = WindowsAsusKeyboard.NextBrightness(keyboardLevel, delta);
                if (WindowsAsusKeyboard.SetBrightness(Volatile.Read(ref keyboardPaths), next, out var error))
                {
                    keyboardLevel = next;
                    result($"FunctionApplied key=KeyboardBrightness level={next} initialStateUnknown={unknown}");
                }
                else
                {
                    keyboardLevel = null;
                    result($"FunctionUnavailable key=KeyboardBrightness error={error}");
                }
            }
        }
        catch (Exception error) { keyboardLevel = null; result("FunctionUnavailable key=KeyboardBrightness error=" + error.GetType().Name); }
        finally
        {
            Interlocked.Exchange(ref keyboardWorker, 0);
            if (Volatile.Read(ref keyboardDelta) != 0 && Interlocked.CompareExchange(ref keyboardWorker, 1, 0) == 0)
                _ = Task.Run(DrainKeyboardBrightness);
        }
    }
    public void Brightness(int direction)
    {
        Interlocked.Add(ref brightnessDelta, direction);
        if (Interlocked.CompareExchange(ref brightnessWorker, 1, 0) == 0)
            _ = Task.Run(DrainBrightness);
    }
    private void DrainBrightness()
    {
        try
        {
            while (true)
            {
                var delta = Interlocked.Exchange(ref brightnessDelta, 0);
                if (delta == 0)
                    break;
                object? locator = null, service = null, levels = null, methods = null;
                var stage = "connect";
                try
                {
                    var type = Type.GetTypeFromProgID("WbemScripting.SWbemLocator") ?? throw new NotSupportedException();
                    locator = Activator.CreateInstance(type)!;
                    service = ((dynamic)locator).ConnectServer(".", "root\\WMI");
                    stage = "read";
                    levels = ((dynamic)service).ExecQuery("SELECT CurrentBrightness,InstanceName FROM WmiMonitorBrightness WHERE Active=TRUE");
                    string? instance = null;
                    var brightness = 0;
                    foreach (var entry in (System.Collections.IEnumerable)levels)
                    {
                        // WMI's custom IDispatch field lookup fails on a worker apartment.
                        // Its declared Properties_ collection works on both STA and MTA.
                        try
                        {
                            instance = Convert.ToString(Property(entry, "InstanceName"));
                            brightness = Convert.ToInt32(Property(entry, "CurrentBrightness"));
                        }
                        finally { Release(entry); }
                        break;
                    }
                    if (instance is null)
                    {
                        result("FunctionUnavailable key=Brightness reason=no_active_system_backlight");
                        continue;
                    }
                    var desired = (byte)Math.Clamp(brightness + delta * 5, 0, 100);
                    var applied = false;
                    methods = ((dynamic)service).ExecQuery("SELECT * FROM WmiMonitorBrightnessMethods");
                    foreach (var entry in (System.Collections.IEnumerable)methods)
                    {
                        object? arguments = null, output = null;
                        try
                        {
                            if (Convert.ToString(Property(entry, "InstanceName")) != instance)
                                continue;
                            stage = "set";
                            arguments = ((dynamic)entry).Methods_.Item("WmiSetBrightness").InParameters.SpawnInstance_();
                            ((dynamic)arguments).Properties_.Item("Timeout").Value = (uint)1;
                            ((dynamic)arguments).Properties_.Item("Brightness").Value = desired;
                            output = ((dynamic)entry).ExecMethod_("WmiSetBrightness", arguments);
                            var code = Convert.ToUInt32(Property(output, "ReturnValue"));
                            applied = code == 0;
                        }
                        finally { Release(output); Release(arguments); Release(entry); }
                        if (applied)
                            break;
                    }
                    result(applied ? $"FunctionApplied key=Brightness previous={brightness} requested={desired}" : "FunctionUnavailable key=Brightness reason=driver_rejected");
                }
                catch (Exception error) { result($"FunctionUnavailable key=Brightness stage={stage} error={error.GetType().Name} hresult={error.HResult:X8}"); }
                finally { Release(methods); Release(levels); Release(service); Release(locator); }
            }
        }
        finally
        {
            Interlocked.Exchange(ref brightnessWorker, 0);
            if (Volatile.Read(ref brightnessDelta) != 0 && Interlocked.CompareExchange(ref brightnessWorker, 1, 0) == 0)
                _ = Task.Run(DrainBrightness);
        }
    }
    internal static object Property(object value, string name)
    {
        object? properties = null, property = null;
        try
        {
            properties = ((dynamic)value).Properties_;
            property = ((dynamic)properties).Item(name);
            return ((dynamic)property).Value ?? throw new InvalidOperationException("WMI returned an empty " + name);
        }
        finally { Release(property); Release(properties); }
    }
    private static void Release(object? value)
    {
        if (value is not null && Marshal.IsComObject(value))
            Marshal.FinalReleaseComObject(value);
    }
    public static void MediaTransport(bool forward)
    {
        var window = GetForegroundWindow();
        if (window != IntPtr.Zero)
            PostMessageW(window, 0x0319, window, new IntPtr((forward ? 49 : 50) << 16));
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessageW(IntPtr window, uint message, IntPtr wp, IntPtr lp);
}
