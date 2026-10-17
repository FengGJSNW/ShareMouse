import Foundation

@MainActor public final class ClipboardShortcut {
    private var held: Set<String> = []
    private var consumed: Set<String> = []
    private let modifier: String
    public var cutFiles: (() -> Bool)?
    public var paste: (() -> Void)?
    public init(platform: String) { modifier = platform == "macos" ? "Meta" : "Control" }
    public func capture(_ input: CapturedInput, active: @autoclosure () -> Bool, allowCut: Bool = true) -> Bool {
        guard let key = input.key, ["keyDown", "keyUp"].contains(input.type) else { return false }
        if input.type == "keyUp" {
            held.remove(key);
            return consumed.remove(key) != nil
        }
        held.insert(key)
        if consumed.contains(key) { return true }
        if allowCut, key == "KeyX", held.subtracting([key]).contains(where: { $0.hasPrefix(modifier) }),
            held.subtracting([key]).allSatisfy({ $0.hasPrefix(modifier) }), cutFiles?() == true
        {
            consumed.insert(key);
            return true
        }
        if key == "KeyV", held.subtracting([key]).contains(where: { $0.hasPrefix(modifier) }),
            held.subtracting([key]).allSatisfy({ $0.hasPrefix(modifier) }), active()
        {
            consumed.insert(key);
            paste?();
            return true
        }
        return false
    }
    public func reset() {
        held = [];
        consumed = []
    }
}
