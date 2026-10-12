import AppKit
import SwiftUI
import Charts

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
    private let symbols = ["rectangle.connected.to.line.below", "display.2", "keyboard", "arrow.down.doc", "slider.horizontal.3"]
    private let subtitles = ["连接你的设备，让协作自然发生。", "为每一块屏幕，找到合适的位置。", "熟悉的操作，延伸到另一台电脑。", "文字与文件，在设备之间自由流动。", "按照你的习惯，调整 ShareMouse。"]

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
                        withAnimation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)) { page = index }
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(page == index ? SMTheme.module(index) : .clear).frame(width: 3, height: 20)
                            Image(systemName: symbols[index]).frame(width: 20).foregroundStyle(SMTheme.module(index))
                            Text(titles[index]).font(.system(size: 13, weight: page == index ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }.padding(.vertical, 12).padding(.horizontal, 8)
                        .background(page == index ? SMTheme.module(index).opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(page == index ? .isSelected : [])
                }
                Spacer()
                Rectangle().fill(SMTheme.border).frame(height: 1).padding(.vertical, 10)
                Label("一个连续的桌面", systemImage: "circle.grid.2x2").font(.caption).foregroundStyle(.secondary).padding(10)
                SMThemePicker().padding(.horizontal, 8).padding(.bottom, 16)
            }.padding(.horizontal, 12).frame(width: 192).background { SMPaper(color:SMTheme.sidebar) }
            Rectangle().fill(SMTheme.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(titles[page]).font(.system(size: 27, weight: .semibold))
                    Text(subtitles[page]).font(.callout).foregroundStyle(.secondary)
                    Capsule().fill(SMTheme.module(page)).frame(width:44,height:4).padding(.top,5)
                }.padding(28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let startupError { Label(startupError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                        if let pairing { PairingPanel(model: pairing, page: $page).environment(\.smModule,page) }
                        else { Text("本机初始化失败，请检查身份存储与日志权限。").foregroundStyle(.secondary) }
                    }.padding(.horizontal, 28).padding(.bottom, 24)
                }
                HStack {
                    Text("关闭窗口后继续在菜单栏运行").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开日志", action: openLogs)
                }.padding(.horizontal, 28).padding(.vertical, 14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background { SMPaper(color:SMTheme.canvas) }
        }.frame(minWidth: 920, minHeight: 640)
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
            GroupBox("本机信息") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(model.peer.name, systemImage: "laptopcomputer").font(.title2)
                        Spacer()
                        Text("macOS").foregroundStyle(.secondary)
                    }
                    DisclosureGroup("查看配对身份与公钥") {
                        Text("设备 ID：\(model.identity.certificatePeer.peerID)").font(.caption).textSelection(.enabled)
                        Text(model.identity.certificatePeer.publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                GroupBox("本机配对信息") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("配对码").frame(width: 80, alignment: .leading)
                            TextField("6 位数字", text: $model.localCode).textFieldStyle(SMInputStyle()).frame(width: 150)
                            Text("密钥").frame(width: 40)
                            if model.revealPassword {
                                TextField("可选密钥", text: $model.localPassword).textFieldStyle(SMInputStyle())
                            } else { SecureField("可选密钥", text: $model.localPassword).textFieldStyle(SMInputStyle()) }
                        }
                        HStack {
                            Toggle("显示密钥", isOn: $model.revealPassword)
                            Spacer()
                        }
                        HStack {
                            Text("连接方式")
                    Toggle("Network", isOn: Binding(get: { model.networkAvailable }, set: { model.setNetworkAvailable($0) }))
                    Toggle("Bluetooth", isOn: Binding(get: { model.bluetoothAvailable }, set: { model.setBluetoothAvailable($0) }))
                    Toggle("MCPserver", isOn: Binding(get: { model.preferences.mcpEnabled }, set: { model.preferences.mcpEnabled = $0; model.configureMCP(); model.objectWillChange.send() }))
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
                        Text("后台自动发现附近设备；验证通过后加入已知设备列表。")
                            .font(.caption).foregroundStyle(.secondary)
                        Label(model.status, systemImage: model.sessions.isEmpty ? "network" : "lock.shield")
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
                                } else { Text("未连接").foregroundStyle(.secondary); Button("快速连接") { model.quickConnect(known.peerID) }.disabled(model.busy) }
                            }
                            let transports = model.sessions.first { $0.peerID == known.peerID }?.capabilities ?? []
                            Text("网络：" + (transports.contains("tcp") || transports.contains("quic") ? "已连接" : "未连接") + " · 蓝牙：" + (transports.contains("ble") ? "已连接" : "未连接") + " · MCP：" + (transports.contains("mcp-server") ? "已启用" : "未启用"))
                            Text(model.latencySummary(known.peerID)).font(.caption).foregroundStyle(.secondary)
                            Button(model.latencyTesting.contains(known.peerID) ? "正在测试（10 秒）…" : "延迟抖动测试") { model.testLatency(known.peerID) }
                                .disabled(!model.sessions.contains { $0.peerID == known.peerID } || !model.latencyTesting.isEmpty || !model.throughputTesting.isEmpty)
                            Text(model.throughputSummary(known.peerID)).font(.caption).foregroundStyle(.secondary)
                            Button(model.throughputTesting.contains(known.peerID) ? "正在测速…" : "传输速度测试") { model.testThroughput(known.peerID) }
                                .disabled(!model.sessions.contains { $0.peerID == known.peerID } || !model.throughputTesting.isEmpty || !model.latencyTesting.isEmpty || !model.throughputTesting.isEmpty)
                            Text("同时测量已连接的网络与蓝牙，本机发送、对方确认；测试会短暂暂停本机键鼠共享。").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("删除设备") { model.deletePeer(known.peerID) }
                                Toggle("Trusted", isOn: Binding(get: { known.trust == .trusted },
                                    set: { model.setPreferences(known.peerID, trusted: $0, autoConnect: known.autoConnect) }))
                                Toggle("自动连接", isOn: Binding(get: { known.autoConnect },
                                    set: { model.setPreferences(known.peerID, trusted: known.trust == .trusted, autoConnect: $0) })).disabled(known.trust != .trusted)

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
                    HStack { Button("断开") { model.pauseInput() }; Button("重连") { model.reconnectInput() } }
                    Picker("本机游戏鼠标",selection:Binding(get:{model.preferences.gameMouseMode},set:{model.preferences.gameMouseMode=$0;model.preferences.save();model.objectWillChange.send()})) { Text("桌面坐标").tag("auto"); Text("游戏相对位移").tag("on") }
                    Text("控制 Mac 游戏视角时，请在本机选择“游戏相对位移”；结束游戏后切回桌面坐标。此模式暂停边缘穿梭，原暂停快捷键可回本机。").font(.caption).foregroundStyle(.secondary)
                    Picker("键鼠输入链路",selection:Binding(get:{model.bluetoothInputPreferred},set:{model.setInputLinkPreference($0)})) {
                        Text("蓝牙优先").tag(true);Text("Wi-Fi 优先").tag(false)
                    }.pickerStyle(.segmented)
                    Text("所选链路为偏好；不可用时立即回退，延迟明显偏高时在操作间隙选择更快链路。文件和 MCP 优先网络。").font(.caption).foregroundStyle(.secondary)
                    Text("保留配对和文件连接。Control+Option+Shift+Esc 暂停／恢复键鼠共享，长按只切换一次；任意一端重连即可恢复共享。").font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("键盘配置") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.groupState?.configs.first { $0.id == model.groupState?.currentConfigID }?.name ?? "打开配置管理可创建或选择配置")
                    Button("按键映射") { model.editConfig() }
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
                    ForEach(model.transfers, id: \.id) { task in VStack(alignment: .leading, spacing: 6) {
                        Text(task.destination).lineLimit(1).truncationMode(.middle)
                        Text("\(task.direction == "send" ? "发送" : "接收") · \(task.state) · \(task.received) / \(task.total) 字节").font(.caption)
                        ProgressView(value: Double(task.received), total: Double(max(1, task.total)))
                        if let error = task.error { Text(error).font(.caption).foregroundStyle(.red) }
                        HStack { Button("暂停") { model.transferAction(task, "pause") }.disabled(task.state != "running")
                            Button(task.state == "failed" ? "重试" : "继续") { model.transferAction(task, "resume") }.disabled(!["paused", "failed", "cancelled"].contains(task.state))
                            Button("取消") { model.transferAction(task, "cancel") }.disabled(["completed", "cancelled"].contains(task.state))
                            Button(task.direction == "send" ? "打开来源目录" : "打开目标目录") { model.transferAction(task, "open") }
                        }
                    }.padding(.vertical, 8) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }.onChange(of: model.localCode) { _, _ in model.credentialsEdited() }
        .onChange(of: model.localPassword) { _, _ in model.credentialsEdited() }
        .sheet(isPresented: Binding(get: { model.latencySheet != nil }, set: { if !$0 { model.latencySheet = nil } })) {
            if let links = model.latencySheet { LatencyReportView(links: links, rates: model.latencyRates, close: { model.latencySheet = nil }).shareMouseSurface() }
        }
    }
}

