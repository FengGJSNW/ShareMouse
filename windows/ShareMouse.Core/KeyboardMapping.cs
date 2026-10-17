namespace ShareMouse.Core;

public static class KeyboardMapping
{
    public const string NoAction = "NoAction";
    public static readonly string[] Keys = ["KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ", "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Backquote", "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash", "ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight", "Escape", "Tab", "CapsLock", "Backspace", "Enter", "Space", "Insert", "Delete", "Home", "End", "PageUp", "PageDown", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PrintScreen", "ContextMenu", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24", "Fn", "BrightnessDown", "BrightnessUp", "KeyboardBrightnessDown", "KeyboardBrightnessUp", "VolumeMute", "VolumeDown", "VolumeUp", "MediaPlayPause", "MediaNext", "MediaPrevious", "MediaFastForward", "MediaRewind", "MediaStop", "MissionControl", "Spotlight", "Dictation", "DoNotDisturb", "Screenshot", "DisplaySwitch", "Sleep", "FnLock", "AuraCycle", "PerformanceMode", "TouchpadToggle", "AirplaneMode"];
    public static readonly string[] Modifiers = ["ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight"];
    public static readonly string[] FunctionKeys = ["Fn", "BrightnessDown", "BrightnessUp", "KeyboardBrightnessDown", "KeyboardBrightnessUp", "VolumeMute", "VolumeDown", "VolumeUp", "MediaPlayPause", "MediaNext", "MediaPrevious", "MediaFastForward", "MediaRewind", "MediaStop", "MissionControl", "Spotlight", "Dictation", "DoNotDisturb", "Screenshot", "DisplaySwitch", "Sleep", "FnLock", "AuraCycle", "PerformanceMode", "TouchpadToggle", "AirplaneMode"];
    public static bool CanInject(string key, string platform) => platform == "macos"
        ? !new[] { "PrintScreen", "ContextMenu", "F21", "F22", "F23", "F24", "DisplaySwitch", "FnLock", "AuraCycle", "PerformanceMode", "TouchpadToggle", "Sleep", "MediaStop", "AirplaneMode" }.Contains(key)
        : !new[] { "FnLock", "MissionControl", "Spotlight", "Dictation", "DoNotDisturb" }.Contains(key);
    public static readonly IReadOnlyDictionary<string, string> MacFunctionSlots = new Dictionary<string, string>
    {
        ["BrightnessDown"] = "F1",
        ["BrightnessUp"] = "F2",
        ["MissionControl"] = "F3",
        ["Spotlight"] = "F4",
        ["Dictation"] = "F5",
        ["DoNotDisturb"] = "F6",
        ["MediaRewind"] = "F7",
        ["MediaPlayPause"] = "F8",
        ["MediaFastForward"] = "F9",
        ["VolumeMute"] = "F10",
        ["VolumeDown"] = "F11",
        ["VolumeUp"] = "F12"
    };
    public static string? MacFunction(string slot) => MacFunctionSlots.FirstOrDefault(p => p.Value == slot).Key;
    public static readonly IReadOnlyDictionary<string, string> WindowsFunctions = new Dictionary<string, string>
    {
        ["F1"] = "VolumeMute",
        ["F2"] = "KeyboardBrightnessDown",
        ["F3"] = "KeyboardBrightnessUp",
        ["F4"] = "AuraCycle",
        ["F5"] = "PerformanceMode",
        ["F6"] = "Screenshot",
        ["F7"] = "BrightnessDown",
        ["F8"] = "BrightnessUp",
        ["F9"] = "DisplaySwitch",
        ["F10"] = "TouchpadToggle",
        ["F11"] = "DoNotDisturb",
        ["F12"] = "AirplaneMode"
    };
    public static string? WindowsFunction(string slot) => WindowsFunctions.GetValueOrDefault(slot);
    public static string Map(string key, string from, string to, KeyboardConfig? config, bool fnDown = false, Func<string, string?>? functionKey = null, bool fnEnabled = true, bool functionKeysEnabled = true, string? functionSlot = null)
    {
        if (from == to || from is not ("windows" or "macos") || to is not ("windows" or "macos"))
            return key;
        var sourceSlot = from == "windows" && functionSlot is not null && WindowsFunctions.ContainsKey(functionSlot) ? functionSlot : null;
        if (!functionKeysEnabled)
        {
            var plainSlot = sourceSlot ?? (from == "macos" ? MacFunctionSlots.GetValueOrDefault(key, key) : WindowsFunctions.FirstOrDefault(p => p.Value == key).Key ?? key);
            if (plainSlot.StartsWith("F", StringComparison.Ordinal) && int.TryParse(plainSlot.AsSpan(1), out var f) && f is >= 1 and <= 12)
                return plainSlot;
        }
        var custom = to == "macos" ? config?.WindowsToMac : config?.MacToWindows;
        var slot = from == "macos" ? MacFunctionSlots.GetValueOrDefault(key, key) : sourceSlot ?? key;
        // Keep legacy semantic overrides, then consult the visible F key's mapping.
        var mapped = custom?.GetValueOrDefault(key) ?? (slot != key ? custom?.GetValueOrDefault(slot) : null);
        if (from == "macos" && to == "windows")
        {
            if (slot != key)
            {
                var candidate = mapped ?? slot;
                if (WindowsFunctions.ContainsKey(candidate) || candidate == "F12")
                    mapped = (functionKey ?? WindowsFunction)(candidate) ?? NoAction;
            }
            if (mapped is not null)
                return CanInject(mapped, to) && (fnEnabled || mapped != "Fn") && (functionKeysEnabled || mapped == "Fn" || !FunctionKeys.Contains(mapped)) ? mapped : NoAction;
            if (key == "Fn")
                return "ControlLeft";
            if (key.StartsWith("Control", StringComparison.Ordinal))
                return fnEnabled ? "Fn" : NoAction;
            if (key.StartsWith("Alt", StringComparison.Ordinal))
                return key.Replace("Alt", "Meta");
            if (key.StartsWith("Meta", StringComparison.Ordinal))
                return key.Replace("Meta", "Alt");
            return !functionKeysEnabled && FunctionKeys.Contains(key) ? NoAction : key;
        }
        if (sourceSlot is not null && to == "macos")
        {
            var candidate = mapped ?? sourceSlot;
            if (MacFunctionSlots.Values.Contains(candidate))
                mapped = fnEnabled ? MacFunction(candidate) ?? NoAction : candidate;
        }
        if (sourceSlot is null && fnDown && fnEnabled && functionKeysEnabled && functionKey is not null)
        {
            var candidate = mapped ?? slot;
            if (candidate.StartsWith("F", StringComparison.Ordinal) && int.TryParse(candidate.AsSpan(1), out var number) && number is >= 1 and <= 12)
                mapped = functionKey(candidate) ?? NoAction;
        }
        if (mapped is not null)
            return CanInject(mapped, to) && (fnEnabled || mapped != "Fn") && (functionKeysEnabled || mapped == "Fn" || !FunctionKeys.Contains(mapped)) ? mapped : NoAction;
        if (!CanInject(key, to) || !fnEnabled && key == "Fn" || !functionKeysEnabled && key != "Fn" && FunctionKeys.Contains(key))
            return NoAction;
        if (key.StartsWith("Control", StringComparison.Ordinal))
            return key.Replace("Control", "Meta");
        if (key.StartsWith("Meta", StringComparison.Ordinal))
            return key.Replace("Meta", "Control");
        return key;
    }
    public static bool Valid(KeyboardConfig[] configs, IEnumerable<string> members, string selected) => configs.Length is > 0 and <= 64
        && configs.Select(c => c.Id).Distinct().Count() == configs.Length && configs.Any(c => c.Id == selected)
        && configs.All(c => Guid.TryParse(c.Id, out _) && Guid.TryParse(c.OwnerPeerID, out _) && c.Name.Length > 0 && System.Text.Encoding.UTF8.GetByteCount(c.Name) <= 128
            && new[] { c.WindowsToMac, c.MacToWindows }.All(m => m.Count <= Keys.Length && m.All(p => Keys.Contains(p.Key) && (Keys.Contains(p.Value) || p.Value == NoAction))));
    public static bool Same(KeyboardConfig? a, KeyboardConfig? b) => a is null ? b is null : b is not null && a.Id == b.Id
        && a.WindowsToMac.OrderBy(p => p.Key).SequenceEqual(b.WindowsToMac.OrderBy(p => p.Key)) && a.MacToWindows.OrderBy(p => p.Key).SequenceEqual(b.MacToWindows.OrderBy(p => p.Key));
    public static string? Command(string key, IEnumerable<string> held, string from, string to, KeyboardConfig? config, bool fnEnabled = true, bool functionKeysEnabled = true)
    {
        var overrides = from == "windows" && to == "macos" ? config?.WindowsToMac : from == "macos" && to == "windows" ? config?.MacToWindows : null;
        if (overrides?.ContainsKey(key) == true)
            return null;
        var physical = held.ToArray();
        if (from != to && !(from == "macos" && to == "windows") && !physical.Any(k => overrides?.ContainsKey(k) == true))
        {
            var control = physical.Any(k => k.StartsWith("Control", StringComparison.Ordinal));
            var meta = physical.Any(k => k.StartsWith("Meta", StringComparison.Ordinal));
            if (control && (from == "macos" || meta) && key is "ArrowLeft" or "ArrowRight")
                return key == "ArrowLeft" ? "desktopPrevious" : "desktopNext";
            if (from == "macos" && control && key == "ArrowUp" || from == "windows" && meta && key == "Tab")
                return "overview";
        }
        var mapped = physical.Where(k => k != key).Select(k => Map(k, from, to, config, fnEnabled: fnEnabled, functionKeysEnabled: functionKeysEnabled)).Where(k => k != NoAction && k != "Fn").ToArray();
        var modifier = to == "macos" ? "Meta" : "Control";
        if (to is not ("windows" or "macos") || !mapped.Any(k => k.StartsWith(modifier, StringComparison.Ordinal)))
            return null;
        if (key == "KeyZ" && mapped.All(k => k.StartsWith(modifier, StringComparison.Ordinal) || k.StartsWith("Shift", StringComparison.Ordinal)))
            return mapped.Any(k => k.StartsWith("Shift", StringComparison.Ordinal)) ? "redo" : "undo";
        if (mapped.Any(k => !k.StartsWith(modifier, StringComparison.Ordinal)))
            return null;
        if (key == "KeyY" && from == "windows")
            return "redo";
        return key switch
        {
            "KeyC" => "copy",
            "KeyX" => "cut",
            "KeyV" => "paste",
            _ => null
        };
    }
}
