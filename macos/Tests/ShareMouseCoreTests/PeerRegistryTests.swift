import Foundation
import XCTest

@testable import ShareMouseCore

final class PeerRegistryTests: XCTestCase {
    func testDeleteOneDevicePersistsWithoutChangingOtherIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try PeerRegistry(directory: directory)
        try registry.remember(CertificatePeer(peerID: "one", publicKey: "key-one"), name: "One")
        try registry.remember(CertificatePeer(peerID: "two", publicKey: "key-two"), name: "Two")
        try registry.setPreferences("one", trusted: true, autoConnect: true)
        try registry.remove("one")
        let restored = try PeerRegistry(directory: directory)
        XCTAssertNil(restored.find("one"));
        XCTAssertEqual(restored.all().count, 1)
        XCTAssertEqual(restored.find("two")?.publicKey, "key-two")
        XCTAssertEqual(restored.find("two")?.trust, .known);
        XCTAssertEqual(restored.find("two")?.autoConnect, false)
    }
}
