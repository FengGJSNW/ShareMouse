import Foundation

public struct LatencySample: Sendable, Identifiable {
    public let index: Int
    public let seconds: Double
    public var milliseconds: Double?
    public var id: Int { index }
}
public struct LinkLatency: Sendable, Identifiable {
    public let kind: String
    public var samples: [LatencySample]
    public var id: String { kind }
    public var values: [Double] { samples.compactMap(\.milliseconds) }
    public var average: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    public var p95: Double {
        let v = values.sorted();
        return v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count) * 0.95))]
    }
    public var p99: Double {
        let v = values.sorted();
        return v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count) * 0.99))]
    }
    public var maximum: Double { values.max() ?? 0 }
    public var jitter: Double {
        let v = values;
        return v.count < 2 ? 0 : zip(v.dropFirst(), v).map { abs($0 - $1) }.reduce(0, +) / Double(v.count - 1)
    }
    public var lost: Int { samples.count - values.count }
    public var label: String { kind == "ble" ? "蓝牙" : "网络 " + kind.uppercased() }
    public var summary: String {
        values.isEmpty
            ? label + "：未收到回应"
            : String(
                format: "%@：RTT %.1f ms · 抖动 %.1f ms · P95 %.1f ms · P99 %.1f ms · 最大 %.1f ms · 丢失 %d/%d", label,
                average, jitter, p95, p99, maximum, lost, samples.count)
    }
}
struct LatencyProbe: Codable {
    let type: String;
    let token: String
}

public struct LinkThroughput: Sendable {
    public let kind: String
    public let bytes: Int
    public let seconds: Double
    public let error: String?
    public var summary: String {
        let label = kind == "ble" ? "蓝牙" : kind == "quic" ? "网络 QUIC/UDP" : "网络 TCP"
        guard bytes > 0, seconds > 0 else { return label + "：" + (error ?? "未收到数据确认") }
        let rate = Double(bytes) / seconds
        return String(
            format: "%@：%.2f %@ · 已确认 %.1f KiB · %.1f 秒%@", label, rate >= 1048576 ? rate / 1048576 : rate / 1024,
            rate >= 1048576 ? "MiB/s" : "KiB/s", Double(bytes) / 1024, seconds, error.map { " · " + $0 } ?? "")
    }
}
