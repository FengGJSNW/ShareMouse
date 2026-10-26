import AppKit
import Charts
import SwiftUI

// A shared presentation language; no service state is owned by these views.
struct MainView: View {
    @ObservedObject private var appearance = SMAppearance.shared
    let peer: Peer?
    let pairing: PairingViewModel?
    let startupError: String?
    let openLogs: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let titles = ["设备与连接", "屏幕排布", "键盘与鼠标", "剪贴板与传输", "设置"]
    private let symbols = [
        "rectangle.connected.to.line.below", "display.2", "keyboard", "arrow.down.doc", "slider.horizontal.3",
    ]
    private let subtitles = [
        "连接你的设备，让协作自然发生。", "为每一块屏幕，找到合适的位置。", "熟悉的操作，延伸到另一台电脑。", "文字与文件，在设备之间自由流动。", "按照你的习惯，调整 ShareMouse。",
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "computermouse.fill").font(.system(size: 22)).foregroundStyle(SMTheme.accent)
                    Text("ShareMouse").font(.system(size: 18, weight: .semibold))
                }.padding(.vertical, 24).padding(.horizontal, 12)
                Text("工作空间").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(12)
                ForEach(0..<titles.count, id: \.self) { index in
                    Button {
                        withAnimation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)) {
                            page = index
                        }
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(page == index ? SMTheme.module(index) : .clear)
                                .frame(width: 3, height: 20)
                            Image(systemName: symbols[index]).frame(width: 20).foregroundStyle(SMTheme.module(index))
                            Text(titles[index]).font(.system(size: 13, weight: page == index ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }.padding(.vertical, 12).padding(.horizontal, 8).background(
                            page == index ? SMTheme.module(index).opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 9)
                        ).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(page == index ? .isSelected : [])
                }
                Spacer()
                Rectangle().fill(SMTheme.border).frame(height: 1).padding(.vertical, 10)
                Label("一个连续的桌面", systemImage: "circle.grid.2x2").font(.caption).foregroundStyle(.secondary).padding(10)
                SMThemePicker().padding(.horizontal, 8).padding(.bottom, 16)
            }.padding(.horizontal, 12).padding(.top, 28).frame(width: 192).background {
                SMMaterialBackground(material: .sidebar)
            }
            Rectangle().fill(SMTheme.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(titles[page]).font(.system(size: 27, weight: .semibold))
                    Text(subtitles[page]).font(.callout).foregroundStyle(.secondary)
                    Capsule().fill(SMTheme.module(page)).frame(width: 44, height: 4).padding(.top, 5)
                }.padding(28).padding(.top, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let startupError {
                            Label(startupError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                        if let pairing {
                            PairingPanel(model: pairing, page: $page).environment(\.smModule, page)
                        } else {
                            Text("本机初始化失败，请检查身份存储与日志权限。").foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 24)
                }
                HStack {
                    Text("关闭窗口后继续在菜单栏运行").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开日志", action: openLogs)
                }.padding(.horizontal, 28).padding(.vertical, 14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background { SMTheme.canvas }
        }.ignoresSafeArea(.container, edges: .top).frame(minWidth: 920, minHeight: 640)
    }
}

