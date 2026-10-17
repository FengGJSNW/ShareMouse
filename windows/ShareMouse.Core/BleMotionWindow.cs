namespace ShareMouse.Core;

public sealed class BleMotionWindow
{
    private readonly Queue<double> roundTrips = new();
    public void Acknowledged(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds <= 0)
            return;
        roundTrips.Enqueue(seconds);
        if (roundTrips.Count > 32)
            roundTrips.Dequeue();
    }
    public int Capacity(int targetRate)
    {
        var sorted = roundTrips.Order().ToArray();
        var baseline = sorted.Length == 0 ? .020 : sorted[sorted.Length / 5];
        return Math.Clamp((int)Math.Ceiling(Math.Min(.060, baseline) * targetRate) + 2, 3, 16);
    }
    public bool Allows(int count, int targetRate, double oldestAge) => count < Capacity(targetRate) && (count == 0 || oldestAge < .080);
}
