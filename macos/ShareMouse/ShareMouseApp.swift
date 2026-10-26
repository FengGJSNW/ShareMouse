import AppKit
import SwiftUI

@main struct ShareMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            VStack(alignment: .leading, spacing: 18) {
                Text("ShareMouse").font(.system(size: 22, weight: .semibold))
                GroupBox("外观") {
                    HStack {
                        Text("界面主题");
                        Spacer();
                        SMThemePicker().frame(width: 160)
                    }
                }
                Text("设备、权限和共享设置可在主窗口中调整。").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 420).shareMouseSurface()
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: UserPresentedWindow?
    private var statusItem: NSStatusItem?
    private var logger: AppLogger?
    private var preferences: LocalPreferences?
    private var peer: Peer?
    private var pairing: PairingViewModel?
    private var startupError: String?
    private let dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ShareMouse", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            preferences = LocalPreferences(directory: dataDirectory)
            let id = try PeerIdentityStore(directory: dataDirectory).loadOrCreate()
            peer = Peer(id: id, name: Host.current().localizedName ?? "Mac", platform: .macOS, capabilities: [])
            record(.info, "ApplicationStarted platform=macOS peerId=\(id.value.uuidString.lowercased()) phase=10")
            pairing = try PairingViewModel(
                peer: peer!, directory: dataDirectory, localPreferences: preferences,
                log: { [weak self] level, event in self?.record(level, event) })
            pairing?.start()
        } catch {
            startupError = "无法初始化本机身份或密钥。请检查数据目录与钥匙串授权，原有身份已保留。"
            record(.error, "StartupFailed code=\((error as NSError).code)")
        }
        setupMenu()
        showMainWindow()
        if pairing?.firstRun == true || CommandLine.arguments.contains("--permission-setup") {
            DispatchQueue.main.async { [weak self] in self?.pairing?.presentPermissionDeclaration() }
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menuIcon = NSImage(named: "MenuBarTemplate")
        menuIcon?.size = NSSize(width: 18, height: 18)
        menuIcon?.isTemplate = true
        menuIcon?.accessibilityDescription = "ShareMouse"
        statusItem?.button?.image = menuIcon
        let menu = NSMenu()
        let show = NSMenuItem(title: "打开 ShareMouse", action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let logs = NSMenuItem(title: "打开日志目录", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ShareMouse", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc private func showMainWindow() {
        if window == nil {
            let root = MainView(
                peer: peer, pairing: pairing, startupError: startupError, openLogs: { [weak self] in self?.openLogs() })
            let created = UserPresentedWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
                defer: false)
            created.minSize = NSSize(width: 920, height: 640)
            created.title = "ShareMouse"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.contentView = NSHostingView(rootView: (root).shareMouseSurface())
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        window?.userRequestedVisible = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        record(.info, "WindowShown")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window { window?.userRequestedVisible = false }
        sender.orderOut(nil)
        record(.info, "WindowHidden background=running")
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !MacInputAdapter.isCapturingRemotePointer else { return false }
        showMainWindow()
        return false
    }

    @objc private func openLogs() {
        let directory = dataDirectory.appendingPathComponent("logs")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true);
            NSWorkspace.shared.open(directory)
        } catch { NSLog("ShareMouse: 无法打开日志目录") }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        pairing?.stop();
        record(.info, "ApplicationStopped")
    }

    private func record(_ level: LogLevel, _ event: String) {
        guard let preferences, preferences.accepts(level) else { return }
        do {
            if logger == nil { logger = try AppLogger(directory: dataDirectory.appendingPathComponent("logs")) };
            try logger?.write(level, event)
        } catch { fputs("ShareMouse: unable to write lifecycle log.\n", stderr) }
    }
}

// Foregrounding the transparent pointer context must not order a user-closed
// management window back on screen, including deferred AppKit activation.
@MainActor private final class UserPresentedWindow: NSWindow {
    var userRequestedVisible = false
    override var canBecomeMain: Bool { userRequestedVisible && super.canBecomeMain }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place == .out || userRequestedVisible else { return }
        super.order(place, relativeTo: otherWin)
    }
    override func orderFront(_ sender: Any?) {
        guard userRequestedVisible else { return };
        super.orderFront(sender)
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        guard userRequestedVisible else { return };
        super.makeKeyAndOrderFront(sender)
    }
}