private struct LatencyReportView: View {
    let links: [LinkLatency]
    let rates: String
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("延迟抖动测试 · 10 秒").font(.title2); Spacer(); Button("关闭", action: close) }
            Text("各连接独立采样，后台历史同步暂时让路；仍包含系统排队和无线延迟。缺口表示等待后未收到回应。").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(links) { link in
                    ForEach(link.samples) { sample in
                        if let milliseconds = sample.milliseconds {
                            LineMark(x: .value("时间（秒）", sample.seconds), y: .value("往返延迟（毫秒）", milliseconds), series: .value("连续片段", link.kind + ":" + String(link.samples.prefix(sample.index).filter { $0.milliseconds == nil }.count)))
                                .foregroundStyle(by: .value("连接", link.label))
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
@MainActor
final class SMAppearance: ObservableObject {
    static let shared = SMAppearance()
    @Published var mode: String {
        didSet { UserDefaults.standard.set(mode, forKey: "ShareMouse.Appearance"); apply() }
    }
    private init() {
        let saved = UserDefaults.standard.string(forKey: "ShareMouse.Appearance") ?? "system"
        mode = ["light", "dark"].contains(saved) ? saved : "system"
    }
    func apply() {
        NSApp.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) : mode == "light" ? NSAppearance(named: .aqua) : nil
        // Every native and hosted window inherits the same app preference, including
        // returning to system appearance after an explicit light/dark selection.
        for window in NSApp.windows { window.appearance = nil; SMWindowChrome.install(window) }
    }
    var scheme: ColorScheme? { mode == "dark" ? .dark : mode == "light" ? .light : nil }
}

@MainActor
enum SMTheme {
    // SwiftUI also resolves dynamic colors on its background DisplayLink executor.
    nonisolated private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor:NSColor(name:nil) { @Sendable appearance in
            let value=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark:light
            return NSColor(srgbRed:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255,alpha:1)
        })
    }
    static var elevation: Color { adaptive(0xFFF9EF, 0x344452) }
    static var well: Color { adaptive(0xDDD9CE, 0x18242D) }
    static var keyEdge: Color { adaptive(0xACB6B8, 0x101820) }
    static var highlight: Color { adaptive(0xFFF9EE, 0x587082) }
    static var canvas: Color { adaptive(0xF9F9F9, 0x171F27) }
    static var sidebar: Color { adaptive(0xF3F3F3, 0x101820) }
    static var surface: Color { adaptive(0xF3F3F3, 0x25313D) }
    static var border: Color { adaptive(0xC4C7BF, 0x405465) }
    static var accent: Color { adaptive(0x315F7D, 0x8CBDDD) }
    static var selection: Color { adaptive(0xD2E2E9, 0x284C67) }
    static var hover: Color { adaptive(0xDBE5E7, 0x354957) }
    static func module(_ index:Int)->Color {
        let light:[UInt32]=[0x356D98,0x287A74,0x785483,0x9E6D2B,0x5E6C7F]
        let dark:[UInt32]=[0x8AB7DD,0x72C8B8,0xBF9FD2,0xD9B579,0xA8B9D0]
        return adaptive(light[max(0,min(4,index))],dark[max(0,min(4,index))])
    }

}

