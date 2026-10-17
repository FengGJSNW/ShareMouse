import CoreGraphics
import XCTest

@testable import ShareMouseCore

final class KeyboardMappingTests: XCTestCase {
    func testWindowsFunctionSlotsUseMacPositionsAndPreserveOverrides() {
        for number in 1...12 {
            let slot = "F\(number)", source = KeyboardMapping.windowsFunctions[slot]!
            XCTAssertEqual(
                KeyboardMapping.map(source, from: "windows", to: "macos", config: nil, functionSlot: slot),
                KeyboardMapping.macFunction(slot))
            XCTAssertEqual(
                KeyboardMapping.map(
                    source, from: "windows", to: "macos", config: nil, fnEnabled: false, functionSlot: slot), slot)
            XCTAssertEqual(
                KeyboardMapping.map(
                    source, from: "windows", to: "macos", config: nil, functionKeysEnabled: false, functionSlot: slot),
                slot)
            XCTAssertEqual(KeyboardMapping.map(slot, from: "windows", to: "macos", config: nil), slot)
        }
        XCTAssertEqual(KeyboardMapping.map("VolumeMute", from: "windows", to: "macos", config: nil), "VolumeMute")
        var config = KeyboardConfig(
            id: UUID().uuidString, ownerPeerID: UUID().uuidString, name: "Custom", windowsToMac: ["F3": "KeyA"],
            macToWindows: [:])
        XCTAssertEqual(
            KeyboardMapping.map(
                "KeyboardBrightnessUp", from: "windows", to: "macos", config: config, functionSlot: "F3"), "KeyA")
        config.windowsToMac["KeyboardBrightnessUp"] = KeyboardMapping.noAction
        XCTAssertEqual(
            KeyboardMapping.map(
                "KeyboardBrightnessUp", from: "windows", to: "macos", config: config, functionSlot: "F3"),
            KeyboardMapping.noAction)
    }
    func testMacWindowsUsesWindowsFunctionLayerAndPlainFnF() {
        var config = KeyboardConfig(
            id: UUID().uuidString, ownerPeerID: UUID().uuidString, name: "Fn swap", windowsToMac: [:],
            macToWindows: ["Fn": "ControlLeft", "ControlLeft": "Fn"])
        for (key, action) in [
            ("BrightnessDown", "VolumeMute"), ("BrightnessUp", "KeyboardBrightnessDown"),
            ("MissionControl", "KeyboardBrightnessUp"), ("Spotlight", "AuraCycle"), ("Dictation", "PerformanceMode"),
            ("DoNotDisturb", "Screenshot"), ("MediaRewind", "BrightnessDown"), ("MediaPlayPause", "BrightnessUp"),
            ("MediaFastForward", "DisplaySwitch"), ("VolumeDown", "NoAction"), ("VolumeUp", "AirplaneMode"),
        ] { XCTAssertEqual(KeyboardMapping.map(key, from: "macos", to: "windows", config: config), action) }
        for i in 1...12 {
            XCTAssertEqual(
                KeyboardMapping.map(
                    "F\(i)", from: "macos", to: "windows", config: config, fnDown: true,
                    functionKey: KeyboardMapping.windowsFunction), "F\(i)")
        }
        for (key, action) in [
            ("Fn", "ControlLeft"), ("ControlLeft", "Fn"), ("ControlRight", "Fn"), ("AltLeft", "MetaLeft"),
            ("AltRight", "MetaRight"), ("MetaLeft", "AltLeft"), ("MetaRight", "AltRight"),
        ] { XCTAssertEqual(KeyboardMapping.map(key, from: "macos", to: "windows", config: nil), action) }
        config.macToWindows["F3"] = "KeyA"
        XCTAssertEqual(KeyboardMapping.map("MissionControl", from: "macos", to: "windows", config: config), "KeyA")
        XCTAssertEqual(KeyboardMapping.map("F3", from: "macos", to: "windows", config: config), "KeyA")
        config.macToWindows["MissionControl"] = "KeyB"
        XCTAssertEqual(KeyboardMapping.map("MissionControl", from: "macos", to: "windows", config: config), "KeyB")
        XCTAssertEqual(
            KeyboardMapping.command("KeyC", held: ["Fn", "KeyC"], from: "macos", to: "windows", config: nil), "copy")
        XCTAssertNil(
            KeyboardMapping.command("KeyC", held: ["MetaLeft", "KeyC"], from: "macos", to: "windows", config: nil))
        XCTAssertNil(
            KeyboardMapping.command(
                "ArrowUp", held: ["ControlLeft", "ArrowUp"], from: "macos", to: "windows", config: nil))
    }
    func testDirectionAndCustomCommand() {
        XCTAssertEqual(KeyboardMapping.map("ControlLeft", from: "windows", to: "macos", config: nil), "MetaLeft")
        let custom = KeyboardConfig(
            id: UUID().uuidString, ownerPeerID: UUID().uuidString, name: "Custom",
            windowsToMac: ["ControlLeft": "AltLeft"], macToWindows: [:])
        XCTAssertEqual(KeyboardMapping.map("ControlLeft", from: "windows", to: "macos", config: custom), "AltLeft")
        XCTAssertEqual(
            KeyboardMapping.map("ControlLeft", from: "windows", to: "windows", config: custom), "ControlLeft")
        XCTAssertEqual(
            KeyboardMapping.command("KeyC", held: ["ControlLeft", "KeyC"], from: "windows", to: "macos", config: nil),
            "copy")
        XCTAssertEqual(
            KeyboardMapping.command(
                "KeyZ", held: ["ControlLeft", "ShiftRight", "KeyZ"], from: "windows", to: "macos", config: nil), "redo")
        XCTAssertEqual(
            KeyboardMapping.command("KeyZ", held: ["Fn", "KeyZ"], from: "macos", to: "windows", config: nil), "undo")
        XCTAssertNil(
            KeyboardMapping.command(
                "KeyZ", held: ["ControlLeft", "KeyZ"], from: "windows", to: "macos", config: custom))
        XCTAssertNil(
            KeyboardMapping.command(
                "KeyC", held: ["ControlLeft", "KeyC"], from: "windows", to: "macos", config: custom))
    }
}
extension KeyboardMappingTests {
    @MainActor func testSystemFnCommandSwapKeepsPhysicalCtrlAndAltAssignments() async {
        let rows: [[String: UInt64]] = [
            ["HIDKeyboardModifierMappingSrc": 0x7000000e3, "HIDKeyboardModifierMappingDst": 0xff00000003],
            ["HIDKeyboardModifierMappingSrc": 0xff0100000003, "HIDKeyboardModifierMappingDst": 0x7000000e7],
        ]
        XCTAssertTrue(MacInputAdapter.fnCommandSwapped(rows))
        XCTAssertFalse(MacInputAdapter.fnCommandSwapped([]))
        XCTAssertFalse(MacInputAdapter.fnCommandSwapped([rows[0]]))
        func target(_ key: String, _ swapped: Bool) -> String {
            KeyboardMapping.map(
                MacInputAdapter.sourceKey(key, to: "windows", fnCommandSwapped: swapped), from: "macos", to: "windows",
                config: nil)
        }
        XCTAssertEqual(target("MetaLeft", false), "AltLeft")
        XCTAssertEqual(target("Fn", false), "ControlLeft")
        XCTAssertEqual(target("Fn", true), "AltLeft")
        XCTAssertEqual(target("MetaRight", true), "ControlLeft")
        XCTAssertEqual(target("ControlLeft", true), "Fn")
        XCTAssertEqual(target("AltLeft", true), "MetaLeft")
        for key in ["Fn", "MetaRight", "KeyV"] {
            XCTAssertEqual(MacInputAdapter.sourceKey(key, to: "macos", fnCommandSwapped: true), key)
        }
        let ctrl = MacInputAdapter.sourceKey("MetaRight", to: "windows", fnCommandSwapped: true)
        XCTAssertEqual(
            KeyboardMapping.command("KeyV", held: [ctrl, "KeyV"], from: "macos", to: "windows", config: nil), "paste")
        XCTAssertEqual(KeyboardMapping.map("Equal", from: "macos", to: "windows", config: nil), "Equal")
    }
    func testFullKeyMappingNoActionAndDirections() throws {
        let owner = UUID().uuidString, id = UUID().uuidString
        var config = KeyboardConfig(
            id: id, ownerPeerID: owner, name: "双向",
            windowsToMac: ["KeyA": "KeyB", "ControlLeft": "ControlRight", "MetaRight": "NoAction", "F12": "F1"],
            macToWindows: ["KeyA": "KeyC", "ShiftLeft": "ShiftRight"])
        XCTAssertTrue(KeyboardMapping.valid([config], members: [], selected: id))
        XCTAssertEqual(KeyboardMapping.map("KeyA", from: "windows", to: "macos", config: config), "KeyB")
        XCTAssertEqual(KeyboardMapping.map("KeyA", from: "macos", to: "windows", config: config), "KeyC")
        XCTAssertEqual(KeyboardMapping.map("ControlLeft", from: "windows", to: "macos", config: config), "ControlRight")
        XCTAssertEqual(KeyboardMapping.map("MetaRight", from: "windows", to: "macos", config: config), "NoAction")
        XCTAssertEqual(KeyboardMapping.map("F12", from: "windows", to: "macos", config: config), "F1")
        config.macToWindows["ControlLeft"] = "NoAction"
        XCTAssertNil(
            KeyboardMapping.command(
                "ArrowUp", held: ["ControlLeft", "ArrowUp"], from: "macos", to: "windows", config: config))
        config.windowsToMac["KeyC"] = "KeyB"
        XCTAssertNil(
            KeyboardMapping.command(
                "KeyC", held: ["ControlRight", "KeyC"], from: "windows", to: "macos", config: config))
        config.windowsToMac.removeValue(forKey: "ControlLeft")
        XCTAssertEqual(KeyboardMapping.map("ControlLeft", from: "windows", to: "macos", config: config), "MetaLeft")
        let restored = try JSONDecoder().decode(KeyboardConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.id, id);
        XCTAssertEqual(restored.macToWindows, config.macToWindows)
        config.macToWindows["Fn"] = "KeyA"
        XCTAssertTrue(KeyboardMapping.valid([config], members: [owner], selected: id))
    }
    func testAdaptiveRouteDoesNotOscillateDuringContinuousInput() {
        var policy = InputRoutePolicy()
        XCTAssertEqual(policy.choose(["tcp", "ble"], bluetoothPreferred: true, now: 0), "ble")
        for t in [5.0, 10, 15] {
            policy.observe("ble", milliseconds: 90, now: t);
            policy.observe("tcp", milliseconds: 10, now: t)
        }
        for i in 1...150 {
            XCTAssertEqual(policy.choose(["tcp", "ble"], bluetoothPreferred: true, now: Double(i) / 10), "ble")
        }
        XCTAssertEqual(policy.choose(["tcp", "ble"], bluetoothPreferred: true, now: 16), "tcp")
        XCTAssertEqual(policy.choose(["ble"], bluetoothPreferred: true, now: 16.01), "ble")
    }
    func testNetworkInputKeepsQuicAndUsesTcpOnlyWhenQuicUnavailable() {
        var policy = InputRoutePolicy()
        for i in 0..<4 {
            policy.observe("quic", milliseconds: 30, now: Double(i));
            policy.observe("tcp", milliseconds: 1, now: Double(i))
        }
        XCTAssertEqual(policy.choose(["quic", "tcp"], bluetoothPreferred: false, now: 0), "quic")
        XCTAssertEqual(policy.choose(["quic", "tcp"], bluetoothPreferred: false, now: 12), "quic")
        XCTAssertEqual(policy.choose(["tcp"], bluetoothPreferred: false, now: 13), "tcp")
    }

}

