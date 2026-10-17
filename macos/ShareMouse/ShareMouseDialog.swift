import AppKit
import SwiftUI

enum DialogKind: Sendable { case info, question, warning, destructive, connection }

@MainActor enum ShareMouseDialog {
    private static var connections: [String: AsyncDialog] = [:]
    static func completeConnection(_ peerID: String) { connections[peerID]?.finish("allow") }
    static func chooseAsync(
        _ title: String, _ message: String, choices: [(String, String)], peerID: String? = nil,
        destructive: Bool = false, applyToRemaining: Bool = false, detail: String? = nil, defaultChoice: String? = nil,
        kind: DialogKind? = nil
    ) async -> String {
        let content = DialogContent(
            title: title, message: message, detail: detail, choices: choices, destructive: destructive,
            applyToRemaining: applyToRemaining, defaultChoice: defaultChoice, kind: kind)
        return await withCheckedContinuation { continuation in
            if let peerID, let pending = connections[peerID] {
                pending.addWaiter(continuation);
                return
            }
            let dialog = AsyncDialog(content, continuation: continuation) {
                if let peerID { connections.removeValue(forKey: peerID) }
            }
            if let peerID { connections[peerID] = dialog }
            dialog.show()
        }
    }
    static func choose(
        _ title: String, _ message: String, choices: [(String, String)], destructive: Bool = false,
        detail: String? = nil, defaultChoice: String? = nil, kind: DialogKind? = nil
    ) -> String {
        var result = "cancel"
        let content = DialogContent(
            title: title, message: message, detail: detail, choices: choices, destructive: destructive,
            applyToRemaining: false, defaultChoice: defaultChoice, kind: kind)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: DialogContent.width, height: 200), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        panel.title = "ShareMouse";
        panel.isReleasedWhenClosed = false
        SMWindowChrome.install(panel)
        host(
            DialogBody(content: content) { value in
                result = value;
                NSApp.stopModal();
                panel.orderOut(nil)
            }, in: panel)
        let delegate = DialogClose();
        panel.delegate = delegate
        panel.center();
        panel.makeKeyAndOrderFront(nil);
        NSApp.activate(ignoringOtherApps: true);
        NSApp.runModal(for: panel)
        return result
    }
    // Identity text shared by approval dialogs and the local identity view, so both sides compare the same groups.
    nonisolated static func identity(peerID: String, publicKey: String) -> String {
        "设备 ID\n\(peerID)\n\n公钥\n\(groupedKey(publicKey))"
    }
    nonisolated static func groupedKey(_ key: String) -> String {
        guard !key.contains("-----"), !key.contains(where: \.isWhitespace) else { return key }
        var groups: [String] = []
        var index = key.startIndex
        while index < key.endIndex {
            let next = key.index(index, offsetBy: 4, limitedBy: key.endIndex) ?? key.endIndex
            groups.append(String(key[index..<next]));
            index = next
        }
        return groups.joined(separator: " ")
    }
    fileprivate static func host<Root: View>(_ root: Root, in panel: NSPanel) {
        let hosting = NSHostingView(rootView: root.shareMouseSurface())
        panel.contentView = hosting
        let limit = (NSScreen.main?.visibleFrame.height ?? 800) * 0.7
        panel.setContentSize(
            NSSize(width: DialogContent.width, height: min(max(hosting.fittingSize.height, 120), limit)))
    }
}

private struct DialogContent {
    static let width: CGFloat = 440
    static let dangerous: Set<String> = ["delete", "deleteAll", "overwrite"]
    let title: String
    let message: String
    let detail: String?
    let choices: [(String, String)]
    let destructive: Bool
    let applyToRemaining: Bool
    let kind: DialogKind
    let primary: String?
    init(
        title: String, message: String, detail: String?, choices: [(String, String)], destructive: Bool,
        applyToRemaining: Bool, defaultChoice: String?, kind: DialogKind?
    ) {
        self.title = title;
        self.message = message;
        self.detail = detail;
        self.choices = choices
        self.destructive = destructive;
        self.applyToRemaining = applyToRemaining
        let resolved = kind ?? (destructive ? .destructive : choices.count == 1 ? .info : .question)
        self.kind = resolved
        primary =
            resolved == .destructive
            ? nil : (defaultChoice ?? choices.last(where: { $0.0 != "cancel" && !Self.dangerous.contains($0.0) })?.0)
    }
    // Approvals can appear while the user is typing elsewhere; Return must never grant or delete.
    var returnKeyEnabled: Bool { kind != .destructive && kind != .connection }
    var ordered: [(String, String)] {
        let cancel = choices.filter { $0.0 == "cancel" }
        let danger = choices.filter { Self.dangerous.contains($0.0) }
        let main = choices.filter { $0.0 == primary }
        let rest = choices.filter { $0.0 != "cancel" && !Self.dangerous.contains($0.0) && $0.0 != primary }
        return primary == nil ? rest + cancel + danger : rest + danger + cancel + main
    }
}

