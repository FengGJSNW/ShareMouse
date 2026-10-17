namespace ShareMouse.Core;

public sealed class InputRoutePolicy
{
    private sealed record Sample(double Mean, double Jitter, int Count, double At);
    private readonly Dictionary<string, Sample> samples = new();
    private string? current; private double switched = double.NegativeInfinity, lastInput = double.NegativeInfinity;
    public void Observe(string kind, double milliseconds, double now)
    {
        if (!double.IsFinite(milliseconds) || milliseconds < 0 || milliseconds >= 20000)
            return;
        samples[kind] = samples.TryGetValue(kind, out var old) ? new(old.Mean * .75 + milliseconds * .25, old.Jitter * .75 + Math.Abs(milliseconds - old.Mean) * .25, old.Count + 1, now) : new(milliseconds, 0, 1, now);
    }
    public void ResetPreference() => current = null;
    public string? Choose(IEnumerable<string> available, bool bluetoothPreferred, double now)
    {
        var set = available.ToHashSet();
        if (set.Contains("quic"))
            set.Remove("tcp");
        var order = bluetoothPreferred ? new[] { "ble", "quic", "tcp" } : new[] { "quic", "tcp", "ble" };
        var fallback = order.FirstOrDefault(set.Contains);
        if (fallback is null)
        {
            current = null;
            return null;
        }
        if (current is not { } previous || !set.Contains(previous))
        {
            current = fallback;
            switched = lastInput = now;
            return fallback;
        }
        var idle = now - lastInput;
        lastInput = now;
        if (idle < .5 || now - switched < 10)
            return previous;
        var measured = set.Where(k => samples.TryGetValue(k, out var s) && s.Count >= 3 && now - s.At < 16).ToArray();
        if (!measured.Contains(previous) || measured.Length < 2)
            return previous;
        double Score(string k)
        {
            var s = samples[k];
            var preferred = bluetoothPreferred ? k == "ble" : k != "ble";
            return s.Mean + s.Jitter + (preferred ? 0 : 20) + (k == "tcp" ? 1 : 0);
        }
        var next = measured.MinBy(Score)!;
        if (next == previous || Score(next) + 5 >= Score(previous))
            return previous;
        current = next;
        switched = now;
        return next;
    }
}