struct SMThemePicker: View {
    @ObservedObject private var appearance = SMAppearance.shared
    var body: some View {
        Menu {
            Button("跟随系统") { appearance.mode="system" }
            Button("亮色") { appearance.mode="light" }
            Button("暗色") { appearance.mode="dark" }
        } label: {
            HStack {Text(appearance.mode == "light" ? "亮色" : appearance.mode == "dark" ? "暗色" : "跟随系统");Spacer();Image(systemName:"chevron.up.chevron.down").font(.caption)}
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).padding(.horizontal,9).padding(.vertical,6)
            .background {SMPaper(color:SMTheme.surface).clipShape(RoundedRectangle(cornerRadius:6))}
            .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(SMTheme.border))
            .accessibilityLabel("界面外观").help("外观仅保存在本机，对所有 ShareMouse 窗口生效")
    }
}

private struct SMModuleKey:EnvironmentKey {static let defaultValue=0}
extension EnvironmentValues {var smModule:Int {get {self[SMModuleKey.self]} set {self[SMModuleKey.self]=newValue}}}
private struct SMCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {Card(configuration:configuration)}
    private struct Card:View {
        let configuration:GroupBoxStyle.Configuration
        @ObservedObject private var appearance=SMAppearance.shared
        @Environment(\.smModule) private var module
        var body:some View {
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:10) {Capsule().fill(SMTheme.module(module)).frame(width:3,height:18);configuration.label.font(.system(size:14,weight:.semibold));Spacer(minLength:0)}
                    .foregroundStyle(SMTheme.module(module)).padding(.horizontal,18).padding(.vertical,12).background(SMTheme.module(module).opacity(0.12))
                configuration.content.frame(maxWidth:.infinity,alignment:.leading).padding(18)
            }.background {SMPaper(color:SMTheme.surface)}.clipShape(RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(SMTheme.border,lineWidth:1))
                .shadow(color:.black.opacity(0.08),radius:4,y:2)
        }
    }
}