private struct PairingPanel: View {
    @ObservedObject var model: PairingViewModel
    @Binding var page: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Color.clear.frame(height: 0).onAppear { if model.firstRun || model.needsInputPermissions { page = 4 } }
            if page == 4 { SettingsPanel(model: model, preferences: model.preferences) }
            if page == 0 {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {

                        HStack {
                            Label(model.peer.name, systemImage: "laptopcomputer").font(.title2)
                            Spacer()
                            Text("macOS").foregroundStyle(.secondary)
                        }

                        Divider()

                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 12) {

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("设备 ID").font(.caption).foregroundStyle(.secondary)

                                    Text(model.identity.certificatePeer.peerID).font(
                                        .system(.caption, design: .monospaced)
                                    ).textSelection(.enabled)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("公钥").font(.caption).foregroundStyle(.secondary)

                                    Text(ShareMouseDialog.groupedKey(model.identity.certificatePeer.publicKey)).font(
                                        .system(.caption, design: .monospaced)
                                    ).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }.padding(.top, 8)
                        } label: {
                            Label("配对身份", systemImage: "key")
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("本机信息")
                }
                Group {
                    GroupBox("本机配对信息") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("配对码").frame(width: 80, alignment: .leading)
                                TextField("6 位数字", text: $model.localCode).textFieldStyle(SMInputStyle()).frame(
                                    width: 150)
                                Text("密钥").frame(width: 40)
                                if model.revealPassword {
                                    TextField("可选密钥", text: $model.localPassword).textFieldStyle(SMInputStyle())
                                } else {
                                    SecureField("可选密钥", text: $model.localPassword).textFieldStyle(SMInputStyle())
                                }
                            }
                            HStack {
                                Toggle("显示密钥", isOn: $model.revealPassword)
                                Spacer()
                            }
                            HStack {
                                Text("连接方式")
                                Toggle(
                                    "局域网",
                                    isOn: Binding(
                                        get: { model.networkAvailable }, set: { model.setNetworkAvailable($0) }))
                                Toggle(
                                    "蓝牙",
                                    isOn: Binding(
                                        get: { model.bluetoothAvailable }, set: { model.setBluetoothAvailable($0) }))
                                Toggle(
                                    "AI 接口",
                                    isOn: Binding(
                                        get: { model.preferences.mcpEnabled },
                                        set: {
                                            model.preferences.mcpEnabled = $0;
                                            model.configureMCP();
                                            model.objectWillChange.send()
                                        }))
                            }.toggleStyle(.checkbox)
                            Text("配对码与可选密钥适用于两种方式；取消勾选将停止对应方式的对外发现和新连接。").font(.caption).foregroundStyle(.secondary)
                        }.padding(10)
                    }
                    GroupBox("连接其他设备") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                TextField("对方配对码", text: $model.remoteCode).textFieldStyle(SMInputStyle())
                                SecureField("对方密钥（可选）", text: $model.remotePassword).textFieldStyle(SMInputStyle())
                                Button(model.busy ? "连接中…" : "连接") { model.connect() }.disabled(model.busy)
                            }
                            TextField("可选：对方 IP；留空时按配对码查找附近设备", text: $model.remoteHost).textFieldStyle(SMInputStyle())
                            Text("后台自动发现附近设备；验证通过后加入已知设备列表。").font(.caption).foregroundStyle(.secondary)
                            Label(
                                model.status,
                                systemImage: model.status.hasPrefix("连接失败")
                                    ? "exclamationmark.triangle" : model.sessions.isEmpty ? "network" : "lock.shield"
                            ).foregroundStyle(model.status.hasPrefix("连接失败") ? Color.red : Color.primary)
                        }.padding(10)
                    }
                }
                GroupBox("已知设备") {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.knownPeers.isEmpty { Text("完成首次配对后，设备会显示在这里。").foregroundStyle(.secondary) }
                        ForEach(model.knownPeers, id: \.peerID) { known in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(known.name).font(.headline)
                                    Spacer()
                                    if model.sessions.contains(where: { $0.peerID == known.peerID }) {
                                        Button("断开") { model.disconnect(known.peerID) }
                                    } else {
                                        Text("未连接").foregroundStyle(.secondary);
                                        Button("快速连接") { model.quickConnect(known.peerID) }.disabled(model.busy)
                                    }
                                }
                                let transports = model.sessions.first { $0.peerID == known.peerID }?.capabilities ?? []
                                Text(
                                    "网络：" + (transports.contains("tcp") || transports.contains("quic") ? "已连接" : "未连接")
                                        + " · 蓝牙：" + (transports.contains("ble") ? "已连接" : "未连接") + " · MCP："
                                        + (transports.contains("mcp-server") ? "已启用" : "未启用"))
                                Text(model.latencySummary(known.peerID)).font(.caption).foregroundStyle(.secondary)
                                Button(model.latencyTesting.contains(known.peerID) ? "正在测试（10 秒）…" : "延迟抖动测试") {
                                    model.testLatency(known.peerID)
                                }.disabled(
                                    !model.sessions.contains { $0.peerID == known.peerID }
                                        || !model.latencyTesting.isEmpty || !model.throughputTesting.isEmpty)
                                Text(model.throughputSummary(known.peerID)).font(.caption).foregroundStyle(.secondary)
                                Button(model.throughputTesting.contains(known.peerID) ? "正在测速…" : "传输速度测试") {
                                    model.testThroughput(known.peerID)
                                }.disabled(
                                    !model.sessions.contains { $0.peerID == known.peerID }
                                        || !model.throughputTesting.isEmpty || !model.latencyTesting.isEmpty
                                        || !model.throughputTesting.isEmpty)
                                Text("同时测量已连接的网络与蓝牙，本机发送、对方确认；测试会短暂暂停本机键鼠共享。").font(.caption).foregroundStyle(
                                    .secondary)
                                HStack {
                                    Button("删除设备…") {
                                        let id = known.peerID, name = known.name
                                        Task {
                                            if await ShareMouseDialog.chooseAsync(
                                                "删除“\(name)”？", "删除后需要重新配对才能再连接这台设备。",
                                                choices: [("cancel", "取消"), ("delete", "删除")], kind: .destructive)
                                                == "delete"
                                            {
                                                model.deletePeer(id)
                                            }
                                        }
                                    }
                                    Toggle(
                                        "信任",
                                        isOn: Binding(
                                            get: { known.trust == .trusted },
                                            set: {
                                                model.setPreferences(
                                                    known.peerID, trusted: $0, autoConnect: known.autoConnect)
                                            }))
                                    Toggle(
                                        "自动连接",
                                        isOn: Binding(
                                            get: { known.autoConnect },
                                            set: {
                                                model.setPreferences(
                                                    known.peerID, trusted: known.trust == .trusted, autoConnect: $0)
                                            })
                                    ).disabled(known.trust != .trusted)

                                }
                            }
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if page == 1 { ScreenLayoutView(model: model) }
            if page == 2 {
                GroupBox("鼠标共享") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.inputStatus)
                        Toggle(
                            "允许鼠标穿梭到其他电脑",
                            isOn: Binding(
                                get: { model.preferences.screenCrossingEnabled }, set: { model.setScreenCrossing($0) }))
                        Text("Control+Option+Shift+L 切换。关闭后停留在当前电脑，键鼠继续工作，不返回本机。").font(.caption).foregroundStyle(
                            .secondary)
                        HStack {
                            Button("断开") { model.pauseInput() };
                            Button("重连") { model.reconnectInput() }
                        }
                        Toggle(
                            "合盖释放键鼠",
                            isOn: Binding(
                                get: { model.preferences.releaseOnLidClose },
                                set: { model.setAutomaticRelease(lid: $0) }))
                        Toggle(
                            "锁屏释放键鼠",
                            isOn: Binding(
                                get: { model.preferences.releaseOnLock }, set: { model.setAutomaticRelease(lock: $0) }))
                        Text("暂时释放本机键鼠共享，其他电脑继续使用；开盖／解锁后自动恢复。手动断开不会自动恢复，配对和文件连接保留。").font(.caption).foregroundStyle(
                            .secondary)
                        Picker(
                            "本机游戏鼠标",
                            selection: Binding(
                                get: { model.preferences.gameMouseMode },
                                set: {
                                    model.preferences.gameMouseMode = $0;
                                    model.preferences.save();
                                    model.objectWillChange.send()
                                })
                        ) {
                            Text("桌面坐标").tag("auto");
                            Text("游戏相对位移").tag("on")
                        }
                        Text("控制 Mac 游戏视角时，请在本机选择“游戏相对位移”；结束游戏后切回桌面坐标。此模式暂停边缘穿梭，原暂停快捷键可回本机。").font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(
                            "键鼠输入链路",
                            selection: Binding(
                                get: { model.bluetoothInputPreferred }, set: { model.setInputLinkPreference($0) })
                        ) {
                            Text("蓝牙优先").tag(true);
                            Text("Wi-Fi 优先").tag(false)
                        }.pickerStyle(.segmented)
                        Text("所选链路为偏好；不可用时立即回退，延迟明显偏高时在操作间隙选择更快链路。文件和 MCP 优先网络。").font(.caption).foregroundStyle(
                            .secondary)
                        Text(
                            "保留配对和文件连接。Command+Control+Shift+Esc 暂停／恢复键鼠共享（也支持 Control+Option+Shift+Esc），长按只切换一次；任意一端重连即可恢复共享。"
                        ).font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("远端行为设置") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.knownPeers.isEmpty { Text("配对后可为每台设备单独设置。").foregroundStyle(.secondary) }
                        ForEach(model.knownPeers, id: \.peerID) { peer in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(peer.name).fontWeight(.semibold)
                                HStack {
                                    Text("远端鼠标灵敏度");
                                    Spacer();
                                    Text(
                                        String(format: "%.1f×", model.preferences.pointerSensitivity[peer.peerID] ?? 1)
                                    ).monospacedDigit();
                                    Button("重置") { model.setSensitivity(peer.peerID, 1) }
                                }
                                Slider(
                                    value: Binding(
                                        get: { model.preferences.pointerSensitivity[peer.peerID] ?? 1 },
                                        set: { model.setSensitivity(peer.peerID, $0) }), in: 0.1...4, step: 0.1)
                                HStack {
                                    Text("滚动反转")
                                    Toggle(
                                        "左右",
                                        isOn: Binding(
                                            get: { model.preferences.reverseScrollHorizontal[peer.peerID] ?? false },
                                            set: { model.setScrollInversion(peer.peerID, horizontal: $0) }))
                                    Toggle(
                                        "上下",
                                        isOn: Binding(
                                            get: { model.preferences.reverseScrollVertical[peer.peerID] ?? false },
                                            set: { model.setScrollInversion(peer.peerID, vertical: $0) }))
                                }
                                HStack {
                                    Text("左右滚动角度阈值");
                                    Spacer()
                                    Text(
                                        String(
                                            format: "%.0f°", model.preferences.horizontalScrollAngle[peer.peerID] ?? 30)
                                    ).monospacedDigit()
                                    Button("重置") { model.setHorizontalScrollAngle(peer.peerID, 30) }
                                }
                                Slider(
                                    value: Binding(
                                        get: { model.preferences.horizontalScrollAngle[peer.peerID] ?? 30 },
                                        set: { model.setHorizontalScrollAngle(peer.peerID, $0) }), in: 0...90, step: 1)
                                Text("相对竖直方向的角度，默认 30°。0° 不过滤，90° 禁用左右滚动；越过阈值从 0 平滑起步，上下不受影响。").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("按目标电脑分别保存，即时生效。灵敏度包含游戏相对位移；滚动可独立反转左右、上下方向。不改变本机键鼠行为。").font(.caption).foregroundStyle(
                            .secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("键盘配置") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            model.groupState?.configs.first { $0.id == model.groupState?.currentConfigID }?.name
                                ?? "打开配置管理可创建或选择配置")
                        Button("按键映射") { model.editConfig() }
                        Toggle(
                            "启用 Fn 功能组合层",
                            isOn: Binding(
                                get: { model.preferences.fnEnabled }, set: { model.setKeyboardOptions(fn: $0) }))
                        Text("Control+Option+Shift+F 切换；关闭后停用 Fn 功能组合层，保留 Fn→Ctrl。").font(.caption).foregroundStyle(
                            .secondary)
                        Toggle(
                            "启用功能键映射",
                            isOn: Binding(
                                get: { model.preferences.functionKeysEnabled },
                                set: { model.setKeyboardOptions(functions: $0) }))
                        Text("Control+Option+Shift+G 切换；关闭后仍发送普通 F1–F12，不触发亮度、音量等功能。只影响本机发往对端的键盘，原按键映射配置保留。").font(
                            .caption
                        ).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if page == 3 {
                GroupBox("共享剪贴板") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.clipboardStatus)
                        Button("加载到本机剪贴板") { model.loadClipboard() }
                        Button("剪贴板历史…") { model.openHistory() }
                        Text("普通 Command+V 使用最新共享项；文件粘贴到 Finder 当前目录。").font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("文件传输") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("粘贴文件到目录…") { model.pasteFiles() }
                        if model.transfers.isEmpty { Text("复制文件后粘贴，任务将在此显示。").foregroundStyle(.secondary) }
                        ForEach(model.transfers, id: \.id) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.destination).lineLimit(1).truncationMode(.middle)
                                Text(
                                    "\(task.direction == "send" ? "发送" : "接收") · \(task.state) · \(task.received) / \(task.total) 字节"
                                ).font(.caption)
                                ProgressView(value: Double(task.received), total: Double(max(1, task.total)))
                                if let error = task.error { Text(error).font(.caption).foregroundStyle(.red) }
                                HStack {
                                    Button("暂停") { model.transferAction(task, "pause") }.disabled(
                                        task.state != "running")
                                    Button(task.state == "failed" ? "重试" : "继续") {
                                        model.transferAction(task, "resume")
                                    }.disabled(!["paused", "failed", "cancelled"].contains(task.state))
                                    Button("取消") { model.transferAction(task, "cancel") }.disabled(
                                        ["completed", "cancelled"].contains(task.state))
                                    Button(task.direction == "send" ? "打开来源目录" : "打开目标目录") {
                                        model.transferAction(task, "open")
                                    }
                                }
                            }.padding(.vertical, 8)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.onChange(of: model.localCode) { _, _ in model.credentialsEdited() }.onChange(of: model.localPassword) {
            _, _ in model.credentialsEdited()
        }.sheet(isPresented: Binding(get: { model.latencySheet != nil }, set: { if !$0 { model.latencySheet = nil } }))
        {
            if let links = model.latencySheet {
                LatencyReportView(links: links, rates: model.latencyRates, close: { model.latencySheet = nil })
                    .shareMouseSurface()
            }
        }
    }
}

