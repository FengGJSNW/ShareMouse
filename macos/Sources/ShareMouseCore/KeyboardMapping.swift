import Foundation

public enum KeyboardMapping {
    public static let noAction = "NoAction"
    public static let keys = [
        "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN",
        "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ", "Digit0",
        "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Backquote", "Minus",
        "Equal", "BracketLeft", "BracketRight", "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash",
        "ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight",
        "Escape", "Tab", "CapsLock", "Backspace", "Enter", "Space", "Insert", "Delete", "Home", "End", "PageUp",
        "PageDown", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PrintScreen", "ContextMenu", "F1", "F2", "F3",
        "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20",
        "F21", "F22", "F23", "F24", "Fn", "BrightnessDown", "BrightnessUp", "KeyboardBrightnessDown",
        "KeyboardBrightnessUp", "VolumeMute", "VolumeDown", "VolumeUp", "MediaPlayPause", "MediaNext", "MediaPrevious",
        "MediaFastForward", "MediaRewind", "MediaStop", "MissionControl", "Spotlight", "Dictation", "DoNotDisturb",
        "Screenshot", "DisplaySwitch", "Sleep", "FnLock", "AuraCycle", "PerformanceMode", "TouchpadToggle",
        "AirplaneMode",
    ]
    public static let modifiers = [
        "ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight",
    ]
    public static let functionKeys = [
        "Fn", "BrightnessDown", "BrightnessUp", "KeyboardBrightnessDown", "KeyboardBrightnessUp", "VolumeMute",
        "VolumeDown", "VolumeUp", "MediaPlayPause", "MediaNext", "MediaPrevious", "MediaFastForward", "MediaRewind",
        "MediaStop", "MissionControl", "Spotlight", "Dictation", "DoNotDisturb", "Screenshot", "DisplaySwitch", "Sleep",
        "FnLock", "AuraCycle", "PerformanceMode", "TouchpadToggle", "AirplaneMode",
    ]
    public static func canInject(_ key: String, on platform: String) -> Bool {
        if platform == "macos" {
            return ![
                "PrintScreen", "ContextMenu", "F21", "F22", "F23", "F24", "DisplaySwitch", "FnLock", "AuraCycle",
                "PerformanceMode", "TouchpadToggle", "Sleep", "MediaStop", "AirplaneMode",
            ].contains(key)
        }
        return !["FnLock", "MissionControl", "Spotlight", "Dictation", "DoNotDisturb"].contains(key)
    }
    // macOS reports the function layer by meaning rather than the F number on the keycap.
    public static let macFunctionSlots = [
        "BrightnessDown": "F1", "BrightnessUp": "F2", "MissionControl": "F3", "Spotlight": "F4", "Dictation": "F5",
        "DoNotDisturb": "F6", "MediaRewind": "F7", "MediaPlayPause": "F8", "MediaFastForward": "F9",
        "VolumeMute": "F10", "VolumeDown": "F11", "VolumeUp": "F12",
    ]
    public static func macFunction(_ slot: String) -> String? { macFunctionSlots.first { $0.value == slot }?.key }
    public static let windowsFunctions = [
        "F1": "VolumeMute", "F2": "KeyboardBrightnessDown", "F3": "KeyboardBrightnessUp", "F4": "AuraCycle",
        "F5": "PerformanceMode", "F6": "Screenshot", "F7": "BrightnessDown", "F8": "BrightnessUp",
        "F9": "DisplaySwitch", "F10": "TouchpadToggle", "F11": "DoNotDisturb", "F12": "AirplaneMode",
    ]
    public static func windowsFunction(_ slot: String) -> String? { windowsFunctions[slot] }
    public static func map(
        _ key: String, from: String, to: String, config: KeyboardConfig?, fnDown: Bool = false,
        functionKey: ((String) -> String?)? = nil, fnEnabled: Bool = true, functionKeysEnabled: Bool = true,
        functionSlot: String? = nil
    ) -> String {
        guard from != to, ["windows", "macos"].contains(from), ["windows", "macos"].contains(to) else { return key }
        let sourceSlot = from == "windows" ? functionSlot.flatMap { windowsFunctions[$0] != nil ? $0 : nil } : nil
        if !functionKeysEnabled {
            let slot =
                sourceSlot
                ?? (from == "macos"
                    ? macFunctionSlots[key] ?? key : windowsFunctions.first(where: { $0.value == key })?.key ?? key)
            if slot.hasPrefix("F"), let number = Int(slot.dropFirst()), (1...12).contains(number) { return slot }
        }
        let custom = to == "macos" ? config?.windowsToMac : config?.macToWindows
        let slot = from == "macos" ? macFunctionSlots[key] ?? key : sourceSlot ?? key
        // Existing semantic overrides win; otherwise the visible F tile applies to both layers.
        var mapped = custom?[key] ?? (slot != key ? custom?[slot] : nil)
        if from == "macos", to == "windows" {
            // macOS has already selected the layer: a semantic event is a Windows function
            // at the same physical slot; an ordinary F event stays an ordinary F key.
            if slot != key {
                let candidate = mapped ?? slot
                if windowsFunctions[candidate] != nil || candidate == "F12" {
                    mapped = (functionKey ?? windowsFunction)(candidate) ?? noAction
                }
            }
            if let mapped {
                return canInject(mapped, on: to) && (fnEnabled || mapped != "Fn")
                    && (functionKeysEnabled || mapped == "Fn" || !functionKeys.contains(mapped)) ? mapped : noAction
            }
            if key == "Fn" { return "ControlLeft" }
            if key.hasPrefix("Control") { return fnEnabled ? "Fn" : noAction }
            if key.hasPrefix("Alt") { return key.replacingOccurrences(of: "Alt", with: "Meta") }
            if key.hasPrefix("Meta") { return key.replacingOccurrences(of: "Meta", with: "Alt") }
            return !functionKeysEnabled && functionKeys.contains(key) ? noAction : key
        }
        if let sourceSlot, to == "macos" {
            let candidate = mapped ?? sourceSlot
            if macFunctionSlots.values.contains(candidate) {
                mapped = fnEnabled ? macFunction(candidate) ?? noAction : candidate
            }
        }
        if sourceSlot == nil && fnDown && fnEnabled && functionKeysEnabled, let functionKey {
            let candidate = mapped ?? slot
            if candidate.hasPrefix("F"), let number = Int(candidate.dropFirst()), (1...12).contains(number) {
                mapped = functionKey(candidate) ?? noAction
            }
        }
        if let mapped {
            return canInject(mapped, on: to) && (fnEnabled || mapped != "Fn")
                && (functionKeysEnabled || mapped == "Fn" || !functionKeys.contains(mapped)) ? mapped : noAction
        }
        if !canInject(key, on: to) || !fnEnabled && key == "Fn"
            || !functionKeysEnabled && key != "Fn" && functionKeys.contains(key)
        {
            return noAction
        }
        if key.hasPrefix("Control") { return key.replacingOccurrences(of: "Control", with: "Meta") }
        if key.hasPrefix("Meta") { return key.replacingOccurrences(of: "Meta", with: "Control") }
        return key
    }
    public static func valid(_ configs: [KeyboardConfig], members: Set<String>, selected: String) -> Bool {
        !configs.isEmpty && configs.count <= 64 && Set(configs.map(\.id)).count == configs.count
            && configs.contains { $0.id == selected }
            && configs.allSatisfy { c in
                UUID(uuidString: c.id) != nil && UUID(uuidString: c.ownerPeerID) != nil && !c.name.isEmpty
                    && c.name.utf8.count <= 128
                    && [c.windowsToMac, c.macToWindows].allSatisfy {
                        $0.count <= keys.count
                            && $0.allSatisfy {
                                keys.contains($0.key) && (keys.contains($0.value) || $0.value == noAction)
                            }
                    }
            }
    }
    public static func command(
        _ key: String, held: Set<String>, from: String, to: String, config: KeyboardConfig?, fnEnabled: Bool = true,
        functionKeysEnabled: Bool = true
    ) -> String? {
        let overrides =
            from == "windows" && to == "macos"
            ? config?.windowsToMac : from == "macos" && to == "windows" ? config?.macToWindows : nil
        if overrides?[key] != nil { return nil }
        if from != to, !(from == "macos" && to == "windows"), !held.contains(where: { overrides?[$0] != nil }) {
            let control = held.contains { $0.hasPrefix("Control") }, meta = held.contains { $0.hasPrefix("Meta") }
            if control && (from == "macos" || meta), ["ArrowLeft", "ArrowRight"].contains(key) {
                return key == "ArrowLeft" ? "desktopPrevious" : "desktopNext"
            }
            if from == "macos" && control && key == "ArrowUp" || from == "windows" && meta && key == "Tab" {
                return "overview"
            }
        }
        let mapped = held.subtracting([key]).map {
            map($0, from: from, to: to, config: config, fnEnabled: fnEnabled, functionKeysEnabled: functionKeysEnabled)
        }.filter { $0 != noAction && $0 != "Fn" }
        let modifier = to == "macos" ? "Meta" : "Control"
        guard ["windows", "macos"].contains(to), mapped.contains(where: { $0.hasPrefix(modifier) }) else { return nil }
        if key == "KeyZ", mapped.allSatisfy({ $0.hasPrefix(modifier) || $0.hasPrefix("Shift") }) {
            return mapped.contains(where: { $0.hasPrefix("Shift") }) ? "redo" : "undo"
        }
        guard mapped.allSatisfy({ $0.hasPrefix(modifier) }) else { return nil }
        if key == "KeyY", from == "windows" { return "redo" }
        return ["KeyC": "copy", "KeyX": "cut", "KeyV": "paste"][key]
    }
}
