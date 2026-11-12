using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using ShareMouse.Core;
using ShareMouse.Network;

namespace ShareMouse;

public sealed partial class WindowsComputerAdapter
{
    private JsonNode activeControl = ComputerUseService.Obj(("mode", "user_mouse"));
    public JsonNode ListWindows()
    {
        var result = new JsonArray();
        EnumWindows((hwnd, _) =>
        {
            if (result.Count >= 100 || !IsWindowVisible(hwnd)) return true;
            try { if (WindowInfo(hwnd) is { } window && window["title"]!.GetValue<string>().Length > 0) result.Add(window); }
            catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
            return true;
        }, IntPtr.Zero);
        return result;
    }
    private static JsonObject? WindowInfo(IntPtr hwnd)
    {
        if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd, out var rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top) return null;
        GetWindowThreadProcessId(hwnd, out var pid);
        using var process = Process.GetProcessById((int)pid);
        var title = new StringBuilder(512); GetWindowTextW(hwnd, title, title.Capacity);
        return ComputerUseService.Obj(("window_id", "win:" + pid + ":" + hwnd.ToInt64().ToString("X")),
            ("process_id", pid), ("process_name", process.ProcessName), ("title", title.ToString()),
            ("left", rect.Left), ("top", rect.Top), ("right", rect.Right), ("bottom", rect.Bottom), ("minimized", IsIconic(hwnd)));
    }
    internal static IntPtr WindowHandle(string id)
    {
        var parts = id.Split(':');
        if (parts.Length != 3 || parts[0] != "win" || !uint.TryParse(parts[1], out var pid) || !long.TryParse(parts[2], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var handle))
            throw new IOException("invalid_window_id");
        var hwnd = new IntPtr(handle);
        GetWindowThreadProcessId(hwnd, out var current);
        if (current != pid || !IsWindowVisible(hwnd)) throw new IOException("application_window_unavailable");
        return hwnd;
    }
    public JsonNode PrepareControl(JsonNode args)
    {
        var mode = args["control_mode"]?.GetValue<string>() ?? "user_mouse";
        if (mode == "user_mouse") return ComputerUseService.Obj(("mode", mode));
        if (mode != "independent") throw new IOException("control_mode_unsupported");
        var windowID = args["window_id"]?.GetValue<string>();
        var app = args["application"]?.GetValue<string>();
        var matches = ListWindows().AsArray().Where(w => (windowID is null || w!["window_id"]!.GetValue<string>() == windowID)
            && (app is null || w!["process_name"]!.GetValue<string>().Equals(app, StringComparison.OrdinalIgnoreCase) || w["title"]!.GetValue<string>().Equals(app, StringComparison.OrdinalIgnoreCase))).ToArray();
        if (windowID is null && app is null) throw new IOException("independent_requires_application_or_window_id");
        if (matches.Length != 1) throw new IOException(matches.Length == 0 ? "application_window_unavailable" : "application_window_ambiguous:use_windows_then_window_id");
        return ComputerUseService.Obj(("mode", mode), ("window_id", matches[0]!["window_id"]));
    }
    private static JsonObject Target(JsonNode context) => WindowInfo(WindowHandle(context["window_id"]!.GetValue<string>())) ?? throw new IOException("application_window_unavailable");
    public JsonObject InputState()
    {
        var state = WindowsInputStatus.Capture();
        if (activeControl["mode"]?.GetValue<string>() == "independent")
        {
            try { state["control_target_window"] = Target(activeControl); }
            catch (Exception e) when (e is IOException or ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { state["control_target_window"] = null; }
            state["uses_system_pointer"] = false;
            state["provider_may_change_foreground"] = true;
        }
        return state;
    }
    private async Task<JsonObject> CaptureAccessibility(ScreenGeometry screen, JsonNode options, Func<bool> active)
    {
        var context = options["_control_context"]!;
        var window = Target(context);
        if (options["capture_region"] is not null) throw new IOException("accessibility_observation_has_no_pixel_crop");
        var left = window["left"]!.GetValue<int>(); var top = window["top"]!.GetValue<int>();
        var width = window["right"]!.GetValue<int>() - left; var height = window["bottom"]!.GetValue<int>() - top;
        var bounds = ComputerUseService.Obj(("x", left), ("y", top), ("width", width), ("height", height));
        var inspect = (JsonObject)options.DeepClone(); inspect["include_ocr"] = false; inspect["include_controls"] = true; inspect["text_only"] = true;
        var analysis = await WindowsMCPInspection.Inspect(null, inspect, bounds, width, height, window["window_id"]!.GetValue<string>(), active);
        _ = Target(context);
        return ComputerUseService.Obj(("width", width), ("height", height), ("captured_at", DateTime.UtcNow.ToString("O")),
            ("desktop_bounds", bounds), ("screen_desktop_bounds", bounds), ("desktop_coordinate_space", "desktop_pixels"),
            ("input_state", InputState()), ("analysis", analysis), ("image_omitted", true), ("pixels_captured", false),
            ("observation_kind", "window_accessibility"));
    }
    public async Task AccessibilityAction(JsonNode action, JsonNode context)
    {
        _ = Target(context);
        var options = ComputerUseService.Obj(("_control_context", context), ("_accessibility_action", action));
        var result = await WindowsMCPInspection.Inspect(null, options, new JsonObject(), 0, 0, context["window_id"]!.GetValue<string>(), () => activeControl == context && DesktopAvailable);
        if (result["action_completed"]?.GetValue<bool>() != true) throw new IOException(result["error"]?.GetValue<string>() ?? "accessibility_action_outcome_unknown");
    }
    [StructLayout(LayoutKind.Sequential)] private struct WindowRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out WindowRect bounds);
}