private struct LatencyReportView: View {
    let links: [LinkLatency]
    let rates: String
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("延迟抖动测试 · 10 秒").font(.title2);
                Spacer();
                Button("关闭", action: close)
            }
            Text("各连接独立采样，后台历史同步暂时让路；仍包含系统排队和无线延迟。缺口表示等待后未收到回应。").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(links) { link in
                    ForEach(link.samples) { sample in
                        if let milliseconds = sample.milliseconds {
                            LineMark(
                                x: .value("时间（秒）", sample.seconds), y: .value("往返延迟（毫秒）", milliseconds),
                                series: .value(
                                    "连续片段",
                                    link.kind + ":"
                                        + String(
                                            link.samples.prefix(sample.index).filter { $0.milliseconds == nil }.count))
                            ).foregroundStyle(by: .value("连接", link.label))
                        }
                    }
                }
            }.chartXScale(domain: 0...10).chartXAxisLabel("时间（秒）").chartYAxisLabel("RTT（毫秒）").frame(height: 260)
            ForEach(links) { Text($0.summary).font(.callout) }
            Text(rates).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 720)
    }
}

// Shared styling for every SwiftUI host, including independent utility panels.
@MainActor final class SMAppearance: ObservableObject {
    static let shared = SMAppearance()
    @Published var mode: String {
        didSet {
            UserDefaults.standard.set(mode, forKey: "ShareMouse.Appearance");
            apply()
        }
    }
    private init() {
        let saved = UserDefaults.standard.string(forKey: "ShareMouse.Appearance") ?? "system"
        mode = ["light", "dark"].contains(saved) ? saved : "system"
    }
    func apply() {
        NSApp.appearance =
            mode == "dark" ? NSAppearance(named: .darkAqua) : mode == "light" ? NSAppearance(named: .aqua) : nil
        // Every native and hosted window inherits the same app preference, including
        // returning to system appearance after an explicit light/dark selection.
        for window in NSApp.windows { window.appearance = nil }
    }
    var scheme: ColorScheme? { mode == "dark" ? .dark : mode == "light" ? .light : nil }
}