private struct SMButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SMButtonBody(configuration: configuration) }
    private struct SMButtonBody: View {
    @ObservedObject private var appearance = SMAppearance.shared
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label.font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
                .background(LinearGradient(colors: configuration.isPressed ? [SMTheme.selection, SMTheme.selection] : hovered ? [SMTheme.hover, SMTheme.surface] : [SMTheme.elevation, SMTheme.surface], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 7))
                .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.10), radius: 1.5, y: 1)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(hovered ? SMTheme.accent.opacity(0.55) : SMTheme.border))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

private struct SMSurface: ViewModifier {
    @ObservedObject private var appearance = SMAppearance.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false
    let background: Bool
    let animated: Bool
    func body(content: Content) -> some View {
        content.font(.system(size: 13)).tint(SMTheme.accent)
            .buttonStyle(SMButtonStyle()).groupBoxStyle(SMCardStyle()).toggleStyle(SMSwitchStyle()).textFieldStyle(SMInputStyle())
            .background { if background { SMPaper(color:SMTheme.canvas) } }
            .opacity(presented || !animated ? 1 : 0)
            .offset(y: presented || reduceMotion || !animated ? 0 : 6)
            .onAppear {
                appearance.apply()
                withAnimation(reduceMotion || !animated ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.22)) { presented = true }
            }
    }
}

extension View {
    func shareMouseSurface(background: Bool = true, animated: Bool = true) -> some View { modifier(SMSurface(background: background, animated: animated)) }
}

// Shared tactile controls. Native slider tracking preserves keyboard/accessibility behavior.
struct SMSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Switch(configuration: configuration) }
    private struct Switch: View {
    @ObservedObject private var appearance = SMAppearance.shared
        let configuration: ToggleStyle.Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 10) {
                    Capsule().fill(configuration.isOn ? SMTheme.accent : SMTheme.well)
                        .overlay(Capsule().strokeBorder(hovered ? SMTheme.accent : SMTheme.border, lineWidth: 1))
                        .overlay(alignment: .leading) {
                            Circle().fill(configuration.isOn ? SMTheme.surface : Color.secondary)
                                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                                .frame(width: 16, height: 16).offset(x: configuration.isOn ? 21 : 3)
                        }.frame(width: 40, height: 22)
                    configuration.label
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).onHover { hovered = $0 }.opacity(enabled ? 1 : 0.4)
                .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.18), value: configuration.isOn)
                .accessibilityValue(configuration.isOn ? "开启" : "关闭")
        }
    }
}

struct SMKeyMaterial: ViewModifier {
    @ObservedObject private var appearance = SMAppearance.shared
    var selected = false
    var border: Color = SMTheme.border
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 7).fill(SMTheme.keyEdge).offset(y: 3)
                RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: selected ? [SMTheme.selection, SMTheme.selection] : [SMTheme.elevation, SMTheme.surface], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: selected ? 1.5 : 1))
                    .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 1).fill(SMTheme.highlight.opacity(0.6)).frame(height: 1).padding(.horizontal, 6).padding(.top, 1) }
            }
            // The key base carries depth; avoid hundreds of live blur surfaces.
            .offset(y: hovered ? -1.5 : 0)
            .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.17), value: hovered)
            .onHover { hovered = $0 }
            // The material must not install a DragGesture: native onDrag owns this
            // gesture, including drag-out from the key library and its item provider.
    }
}

