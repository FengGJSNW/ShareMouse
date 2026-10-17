import XCTest

@testable import ShareMouseCore

final class FileWindowTests: XCTestCase {
    func testTailPressureRecoveryAndPeerHintExpiry() {
        var policy = FileWindowPolicy()
        XCTAssertEqual(policy.window(now: 0), 8)
        for i in 0..<8 { policy.observe("quic", milliseconds: 80, now: Double(i) * 0.01) }
        XCTAssertEqual(policy.window(now: 0.08), 2, "An initially congested link must also shrink")
        policy.congested(now: 0.1);
        XCTAssertEqual(policy.window(now: 0.11), 2, "Duplicate pressure must not cause repeated halving")
        for i in 0..<64 { policy.observe("quic", milliseconds: 10, now: 1.2 + Double(i) * 0.01) }
        XCTAssertGreaterThan(policy.window(now: 1.85), 2)
        policy.remoteLimit(1, sequence: 100, now: 2);
        XCTAssertEqual(policy.window(now: 2), 1)
        policy.remoteLimit(8, sequence: 99, now: 2.1);
        XCTAssertEqual(policy.window(now: 2.1), 1)
        policy.remoteLimit(0, sequence: 101, now: 2.2);
        XCTAssertEqual(policy.window(now: 2.2), 1)
        XCTAssertGreaterThan(policy.window(now: 5.1), 1, "Expired peer pressure must not permanently throttle files")
        policy.observe("ble", milliseconds: 20, now: 6);
        XCTAssertLessThanOrEqual(policy.window(now: 6), 4)
    }
    func testRequestedChunkLimitSurvivesJSONCodec() throws {
        var request = FilePacket("chunk", groupID: "g", entryID: "e", taskID: "t")
        request.offset = 123;
        request.maximumBytes = 256
        for compact in [false, true] {
            let decoded = try FilePacketCodec.decode(
                FilePacketCodec.encode(request, compact: compact), compact: compact)
            XCTAssertEqual(decoded.maximumBytes, 256);
            XCTAssertEqual(decoded.offset, 123)
        }
    }
}