extension KeyboardMappingTests {
    @MainActor func testRemappedCommandFnRoleUsesLogicalFlagsForCtrlShortcuts() async {
        let fn = CGEventFlags(rawValue: CGEventFlags.maskSecondaryFn.rawValue | 0x100)
        let held = MacInputAdapter.modifierState(changing: "MetaLeft", flags: fn, previous: [])
        XCTAssertEqual(held, ["Fn"])
        XCTAssertEqual(KeyboardMapping.map(held.first!, from: "macos", to: "windows", config: nil), "ControlLeft")
        XCTAssertEqual(
            KeyboardMapping.command("KeyV", held: held.union(["KeyV"]), from: "macos", to: "windows", config: nil),
            "paste")
        XCTAssertEqual(
            KeyboardMapping.command("KeyC", held: held.union(["KeyC"]), from: "macos", to: "windows", config: nil),
            "copy")
        XCTAssertEqual(
            MacInputAdapter.modifierState(changing: "MetaLeft", flags: CGEventFlags(rawValue: 0x100), previous: held),
            [])
        let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        XCTAssertEqual(MacInputAdapter.modifierState(changing: "Fn", flags: command, previous: []), ["MetaRight"])
        let shifted = CGEventFlags(rawValue: fn.rawValue | CGEventFlags.maskShift.rawValue | 0x2)
        let chord = MacInputAdapter.modifierState(changing: "ShiftLeft", flags: shifted, previous: held)
        XCTAssertEqual(chord, ["Fn", "ShiftLeft"])
        XCTAssertEqual(KeyboardMapping.map("Equal", from: "macos", to: "windows", config: nil), "Equal")
        XCTAssertEqual(MacInputAdapter.modifierState(changing: "ShiftLeft", flags: fn, previous: chord), held)
        // Releasing an unseen Option must still never invent a Windows-key press.
        XCTAssertEqual(
            MacInputAdapter.modifierState(changing: "AltLeft", flags: CGEventFlags(rawValue: 0x100), previous: []), [])
    }
    @MainActor func testModifierFlagsDoNotInventWinPress() async {
        let up = CGEventFlags(rawValue: 0x100)
        XCTAssertFalse(MacInputAdapter.modifierDown("AltLeft", flags: up, previous: []))
        XCTAssertFalse(MacInputAdapter.modifierDown("AltLeft", flags: up, previous: ["AltLeft"]))
        let both = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x60)
        XCTAssertTrue(MacInputAdapter.modifierDown("AltLeft", flags: both, previous: ["AltLeft"]))
        XCTAssertTrue(MacInputAdapter.modifierDown("AltRight", flags: both, previous: ["AltLeft"]))
        let right = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        XCTAssertFalse(MacInputAdapter.modifierDown("AltLeft", flags: right, previous: ["AltLeft", "AltRight"]))
        XCTAssertTrue(MacInputAdapter.modifierDown("AltRight", flags: right, previous: ["AltLeft", "AltRight"]))
        XCTAssertTrue(
            MacInputAdapter.modifierDown("AltLeft", flags: .maskAlternate, previous: ["AltLeft"], changing: false))
        XCTAssertFalse(MacInputAdapter.modifierDown("Fn", flags: up, previous: ["Fn"]))
    }
}
