namespace ShareMouse.Core;

public sealed class SharingShortcut
{
    private readonly HashSet<string> held = new();
    private readonly HashSet<string> consumed = new();
    public Action? ToggleFn
    {
        get; set;
    }
    public Action? ToggleFunctions
    {
        get; set;
    }
    public Action? ToggleCrossing
    {
        get; set;
    }
    public Action? Toggle
    {
        get; set;
    }
    public bool Capture(CapturedInput input)
    {
        if (input.Key is not { } key || input.Type is not ("keyDown" or "keyUp"))
            return false;
        if (input.Type == "keyUp")
        {
            held.Remove(key);
            return consumed.Remove(key);
        }
        held.Add(key);
        if (consumed.Contains(key))
            return true;
        if (!new[] { "Control", "Alt", "Shift" }.All(prefix => held.Any(k => k.StartsWith(prefix, StringComparison.Ordinal))))
            return false;
        var action = key switch
        {
            "Escape" => Toggle,
            "KeyF" => ToggleFn,
            "KeyG" => ToggleFunctions,
            "KeyL" => ToggleCrossing,
            _ => null
        };
        if (action is null)
            return false;
        consumed.Add(key);
        action();
        return true;
    }
    public void Reset()
    {
        held.Clear();
        consumed.Clear();
    }
}