// Retained by the hosted completion while open; finish breaks that ownership cycle.
@MainActor private final class DecisionPanel: NSPanel {
    override var canBecomeKey: Bool { true };
    override var canBecomeMain: Bool { false }
}
@MainActor private final class AsyncDialog: NSObject, NSWindowDelegate {
    private let panel = DecisionPanel(
        contentRect: NSRect(x: 0, y: 0, width: DialogContent.width, height: 200),
        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
    private var continuations: [CheckedContinuation<String, Never>] = []
    private let completed: () -> Void
    init(_ content: DialogContent, continuation: CheckedContinuation<String, Never>, completed: @escaping () -> Void) {
        self.continuations = [continuation]
        self.completed = completed
        super.init()
        panel.title = "ShareMouse";
        panel.isReleasedWhenClosed = false;
        panel.delegate = self
        panel.level = .popUpMenu;
        panel.isFloatingPanel = true;
        panel.hidesOnDeactivate = false
        SMWindowChrome.install(panel)
        ShareMouseDialog.host(DialogBody(content: content) { [self] value in finish(value) }, in: panel)
    }
    func show() {
        panel.center();
        panel.makeKeyAndOrderFront(nil)
    }
    func addWaiter(_ value: CheckedContinuation<String, Never>) { continuations.append(value) }
    func finish(_ result: String) {
        guard !continuations.isEmpty else { return }
        let waiting = continuations;
        continuations = [];
        panel.delegate = nil;
        panel.orderOut(nil);
        panel.contentView = nil;
        panel.close()
        completed()
        for continuation in waiting { continuation.resume(returning: result) }
    }
    func windowWillClose(_ notification: Notification) { finish("cancel") }
}
@MainActor private final class DialogClose: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApp.stopModal() }
}

private struct DialogBody: View {
    let content: DialogContent
    let complete: (String) -> Void
    @State private var seconds = 3
    @State private var applyAll = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                DialogIcon(kind: content.kind)
                VStack(alignment: .leading, spacing: 8) {
                    Text(content.title).font(.system(size: 15, weight: .semibold)).fixedSize(
                        horizontal: false, vertical: true
                    ).accessibilityAddTraits(.isHeader)
                    if !content.message.isEmpty {
                        Text(content.message).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let detail = content.detail, !detail.isEmpty { DialogDetail(text: detail) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if content.applyToRemaining {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("对后续文件执行相同操作", isOn: $applyAll).toggleStyle(.checkbox)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0);
                        buttons
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Spacer(minLength: 0);
                    buttons
                }
            }
        }.padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 20).frame(
            width: DialogContent.width, alignment: .topLeading
        ).task {
            guard content.destructive else { return }
            while seconds > 0 {
                try? await Task.sleep(for: .seconds(1));
                if Task.isCancelled { return };
                seconds -= 1
            }
        }
    }
    @ViewBuilder private var buttons: some View {
        let ordered = content.ordered
        ForEach(ordered.indices, id: \.self) { index in button(ordered[index]) }
    }
    @ViewBuilder private func button(_ choice: (String, String)) -> some View {
        let counting = content.destructive && choice.0 == "deleteAll" && seconds > 0
        let label = counting ? "\(choice.1)（\(seconds)）" : choice.1
        let value = choice.0 + (content.applyToRemaining && applyAll && choice.0 != "cancel" ? ":all" : "")
        let shortcut: KeyboardShortcut? =
            choice.0 == "cancel"
            ? .cancelAction : choice.0 == content.primary && content.returnKeyEnabled ? .defaultAction : nil
        if choice.0 == content.primary {
            Button {
                complete(value)
            } label: {
                Text(label).frame(minWidth: 56)
            }.buttonStyle(.borderedProminent).modifier(DialogShortcut(shortcut: shortcut))
        } else {
            Button {
                complete(value)
            } label: {
                Text(label).frame(minWidth: 56).foregroundStyle(
                    DialogContent.dangerous.contains(choice.0) ? Color.red : Color.primary)
            }.buttonStyle(.bordered).disabled(counting).modifier(DialogShortcut(shortcut: shortcut))
        }
    }
}

private struct DialogShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?
    @ViewBuilder func body(content: Content) -> some View {
        if let shortcut { content.keyboardShortcut(shortcut) } else { content }
    }
}

private struct DialogIcon: View {
    let kind: DialogKind
    var body: some View {
        let style = appearance
        Image(systemName: style.symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(style.color).frame(
            width: 38, height: 38
        ).background(style.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
    }
    private var appearance: (symbol: String, color: Color) {
        switch kind {
        case .info: return ("info.circle", SMTheme.accent)
        case .question: return ("questionmark.circle", SMTheme.accent)
        case .warning: return ("exclamationmark.triangle", .orange)
        case .destructive: return ("exclamationmark.triangle", .red)
        case .connection: return ("link", SMTheme.accent)
        }
    }
}

// Paths and keys stay monospaced and selectable; long lists scroll inside a fixed box.
private struct DialogDetail: View {
    let text: String
    private var estimatedLines: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ($1.count + 39) / 40) }
    }
    var body: some View {
        let lines = Text(text).font(.system(size: 12, design: .monospaced)).lineSpacing(2).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
        Group {
            if estimatedLines > 10 {
                ScrollView { lines.fixedSize(horizontal: false, vertical: true) }.frame(height: 180)
            } else {
                lines.fixedSize(horizontal: false, vertical: true)
            }
        }.background(SMTheme.surface, in: RoundedRectangle(cornerRadius: 6)).overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(SMTheme.border, lineWidth: 0.5))
    }
}
