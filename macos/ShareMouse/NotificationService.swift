import AppKit
import QuartzCore
import SwiftUI
import UserNotifications
@MainActor
private protocol NotificationRenderer { func show(_ id: String, title: String, message: String, progress: Double?, persistent: Bool); func hide(_ id: String); func stop() }
@MainActor
private final class NativeRenderer: NSObject, NotificationRenderer, UNUserNotificationCenterDelegate {
    var available = false
    private var shown: Set<String> = []
    func enable() async -> Bool { do { available = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]); UNUserNotificationCenter.current().delegate = self } catch { available = false }; return available }
    func show(_ id: String, title: String, message: String, progress: Double?, persistent: Bool) {
        guard available else { return }; let content = UNMutableNotificationContent(); content.title = title
        content.body = message + (progress.map { "\n\(Int($0 * 100))%" } ?? "")
        shown.insert(id); Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
    }
    func hide(_ id: String) { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id]); shown.remove(id) }
    func stop() { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(shown)); shown = [] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
}
@MainActor
private final class CustomRenderer: NotificationRenderer {
    var corner = "bottomRight"
    private var panels: [String: NSPanel] = [:]
    private var order: [String] = []
    private var hidden: Set<String> = []
    private var timers: [String: Task<Void, Never>] = [:]
    private var controlActions: [String: () -> Void] = [:]
    func showControl(_ id: String, title: String, message: String, exit: @escaping () -> Void) {
        controlActions[id] = exit; show(id,title:title,message:message,progress:nil,persistent:true)
    }
    func show(_ id: String, title: String, message: String, progress: Double?, persistent: Bool) {
        guard !hidden.contains(id) else { return }
        let firstPresentation = panels[id] == nil
        let panel: NSPanel
        if let old = panels[id] { panel = old } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 148), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isReleasedWhenClosed = false
            panels[id] = panel; order.append(id)
        }
        panel.hasShadow = controlActions[id] == nil
        panel.contentView = NSHostingView(rootView: (ToastBody(title: title, message: message, progress: progress, exitControl: controlActions[id]) { self.hidden.insert(id); self.hide(id) }).shareMouseSurface(background: false, animated: false))
        arrange(); panel.orderFrontRegardless()
        if firstPresentation && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue=0
            NSAnimationContext.runAnimationGroup { context in
                context.duration=0.22;context.timingFunction=CAMediaTimingFunction(controlPoints:0.16,1,0.3,1)
                panel.animator().alphaValue=1
            }
        }
        if persistent { timers.removeValue(forKey: id)?.cancel() }
        if !persistent, timers[id] == nil { timers[id] = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { self.hide(id) }; self.timers.removeValue(forKey: id) } }
    }
    private func arrange() { let point = NSEvent.mouseLocation; let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main; guard let rect = screen?.visibleFrame else { return }
        for (index, id) in order.enumerated() { panels[id]?.setFrameOrigin(NSPoint(x: corner.hasSuffix("Right") ? rect.maxX - 350 : rect.minX + 20,
            y: corner.hasPrefix("top") ? rect.maxY - 168 - Double(index) * 160 : rect.minY + 20 + Double(index) * 160)) }
    }
    func hide(_ id: String) { panels.removeValue(forKey: id)?.orderOut(nil); order.removeAll { $0 == id }; timers.removeValue(forKey: id)?.cancel(); controlActions.removeValue(forKey:id); arrange() }
    func stop() { for id in Array(panels.keys) { hide(id) }; hidden = [] }
}
private struct ToastBody: View {
    @ObservedObject private var appearance = SMAppearance.shared
    let title: String; let message: String; let progress: Double?; let exitControl: (() -> Void)?; let hide: () -> Void
    var body: some View {
        if let exitControl {
            VStack(alignment:.leading,spacing:5) {
                HStack {Text(title).font(.headline);Spacer();Button("退出接管",action:exitControl).buttonStyle(.plain)}
                ForEach(Array(message.components(separatedBy:"\n").enumerated()),id:\.offset) {_,line in Text(line).font(.caption).lineLimit(1).truncationMode(.tail)}
            }.foregroundStyle(.white).shadow(color:.black.opacity(0.95),radius:1.5).padding(4).frame(width:330,height:148,alignment:.topLeading)
        } else {
            VStack(alignment:.leading,spacing:8) {HStack {Text(title).font(.headline);Spacer();Button("×",action:hide).buttonStyle(.plain)};Text(message).font(.caption);if let progress {ProgressView(value:progress).tint(SMTheme.accent)}}.padding(16).frame(width:330,height:148,alignment:.topLeading).background {SMPaper(color:SMTheme.surface).clipShape(RoundedRectangle(cornerRadius:12))}.overlay(RoundedRectangle(cornerRadius:12).strokeBorder(SMTheme.border))
        }
    }
}
@MainActor
final class NotificationService {
    private let native = NativeRenderer(); private let custom = CustomRenderer(); private let preferences: LocalPreferences
    private var signatures: [String: String] = [:]
    private var previousLinks: [String: Set<String>] = [:], seenLinks: [String: Set<String>] = [:]
    private var pendingLinks: [String: (name: String, labels: Set<String>)] = [:]
    private var linkTasks: [String: Task<Void,Never>] = [:]
    func connections(_ sessions: [SessionInfo]) {
        let alive = Set(sessions.map(\.peerID))
        for peer in previousLinks.keys where !alive.contains(peer) { previousLinks[peer] = [] }
        for item in sessions {
            var current: Set<String> = []
            if item.capabilities.contains("tcp") || item.capabilities.contains("quic") { current.insert("Wi-Fi") }
            if item.capabilities.contains("ble") { current.insert("蓝牙") }
            let previous = previousLinks[item.peerID], seen = seenLinks[item.peerID,default:[]]
            previousLinks[item.peerID] = current; seenLinks[item.peerID] = seen.union(current)
            guard let previous else { continue } // Silence the initial snapshot; never replay old startup states.
            let labels = Set(current.subtracting(previous).map { $0 + " 链路" + (seen.contains($0) ? "已重连" : "已连接") })
            guard !labels.isEmpty else { continue }
            let prior = pendingLinks[item.peerID]?.labels ?? []
            pendingLinks[item.peerID] = (item.name, prior.union(labels))
            linkTasks[item.peerID]?.cancel()
            linkTasks[item.peerID] = Task { [weak self] in
                try? await Task.sleep(for:.milliseconds(600)); guard !Task.isCancelled,let self,let value=self.pendingLinks.removeValue(forKey:item.peerID) else { return }
                self.linkTasks.removeValue(forKey:item.peerID)
                self.toast("设备链路",value.name + "\n" + value.labels.sorted().joined(separator:" · "))
            }
        }
    }
    func inputReconnected(_ sessions: [SessionInfo], bluetoothPreferred: Bool) {
        let lines = sessions.map { item in
            let kind = bluetoothPreferred && item.capabilities.contains("ble") ? "蓝牙" : item.capabilities.contains("quic") ? "Wi-Fi（QUIC）" : item.capabilities.contains("tcp") ? "Wi-Fi（TCP）" : "蓝牙"
            return item.name + " · " + kind + " 链路"
        }
        if !lines.isEmpty { toast("键鼠重连完成",lines.joined(separator:"\n")) }
    }

