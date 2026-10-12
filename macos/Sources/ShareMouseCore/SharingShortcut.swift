import Foundation

@MainActor
public final class SharingShortcut {
    private var held: Set<String> = []
    private var consumed = false
    public var toggle: (() -> Void)?
    public init() {}
    public func capture(_ input: CapturedInput) -> Bool {
        guard let key = input.key, ["keyDown", "keyUp"].contains(input.type) else { return false }
        if input.type == "keyUp" { held.remove(key); if key == "Escape", consumed { consumed = false; return true }; return false }
        held.insert(key)
        guard key == "Escape" else { return false }
        if consumed { return true }
        if ["Control", "Alt", "Shift"].allSatisfy({ prefix in held.contains { $0.hasPrefix(prefix) } }) { consumed = true; toggle?(); return true }
        return false
    }
    public func reset() { held = []; consumed = false }
}
