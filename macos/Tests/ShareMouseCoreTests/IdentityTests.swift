import Foundation
import XCTest
@testable import ShareMouseCore

final class IdentityTests: XCTestCase {
    func testRestartPreservesIdentityAndCorruptionIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PeerIdentityStore(directory: directory)
        let original = try store.loadOrCreate()
        XCTAssertEqual(original, try PeerIdentityStore(directory: directory).loadOrCreate())
        let file = directory.appendingPathComponent("peer-id")
        try "invalid".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.loadOrCreate())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
    }
}
