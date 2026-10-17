using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.Win32;
using ShareMouse.Core;
using ShareMouse.Network;

namespace ShareMouse;

public sealed class WindowsComputerAdapter
{
    private readonly MCPClickFeedback feedback = new();
    private bool showHints = true;
    public bool ShowHints
    {
        get => showHints; set
        {
            showHints = value;
            if (!value)
                feedback.Stop();
        }
    }
    public void BeginControl()
    {
    }
    public static bool DesktopAvailable
    {
        get
        {
            var session = DesktopSession();
            if (session.locked != false || session.active != true)
                return false;
            var desktop = OpenInputDesktop(0, false, 0x101);
            if (desktop == IntPtr.Zero)
                return false;
            try
            {
                var name = new StringBuilder(256);
                return GetUserObjectInformation(desktop, 2, name, 512, out _) && name.ToString() == "Default";
            }
            finally { CloseDesktop(desktop); }
        }
    }
    public JsonObject Info()
    {
        var desktopAvailable = DesktopAvailable;
        var session = DesktopSession();
        using var cpu = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0");
        var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        GlobalMemoryStatusEx(ref memory);
        var drive = new DriveInfo(System.IO.Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))!);
        return ComputerUseService.Obj(("platform", "windows"), ("os_version", RuntimeInformation.OSDescription), ("architecture", RuntimeInformation.OSArchitecture.ToString()), ("hostname", Environment.MachineName), ("input_state", WindowsInputStatus.Capture()), ("mcp_features", ComputerUseService.Obj(("ocr", "optional_native_recognizer"), ("controls", "optional_ui_automation"), ("stable_region", true), ("relative_move", true), ("key_hold", true), ("pointer_animation", true), ("pointer_animation_enabled", ShowHints), ("pointer_animation_scope", "presentation_overlay"), ("control_modes", new[] { "user_mouse" }), ("system_cursor_style_active", false), ("cursor_style", "system"))), ("cpu", cpu?.GetValue("ProcessorNameString") as string ?? "Unknown"), ("cpu_cores", Environment.ProcessorCount), ("memory_bytes", memory.TotalPhysical), ("home_free_bytes", drive.AvailableFreeSpace), ("permissions", ComputerUseService.Obj(("screen_capture", desktopAvailable), ("input_injection", desktopAvailable), ("desktop_available", desktopAvailable), ("session_locked", session.locked), ("session_active", session.active), ("elevation_boundary", "Current user desktop; higher integrity windows may reject input."))));
    }
    public Task<JsonObject> Capture(ScreenGeometry geometry) => Capture(geometry, new JsonObject(), () => true);
    public async Task<JsonObject> Capture(ScreenGeometry geometry, JsonNode options, Func<bool> active)
    {
        ComputerUseService.ValidateObservationOptions(options);
        if (!DesktopAvailable)
            throw new IOException("desktop_locked_or_unavailable");
        var screen = System.Windows.Forms.Screen.AllScreens.FirstOrDefault(s => geometry.Id.EndsWith(":" + s.DeviceName, StringComparison.Ordinal)) ?? throw new IOException("screen_unavailable");
        var screenBounds = screen.Bounds;
        var roi = options["capture_region"]?.DeepClone() ?? ComputerUseService.Obj(("x", 0), ("y", 0), ("width", 1), ("height", 1));
        double R(string key) => roi[key]!.GetValue<double>();
        var left = Math.Min(screenBounds.Right - 1, screenBounds.X + (int)Math.Round(R("x") * screenBounds.Width));
        var top = Math.Min(screenBounds.Bottom - 1, screenBounds.Y + (int)Math.Round(R("y") * screenBounds.Height));
        var right = Math.Clamp(screenBounds.X + (int)Math.Round((R("x") + R("width")) * screenBounds.Width), left + 1, screenBounds.Right);
        var bottom = Math.Clamp(screenBounds.Y + (int)Math.Round((R("y") + R("height")) * screenBounds.Height), top + 1, screenBounds.Bottom);
        var bounds = new System.Drawing.Rectangle(left, top, right - left, bottom - top);
        roi = ComputerUseService.Obj(("x", (left - screenBounds.X) / (double)screenBounds.Width), ("y", (top - screenBounds.Y) / (double)screenBounds.Height), ("width", bounds.Width / (double)screenBounds.Width), ("height", bounds.Height / (double)screenBounds.Height));
        var maximum = options["thumbnail_max_dimension"]?.GetValue<int>() ?? options["max_dimension"]?.GetValue<int>() ?? 0;
        var ratio = maximum > 0 ? Math.Min(1, maximum / (double)Math.Max(bounds.Width, bounds.Height)) : 1;
        var width = Math.Max(1, (int)(bounds.Width * ratio));
        var height = Math.Max(1, (int)(bounds.Height * ratio));
        var textOnly = ComputerUseService.Flag(options, "text_only");
        var pixels = !textOnly || ComputerUseService.Flag(options, "include_ocr");
        System.Drawing.Bitmap Frame()
        {
            if (!active())
                throw new IOException("capture_interrupted");
            var original = new System.Drawing.Bitmap(bounds.Width, bounds.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try
            {
                using (var g = System.Drawing.Graphics.FromImage(original))
                    g.CopyFromScreen(bounds.Location, System.Drawing.Point.Empty, bounds.Size, System.Drawing.CopyPixelOperation.SourceCopy);
                if (width == bounds.Width && height == bounds.Height)
                    return original;
                var scaled = new System.Drawing.Bitmap(width, height);
                try
                {
                    using var g = System.Drawing.Graphics.FromImage(scaled);
                    g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g.DrawImage(original, 0, 0, width, height);
                }
                catch { scaled.Dispose(); throw; }
                original.Dispose();
                return scaled;
            }
            catch { original.Dispose(); throw; }
        }
        var started = System.Diagnostics.Stopwatch.StartNew();
        System.Drawing.Bitmap? image = pixels ? Frame() : null;
        var captured = DateTime.UtcNow;
        var stability = ComputerUseService.Obj(("status", "not_requested"));
        try
        {
            if (ComputerUseService.Flag(options, "wait_for_stable"))
            {
                var region = WindowsMCPInspection.Region(options["stability_region"], width, height);
                var previous = Sample(image!, region);
                var matching = 1;
                var samples = 1;
                var score = double.PositiveInfinity;
                var timeout = ComputerUseService.Integer(options, "stability_timeout_ms", 2000, 200, 5000);
                var interval = ComputerUseService.Integer(options, "stability_interval_ms", 200, 100, 1000);
                var required = ComputerUseService.Integer(options, "stability_samples", 3, 2, 5);
                var threshold = options["stability_threshold"]?.GetValue<double>() ?? 3;
                while (started.ElapsedMilliseconds < timeout && matching < required)
                {
                    await Task.Delay(Math.Min(interval, Math.Max(1, timeout - (int)started.ElapsedMilliseconds)));
                    if (!active())
                        throw new IOException("capture_interrupted");
                    if (started.ElapsedMilliseconds >= timeout)
                        break;
                    image!.Dispose();
                    image = Frame();
                    captured = DateTime.UtcNow;
                    var next = Sample(image, region);
                    score = Difference(previous, next);
                    matching = score <= threshold ? matching + 1 : 1;
                    previous = next;
                    samples++;
                }
                stability = ComputerUseService.Obj(("status", matching >= required ? "stable_in_region" : "timeout"), ("samples_taken", samples), ("matched_frames", matching), ("difference_score", double.IsFinite(score) ? score : (double?)null), ("elapsed_ms", started.Elapsed.TotalMilliseconds), ("proves_interactivity", false));
            }
            var state = WindowsInputStatus.Capture();
            var desktop = ComputerUseService.Obj(("x", bounds.X), ("y", bounds.Y), ("width", bounds.Width), ("height", bounds.Height));
            var analysis = ComputerUseService.Obj(("stability", stability));
            if (ComputerUseService.Flag(options, "include_ocr") || ComputerUseService.Flag(options, "include_controls") || textOnly)
            {
                byte[]? raw = null;
                if (ComputerUseService.Flag(options, "include_ocr"))
                {
                    using var stream = new MemoryStream();
                    image!.Save(stream, System.Drawing.Imaging.ImageFormat.Png);
                    raw = stream.ToArray();
                }
                var extra = await WindowsMCPInspection.Inspect(raw, options, desktop, width, height, state["foreground_window"]?["window_id"]?.GetValue<string>(), active);
                foreach (var entry in extra)
                    analysis[entry.Key] = entry.Value?.DeepClone();
            }
            if (!active())
                throw new IOException("capture_interrupted");
            if (analysis["controls"] is not null && WindowsInputStatus.Capture()["foreground_window"]?["window_id"]?.GetValue<string>() != state["foreground_window"]?["window_id"]?.GetValue<string>())
                analysis["controls"] = ComputerUseService.Obj(("status", "window_changed_during_inspection"));
            var result = ComputerUseService.Obj(("width", width), ("height", height), ("captured_at", captured.ToString("O")), ("desktop_bounds", desktop), ("screen_desktop_bounds", ComputerUseService.Obj(("x", screenBounds.X), ("y", screenBounds.Y), ("width", screenBounds.Width), ("height", screenBounds.Height))), ("normalized_capture_region", roi), ("desktop_coordinate_space", "desktop_pixels"), ("display_pixel_size", ComputerUseService.Obj(("width", screenBounds.Width), ("height", screenBounds.Height))), ("input_state", state), ("analysis", analysis), ("capture_and_analysis_ms", started.Elapsed.TotalMilliseconds), ("image_omitted", textOnly), ("pixels_captured", pixels));
            result["capture_resolution"] = ComputerUseService.Obj(("requested", "native"), ("source_render_scale", 1), ("max_dimension", maximum));
            if (!textOnly)
            {
                Annotate(image!, options, state, bounds);
                using var bytes = new MemoryStream();
                var transport = ComputerUseService.Flag(options, "_transport_jpeg");
                var jpeg = transport || options["image_format"]?.GetValue<string>() == "jpeg";
                if (jpeg)
                {
                    var encoder = System.Drawing.Imaging.ImageCodecInfo.GetImageEncoders().First(e => e.FormatID == System.Drawing.Imaging.ImageFormat.Jpeg.Guid);
                    using var parameters = new System.Drawing.Imaging.EncoderParameters(1);
                    foreach (var quality in transport ? new long[] { 72, 50, 32, 18 } : new long[] { options["jpeg_quality"]?.GetValue<int>() ?? 80 })
                    {
                        bytes.SetLength(0);
                        parameters.Param[0] = new System.Drawing.Imaging.EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
                        image!.Save(bytes, encoder, parameters);
                        if (!transport || bytes.Length <= 300 * 1024)
                            break;
                    }
                }
                else
                    image!.Save(bytes, System.Drawing.Imaging.ImageFormat.Png);
                if (bytes.Length > (transport ? 300 * 1024 : 10 * 1024 * 1024))
                    throw new IOException("screenshot_too_large");
                result["data"] = Convert.ToBase64String(bytes.ToArray());
                result["mime_type"] = jpeg ? "image/jpeg" : "image/png";
                result["image_annotated"] = ComputerUseService.Flag(options, "mark_cursor") || options["preview_point"] is not null;
            }
            return result;
        }
        finally { image?.Dispose(); }
    }
    public void MoveRelative(CapturedInput input)
    {
        WindowsInputStatus.EnsureCanInject();
        var packet = new Input { Type = 0, Data = new InputUnion { Mouse = new Mouse { X = (int)Math.Round(input.DeltaX), Y = (int)Math.Round(input.DeltaY), Flags = 1, Extra = new UIntPtr(0x534d494e) } } };
        if (SendInput(1, [packet], Marshal.SizeOf<Input>()) != 1)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    private static byte[] Sample(System.Drawing.Bitmap image, System.Drawing.RectangleF region)
    {
        var values = new byte[40 * 30 * 3];
        for (var y = 0; y < 30; y++)
            for (var x = 0; x < 40; x++)
            {
                var pixel = image.GetPixel(Math.Clamp((int)(region.X + (x + .5) / 40 * region.Width), 0, image.Width - 1), Math.Clamp((int)(region.Y + (y + .5) / 30 * region.Height), 0, image.Height - 1));
                var offset = (y * 40 + x) * 3;
                values[offset] = pixel.R;
                values[offset + 1] = pixel.G;
                values[offset + 2] = pixel.B;
            }
        return values;
    }
    private static double Difference(byte[] a, byte[] b)
    {
        if (a.Length == 0 || a.Length != b.Length)
            return double.PositiveInfinity;
        long total = 0;
        for (var i = 0; i < a.Length; i++)
            total += Math.Abs(a[i] - b[i]);
        return total / (double)a.Length;
    }
    private static void Annotate(System.Drawing.Bitmap image, JsonNode options, JsonNode state, System.Drawing.Rectangle bounds)
    {
        var points = new System.Collections.Generic.List<System.Drawing.PointF>();
        if (ComputerUseService.Flag(options, "mark_cursor") && state["cursor_position"] is { } cursor)
            points.Add(new((float)((cursor["x"]!.GetValue<double>() - bounds.X) / bounds.Width * image.Width), (float)((cursor["y"]!.GetValue<double>() - bounds.Y) / bounds.Height * image.Height)));
        if (options["preview_point"] is { } preview)
        {
            var x = preview["x"]!.GetValue<double>();
            var y = preview["y"]!.GetValue<double>();
            if (x < 0 || y < 0 || x >= image.Width || y >= image.Height)
                throw new IOException("preview_point_outside_observation");
            points.Add(new((float)x, (float)y));
        }
        using var graphics = System.Drawing.Graphics.FromImage(image);
        using var pen = new System.Drawing.Pen(System.Drawing.Color.Red, 2);
        foreach (var point in points)
        {
            graphics.DrawEllipse(pen, point.X - 10, point.Y - 10, 20, 20);
            graphics.DrawLine(pen, point.X - 15, point.Y, point.X + 15, point.Y);
            graphics.DrawLine(pen, point.X, point.Y - 15, point.X, point.Y + 15);
        }
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Mouse
    {
        public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra;
    }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public Mouse Mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type; public InputUnion Data;
    }
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] input, int size);
    public async Task FocusApplication(string query)
    {
        var name = query.Trim().ToLowerInvariant();
        var found = new System.Collections.Generic.List<IntPtr>();
        EnumWindows((window, _) => { if (!IsWindowVisible(window)) return true; GetWindowThreadProcessId(window, out var pid); try { using var process = System.Diagnostics.Process.GetProcessById((int)pid); var title = new StringBuilder(512); GetWindowTextW(window, title, 512); var processName = process.ProcessName.ToLowerInvariant(); if (processName == name || title.ToString().Equals(query, StringComparison.OrdinalIgnoreCase) || name == "微信" && processName is "wechat" or "weixin") found.Add(window); } catch (ArgumentException) { } return true; }, IntPtr.Zero);
        var foreground = GetForegroundWindow();
        if (found.Contains(foreground))
            return;
        var main = found.Where(window => { GetWindowThreadProcessId(window, out var pid); try { using var process = System.Diagnostics.Process.GetProcessById((int)pid); return process.MainWindowHandle == window; } catch (ArgumentException) { return false; } }).ToArray();
        if (main.Length == 1)
            found = new() { main[0] };
        if (found.Count != 1)
            throw new IOException(found.Count == 0 ? "application_not_found" : "application_ambiguous");
        var selected = found[0];
        if (IsIconic(selected))
            ShowWindow(selected, 9);
        SetForegroundWindow(selected);
        for (var i = 0; i < 20; i++)
        {
            if (GetForegroundWindow() == selected)
                return;
            await Task.Delay(50);
        }
        throw new IOException("application_focus_denied");
    }
    private delegate bool WindowEnumerator(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowEnumerator callback, IntPtr data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int size);
    // The existing preview hook delays only the visual presentation; endpoint injection
    // and the supplied drag path remain owned by ComputerUseService.
    public int Preview(ScreenGeometry geometry, double x, double y, string kind)
    {
        if (!ShowHints)
            return 0;
        var screen = System.Windows.Forms.Screen.AllScreens.FirstOrDefault(s => geometry.Id.EndsWith(":" + s.DeviceName, StringComparison.Ordinal));
        if (screen is null)
            return 0;
        return feedback.Preview(screen.Bounds.Left + Math.Clamp((int)Math.Round(x * screen.Bounds.Width), 0, screen.Bounds.Width - 1), screen.Bounds.Top + Math.Clamp((int)Math.Round(y * screen.Bounds.Height), 0, screen.Bounds.Height - 1), kind);
    }
    public void Mark(ScreenGeometry geometry, double x, double y, string kind)
    {
        if (!ShowHints || kind != "click")
        {
            feedback.Stop();
            return;
        }
        var screen = System.Windows.Forms.Screen.AllScreens.FirstOrDefault(s => geometry.Id.EndsWith(":" + s.DeviceName, StringComparison.Ordinal));
        if (screen is null)
            return;
        feedback.Show(screen.Bounds.Left + Math.Clamp((int)Math.Round(x * screen.Bounds.Width), 0, screen.Bounds.Width - 1), screen.Bounds.Top + Math.Clamp((int)Math.Round(y * screen.Bounds.Height), 0, screen.Bounds.Height - 1));
    }
    public void Stop() => feedback.Stop();
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length, Load; public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [DllImport("kernel32.dll")] private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    // WTSINFOEX has an 8-byte-aligned union. Read only the level-1 prefix, after checking its size.
    [StructLayout(LayoutKind.Explicit)]
    private struct SessionHeader
    {
        [FieldOffset(0)] public uint Level; [FieldOffset(8)] public uint SessionId; [FieldOffset(12)] public int State; [FieldOffset(16)] public int Flags;
    }
    private static (bool? locked, bool? active) DesktopSession()
    {
        var buffer = IntPtr.Zero;
        try
        {
            if (!WTSQuerySessionInformationW(IntPtr.Zero, -1, 25, out buffer, out var size) || size < Marshal.SizeOf<SessionHeader>())
                return (null, null);
            var state = Marshal.PtrToStructure<SessionHeader>(buffer);
            if (state.Level != 1)
                return (null, null);
            return (state.Flags == 0 ? true : state.Flags == 1 ? false : null, state.State == 0);
        }
        finally { if (buffer != IntPtr.Zero) WTSFreeMemory(buffer); }
    }
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int kind, out IntPtr buffer, out int length);
    [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr buffer);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder data, int size, out int needed);
}
