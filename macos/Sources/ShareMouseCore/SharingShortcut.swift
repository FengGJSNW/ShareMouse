import Foundation

@MainActor public final class SharingShortcut {
    private var held: Set<String> = []
    private var consumed: Set<String> = []
    public var toggleFn: (() -> Void)?
    public var toggleFunctions: (() -> Void)?
    public var toggleCrossing: (() -> Void)?
    public var toggle: (() -> Void)?
    public init() {}
    public func capture(_ input: CapturedInput) -> Bool {
        guard let key = input.key, ["keyDown", "keyUp"].contains(input.type) else { return false }
        if input.type == "keyUp" {
            held.remove(key);
            return consumed.remove(key) != nil
        }
        held.insert(key)
        if consumed.contains(key) { return true }
        guard ["Control", "Alt", "Shift"].allSatisfy({ prefix in held.contains { $0.hasPrefix(prefix) } }) else {
            return false
        }
        let action: (() -> Void)? =
            ["Escape": toggle, "KeyF": toggleFn, "KeyG": toggleFunctions, "KeyL": toggleCrossing][key] ?? nil
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