struct SMZoomSlider: NSViewRepresentable {
    @ObservedObject private var appearance = SMAppearance.shared
    @Binding var value: Double
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: 0.25, maxValue: 4, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.cell = MaterialSliderCell(); slider.minValue = 0.25; slider.maxValue = 4
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:)); slider.isContinuous = true
        slider.setAccessibilityLabel("地图缩放"); slider.toolTip = "地图缩放"
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) { context.coordinator.parent = self; slider.doubleValue = value; slider.needsDisplay = true }
    @MainActor final class Coordinator: NSObject {
        var parent: SMZoomSlider
        init(_ parent: SMZoomSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
    private final class MaterialSliderCell: NSSliderCell {
        override var knobThickness: CGFloat { 20 }
        override func drawBar(inside rect: NSRect, flipped: Bool) {
            let rail = NSRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 6)
            NSColor(SMTheme.well).setFill(); NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).fill()
            let fraction = (doubleValue - minValue) / max(0.001, maxValue - minValue)
            NSColor(SMTheme.accent).setFill()
            NSBezierPath(roundedRect: NSRect(x: rail.minX, y: rail.minY, width: max(3, rail.width * fraction), height: 6), xRadius: 3, yRadius: 3).fill()
        }
        override func drawKnob(_ knobRect: NSRect) {
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            let knob = NSRect(x: knobRect.midX - 9, y: knobRect.midY - 9, width: 18, height: 18)
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
            NSColor(SMTheme.elevation).setFill(); NSBezierPath(ovalIn: knob).fill()
            shadow.shadowColor = .clear; shadow.set()
            NSColor(SMTheme.border).setStroke(); NSBezierPath(ovalIn: knob).stroke()
            NSColor(SMTheme.accent).setFill(); NSBezierPath(ovalIn: knob.insetBy(dx: isHighlighted ? 6 : 5, dy: isHighlighted ? 6 : 5)).fill()
        }
    }
}

// Reuse a small raster: paper does not regenerate noise during interaction.
struct SMPaper: View {
    let color: Color
    private static let grain: NSImage = {
        let size=256
        let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32)!
        let data=rep.bitmapData!;var seed:UInt32=73021
        for i in 0..<(size*size) {seed=seed &* 1664525 &+ 1013904223;data[i*4]=0;data[i*4+1]=0;data[i*4+2]=0;data[i*4+3]=UInt8((seed>>24)%15)}
        for _ in 0..<220 {seed=seed &* 1664525 &+ 1013904223;let x=Int(seed%256),y=Int((seed>>8)%256),length=3+Int((seed>>16)%12);for dx in 0..<length {data[(y*size+(x+dx)%size)*4+3]=18}}
        let image=NSImage(size:NSSize(width:128,height:128));image.addRepresentation(rep);return image
    }()
    var body: some View { color.overlay { Rectangle().fill(ImagePaint(image:Image(nsImage:Self.grain),scale:1)).opacity(0.5).allowsHitTesting(false) }.allowsHitTesting(false) }
}
@MainActor
struct SMInputStyle: @preconcurrency TextFieldStyle {
    func _body(configuration:TextField<Self._Label>) -> some View { SMInputBody(content:configuration.textFieldStyle(.plain)) }
}
private struct SMInputBody<Content:View>:View {
    @ObservedObject private var appearance = SMAppearance.shared
    let content:Content
    @FocusState private var focused:Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        content.focused($focused).padding(.horizontal,9).padding(.vertical,6)
            .background { SMPaper(color:SMTheme.surface).clipShape(RoundedRectangle(cornerRadius:6)) }
            .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(focused ? SMTheme.accent : SMTheme.border,lineWidth:focused ? 1.5:1))
            .opacity(enabled ? 1:0.5)
    }
}