@MainActor enum SMTheme {
    // SwiftUI also resolves dynamic colors on its background DisplayLink executor.
    nonisolated private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { @Sendable appearance in
                let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                    blue: Double(value & 255) / 255, alpha: 1)
            })
    }
    // Window surfaces follow the system so hosted views sit flush with native controls.
    static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    static var sidebar: Color { Color(nsColor: .underPageBackgroundColor) }
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var border: Color { Color(nsColor: .separatorColor) }
    // The brand accent and the keycap material are the only custom colors.
    static var accent: Color { adaptive(0x315F7D, 0x8CBDDD) }
    static var selection: Color { adaptive(0xD2E2E9, 0x284C67) }
    static var hover: Color { adaptive(0xDBE5E7, 0x354957) }
    static var elevation: Color { adaptive(0xFFF9EF, 0x344452) }
    static var well: Color { adaptive(0xDDD9CE, 0x18242D) }
    static var keyEdge: Color { adaptive(0xACB6B8, 0x101820) }
    static var highlight: Color { adaptive(0xFFF9EE, 0x587082) }
    static var keyFace: Color { adaptive(0xF3F3F3, 0x25313D) }
    static var keyBorder: Color { adaptive(0xC4C7BF, 0x405465) }
    static func module(_ index: Int) -> Color {
        let light: [UInt32] = [0x356D98, 0x287A74, 0x785483, 0x9E6D2B, 0x5E6C7F]
        let dark: [UInt32] = [0x8AB7DD, 0x72C8B8, 0xBF9FD2, 0xD9B579, 0xA8B9D0]
        return adaptive(light[max(0, min(4, index))], dark[max(0, min(4, index))])
    }
}

