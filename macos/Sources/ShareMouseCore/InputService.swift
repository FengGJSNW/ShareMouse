import Foundation

@MainActor public final class InputService {
    public var remoteTargetPlatform: String? {
        guard let screen = active, screen.peerID != id else { return nil };
        return platforms[screen.peerID]
    }
    public var screenCrossingEnabled = true
    public var pointerSensitivity: ((String) -> Double)?
    public var scrollInversion: ((String) -> (horizontal: Bool, vertical: Bool))?
    public var horizontalScrollAngle: ((String) -> Double)?
    private var fnEnabled = true, functionKeysEnabled = true
    private var sourceOptions: [String: (fn: Bool, functions: Bool)] = [:]
    private var physicalFunctionSlots: [String: String] = [:]
    private var remoteFunctionSlots: [String: [String: String]] = [:]
    public func configureKeyboard(fn: Bool, functions: Bool) {
        guard fnEnabled != fn || functionKeysEnabled != functions else { return }
        fnEnabled = fn;
        functionKeysEnabled = functions
        heldSnapshots = [:];
        sendHeld()
    }
    private func gain(_ peer: String) -> Double {
        guard peer != id, let gain = pointerSensitivity?(peer), gain.isFinite else { return 1 }
        return max(0.1, min(4, gain))
    }
    private let id: String
    private let platform: String
    private let manager: SessionManager
    private let inject: (CapturedInput, ScreenGeometry?, Double, Double) throws -> Void
    private let restrict: (Bool, Bool) -> Void
    private let status: (String) -> Void
    private let event: (String) -> Void
    private var group: SharedGroup?
    private var online: Set<String> = []
    private var inputPeers: Set<String> = []
    public var relativePointerCaptured: (() -> Bool)?
    private var relativePeers: Set<String> = []
    private var functionPeers: Set<String> = []
    private var relativePeer: String?
    private var relativeEpoch: UInt64 = 0
    private var relativeX = 0.0, relativeY = 0.0
    private var localRelative = false
    private var relativeReported: String?
    private var relativeReportAt = ProcessInfo.processInfo.systemUptime
    private var relativeReceived: [String: (epoch: UInt64, x: Double, y: Double)] = [:]
    private static func motionType(_ type: String) -> Bool { ["move", "relative-move"].contains(type) }
    private func reportRelativeMode() {
        guard enabled, let screen = active, let pointer, screen.peerID == id, pointer.ownerPeerID != id,
            relativePeers.contains(pointer.ownerPeerID)
        else {
            if localRelative { try? inject(CapturedInput("relativeEnd"), active, 0, 0) };
            localRelative = false;
            relativeReported = nil;
            return
        }
        let captured = relativePointerCaptured?() ?? false
        let key = "\(pointer.ownerPeerID)|\(pointer.epoch)|\(screen.id)|\(captured)"
        let now = ProcessInfo.processInfo.systemUptime
        guard key != relativeReported || now - relativeReportAt >= 2 else { return }
        relativeReported = key;
        relativeReportAt = now
        if localRelative != captured {
            try? inject(CapturedInput(captured ? "relativeBegin" : "relativeEnd"), screen, 0, 0)
        }
        localRelative = captured
        if captured { renderTarget = nil }
        var value = packet("mouse-mode", pointer.ownerPeerID);
        value.command = captured ? "relative-on" : "relative-off"
        queue(pointer.ownerPeerID, value)
    }
    private func receiveMouseMode(_ peer: String, _ value: InputPacket) {
        guard enabled, relativePeers.contains(peer), let screen = active, screen.peerID == peer,
            pointer?.ownerPeerID == id, value.targetPeerID == id, value.targetScreenID == screen.id,
            value.pointer?.epoch == pointer?.epoch, ["relative-on", "relative-off"].contains(value.command ?? "")
        else { return }
        if value.command == "relative-off" {
            if relativePeer != nil { event("InputRelativeModeEnded") };
            relativePeer = nil;
            return
        }
        guard relativePeer != peer || relativeEpoch != pointer?.epoch else { return }
        relativePeer = peer;
        relativeEpoch = pointer?.epoch ?? 0;
        relativeX = 0;
        relativeY = 0
        motion.removeValue(forKey: peer);
        pending.removeAll { $0.peer == peer && Self.motionType($0.packet.type) }
        var start = packet("relative-start", peer);
        start.deltaX = 0;
        start.deltaY = 0;
        queue(peer, start)
        event("InputRelativeModeStarted targetPeerId=\(peer)")
    }
    private func applyRelative(_ peer: String, _ value: InputPacket, _ screen: ScreenGeometry) {
        guard relativePeers.contains(peer), screen.peerID == id, value.deltaX.isFinite, value.deltaY.isFinite,
            abs(value.deltaX) <= 1e9, abs(value.deltaY) <= 1e9, let epoch = value.pointer?.epoch
        else { return }
        if value.type == "relative-start" {
            relativeReceived[peer] = (epoch, value.deltaX, value.deltaY);
            renderTarget = nil;
            try? inject(CapturedInput("relativeReset"), screen, 0, 0);
            return
        }
        guard localRelative, let old = relativeReceived[peer], old.epoch == epoch else { return }
        relativeReceived[peer] = (epoch, value.deltaX, value.deltaY)
        let dx = value.deltaX - old.x, dy = value.deltaY - old.y
        guard abs(dx) <= 10000, abs(dy) <= 10000 else { return }
        do { try inject(CapturedInput("relativeMove", deltaX: dx, deltaY: dy), screen, 0, 0) } catch { pause() }
    }
    private var compactPeers: Set<String> = []
    private var scrollPeers: Set<String> = []
    private var contextPeers: Set<String> = [], scrollFlowPeers: Set<String> = []
    private var scroll: [String: InputPacket] = [:]
    private var scrollTask: Task<Void, Never>?
    public var resumeRequested: (() -> Void)?
    private var blePeers: Set<String> = []
    private var bleCompactPeers: Set<String> = []
    private var bleWindows: [String: BLEMotionWindow] = [:]
    private var bleSentAt: [String: [UInt64: Double]] = [:]
    private var bleAckMilliseconds: [Double] = []
    private var bleReportAt = ProcessInfo.processInfo.systemUptime
    private var outstanding: [String: Set<UInt64>] = [:]
    private var motionProgress: [String: ContinuousClock.Instant] = [:]
    private var deliveryChecks: Set<String> = []
    private var slowDeliveryReported: [String: Double] = [:]
    private var acknowledgements: [String: (sequence: UInt64, transport: SecureNetwork)] = [:]
    private var lastAckAt = ProcessInfo.processInfo.systemUptime
    private var renderFrom: PointerState?
    private var rendered: PointerState?
    private var renderAt: ContinuousClock.Instant = .now
    private var renderTarget: PointerState?
    private var highRateTimer: Task<Void, Never>?
    private var interactiveActivity: NSObjectProtocol?
    private var receiveDelayReported = 0.0
    public private(set) var captureRate: Int = 0
    public private(set) var sendRate: Int = 0
    private var capturedMoves = 0
    private var sentMoves = 0
    private var lastRemoteMotion: ContinuousClock.Instant?
    private var sessionIDs: [String: String] = [:]
    private var arrivals: [String] = []
    private var priority: [String] = []
    private var priorityRecipients: Set<String> = []
    public private(set) var pointer: PointerState?
    public private(set) var enabled = false
    private var physicalKeys: Set<String> = []
    private var physicalButtons: Set<Int> = []
    private var heldSnapshots: [String: (screen: String, epoch: UInt64, keys: Set<String>, buttons: Set<Int>)] = [:]
    private var keys: [String: Set<String>] = [:]
    private var originalKeys: [String: [String: String]] = [:]
    private var commandKeys: Set<String> = []
    private var platforms: [String: String] = [:]
    public var commandHandler: ((String, String, String?) async throws -> Bool)?
    public var targetKeyHandler: ((CapturedInput) -> Bool)?
    public var clipboardEntryID: (() -> String?)?
    public var sourceKeyTransform: ((String, String) -> String)?
    public var localClipboardCommand: (() -> Void)?
    private var config: KeyboardConfig? { group?.configs.first { $0.id == group?.currentConfigID } }
    private var buttons: [String: Set<Int>] = [:]
    private var received: [String: UInt64] = [:]
    // Keep wire context separate from the local, mutable ownership state.
    private var receivedContexts: [String: (pointer: PointerState, sequence: UInt64)] = [:]
    private var deliveryGeneration = 0
    private var heard: [String: ContinuousClock.Instant] = [:]
    private var pending: [(peer: String, packet: InputPacket, at: Double)] = []
    private var sequence: UInt64 = 0
    private var noiseX: Double = 0
    private var noiseY: Double = 0
    private var noiseAt: ContinuousClock.Instant = .now
    private var motion: [String: InputPacket] = [:]
    private var motionTask: Task<Void, Never>?
    private var sending = false
    private var stopped = false
    private var timer: Task<Void, Never>?
    private var tickCount = 0
    private var stateReportAt = 0.0
    private var rejectionReportAt = 0.0
    private var generation = 0
    private var capabilityUpdate: Task<Void, Never>?
    private var active: ScreenGeometry? { group?.layout.first { $0.id == pointer?.screenID } }
    private var usable: [ScreenGeometry] {
        group?.layout.filter { online.contains($0.peerID) && ($0.peerID == id || inputPeers.contains($0.peerID)) } ?? []
    }
    public init(
        id: String, platform: String, manager: SessionManager,
        inject: @escaping (CapturedInput, ScreenGeometry?, Double, Double) throws -> Void,
        restrict: @escaping (Bool, Bool) -> Void, status: @escaping (String) -> Void,
        event: @escaping (String) -> Void = { _ in }
    ) {
        self.id = id;
        self.platform = platform;
        self.manager = manager
        self.inject = inject;
        self.restrict = restrict;
        self.status = status;
        self.event = event
    }
    public func start() async {
        guard timer == nil, !stopped else { return }
        await manager.receiveWithTransport(channel: "input") { [weak self] peer, bytes, transport in
            // Preserve FIFO delivery without holding the TLS reader behind the desktop run loop.
            let queued = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - queued > 0.008, now - self.receiveDelayReported > 2 {
                    self.receiveDelayReported = now;
                    self.event("InputReceiveQueued durationMs=\(Int((now-queued)*1000))")
                }
                self.receive(peer, bytes, transport: transport)
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100));
                guard let self else { return };
                self.tick()
            }
        }
    }
    public func update(_ value: SharedGroup?, online peers: [String], sessions: [SessionInfo]) {
        let oldBLE = blePeers;
        let oldInput = inputPeers
        let old = online;
        online = Set(peers);
        platforms = Dictionary(uniqueKeysWithValues: sessions.map { ($0.peerID, $0.remotePlatform) })
        blePeers = Set(
            sessions.filter {
                $0.capabilities.contains("ble")
                    && (manager.bluetoothInputOnly
                        || !$0.capabilities.contains("tcp") && !$0.capabilities.contains("quic"))
            }.map(\.peerID))
        bleCompactPeers = Set(sessions.filter { $0.capabilities.contains("ble-input-v2") }.map(\.peerID)).intersection(
            blePeers)
        relativePeers = Set(sessions.filter { $0.capabilities.contains("relative-pointer-v1") }.map(\.peerID))
        functionPeers = Set(sessions.filter { $0.capabilities.contains("input-function-keys-v1") }.map(\.peerID))
        compactPeers = Set(sessions.filter { $0.capabilities.contains("compact-input") }.map(\.peerID))
        contextPeers = Set(sessions.filter { $0.capabilities.contains("compact-input-v3") }.map(\.peerID))
        scrollFlowPeers = Set(sessions.filter { $0.capabilities.contains("scroll-flow-v1") }.map(\.peerID))
        scrollPeers = Set(sessions.filter { $0.capabilities.contains("compact-scroll-v1") }.map(\.peerID))
        inputPeers = Set(sessions.filter { $0.capabilities.contains("input") }.map(\.peerID))
        for session in sessions {
            let inputSession = session.sessionID + "|" + (session.remoteInstanceID ?? "legacy")
            if let previous = sessionIDs[session.peerID], previous != inputSession {
                bleSentAt.removeValue(forKey: session.peerID);
                releasePeer(session.peerID);
                outstanding.removeValue(forKey: session.peerID);
                motionProgress.removeValue(forKey: session.peerID);
                slowDeliveryReported.removeValue(forKey: session.peerID);
                received.removeValue(forKey: session.peerID);
                receivedContexts.removeValue(forKey: session.peerID);
                heard.removeValue(forKey: session.peerID)
                if enabled, pointer?.ownerPeerID == session.peerID || active?.peerID == session.peerID {
                    recover("对端已重新连接，输入状态已恢复")
                }
                event("InputPeerRestarted peerId=\(session.peerID)")
            }
            sessionIDs[session.peerID] = inputSession
        }
        for peer in old.subtracting(online) {
            bleSentAt.removeValue(forKey: peer);
            releasePeer(peer);
            outstanding.removeValue(forKey: peer);
            motionProgress.removeValue(forKey: peer);
            slowDeliveryReported.removeValue(forKey: peer);
            received.removeValue(forKey: peer);
            receivedContexts.removeValue(forKey: peer);
            heard.removeValue(forKey: peer);
            arrivals.removeAll { $0 == peer }
        }
        for session in sessions where !arrivals.contains(session.peerID) { arrivals.append(session.peerID) }
        if !arrivals.contains(id) { arrivals.insert(id, at: 0) }
        let oldConfig = config
        let previousGroup = group;
        let changed = group?.id != value?.id;
        group = value
        if !changed, var current = pointer,
            let before = previousGroup?.layout.first(where: { $0.id == current.screenID }),
            let after = group?.layout.first(where: { $0.id == current.screenID }),
            before.x != after.x || before.y != after.y || before.scale != after.scale || before.scaleX != after.scaleX
                || before.scaleY != after.scaleY || before.rotation != after.rotation
                || before.pixelWidth != after.pixelWidth || before.pixelHeight != after.pixelHeight
        {
            if before.pixelWidth != after.pixelWidth || before.pixelHeight != after.pixelHeight {
                releaseAll();
                physicalKeys = [];
                physicalFunctionSlots = [:];
                physicalButtons = []
            }
            current.x = after.x + (current.x - before.x) / before.width * after.width
            current.y = after.y + (current.y - before.y) / before.height * after.height;
            pointer = current
            if enabled, current.ownerPeerID == id { broadcast("control") };
            moveLocal()
        }
        if oldConfig != config {
            releaseAll();
            sendHeld()
        }
        if changed {
            pause();
            pointer = nil;
            received = [:];
            receivedContexts = [:]
        }
        guard let group, online.count > 1 else {
            pause();
            return
        }
        if group.leaderID == id {
            let next = (priority + arrivals).filter { online.contains($0) }.reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            if changed || priority != next || priorityRecipients != inputPeers {
                priority = next;
                priorityRecipients = inputPeers;
                broadcast("priority")
            }
        }
        if enabled, let pointer, !usable.contains(where: { $0.id == pointer.screenID }) {
            releaseAll();
            physicalKeys = [];
            physicalFunctionSlots = [:];
            physicalButtons = []
            guard
                let safe = usable.first(where: { $0.peerID == id && $0.primary }) ?? usable.first(where: { $0.primary })
                    ?? usable.first
            else {
                pause();
                return
            }
            self.pointer = PointerRouter.center(safe, owner: id, epoch: pointer.epoch + 1)
            broadcast("control");
            moveLocal()
        }
        for peer in oldInput.subtracting(inputPeers) where manager.bluetoothInputOnly {
            releasePeer(peer);
            outstanding.removeValue(forKey: peer);
            bleSentAt.removeValue(forKey: peer)
            if pointer?.ownerPeerID == peer { recover("蓝牙输入链路已断开，已释放本机控制", announce: false) }
        }
        if oldBLE != blePeers { refreshInputRoute() }
        if enabled {
            status(
                inputPeers.isEmpty
                    ? "等待对端输入就绪 · 本机输入可用"
                    : "键鼠共享已启用 · 当前输入："
                        + (active.map { $0.peerID == id ? "本机" : blePeers.contains($0.peerID) ? "蓝牙" : "Wi-Fi／网络" }
                            ?? "本机"))
        }
        restrictCursor()
    }
    private func discardContinuousDelivery() {
        deliveryGeneration += 1
        motion = [:];
        scroll = [:];
        motionTask?.cancel();
        motionTask = nil;
        scrollTask?.cancel();
        scrollTask = nil
        pending.removeAll { ["move", "relative-move", "scroll"].contains($0.packet.type) };
        outstanding = [:];
        bleSentAt = [:];
        bleWindows = [:];
        motionProgress = [:];
        slowDeliveryReported = [:]
    }
    public func refreshInputRoute() {
        discardContinuousDelivery();
        heldSnapshots = [:]
        if enabled, pointer?.ownerPeerID == id {
            broadcast("control");
            sendHeld()
        }
    }
    public func enable(preservingLocalCursor position: CapturedInput? = nil) async throws {
        generation += 1;
        let round = generation
        guard group != nil, online.count > 1, let screen = usable.first(where: { $0.peerID == id && $0.primary }) else {
            throw GroupError.offline
        }
        // A paused interval must not count against the next input session's watchdog.
        heard = [:]
        startHighRateTimer()
        let epoch = (pointer?.epoch ?? 0) + 1
        // Independent MCP never moves the user's cursor, including when normal sharing resumes.
        let preserved = position.flatMap { value -> PointerState? in
            guard value.x.isFinite, value.y.isFinite, (0...1).contains(value.x), (0...1).contains(value.y),
                let local = usable.first(where: { $0.peerID == id && $0.id == value.screenID })
            else { return nil }
            let point = local.logical(value.x, value.y)
            return PointerState(
                screenID: local.id, x: local.x + point.0 * local.width, y: local.y + point.1 * local.height,
                ownerPeerID: id, epoch: epoch)
        }
        enabled = true;
        pointer = preserved ?? PointerRouter.center(screen, owner: id, epoch: epoch);
        noiseX = 0;
        noiseY = 0
        if preserved != nil {
            renderTarget = nil;
            rendered = pointer
        } else {
            moveLocal()
        }
        restrictCursor();
        guard enabled else { return }
        await changeCapability(true).value;
        guard round == generation else { return }
        if pointer?.ownerPeerID == id { broadcast("control") };
        event(
            "InputMode bluetoothOnly=\(manager.bluetoothInputOnly) bleWindow=adaptive-max16 maxPendingAgeMs=80 coalesceMs=2 render=immediate"
        );
        event("InputEnabled targetPeerId=\(active?.peerID ?? "none") epoch=\(pointer?.epoch ?? 0)");
        status(
            manager.bluetoothInputOnly && inputPeers.isEmpty
                ? "等待蓝牙输入链路 · 本机输入可用" : "键鼠共享已启用 · Ctrl+Option+Shift+Esc 暂停／恢复")
    }
    private func changeCapability(_ enabled: Bool) -> Task<Void, Never> {
        let previous = capabilityUpdate
        let task = Task {
            await previous?.value
            // Codec support remains available while sharing is paused (also for MCP).
            // The input capability alone controls whether this peer can be targeted.
            var values = [
                "input-function-slots-v1": true, "input-function-keys-v1": true, "ble-input-v2": true,
                "compact-input": true, "compact-scroll-v1": true, "compact-input-v3": true, "scroll-flow-v1": true,
                "relative-pointer-v1": true, "input-resume": true, "input": enabled, "command-clipboard": enabled,
                "scroll-2d": enabled, "input-committed-text": enabled, "command-undo-redo": enabled,
            ]
            if platform == "macos" { values["scroll-momentum-phase"] = enabled }
            await manager.setCapabilities(values)
        }
        capabilityUpdate = task;
        return task
    }
    public func pause(caller: String = #function) {
        if let activity = interactiveActivity {
            ProcessInfo.processInfo.endActivity(activity);
            interactiveActivity = nil
        }
        if localRelative { try? inject(CapturedInput("relativeEnd"), active, 0, 0) };
        relativePeer = nil;
        relativeReceived = [:];
        relativeReported = nil;
        localRelative = false
        if enabled { event("InputPaused caller=\(caller)") }
        generation += 1;
        bleWindows = [:];
        bleSentAt = [:];
        outstanding = [:];
        motionProgress = [:];
        slowDeliveryReported = [:];
        acknowledgements = [:];
        renderTarget = nil;
        rendered = nil;
        highRateTimer?.cancel();
        highRateTimer = nil;
        motionTask?.cancel();
        motionTask = nil;
        motion = [:];
        scroll = [:];
        scrollTask?.cancel();
        scrollTask = nil;
        pending = [];
        if enabled { broadcast("release") }
        _ = changeCapability(false)
        enabled = false;
        commandKeys = [];
        physicalKeys = [];
        physicalFunctionSlots = [:];
        physicalButtons = [];
        releaseAll();
        restrict(false, false)
    }
    private func claim(_ input: CapturedInput) {
        if pointer == nil, let screen = usable.first(where: { $0.id == input.screenID }) {
            let position = screen.logical(input.x, input.y)
            pointer = PointerState(
                screenID: screen.id, x: screen.x + position.0 * screen.width, y: screen.y + position.1 * screen.height,
                ownerPeerID: id, epoch: 0)
        }
        guard var current = pointer else { return }
        discardContinuousDelivery();
        current.ownerPeerID = id;
        current.epoch += 1;
        pointer = current;
        noiseX = 0;
        noiseY = 0;
        broadcast("control")
    }
    public var remoteScreenID: String? { enabled && active?.peerID != id ? active?.id : nil }
    public func sourceCommand(_ key: String, held: Set<String>) -> Bool {
        guard enabled, let screen = active, screen.peerID != id,
            let command = KeyboardMapping.command(
                sourceKey(key, screen.peerID), held: Set(held.map { sourceKey($0, screen.peerID) }), from: platform,
                to: platforms[screen.peerID, default: "unknown"], config: config, fnEnabled: fnEnabled,
                functionKeysEnabled: functionKeysEnabled)
        else { return false }
        perform(command, target: screen.peerID);
        return true
    }
    public func beginSourceIME() -> Bool {
        guard remoteScreenID != nil else { return false };
        physicalKeys = [];
        physicalFunctionSlots = [:];
        commandKeys = [];
        sendHeld();
        return true
    }
    public func commitText(_ text: String, screenID: String) -> Bool {
        guard enabled, let screen = active, screen.id == screenID, screen.peerID != id else { return false }
        var part = ""
        for scalar in text.unicodeScalars {
            let value = String(scalar);
            if part.utf8.count + value.utf8.count > 4096 {
                var message = packet("text", screen.peerID);
                message.text = part;
                queue(screen.peerID, message);
                part = ""
            };
            part += value
        }
        if !part.isEmpty {
            var message = packet("text", screen.peerID);
            message.text = part;
            queue(screen.peerID, message)
        };
        return true
    }
    public func capture(_ input: CapturedInput) -> Bool {
        if input.type == "move", localRelative, pointer?.ownerPeerID != id, input.hardwareMotion == false {
            return false
        }
        guard enabled, group != nil, var current = pointer, var screen = active else { return false }
        if let key = input.key, screen.peerID != id, !functionPeers.contains(screen.peerID),
            KeyboardMapping.functionKeys.contains(key) || (Int(key.dropFirst()) ?? 0) > 12 && key.hasPrefix("F")
        {
            return false
        }
        if (input.type == "keyDown" || input.type == "keyUp"), let key = input.key {
            if input.type == "keyDown" {
                physicalKeys.insert(key);
                if let slot = input.functionSlot, KeyboardMapping.windowsFunctions[slot] != nil {
                    physicalFunctionSlots[key] = slot
                }
            } else {
                physicalKeys.remove(key);
                physicalFunctionSlots.removeValue(forKey: key);
                if active?.peerID == id, keys[id]?.contains(key) == true { try? setKey(id, key, false) }
            }
            if input.type == "keyDown", key == "Escape", has("Control"), has("Alt"), has("Shift") {
                pause();
                status("已紧急恢复本机输入");
                return true
            }
        }
        if let key = input.key, input.type == "keyUp", commandKeys.remove(key) != nil { return true }
        if let key = input.key, input.type == "keyDown", !commandKeys.contains(key),
            let command = KeyboardMapping.command(
                sourceKey(key, screen.peerID), held: Set(physicalKeys.map { sourceKey($0, screen.peerID) }),
                from: platform, to: screen.peerID == id ? platform : platforms[screen.peerID, default: "unknown"],
                config: config, fnEnabled: screen.peerID == id || fnEnabled, functionKeysEnabled: functionKeysEnabled)
        {
            if screen.peerID == id, ["copy", "cut", "paste", "undo", "redo"].contains(command) {
                if command == "copy" || command == "cut" { localClipboardCommand?() }
                return false
            }
            commandKeys.insert(key);
            perform(command, target: screen.peerID);
            return true
        }
        if let key = input.key, commandKeys.contains(key) { return true }
        if input.type == "command", let command = input.command {
            perform(command, target: screen.peerID);
            return true
        }
        if input.type == "move", let screen = active, relativePeer == screen.peerID, pointer?.ownerPeerID == id,
            screen.peerID != id
        {
            capturedMoves += 1;
            lastRemoteMotion = .now
            relativeX += input.deltaX * gain(screen.peerID);
            relativeY += input.deltaY * gain(screen.peerID)
            var value = packet("relative-move", screen.peerID);
            value.deltaX = relativeX;
            value.deltaY = relativeY
            queue(screen.peerID, value);
            restrictCursor();
            return true
        }
        if input.type == "move" {
            capturedMoves += 1
            if current.ownerPeerID != id {
                if noiseAt.duration(to: .now) > .milliseconds(200) {
                    noiseX = 0;
                    noiseY = 0
                };
                noiseAt = .now
                noiseX += input.deltaX;
                noiseY += input.deltaY
                if hypot(noiseX, noiseY) < 6 { return true }
                claim(input);
                current = pointer!
            }
            let previous = current.screenID
            let local = screen.peerID == id && input.screenID == screen.id
            if local {
                let position = screen.logical(min(1, max(0, input.x)), min(1, max(0, input.y)))
                current.x = screen.x + position.0 * screen.width
                current.y = screen.y + position.1 * screen.height
            }
            let edgeX =
                input.x <= 0 && input.deltaX < 0 || input.x >= 1 - 1 / Double(screen.pixelWidth) && input.deltaX > 0
            let edgeY =
                input.y <= 0 && input.deltaY < 0 || input.y >= 1 - 1 / Double(screen.pixelHeight) && input.deltaY > 0
            let delta =
                local
                ? screen.delta(edgeX ? input.deltaX : 0, edgeY ? input.deltaY : 0)
                : (input.deltaX * (screen.scaleX ?? screen.scale), input.deltaY * (screen.scaleY ?? screen.scale))
            pointer = PointerRouter.move(
                current, screens: screenCrossingEnabled ? usable : usable.filter { $0.peerID == screen.peerID },
                dx: delta.0 * gain(screen.peerID), dy: delta.1 * gain(screen.peerID))
            screen = active!
            if previous != pointer?.screenID {
                let crossingBegan = ProcessInfo.processInfo.systemUptime
                // Crossing terminates a local selection/drag before the original up can be intercepted.
                if local {
                    for button in physicalButtons { try? inject(CapturedInput("buttonUp", button: button), nil, 0, 0) }
                    for key in physicalKeys { try? inject(CapturedInput("keyUp", key: key), nil, 0, 0) }
                }
                physicalButtons = [];
                releaseAll();
                broadcast("control");
                moveLocal();
                sendHeld()
                if screen.peerID == id {
                    for key in physicalKeys.subtracting(commandKeys) { try? setKey(id, key, true) }
                    event(
                        "InputLocalHandoff durationMs=\(Int((ProcessInfo.processInfo.systemUptime-crossingBegan)*1000))"
                    )
                }
            } else if screen.peerID != id {
                lastRemoteMotion = .now;
                emit("move", screen.peerID)
            }
            restrictCursor();
            return !local || previous != pointer?.screenID
        }
        if (input.type == "buttonDown" || input.type == "scroll"), current.ownerPeerID != id { claim(input) }
        if input.type == "buttonDown" { physicalButtons.insert(input.button) }
        if input.type == "buttonUp" { physicalButtons.remove(input.button) }
        if screen.peerID == id { return false }
        var message = packet(input.type, screen.peerID);
        message.functionSlot = input.functionSlot;
        message.key = input.key.map { sourceKey($0, screen.peerID) };
        message.button = input.button
        if input.type == "scroll" { lastRemoteMotion = .now }
        // Apply the source computer's target preference once, before scroll coalescing/credit.
        let inversion = input.type == "scroll" ? scrollInversion?(screen.peerID) : nil
        let dx =
            input.type == "scroll"
            ? HorizontalScrollFilter.apply(
                input.deltaX, dy: input.deltaY, angle: horizontalScrollAngle?(screen.peerID) ?? 30) : input.deltaX
        message.deltaX = inversion?.horizontal == true ? -dx : dx
        message.deltaY = inversion?.vertical == true ? -input.deltaY : input.deltaY
        message.scrollPhase = input.scrollPhase;
        message.momentumPhase = input.momentumPhase;
        message.preciseScroll = input.preciseScroll;
        queue(screen.peerID, message);
        return true
    }
    public func requestPeerResume() {
        guard enabled, group != nil else { return }
        for peer in online where peer != id { queue(peer, packet("resume", peer)) }
    }
    private static func continuousInput(_ packet: InputPacket) -> Bool {
        motionType(packet.type)
            || packet.type == "scroll" && [0, 2].contains(packet.scrollPhase ?? 0)
                && [0, 2].contains(packet.momentumPhase ?? 0)
    }
    private static func mergeableScroll(_ a: InputPacket, _ b: InputPacket) -> Bool {
        a.type == "scroll" && b.type == "scroll" && a.targetScreenID == b.targetScreenID
            && a.pointer?.epoch == b.pointer?.epoch && (a.scrollPhase ?? 0) == (b.scrollPhase ?? 0)
            && [0, 2].contains(b.scrollPhase ?? 0) && (a.momentumPhase ?? 0) == (b.momentumPhase ?? 0)
            && [0, 2].contains(b.momentumPhase ?? 0) && (a.preciseScroll ?? false) == (b.preciseScroll ?? false)
    }
    private static func mergedScroll(_ a: InputPacket, _ b: InputPacket) -> InputPacket {
        var next = b;
        next.deltaX = max(-10000, min(10000, a.deltaX + b.deltaX));
        next.deltaY = max(-10000, min(10000, a.deltaY + b.deltaY));
        return next
    }
    private func has(_ prefix: String) -> Bool { physicalKeys.contains { $0.hasPrefix(prefix) } }
    private func sourceKey(_ key: String, _ target: String) -> String {
        sourceKeyTransform?(key, target == id ? platform : platforms[target, default: "unknown"]) ?? key
    }
    private func packet(_ type: String, _ target: String) -> InputPacket {
        sequence += 1
        var packet = InputPacket(type: type, groupID: group!.id, sourcePeerID: id, targetPeerID: target)
        if ["keyDown", "keyUp", "held"].contains(type) {
            packet.fnEnabled = fnEnabled;
            packet.functionKeysEnabled = functionKeysEnabled
        }
        packet.sequence = sequence;
        packet.pointer = pointer;
        packet.targetScreenID = pointer?.screenID;
        packet.sourcePlatform = platform
        return packet
    }
    private func emit(_ type: String, _ peer: String) { queue(peer, packet(type, peer)) }
    private func broadcast(_ type: String) {
        guard group != nil else { return }
        for peer in online where peer != id && (!["pointer", "priority"].contains(type) || inputPeers.contains(peer)) {
            var message = packet(type, active?.peerID ?? id);
            message.priority = priority;
            queue(peer, message)
        }
    }
    private func queue(_ peer: String, _ packet: InputPacket) {
        guard !stopped else { return }
        if packet.type == "scroll" {
            guard packet.deltaX.isFinite, packet.deltaY.isFinite else { return }
            var next = packet;
            next.deltaX = max(-10000, min(10000, next.deltaX));
            next.deltaY = max(-10000, min(10000, next.deltaY))
            if let previous = scroll[peer], Self.mergeableScroll(previous, next) {
                next = Self.mergedScroll(previous, next)
            } else if scroll[peer] != nil {
                flushMotion()
            }
            scroll[peer] = next
            if ![0, 2].contains(next.scrollPhase ?? 0) || ![0, 2].contains(next.momentumPhase ?? 0) {
                flushMotion();
                return
            }
            if scrollTask == nil {
                scrollTask = Task {
                    try? await Task.sleep(for: .milliseconds(8));
                    guard !Task.isCancelled else { return };
                    self.scrollTask = nil;
                    self.flushMotion()
                }
            }
            return
        }
        if Self.motionType(packet.type) {
            motion[peer] = packet
            if motionTask == nil {
                let delay = 2;
                motionTask = Task {
                    try? await Task.sleep(for: .milliseconds(delay));
                    guard !Task.isCancelled else { return };
                    self.motionTask = nil;
                    self.flushMotion()
                }
            }
            return
        }
        if ["control", "release"].contains(packet.type) {
            scroll.removeValue(forKey: peer);
            motion.removeValue(forKey: peer);
            pending.removeAll {
                $0.peer == peer
                    && (Self.motionType($0.packet.type)
                        || $0.packet.type == "scroll" && [0, 2].contains($0.packet.scrollPhase ?? 0)
                            && [0, 2].contains($0.packet.momentumPhase ?? 0))
            }
        }
        flushMotion()
        enqueue(peer, packet)
    }
    private func flushMotion() {
        let latest = (Array(motion) + Array(scroll)).sorted { $0.value.sequence < $1.value.sequence };
        motion = [:];
        scroll = [:];
        scrollTask?.cancel();
        scrollTask = nil
        for (peer, packet) in latest { enqueue(peer, packet) }
    }
    private func enqueue(_ peer: String, _ packet: InputPacket) {
        let now = ProcessInfo.processInfo.systemUptime
        var next = packet
        if Self.continuousInput(packet) {
            // Interleaved moves cannot defeat scroll coalescing or bypass flow control.
            for index in pending.indices.reversed() {
                let old = pending[index]
                if old.peer != peer || !Self.continuousInput(old.packet) { break }
                if Self.mergeableScroll(old.packet, packet) {
                    next = Self.mergedScroll(old.packet, packet);
                    pending.remove(at: index);
                    break
                }
                if Self.motionType(packet.type), old.packet.type == packet.type,
                    old.packet.targetScreenID == packet.targetScreenID,
                    old.packet.pointer?.epoch == packet.pointer?.epoch
                {
                    pending.remove(at: index);
                    break
                }
            }
        }
        if pending.count >= 256 {
            event("InputQueueCongested targetPeerId=\(peer)");
            pending = [];
            recover("输入队列拥塞，已恢复本机控制并保持共享");
            return
        }
        pending.append((peer, next, now))
        if !sending {
            sending = true;
            Task { await self.drain() }
        }
    }
    private func motionWindowFull(_ peer: String) -> Bool {
        let count = outstanding[peer, default: []].count
        guard blePeers.contains(peer) else { return count >= 8 }
        let oldest = bleSentAt[peer]?.values.min() ?? ProcessInfo.processInfo.systemUptime
        return !bleWindows[peer, default: BLEMotionWindow()].allows(
            count: count, targetRate: platforms[peer] == "windows" ? 240 : 60,
            oldestAge: ProcessInfo.processInfo.systemUptime - oldest)
    }
    private func drain() async {
        defer { sending = false }
        while !pending.isEmpty, !stopped {
            var item = pending[0]
            if (Self.motionType(item.packet.type)
                || item.packet.type == "scroll" && scrollFlowPeers.contains(item.peer)),
                compactPeers.contains(item.peer), motionWindowFull(item.peer)
            {
                if Self.continuousInput(item.packet),
                    !pending.dropFirst().contains(where: { !Self.continuousInput($0.packet) })
                {
                    return
                }
                // A click carries its exact latest position even when the movement window is full.
                if item.packet.type != "scroll" { item.packet.type = "pointer" }
            }
            pending.removeFirst()
            let round = (generation, deliveryGeneration)
            do {
                let compact =
                    compactPeers.contains(item.peer)
                    ? MotionCodec.encode(
                        item.packet, layout: group?.layout ?? [], extended: bleCompactPeers.contains(item.peer),
                        compactScroll: scrollPeers.contains(item.peer), compactContext: contextPeers.contains(item.peer)
                    ) : nil
                if Self.motionType(item.packet.type) { sentMoves += 1 };
                if Self.motionType(item.packet.type)
                    || item.packet.type == "scroll" && scrollFlowPeers.contains(item.peer)
                {
                    if compact != nil {
                        if outstanding[item.peer, default: []].isEmpty { motionProgress[item.peer] = .now };
                        outstanding[item.peer, default: []].insert(item.packet.sequence)
                    }
                }
                if (Self.motionType(item.packet.type)
                    || item.packet.type == "scroll" && scrollFlowPeers.contains(item.peer)), compact != nil,
                    blePeers.contains(item.peer)
                {
                    bleSentAt[item.peer, default: [:]][item.packet.sequence] = ProcessInfo.processInfo.systemUptime
                }
                let tracked =
                    compact != nil
                    && (Self.motionType(item.packet.type)
                        || item.packet.type == "scroll" && scrollFlowPeers.contains(item.peer))
                try await manager.sendInput(
                    peerID: item.peer, payload: compact ?? JSONEncoder().encode(item.packet),
                    acknowledgedSequence: tracked ? item.packet.sequence : nil)
            } catch {
                if round == (generation, deliveryGeneration) {
                    outstanding.removeValue(forKey: item.peer);
                    releasePeer(item.peer);
                    if active?.peerID == item.peer { recover("输入目标暂不可达，已恢复本机控制并保持共享") }
                }
            }
        }
    }
    private func receive(_ peer: String, _ bytes: Data, transport: SecureNetwork) {
        guard !stopped, let group, online.contains(peer),
            let message = MotionCodec.decode(
                bytes, group: group, source: peer, target: id, context: receivedContexts[peer]?.pointer)
                ?? (try? JSONDecoder().decode(InputPacket.self, from: bytes)), message.sourcePeerID == peer,
            message.groupID == group.id, (message.keys?.count ?? 0) <= 128, (message.buttons?.count ?? 0) <= 8
        else { return }
        heard[peer] = .now
        if message.type == "resume", message.targetPeerID == id, message.sequence > received[peer, default: 0] {
            received[peer] = message.sequence;
            resumeRequested?();
            event("InputResumeRequested peerId=\(peer)");
            return
        }
        if message.type == "motionAck", let ack = message.acknowledgedSequence {
            Task { await manager.inputAcknowledged(peer, sequence: ack, transport: transport) }
            let now = ProcessInfo.processInfo.systemUptime
            var tail = 0.0
            for (sequence, started) in bleSentAt[peer, default: [:]] where sequence <= ack {
                if transport.kind == "ble" {
                    bleWindows[peer, default: BLEMotionWindow()].acknowledged(seconds: now - started);
                    tail = max(tail, now - started)
                    if bleAckMilliseconds.count < 2048 { bleAckMilliseconds.append((now - started) * 1000) }
                }
                bleSentAt[peer]?.removeValue(forKey: sequence)
            }
            if tail > 0.06 { Task { await manager.yieldBulkForInput(peer) } }
            let previous = outstanding[peer, default: []]
            outstanding[peer] = previous.filter { $0 > ack }
            if outstanding[peer]?.count != previous.count {
                motionProgress[peer] = .now
                if slowDeliveryReported.removeValue(forKey: peer) != nil {
                    event("InputDeliveryResumed peerId=\(peer)");
                    status("对端输入已恢复，键鼠共享继续运行")
                }
            }
            if !sending, !pending.isEmpty {
                sending = true;
                Task { await self.drain() }
            };
            return
        }
        if (Self.motionType(message.type) || message.type == "scroll" && scrollFlowPeers.contains(peer)),
            compactPeers.contains(peer), message.sequence >= (acknowledgements[peer]?.sequence ?? 0)
        {
            acknowledgements[peer] = (message.sequence, transport)
        }
        if message.type == "release" {
            received[peer] = max(received[peer, default: 0], message.sequence);
            releasePeer(peer);
            if pointer?.ownerPeerID == peer || active?.peerID == peer { recover("对端已停止输入共享，本机已恢复", announce: false) };
            return
        }
        if message.type == "priority", peer == group.leaderID, let list = message.priority,
            list.count <= group.members.count, Set(list).count == list.count, list.allSatisfy({ online.contains($0) })
        {
            priority = list;
            return
        }
        if message.type == "mouse-mode" {
            receiveMouseMode(peer, message);
            return
        }
        if ["control", "pointer", "move", "relative-start", "relative-move"].contains(message.type) {
            guard let next = message.pointer, next.ownerPeerID == peer, next.x.isFinite, next.y.isFinite,
                let screen = group.layout.first(where: { $0.id == next.screenID }), online.contains(screen.peerID),
                next.x >= screen.x, next.x <= screen.x + screen.width, next.y >= screen.y,
                next.y <= screen.y + screen.height
            else { return }
            if message.sequence >= (receivedContexts[peer]?.sequence ?? 0),
                next.epoch >= (receivedContexts[peer]?.pointer.epoch ?? 0)
            {
                receivedContexts[peer] = (next, message.sequence)
            }
            if let current = pointer,
                next.epoch < current.epoch
                    || next.epoch == current.epoch && next.ownerPeerID != current.ownerPeerID
                        && rank(next.ownerPeerID) >= rank(current.ownerPeerID)
            {
                let now = ProcessInfo.processInfo.systemUptime
                if ProcessInfo.processInfo.arguments.contains("--input-state-check"), now - rejectionReportAt >= 5 {
                    rejectionReportAt = now;
                    event(
                        "InputControlRejected type=\(message.type) incomingOwner=\(next.ownerPeerID) incomingEpoch=\(next.epoch) localOwner=\(current.ownerPeerID) localEpoch=\(current.epoch)"
                    )
                }
                return
            }
            guard message.sequence > received[peer, default: 0] else { return }
            received[peer] = message.sequence;
            let changedScreen = pointer?.screenID != next.screenID
            let changedOwner = pointer?.epoch != next.epoch || pointer?.ownerPeerID != next.ownerPeerID
            if changedOwner, pointer?.ownerPeerID == id { discardContinuousDelivery() }
            pointer = next;
            noiseX = 0;
            noiseY = 0;
            reportRelativeMode()
            if message.type == "control" {
                event(
                    "InputControlApplied sourcePeerId=\(peer) targetPeerId=\(screen.peerID) epoch=\(next.epoch) enabled=\(enabled)"
                )
            }
            if ["relative-start", "relative-move"].contains(message.type) {
                applyRelative(peer, message, screen);
                restrictCursor();
                return
            }
            if localRelative && !changedScreen && !changedOwner && message.type != "control" { return }
            if changedScreen || changedOwner || message.type == "control" {
                let began = ProcessInfo.processInfo.systemUptime
                releaseAllIfCrossing(changedScreen);
                moveLocal();
                sendHeldIfCrossing(changedScreen)
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                if screen.peerID == id, elapsed > 0.008 {
                    event("InputFirstPlacementSlow durationMs=\(Int(elapsed*1000))")
                }
            } else {
                scheduleRender(next)
            }
            restrictCursor();
            return
        }
        if message.type == "scroll",
            message.pointer?.ownerPeerID != peer || pointer?.ownerPeerID != peer
                || message.pointer?.epoch != pointer?.epoch
        {
            return
        }
        guard enabled, message.targetPeerID == id, message.targetScreenID == pointer?.screenID, active?.peerID == id,
            message.sequence > received[peer, default: 0]
        else { return }
        received[peer] = message.sequence
        if ["keyDown", "keyUp", "held"].contains(message.type) {
            let next = (fn: message.fnEnabled ?? true, functions: message.functionKeysEnabled ?? true)
            let old = sourceOptions[peer] ?? (fn: true, functions: true)
            if old != next {
                let from = message.sourcePlatform ?? platforms[peer, default: "unknown"]
                let originals = originalKeys[peer, default: [:]]
                let function: ((String) -> String?)? = platform == "macos" ? { KeyboardMapping.macFunction($0) } : nil
                let fnDown = originals.keys.contains {
                    KeyboardMapping.map(
                        $0, from: from, to: platform, config: config, fnEnabled: next.fn,
                        functionKeysEnabled: next.functions) == "Fn"
                }
                for (key, mapped) in originals {
                    let updated = KeyboardMapping.map(
                        key, from: from, to: platform, config: config, fnDown: fnDown, functionKey: function,
                        fnEnabled: next.fn, functionKeysEnabled: next.functions,
                        functionSlot: remoteFunctionSlots[peer]?[key])
                    if updated != mapped { try? mappedKey(peer, key, false, from: from) }
                }
            }
            sourceOptions[peer] = next
        }
        // Unchanged held-state repair must not interrupt an in-flight movement interpolation.
        if message.type == "scroll", let next = message.pointer, let current = pointer, next.ownerPeerID == peer,
            next.epoch == current.epoch, next.screenID == current.screenID, let screen = active, next.x.isFinite,
            next.y.isFinite, next.x >= screen.x, next.x <= screen.x + screen.width, next.y >= screen.y,
            next.y <= screen.y + screen.height
        {
            pointer = next;
            if next != current { moveLocal() }
        }
        if message.type != "scroll"
            && (message.type != "held" || Set(message.keys ?? []) != Set(originalKeys[peer, default: [:]].keys)
                || Set(message.buttons ?? []) != buttons[peer, default: []])
        {
            moveLocal()
        }
        do {
            switch message.type {
            case "held":
                try syncHeld(
                    peer, message.keys ?? [], message.buttons ?? [],
                    from: message.sourcePlatform ?? platforms[peer, default: "unknown"],
                    slots: message.functionSlots ?? [:])
            case "keyDown", "keyUp":
                if let key = message.key, targetKeyHandler?(CapturedInput(message.type, key: key)) != true,
                    !key.isEmpty, key.utf8.count <= 32
                {
                    try mappedKey(
                        peer, key, message.type == "keyDown",
                        from: message.sourcePlatform ?? platforms[peer, default: "unknown"],
                        functionSlot: message.functionSlot)
                }
            case "text":
                if let text = message.text, !text.isEmpty, text.utf8.count <= 4096 {
                    try inject(CapturedInput("text", text: text), active, 0, 0)
                }
            case "command":
                if let command = message.command { execute(command, source: peer, entryID: message.clipboardEntryID) }
            case "buttonDown", "buttonUp":
                if (0...2).contains(message.button) {
                    try setButton(peer, message.button, message.type == "buttonDown")
                }
            case "scroll":
                if message.deltaX.isFinite, message.deltaY.isFinite {
                    try inject(
                        CapturedInput(
                            "scroll", deltaX: max(-10000, min(10000, message.deltaX)),
                            deltaY: max(-10000, min(10000, message.deltaY)), scrollPhase: message.scrollPhase,
                            momentumPhase: message.momentumPhase, preciseScroll: message.preciseScroll), active, 0, 0)
                }
            default: break
            }
        } catch {
            pause();
            status("系统拒绝输入注入，已恢复本机控制")
        }
    }
    private func perform(_ command: String, target: String) {
        event("InputCommandSent command=\(command) targetPeerId=\(target)")
        let entryID = command == "paste" ? clipboardEntryID?() : nil
        if target == id {
            execute(command, source: id, entryID: entryID)
        } else {
            var message = packet("command", target);
            message.command = command;
            message.clipboardEntryID = entryID;
            queue(target, message)
        }
    }
    private func execute(_ command: String, source: String, entryID: String?) {
        guard
            ["copy", "cut", "paste", "history", "undo", "redo", "desktopPrevious", "desktopNext", "overview"].contains(
                command)
        else { return }
        event("InputCommandExecute command=\(command) sourcePeerId=\(source)")
        Task {
            do {
                if let commandHandler, try await commandHandler(command, source, entryID) { return }
                try inject(CapturedInput("command", command: command), active, 0, 0)
            } catch {
                pause();
                status("命令未完成：目标系统权限或能力不可用，已恢复本机控制")
            }
        }
    }
    private func mappedKey(_ peer: String, _ key: String, _ down: Bool, from: String, functionSlot: String? = nil)
        throws
    {
        if down {
            if let existing = originalKeys[peer]?[key] {
                if existing != KeyboardMapping.noAction { try setKey(peer, existing, true) };
                return
            }
            remoteFunctionSlots[peer, default: [:]][key] = functionSlot.flatMap {
                KeyboardMapping.windowsFunctions[$0] != nil ? $0 : nil
            }
            let fnDown = originalKeys[peer, default: [:]].values.contains("Fn")
            let functionKey: ((String) -> String?)? = platform == "macos" ? { KeyboardMapping.macFunction($0) } : nil
            let mapped = KeyboardMapping.map(
                key, from: from, to: platform, config: config, fnDown: fnDown, functionKey: functionKey,
                fnEnabled: sourceOptions[peer]?.fn ?? true, functionKeysEnabled: sourceOptions[peer]?.functions ?? true,
                functionSlot: remoteFunctionSlots[peer]?[key])
            let duplicate = originalKeys[peer, default: [:]].values.contains(mapped)
            originalKeys[peer, default: [:]][key] = mapped
            if !duplicate && mapped != KeyboardMapping.noAction { try setKey(peer, mapped, true) }
        } else {
            remoteFunctionSlots[peer]?.removeValue(forKey: key)
            if let mapped = originalKeys[peer]?.removeValue(forKey: key),
                !originalKeys[peer, default: [:]].values.contains(mapped), mapped != KeyboardMapping.noAction
            {
                try setKey(peer, mapped, false)
            }
        }
    }
    private func rank(_ peer: String) -> Int { priority.firstIndex(of: peer) ?? Int.max }
    private func restrictCursor() {
        restrict(enabled && active?.peerID != id, enabled && (active?.peerID != id || pointer?.ownerPeerID != id))
    }
    private func moveLocal() {
        if localRelative && pointer?.ownerPeerID != id { return }
        renderTarget = nil;
        rendered = pointer
        guard enabled, let pointer, let screen = active, screen.peerID == id else { return }
        // Leave the remote capture context before placing the visible local cursor.
        restrictCursor()
        do {
            let native = screen.native((pointer.x - screen.x) / screen.width, (pointer.y - screen.y) / screen.height);
            try inject(CapturedInput("move"), screen, native.0, native.1)
        } catch { movementFailed(error) }
    }
    private func movementFailed(_ error: Error) {
        if let failure = error as? InputAdapterError {
            event("InputMovementFailed reason=\(failure)")
            if failure == .event || failure == .display {
                // Release interception and held state without recursively retrying the
                // failed placement. The next real input can resume sharing.
                recover("指针定位暂时失败，已恢复本机控制；共享继续运行", reposition: false)
                return
            }
        }
        pause();
        status("系统拒绝输入权限，已恢复本机控制")
    }
    private func setKey(_ peer: String, _ key: String, _ down: Bool) throws {
        if down {
            let other = keys.contains { $0.key != peer && $0.value.contains(key) };
            let fresh = keys[peer, default: []].insert(key).inserted
            if !other || !fresh { try inject(CapturedInput("keyDown", key: key), active, 0, 0) }
        } else if keys[peer, default: []].remove(key) != nil, !keys.values.contains(where: { $0.contains(key) }) {
            try inject(CapturedInput("keyUp", key: key), active, 0, 0)
        }
    }
    private func setButton(_ peer: String, _ button: Int, _ down: Bool) throws {
        if down {
            let other = buttons.contains { $0.key != peer && $0.value.contains(button) }
            if buttons[peer, default: []].insert(button).inserted, !other {
                try inject(CapturedInput("buttonDown", button: button), active, 0, 0)
            }
        } else if buttons[peer, default: []].remove(button) != nil,
            !buttons.values.contains(where: { $0.contains(button) })
        {
            try inject(CapturedInput("buttonUp", button: button), active, 0, 0)
        }
    }
    private func syncHeld(
        _ peer: String, _ desiredKeys: [String], _ desiredButtons: [Int], from: String, slots: [String: String] = [:]
    ) throws {
        guard slots.count <= desiredKeys.count,
            slots.allSatisfy({ desiredKeys.contains($0.key) && KeyboardMapping.windowsFunctions[$0.value] != nil })
        else { return }
        guard desiredKeys.allSatisfy({ $0.utf8.count <= 32 }), desiredButtons.allSatisfy({ (0...2).contains($0) })
        else { return }
        let desiredKeys = desiredKeys.filter { targetKeyHandler?(CapturedInput("keyDown", key: $0)) != true }
        for key in Set(originalKeys[peer, default: [:]].keys).subtracting(desiredKeys) {
            try mappedKey(peer, key, false, from: from)
        }
        // A held snapshot is a set. Establish mapped Fn before resolving a newly held F key.
        let added = Set(desiredKeys).subtracting(originalKeys[peer, default: [:]].keys).sorted {
            let a = KeyboardMapping.map($0, from: from, to: platform, config: config) == "Fn"
            let b = KeyboardMapping.map($1, from: from, to: platform, config: config) == "Fn"
            return a != b ? a : $0 < $1
        }
        for key in added { try mappedKey(peer, key, true, from: from, functionSlot: slots[key]) }
        for button in buttons[peer, default: []].subtracting(desiredButtons) { try setButton(peer, button, false) }
        for button in Set(desiredButtons).subtracting(buttons[peer, default: []]) { try setButton(peer, button, true) }
    }
    private func releasePeer(_ peer: String) {
        for key in keys[peer, default: []] { try? setKey(peer, key, false) }
        for button in buttons[peer, default: []] { try? setButton(peer, button, false) }
        remoteFunctionSlots.removeValue(forKey: peer);
        originalKeys.removeValue(forKey: peer);
        keys.removeValue(forKey: peer);
        buttons.removeValue(forKey: peer)
    }
    private func releaseAll() { for peer in Set(keys.keys).union(buttons.keys) { releasePeer(peer) } }
    private func sendHeld() {
        guard enabled, let screen = active else { return }
        if screen.peerID == id { return }
        let desiredKeys = Set(physicalKeys.subtracting(commandKeys).map { sourceKey($0, screen.peerID) })
        let epoch = pointer?.epoch ?? 0
        // Empty repair has no work after its first delivery; compact pointer frames
        // already provide liveness. Repeating JSON every 500ms fills the BLE stream.
        if desiredKeys.isEmpty, physicalButtons.isEmpty, let last = heldSnapshots[screen.peerID],
            last.screen == screen.id, last.epoch == epoch, last.keys.isEmpty, last.buttons.isEmpty
        {
            return
        }
        heldSnapshots[screen.peerID] = (screen.id, epoch, desiredKeys, physicalButtons)
        var message = packet("held", screen.peerID);
        message.keys = Array(desiredKeys);
        message.functionSlots = Dictionary(
            uniqueKeysWithValues: physicalFunctionSlots.filter {
                desiredKeys.contains(sourceKey($0.key, screen.peerID))
            }.map { (sourceKey($0.key, screen.peerID), $0.value) });
        message.buttons = Array(physicalButtons);
        queue(screen.peerID, message)
    }
    private func tick() {
        let reportNow = ProcessInfo.processInfo.systemUptime
        if ProcessInfo.processInfo.arguments.contains("--input-state-check"), reportNow - stateReportAt >= 5 {
            stateReportAt = reportNow
            event(
                "InputState enabled=\(enabled) online=\(online.sorted().joined(separator: ",")) inputPeers=\(inputPeers.sorted().joined(separator: ",")) blePeers=\(blePeers.sorted().joined(separator: ",")) owner=\(pointer?.ownerPeerID ?? "none") target=\(active?.peerID ?? "none") epoch=\(pointer?.epoch ?? 0) captureRate=\(captureRate) sendRate=\(sendRate)"
            )
        }
        if reportNow - bleReportAt >= 5, !bleAckMilliseconds.isEmpty {
            let samples = bleAckMilliseconds.sorted();
            bleAckMilliseconds = [];
            bleReportAt = reportNow
            event(
                "BLEInputDelivery samples=\(samples.count) ackP50Ms=\(Int(samples[samples.count / 2])) ackP95Ms=\(Int(samples[min(samples.count - 1, samples.count * 95 / 100)])) ackMaxMs=\(Int(samples.last!))"
            )
        }

        guard !stopped, enabled else { return }
        reportRelativeMode()
        if let stalled = outstanding.first(where: {
            !$0.value.isEmpty && (motionProgress[$0.key]?.duration(to: .now) ?? .zero) > .seconds(1)
        })?.key {
            checkSlowInput(stalled, delivery: true)
        }
        for peer in heard.filter({ $0.value.duration(to: .now) > .seconds(3) }).map(\.key) {
            checkSlowInput(peer, delivery: false)
        }
        tickCount += 1
        if tickCount % 10 == 0 {
            captureRate = capturedMoves;
            sendRate = sentMoves;
            capturedMoves = 0;
            sentMoves = 0
        }
        if tickCount % 5 == 0 {
            // Move frames already carry position and liveness. Keep bulky repair off the moving path.
            let movingRemote =
                pointer?.ownerPeerID == id && active?.peerID != id
                && (lastRemoteMotion?.duration(to: .now) ?? .seconds(1)) < .milliseconds(250)
            if !movingRemote {
                if pointer?.ownerPeerID == id { broadcast("pointer") };
                sendHeld()
            }
        }
    }
    private func releaseAllIfCrossing(_ crossing: Bool) { if crossing { releaseAll() } }
    private func sendHeldIfCrossing(_ crossing: Bool) { if crossing { sendHeld() } }
    private func checkSlowInput(_ peer: String, delivery: Bool) {
        guard !deliveryChecks.contains(peer) else { return }
        deliveryChecks.insert(peer);
        let round = (generation, deliveryGeneration)
        Task {
            let alive = await manager.inputSessionAlive(peer)
            deliveryChecks.remove(peer)
            guard round == (generation, deliveryGeneration), enabled, online.contains(peer) else { return }
            if delivery {
                guard !(outstanding[peer]?.isEmpty ?? true),
                    (motionProgress[peer]?.duration(to: .now) ?? .zero) > .seconds(1)
                else { return }
                if alive {
                    let now = ProcessInfo.processInfo.systemUptime
                    // Do not fabricate ACKs or reset credit while the native dispatcher is slow.
                    let previous = slowDeliveryReported[peer]
                    if now - (previous ?? -Double.infinity) >= 5 {
                        slowDeliveryReported[peer] = now;
                        event("InputDeliveryWaiting peerId=\(peer) sessionAlive=true")
                        if previous == nil { status("对端输入处理较慢，共享保持连接；可用紧急快捷键恢复本机") }
                    }
                } else {
                    event("InputMotionAckStalled peerId=\(peer)");
                    recover("输入连接已不可用，已恢复本机控制")
                }
            } else if !alive, (heard[peer]?.duration(to: .now) ?? .zero) > .seconds(3) {
                releasePeer(peer);
                heard.removeValue(forKey: peer)
                if pointer?.ownerPeerID == peer { recover("输入连接已不可用，已恢复本机控制") }
            }
        }
    }
    public func recoverCaptureInterruption() { recover("输入监听已恢复，本机控制已释放；共享继续运行") }
    public func recoverCaptureTimeout() {
        // A native tap timeout is not a transport disconnect. Keep the current screen,
        // but fence off packets captured before the gap and release potentially missed ups.
        discardContinuousDelivery();
        pending = [];
        physicalKeys = [];
        physicalFunctionSlots = [:];
        physicalButtons = [];
        commandKeys = []
        heldSnapshots = [:];
        releaseAll();
        renderTarget = nil
        if enabled, var current = pointer, current.ownerPeerID == id {
            current.epoch += 1;
            pointer = current;
            relativePeer = nil
            broadcast("control");
            sendHeld()
            if let screen = active, screen.peerID != id, scrollPeers.contains(screen.peerID) {
                var end = packet("scroll", screen.peerID);
                end.preciseScroll = true;
                end.scrollPhase = 8;
                end.momentumPhase = 4
                queue(screen.peerID, end)
            }
        }
        restrictCursor()
        event("InputCaptureTimeoutRecovered enabled=\(enabled) targetPeerId=\(active?.peerID ?? "none")")
    }
    private func recover(_ reason: String, announce: Bool = true, reposition: Bool = true) {
        discardContinuousDelivery();
        pending = [];
        acknowledgements = [:];
        heard = [:]
        physicalKeys = [];
        physicalFunctionSlots = [:];
        physicalButtons = [];
        commandKeys = [];
        releaseAll();
        renderTarget = nil
        if let screen = usable.first(where: { $0.peerID == id && $0.primary }) {
            pointer = PointerRouter.center(screen, owner: id, epoch: (pointer?.epoch ?? 0) + 1)
            restrict(false, false);
            if reposition { moveLocal() }
            if announce { broadcast("control") }
        } else {
            restrict(false, false)
        }
        event("InputRecovered enabled=\(enabled)");
        status(reason)
    }
    private func scheduleRender(_ target: PointerState) {
        guard enabled, active?.peerID == id else { return }
        if blePeers.contains(target.ownerPeerID) {
            moveLocal();
            return
        }
        if renderTarget == target { return }
        if rendered == target {
            renderTarget = nil;
            return
        }
        renderFrom = rendered ?? target;
        renderTarget = target;
        renderAt = .now
    }
    private func startHighRateTimer() {
        if interactiveActivity == nil {
            interactiveActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "ShareMouse interactive keyboard and pointer sharing")
        }
        highRateTimer?.cancel()
        highRateTimer = Task { [weak self] in
            self?.lastAckAt = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2));
                guard !Task.isCancelled, let self else { return }
                self.renderStep()
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastAckAt >= 0.008 {
                    self.lastAckAt = now;
                    self.sendAcknowledgements()
                }
            }
        }
    }
    private func renderStep() {
        guard enabled, let target = renderTarget, let from = renderFrom, let screen = active, screen.peerID == id else {
            return
        }
        let elapsed = renderAt.duration(to: .now).components
        let fraction = min(1, (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) / 0.004)
        var point = target;
        point.x = from.x + (target.x - from.x) * fraction;
        point.y = from.y + (target.y - from.y) * fraction
        do {
            let native = screen.native((point.x - screen.x) / screen.width, (point.y - screen.y) / screen.height);
            try inject(CapturedInput("move"), screen, native.0, native.1);
            rendered = point;
            if fraction == 1 { renderTarget = nil }
        } catch { movementFailed(error) }
    }
    private func sendAcknowledgements() {
        guard let group else { return }
        let values = acknowledgements;
        acknowledgements = [:]
        for (peer, value) in values {
            var ack = InputPacket(type: "motionAck", groupID: group.id, sourcePeerID: id, targetPeerID: peer);
            ack.acknowledgedSequence = value.sequence
            guard let bytes = MotionCodec.encode(ack, layout: group.layout, compactContext: contextPeers.contains(peer))
            else { continue }
            Task {
                await manager.inputReceived(peer, transport: value.transport);
                try? await manager.sendOnTransport(
                    peerID: peer, channel: "input", payload: bytes, transport: value.transport)
            }
        }
    }
    public func stop() {
        pause();
        stopped = true;
        timer?.cancel();
        pending = []
    }
}
