import XCTest

@testable import ShareMouseCore

final class SessionMonitorTests: XCTestCase {
    @MainActor func testNativeMonitorCanReadRefreshAndRestartWithoutChangingSystemState() {
        let monitor = MacSessionMonitor()
        monitor.start()
        let lid = monitor.lidClosed, locked = monitor.screenLocked
        var changes = 0
        monitor.changed = { changes += 1 }
        monitor.refresh()
        XCTAssertEqual(monitor.lidClosed, lid)
        XCTAssertEqual(monitor.screenLocked, locked)
        XCTAssertEqual(changes, 0, "An unchanged snapshot must not repeatedly pause or resume input")
        monitor.stop();
        monitor.stop();
        monitor.start();
        monitor.stop()
    }
}