struct SMThemePicker: View {
    @ObservedObject private var appearance = SMAppearance.shared
    var body: some View {
        Picker("界面外观", selection: $appearance.mode) {
            Text("跟随系统").tag("system")
            Text("亮色").tag("light")
            Text("暗色").tag("dark")
        }.pickerStyle(.menu).labelsHidden().accessibilityLabel("界面外观").help("外观仅保存在本机，对所有 ShareMouse 窗口生效")
    }
}

private struct SMModuleKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var smModule: Int {
        get { self[SMModuleKey.self] }
        set { self[SMModuleKey.self] = newValue }
    }
}

private struct SMSurface: ViewModifier {
    @ObservedObject private var appearance = SMAppearance.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false
    let background: Bool
    let animated: Bool
    func body(content: Content) -> some View {
        content.font(.system(size: 13)).tint(SMTheme.accent).toggleStyle(.switch).background {
            if background { SMTheme.canvas.ignoresSafeArea() }
        }.opacity(presented || !animated ? 1 : 0).onAppear {
            appearance.apply()
            withAnimation(reduceMotion || !animated ? nil : .easeOut(duration: 0.18)) { presented = true }
        }
    }
}

extension View {
    func shareMouseSurface(background: Bool = true, animated: Bool = true) -> some View {
        modifier(SMSurface(background: background, animated: animated))
    }
}

