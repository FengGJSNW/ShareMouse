import AppKit
import SwiftUI

@MainActor
final class SourceIME: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var input: InputService?
    private var watcher: Task<Void, Never>?
    private var held: Set<String> = []
    private var consumed: Set<String> = []
    private var target: String?
    var shortcutRequested: (() -> Void)?
    var canOpen: (() -> Bool)?
    var released: (([String]) -> Void)?
    var enabled: Bool { window?.isVisible == true }
    func open(_ input: InputService) -> Bool {
        guard let target = input.remoteScreenID, input.beginSourceIME() else { return false }
        if enabled { window?.makeKeyAndOrderFront(nil); return true }
        self.input = input; self.target = target
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 210), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(SMTheme.canvas)
        panel.title = "来源输入法 · 关闭后恢复普通键盘"; panel.isReleasedWhenClosed = false; panel.delegate = self
        let status = NSTextField(labelWithString: "候选条留在本机，提交文本进入远端。Ctrl+Alt+Shift+Esc 紧急释放。")
        status.frame = NSRect(x: 18, y: 155, width: 464, height: 40); status.lineBreakMode = .byWordWrapping; status.font = .systemFont(ofSize: 13, weight: .medium); status.textColor = .secondaryLabelColor
        let text = CompositionView(frame: NSRect(x: 18, y: 20, width: 464, height: 130)); text.isRichText = false; text.font = .systemFont(ofSize: 20); text.textContainerInset = NSSize(width: 12, height: 12); text.wantsLayer = true; text.layer?.cornerRadius = 10; text.backgroundColor = NSColor(SMTheme.surface); text.textColor = .textColor
        text.commit = { [weak self] value in guard let self, let target = self.target else { return }; if self.input?.commitText(value, screenID: target) != true { status.stringValue = "目标已改变；本段未发送，请重新开启输入法模式"; self.close() } }
        text.control = { [weak self] key in guard let self, let input = self.input, input.remoteScreenID == self.target else { self?.close(); return }; _ = input.capture(CapturedInput("keyDown", key: key)); _ = input.capture(CapturedInput("keyUp", key: key)) }
        panel.contentView?.addSubview(status); panel.contentView?.addSubview(text); window = panel
        SMWindowChrome.install(panel)
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); panel.makeFirstResponder(text)
        watcher = Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)); guard let self, !Task.isCancelled else { return }; if self.input?.remoteScreenID != self.target { self.close(); return } } }
        return true
    }
    // Passthrough is restricted to keyboard input while our composition window owns focus.
    func capture(_ event: CapturedInput) -> Bool? {
        guard event.type == "keyDown" || event.type == "keyUp", let key = event.key else { return nil }
        if event.type == "keyDown" { held.insert(key) } else { held.remove(key) }
        if event.type == "keyUp", consumed.remove(key) != nil { return true }
        if consumed.contains(key) { return true }
        if event.type == "keyDown", key == "KeyI", held.contains(where: { $0.hasPrefix("Control") }), held.contains(where: { $0.hasPrefix("Alt") }), held.subtracting([key]).allSatisfy({ $0.hasPrefix("Control") || $0.hasPrefix("Alt") }), canOpen?() == true {
            if enabled { close() } else { shortcutRequested?() }; consumed.insert(key); return true
        }
        guard enabled else { return nil }
        guard window?.isKeyWindow == true else { close(); return nil }
        if event.type == "keyDown", key == "Escape", ["Control", "Alt", "Shift"].allSatisfy({ prefix in held.contains { $0.hasPrefix(prefix) } }) { input?.pause(); close(); return true }
        if event.type == "keyDown", (window?.firstResponder as? CompositionView)?.hasMarkedText() != true, input?.sourceCommand(key, held: held) == true { consumed.insert(key); return true }
        return false
    }
    func close() { watcher?.cancel(); watcher = nil; let previous = window; window = nil; if previous != nil { released?(Array(held)) }; previous?.close(); held = []; consumed = []; target = nil }
    func windowWillClose(_ notification: Notification) { close() }
    private final class CompositionView: NSTextView {
        var commit: ((String) -> Void)?; var control: ((String) -> Void)?
        override func insertText(_ value: Any, replacementRange: NSRange) {
            let text = value as? String ?? (value as? NSAttributedString)?.string ?? ""
            super.insertText(value, replacementRange: replacementRange)
            if !text.isEmpty { commit?(text) }; string = ""
        }
        override func doCommand(by selector: Selector) {
            let keys: [String: String] = ["insertNewline:":"Enter", "insertTab:":"Tab", "deleteBackward:":"Backspace", "deleteForward:":"Delete", "moveLeft:":"ArrowLeft", "moveRight:":"ArrowRight", "moveUp:":"ArrowUp", "moveDown:":"ArrowDown"]
            if !hasMarkedText(), let key = keys[NSStringFromSelector(selector)] { control?(key) } else { super.doCommand(by: selector) }
        }
    }
}
