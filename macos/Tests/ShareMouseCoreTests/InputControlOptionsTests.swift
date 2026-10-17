import XCTest

@testable import ShareMouseCore

final class InputControlOptionsTests: XCTestCase {
    func testHorizontalScrollAngleSuppressesNoiseWithContinuousOnset() {
        XCTAssertEqual(HorizontalScrollFilter.apply(5, dy: 10, angle: 30), 0)
        XCTAssertEqual(HorizontalScrollFilter.apply(10, dy: 10, angle: 45), 0, accuracy: 1e-12)
        XCTAssertEqual(HorizontalScrollFilter.apply(10.001, dy: 10, angle: 45), 0.001, accuracy: 1e-12)
        XCTAssertEqual(HorizontalScrollFilter.apply(-12, dy: -10, angle: 45), -2, accuracy: 1e-12)
        XCTAssertEqual(HorizontalScrollFilter.apply(12, dy: -10, angle: 45), 2, accuracy: 1e-12)
        XCTAssertEqual(HorizontalScrollFilter.apply(12, dy: 10, angle: 0), 12)
        XCTAssertEqual(
            HorizontalScrollFilter.apply(12, dy: 0, angle: 30), 12, "Pure horizontal movement remains available")
        XCTAssertEqual(
            HorizontalScrollFilter.apply(12, dy: 0, angle: 90), 0, "90 degrees disables horizontal scrolling")
        XCTAssertEqual(
            HorizontalScrollFilter.apply(24, dy: 20, angle: 45), 4, accuracy: 1e-12,
            "Angle does not depend on speed or frame size")
        XCTAssertEqual(
            HorizontalScrollFilter.apply(0, dy: 20, angle: 30), 0,
            "Vertical movement must not create horizontal rebound")
    }
    func testSwitchesDoNotRewriteMappingsOrDisableLocalKeys() throws {
        let custom = KeyboardConfig(
            id: UUID().uuidString, ownerPeerID: UUID().uuidString, name: "User", windowsToMac: [:],
            macToWindows: ["F3": "KeyA"])
        XCTAssertEqual(
            KeyboardMapping.map(
                "MissionControl", from: "macos", to: "windows", config: custom, functionKeysEnabled: false), "F3")
        XCTAssertEqual(KeyboardMapping.map("MissionControl", from: "macos", to: "windows", config: custom), "KeyA")
        XCTAssertEqual(
            KeyboardMapping.map("Fn", from: "macos", to: "windows", config: nil, fnEnabled: false), "ControlLeft")
        XCTAssertEqual(
            KeyboardMapping.map("ControlLeft", from: "macos", to: "windows", config: nil, fnEnabled: false),
            KeyboardMapping.noAction)
        XCTAssertEqual(
            KeyboardMapping.command(
                "KeyV", held: ["Fn", "KeyV"], from: "macos", to: "windows", config: nil, fnEnabled: false), "paste")
        XCTAssertEqual(KeyboardMapping.map("Fn", from: "macos", to: "macos", config: nil, fnEnabled: false), "Fn")
        XCTAssertEqual(
            KeyboardMapping.map(
                "F5", from: "windows", to: "macos", config: nil, fnDown: true, functionKey: KeyboardMapping.macFunction,
                functionKeysEnabled: false), "F5")
        var packet = InputPacket(type: "held", groupID: "group", sourcePeerID: "source", targetPeerID: "target")
        packet.fnEnabled = false;
        packet.functionKeysEnabled = false
        let decoded = try JSONDecoder().decode(InputPacket.self, from: JSONEncoder().encode(packet))
        XCTAssertEqual(decoded.fnEnabled, false);
        XCTAssertEqual(decoded.functionKeysEnabled, false)
        packet.fnEnabled = nil;
        packet.functionKeysEnabled = nil
        let legacy = try JSONDecoder().decode(InputPacket.self, from: JSONEncoder().encode(packet))
        XCTAssertNil(legacy.fnEnabled)
    }
    @MainActor func testIndependentHotkeysConsumeRepeatAndPreservePauseChord() {
        let shortcuts = SharingShortcut();
        var changes = [0, 0, 0, 0]
        shortcuts.toggle = { changes[0] += 1 };
        shortcuts.toggleFn = { changes[1] += 1 };
        shortcuts.toggleFunctions = { changes[2] += 1 };
        shortcuts.toggleCrossing = { changes[3] += 1 }
        for modifier in ["ControlLeft", "AltLeft", "ShiftRight"] {
            _ = shortcuts.capture(CapturedInput("keyDown", key: modifier))
        }
        for (i, key) in ["Escape", "KeyF", "KeyG", "KeyL"].enumerated() {
            for _ in 0..<8 { XCTAssertTrue(shortcuts.capture(CapturedInput("keyDown", key: key))) }
            XCTAssertEqual(changes[i], 1);
            XCTAssertTrue(shortcuts.capture(CapturedInput("keyUp", key: key)))
        }
        shortcuts.reset();
        XCTAssertFalse(shortcuts.capture(CapturedInput("keyDown", key: "KeyL")))
    }
}
