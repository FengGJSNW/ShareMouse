import AppKit
import SwiftUI
@MainActor
enum ShareMouseDialog {
    private static var connections: [String: AsyncDialog] = [:]
    static func completeConnection(_ peerID: String) { connections[peerID]?.finish("allow") }
    static func chooseAsync(_ title: String, _ message: String, choices: [(String, String)], peerID: String? = nil, destructive: Bool = false, applyToRemaining: Bool = false) async -> String {
        await withCheckedContinuation { continuation in
            if let peerID, let pending = connections[peerID] { pending.addWaiter(continuation); return }
            let dialog = AsyncDialog(title, message, choices: choices, destructive: destructive, applyToRemaining: applyToRemaining, continuation: continuation) {
                if let peerID { connections.removeValue(forKey: peerID) }
            }
            if let peerID { connections[peerID] = dialog }
            dialog.show()
        }
    }
    static func choose(_ title: String, _ message: String, choices: [(String, String)], destructive: Bool = false) -> String {
        var result = "cancel"
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "ShareMouse"; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: (DialogBody(title: title, message: message, choices: choices, destructive: destructive, applyToRemaining: false) { value in result = value; NSApp.stopModal(); panel.orderOut(nil) }).shareMouseSurface())
        let delegate = DialogClose(); panel.delegate = delegate
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); NSApp.runModal(for: panel)
        return result
    }
}
// Retained by the hosted completion while open; finish breaks that ownership cycle.
@MainActor
private final class DecisionPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }
@MainActor
private final class AsyncDialog: NSObject, NSWindowDelegate {
    private let panel = DecisionPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
    private var continuations: [CheckedContinuation<String, Never>] = []
    private let completed: () -> Void
    init(_ title: String, _ message: String, choices: [(String, String)], destructive: Bool, applyToRemaining: Bool, continuation: CheckedContinuation<String, Never>, completed: @escaping () -> Void) {
        self.continuations = [continuation]
        self.completed = completed
        super.init()
        panel.title = "ShareMouse"; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = .popUpMenu;panel.isFloatingPanel = true;panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: (DialogBody(title: title, message: message, choices: choices, destructive: destructive, applyToRemaining: applyToRemaining) { [self] value in finish(value) }).shareMouseSurface())
    }
    func show() { panel.center(); panel.makeKeyAndOrderFront(nil) }
    func addWaiter(_ value: CheckedContinuation<String, Never>) { continuations.append(value) }
    func finish(_ result: String) {
        guard !continuations.isEmpty else { return }
        let waiting = continuations; continuations = []; panel.delegate = nil; panel.orderOut(nil); panel.contentView = nil; panel.close()
        completed()
        for continuation in waiting { continuation.resume(returning: result) }
    }
    func windowWillClose(_ notification: Notification) { finish("cancel") }
}
@MainActor
private final class DialogClose: NSObject, NSWindowDelegate { func windowWillClose(_ notification: Notification) { NSApp.stopModal() } }
private struct DialogBody: View {
    let title: String; let message: String; let choices: [(String, String)]; let destructive: Bool; let applyToRemaining: Bool; let complete: (String) -> Void
    @State private var seconds = 3
    @State private var applyAll = false
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Label(title, systemImage: "rectangle.on.rectangle").font(.system(size: 21, weight: .semibold)); ScrollView { Text(message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
        if applyToRemaining { Toggle("对后续文件执行相同操作", isOn: $applyAll).toggleStyle(.checkbox) }
        ViewThatFits(in: .horizontal) {
            HStack { Spacer(minLength: 0); actionButtons.fixedSize() }
            VStack(alignment: .trailing, spacing: 8) { actionButtons }
        }
    }.padding(24).task { while seconds > 0 { try? await Task.sleep(for: .seconds(1)); if Task.isCancelled { return }; seconds -= 1 } } }
    private var actionButtons: some View { ForEach(choices.indices, id: \.self) { index in
            let choice = choices[index]
            Button(destructive && choice.0 == "deleteAll" && seconds > 0 ? "\(choice.1) (\(seconds))" : choice.1, role: destructive && choice.0 == "deleteAll" ? .destructive : nil) { complete(choice.0 + (applyToRemaining && applyAll && choice.0 != "cancel" ? ":all" : "")) }.disabled(destructive && choice.0 == "deleteAll" && seconds > 0)
        } }

}
