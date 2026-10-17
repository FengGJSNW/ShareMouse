import XCTest

@testable import ShareMouseCore

final class SharingShortcutTests: XCTestCase {
    @MainActor func testPasteboardQueryOnlyRunsForPasteChord() {
        let shortcut = ClipboardShortcut(platform: "macos");
        var queries = 0;
        var pastes = 0
        func query() -> Bool {
            queries += 1;
            return true
        }
        shortcut.paste = { pastes += 1 }
        for _ in 0..<500 {
            XCTAssertFalse(shortcut.capture(CapturedInput("move", deltaX: 1), active: query()))
            XCTAssertFalse(shortcut.capture(CapturedInput("scroll", deltaY: 1), active: query()))
        }
        XCTAssertFalse(shortcut.capture(CapturedInput("keyDown", key: "KeyV"), active: query()))
        _ = shortcut.capture(CapturedInput("keyUp", key: "KeyV"), active: query())
        XCTAssertEqual(queries, 0)
        _ = shortcut.capture(CapturedInput("keyDown", key: "MetaLeft"), active: query())
        XCTAssertTrue(shortcut.capture(CapturedInput("keyDown", key: "KeyV"), active: query()))
        XCTAssertTrue(shortcut.capture(CapturedInput("keyUp", key: "KeyV"), active: query()))
        XCTAssertEqual(queries, 1);
        XCTAssertEqual(pastes, 1)
    }
    @MainActor func testToggleWorksWhilePausedAndDoesNotRepeatUntilEscapeReleased() {
        let shortcut = SharingShortcut();
        var enabled = true;
        var toggles = 0
        shortcut.toggle = {
            enabled.toggle();
            toggles += 1
        }
        for key in ["ControlLeft", "AltRight", "ShiftLeft"] {
            XCTAssertFalse(shortcut.capture(CapturedInput("keyDown", key: key)))
        }
        XCTAssertTrue(shortcut.capture(CapturedInput("keyDown", key: "Escape")));
        XCTAssertFalse(enabled)
        for _ in 0..<10 { XCTAssertTrue(shortcut.capture(CapturedInput("keyDown", key: "Escape"))) }
        XCTAssertEqual(toggles, 1)
        XCTAssertTrue(shortcut.capture(CapturedInput("keyUp", key: "Escape")))
        XCTAssertTrue(shortcut.capture(CapturedInput("keyDown", key: "Escape")));
        XCTAssertTrue(enabled);
        XCTAssertEqual(toggles, 2)
        shortcut.reset()
        XCTAssertFalse(
            shortcut.capture(CapturedInput("keyDown", key: "Escape")), "MCP suspension must clear remembered modifiers")
    }
    @MainActor func testWindowsPasteUsesControlVAndRemoteCutIsNotCapturedLocally() {
        let windows = ClipboardShortcut(platform: "windows");
        var pastes = 0
        windows.paste = { pastes += 1 }
        _ = windows.capture(CapturedInput("keyDown", key: "MetaLeft"), active: true)
        XCTAssertFalse(windows.capture(CapturedInput("keyDown", key: "KeyV"), active: true));
        XCTAssertEqual(pastes, 0)
        windows.reset();
        _ = windows.capture(CapturedInput("keyDown", key: "ControlLeft"), active: true)
        XCTAssertTrue(windows.capture(CapturedInput("keyDown", key: "KeyV"), active: true));
        XCTAssertEqual(pastes, 1)
        let mac = ClipboardShortcut(platform: "macos");
        var cuts = 0
        mac.cutFiles = {
            cuts += 1;
            return true
        }
        _ = mac.capture(CapturedInput("keyDown", key: "MetaLeft"), active: false, allowCut: false)
        XCTAssertFalse(mac.capture(CapturedInput("keyDown", key: "KeyX"), active: false, allowCut: false));
        XCTAssertEqual(cuts, 0)
    }
}
