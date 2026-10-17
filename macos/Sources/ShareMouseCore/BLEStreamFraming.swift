import Foundation

// GATT callback scheduling need not preserve delivery order across async handlers.
// These headers wrap TLS ciphertext only; TLS still authenticates all app data.
public struct BLEStreamFraming {
    private var sent: UInt64 = 0
    private var expected: UInt64 = 0
    private var waiting: [UInt64: Data] = [:]
    public private(set) var reordered = 0
    public private(set) var duplicates = 0
    public var nextExpected: UInt64 { expected }
    public var nextSent: UInt64 { sent }
    public var pendingCount: Int { waiting.count }
    public init() {}
    public mutating func encode(_ bytes: Data) -> Data {
        let frame = Data("SBF1".utf8) + MotionCodec.integer(sent) + bytes
        sent += 1;
        return frame
    }
    public mutating func receive(_ frame: Data) throws -> [Data] {
        guard frame.count > 12, frame.count <= 512, frame.prefix(4) == Data("SBF1".utf8) else {
            throw PairingError.invalidMessage
        }
        let sequence = MotionCodec.number(frame, 4, 8)
        if sequence < expected {
            duplicates += 1;
            return []
        }
        guard sequence - expected < 64 else { throw PairingError.invalidMessage }
        let payload = Data(frame.dropFirst(12))
        if let previous = waiting[sequence] {
            guard previous == payload else { throw PairingError.invalidMessage };
            return []
        }
        if sequence != expected { reordered += 1 }
        waiting[sequence] = payload
        var ordered: [Data] = []
        while let bytes = waiting.removeValue(forKey: expected) {
            ordered.append(bytes);
            expected += 1
        }
        return ordered
    }
}
