namespace ShareMouse.Core;

public sealed class SharingShortcut {
    private readonly HashSet<string> held=new();
    private bool consumed;
    public Action? Toggle {get;set;}
    public bool Capture(CapturedInput input) {
        if(input.Key is not {} key || input.Type is not ("keyDown" or "keyUp")) return false;
        if(input.Type=="keyUp") {held.Remove(key);if(key=="Escape" && consumed) {consumed=false;return true;}return false;}
        held.Add(key);if(key!="Escape")return false;if(consumed)return true;
        if(new[]{"Control","Alt","Shift"}.All(prefix=>held.Any(k=>k.StartsWith(prefix,StringComparison.Ordinal)))) {consumed=true;Toggle?.Invoke();return true;}
        return false;
    }
    public void Reset(){held.Clear();consumed=false;}
}
