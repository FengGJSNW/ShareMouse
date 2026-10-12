import Foundation

/// Bounded file requests adapt to confirmed input delivery, before TLS bytes are queued.
public struct FileWindowPolicy: Sendable {
    private var samples: [(at: Double, ms: Double)] = []
    private var kind: String?
    private var baseline = Double.infinity
    private var count = 8
    private var changed = -Double.infinity
    private var activity = -Double.infinity
    private var pressureUntil = -Double.infinity
    private var remoteCount = 8
    private var remoteAt = -Double.infinity
    private var remoteSequence: UInt64 = 0
    public init() {}
    public mutating func markInput(now: Double) { activity = now }
    public mutating func congested(now: Double) {
        if now >= pressureUntil { count = max(1, count / 2); changed = now }
        pressureUntil = now + 0.5
    }
    public mutating func observe(_ transport: String, milliseconds: Double, now: Double) {
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 20_000 else { return }
        activity = now
        if kind != transport { kind = transport; samples = []; baseline = .infinity; count = min(count, 4) }
        baseline = min(baseline, milliseconds)
        samples.removeAll { now - $0.at > 1 }
        if samples.count >= 64 { samples.removeFirst() }
        samples.append((now, milliseconds))
        guard samples.count >= 8, now - changed >= 0.5 else { return }
        let values = samples.map(\.ms).sorted()
        let p95 = values[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)]
        let p99 = values.last!
        if p95 > min(60,max(35,baseline+30)) || p99 > min(90,max(60,baseline+50)) { congested(now: now) }
        else if p95 < min(45,baseline+20), p99 < min(65,baseline+30), now >= pressureUntil {
            count = min(8, count + 1); changed = now
        }
    }
    public mutating func remoteLimit(_ limit: Int, sequence: UInt64, now: Double) {
        guard (1...8).contains(limit), sequence > remoteSequence else { return }
        remoteCount = limit; remoteSequence = sequence; remoteAt = now
    }
    public mutating func localWindow(now: Double) -> Int {
        if count < 8, now > pressureUntil, now - activity >= 0.3, now - changed >= 0.5 { count += 1; changed = now }
        return count
    }
    public mutating func window(now: Double) -> Int {
        min(localWindow(now: now), now - remoteAt < 3 ? remoteCount : 8)
    }
}
