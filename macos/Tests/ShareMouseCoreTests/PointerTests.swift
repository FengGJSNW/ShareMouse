import XCTest

@testable import ShareMouseCore

final class PointerTests: XCTestCase {
    @MainActor func testRetinaNativeCoordinatesReachAllCaptureEdges() {
        XCTAssertEqual(MacInputAdapter.normalizedPosition(0, origin: 0, extent: 1470), 0)
        XCTAssertEqual(MacInputAdapter.normalizedPosition(1469, origin: 0, extent: 1470), 1)
        XCTAssertEqual(MacInputAdapter.normalizedPosition(955, origin: 0, extent: 956), 1)
        XCTAssertEqual(MacInputAdapter.normalizedPosition(735, origin: 0, extent: 1470), 0.5)
        XCTAssertEqual(MacInputAdapter.normalizedPosition(-1, origin: -1470, extent: 1470), 1)
    }
    func testContactSegmentAndScaleDetermineCrossing() {
        let a = ScreenGeometry(
            id: "a", peerID: "one", name: "A", number: 1, pixelWidth: 1000, pixelHeight: 720, primary: true, x: 0, y: 0)
        let b = ScreenGeometry(
            id: "b", peerID: "two", name: "B", number: 2, pixelWidth: 2000, pixelHeight: 1440, primary: true, x: 1000,
            y: 360)
        let outside = PointerState(screenID: "a", x: 999, y: 100, ownerPeerID: "one", epoch: 1)
        XCTAssertEqual(PointerRouter.move(outside, screens: [a, b], dx: 20, dy: 0).screenID, "a")
        XCTAssertEqual(PointerRouter.move(outside, screens: [a, b], dx: 20, dy: 200).y, 300, accuracy: 0.01)
        var inside = outside;
        inside.y = 500
        let crossed = PointerRouter.move(inside, screens: [a, b], dx: 20, dy: 0)
        XCTAssertEqual(crossed.screenID, "b");
        XCTAssertEqual(crossed.x, 1019, accuracy: 0.01)
        var scaled = a;
        scaled.scale = 2
        var aligned = b;
        aligned.x = 2000;
        aligned.y = 0
        let point = PointerState(screenID: "a", x: 1999, y: 1080, ownerPeerID: "one", epoch: 1)
        let result = PointerRouter.move(point, screens: [scaled, aligned], dx: 10, dy: 0)
        XCTAssertEqual(result.screenID, "b");
        XCTAssertEqual((result.y - aligned.y) / aligned.height, 0.75, accuracy: 0.001)
    }
}