struct SMSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Toggle(configuration).toggleStyle(.switch) }
}

struct SMKeyMaterial: ViewModifier {
    @ObservedObject private var appearance = SMAppearance.shared
    var selected = false
    var border: Color = SMTheme.keyBorder
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        // The key base carries depth; avoid hundreds of live blur surfaces.
        content.background {
            RoundedRectangle(cornerRadius: 7).fill(SMTheme.keyEdge).offset(y: 3)
            RoundedRectangle(cornerRadius: 6).fill(
                LinearGradient(
                    colors: selected ? [SMTheme.selection, SMTheme.selection] : [SMTheme.elevation, SMTheme.keyFace],
                    startPoint: .top, endPoint: .bottom)
            ).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: selected ? 1.5 : 1)).overlay(
                alignment: .top
            ) {
                RoundedRectangle(cornerRadius: 1).fill(SMTheme.highlight.opacity(0.6)).frame(height: 1).padding(
                    .horizontal, 6
                ).padding(.top, 1)
            }
        }.offset(y: hovered ? -1.5 : 0).animation(
            reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.17), value: hovered
        ).onHover { hovered = $0 }
        // The material must not install a DragGesture: native onDrag owns this
        // gesture, including drag-out from the key library and its item provider.
    }
}

// Small keycap used wherever a shortcut is shown, so every shortcut reads the same way.
struct SMKeyCap: View {
    @ObservedObject private var appearance = SMAppearance.shared
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 4).frame(
            minWidth: 17, minHeight: 17
        ).background {
            RoundedRectangle(cornerRadius: 4).fill(SMTheme.keyEdge.opacity(0.55)).offset(y: 1)
            RoundedRectangle(cornerRadius: 4).fill(SMTheme.keyFace).overlay(
                RoundedRectangle(cornerRadius: 4).strokeBorder(SMTheme.keyBorder, lineWidth: 0.5))
        }.padding(.bottom, 1).accessibilityLabel(label)
    }
}

