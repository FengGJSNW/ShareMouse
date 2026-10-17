import AppKit
import CoreBluetooth
import Network
import SwiftUI

@MainActor final class PairingViewModel: ObservableObject {
    private let sharingShortcut = SharingShortcut()
    let firstRun: Bool
    let preferences: LocalPreferences
    private let notifications: NotificationService
    @Published var permissionStatus = "尚未检查"
    @Published var finderPermissionStatus = "尚未申请"
    var needsInputPermissions: Bool { inputAdapter?.canInject != true || inputAdapter?.canCapture != true }
    private var permissionTask: Task<Void, Never>?
    @Published var localCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
    @Published var localPassword = ""
    @Published var revealPassword = false
    @Published var remoteCode = ""
    @Published var remotePassword = ""
    @Published var remoteHost = ""
    @Published var selectedCandidate = ""
    @Published var networkAvailable = true
    @Published var bluetoothAvailable = true
    var bluetoothInputPreferred: Bool { preferences.bluetoothInputOnly }
    func setInputLinkPreference(_ bluetooth: Bool) {
        preferences.bluetoothInputOnly = bluetooth;
        preferences.save();
        objectWillChange.send()
        Task {
            await manager?.setInputLinkPreference(bluetooth: bluetooth)
            if !bluetooth { try? await manager?.startQuicListener() }
            input?.refreshInputRoute();
            input?.update(groupState, online: groupOnline, sessions: sessions)
        }
    }
    func setNetworkAvailable(_ enabled: Bool) {
        networkAvailable = enabled;
        preferences.networkAvailable = enabled;
        preferences.save()
        Task {
            await manager?.setNetworkAvailable(enabled)
            pairDiscovery?.update(code: localCode, enabled: enabled)
        }
    }
    func setBluetoothAvailable(_ enabled: Bool) {
        bluetoothAvailable = enabled;
        preferences.bluetoothAvailable = enabled;
        preferences.save()
        ble?.setAvailable(enabled)
        if enabled {
            startBluetooth();
            ble?.tryDiscovery()
        }
        Task { await manager?.setBluetoothAvailable(enabled) }
    }
    @Published var candidates: [LANCandidate] = []
    @Published var sessions: [SessionInfo] = []
    @Published var knownPeers: [KnownPeer] = []
    @Published var bleCandidates: Set<String> = []
    @Published var bleNames: [String: String] = [:]
    private var bluetoothEnabled = true
    @Published var throughputResults: [String: [LinkThroughput]] = [:]
    @Published var throughputTesting: Set<String> = []
    func throughputSummary(_ id: String) -> String {
        guard let values = throughputResults[id] else { return "传输速度：尚未测试" }
        var rows = values.map(\.summary)
        if !values.contains(where: { $0.kind == "ble" }) { rows.append("蓝牙：未连接，未测试") }
        if !values.contains(where: { $0.kind != "ble" }) { rows.append("网络：未连接，未测试") }
        return "本机 → 对方 · 应用有效吞吐\n" + rows.joined(separator: "\n")
    }
    func testThroughput(_ id: String) {
        guard let manager, throughputTesting.isEmpty, latencyTesting.isEmpty, computer?.controlling != true else {
            return
        }
        throughputTesting.insert(id)
        let resume = input?.enabled == true, revision = inputPauseRevision
        input?.pause()
        status = "传输速度测试运行中；暂时暂停本机键鼠共享…"
        Task {
            do {
                let values = try await manager.testThroughput(peerID: id);
                throughputResults[id] = values
                for value in values {
                    log(
                        .info,
                        "LinkThroughputMeasured transport=\(value.kind) bytes=\(value.bytes) seconds=\(value.seconds) error=\(value.error ?? "none")"
                    )
                }
                status = "传输速度测试完成"
            } catch { status = "测速未完成：请连接两端新版并检查链路" }
            throughputTesting.remove(id)
            if resume, sharingRequested, revision == inputPauseRevision, computer?.controlling != true { enableInput() }
            startAutomaticInput()
        }
    }
    @Published var latencyResults: [String: [LinkLatency]] = [:]
    @Published var latencyTesting: Set<String> = []
    @Published var latencySheet: [LinkLatency]?
    @Published var latencyRates = ""
    @Published var bleStatus = "蓝牙发现尚未启动"
    @Published var status = "等待配对"
    @Published var busy = false
    @Published var groupState: SharedGroup?
    @Published var savedGroups: [SharedGroup] = []
    @Published var groupLocks: [GroupEditLock] = []
    @Published var groupOnline: [String] = []
    @Published var groupStatus = "尚未加入桌面组"
    @Published var selectedGroup = ""
    @Published var inputStatus = "键鼠共享尚未启用"
    @Published var inputEnabled = false
    @Published var configLease: GroupEditLock?
    @Published var configDraft: [KeyboardConfig] = []
    @Published var configSelected = ""
    @Published var layoutLease: GroupEditLock?
    @Published var layoutDraft: [ScreenGeometry] = []
    @Published var layoutStarting = false
    @Published var layoutError = ""
    @Published var nativeLayoutError = ""
    @Published var clipboardStatus = "等待复制 · 正文按粘贴请求"
    private var cutting = false
    @Published var historyEntries: [HistoryEntry] = []
    @Published var historyStatus = "历史只保存在本机"
    var historyVisibleCount: Int { history?.visibleCount ?? 5 }
    var historySide: String { history?.preferredSide ?? "right" }
    var historyCapacity: Int { history?.capacity ?? 50 }
    var historyKey: String { history?.shortcutKey ?? "KeyV" }
    var historyModifiers: [String] { history?.modifiers ?? ["Control", "Alt"] }
    private var history: HistoryService?
    private let historyPopup = HistoryPopup()
    @Published var transfers: [TransferTask] = []
    private var files: FileTransferService?
    private var clipboard: ClipboardService?
    private let clipboardAdapter = MacClipboardAdapter()
    private let clipboardShortcut = ClipboardShortcut(platform: "macos")
    private var preparingLocalFiles: (version: Int, previousEntryID: String?)?
    private var appliedClipboard: (entryID: String, revision: UInt64?, version: Int)?
    private var pasting = false
    private var input: InputService?
    private var inputAdapter: MacInputAdapter?
    private var peerResumePending = false
    private var inputStarting = false
    private var displayObserver: NSObjectProtocol?
    private let directory: URL
    private var group: GroupManager?
    private var configWindow: NSWindow?
    let peer: Peer
    let identity: IdentityKeychain
    private let registry: PeerRegistry
    private var manager: SessionManager?
    private var computer: ComputerUseService?
    private var mcp: MCPServer?
    private let computerAdapter = MacComputerAdapter()
    @Published var mcpStatus = "MCP 服务未启用"
    @Published var mcpControlling = false
    private var discovery: LANDiscovery?
    private var pairDiscovery: PairDiscovery?
    private var bonjourCandidates: [LANCandidate] = []
    private var pairHints: [LANCandidate] = []
    private var generatedCode = true
    private var trustAsked: Set<String> = []
    private var sharingRequested = true
    private var autoConnecting = false
    private var ble: BLEDiscovery?
    private var autoTask: Task<Void, Never>?
    private var bleAutoTask: Task<Void, Never>?
    private var automaticInputPending = false
    private var connectionPromptOpen = false
    private var pendingConnectionDialogs = 0
    private var inputPauseRevision = 0
    private var computerInputPauseRevision = 0
    private var resumePreservingUserCursor = false
    private var previousInputPermission = false
    private var credentialsPrompt: Task<Void, Never>?
    private var appliedCredentials: (String, String)?
    private var localCutVersion: Int?
    private var lastNativeLayout: [ScreenGeometry]?
    private var applyingDisplayLayout = false
    private var layoutEditGeneration = 0
    private var layoutCommitting = false
    private var candidatePeers: [String: String] = [:]
    private var suppressed: Set<String> = []
    private let log: (LogLevel, String) -> Void

