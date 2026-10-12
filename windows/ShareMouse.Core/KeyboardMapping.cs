namespace ShareMouse.Core;

public static class KeyboardMapping {
    public const string NoAction="NoAction";
    public static readonly string[] Keys = ["KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ", "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Backquote", "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash", "ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight", "Escape", "Tab", "CapsLock", "Backspace", "Enter", "Space", "Insert", "Delete", "Home", "End", "PageUp", "PageDown", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PrintScreen", "ContextMenu", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"];
    public static readonly string[] Modifiers = ["ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight"];
    public static string Map(string key, string from, string to, KeyboardConfig? config) {
        if (from == to || from is not ("windows" or "macos") || to is not ("windows" or "macos")) return key;
        var custom = to == "macos" ? config?.WindowsToMac : config?.MacToWindows;
        if (custom?.TryGetValue(key, out var mapped) == true) return to=="macos" && mapped is "PrintScreen" or "ContextMenu" ? NoAction : mapped;
        if(to=="macos" && key is "PrintScreen" or "ContextMenu")return NoAction;
        if (key.StartsWith("Control", StringComparison.Ordinal)) return key.Replace("Control", "Meta");
        if (key.StartsWith("Meta", StringComparison.Ordinal)) return key.Replace("Meta", "Control");
        return key;
    }
    public static bool Valid(KeyboardConfig[] configs, IEnumerable<string> members, string selected) => configs.Length is > 0 and <= 64
        && configs.Select(c=>c.Id).Distinct().Count()==configs.Length && configs.Any(c=>c.Id==selected)
        && configs.All(c=>Guid.TryParse(c.Id,out _) && Guid.TryParse(c.OwnerPeerID,out _) && c.Name.Length>0 && System.Text.Encoding.UTF8.GetByteCount(c.Name)<=128
            && new[]{c.WindowsToMac,c.MacToWindows}.All(m=>m.Count<=Keys.Length && m.All(p=>Keys.Contains(p.Key) && (Keys.Contains(p.Value)||p.Value==NoAction))));
    public static bool Same(KeyboardConfig? a,KeyboardConfig? b) => a is null ? b is null : b is not null && a.Id==b.Id
        && a.WindowsToMac.OrderBy(p=>p.Key).SequenceEqual(b.WindowsToMac.OrderBy(p=>p.Key)) && a.MacToWindows.OrderBy(p=>p.Key).SequenceEqual(b.MacToWindows.OrderBy(p=>p.Key));
    public static string? Command(string key, IEnumerable<string> held, string from, string to, KeyboardConfig? config) {
        var overrides=from=="windows"&&to=="macos"?config?.WindowsToMac:from=="macos"&&to=="windows"?config?.MacToWindows:null;
        if(overrides?.ContainsKey(key)==true)return null;
        var physical=held.ToArray();
        if(from!=to && !physical.Any(k=>overrides?.ContainsKey(k)==true)) {
            var control=physical.Any(k=>k.StartsWith("Control",StringComparison.Ordinal)); var meta=physical.Any(k=>k.StartsWith("Meta",StringComparison.Ordinal));
            if(control && (from=="macos" || meta) && key is "ArrowLeft" or "ArrowRight") return key=="ArrowLeft"?"desktopPrevious":"desktopNext";
            if(from=="macos" && control && key=="ArrowUp" || from=="windows" && meta && key=="Tab") return "overview";
        }
        var mapped=physical.Where(k=>k!=key).Select(k=>Map(k,from,to,config)).Where(k=>k!=NoAction).ToArray();
        var modifier=to=="macos"?"Meta":"Control";
        if (to is not ("windows" or "macos") || !mapped.Any(k=>k.StartsWith(modifier,StringComparison.Ordinal))) return null;
        if(key=="KeyZ" && mapped.All(k=>k.StartsWith(modifier,StringComparison.Ordinal)||k.StartsWith("Shift",StringComparison.Ordinal))) return mapped.Any(k=>k.StartsWith("Shift",StringComparison.Ordinal))?"redo":"undo";
        if(mapped.Any(k=>!k.StartsWith(modifier,StringComparison.Ordinal))) return null;
        if(key=="KeyY" && from=="windows") return "redo";
        return key switch { "KeyC"=>"copy", "KeyX"=>"cut", "KeyV"=>"paste", _=>null };
    }
}
