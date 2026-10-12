import AppKit
import SwiftUI
private final class HistoryPanel: NSPanel {
    var keyAction: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if let keyAction { keyAction(event) } else { super.keyDown(with: event) } }
}
@MainActor
private final class HistoryFilter: ObservableObject {
    @Published var search = ""
    @Published var favorites = false
    @Published var selection = 0
    func entries(_ model: PairingViewModel) -> [HistoryEntry] { model.historyEntries.filter { (!favorites || $0.favorite) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) } }
    func index(_ model: PairingViewModel) -> Int { min(max(0, selection), max(0, entries(model).count - 1)) }
    func page(_ model: PairingViewModel) -> Int { index(model) / model.historyVisibleCount }
    func visible(_ model: PairingViewModel) -> [HistoryEntry] { Array(entries(model).dropFirst(page(model) * model.historyVisibleCount).prefix(model.historyVisibleCount)) }
    func move(_ amount: Int, _ model: PairingViewModel) { selection = min(max(0, index(model) + amount), max(0, entries(model).count - 1)) }
}
@MainActor
final class HistoryPopup: NSObject, NSWindowDelegate {
    private var panel: HistoryPanel?
    private var settings: NSPanel?
    private var details: HistoryPanel?
    private var mouseMonitor: Any?
    private func watchFocus() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window, window === self.panel || window === self.details, let content = window.contentView else { return event }
            var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
            while let candidate = view {
                if let field = candidate as? NSTextField, field.isEditable { return event }
                if let text = candidate as? NSTextView, text.isEditable { return event }
                view = candidate.superview
            }
            window.makeFirstResponder(window); return event
        }
    }
    func stop() { if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil; panel?.orderOut(nil); details?.orderOut(nil); settings?.orderOut(nil) }
    private var filter = HistoryFilter()
    private var model: PairingViewModel?
    private var previousApplication: NSRunningApplication?
    private var previousWindow: NSWindow?
    private var consumed: Set<String> = []
    func show(_ model: PairingViewModel) {
        if panel?.isVisible == true { dismiss(); return }
        watchFocus(); self.model = model; filter = HistoryFilter()
        previousApplication = NSWorkspace.shared.frontmostApplication; previousWindow = NSApp.keyWindow
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame, width = min(400.0, area.width), height = min(Double(model.historyVisibleCount * 36 + 80), area.height)
        let right = point.x + 12, left = point.x - 12 - width
        let preferred = model.historySide == "left" ? left : right, alternate = model.historySide == "left" ? right : left
        let x = preferred >= area.minX && preferred + width <= area.maxX ? preferred : alternate
        let frame = NSRect(x: min(max(area.minX, x), area.maxX - width), y: min(max(area.minY, point.y - height + 16), area.maxY - height), width: width, height: height)
        let panel = HistoryPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true; panel.level = .popUpMenu
        panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.delegate = self
        panel.keyAction = { [weak self] event in
            let keys: [UInt16: String] = [53: "Escape", 36: "Enter", 76: "Enter", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp"]
            _ = self?.capture(CapturedInput("keyDown", key: keys[event.keyCode] ?? "Digit" + (event.charactersIgnoringModifiers ?? "")))
        }
        panel.contentView = NSHostingView(rootView: (CompactHistoryView(model: model, filter: filter, selected: { [weak self] in self?.choose($0) }, settings: { [weak self] in self?.dismiss(); self?.showManagement(model) }, details: { [weak self] in self?.dismiss(); self?.showDetails(model) })).shareMouseSurface(background: false))
        self.panel = panel; panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel)
    }
    func capture(_ input: CapturedInput) -> Bool {
        guard let key = input.key, ["keyDown", "keyUp"].contains(input.type) else { return false }
        if input.type == "keyUp" { return consumed.remove(key) != nil }
        if consumed.contains(key) { return true }
        guard let active = details?.isKeyWindow == true ? details : panel, active.isVisible, active.isKeyWindow, let model, !["Control", "Alt", "Shift", "Meta"].contains(where: { key.hasPrefix($0) }) else { return false }
        if let editor = active.firstResponder as? NSTextView, editor.isFieldEditor, key != "Escape", key != "Enter" { return false }
        guard ["Escape", "Enter", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].contains(key) || (key.hasPrefix("Digit") || key.hasPrefix("Numpad")) && (1...9).contains(key.last?.wholeNumberValue ?? 0) else { return false }
        consumed.insert(key)
        switch key {
        case "Escape": details?.orderOut(nil); dismiss()
        case "ArrowUp": filter.move(-1, model)
        case "ArrowDown": filter.move(1, model)
        case "ArrowLeft": filter.move(-model.historyVisibleCount, model)
        case "ArrowRight": filter.move(model.historyVisibleCount, model)
        case "Enter": let all = filter.entries(model); if !all.isEmpty { choose(all[filter.index(model)]) }
        default: if (key.hasPrefix("Digit") || key.hasPrefix("Numpad")), let digit = key.last?.wholeNumberValue { let visible = filter.visible(model); if (1...9).contains(digit), digit <= visible.count { choose(visible[digit - 1]) } }
        }
        return true
    }
    private func choose(_ entry: HistoryEntry) {
        let target = previousApplication, model = self.model
        details?.orderOut(nil); dismiss()
        model?.selectHistory(entry, paste: true, expectedApplication: target?.processIdentifier)
    }
    private func dismiss() {
        panel?.orderOut(nil)
        if let app = previousApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { NSApp.yieldActivation(to: app); app.activate(from: .current, options: []) }
        else if let previousWindow, previousWindow.isVisible { previousWindow.makeKeyAndOrderFront(nil) }
    }
    func windowDidResignKey(_ notification: Notification) { if panel?.isVisible == true { panel?.orderOut(nil) } }
    func showManagement(_ model: PairingViewModel) {
        if let settings, settings.isVisible { settings.makeKeyAndOrderFront(nil); return }
        let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "剪贴板设置"; panel.isReleasedWhenClosed = false; panel.level = .popUpMenu; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: (HistorySettingsView(model: model)).shareMouseSurface())
        settings = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    private func showDetails(_ model: PairingViewModel) {
        if let details, details.isVisible { details.makeKeyAndOrderFront(nil); return }
        let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 580), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "剪贴板详细记录"; panel.isReleasedWhenClosed = false; panel.level = .popUpMenu; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        watchFocus(); self.model = model
        panel.keyAction = { [weak self] event in
            let keys: [UInt16: String] = [53: "Escape", 36: "Enter", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp"]
            if let key = keys[event.keyCode] { _ = self?.capture(CapturedInput("keyDown", key: key)) }
        }
        panel.contentView = NSHostingView(rootView: (HistoryDetailsView(model: model, filter: filter) { [weak self] in self?.choose($0) }).shareMouseSurface())
        details = panel; panel.center(); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel)
    }
}
private struct HistoryToolbar: View {
    @ObservedObject private var appearance = SMAppearance.shared
    @ObservedObject var model: PairingViewModel
    @ObservedObject fileprivate var filter: HistoryFilter
    var body: some View { HStack(spacing: 6) {
        TextField("搜索历史", text: $filter.search).textFieldStyle(SMInputStyle()).onChange(of: filter.search) { _, _ in filter.selection = 0 }
        Button("同步") { model.syncHistory() }
        Button("收藏") { filter.favorites.toggle(); filter.selection = 0 }.buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 4).background(filter.favorites ? SMTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 5)).accessibilityValue(filter.favorites ? "已开启" : "已关闭")
    }.font(.caption) }
}
private struct CompactHistoryView: View {
    @ObservedObject private var appearance = SMAppearance.shared
    @ObservedObject var model: PairingViewModel
    @ObservedObject fileprivate var filter: HistoryFilter
    let selected: (HistoryEntry) -> Void
    let settings: () -> Void
    let details: () -> Void
    var body: some View { VStack(spacing: 6) {
        ScrollView { VStack(spacing: 4) {
            if filter.visible(model).isEmpty { Text("没有匹配的文本历史").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 30) }
            ForEach(Array(filter.visible(model).enumerated()), id: \.element.id) { number, entry in
                HStack(spacing: 6) {
                    Button(entry.favorite ? "★" : "☆") { model.favoriteHistory(entry.id) }.buttonStyle(.plain).foregroundStyle(entry.favorite ? Color.orange : Color.secondary).help("收藏／取消收藏")
                    Button { selected(entry) } label: { HStack(spacing: 7) { Text(String(number + 1)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary); Text(entry.text.isEmpty ? "（空文本）" : entry.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }.contentShape(Rectangle()) }.buttonStyle(.plain)
                }.font(.callout).padding(.horizontal, 8).frame(height: 32).background(filter.index(model) == filter.page(model) * model.historyVisibleCount + number ? SMTheme.selection : SMTheme.surface, in: RoundedRectangle(cornerRadius: 7))
            }
        } }
        HStack(spacing: 6) { HistoryToolbar(model: model, filter: filter); Button("设置", action: settings); Button("详细", action: details) }.font(.caption)
        HStack { Button("‹") { filter.move(-model.historyVisibleCount, model) }; Text("\(filter.page(model) + 1) / \(max(1, (filter.entries(model).count + model.historyVisibleCount - 1) / model.historyVisibleCount)) 页"); Button("›") { filter.move(model.historyVisibleCount, model) }; Spacer(); Text("↑↓ 选择 · ←→ 翻页 · 1–9／Enter 粘贴") }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
    }.padding(9).background(SMTheme.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SMTheme.border)) }
}
private struct HistorySettingsView: View {
    @ObservedObject private var appearance = SMAppearance.shared
    @ObservedObject var model: PairingViewModel
    @State private var capacity = "50"
    @State private var key = "KeyV"
    @State private var modifiers = "Control+Alt"
    var body: some View { VStack(alignment: .leading, spacing: 16) {
        GroupBox("快捷面板") { VStack(alignment: .leading, spacing: 8) {
            Stepper("每页 \(model.historyVisibleCount) 条", value: Binding(get: { model.historyVisibleCount }, set: { model.configureHistoryPopup($0, side: model.historySide) }), in: 1...9)
            Picker("偏好位置", selection: Binding(get: { model.historySide }, set: { model.configureHistoryPopup(model.historyVisibleCount, side: $0) })) { Text("右侧").tag("right"); Text("左侧").tag("left") }
            Text("条目数只控制每页大小，所有历史均可翻页查看。").font(.caption).foregroundStyle(.secondary)
        }.padding(6) }
        GroupBox("存储与快捷键") { VStack(alignment: .leading, spacing: 8) {
            HStack { Text("历史容量"); TextField("1–1000", text: $capacity).frame(width: 65); Spacer() }
            HStack { Picker("按键", selection: $key) { ForEach(["KeyV", "KeyH", "KeyB"], id: \.self) { Text(String($0.suffix(1))).tag($0) } }; Picker("修饰键", selection: $modifiers) { ForEach(["Control+Alt", "Meta+Alt", "Control+Shift", "Meta+Shift"], id: \.self) { Text($0).tag($0) } } }
            HStack { Button("保存") { model.configureHistory(Int(capacity) ?? 50, key: key, modifiers: modifiers.components(separatedBy: "+")) }; Button("分享收藏") { model.shareFavorites() } }
        }.padding(6) }
        Text(model.historyStatus).font(.caption).foregroundStyle(.secondary)
        Text("收藏长期保留；显示、容量和快捷键设置仅保存在本机。").font(.caption).foregroundStyle(.secondary)
    }.padding(18).onAppear { capacity = String(model.historyCapacity); key = model.historyKey; modifiers = model.historyModifiers.joined(separator: "+") } }
}
private struct HistoryDetailsView: View {
    @ObservedObject private var appearance = SMAppearance.shared
    @ObservedObject var model: PairingViewModel
    @ObservedObject fileprivate var filter: HistoryFilter
    let selected: (HistoryEntry) -> Void
    @State private var expanded: Set<String> = []
    var body: some View { VStack(spacing: 12) {
        HistoryToolbar(model: model, filter: filter)
        ScrollViewReader { proxy in ScrollView { LazyVStack(alignment: .leading, spacing: 10) { ForEach(filter.entries(model), id: \.id) { entry in
            VStack(alignment: .leading, spacing: 8) {
                HStack { Button(entry.favorite ? "★" : "☆") { model.favoriteHistory(entry.id) }; Spacer(); Button(expanded.contains(entry.id) ? "收起" : "展开全文") { if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) } }; Button("粘贴") { selected(entry) } }.font(.caption)
                Text(entry.text.isEmpty ? "（空文本）" : entry.text).lineLimit(expanded.contains(entry.id) ? nil : 10).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).background(filter.entries(model).indices.contains(filter.index(model)) && filter.entries(model)[filter.index(model)].id == entry.id ? SMTheme.selection : SMTheme.surface, in: RoundedRectangle(cornerRadius: 9)).id(entry.id)
        } } }.onChange(of: filter.selection) { _, _ in let entries = filter.entries(model); if !entries.isEmpty { proxy.scrollTo(entries[filter.index(model)].id, anchor: .center) } } }
        Text("默认最多展示 10 行；展开可查看全文，粘贴始终保留完整内容。").font(.caption).foregroundStyle(.secondary)
    }.padding(16) }
}
