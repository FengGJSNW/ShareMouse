namespace ShareMouse.Core;

public sealed record LatencySample(int Index, double Seconds, double? Milliseconds);
public sealed record LinkLatency(string Kind, LatencySample[] Samples)
{
    public double[] Values => Samples.Where(s => s.Milliseconds.HasValue).Select(s => s.Milliseconds!.Value).ToArray();
    public double Average => Values.Length == 0 ? 0 : Values.Average();
    public double P95 => Values.Length == 0 ? 0 : Values.Order().ElementAt(Math.Min(Values.Length - 1, (int)(Values.Length * .95)));
    public double P99 => Values.Length == 0 ? 0 : Values.Order().ElementAt(Math.Min(Values.Length - 1, (int)(Values.Length * .99)));
    public double Maximum => Values.Length == 0 ? 0 : Values.Max();
    public double Jitter => Values.Length < 2 ? 0 : Values.Skip(1).Zip(Values, (a, b) => Math.Abs(a - b)).Average();
    public int Lost => Samples.Length - Values.Length;
    public string Label => Kind == "ble" ? "蓝牙" : "网络 " + Kind.ToUpperInvariant();
    public string Summary => Values.Length == 0 ? Label + "：未收到回应" : $"{Label}：RTT {Average:F1} ms · 抖动 {Jitter:F1} ms · P95 {P95:F1} ms · P99 {P99:F1} ms · 最大 {Maximum:F1} ms · 丢失 {Lost}/{Samples.Length}";
}
public sealed record LatencyProbe(string Type, string Token);

public sealed record LinkThroughput(string Kind, long Bytes, double Seconds, string? Error)
{
    public string Summary
    {
        get
        {
            var label = Kind == "ble" ? "蓝牙" : Kind == "quic" ? "网络 QUIC/UDP" : "网络 TCP";
            if (Bytes <= 0 || Seconds <= 0)
                return label + "：" + (Error ?? "未收到数据确认");
            var rate = Bytes / Seconds;
            return $"{label}：{(rate >= 1048576 ? rate / 1048576 : rate / 1024):F2} {(rate >= 1048576 ? "MiB/s" : "KiB/s")} · 已确认 {Bytes / 1024.0:F1} KiB · {Seconds:F1} 秒" + (Error is null ? "" : " · " + Error);
        }
    }
}
