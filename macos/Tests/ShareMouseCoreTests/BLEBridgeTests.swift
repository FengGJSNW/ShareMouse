import Foundation
import Network
import XCTest
@testable import ShareMouseCore

final class BLEBridgeTests: XCTestCase {
    func testNotificationsBeforeLocalTLSConnectionPreserveOrder() async throws {
        let queue = DispatchQueue(label: "BLEBridgeRegression")
        let bridge = BLEByteBridge(queue: queue, forward: { _, done in done(nil) }, ended: {})
        let first = Data((0..<512).map { UInt8(truncatingIfNeeded: $0) })
        let second = Data(repeating: 0xA5, count: 512)
        let endpoint: NWEndpoint = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try bridge.listen { result in continuation.resume(with: result) }
                    bridge.receive(first); bridge.receive(second)
                } catch { continuation.resume(throwing: error) }
            }
        }
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1024, maximumLength: 1024) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
        XCTAssertEqual(bytes, first + second)
        connection.cancel(); queue.async { bridge.close() }
    }
}
