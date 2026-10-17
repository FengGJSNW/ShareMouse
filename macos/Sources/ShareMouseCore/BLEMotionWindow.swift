import Foundation

public struct BLEMotionWindow {
    private var roundTrips: [Double] = []
    public init() {}
    public mutating func acknowledged(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        roundTrips.append(seconds);
        if roundTrips.count > 32 { roundTrips.removeFirst() }
    }
    public func capacity(targetRate: Int) -> Int {
        let sorted = roundTrips.sorted()
        let baseline = sorted.isEmpty ? 0.020 : sorted[sorted.count / 5]
        // Cover normal RTT; a congested tail must not expand the queue indefinitely.
        return max(3, min(16, Int(ceil(min(0.060, baseline) * Double(targetRate))) + 2))
    }
    public func allows(count: Int, targetRate: Int, oldestAge: Double) -> Bool {
        count < capacity(targetRate: targetRate) && (count == 0 || oldestAge < 0.080)
    }
}