    init(preferences: LocalPreferences) { self.preferences = preferences }
    func configure() async -> Bool { custom.corner = preferences.corner; custom.stop(); native.stop(); signatures = [:]; if mcpControlID != nil { mcpControl(true,"opened") }; if preferences.renderer == "native" { return await native.enable() }; return true }
    private var renderer: any NotificationRenderer { preferences.renderer == "native" && native.available ? native : custom }
    func toast(_ title: String, _ message: String) { custom.corner = preferences.corner; renderer.show(UUID().uuidString, title: title, message: message, progress: nil, persistent: false) }
    private var mcpControlID: String?, mcpNoticeID: String?
    var exitMCPControl: () -> Void = {}
    private var lastMCPNotice = -Double.infinity
    func mcpActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        guard mcpControlID == nil, now - lastMCPNotice >= 30 else { return }
        lastMCPNotice = now
        if let id = mcpNoticeID { custom.hide(id) }
        let id = UUID().uuidString; mcpNoticeID = id; custom.corner = preferences.corner
        custom.show(id,title:"MCP 正在读取本机",message:"AI 正在通过 ShareMouse 读取本机信息",progress:nil,persistent:false)
    }
    func mcpControl(_ active: Bool, _ reason: String) {
        if let id = mcpNoticeID { custom.hide(id); mcpNoticeID = nil }
        if let id = mcpControlID { custom.hide(id); mcpControlID = nil }
        custom.corner = preferences.corner
        if active {
            let id = UUID().uuidString; mcpControlID = id
            custom.showControl(id,title:"MCP 正在被使用中",message:"AI 正在截图并控制本机\n误动键鼠不会退出，点击下方按钮结束",exit:exitMCPControl)
        } else if reason != "server_stopped" {
            let message = ["user_exit":"你已退出 MCP 接管，本机输入已恢复","lease_expired":"控制会话空闲到期，已恢复键鼠共享","peer_disconnected":"远端设备已断开","screen_changed":"屏幕配置已变化","computer_access_disabled":"电脑操控权限已关闭","input_permission_or_desktop_unavailable":"输入权限丢失或桌面已锁定","capture_failed":"截图未能完成","closed":"AI 已释放电脑控制"][reason] ?? "控制会话已结束"
            toast("MCP 操控已结束",message)
        }
    }
    private struct Sample { var bytes: Int64; var time: ContinuousClock.Instant; var state: String; var rate: Double = 0 }
    private var samples: [String: Sample] = [:]
    private var latest: [TransferTask] = []
    private var ticker: Task<Void, Never>?
    private var shownAt: [String: ContinuousClock.Instant] = [:]
    private var restoredStates: [String: String] = [:]
    func restoreTransfers(_ tasks: [TransferTask]) { latest = tasks; restoredStates = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.state) }) }
    func transfers(_ tasks: [TransferTask]) {
        latest = tasks; refreshTransfers()
        if tasks.contains(where: { $0.state == "running" }), ticker == nil { ticker = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); guard !Task.isCancelled, let self else { return }; self.refreshTransfers() }
        } }
        if !tasks.contains(where: { $0.state == "running" }) { ticker?.cancel(); ticker = nil }
    }
    private func refreshTransfers() {
        custom.corner = preferences.corner
        for task in latest {
            if let restored = restoredStates[task.id] {
                if task.state == restored { continue }
                restoredStates.removeValue(forKey: task.id)
            }
            let active = ["running", "queued", "paused"].contains(task.state)
            if signatures[task.id] == nil, !active { continue }
            let now = ContinuousClock.now
            var sample = samples[task.id] ?? Sample(bytes: task.received, time: now, state: task.state)
            if task.state != "running" || sample.state != "running" || task.received < sample.bytes { sample = Sample(bytes: task.received, time: now, state: task.state) }
            else { let elapsed = sample.time.duration(to: now).components; let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                if seconds >= 1 { sample = Sample(bytes: task.received, time: now, state: task.state, rate: Double(max(0, task.received - sample.bytes)) / seconds) }
            }
            samples[task.id] = sample
            let labels = ["running": "正在传输", "queued": "排队中", "paused": "已暂停", "completed": "已完成", "failed": "传输失败", "cancelled": "已取消"]
            let direction = task.direction == "send" ? "发送文件" : "接收文件"
            let title = direction + " · " + (labels[task.state] ?? task.state)
            let current = task.files.first { !$0.item.directory && !$0.completed && !$0.skipped } ?? task.files.first { $0.item.id == $0.item.rootID }
            let name = current.map { URL(fileURLWithPath: $0.item.relativePath).lastPathComponent } ?? "正在获取文件清单…"
            let percent = min(100, max(0, Int(Double(task.received) / Double(max(1, task.total)) * 100)))
            let transport = ["tcp": "网络 TCP", "quic": "网络 QUIC", "ble": "蓝牙 BLE"][task.transport ?? ""] ?? "等待链路"
            let message = name + "\n" + bytes(Double(task.received)) + " / " + bytes(Double(task.total)) + " · \(percent)%\n" + bytes(sample.rate) + "/s · " + transport + (task.error == nil ? "" : "\n" + (task.error ?? ""))
            let signature = task.state + ":" + message
            guard signatures[task.id] != signature else { continue }
            if signatures[task.id]?.hasPrefix(task.state + ":") == true, let shown = shownAt[task.id], shown.duration(to: now) < .seconds(1) { continue }
            signatures[task.id] = signature; shownAt[task.id] = now
            renderer.show(task.id, title: title, message: message, progress: active ? Double(percent) / 100 : nil, persistent: active)
            if !active { Task { try? await Task.sleep(for: .seconds(6)); if self.signatures[task.id] == signature { self.renderer.hide(task.id) } } }
        }
    }
    private func bytes(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB", value / 1_000) }
        return String(format: "%.0f B", value)
    }
    func stop() { linkTasks.values.forEach { $0.cancel() }; linkTasks = [:]; pendingLinks = [:]; ticker?.cancel(); ticker = nil; native.stop(); custom.stop() }
}
