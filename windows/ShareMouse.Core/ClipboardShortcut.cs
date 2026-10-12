namespace ShareMouse.Core;
public sealed class ClipboardShortcut(string platform) {
    private readonly HashSet<string> held=new(),consumed=new();
    private readonly string modifier=platform=="macos"?"Meta":"Control";
    public Action? Paste { get; set; }
    public bool Capture(CapturedInput input,bool active) {
        if(input.Key is not {} key || input.Type is not ("keyDown" or "keyUp")) return false;
        if(input.Type=="keyUp") { held.Remove(key); return consumed.Remove(key); }
        held.Add(key); if(consumed.Contains(key)) return true;
        var modifiers=held.Where(k=>k!=key).ToArray();
        if(active && key=="KeyV" && modifiers.Length>0 && modifiers.All(k=>k.StartsWith(modifier,StringComparison.Ordinal))) { consumed.Add(key); Paste?.Invoke(); return true; }
        return false;
    }
    public void Reset() { held.Clear(); consumed.Clear(); }
}
