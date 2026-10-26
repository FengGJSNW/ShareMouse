import XCTest

@testable import ShareMouseCore

final class SharingShortcutTests: XCTestCase {
    @MainActor func testNativeEditorCutPassesThroughAndOnlyFileCutIsConsumed() {
        let shortcut = ClipboardShortcut(platform: "macos")
        var filesSelected = false, fileCuts = 0, pasteQueries = 0
        shortcut.cutFiles = {
            guard filesSelected else { return false }
            fileCuts += 1
            return true
        }
        func capture(_ event: CapturedInput) -> Bool {
            shortcut.capture(
                event,
                active: {
                    pasteQueries += 1;
                    return false
                }())
        }
        for modifier in ["MetaLeft", "MetaRight"] {
            XCTAssertFalse(capture(CapturedInput("keyDown", key: modifier)))
            for _ in 0..<3 { XCTAssertFalse(capture(CapturedInput("keyDown", key: "KeyX"))) }
            XCTAssertFalse(capture(CapturedInput("keyUp", key: "KeyX")))
            XCTAssertFalse(capture(CapturedInput("keyUp", key: modifier)))
        }
        XCTAssertEqual(fileCuts, 0, "An editor owns its Cut even without an AX selection")
        XCTAssertEqual(pasteQueries, 0, "Native Cut must not query or fetch a shared pasteboard")
        filesSelected = true
        XCTAssertFalse(capture(CapturedInput("keyDown", key: "MetaLeft")))
        for _ in 0..<8 { XCTAssertTrue(capture(CapturedInput("keyDown", key: "KeyX"))) }
        XCTAssertTrue(capture(CapturedInput("keyUp", key: "KeyX")))
        XCTAssertEqual(fileCuts, 1, "A held file Cut starts only one transaction")
        filesSelected = false
        XCTAssertFalse(capture(CapturedInput("keyDown", key: "KeyX")))
        XCTAssertFalse(capture(CapturedInput("keyUp", key: "KeyX")))
    }
    @MainActor func testMacEmergencyChordReservesCommandAndSwappedPhysicalCommand() {
        for (modifiers, swapped) in [
            (["MetaLeft", "ControlRight", "ShiftLeft"], false), (["Fn", "ControlLeft", "ShiftRight"], true),
            (["MetaRight", "ControlLeft", "ShiftRight"], true), (["AltLeft", "ControlRight", "ShiftLeft"], false),
        ] {
            let shortcut = SharingShortcut(platform: "macos")
            var toggles = 0
            shortcut.toggle = { toggles += 1 }
            func capture(_ input: CapturedInput) -> Bool {
                shortcut.capture(
                    input, sourceKey: { MacInputAdapter.sourceKey($0, to: "windows", fnCommandSwapped: swapped) })
            }
            for key in modifiers { XCTAssertFalse(capture(CapturedInput("keyDown", key: key))) }
            for _ in 0..<10 { XCTAssertTrue(capture(CapturedInput("keyDown", key: "Escape"))) }
            XCTAssertEqual(toggles, 1, "A held emergency chord must not reconnect on auto-repeat")
            XCTAssertTrue(capture(CapturedInput("keyUp", key: "Escape")))
            for key in modifiers.reversed() { _ = capture(CapturedInput("keyUp", key: key)) }
            XCTAssertFalse(capture(CapturedInput("keyDown", key: "Escape")))
        }
        for platform in ["macos", "windows"] {
            XCTAssertFalse(
                SharingShortcut.isEmergencyChord(["ControlLeft", "ShiftLeft"], platform: platform),
                "Ctrl+Shift+Esc must remain available to the target")
        }
        XCTAssertFalse(SharingShortcut.isEmergencyChord(["MetaLeft", "ControlLeft", "ShiftLeft"], platform: "windows"))
    }
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
