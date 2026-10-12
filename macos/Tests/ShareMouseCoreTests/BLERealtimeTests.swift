import XCTest
@testable import ShareMouseCore
final class BLERealtimeTests: XCTestCase {
    func testReorderedFragmentsAndAdaptiveWindow() throws {
        var sender = BLEStreamFraming(), receiver = BLEStreamFraming()
        let packets = (0..<32).map { sender.encode(Data(repeating: UInt8($0), count: 500)) }
        var restored = Data()
        for index in stride(from: 0, to: 32, by: 2) {
            XCTAssertTrue(try receiver.receive(packets[index + 1]).isEmpty)
            for bytes in try receiver.receive(packets[index]) { restored.append(bytes) }
        }
        XCTAssertEqual(restored, Data((0..<32).flatMap { Array(repeating: UInt8($0), count: 500) }))
        XCTAssertEqual(receiver.reordered, 16)
        XCTAssertTrue(try receiver.receive(packets[0]).isEmpty)
        XCTAssertEqual(packets[0].prefix(12), Data([83,66,70,49,0,0,0,0,0,0,0,0]))
        var window = BLEMotionWindow()
        for _ in 0..<16 { window.acknowledged(seconds: 0.045) }
        XCTAssertEqual(window.capacity(targetRate: 240), 13)
        XCTAssertEqual(window.capacity(targetRate: 60), 5)
        XCTAssertTrue(window.allows(count: 12, targetRate: 240, oldestAge: 0.045))
        XCTAssertFalse(window.allows(count: 2, targetRate: 240, oldestAge: 0.081))
        window.acknowledged(seconds: 0.300)
        XCTAssertEqual(window.capacity(targetRate: 240), 13, "Congestion must not expand the queue")
    }
}
