import AppKit
import SwiftUI

private final class HistoryPanel: NSPanel {
    var keyAction: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if let keyAction { keyAction(event) } else { super.keyDown(with: event) }
    }
}
@MainActor private final class HistoryFilter: ObservableObject {
    @Published var search = ""
    @Published var favorites = false
    @Published var selection = 0
    func entries(_ model: PairingViewModel) -> [HistoryEntry] {
        model.historyEntries.filter {
            (!favorites || $0.favorite) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search))
        }
    }
    func index(_ model: PairingViewModel) -> Int { min(max(0, selection), max(0, entries(model).count - 1)) }
    func page(_ model: PairingViewModel) -> Int { index(model) / model.historyVisibleCount }
    func visible(_ model: PairingViewModel) -> [HistoryEntry] {
        Array(entries(model).dropFirst(page(model) * model.historyVisibleCount).prefix(model.historyVisibleCount))
    }
    func move(_ amount: Int, _ model: PairingViewModel) {
        selection = min(max(0, index(model) + amount), max(0, entries(model).count - 1))
    }
}
@MainActor final class HistoryPopup: NSObject, NSWindowDelegate {
    private var panel: HistoryPanel?
    private var settings: NSPanel?
    private var details: HistoryPanel?
    private var mouseMonitor: Any?
    private func watchFocus() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window, window === self.panel || window === self.details,
                let content = window.contentView
            else { return event }
            var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
            while let candidate = view {
                if let field = candidate as? NSTextField, field.isEditable { return event }
                if let text = candidate as? NSTextView, text.isEditable { return event }
                view = candidate.superview
            }
            window.makeFirstResponder(window);
            return event
        }
    }
    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) };
        mouseMonitor = nil;
        panel?.orderOut(nil);
        details?.orderOut(nil);
        settings?.orderOut(nil)
    }
    private var filter = HistoryFilter()
    private var model: PairingViewModel?
    private var previousApplication: NSRunningApplication?
    private var previousWindow: NSWindow?
    private var consumed: Set<String> = []
    func show(_ model: PairingViewModel) {
        if panel?.isVisible == true {
            dismiss();
            return
        }
        watchFocus();
        self.model = model;
        filter = HistoryFilter()
        previousApplication = NSWorkspace.shared.frontmostApplication;
        previousWindow = NSApp.keyWindow
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame, width = min(400.0, area.width),
            height = min(Double(model.historyVisibleCount * 34 + 116), area.height)
        let right = point.x + 12, left = point.x - 12 - width
        let preferred = model.historySide == "left" ? left : right,
            alternate = model.historySide == "left" ? right : left
        let x = preferred >= area.minX && preferred + width <= area.maxX ? preferred : alternate
        let frame = NSRect(
            x: min(max(area.minX, x), area.maxX - width),
            y: min(max(area.minY, point.y - height + 16), area.maxY - height), width: width, height: height)
        let panel = HistoryPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false;
        panel.isFloatingPanel = true;
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false;
        panel.isOpaque = false;
        panel.backgroundColor = .clear;
        panel.hasShadow = true;
        panel.delegate = self
        panel.keyAction = { [weak self] event in
            let keys: [UInt16: String] = [
                53: "Escape", 36: "Enter", 76: "Enter", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown",
                126: "ArrowUp",
            ]
            _ = self?.capture(
                CapturedInput(
                    "keyDown", key: keys[event.keyCode] ?? "Digit" + (event.charactersIgnoringModifiers ?? "")))
        }
        panel.contentView = NSHostingView(
            rootView: (CompactHistoryView(
                model: model, filter: filter, selected: { [weak self] in self?.choose($0) },
                settings: { [weak self] in
                    self?.dismiss();
                    self?.showManagement(model)
                },
                details: { [weak self] in
                    self?.dismiss();
                    self?.showDetails(model)
                })).shareMouseSurface(background: false))
        self.panel = panel;
        panel.makeKeyAndOrderFront(nil);
        panel.makeFirstResponder(panel)
    }
    func capture(_ input: CapturedInput) -> Bool {
        guard let key = input.key, ["keyDown", "keyUp"].contains(input.type) else { return false }
        if input.type == "keyUp" { return consumed.remove(key) != nil }
        if consumed.contains(key) { return true }
        guard let active = details?.isKeyWindow == true ? details : panel, active.isVisible, active.isKeyWindow,
            let model, !["Control", "Alt", "Shift", "Meta"].contains(where: { key.hasPrefix($0) })
        else { return false }
        if let editor = active.firstResponder as? NSTextView, editor.isFieldEditor, key != "Escape", key != "Enter" {
            return false
        }
        guard
            ["Escape", "Enter", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].contains(key)
                || (key.hasPrefix("Digit") || key.hasPrefix("Numpad"))
                    && (1...9).contains(key.last?.wholeNumberValue ?? 0)
        else { return false }
        consumed.insert(key)
        switch key {
        case "Escape":
            details?.orderOut(nil);
            dismiss()
        case "ArrowUp": filter.move(-1, model)
        case "ArrowDown": filter.move(1, model)
        case "ArrowLeft": filter.move(-model.historyVisibleCount, model)
        case "ArrowRight": filter.move(model.historyVisibleCount, model)
        case "Enter":
            let all = filter.entries(model);
            if !all.isEmpty { choose(all[filter.index(model)]) }
        default:
            if (key.hasPrefix("Digit") || key.hasPrefix("Numpad")), let digit = key.last?.wholeNumberValue {
                let visible = filter.visible(model);
                if (1...9).contains(digit), digit <= visible.count { choose(visible[digit - 1]) }
            }
        }
        return true
    }
    private func choose(_ entry: HistoryEntry) {
        let target = previousApplication, model = self.model
        details?.orderOut(nil);
        dismiss()
        model?.selectHistory(entry, paste: true, expectedApplication: target?.processIdentifier)
    }
    private func dismiss() {
        panel?.orderOut(nil)
        if let app = previousApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            NSApp.yieldActivation(to: app);
            app.activate(from: .current, options: [])
        } else if let previousWindow, previousWindow.isVisible {
            previousWindow.makeKeyAndOrderFront(nil)
        }
    }
    func windowDidResignKey(_ notification: Notification) { if panel?.isVisible == true { panel?.orderOut(nil) } }
    func showManagement(_ model: PairingViewModel) {
        if let settings, settings.isVisible {
            settings.makeKeyAndOrderFront(nil);
            return
        }
        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "剪贴板设置";
        panel.isReleasedWhenClosed = false;
        panel.level = .popUpMenu;
        panel.isFloatingPanel = true;
        panel.hidesOnDeactivate = false
        SMWindowChrome.install(panel, showsTitle: true)
        panel.contentView = NSHostingView(rootView: (HistorySettingsView(model: model)).shareMouseSurface())
        settings = panel;
        panel.center();
        panel.makeKeyAndOrderFront(nil)
    }
    private func showDetails(_ model: PairingViewModel) {
        if let details, details.isVisible {
            details.makeKeyAndOrderFront(nil);
            return
        }
        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 580),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "剪贴板详细记录";
        panel.isReleasedWhenClosed = false;
        panel.level = .popUpMenu;
        panel.isFloatingPanel = true;
        panel.hidesOnDeactivate = false
        SMWindowChrome.install(panel, showsTitle: true)
        watchFocus();
        self.model = model
        panel.keyAction = { [weak self] event in
            let keys: [UInt16: String] = [
                53: "Escape", 36: "Enter", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
            ]
            if let key = keys[event.keyCode] { _ = self?.capture(CapturedInput("keyDown", key: key)) }
        }
        panel.contentView = NSHostingView(
            rootView: (HistoryDetailsView(model: model, filter: filter) { [weak self] in self?.choose($0) })
                .shareMouseSurface())
        details = panel;
        panel.center();
        panel.makeKeyAndOrderFront(nil);
        panel.makeFirstResponder(panel)
    }
}
private struct HistoryToolbar: View {
    @ObservedObject private var appearance = SMAppearance.shared
    @ObservedObject var model: PairingViewModel
    @ObservedObject fileprivate var filter: HistoryFilter
    var body: some View {
        HStack(spacing: 6) {
            TextField("搜索历史", text: $filter.search).textFieldStyle(.roundedBorder).onChange(of: filter.search) { _, _ in
                filter.selection = 0
            }
            Toggle(isOn: $filter.favorites) { Image(systemName: filter.favorites ? "star.fill" : "star") }.toggleStyle(
                .button
            ).help(filter.favorites ? "显示全部" : "只看收藏").accessibilityLabel("只看收藏").onChange(of: filter.favorites) {
                _, _ in filter.selection = 0
            }
            Button {
                model.syncHistory()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }.help("同步历史").accessibilityLabel("同步历史")
        }.controlSize(.small)
    }
}
private struct CompactHistoryView: View {
    @ObservedObject private var appearance = SMAppearance.shared
    @ObservedObject var model: PairingViewModel
    @ObservedObject fileprivate var filter: HistoryFilter
    let selected: (HistoryEntry) -> Void
    let settings: () -> Void
    let details: () -> Void
    var body: some View {
        let visible = filter.visible(model)
        let current = filter.index(model) - filter.page(model) * model.historyVisibleCount
        let pages = max(1, (filter.entries(model).count + model.historyVisibleCount - 1) / model.historyVisibleCount)
        VStack(alignment: .leading, spacing: 8) {
            HistoryToolbar(model: model, filter: filter)
            VStack(spacing: 2) {
                if visible.isEmpty {
                    Text(filter.search.isEmpty && !filter.favorites ? "还没有文本历史。复制一段文字后会出现在这里。" : "没有匹配的历史").font(
                        .callout
                    ).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 32)
                }
                ForEach(Array(visible.enumerated()), id: \.element.id) { number, entry in
                    row(entry, number: number, isSelected: number == current)
                }
            }.frame(maxHeight: .infinity, alignment: .top)
            HStack(spacing: 4) {
                Button {
                    filter.move(-model.historyVisibleCount, model)
                } label: {
                    Image(systemName: "chevron.left")
                }.help("上一页").accessibilityLabel("上一页")
                Text("\(filter.page(model) + 1) / \(pages)").font(.system(size: 11).monospacedDigit()).foregroundStyle(
                    .secondary
                ).frame(minWidth: 36)
                Button {
                    filter.move(model.historyVisibleCount, model)
                } label: {
                    Image(systemName: "chevron.right")
                }.help("下一页").accessibilityLabel("下一页")
                Spacer()
                Button(action: settings) { Image(systemName: "gearshape") }.help("剪贴板设置").accessibilityLabel("剪贴板设置")
                Button(action: details) { Image(systemName: "list.bullet.rectangle") }.help("详细记录").accessibilityLabel(
                    "详细记录")
            }.buttonStyle(.borderless)
            HStack(spacing: 12) {
                SMKeyHint(keys: ["↑", "↓"], text: "选择")
                SMKeyHint(keys: ["←", "→"], text: "翻页")
                SMKeyHint(keys: ["1–9", "↩"], text: "粘贴")
            }
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background {
            SMMaterialBackground(material: .popover, cornerRadius: 12)
        }.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SMTheme.border, lineWidth: 0.5))
    }
    private func row(_ entry: HistoryEntry, number: Int, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                selected(entry)
            } label: {
                HStack(spacing: 8) {
                    SMKeyCap(String(number + 1))
                    Text(
                        entry.text.isEmpty
                            ? "（空文本）"
                            : entry.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(
                                of: "\r", with: " ")
                    ).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button {
                model.favoriteHistory(entry.id)
            } label: {
                Image(systemName: entry.favorite ? "star.fill" : "star").foregroundStyle(
                    entry.favorite ? Color.orange : Color.secondary)
            }.buttonStyle(.plain).help(entry.favorite ? "取消收藏" : "收藏").accessibilityLabel(
                entry.favorite ? "取消收藏" : "收藏")
        }.font(.system(size: 13)).padding(.horizontal, 8).frame(height: 32).background(
            isSelected ? SMTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
}
private struct HistorySettingsView: View {
    @ObservedObject private var appearance = SMAppearance.shared
    @ObservedObject var model: PairingViewModel
    @State private var capacity = "50"
    @State private var key = "KeyV"
    @State private var modifiers = "Control+Alt"
    private static let modifierNames = [
        "Control+Alt": "⌃ Control + ⌥ Option", "Meta+Alt": "⌘ Command + ⌥ Option",
        "Control+Shift": "⌃ Control + ⇧ Shift", "Meta+Shift": "⌘ Command + ⇧ Shift",
    ]
    private static let modifierSymbols = ["Control": "⌃", "Alt": "⌥", "Shift": "⇧", "Meta": "⌘"]
    private var capacityValue: Int? {
        Int(capacity.trimmingCharacters(in: .whitespaces)).flatMap { (1...1000).contains($0) ? $0 : nil }
    }
    private var shortcut: [String] {
        modifiers.components(separatedBy: "+").map { Self.modifierSymbols[$0] ?? $0 } + [String(key.suffix(1))]
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("快捷面板") {
                    Stepper(
                        "每页 \(model.historyVisibleCount) 条",
                        value: Binding(
                            get: { model.historyVisibleCount },
                            set: { model.configureHistoryPopup($0, side: model.historySide) }), in: 1...9)
                    Picker(
                        "弹出位置",
                        selection: Binding(
                            get: { model.historySide },
                            set: { model.configureHistoryPopup(model.historyVisibleCount, side: $0) })
                    ) {
                        Text("鼠标右侧").tag("right");
                        Text("鼠标左侧").tag("left")
                    }.pickerStyle(.segmented)
                }
                Section {
                    LabeledContent("历史容量") {
                        HStack(spacing: 6) {
                            TextField("", text: $capacity).labelsHidden().multilineTextAlignment(.trailing).frame(
                                width: 70);
                            Text("条").foregroundStyle(.secondary)
                        }
                    }
                    if capacityValue == nil { Text("请输入 1 到 1000 之间的数字").font(.caption).foregroundStyle(.red) }
                } header: {
                    Text("存储")
                } footer: {
                    Text("每页条数只决定快捷面板一页显示多少条，全部历史都可以翻页查看。收藏的条目会一直保留。这些设置只保存在本机。").font(.caption).foregroundStyle(
                        .secondary)
                }
                Section("快捷键") {
                    Picker("按键", selection: $key) {
                        ForEach(["KeyV", "KeyH", "KeyB"], id: \.self) { Text(String($0.suffix(1))).tag($0) }
                    }
                    Picker("修饰键", selection: $modifiers) {
                        ForEach(["Control+Alt", "Meta+Alt", "Control+Shift", "Meta+Shift"], id: \.self) {
                            Text(Self.modifierNames[$0] ?? $0).tag($0)
                        }
                    }
                    LabeledContent("组合") { HStack(spacing: 3) { ForEach(shortcut, id: \.self) { SMKeyCap($0) } } }
                }
            }.formStyle(.grouped)
            HStack(spacing: 10) {
                Button("分享收藏") { model.shareFavorites() }
                Text(model.historyStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button("保存") {
                    if let value = capacityValue {
                        model.configureHistory(value, key: key, modifiers: modifiers.components(separatedBy: "+"))
                    }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(capacityValue == nil)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.onAppear {
            capacity = String(model.historyCapacity);
            key = model.historyKey;
            modifiers = model.historyModifiers.joined(separator: "+")
        }
    }
}
private struct HistoryDetailsView: View {
    @ObservedObject private var appearance = SMAppearance.shared
    @ObservedObject var model: PairingViewModel
    @ObservedObject fileprivate var filter: HistoryFilter
    let selected: (HistoryEntry) -> Void
    @State private var expanded: Set<String> = []
    var body: some View {
        let entries = filter.entries(model)
        let current = entries.indices.contains(filter.index(model)) ? entries[filter.index(model)].id : nil
        VStack(spacing: 12) {
            HistoryToolbar(model: model, filter: filter)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if entries.isEmpty {
                            Text("没有匹配的历史").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                        }
                        ForEach(entries, id: \.id) { entry in card(entry, isSelected: entry.id == current).id(entry.id)
                        }
                    }.padding(.vertical, 2)
                }.onChange(of: filter.selection) { _, _ in
                    let all = filter.entries(model);
                    if !all.isEmpty { proxy.scrollTo(all[filter.index(model)].id, anchor: .center) }
                }
            }
            Text("默认最多显示 10 行，展开可查看全文；粘贴时始终使用完整内容。").font(.caption).foregroundStyle(.secondary).frame(
                maxWidth: .infinity, alignment: .leading)
        }.padding(16)
    }
    private func card(_ entry: HistoryEntry, isSelected: Bool) -> some View {
        let open = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.favoriteHistory(entry.id)
                } label: {
                    Image(systemName: entry.favorite ? "star.fill" : "star").foregroundStyle(
                        entry.favorite ? Color.orange : Color.secondary)
                }.help(entry.favorite ? "取消收藏" : "收藏").accessibilityLabel(entry.favorite ? "取消收藏" : "收藏")
                Spacer()
                Button {
                    if open { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                } label: {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                }.help(open ? "收起" : "展开全文").accessibilityLabel(open ? "收起" : "展开全文")
                Button {
                    selected(entry)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }.help("粘贴").accessibilityLabel("粘贴")
            }.buttonStyle(.borderless)
            Text(entry.text.isEmpty ? "（空文本）" : entry.text).lineLimit(open ? nil : 10).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(
            isSelected ? SMTheme.selection : SMTheme.surface, in: RoundedRectangle(cornerRadius: 9)
        ).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SMTheme.border, lineWidth: 0.5))
    }
}
