import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct KeyCatalog: Decodable {
    struct Key: Decodable, Identifiable {
        let id, mac, windows, shift, side, category: String;
        let icon, macFunction, windowsFunction: String?;
        let supported: Bool
    }
    struct Position: Decodable, Identifiable {
        let key: String;
        let x, y, w, h: Double;
        var id: String { key }
    }
    let keys: [Key];
    let layouts: [String: [Position]];
    let icons: [String: String]
    static let shared = load()
    static func load() -> KeyCatalog? {
        guard let url = Bundle.main.url(forResource: "keyboard-layouts", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func enabled(_ id: String, platform: String, forInjection: Bool = false) -> Bool {
        id == KeyboardMapping.noAction
            || (keys.contains { $0.id == id && $0.supported }
                && (!forInjection || KeyboardMapping.canInject(id, on: platform)))
    }
}
// Assets use the SVG path commands M/L/Z; render the same vector geometry on both platforms.
private struct KeySVG: Shape {
    let svg: String
    private static let paths: [String: Path] = {
        var result: [String: Path] = [:]
        for svg in KeyCatalog.shared?.icons.values ?? Dictionary<String, String>().values { result[svg] = parse(svg) }
        return result
    }()
    private static func parse(_ svg: String) -> Path {
        let tokens = svg.replacingOccurrences(of: "([MLZ])", with: " $1 ", options: .regularExpression).split(
            separator: " "
        ).map(String.init)
        var path = Path(), i = 0, command = "M"
        while i < tokens.count {
            if ["M", "L", "Z"].contains(tokens[i]) {
                command = tokens[i];
                i += 1;
                if command == "Z" {
                    path.closeSubpath();
                    continue
                }
            }
            guard i + 1 < tokens.count, let x = Double(tokens[i]), let y = Double(tokens[i + 1]) else { break };
            i += 2
            let point = CGPoint(x: x, y: y)
            if command == "M" {
                path.move(to: point);
                command = "L"
            } else {
                path.addLine(to: point)
            }
        };
        return path
    }
    func path(in rect: CGRect) -> Path {
        (Self.paths[svg] ?? Self.parse(svg)).applying(
            CGAffineTransform(a: rect.width / 24, b: 0, c: 0, d: rect.height / 24, tx: rect.minX, ty: rect.minY))
    }
}

struct ConfigEditor: View {
    @ObservedObject private var appearance = SMAppearance.shared
    let owner: String
    let save: @MainActor ([KeyboardConfig], String) async throws -> Void
    @State var configs: [KeyboardConfig]
    @State var selected: String
    @State private var source = "macos"
    @State private var search = ""
    @State private var selectedKey: String?
    @State private var hovered: String?
    @State private var status = "自动保存；拖动右侧按键到下方键盘。"
    @State private var dropKey: String?
    @State private var savePending = false
    @State private var saving = false
    @State private var revision = 0
    private let catalog = KeyCatalog.shared
    private var target: String { source == "macos" ? "windows" : "macos" }
    private var index: Int? { configs.firstIndex { $0.id == selected } }
    private var config: KeyboardConfig? { index.map { configs[$0] } }
    private var overrides: [String: String] {
        source == "macos" ? config?.macToWindows ?? [:] : config?.windowsToMac ?? [:]
    }
    private func mapped(_ key: String) -> String { KeyboardMapping.map(key, from: source, to: target, config: config) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("配置", selection: $selected) { ForEach(configs, id: \.id) { Text($0.name).tag($0.id) } }.frame(
                    width: 260)
                Button("新建") {
                    let c = KeyboardConfig(
                        id: UUID().uuidString.lowercased(), ownerPeerID: owner, name: "新配置", windowsToMac: [:],
                        macToWindows: [:], revision: 1);
                    configs.append(c);
                    selected = c.id;
                    changed()
                }.disabled(configs.count >= 64)
                Button("复制") {
                    if var c = config {
                        c.id = UUID().uuidString.lowercased();
                        c.ownerPeerID = owner;
                        c.name += "（副本）";
                        c.revision = 1;
                        configs.append(c);
                        selected = c.id;
                        changed()
                    }
                }.disabled(configs.count >= 64)
                Button("删除") {
                    if configs.count > 1 {
                        let id = selected;
                        Task {
                            if await ShareMouseDialog.chooseAsync(
                                "删除键盘配置？", "将删除“\(configs.first(where:{$0.id==id})?.name ?? "这个配置")”。",
                                choices: [("cancel", "取消"), ("delete", "删除")], kind: .destructive) == "delete",
                                configs.count > 1
                            {
                                configs.removeAll { $0.id == id };
                                selected = configs[0].id;
                                changed()
                            }
                        }
                    }
                }.disabled(configs.count < 2)
                Spacer()
            }
            HStack {
                if let i = index {
                    TextField(
                        "配置名称",
                        text: Binding(
                            get: { configs[i].name },
                            set: {
                                configs[i].name = String($0.prefix(40));
                                if !configs[i].name.isEmpty { changed() }
                            })
                    ).frame(width: 240).textFieldStyle(SMInputStyle())
                }
                Picker("来源", selection: $source) {
                    Text("macOS").tag("macos");
                    Text("Windows").tag("windows")
                }.frame(width: 190)
                Image(systemName: "arrow.right")
                Picker("目标", selection: Binding(get: { target }, set: { source = $0 == "macos" ? "windows" : "macos" }))
                {
                    Text("macOS").tag("macos");
                    Text("Windows").tag("windows")
                }.frame(width: 190)
                Spacer()
            }
            if let catalog {
                HStack(alignment: .top, spacing: 18) {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("来源键盘 · 只读参考").font(.headline)
                            keyboard(catalog, editable: false)
                            Text("目标映射 · 保持来源键盘的位置与形状").font(.headline).padding(.top, 14)
                            keyboard(catalog, editable: true)
                            if let key = selectedKey {
                                Text(
                                    "\(label(key,platform:source,catalog:catalog)) → \(label(mapped(key),platform:target,catalog:catalog))"
                                ).font(.callout);
                                Button("恢复所选按键默认映射") { setMapping(key, nil) }
                            }
                            Button("恢复此方向全部默认映射") {
                                if let i = index {
                                    if source == "macos" {
                                        configs[i].macToWindows = [:]
                                    } else {
                                        configs[i].windowsToMac = [:]
                                    };
                                    changed()
                                }
                            }
                            Text(
                                "Mac→Windows：不按来源 Fn 的顶行按目标同号功能执行；按来源 Fn 输出普通 F1–F12，暂时释放它映射的修饰键。Fn／Command 的位置使用系统当前设置，不重复交换。"
                            ).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 790, alignment: .leading)
                        }.padding(4)
                    }
                    VStack(alignment: .leading) {
                        Text("\(target=="macos" ? "macOS":"Windows") 按键库").font(.headline)
                        TextField("搜索名称 / KeyID", text: $search).textFieldStyle(SMInputStyle())
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                libraryKey(KeyboardMapping.noAction, catalog: catalog)
                                ForEach(["字母", "数字与符号", "修饰键", "导航与编辑", "F1-F24", "特殊"], id: \.self) { category in
                                    let items = catalog.keys.filter {
                                        $0.category == category
                                            && (category != "F1-F24" || (Int($0.id.dropFirst()) ?? 0) <= 12)
                                            && $0.id != KeyboardMapping.noAction
                                            && (search.isEmpty
                                                || ($0.id + " " + $0.mac + " " + $0.windows)
                                                    .localizedCaseInsensitiveContains(search))
                                    }
                                    if !items.isEmpty {
                                        Text(category == "F1-F24" ? "F1–F12" : category).font(.caption).foregroundStyle(
                                            .secondary
                                        ).padding(.top, 6)
                                        LazyVGrid(
                                            columns: [
                                                GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
                                            ], spacing: 6
                                        ) { ForEach(items) { key in libraryKey(key.id, catalog: catalog) } }
                                    }
                                }
                            }.padding(3)
                        }
                        Text("可重复拖入；也可选中下方按键后点击库中按键。").font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 230)
                }
            } else {
                Text("键盘布局资源无法读取").foregroundStyle(.red)
            }
            Text(status).font(.caption).foregroundStyle(status.contains("失败") ? .red : .secondary)
        }.padding(20).frame(minWidth: 1080, minHeight: 730).onChange(of: selected) { _, _ in
            selectedKey = nil;
            changed()
        }.onChange(of: source) { _, _ in
            selectedKey = nil;
            hovered = nil
        }
    }
    private func label(_ id: String, platform: String, catalog: KeyCatalog) -> String {
        if id == KeyboardMapping.noAction { return "No Action" }
        guard let k = catalog.keys.first(where: { $0.id == id }) else { return id }
        return (platform == "macos" ? k.mac : k.windows) + (k.side.isEmpty ? "" : " · " + k.side)
    }
    @ViewBuilder private func face(_ id: String, platform: String, catalog: KeyCatalog) -> some View {
        let key = catalog.keys.first { $0.id == id };
        let icon = (id == "Fn" || key?.category == "功能键" ? nil : key?.icon).map {
            $0 == "command" ? (platform == "macos" ? "command" : "windows") : $0
        }
        VStack(spacing: 1) {
            if let icon, let svg = catalog.icons[icon] {
                KeySVG(svg: svg).stroke(lineWidth: 1.4).frame(width: 17, height: 17)
            } else {
                Text(id == KeyboardMapping.noAction ? "∅" : (platform == "macos" ? key?.mac : key?.windows) ?? id).font(
                    .system(size: 11, weight: .medium)
                ).lineLimit(1)
            }
            if let key, !key.shift.isEmpty { Text(key.shift).font(.system(size: 9)).foregroundStyle(.secondary) }
            if let key, !key.side.isEmpty { Text(key.side).font(.system(size: 8)).foregroundStyle(.secondary) }
        }
    }
    private func keyboard(_ catalog: KeyCatalog, editable: Bool) -> some View {
        let positions = catalog.layouts[source] ?? [];
        let unit: Double = source == "macos" ? 51 : 44
        return ZStack(alignment: .topLeading) {
            ForEach(positions) { position in keyPosition(position, catalog: catalog, editable: editable, unit: unit) }
        }.frame(
            width: (positions.map { $0.x + $0.w }.max() ?? 15) * unit,
            height: (positions.map { $0.y + $0.h }.max() ?? 6) * unit, alignment: .topLeading
        ).padding(12).background(SMTheme.well, in: RoundedRectangle(cornerRadius: 12)).overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(SMTheme.border))
    }
    private func keyPosition(_ position: KeyCatalog.Position, catalog: KeyCatalog, editable: Bool, unit: Double)
        -> some View
    {
        let key = position.key;
        let destination = editable ? mapped(key) : key
        let enabled = catalog.enabled(key, platform: source), linked = key == (hovered ?? selectedKey)
        let dropping = dropKey == key && editable
        let border: Color =
            !enabled
            ? .gray.opacity(0.3)
            : dropping
                ? .green : linked ? SMTheme.accent : editable && overrides[key] != nil ? .orange : .gray.opacity(0.5)
        return face(destination, platform: editable ? target : source, catalog: catalog).frame(
            width: position.w * unit - 4, height: position.h * unit - 4
        ).modifier(SMKeyMaterial(selected: linked || dropping, border: border)).opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle()).onHover { inside in hovered = inside ? key : nil }.onTapGesture {
                selectedKey = key
            }.onDrop(
                of: [UTType.plainText],
                isTargeted: Binding(get: { dropKey == key && editable }, set: { dropKey = $0 ? key : nil })
            ) { providers in
                guard editable, enabled, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    let id = value as? String
                    Task { @MainActor in
                        if let id, catalog.enabled(id, platform: target, forInjection: true) { setMapping(key, id) };
                        dropKey = nil
                    }
                };
                return true
            }.help(
                enabled
                    ? label(key, platform: source, catalog: catalog)
                        + (editable ? " → " + label(destination, platform: target, catalog: catalog) : "")
                    : "此平台无法可靠捕获该按键"
            ).offset(x: position.x * unit, y: position.y * unit)
    }
    private func libraryKey(_ id: String, catalog: KeyCatalog) -> some View {
        let enabled = catalog.enabled(id, platform: target, forInjection: true)
        return face(id, platform: target, catalog: catalog).frame(maxWidth: .infinity, minHeight: 42).modifier(
            SMKeyMaterial()
        ).opacity(enabled ? 1 : 0.35).onDrag { NSItemProvider(object: (enabled ? id : "") as NSString) }.onTapGesture {
            if enabled, let key = selectedKey, catalog.enabled(key, platform: source) { setMapping(key, id) }
        }.help(label(id, platform: target, catalog: catalog))
    }
    private func setMapping(_ key: String, _ targetKey: String?) {
        guard let i = index else { return };
        if source == "macos" {
            if let function = KeyboardMapping.macFunction(key) { configs[i].macToWindows.removeValue(forKey: function) }
            configs[i].macToWindows[key] = targetKey
        } else {
            configs[i].windowsToMac[key] = targetKey
        };
        selectedKey = key;
        changed()
    }
    private func changed() {
        revision += 1;
        savePending = true;
        guard !saving else { return };
        saving = true
        Task { @MainActor in
            while savePending {
                savePending = false;
                let r = revision;
                try? await Task.sleep(for: .milliseconds(400))
                if r != revision {
                    savePending = true;
                    continue
                }
                if let i = index { configs[i].modified = Int64(Date().timeIntervalSince1970 * 1000) }
                let snapshot = configs, id = selected
                do {
                    try await save(snapshot, id);
                    status = "已自动保存"
                } catch { status = "保存／同步未完成；编辑内容仍在窗口中，下一次编辑将重试。" }
            };
            saving = false
        }
    }
}