struct SMKeyHint: View {
    let keys: [String]
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { SMKeyCap($0) }
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 2)
        }
    }
}

struct SMZoomSlider: NSViewRepresentable {
    @Binding var value: Double
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value, minValue: 0.25, maxValue: 4, target: context.coordinator,
            action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true;
        slider.controlSize = .small
        slider.setAccessibilityLabel("地图缩放");
        slider.toolTip = "地图缩放"
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self;
        slider.doubleValue = value
    }
    @MainActor final class Coordinator: NSObject {
        var parent: SMZoomSlider
        init(_ parent: SMZoomSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
}

// Flat fill for hosted surfaces.
struct SMPaper: View {
    let color: Color
    var body: some View { color.allowsHitTesting(false) }
}

// System material for sidebars, floating panels and toasts. The rounded mask is
// applied by AppKit because SwiftUI clipping does not reach the effect view.
struct SMMaterialBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = 0
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material;
        view.blendingMode = blending;
        view.maskImage = Self.mask(cornerRadius)
    }
    private static func mask(_ radius: CGFloat) -> NSImage? {
        guard radius > 0 else { return nil }
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill();
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill();
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

@MainActor struct SMInputStyle: @preconcurrency TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View { configuration.textFieldStyle(.roundedBorder) }
}

// Native title bar for compact utility windows: only the close control remains, and
// the window content carries its own heading unless the title is shown.
@MainActor enum SMWindowChrome {
    static func install(_ window: NSWindow, showsTitle: Bool = false) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = showsTitle ? .visible : .hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

#Preview("MainView") {
    MainView(peer: nil, pairing: nil, startupError: nil, openLogs: { print("Open Logs") }).frame(
        width: 1000, height: 700)
}
