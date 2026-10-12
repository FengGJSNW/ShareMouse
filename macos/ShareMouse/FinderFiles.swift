import AppKit
import ApplicationServices
import CoreServices
@MainActor
enum FinderFiles {
    nonisolated static func automationPermission(request: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, request)
    }
    static var frontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" }
    static var canCut: Bool {
        guard frontmost, let application = NSWorkspace.shared.frontmostApplication else { return false }
        guard let element = MacCutSelection.focusedElement(in: application) else { return false }
        var role: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success, let role = role as? String else { return false }
        return ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }
    static func selection(requireFrontmost: Bool = true) -> [String] {
        guard !requireFrontmost || frontmost else { return [] }
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Finder\"\nset resultPaths to {}\nrepeat with selectedItem in selection\nset end of resultPaths to POSIX path of (selectedItem as alias)\nend repeat\nreturn resultPaths\nend tell")
        guard let result = script?.executeAndReturnError(&error), error == nil else { return [] }
        return (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1)?.stringValue }
    }
    static func destination() -> String? {
        guard frontmost else { return nil }; var error: NSDictionary?
        let result = NSAppleScript(source: "tell application \"Finder\"\nif (count of Finder windows) is 0 then return POSIX path of (desktop as alias)\nreturn POSIX path of (target of front window as alias)\nend tell")?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}

@MainActor
enum MacCutSelection {
    enum Content { case text, files, none, unavailable }

    static func focusedElement(in application: NSRunningApplication) -> AXUIElement? {
        let app = AXUIElementCreateApplication(application.processIdentifier)
        // A slow application must not hold up the event tap. Called after the cut chord is consumed.
        AXUIElementSetMessagingTimeout(app, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }

    static func content(in application: NSRunningApplication) -> Content {
        guard let element = focusedElement(in: application) else { return .unavailable }
        if application.bundleIdentifier == "com.apple.finder" {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
                  let role = value as? String else { return .unavailable }
            if ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return .files }
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return .unavailable }
            return range.length > 0 ? .text : .none
        }
        // Some applications expose selected text but not its range. Never log or retain this text.
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let text = value as? String { return text.isEmpty ? .none : .text }
        return .unavailable
    }
}
