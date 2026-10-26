import Foundation

@MainActor public final class SharingShortcut {
    private var held: Set<String> = []
    private var consumed: Set<String> = []
    private let platform: String
    public var toggleFn: (() -> Void)?
    public var toggleFunctions: (() -> Void)?
    public var toggleCrossing: (() -> Void)?
    public var toggle: (() -> Void)?
    public init(platform: String = "windows") { self.platform = platform }
    public static func isEmergencyChord(_ held: Set<String>, platform: String) -> Bool {
        func has(_ prefix: String) -> Bool { held.contains { $0.hasPrefix(prefix) } }
        return has("Control") && has("Shift") && (has("Alt") || platform == "macos" && has("Meta"))
    }
    public func capture(_ input: CapturedInput, sourceKey: ((String) -> String)? = nil) -> Bool {
        guard let key = input.key, ["keyDown", "keyUp"].contains(input.type) else { return false }
        if input.type == "keyUp" {
            held.remove(key);
            return consumed.remove(key) != nil
        }
        held.insert(key)
        if consumed.contains(key) { return true }
        let action: (() -> Void)?
        // Reserve Escape before user/target mappings. Check both macOS roles and
        // physical roles when the user has exchanged Fn and Command in Settings.
        if key == "Escape",
            Self.isEmergencyChord(held, platform: platform)
                || sourceKey.map({ Self.isEmergencyChord(Set(held.map($0)), platform: platform) }) == true
        {
            action = toggle
        } else {
            guard ["Control", "Alt", "Shift"].allSatisfy({ prefix in held.contains { $0.hasPrefix(prefix) } }) else {
                return false
            }
            action = ["KeyF": toggleFn, "KeyG": toggleFunctions, "KeyL": toggleCrossing][key] ?? nil
        }
        guard let action else { return false }
        consumed.insert(key);
        action();
        return true
    }
    public func reset() {
        held = [];
        consumed = []
    }
}
