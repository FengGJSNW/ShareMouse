namespace ShareMouse.Core;

/// File admission responds to input ACK tails; already encrypted bytes are never reordered.
public sealed class FileWindowPolicy
{
    private readonly Queue<(double At, double Ms)> samples = new();
    private string? kind;
    private double baseline = double.PositiveInfinity, changed = double.NegativeInfinity, activity = double.NegativeInfinity,
        pressureUntil = double.NegativeInfinity, remoteAt = double.NegativeInfinity;
    private int count = 8, remoteCount = 8;
    private ulong remoteSequence;
    public void MarkInput(double now) => activity = now;
    public void Congested(double now)
    {
        if (now >= pressureUntil)
        {
            count = Math.Max(1, count / 2);
            changed = now;
        }
        pressureUntil = now + .5;
    }
    public void Observe(string transport, double milliseconds, double now)
    {
        if (!double.IsFinite(milliseconds) || milliseconds < 0 || milliseconds >= 20000)
            return;
        activity = now;
        if (kind != transport)
        {
            kind = transport;
            samples.Clear();
            baseline = double.PositiveInfinity;
            count = Math.Min(count, 4);
        }
        baseline = Math.Min(baseline, milliseconds);
        while (samples.Count > 0 && now - samples.Peek().At > 1)
            samples.Dequeue();
        if (samples.Count >= 64)
            samples.Dequeue();
        samples.Enqueue((now, milliseconds));
        if (samples.Count < 8 || now - changed < .5)
            return;
        var values = samples.Select(s => s.Ms).Order().ToArray();
        var p95 = values[Math.Min(values.Length - 1, (int)Math.Ceiling(values.Length * .95) - 1)];
        var p99 = values[^1];
        if (p95 > Math.Min(60, Math.Max(35, baseline + 30)) || p99 > Math.Min(90, Math.Max(60, baseline + 50)))
            Congested(now);
        else if (p95 < Math.Min(45, baseline + 20) && p99 < Math.Min(65, baseline + 30) && now >= pressureUntil)
        {
            count = Math.Min(8, count + 1);
            changed = now;
        }
    }
    public void RemoteLimit(int limit, ulong sequence, double now)
    {
        if (limit is < 1 or > 8 || sequence <= remoteSequence)
            return;
        remoteCount = limit;
        remoteAt = now;
        remoteSequence = sequence;
    }
    public int LocalWindow(double now)
    {
        if (count < 8 && now > pressureUntil && now - activity >= .3 && now - changed >= .5)
        {
            count++;
            changed = now;
        }
        return count;
    }
    public int Window(double now) => Math.Min(LocalWindow(now), now - remoteAt < 3 ? remoteCount : 8);
}
