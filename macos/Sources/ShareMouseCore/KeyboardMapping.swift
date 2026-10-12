import Foundation

public enum KeyboardMapping {
    public static let noAction = "NoAction"
    public static let keys = ["KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ", "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Backquote", "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash", "ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight", "Escape", "Tab", "CapsLock", "Backspace", "Enter", "Space", "Insert", "Delete", "Home", "End", "PageUp", "PageDown", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PrintScreen", "ContextMenu", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"]
    public static let modifiers = ["ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight"]
    public static func map(_ key: String, from: String, to: String, config: KeyboardConfig?) -> String {
        guard from != to, ["windows", "macos"].contains(from), ["windows", "macos"].contains(to) else { return key }
        let custom = to == "macos" ? config?.windowsToMac : config?.macToWindows
        if let mapped = custom?[key] { return to == "macos" && ["PrintScreen", "ContextMenu"].contains(mapped) ? noAction : mapped }
        if to=="macos",["PrintScreen","ContextMenu"].contains(key){return noAction}
        if key.hasPrefix("Control") { return key.replacingOccurrences(of: "Control", with: "Meta") }
        if key.hasPrefix("Meta") { return key.replacingOccurrences(of: "Meta", with: "Control") }
        return key
    }
    public static func valid(_ configs: [KeyboardConfig], members: Set<String>, selected: String) -> Bool {
        !configs.isEmpty && configs.count <= 64 && Set(configs.map(\.id)).count == configs.count && configs.contains { $0.id == selected }
        && configs.allSatisfy { c in UUID(uuidString: c.id) != nil && UUID(uuidString: c.ownerPeerID) != nil && !c.name.isEmpty && c.name.utf8.count <= 128
            && [c.windowsToMac, c.macToWindows].allSatisfy { $0.count <= keys.count && $0.allSatisfy { keys.contains($0.key) && (keys.contains($0.value) || $0.value == noAction) } } }
    }
    public static func command(_ key: String, held: Set<String>, from: String, to: String, config: KeyboardConfig?) -> String? {
        let overrides = from == "windows" && to == "macos" ? config?.windowsToMac : from == "macos" && to == "windows" ? config?.macToWindows : nil
        if overrides?[key] != nil { return nil }
        if from != to, !held.contains(where: { overrides?[$0] != nil }) {
            let control = held.contains { $0.hasPrefix("Control") }, meta = held.contains { $0.hasPrefix("Meta") }
            if control && (from == "macos" || meta), ["ArrowLeft", "ArrowRight"].contains(key) { return key == "ArrowLeft" ? "desktopPrevious" : "desktopNext" }
            if from == "macos" && control && key == "ArrowUp" || from == "windows" && meta && key == "Tab" { return "overview" }
        }
        let mapped = held.subtracting([key]).map { map($0, from: from, to: to, config: config) }.filter { $0 != noAction }
        let modifier = to == "macos" ? "Meta" : "Control"
        guard ["windows", "macos"].contains(to), mapped.contains(where: { $0.hasPrefix(modifier) }) else { return nil }
        if key == "KeyZ", mapped.allSatisfy({ $0.hasPrefix(modifier) || $0.hasPrefix("Shift") }) { return mapped.contains(where: { $0.hasPrefix("Shift") }) ? "redo" : "undo" }
        guard mapped.allSatisfy({ $0.hasPrefix(modifier) }) else { return nil }
        if key == "KeyY", from == "windows" { return "redo" }
        return ["KeyC":"copy", "KeyX":"cut", "KeyV":"paste"][key]
    }
}