// Application-owned chrome. Standard system traffic lights and title are hidden.
@MainActor enum SMWindowChrome {
    static func install(_ window:NSWindow) {
        guard window.styleMask.contains(.titled), !(window is NSOpenPanel), !(window is NSSavePanel),
              let content=window.contentView, !(content is SMChromeContainer) else {return}
        window.styleMask.insert(.fullSizeContentView);window.titleVisibility = .hidden
        window.titlebarAppearsTransparent=true;window.toolbar=nil
        for type in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] {window.standardWindowButton(type)?.isHidden=true}
        let root=SMChromeContainer(frame:content.frame);let bar=SMCaption(frame:.zero)
        window.contentView=root;content.translatesAutoresizingMaskIntoConstraints=false;bar.translatesAutoresizingMaskIntoConstraints=false
        root.addSubview(content);root.addSubview(bar)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo:root.leadingAnchor),bar.trailingAnchor.constraint(equalTo:root.trailingAnchor),bar.topAnchor.constraint(equalTo:root.topAnchor),bar.heightAnchor.constraint(equalToConstant:40),content.leadingAnchor.constraint(equalTo:root.leadingAnchor),content.trailingAnchor.constraint(equalTo:root.trailingAnchor),content.topAnchor.constraint(equalTo:bar.bottomAnchor),content.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        bar.configure(window)
    }
}
@MainActor private final class SMChromeContainer:NSView {}
@MainActor private final class SMCaption:NSView {
    override var isFlipped:Bool {true}
    private weak var owner:NSWindow?
    private var controls:[SMCaptionButton]=[]
    func configure(_ window:NSWindow) {
        owner=window
        func add(_ title:String,_ label:String,_ action:@escaping ()->Void) {let button=SMCaptionButton(title:title,label:label,action:action);controls.append(button);addSubview(button)}
        if window.styleMask.contains(.miniaturizable) {add("−","最小化") {[weak window] in window?.miniaturize(nil)}}
        if window.styleMask.contains(.resizable) {add("□","缩放窗口") {[weak window] in window?.zoom(nil)}}
        if window.styleMask.contains(.closable) {add("×","关闭窗口") {[weak window] in window?.performClose(nil)}}
        needsLayout=true
    }
    override func layout(){super.layout();for (i,button) in controls.enumerated(){button.frame=NSRect(x:bounds.width-8-Double(controls.count-i)*38,y:5,width:34,height:30)}}
    override func draw(_ rect:NSRect) {
        NSColor(SMTheme.sidebar).setFill();bounds.fill();NSColor(SMTheme.border).setFill();NSRect(x:0,y:bounds.height-1,width:bounds.width,height:1).fill()
        NSColor(SMTheme.accent).setFill();NSBezierPath(roundedRect:NSRect(x:16,y:14,width:12,height:12),xRadius:4,yRadius:4).fill()
        let text=owner?.title ?? "ShareMouse"
        (text as NSString).draw(in:NSRect(x:38,y:12,width:max(0,bounds.width-180),height:20),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:NSColor.labelColor])
    }
    override func mouseDown(with event:NSEvent){if event.clickCount==2,owner?.styleMask.contains(.resizable)==true{owner?.zoom(nil)}else{owner?.performDrag(with:event)}}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}
@MainActor private final class SMCaptionButton:NSView {
    private let glyph:String;private let action:()->Void;private var hovering=false;private var tracking:NSTrackingArea?
    init(title:String,label:String,action:@escaping ()->Void){glyph=title;self.action=action;super.init(frame:.zero);setAccessibilityElement(true);setAccessibilityRole(.button);setAccessibilityLabel(label)}
    required init?(coder:NSCoder){fatalError("Programmatic caption")}
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking {removeTrackingArea(tracking)};let area=NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseEnteredAndExited,.inVisibleRect],owner:self);addTrackingArea(area);tracking=area}
    override func mouseEntered(with event:NSEvent){hovering=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent){hovering=false;needsDisplay=true}
    override func mouseDown(with event:NSEvent){if let owner=window,let up=owner.nextEvent(matching:.leftMouseUp),bounds.contains(convert(up.locationInWindow,from:nil)){action()}}
    override func accessibilityPerformPress()->Bool {action();return true}
    override func draw(_ rect:NSRect){if hovering {(glyph=="×" ? NSColor.systemRed : NSColor(SMTheme.hover)).setFill();NSBezierPath(roundedRect:bounds,xRadius:5,yRadius:5).fill()};let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:18,weight:.regular),.foregroundColor:hovering && glyph=="×" ? NSColor.white : NSColor.labelColor];let size=(glyph as NSString).size(withAttributes:attributes);(glyph as NSString).draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2),withAttributes:attributes)}
}

