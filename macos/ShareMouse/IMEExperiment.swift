import AppKit
import SwiftUI

@MainActor final class SourceIME: NSObject, NSWindowDelegate {
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
        if enabled {
            window?.makeKeyAndOrderFront(nil);
            return true
        }
        self.input = input;
        self.target = target
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 232), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        panel.title = "输入法模式";
        panel.isReleasedWhenClosed = false;
        panel.delegate = self
        let status = NSTextField(wrappingLabelWithString: "在这里打字，确认后的文字会发到当前远端屏幕。候选条留在本机。关闭窗口即恢复普通键盘。")
        status.frame = NSRect(x: 18, y: 186, width: 464, height: 36);
        status.font = .systemFont(ofSize: 13);
        status.textColor = .secondaryLabelColor
        let text = CompositionView(frame: NSRect(x: 18, y: 46, width: 464, height: 132));
        text.isRichText = false;
        text.font = .systemFont(ofSize: 20);
        text.textContainerInset = NSSize(width: 12, height: 12);
        text.wantsLayer = true;
        text.layer?.cornerRadius = 10;
        text.backgroundColor = .controlBackgroundColor;
        text.textColor = .textColor
        let footer = NSHostingView(rootView: IMEShortcutHints().shareMouseSurface(background: false, animated: false))
        footer.frame = NSRect(x: 18, y: 12, width: 464, height: 24)
        text.commit = { [weak self] value in
            guard let self, let target = self.target else { return };
            if self.input?.commitText(value, screenID: target) != true {
                status.textColor = .systemRed;
                status.stringValue = "目标屏幕已经变了，这段文字没有发出去。请重新打开输入法模式。";
                self.close()
            }
        }
        text.control = { [weak self] key in
            guard let self, let input = self.input, input.remoteScreenID == self.target else {
                self?.close();
                return
            };
            _ = input.capture(CapturedInput("keyDown", key: key));
            _ = input.capture(CapturedInput("keyUp", key: key))
        }
        panel.contentView?.addSubview(status);
        panel.contentView?.addSubview(text);
        panel.contentView?.addSubview(footer);
        window = panel
        SMWindowChrome.install(panel, showsTitle: true)
        panel.center();
        panel.makeKeyAndOrderFront(nil);
        NSApp.activate(ignoringOtherApps: true);
        panel.makeFirstResponder(text)
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200));
                guard let self, !Task.isCancelled else { return };
                if self.input?.remoteScreenID != self.target {
                    self.close();
                    return
                }
            }
        }
        return true
    }
    // Passthrough is restricted to keyboard input while our composition window owns focus.
    func capture(_ event: CapturedInput) -> Bool? {
        guard event.type == "keyDown" || event.type == "keyUp", let key = event.key else { return nil }
        if event.type == "keyDown" { held.insert(key) } else { held.remove(key) }
        if event.type == "keyUp", consumed.remove(key) != nil { return true }
        if consumed.contains(key) { return true }
        if event.type == "keyDown", key == "KeyI", held.contains(where: { $0.hasPrefix("Control") }),
            held.contains(where: { $0.hasPrefix("Alt") }),
            held.subtracting([key]).allSatisfy({ $0.hasPrefix("Control") || $0.hasPrefix("Alt") }), canOpen?() == true
        {
            if enabled { close() } else { shortcutRequested?() };
            consumed.insert(key);
            return true
        }
        guard enabled else { return nil }
        guard window?.isKeyWindow == true else {
            close();
            return nil
        }
        if event.type == "keyDown", key == "Escape", SharingShortcut.isEmergencyChord(held, platform: "macos") {
            input?.pause();
            close();
            return true
        }
        if event.type == "keyDown", (window?.firstResponder as? CompositionView)?.hasMarkedText() != true,
            input?.sourceCommand(key, held: held) == true
        {
            consumed.insert(key);
            return true
        }
        return false
    }
    func close() {
        watcher?.cancel();
        watcher = nil;
        let previous = window;
        window = nil;
        if previous != nil { released?(Array(held)) };
        previous?.close();
        held = [];
        consumed = [];
        target = nil
    }
    func windowWillClose(_ notification: Notification) { close() }
    private final class CompositionView: NSTextView {
        var commit: ((String) -> Void)?;
        var control: ((String) -> Void)?
        // The placeholder is drawn, not inserted, so composition and commit stay untouched.
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !hasMarkedText() else { return }
            let origin = NSPoint(
                x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
            ("开始输入…" as NSString).draw(
                at: origin,
                withAttributes: [
                    .font: font ?? NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.placeholderTextColor,
                ])
        }
        override func insertText(_ value: Any, replacementRange: NSRange) {
            let text = value as? String ?? (value as? NSAttributedString)?.string ?? ""
            super.insertText(value, replacementRange: replacementRange)
            if !text.isEmpty { commit?(text) };
            string = ""
        }
        override func doCommand(by selector: Selector) {
            let keys: [String: String] = [
                "insertNewline:": "Enter", "insertTab:": "Tab", "deleteBackward:": "Backspace",
                "deleteForward:": "Delete", "moveLeft:": "ArrowLeft", "moveRight:": "ArrowRight", "moveUp:": "ArrowUp",
                "moveDown:": "ArrowDown",
            ]
            if !hasMarkedText(), let key = keys[NSStringFromSelector(selector)] {
                control?(key)
            } else {
                super.doCommand(by: selector)
            }
        }
    }
}

private struct IMEShortcutHints: View {
    var body: some View {
        HStack {
            SMKeyHint(keys: ["⌘", "⌃", "⇧", "⎋"], text: "紧急释放")
            Spacer()
            SMKeyHint(keys: ["⌃", "⌥", "I"], text: "开关输入法模式")
        }
    }
}