    init(
        peer: Peer, directory: URL, localPreferences: LocalPreferences? = nil, log: @escaping (LogLevel, String) -> Void
    ) throws {
        self.peer = peer;
        self.log = log;
        self.directory = directory
        preferences = localPreferences ?? LocalPreferences(directory: directory);
        networkAvailable = preferences.networkAvailable;
        bluetoothAvailable = preferences.bluetoothAvailable;
        bluetoothEnabled = true;
        firstRun = !preferences.onboardingComplete;
        notifications = NotificationService(preferences: preferences)
        identity = try IdentityKeychain(peerID: peer.id.value.uuidString.lowercased())
        registry = try PeerRegistry(directory: directory)
        knownPeers = registry.all();
        trustAsked.formUnion(knownPeers.map(\.peerID))
    }
    func start() {
        appliedCredentials = (localCode, localPassword)
        let registry = self.registry
        let engine = SessionManager(
            localID: peer.id.value.uuidString.lowercased(), name: peer.name, identity: identity, registry: registry,
            pairCode: localCode, password: localPassword,
            confirmCertificate: { [weak self] certificate in await self?.confirmIdentity(certificate) ?? false },
            confirmConnection: { _ in false },
            changed: { [weak self] items in Task { @MainActor in self?.sessionsChanged(items) } },
            event: { [weak self] event in Task { @MainActor in self?.log(.info, event) } },
            confirmPeerConnection: { [weak self] id, name, bluetooth in
                if bluetooth { return await self?.confirmBluetoothConnection(name, peerID: id) ?? false }
                return await self?.confirmReconnect(name, peerID: id) ?? false
            }, bluetoothInputOnly: preferences.bluetoothInputOnly)
        manager = engine
        log(.info, "InputTransportConfigured bluetoothOnly=\(engine.bluetoothInputOnly) source=localSettings")
        let inputAdapter = MacInputAdapter(
            peerID: peer.id.value.uuidString.lowercased(), diagnostic: { [weak self] text in self?.log(.warn, text) })
        self.inputAdapter = inputAdapter
        let input = InputService(
            id: peer.id.value.uuidString.lowercased(), platform: "macos", manager: engine,
            inject: { event, screen, x, y in try inputAdapter.inject(event, screen: screen, x: x, y: y) },
            restrict: { remote, suppress in inputAdapter.cursorState(remoteTarget: remote, suppressPhysical: suppress)
            },
            status: { [weak self] text in
                self?.inputStatus = text;
                if let self, self.sharingRequested, self.input?.enabled != true { self.automaticInputPending = true };
                self?.inputEnabled = self?.input?.enabled ?? false
                self?.refreshBluetoothScanning()
                if ProcessInfo.processInfo.arguments.contains("--input-state-check") {
                    self?.log(.info, "InputStatus " + text)
                }
            }, event: { [weak self] text in self?.log(.info, text) })
        input.relativePointerCaptured = { [weak self] in self?.preferences.gameMouseMode == "on" }
        self.input = input
        input.pointerSensitivity = { [weak self] peer in self?.preferences.pointerSensitivity[peer] ?? 1 }
        input.scrollInversion = { [weak self] peer in
            (
                horizontal: self?.preferences.reverseScrollHorizontal[peer] ?? false,
                vertical: self?.preferences.reverseScrollVertical[peer] ?? false
            )
        }
        input.horizontalScrollAngle = { [weak self] peer in self?.preferences.horizontalScrollAngle[peer] ?? 30 }
        input.screenCrossingEnabled = preferences.screenCrossingEnabled
        input.configureKeyboard(fn: preferences.fnEnabled, functions: preferences.functionKeysEnabled)
        sharingShortcut.toggleFn = { [weak self] in
            guard let self else { return };
            self.setKeyboardOptions(fn: !self.preferences.fnEnabled)
        }
        sharingShortcut.toggleFunctions = { [weak self] in
            guard let self else { return };
            self.setKeyboardOptions(functions: !self.preferences.functionKeysEnabled)
        }
        sharingShortcut.toggleCrossing = { [weak self] in
            guard let self else { return };
            self.setScreenCrossing(!self.preferences.screenCrossingEnabled)
        }
        sharingShortcut.toggle = { [weak self, weak input] in
            if input?.enabled == true { self?.pauseInput() } else { self?.reconnectInput() }
        }
        input.resumeRequested = { [weak self] in
            guard let self, !self.stopping else { return };
            self.sharingRequested = true;
            self.automaticInputPending = true;
            self.startAutomaticInput()
        }
        let clipboard = ClipboardService(
            id: peer.id.value.uuidString.lowercased(), manager: engine,
            changed: { [weak self] entry in
                self?.files?.clipboardChanged(entry);
                self?.clipboardStatus =
                    entry.map {
                        "当前剪贴板 · "
                            + ($0.kind == "text"
                                ? "文本 \($0.byteCount) 字节"
                                : $0.kind == "files"
                                    ? ($0.fileCount == 0
                                        ? "正在准备文件清单…" : "\($0.cut == true ? "剪切" : "复制") \($0.fileCount ?? 0) 项")
                                    : ["png", "url", "html", "rtf"].contains($0.kind)
                                        ? $0.kind.uppercased() : "此类型尚不可用")
                    } ?? "等待复制"
            }, event: { [weak self] metadata in self?.log(.info, metadata) }, directory: directory)
        self.clipboard = clipboard
        do {
            history = try HistoryService(
                id: peer.id.value.uuidString.lowercased(), directory: directory, manager: engine,
                changed: { [weak self] in self?.refreshHistory() });
            refreshHistory()
        } catch { historyStatus = "历史记录无法读取；未覆盖原文件" }
        clipboard.textForEntry = { [weak self] entryID in self?.history?.text(entryID) }
        history?.opened = { [weak self] in
            guard let self else { return };
            if self.input?.enabled == true {
                _ = self.input?.capture(CapturedInput("command", command: "history"))
            } else {
                self.openHistory()
            }
        }
        do {
            files = try FileTransferService(
                id: peer.id.value.uuidString.lowercased(), directory: directory, manager: engine, clipboard: clipboard,
                changed: { [weak self] tasks in
                    self?.transfers = tasks;
                    self?.notifications.transfers(tasks)
                }, event: { [weak self] text in self?.log(.info, text) },
                sourceChanged: { paths in
                    return await ShareMouseDialog.chooseAsync(
                        "源文件已经改过", "这些文件在你复制之后被修改过。要复制现在的版本吗？", choices: [("current", "复制当前版本"), ("cancel", "取消")],
                        detail: paths.joined(separator: "\n"), kind: .warning) == "current"
                },
                conflict: { path, _, allow in
                    return await ShareMouseDialog.chooseAsync(
                        "目标位置已有同名文件", "选择要怎么处理这个文件。",
                        choices: (allow ? [("overwrite", "覆盖")] : []) + [
                            ("keepBoth", "保留两者"), ("skip", "跳过"), ("cancel", "取消"),
                        ], applyToRemaining: true, detail: path, defaultChoice: "keepBoth", kind: .warning)
                },
                partialFailure: { _ in
                    return await ShareMouseDialog.chooseAsync(
                        "部分剪切的文件没有传完", "没有确认送达的源文件都还在原位置。选“删除全部”会把这次剪切选中的源文件全部删掉，包括还没传过去的。",
                        choices: [("abort", "中断传输"), ("retry", "继续尝试"), ("deleteAll", "删除全部"), ("cancel", "返回")],
                        defaultChoice: "retry", kind: .warning)
                },
                deleteAll: { paths in
                    return await ShareMouseDialog.chooseAsync(
                        "删除全部源文件？", "下面这些文件会被删除，即使它们还没有传到目标电脑。", choices: [("cancel", "取消"), ("deleteAll", "删除全部")],
                        destructive: true, detail: paths.joined(separator: "\n")) == "deleteAll"
                },
                additionalFiles: { paths in
                    await ShareMouseDialog.chooseAsync(
                        "文件夹里有新文件", "你复制或剪切的文件夹里新增了下面这些文件，要一起处理吗？",
                        choices: [("include", "一起处理"), ("exclude", "不处理"), ("cancel", "取消")],
                        detail: paths.prefix(20).joined(separator: "\n")
                            + (paths.count > 20 ? "\n…共 \(paths.count) 项" : ""), kind: .question)
                })
        } catch { clipboardStatus = "文件任务记录无法读取；文本剪贴板仍可使用" }
        transfers = files?.currentTasks ?? [];
        notifications.restoreTransfers(transfers)
        clipboardAdapter.filesCopied = { [weak self] paths, cut in
            let version = NSPasteboard.general.changeCount
            self?.preparingLocalFiles = (version, self?.clipboard?.current?.id)
            Task {
                guard let self else { return };
                defer { if self.preparingLocalFiles?.version == version { self.preparingLocalFiles = nil } };
                do {
                    guard let files = self.files else {
                        try await self.clipboard?.publishContent(nil);
                        self.clipboardStatus = "文件模块不可用；其它剪贴板格式继续工作";
                        return
                    };
                    try await files.copy(paths, cut: cut, stillCurrent: { NSPasteboard.general.changeCount == version })
                } catch { if NSPasteboard.general.changeCount == version { self.clipboardStatus = "文件清单无法准备；请重新复制" } }
            }
        }
        clipboardShortcut.cutFiles = { [weak self] in self?.captureSelectedCut() ?? false }
        clipboardAdapter.contentCopied = { [weak self, weak clipboard] content in
            try await clipboard?.publishContent(content);
            if let text = content?.plainText { try self?.history?.remember(text, entryID: clipboard?.current?.id) }
        }
        clipboardAdapter.failed = { [weak self] in self?.clipboardStatus = "剪贴板暂时不可读，稍后重试" }
        clipboardAdapter.start()
        input.targetKeyHandler = { [weak self] in self?.historyPopup.capture($0) ?? false }
        input.clipboardEntryID = { [weak clipboard] in clipboard?.current?.id }
        input.sourceKeyTransform = { [weak inputAdapter] key, target in inputAdapter?.sourceKey(key, to: target) ?? key
        }
        input.localClipboardCommand = { [weak self] in
            Task {
                try? await Task.sleep(for: .milliseconds(80));
                guard let self, !self.stopping else { return };
                await self.clipboardAdapter.poll()
            }
        }
        input.commandHandler = { [weak self] command, source, entryID in
            guard let self else { return true };
            return try await self.clipboardCommand(command, entryID: entryID, source: source)
        }
        clipboardShortcut.paste = { [weak self] in
            guard let self else { return };
            let screenID = self.input?.pointer?.screenID
            Task {
                do {
                    guard self.input?.remoteScreenID == nil, self.input?.pointer?.screenID == screenID else { return }
                    if !(try await self.clipboardCommand("paste")), self.input?.remoteScreenID == nil,
                        self.input?.pointer?.screenID == screenID
                    {
                        try self.inputAdapter?.inject(
                            CapturedInput("command", command: "paste"), screen: nil, x: 0, y: 0)
                    }
                } catch { self.clipboardStatus = "系统拒绝粘贴，请检查辅助功能权限" }
            }
        }
        inputAdapter.captured = { [weak self, weak input] event in
            if self?.computer?.physicalInput(event) == true { return false }
            if self?.computer?.controlling != true, self?.sharingShortcut.capture(event) == true { return true }
            if self?.historyPopup.capture(event) == true { return true }
            if self?.history?.capture(event) == true { return true }

            let local = input?.enabled != true || input?.remoteScreenID == nil
            if self?.clipboardShortcut.capture(
                event, active: local && self?.needsSharedPaste() == true, allowCut: local) == true
            {
                return true
            }
            return input?.enabled == true ? input?.capture(event) ?? false : false
        }
        inputAdapter.interceptRemoteFn = { [weak input] in
            input?.enabled == true && input?.remoteTargetPlatform == "windows"
        }
        inputAdapter.modifierDiagnostic = { [weak self] text in self?.log(.info, text) }
        try? inputAdapter.start()
        inputAdapter.interrupted = { [weak self] reason in
            guard let self else { return }
            if reason == .permissionRevoked {
                self.stopInputForPermissionLoss()
            } else {
                self.history?.resetCapture();
                self.clipboardShortcut.reset();
                self.sharingShortcut.reset()
                if reason == .captureTimedOut {
                    self.input?.recoverCaptureTimeout()
                } else {
                    self.input?.recoverCaptureInterruption()
                }
                self.inputEnabled = self.input?.enabled == true
                self.log(.warn, "InputTapReenabled")
            }
        }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopping else { return };
                self.inputAdapter?.refreshDisplays();
                guard !self.applyingDisplayLayout else { return };
                self.lastNativeLayout = nil;
                await self.group?.updateScreens(Self.localScreens(self.peer.id.value.uuidString.lowercased()));
                self.applyNativeLayout(self.groupState?.layout ?? [])
            }
        }
        do {
            group = try GroupManager(
                localID: peer.id.value.uuidString.lowercased(), name: peer.name,
                publicKey: identity.certificatePeer.publicKey,
                screens: Self.localScreens(peer.id.value.uuidString.lowercased()), directory: directory,
                manager: engine, registry: registry, confirm: { member in await Self.confirmGroupMember(member) },
                changed: { [weak self] state, locks, online, saved in
                    Task { @MainActor in
                        self?.groupState = state;
                        self?.applyNativeLayout(state?.layout ?? []);
                        self?.groupLocks = locks;
                        self?.groupOnline = online;
                        self?.savedGroups = saved
                        if let self, let lease = self.layoutLease, !self.layoutCommitting,
                            online.count < 2 || state == nil
                                || (state!.revision > lease.baseRevision && !locks.contains(lease))
                        {
                            self.cancelLayoutEdit();
                            self.layoutError = "共享排布已更新，请重新拖动屏幕"
                        }
                        if let self {
                            self.clipboard?.update(state, online: online);
                            self.history?.update(state, online: online);
                            self.files?.update(state, online: online, sessions: self.sessions);
                            self.input?.update(state, online: online, sessions: self.sessions);
                            self.inputEnabled = self.input?.enabled ?? false;
                            if self.sharingRequested && !self.inputEnabled { self.automaticInputPending = true };
                            self.startAutomaticInput()
                        }
                    }
                },
                event: { [weak self] event in
                    Task { @MainActor in
                        self?.groupStatus = event;
                        self?.log(.info, event)
                    }
                },
                connectMember: { [weak self] member, id in
                    guard let self else { throw GroupError.offline };
                    try await self.connectGroupMember(member, id)
                }, automaticSharing: true)
        } catch {
            groupStatus = "设备组数据无法读取，配对仍可使用";
            log(.error, "GroupStartupFailed")
        }
        Task {
            await input.start()
            await group?.setConfigConfirmation { name, remote, local in
                await MainActor.run { self.inputStatus = "收到键盘配置：" + remote.name }
                func stamp<Value: BinaryInteger>(_ value: Value?) -> String {
                    value.map {
                        Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened)
                    } ?? "未记录"
                }
                let detail =
                    "对方：\(remote.name)\n修改时间：\(stamp(remote.modified))"
                    + (local.map { "\n\n本机：\($0.name)\n修改时间：\(stamp($0.modified))" } ?? "")
                return await ShareMouseDialog.chooseAsync(
                    local == nil ? "使用对方的键盘配置？" : "键盘配置有冲突",
                    local == nil ? "“\(name)”发来了一个键盘配置。" : "两台设备上，同一个配置的内容不一样。",
                    choices: local == nil
                        ? [("skip", "保留当前"), ("remote", "添加并切换")]
                        : [("local", "保留本机"), ("remote", "使用对方"), ("copy", "另存对方副本")], detail: detail,
                    defaultChoice: local == nil ? "remote" : "copy", kind: local == nil ? .question : .warning)
            }
            await group?.start()
            await clipboard.start()
            await files?.start()
            await history?.start()
            let computer = ComputerUseService(
                id: peer.id.value.uuidString.lowercased(), name: peer.name, manager: engine, files: files,
                clipboard: clipboard, screens: { Self.localScreens(self.peer.id.value.uuidString.lowercased()) },
                info: { self.computerAdapter.info(inputAdapter) },
                screenshot: { try await self.computerAdapter.capture($0) },
                inject: {
                    if self.computerAdapter.independent {
                        try self.computerAdapter.injectIndependent($0, screen: $1, x: $2, y: $3)
                    } else if $0.type == "relativeMove" {
                        try self.computerAdapter.moveRelative($0)
                    } else {
                        try inputAdapter.inject($0, screen: $1, x: $2, y: $3)
                    }
                },
                suspend: {
                    let resume = input.enabled;
                    self.computerInputPauseRevision = self.inputPauseRevision;
                    self.sharingShortcut.reset();
                    self.clipboardShortcut.reset();
                    input.pause();
                    return resume
                },
                restore: { resume in
                    self.resumePreservingUserCursor = self.computerAdapter.independent
                    self.computerAdapter.stop()
                    guard !self.stopping, self.computerInputPauseRevision == self.inputPauseRevision else { return }
                    self.automaticInputPending = self.automaticInputPending || resume;
                    self.startAutomaticInput()
                },
                canControl: {
                    inputAdapter.canInject && inputAdapter.canCapture && MacComputerAdapter.desktopAvailable
                }, marker: { self.computerAdapter.mark($0, $1, $2, $3) }, diagnostic: { self.log(.info, $0) },
                controlChanged: {
                    self.mcpControlling = $0;
                    if $0 { self.computerAdapter.beginControl(self.computer?.controlContext ?? .null) };
                    self.notifications.mcpControl($0, $1)
                }, activity: { self.notifications.mcpActivity() }, inputState: { self.computerAdapter.inputState() },
                captureWithOptions: { try await self.computerAdapter.capture($0, options: $1, shouldContinue: $2) },
                pointerPreview: { self.computerAdapter.preview($0, $1, $2, $3) },
                focusApplication: { try await self.computerAdapter.focusApplication($0) },
                prepareControl: { try self.computerAdapter.prepareControl($0) },
                validatePlatformAction: {
                    try self.computerAdapter.validatePlatformAction($0, screen: $1, x: $2, y: $3)
                })
            self.notifications.exitMCPControl = { [weak self] in self?.exitMCPControl() }
            self.computer = computer
            computer.allowComputer = preferences.allowComputerUse;
            computer.allowFiles = preferences.allowMcpFiles
            await computer.start();
            configureMCP()
            if preferences.renderer == "native" { configureNotifications() }
            refreshPermissions()
            if needsInputPermissions {
                Task {
                    _ = await ShareMouseDialog.chooseAsync(
                        "需要键鼠权限", "在设置页的“权限向导”里允许“辅助功能”和“输入监控”。授权后，已连接设备的键鼠共享会自动恢复。", choices: [("ok", "知道了")])
                }
            }
            if !preferences.onboardingComplete { preferences.status = "请逐项授权；完成后点击完成权限设置。登录启动默认关闭。" }
            permissionTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5));
                    if Task.isCancelled { return };
                    self.refreshPermissions()
                }
            }
            do {
                await engine.setBluetoothAvailable(bluetoothAvailable)
                await engine.setNetworkAvailable(networkAvailable)
                try await engine.start()
                do { try await engine.startQuicListener() } catch { log(.warn, "QUICUnavailable") }
                if preferences.onboardingComplete || CBManager.authorization == .allowedAlways { startBluetooth() }
            } catch {
                status = "无法启动网络服务，请检查端口或本地网络权限";
                log(.error, "SessionStartupFailed")
            }
        }
        discovery = LANDiscovery(
            changed: { [weak self] candidates in
                Task { @MainActor in
                    guard let self else { return };
                    self.bonjourCandidates = candidates.filter { !$0.id.contains(engine.discoveryName) };
                    self.refreshCandidates()
                }
            }, status: { [weak self] event in Task { @MainActor in self?.log(.info, event) } })
        discovery?.start()
        pairDiscovery = PairDiscovery(peerID: peer.id.value.uuidString.lowercased(), code: localCode) {
            [weak self] hints in
            Task { @MainActor in
                guard let self else { return };
                self.pairHints = hints.map {
                    LANCandidate(
                        id: "pair:" + $0.0.peerID,
                        endpoint: .hostPort(host: .init($0.1), port: .init(rawValue: $0.0.port)!), peerID: $0.0.peerID,
                        pairCode: $0.0.pairCode)
                };
                self.refreshCandidates();
                self.resolveCodeCollision()
            }
        };
        pairDiscovery?.update(code: localCode, enabled: networkAvailable);
        pairDiscovery?.start()
        do {
            bleAutoTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2));
                    guard !Task.isCancelled, let self else { return }
                    let desired = Set(
                        self.registry.all().filter { $0.trust == .trusted && $0.autoConnect }.map(\.peerID)
                    ).subtracting(self.suppressed)
                    await self.autoConnectBluetooth(desired: desired)
                }
            }
        }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                if self.bluetoothEnabled && self.preferences.onboardingComplete { self.startBluetooth() }
                await self.autoConnect()
            }
        }
    }
    func bluetoothName(_ locator: String) -> String {
        if let id = candidatePeers[locator], let known = knownPeers.first(where: { $0.peerID == id }) {
            return known.name
        }
        return bleNames[locator] ?? "ShareMouse 设备"
    }
    func bluetoothConnected(_ locator: String) -> Bool {
        guard let id = candidatePeers[locator] else { return false };
        return sessions.contains { $0.peerID == id && $0.capabilities.contains("ble") }
    }
    func latencySummary(_ id: String) -> String {
        latencyResults[id]?.map(\.summary).joined(separator: "\n") ?? "延迟／抖动：尚未测试"
    }
    func testLatency(_ id: String) {
        guard let manager, latencyTesting.isEmpty else { return }
        latencyTesting.insert(id)
        Task {
            defer { latencyTesting.remove(id) }
            do {
                let measurement = Task { @MainActor in
                    var capture = 0, send = 0
                    for _ in 0..<10 {
                        try? await Task.sleep(for: .seconds(1));
                        capture += input?.captureRate ?? 0;
                        send += input?.sendRate ?? 0
                    }
                    return (capture / 10, send / 10)
                }
                let results = try await manager.testLatency(peerID: id)
                let rates = await measurement.value
                latencyResults[id] = results
                for value in results {
                    log(
                        .info,
                        "LinkLatencyMeasured transport=\(value.kind) samples=\(value.samples.count) lost=\(value.lost) averageMs=\(value.average) p95Ms=\(value.p95) p99Ms=\(value.p99) maximumMs=\(value.maximum)"
                    )
                }
                latencyRates = "本机实测采样 \(rates.0) 次/秒 · 发出移动 \(rates.1) 次/秒 · 发送合并目标 500 Hz"
                latencySheet = results
            } catch { status = "无法测试：设备未连接" }
        }
    }
    func quickConnect(_ id: String) {
        guard let manager, !busy else { return };
        busy = true;
        suppressed.remove(id)
        Task {
            defer { busy = false }
            if sessions.contains(where: { $0.peerID == id }) {
                reconnectInput();
                return
            }
            if networkAvailable {
                let cached = registry.find(id)?.networkEndpoints ?? []
                for endpoint in cached {
                    if (try? await manager.connect(
                        endpoint: .hostPort(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!),
                        pairCode: nil, password: nil, expectedPeerID: id, timeout: 5, quickOnly: true)) != nil
                    {
                        return
                    }
                }
                for candidate in candidates where candidate.peerID == nil || candidate.peerID == id {
                    if let found = try? await manager.connect(
                        endpoint: candidate.endpoint, pairCode: nil, password: nil, expectedPeerID: id, timeout: 5,
                        quickOnly: true)
                    {
                        candidatePeers[candidate.id] = found;
                        return
                    }
                }
            }
            if bluetoothAvailable, let ble {
                ble.tryDiscovery()
                for locator in bleCandidates.sorted()
                where candidatePeers[locator] == nil || candidatePeers[locator] == id {
                    if let endpoint = try? await ble.connect(locator),
                        let found = try? await manager.connect(
                            endpoint: endpoint, pairCode: nil, password: nil, kind: "ble", expectedPeerID: id,
                            quickOnly: true)
                    {
                        candidatePeers[locator] = found;
                        return
                    }
                }
            }
            status = "快速连接未完成：需要对端将本机设为 Trusted，并允许连接方式"
        }
    }
    func connectBluetoothCandidate(_ locator: String) {
        guard let manager, let ble, !busy else { return };
        busy = true
        bleStatus = "正在连接设备；请在对方 ShareMouse 中允许连接"
        Task {
            defer { busy = false }
            do {
                let endpoint = try await ble.connect(locator);
                let id = try await manager.connect(
                    endpoint: endpoint, pairCode: remoteCode, password: remotePassword, kind: "ble");
                candidatePeers[locator] = id;
                suppressed.remove(id);
                bleStatus = "蓝牙安全连接已建立"
            } catch {
                bleStatus = "连接未完成：对方未允许、设备离线或身份校验失败；请重新点击连接此设备";
                log(.warn, "BluetoothPairingFailed")
            }
        }
    }
    func startBluetooth() {
        bluetoothEnabled = true
        guard ble == nil else { return }
        ble = BLEDiscovery(
            status: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    self.log(.info, event)
                    self.bleStatus =
                        event.contains("Unavailable")
                        ? "蓝牙不可用，请检查系统权限或蓝牙开关"
                        : event == "BLEActiveDiscovery" ? "正在尝试发现（最多 1 分钟）" : "后台发现 ShareMouse 蓝牙设备"
                }
            },
            found: { [weak self] id, name in
                Task { @MainActor in
                    guard let self else { return };
                    if !self.bleCandidates.contains(id) { self.bleCandidates.insert(id) };
                    if self.bleNames[id] != name { self.bleNames[id] = name }
                    let desired = Set(
                        self.registry.all().filter { $0.trust == .trusted && $0.autoConnect }.map(\.peerID)
                    ).subtracting(self.suppressed)
                    Task { await self.autoConnectBluetooth(desired: desired) }
                }
            })
        ble?.updatePairCode(localCode)
        ble?.setAvailable(bluetoothAvailable)
        refreshBluetoothScanning()
        Task {
            do {
                try await manager?.startBluetoothListener();
                ble?.start()
            } catch { bleStatus = "无法启动蓝牙加密服务" }
        }
    }
    func tryBluetoothDiscovery() {
        startBluetooth();
        ble?.tryDiscovery()
    }
    private func refreshCandidates() {
        candidates = pairHints + bonjourCandidates
        for hint in pairHints { if let id = hint.peerID { candidatePeers[hint.id] = id } }
    }
    private func resolveCodeCollision() {
        guard generatedCode,
            pairHints.contains(where: {
                $0.pairCode == localCode && ($0.peerID ?? "") < peer.id.value.uuidString.lowercased()
            })
        else { return }
        let used = Set(pairHints.compactMap(\.pairCode));
        var next = Int(localCode) ?? 0
        repeat { next = (next + 1) % 1_000_000 } while used.contains(String(format: "%06d", next))
        localCode = String(format: "%06d", next);
        appliedCredentials = (localCode, localPassword);
        applyCredentials()
    }
    func credentialsEdited() {
        credentialsPrompt?.cancel()
        if let appliedCredentials, localCode != appliedCredentials.0 { generatedCode = false }
        credentialsPrompt = Task {
            try? await Task.sleep(for: .milliseconds(350));
            guard !Task.isCancelled else { return };
            applyCredentials()
        }
    }
    func deletePeer(_ id: String) {
        suppressed.insert(id)
        Task {
            await manager?.disconnect(id);
            do {
                try registry.remove(id);
                knownPeers = registry.all()
            } catch { status = "删除设备未完成" }
        }
    }
    func reconnectInput() {
        sharingRequested = true;
        automaticInputPending = true;
        enableInput(resumePeers: true)
    }
    func applyCredentials() {
        Task {
            do {
                guard localCode.count == 6 else {
                    status = "配对码需要 6 位数字";
                    return
                }
                if pairHints.contains(where: { $0.pairCode == localCode }) {
                    if appliedCredentials?.0 != localCode {
                        _ = await ShareMouseDialog.chooseAsync(
                            "这个配对码已被占用", "附近有设备在用这个配对码，请换一个 6 位数字。换好之前，原来的配对码继续有效。", choices: [("ok", "知道了")],
                            kind: .warning);
                        localCode = appliedCredentials?.0 ?? localCode
                    };
                    return
                }
                try await manager?.updateCredentials(pairCode: localCode, password: localPassword);
                appliedCredentials = (localCode, localPassword)
                pairDiscovery?.update(code: localCode, enabled: networkAvailable);
                ble?.updatePairCode(localCode);
                status = "配对信息已自动更新"
            } catch { status = "配对码需要 6 位数字；密钥可留空" }
        }
    }
    func stopBluetooth() {
        bluetoothEnabled = false
        ble?.stop();
        ble = nil;
        bleCandidates = [];
        bleStatus = "蓝牙发现和连接已停止"
        Task { for session in sessions { await manager?.disconnectTransport(session.peerID, kind: "ble") } }
    }
    func connect() {
        guard let manager, !busy else { return }
        busy = true;
        status = "正在验证对方设备"
        let code = remoteCode, secret = remotePassword,
            host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                if !host.isEmpty && networkAvailable {
                    let id = try await manager.connect(
                        endpoint: .hostPort(host: NWEndpoint.Host(host), port: 49160), pairCode: code, password: secret)
                    suppressed.remove(id)
                } else {
                    let options =
                        networkAvailable
                        ? candidates.filter {
                            ($0.pairCode == nil || $0.pairCode == code)
                                && (selectedCandidate.isEmpty || $0.id == selectedCandidate)
                        }.sorted { $0.pairCode != nil && $1.pairCode == nil } : []
                    var connected = false
                    for candidate in options {
                        do {
                            let id = try await manager.connect(
                                endpoint: candidate.endpoint, pairCode: code, password: secret,
                                expectedPeerID: candidate.peerID, timeout: 5)
                            candidatePeers[candidate.id] = id;
                            suppressed.remove(id);
                            connected = true;
                            break
                        } catch { continue }
                    }
                    if !connected, bluetoothAvailable, let ble {
                        for locator in bleCandidates.sorted()
                        where !bleNames[locator, default: ""].hasPrefix("SM") || bleNames[locator] == "SM" + code {
                            do {
                                let endpoint = try await ble.connect(locator)
                                let id = try await manager.connect(
                                    endpoint: endpoint, pairCode: code, password: secret, kind: "ble")
                                candidatePeers[locator] = id;
                                suppressed.remove(id);
                                connected = true;
                                break
                            } catch { continue }
                        }
                    }
                    guard connected else { throw PairingError.authenticationFailed }
                }
                remotePassword = "";
                status = "安全连接已建立"
            } catch {
                let failure = error as NSError;
                log(.warn, "PairingFailed domain=\(failure.domain) code=\(failure.code)");
                status = "连接失败：请检查配对信息、设备身份和网络权限"
            }
        }
    }
    private func autoConnect() async {
        guard let manager, !busy, !autoConnecting else { return };
        autoConnecting = true;
        defer { autoConnecting = false }
        await manager.recoverNetworkLinks(excluding: suppressed)
        let connected = Set(sessions.map(\.peerID))
        let desired = Set(registry.all().filter { $0.trust == .trusted && $0.autoConnect }.map(\.peerID)).subtracting(
            connected
        ).union(sessions.filter { !$0.capabilities.contains("tcp") }.map(\.peerID)).subtracting(suppressed)
        let localID = peer.id.value.uuidString.lowercased()
        for candidate in candidates where !desired.isEmpty {
            if let id = candidatePeers[candidate.id] {
                let declined = await manager.autoConnectionDeclined(id);
                if !desired.contains(id) || declined { continue }
            }
            if let id = try? await manager.connect(
                endpoint: candidate.endpoint, pairCode: nil, password: nil, autoOnly: true)
            {
                candidatePeers[candidate.id] = id
            }
        }
        // Restore the primary link before attempting an optional upgrade. Only one peer upgrades.
        for session in sessions
        where networkAvailable && localID < session.peerID && !session.capabilities.contains("quic") {
            if let host = session.lanHost {
                _ = try? await manager.connect(
                    endpoint: .hostPort(host: .init(host), port: 49164), pairCode: nil, password: nil, autoOnly: true,
                    kind: "quic")
            }
        }
        await autoConnectBluetooth(desired: desired)
    }
    private var bleConnecting = false
    private var nextBLEFallback = Date().addingTimeInterval(10)
    private func autoConnectBluetooth(desired: Set<String>) async {
        guard let manager, !busy, !bleConnecting, bluetoothAvailable, pendingConnectionDialogs == 0 else { return };
        bleConnecting = true;
        defer { bleConnecting = false }
        let localID = peer.id.value.uuidString.lowercased()
        // Choose the initiator even before a session exists, not only after locator mapping.
        let allowFallback = Date() >= nextBLEFallback
        let eligible = desired.filter { peerID in
            localID < peerID || allowFallback && !sessions.contains(where: { $0.peerID == peerID })
        }.union(sessions.filter { localID < $0.peerID && !$0.capabilities.contains("ble") }.map(\.peerID))
        if let ble, !eligible.isEmpty {
            nextBLEFallback = Date().addingTimeInterval(10)
            for locator in bleCandidates.sorted() {
                if let id = candidatePeers[locator], await manager.autoConnectionDeclined(id) { continue }
                if let id = candidatePeers[locator],
                    sessions.contains(where: { $0.peerID == id && ($0.capabilities.contains("ble") || localID > id) })
                {
                    continue
                }
                if candidatePeers[locator] == nil && desired.isEmpty
                    && !sessions.contains(where: { localID < $0.peerID && !$0.capabilities.contains("ble") })
                {
                    continue
                }
                if let endpoint = try? await ble.connect(locator),
                    let id = try? await manager.connect(
                        endpoint: endpoint, pairCode: nil, password: nil, autoOnly: true, kind: "ble")
                {
                    candidatePeers[locator] = id;
                    objectWillChange.send()
                }
            }
        }
    }

    private func refreshBluetoothScanning() {
        // A raw GATT bridge may still be authenticating; only an established BLE session pauses scanning.
        ble?.setRealtimeInputEnabled(input?.enabled == true && sessions.contains { $0.capabilities.contains("ble") })
    }
    private func sessionsChanged(_ values: [SessionInfo]) {
        let newlyKnown = values.filter { !trustAsked.contains($0.peerID) };
        trustAsked.formUnion(newlyKnown.map(\.peerID))
        for item in newlyKnown { Task { await self.offerTrust(item) } }
        let freshConnection = values.contains { item in
            !sessions.contains(where: { $0.peerID == item.peerID && $0.sessionID == item.sessionID })
        }
        connectionPromptOpen = true
        defer {
            connectionPromptOpen = false;
            if freshConnection && sharingRequested { automaticInputPending = true };
            startAutomaticInput()
        }
        notifications.connections(values)
        sessions = values;
        knownPeers = registry.all();
        refreshBluetoothScanning()
        for item in values { ShareMouseDialog.completeConnection(item.peerID) }
        Task { await group?.connectionsChanged(values) }
        status = values.isEmpty ? "等待配对" : "安全连接已建立"

    }
    private func offerTrust(_ item: SessionInfo) async {
        pendingConnectionDialogs += 1;
        defer {
            pendingConnectionDialogs -= 1;
            startAutomaticInput()
        }
        let trusted =
            await ShareMouseDialog.chooseAsync(
                "信任“\(item.name)”？", "信任后，对方用快速连接连这台电脑时，不需要再输入密钥。", choices: [("no", "暂不信任"), ("yes", "信任")],
                kind: .connection) == "yes"
        try? registry.setPreferences(item.peerID, trusted: trusted, autoConnect: false);
        knownPeers = registry.all()
        if trusted {
            let automatic =
                await ShareMouseDialog.chooseAsync(
                    "自动连接“\(item.name)”？", "以后发现这台设备时，自动向它发起连接，对方仍需确认。对方拒绝后，本次运行期间不再提示，你仍可以手动快速连接。",
                    choices: [("no", "手动连接"), ("yes", "自动连接")], kind: .connection) == "yes"
            setPreferences(item.peerID, trusted: true, autoConnect: automatic)
        }
    }
    func setPreferences(_ id: String, trusted: Bool, autoConnect: Bool) {
        do {
            try registry.setPreferences(id, trusted: trusted, autoConnect: autoConnect);
            if autoConnect { suppressed.remove(id) };
            knownPeers = registry.all()
        } catch { status = "无法保存设备偏好" }
    }
    func disconnect(_ id: String) {
        suppressed.insert(id)
        Task {
            await manager?.disconnect(id);
            try? await Task.sleep(for: .seconds(10));
            suppressed.remove(id)
        }
    }
    private var stopping = false
    func stop() {
        stopping = true
        mcp?.stop();
        computer?.stop();
        computerAdapter.stop()
        historyPopup.stop();
        credentialsPrompt?.cancel();
        permissionTask?.cancel();
        notifications.stop();
        history?.stop();
        files?.stop();
        clipboard?.stop();
        clipboardAdapter.stop();
        clipboardShortcut.reset();
        sharingShortcut.reset();
        input?.stop();
        inputAdapter?.stop()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) };
        displayObserver = nil
        bleAutoTask?.cancel();
        autoTask?.cancel();
        discovery?.stop();
        pairDiscovery?.stop();
        ble?.stop()
        Task { await manager?.stop() }
    }
    private func needsSharedPaste() -> Bool {
        let version = NSPasteboard.general.changeCount
        if localCutVersion == version { return true }
        if clipboardAdapter.hasUnobservedChange
            || preparingLocalFiles?.version == version && preparingLocalFiles?.previousEntryID == clipboard?.current?.id
        {
            return false
        }
        guard groupState != nil, let entry = clipboard?.current else { return false }
        if let appliedClipboard, appliedClipboard.entryID == entry.id, appliedClipboard.revision == entry.fileRevision,
            appliedClipboard.version == version
        {
            return false
        }
        return entry.sourcePeerID != peer.id.value.uuidString.lowercased()
    }
    private func markAppliedClipboard() {
        if let entry = clipboard?.current {
            appliedClipboard = (entry.id, entry.fileRevision, NSPasteboard.general.changeCount)
        }
    }
    @discardableResult private func clipboardCommand(
        _ command: String, entryID expectedEntryID: String? = nil, source: String? = nil
    ) async throws -> Bool {
        if command == "history" {
            openHistory();
            return true
        }
        guard let clipboard, let inputAdapter else { return false }
        if command == "paste", localCutVersion == NSPasteboard.general.changeCount, FinderFiles.canCut,
            groupState == nil || clipboard.current?.sourcePeerID == peer.id.value.uuidString.lowercased(),
            expectedEntryID == nil || expectedEntryID == clipboard.current?.id
        {
            localCutVersion = nil
            try inputAdapter.inject(CapturedInput("command", command: "moveFiles"), screen: nil, x: 0, y: 0)
            return true
        }
        if command == "paste" {
            if source == nil || source == peer.id.value.uuidString.lowercased(), !needsSharedPaste() { return false }
            guard !pasting else { return true };
            pasting = true;
            defer { pasting = false }
            do {
                let screenID = input?.pointer?.screenID;
                await clipboardAdapter.poll()
                if let expectedEntryID, let source { try await clipboard.waitForEntry(expectedEntryID, from: source) }
                guard input?.pointer?.screenID == screenID else { throw ClipboardError.changed }
                guard !clipboardAdapter.hasUnobservedChange else { throw ClipboardError.changed }
                if !needsSharedPaste() { return false }
                if clipboard.current?.sourcePeerID == peer.id.value.uuidString.lowercased(),
                    localCutVersion != NSPasteboard.general.changeCount
                {
                    return false
                }
                let pasteboardVersion = NSPasteboard.general.changeCount
                let entryID = clipboard.current?.id
                if clipboard.current?.kind == "files" {
                    var destination = FinderFiles.destination();
                    if destination == nil { destination = await chooseDestination() };
                    guard let destination else { return true }
                    guard clipboard.current?.id == entryID, NSPasteboard.general.changeCount == pasteboardVersion,
                        input?.pointer?.screenID == screenID
                    else { throw ClipboardError.changed }
                    startFilePaste(destination);
                    return true
                }
                let content = try await clipboard.content()
                guard clipboard.current?.id == entryID, input?.pointer?.screenID == screenID,
                    NSPasteboard.general.changeCount == pasteboardVersion
                else { throw ClipboardError.changed }
                if let text = content.plainText {
                    try history?.remember(text, entryID: clipboard.current?.id, timestamp: clipboard.current?.timestamp)
                };
                try clipboardAdapter.writeContent(content);
                markAppliedClipboard();
                try inputAdapter.inject(CapturedInput("command", command: "paste"), screen: nil, x: 0, y: 0)
            } catch let error as InputAdapterError {
                clipboardStatus = "系统拒绝输入注入，请检查辅助功能权限";
                throw error
            } catch {
                clipboardStatus = "粘贴未完成：来源离线、当前项变化或类型不可用";
                notifications.toast("粘贴未完成", "来源离线、当前项变化或系统剪贴板暂不可读；键鼠共享继续运行");
                return true
            }
            return true
        }
        if command == "cut" { return try await cutSelectedContent() }
        if command == "copy" {
            try inputAdapter.inject(CapturedInput("command", command: command), screen: nil, x: 0, y: 0)
            try? await Task.sleep(for: .milliseconds(80));
            await clipboardAdapter.poll();
            return true
        }
        return false
    }
    private func captureSelectedCut() -> Bool {
        let application = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screenID = input?.pointer?.screenID
        // Consume only X; let the modifier pass normally, and query AX outside the native tap callback.
        Task { [weak self] in
            guard let self, !self.stopping, self.input?.remoteScreenID == nil,
                self.input?.pointer?.screenID == screenID,
                NSWorkspace.shared.frontmostApplication?.processIdentifier == application
            else { return }
            do { _ = try await self.cutSelectedContent() } catch { self.clipboardStatus = "系统拒绝剪切，请检查辅助功能权限" }
        }
        return true
    }
    private func cutSelectedContent() async throws -> Bool {
        guard !cutting, !stopping, let application = NSWorkspace.shared.frontmostApplication, let inputAdapter else {
            return true
        }
        cutting = true;
        defer { cutting = false }
        let selection = MacCutSelection.content(in: application)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            return true
        }
        switch selection {
        case .none: clipboardStatus = "未选中文本，未执行剪切"
        case .unavailable: clipboardStatus = "无法确认选中内容，未执行剪切"
        case .text:
            try inputAdapter.inject(CapturedInput("command", command: "cut"), screen: nil, x: 0, y: 0)
            try? await Task.sleep(for: .milliseconds(80));
            await clipboardAdapter.poll()
        case .files:
            let paths = FinderFiles.selection()
            guard !paths.isEmpty,
                NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
            else { return true }
            do {
                try clipboardAdapter.writeFiles(paths, cut: true)
                let version = NSPasteboard.general.changeCount;
                localCutVersion = version
                if groupState != nil {
                    try await files?.copy(
                        paths, cut: true, stillCurrent: { NSPasteboard.general.changeCount == version })
                }
            } catch { clipboardStatus = "所选文件不可用或已被新的 Copy 替换" }
        }
        return true
    }
    private func chooseDestination() async -> String? {
        let panel = NSOpenPanel();
        panel.canChooseDirectories = true;
        panel.canChooseFiles = false;
        panel.allowsMultipleSelection = false;
        panel.message = "选择文件粘贴目标";
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url?.path : nil) }
        }
    }
    func pasteFiles() { Task { if let destination = await chooseDestination() { startFilePaste(destination) } } }
    private func startFilePaste(_ destination: String) {
        let pasteboardVersion = NSPasteboard.general.changeCount
        Task {
            do {
                guard let files else { return };
                guard NSPasteboard.general.changeCount == pasteboardVersion else { throw ClipboardError.changed };
                let taskID = try await files.paste(destination)
                if let task = files.currentTasks.first(where: { $0.id == taskID }), task.state == "failed",
                    task.files.isEmpty
                {
                    notifications.toast("文件传输失败", "来源离线或文件清单不可用；可在传输记录重试，键鼠共享继续运行")
                }
                if let task = files.currentTasks.first(where: { $0.id == taskID }), task.state == "completed",
                    task.files.contains(where: { $0.completed }), clipboard?.current?.id == task.entry.id,
                    NSPasteboard.general.changeCount == pasteboardVersion
                {
                    try clipboardAdapter.writeFiles(
                        task.files.filter { $0.item.id == $0.item.rootID && $0.completed }.map(\.target))
                    markAppliedClipboard()
                }
            } catch { clipboardStatus = "文件粘贴未完成；请在传输记录中重试" }
        }
    }
    func transferAction(_ task: TransferTask, _ action: String) {
        if action == "pause" { files?.pause(task.id) };
        if action == "cancel" { files?.cancel(task.id) };
        if action == "resume" { Task { await files?.resume(task.id) } };
        if action == "open" { NSWorkspace.shared.open(URL(fileURLWithPath: task.destination)) }
    }
    func refreshPermissions() {
        let post = CGPreflightPostEventAccess();
        let listen = CGPreflightListenEventAccess()
        let bluetooth: String
        switch CBManager.authorization {
        case .allowedAlways: bluetooth = "已允许";
        case .denied, .restricted: bluetooth = "未允许";
        case .notDetermined: bluetooth = "点击发现后由系统询问";
        @unknown default: bluetooth = "未知"
        }
        permissionStatus =
            "辅助功能：\(inputAdapter?.canInject == true ? "已允许" : "未允许")\n输入监控：\(listen ? "已允许" : "未允许")\n蓝牙：\(bluetooth)\n网络服务：\(status)"
        let permitted = post && listen && inputAdapter?.canInject == true
        if !permitted {
            if previousInputPermission || inputEnabled { stopInputForPermissionLoss() }
        } else {
            // Retry a failed event-tap startup on the next refresh, without recursive retry.
            try? inputAdapter?.start()
            if !previousInputPermission { automaticInputPending = true }
            startAutomaticInput()
        }
        previousInputPermission = permitted
    }
    func configureNotifications() {
        preferences.save();
        Task {
            if !(await notifications.configure()) { preferences.status = "原生通知未获授权或不可用，已采用自定义提示" };
            notifications.transfers(transfers)
        }
    }
    func testNotification() { notifications.toast("ShareMouse", "后台服务正在运行；此提示可手动隐藏。") }
    private func refreshHistory() {
        historyEntries = history?.entries ?? [];
        historyStatus = history?.status ?? historyStatus
    }
    func openHistory() { historyPopup.show(self) }
    func manageHistory() { historyPopup.showManagement(self) }
    func configureHistoryPopup(_ count: Int, side: String) {
        do { try history?.configurePopup(visibleCount: count, preferredSide: side) } catch {
            historyStatus = "显示条目需为 1–9 条"
        }
    }
    func syncHistory() { Task { await history?.sync() } }
    func shareFavorites() { Task { await history?.shareFavorites() } }
    func favoriteHistory(_ id: String) { do { try history?.favorite(id) } catch { historyStatus = "无法保存收藏" } }
    func configureHistory(_ capacity: Int, key: String, modifiers: [String]) {
        do { try history?.configure(capacity: capacity, key: key, modifiers: modifiers) } catch {
            historyStatus = "容量需为 1–1000，快捷键需包含修饰键"
        }
    }
    func selectHistory(_ entry: HistoryEntry, paste: Bool = false, expectedApplication: pid_t? = nil) {
        let screenID = input?.pointer?.screenID;
        let version = NSPasteboard.general.changeCount;
        Task {
            do {
                try await clipboard?.publishText(entry.text);
                guard NSPasteboard.general.changeCount == version else { throw ClipboardError.changed };
                try clipboardAdapter.writeText(entry.text);
                let appliedVersion = NSPasteboard.general.changeCount;
                try history?.remember(entry.text, entryID: clipboard?.current?.id, favorite: entry.favorite);
                if paste {
                    try await Task.sleep(for: .milliseconds(40));
                    guard input?.pointer?.screenID == screenID, NSPasteboard.general.changeCount == appliedVersion,
                        expectedApplication == nil
                            || NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedApplication
                    else {
                        historyStatus = "目标已改变；历史内容已加载，请手动粘贴";
                        return
                    };
                    try inputAdapter?.inject(CapturedInput("command", command: "paste"), screen: nil, x: 0, y: 0)
                }
            } catch { historyStatus = "无法选择历史项" }
        }
    }
    func loadClipboard() {
        let version = NSPasteboard.general.changeCount
        Task {
            do {
                guard let clipboard else { return };
                let content = try await clipboard.content();
                guard NSPasteboard.general.changeCount == version else { throw ClipboardError.changed };
                try clipboardAdapter.writeContent(content);
                markAppliedClipboard();
                if let text = content.plainText {
                    try history?.remember(text, entryID: clipboard.current?.id, timestamp: clipboard.current?.timestamp)
                };
                clipboardStatus = "已加载到本机剪贴板"
            } catch { clipboardStatus = "无法加载：剪贴板来源不可达或当前类型不可用" }
        }
    }
    private func currentLocalCursor() -> CapturedInput? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        for screen in NSScreen.screens {
            let display =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                ?? CGMainDisplayID()
            let bounds = CGDisplayBounds(display)
            if bounds.contains(point), bounds.width > 0, bounds.height > 0 {
                return CapturedInput(
                    "move", screenID: peer.id.value.uuidString.lowercased() + ":" + String(display),
                    x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
            }
        }
        return nil
    }
    func enableInput(resumePeers: Bool = false) {
        peerResumePending = peerResumePending || resumePeers
        guard throughputTesting.isEmpty, computer?.controlling != true, pendingConnectionDialogs == 0, !inputStarting,
            let input, let inputAdapter
        else { return };
        inputStarting = true
        let revision = inputPauseRevision
        Task {
            defer {
                inputStarting = false;
                inputEnabled = input.enabled
            }
            guard !stopping, revision == inputPauseRevision else { return }
            guard throughputTesting.isEmpty, computer?.controlling != true, pendingConnectionDialogs == 0 else {
                // A controller or dialog can take over after this task was queued.
                automaticInputPending = true;
                return
            }
            do {
                try inputAdapter.start();
                if !input.enabled {
                    try await input.enable(
                        preservingLocalCursor: resumePreservingUserCursor ? currentLocalCursor() : nil);
                    resumePreservingUserCursor = false
                }
                if stopping || revision != inputPauseRevision || computer?.controlling == true {
                    input.pause()
                } else {
                    automaticInputPending = !input.enabled;
                    if peerResumePending && input.enabled {
                        peerResumePending = false;
                        input.requestPeerResume();
                        notifications.inputReconnected(
                            sessions, bluetoothPreferred: manager?.bluetoothInputOnly ?? false)
                    }
                }
            } catch {
                if revision == inputPauseRevision { automaticInputPending = true }
                inputStatus = "正在等待输入监听就绪；请检查辅助功能与输入监控权限"
            }
        }
    }
    func setSensitivity(_ peer: String, _ value: Double) {
        guard value.isFinite else { return }
        preferences.pointerSensitivity[peer] = max(0.1, min(4, value));
        preferences.save();
        objectWillChange.send()
    }
    func setScrollInversion(_ peer: String, horizontal: Bool? = nil, vertical: Bool? = nil) {
        if let horizontal { preferences.reverseScrollHorizontal[peer] = horizontal }
        if let vertical { preferences.reverseScrollVertical[peer] = vertical }
        preferences.save();
        objectWillChange.send()
    }
    func setHorizontalScrollAngle(_ peer: String, _ value: Double) {
        guard value.isFinite else { return }
        preferences.horizontalScrollAngle[peer] = max(0, min(90, value));
        preferences.save();
        objectWillChange.send()
    }
    func setKeyboardOptions(fn: Bool? = nil, functions: Bool? = nil) {
        if let fn { preferences.fnEnabled = fn };
        if let functions { preferences.functionKeysEnabled = functions }
        preferences.save();
        input?.configureKeyboard(fn: preferences.fnEnabled, functions: preferences.functionKeysEnabled);
        objectWillChange.send()
        notifications.toast(
            "远端键盘设置",
            "Fn：\(preferences.fnEnabled ? "开启" : "关闭") · 功能键映射：\(preferences.functionKeysEnabled ? "开启" : "关闭")")
    }
    func setScreenCrossing(_ enabled: Bool) {
        preferences.screenCrossingEnabled = enabled;
        preferences.save();
        input?.screenCrossingEnabled = enabled;
        objectWillChange.send()
        notifications.toast(enabled ? "鼠标穿屏已开启" : "鼠标穿屏已关闭", enabled ? "可以跨越相邻屏幕" : "停留在当前电脑；远端键鼠继续工作")
    }
    func pauseInput() {
        sharingRequested = false;
        inputPauseRevision += 1;
        automaticInputPending = false;
        clipboardShortcut.reset();
        input?.pause();
        inputEnabled = false;
        inputStatus = "键鼠共享已暂停，本机输入已恢复"
    }
    func exitMCPControl() { computer?.endControl(reason: "user_exit") }
    private var mcpServing = false
    private var requestedMcpScreenCapture = false
    func configureMCP() {
        computerAdapter.defaultControlMode = preferences.computerControlMode

        preferences.save();
        computerAdapter.showHints = preferences.computerCursorHints
        guard let computer else { return }
        computer.allowComputer = preferences.allowComputerUse;
        computer.allowFiles = preferences.allowMcpFiles
        if !preferences.allowComputerUse { computer.endControl() }
        if preferences.allowComputerUse, !CGPreflightScreenCaptureAccess(), !requestedMcpScreenCapture {
            requestedMcpScreenCapture = true;
            requestScreenCapture()
        }
        Task { await computer.updateCapabilities() }
        if preferences.mcpEnabled {
            do {
                if mcp == nil {
                    guard let url = Bundle.main.url(forResource: "tools", withExtension: "json") else {
                        throw ComputerUseError.message("MCP 工具定义缺失")
                    };
                    mcp = try MCPServer(service: computer, directory: directory, tools: Data(contentsOf: url))
                };
                try mcp?.start();
                mcpServing = true;
                mcpStatus = "MCP · 127.0.0.1:49170 · 已启用"
            } catch {
                mcpServing = false;
                mcpStatus = "MCP 启动失败：" + error.localizedDescription
            }
        } else {
            mcp?.stop();
            mcpServing = false;
            mcpStatus = "MCP 服务未启用"
        }
        let serving = mcpServing;
        Task { await manager?.setCapability("mcp-server", enabled: serving) }
    }
    func copyMCPConfiguration() {
        guard let bridge = Bundle.main.path(forResource: "bridge", ofType: "py") else {
            mcpStatus = "接入脚本缺失";
            return
        }
        let config: [String: Any] = [
            "mcpServers": [
                "ShareMouse": [
                    "command": "/usr/bin/python3",
                    "args": [bridge, "--token-file", directory.appendingPathComponent("mcp-token").path],
                ]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            NSPasteboard.general.clearContents();
            NSPasteboard.general.setString(text, forType: .string);
            mcpStatus = "接入配置已复制"
        }
    }
    func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess();
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    private func startAutomaticInput() {
        guard !stopping, throughputTesting.isEmpty, sharingRequested, computer?.controlling != true,
            automaticInputPending, !connectionPromptOpen, pendingConnectionDialogs == 0, !inputStarting,
            input?.enabled != true, groupOnline.count > 1, inputAdapter?.canCapture == true,
            inputAdapter?.canInject == true
        else { return }
        automaticInputPending = false;
        enableInput()
    }
    private func stopInputForPermissionLoss() {
        inputPauseRevision += 1
        computer?.endControl()
        inputAdapter?.stop();
        clipboardShortcut.reset();
        history?.resetCapture();
        input?.pause();
        inputEnabled = false
        automaticInputPending = true
        inputStatus = "输入监听已停止，本机事件已放行；授权后自动恢复共享"
        if previousInputPermission { notifications.toast("输入权限已撤销", "已停止拦截本机输入；文件与剪贴板继续运行") }
        previousInputPermission = false
    }
    func requestInputPermissions() {
        inputAdapter?.requestPermissions();
        inputStatus = "在系统设置中逐项允许辅助功能与输入监控，已连接时自动共享"
    }
    func requestAccessibility() {
        inputAdapter?.requestAccessibility();
        refreshPermissions()
    }
    func requestInputMonitoring() {
        inputAdapter?.requestInputMonitoring();
        refreshPermissions()
    }
    func requestFinderPermission() {
        finderPermissionStatus = "等待系统授权"
        Task {
            let result = await Task.detached { FinderFiles.automationPermission(request: true) }.value
            finderPermissionStatus = result == noErr ? "已允许" : "未允许；仅 Finder 文件选择不可用"
        }
    }
    func finishPermissionSetup() {
        preferences.onboardingComplete = true;
        preferences.status = "权限向导已完成；未授权模块可稍后逐项申请。";
        preferences.save();
        refreshPermissions()
    }
    func presentPermissionDeclaration() {
        let decision = ShareMouseDialog.choose(
            "ShareMouse 需要几项权限",
            "每一项都会单独向系统申请，由你在系统窗口里确认。\n\n辅助功能：向其他电脑发送键鼠输入\n输入监控：捕获这台电脑的键鼠\n局域网：和其他设备建立加密连接\n蓝牙、Finder 自动化：可选\n\n点“开始授权”会先申请辅助功能，其余几项在设置页里逐项申请，也可以稍后处理。",
            choices: [("cancel", "稍后处理"), ("start", "开始授权")], kind: .info)
        if decision == "start" { requestAccessibility() }
    }
    func editConfig() {
        guard let group else { return }
        if let window = configWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil);
            return
        }
        Task {
            let configs = await group.keyboardLibrary, selected = await group.selectedKeyboardConfig
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1140, height: 820),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "共享键盘配置";
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: (ConfigEditor(
                    owner: peer.id.value.uuidString.lowercased(),
                    save: { configs, id in try await group.saveKeyboardLibrary(configs, selected: id) },
                    configs: configs, selected: selected)).shareMouseSurface())
            window.minSize = NSSize(width: 1080, height: 760);
            configWindow = window;
            window.center();
            window.makeKeyAndOrderFront(nil);
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func editLayout() {
        guard let group, !layoutStarting, layoutLease == nil else { return };
        layoutStarting = true
        layoutError = ""
        let generation = layoutEditGeneration
        Task {
            defer { if generation == layoutEditGeneration { layoutStarting = false } }
            do {
                let lease = try await group.beginEdit("layout")
                if generation != layoutEditGeneration || groupOnline.count < 2 {
                    await group.release(lease);
                    return
                }
                layoutDraft = groupState?.layout ?? [];
                layoutLease = lease
            } catch { layoutError = "无法编辑：请连接已配对电脑，或等待另一端完成编辑" }
        }
    }
    func commitLayout(_ layout: [ScreenGeometry], lease: GroupEditLock) async throws {
        guard let group else { throw GroupError.offline }
        lastNativeLayout = nil
        layoutCommitting = true;
        defer { layoutCommitting = false }
        do { try await group.commitLayout(layout, lock: lease) } catch {
            layoutLease = nil;
            await group.release(lease);
            groupState = await group.active;
            throw error
        }
        await group.release(lease);
        groupState = await group.active;
        applyNativeLayout(groupState?.layout ?? []);
        layoutLease = nil
    }
    func cancelLayoutEdit() {
        layoutEditGeneration += 1;
        layoutStarting = false;
        layoutError = "";
        guard let lease = layoutLease else { return };
        layoutLease = nil;
        Task { await group?.release(lease) }
    }
    func releaseLayout(_ lease: GroupEditLock) async { await group?.release(lease) }
    func createGroup() { groupOperation { try await $0.create() } }
    func leaveGroup() { groupOperation { try await $0.leave() } }
    func activateGroup() {
        let id = selectedGroup;
        groupOperation { try await $0.activate(id) }
    }
    func joinGroup(_ peerID: String) { groupOperation { try await $0.join(peerID) } }
    func recommendPeer(_ peerID: String) { groupOperation { try await $0.recommend(peerID) } }
    private func connectGroupMember(_ member: GroupMember, _ groupID: String) async throws {
        guard registry.find(member.peerID) != nil, !suppressed.contains(member.peerID) else {
            throw PairingError.disconnected
        }
        guard let manager else { throw GroupError.offline }
        if let host = member.host {
            do {
                _ = try await manager.connect(
                    endpoint: .hostPort(host: .init(host), port: .init(rawValue: member.port)!), pairCode: nil,
                    password: nil, autoOnly: true, groupID: groupID, expectedPeerID: member.peerID);
                return
            } catch {}
        }
        if let ble {
            for locator in bleCandidates.sorted() {
                if let mapped = candidatePeers[locator], mapped != member.peerID,
                    sessions.contains(where: { $0.peerID == mapped })
                {
                    continue
                }
                do {
                    let endpoint = try await ble.connect(locator)
                    _ = try await manager.connect(
                        endpoint: endpoint, pairCode: nil, password: nil, autoOnly: true, kind: "ble", groupID: groupID,
                        expectedPeerID: member.peerID)
                    candidatePeers[locator] = member.peerID;
                    return
                } catch {}
            }
        }
        throw GroupError.offline
    }
    private func groupOperation(_ operation: @escaping @Sendable (GroupManager) async throws -> Void) {
        guard let group else { return }
        Task { do { try await operation(group) } catch { groupStatus = "操作未完成：检查当前设备组、在线状态或编辑锁" } }
    }
    private func applyNativeLayout(_ layout: [ScreenGeometry]) {
        let local = layout.filter { $0.peerID == peer.id.value.uuidString.lowercased() }
        guard !applyingDisplayLayout, local != lastNativeLayout else { return }
        lastNativeLayout = local;
        applyingDisplayLayout = true;
        defer { applyingDisplayLayout = false }
        do {
            try MacDisplayLayout.apply(
                layout, peerID: peer.id.value.uuidString.lowercased(),
                backup: directory.appendingPathComponent("display-layout-backup.json"));
            nativeLayoutError = ""
        } catch {
            nativeLayoutError = "系统屏幕排布同步未完成：同一电脑的屏幕须相连；镜像或系统不支持的排布请调整后再保存";
            log(.warn, "NativeDisplayLayoutRejected")
        }
    }
    static func localScreens(_ peerID: String) -> [ScreenGeometry] {
        var sizes: [String: (Double, Double)] = [:]
        let screens = NSScreen.screens.enumerated().map { index, screen in
            let id =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                ?? CGMainDisplayID()
            let width = Int(CGDisplayPixelsWide(id)), height = Int(CGDisplayPixelsHigh(id))
            let bounds = CGDisplayBounds(id);
            sizes[peerID + ":" + String(id)] = (Double(width), Double(height))
            return ScreenGeometry(
                id: peerID + ":" + String(id), peerID: peerID, name: screen.localizedName, number: index + 1,
                pixelWidth: Int(bounds.width), pixelHeight: Int(bounds.height), primary: id == CGMainDisplayID(),
                x: bounds.minX, y: bounds.minY)
        }
        return ScreenGeometry.nativeLayout(screens, sizes: sizes)
            ?? screens.map { screen in
                var next = screen;
                let size = sizes[screen.id]!;
                next.pixelWidth = Int(size.0);
                next.pixelHeight = Int(size.1);
                return next
            }
    }
    static func confirmGroupMember(_ member: GroupMember) -> Bool {
        ShareMouseDialog.choose(
            "允许“\(member.name)”加入桌面组？", "先核对设备身份。加入桌面组不等于信任这台设备。", choices: [("cancel", "拒绝"), ("allow", "允许加入")],
            detail: ShareMouseDialog.identity(peerID: member.peerID, publicKey: member.publicKey), kind: .connection)
            == "allow"
    }
    private func connectionChoice(
        _ title: String, _ message: String, allow: String, peerID: String? = nil, detail: String? = nil
    ) async -> Bool {
        if let peerID, let manager, await manager.currentSessions().contains(where: { $0.peerID == peerID }) {
            return true
        }
        pendingConnectionDialogs += 1
        let resume = input?.enabled == true, revision = inputPauseRevision
        if resume {
            input?.pause();
            inputEnabled = false
        }
        defer {
            pendingConnectionDialogs -= 1
            if resume, revision == inputPauseRevision { automaticInputPending = true }
            startAutomaticInput()
        }
        // Wait only for this approval, leaving MainActor free for link and input recovery.
        return await ShareMouseDialog.chooseAsync(
            title, message, choices: [("cancel", "拒绝"), ("allow", allow)], peerID: peerID, detail: detail,
            kind: .connection) == "allow"
    }
    private func confirmIdentity(_ certificate: CertificatePeer) async -> Bool {
        await connectionChoice(
            "核对对方的设备身份", "在对方电脑的 ShareMouse 里查看设备身份，确认下面两项完全一致。", allow: "一致，允许连接",
            detail: ShareMouseDialog.identity(peerID: certificate.peerID, publicKey: certificate.publicKey))
    }
    private func confirmReconnect(_ name: String, peerID: String) async -> Bool {
        await connectionChoice("允许“\(name)”连接？", "这是已经配对过的设备。允许后会自动开始共享键鼠。", allow: "允许", peerID: peerID)
    }
    private func confirmBluetoothConnection(_ name: String, peerID: String) async -> Bool {
        await connectionChoice("“\(name)”请求通过蓝牙连接", "允许后会自动开始共享键鼠。", allow: "允许连接", peerID: peerID)
    }
}
