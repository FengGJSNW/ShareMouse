import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v);
        case .array(let v): try c.encode(v);
        case .string(let v): try c.encode(v);
        case .number(let v): try c.encode(v);
        case .bool(let v): try c.encode(v);
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue {
        get { object[key] ?? .null }
        set {
            var v = object;
            v[key] = newValue;
            self = .object(v)
        }
    }
    public var object: [String: JSONValue] {
        if case .object(let v) = self { return v };
        return [:]
    }
    public var array: [JSONValue] {
        if case .array(let v) = self { return v };
        return []
    }
    public var string: String? {
        if case .string(let v) = self { return v };
        return nil
    }
    public var number: Double? {
        if case .number(let v) = self { return v };
        return nil
    }
    public func required(_ key: String) throws -> String {
        guard let v = self[key].string, !v.isEmpty else { throw ComputerUseError.message("missing_" + key) };
        return v
    }
    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
    public func data() throws -> Data {
        let e = JSONEncoder();
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys];
        return try e.encode(self)
    }
}
public enum ComputerUseError: Error, LocalizedError {
    case message(String)
    case detailed(String, JSONValue)
    public var errorDescription: String? {
        switch self {
        case .message(let s), .detailed(let s, _): return s
        }
    }
}

/// A separate target-bound executor; shared-desktop motion coalescing never processes AI actions.
@MainActor public final class ComputerUseService {
    public static let capability = "remote-computer-v1"
    public nonisolated static let idleTimeout: TimeInterval = 600
    public var allowComputer = false
    public var allowFiles = false
    public var controlling: Bool { control != nil }
    public var controlContext: JSONValue { control?.context ?? .null }
    private let id: String, name: String
    private let manager: SessionManager
    private let screens: () -> [ScreenGeometry]
    private let info: () -> JSONValue
    private let captureWithOptions:
        (@MainActor (ScreenGeometry, JSONValue, @escaping @MainActor () -> Bool) async throws -> JSONValue)?
    private let inputState: (() -> JSONValue)?
    private let screenshot: (ScreenGeometry) async throws -> JSONValue
    private let inject: (CapturedInput, ScreenGeometry?, Double, Double) throws -> Void
    private let suspend: () -> Bool
    private let restore: (Bool) -> Void
    private let canControl: () -> Bool
    private let marker: (ScreenGeometry, Double, Double, String) -> Void
    private let focusApplication: (String) async throws -> Void
    private let prepareControl: (JSONValue) throws -> JSONValue
    private let validatePlatformAction: (JSONValue, ScreenGeometry, Double, Double) throws -> Void
    private let pointerPreview: (ScreenGeometry, Double, Double, String) -> Int
    private let now: () -> Date
    private let diagnostic: (String) -> Void
    private let controlChanged: (Bool, String) -> Void
    private let activity: () -> Void
    private let files: FileTransferService?
    private let clipboard: ClipboardService
    private var watcher: Task<Void, Never>?
    private struct Control {
        var token: String, owner: String, ownerSession: String?, screen: ScreenGeometry, restoreSharing: Bool
        var started: Date, expires: Date
        var idleSeconds: TimeInterval = ComputerUseService.idleTimeout
        var clientID: String?, clientName: String?
        var observation = "", width = 0, height = 0, busy = false
        var context: JSONValue = .object(["mode": .string("user_mouse")])
        var region: JSONValue = .object(["x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1)])
        var completed: [String: (Data, JSONValue)] = [:]
        var lastResult: JSONValue = .null, lastCapturedAt: JSONValue = .null, lastWindowID: String?
        var openRequest: String?
    }
    private var control: Control?
    private var lastEnded: (token: String, owner: String, reason: String)?
    private var heldKeys = Set<String>(), heldButtons = Set<Int>()
    private struct Packet: Codable {
        var type: String;
        var requestID: String;
        var offset: Int;
        var total: Int;
        var data: Data
    }
    private struct Assembly {
        var data = Data();
        var total: Int;
        var created = Date()
    }
    private var incoming: [String: Assembly] = [:], working = Set<String>()
    private struct Pending {
        var peer: String;
        var session: String;
        var operation: String;
        var result: CheckedContinuation<JSONValue, Error>
    }
    private var pending: [String: Pending] = [:]
    private var stopped = false
    public init(
        id: String, name: String, manager: SessionManager, files: FileTransferService?, clipboard: ClipboardService,
        screens: @escaping () -> [ScreenGeometry], info: @escaping () -> JSONValue,
        screenshot: @escaping (ScreenGeometry) async throws -> JSONValue,
        inject: @escaping (CapturedInput, ScreenGeometry?, Double, Double) throws -> Void,
        suspend: @escaping () -> Bool, restore: @escaping (Bool) -> Void, canControl: @escaping () -> Bool,
        marker: @escaping (ScreenGeometry, Double, Double, String) -> Void = { _, _, _, _ in },
        now: @escaping () -> Date = { Date() }, diagnostic: @escaping (String) -> Void = { _ in },
        controlChanged: @escaping (Bool, String) -> Void = { _, _ in }, activity: @escaping () -> Void = {},
        inputState: (() -> JSONValue)? = nil,
        captureWithOptions: (
            @MainActor (ScreenGeometry, JSONValue, @escaping @MainActor () -> Bool) async throws -> JSONValue
        )? = nil, pointerPreview: @escaping (ScreenGeometry, Double, Double, String) -> Int = { _, _, _, _ in 0 },
        focusApplication: @escaping (String) async throws -> Void = { _ in
            throw ComputerUseError.message("application_focus_unavailable")
        },
        prepareControl: @escaping (JSONValue) throws -> JSONValue = { args in
            let mode = args["control_mode"].string ?? "user_mouse"
            guard mode == "user_mouse" else { throw ComputerUseError.message("control_mode_unsupported") }
            return .object(["mode": .string(mode)])
        },
        validatePlatformAction: @escaping (JSONValue, ScreenGeometry, Double, Double) throws -> Void = { _, _, _, _ in }
    ) {
        self.id = id;
        self.name = name;
        self.manager = manager;
        self.files = files;
        self.clipboard = clipboard
        self.screens = screens;
        self.info = info;
        self.screenshot = screenshot;
        self.inject = inject
        self.suspend = suspend;
        self.restore = restore;
        self.canControl = canControl;
        self.marker = marker
        self.now = now;
        self.diagnostic = diagnostic;
        self.controlChanged = controlChanged
        self.activity = activity;
        self.inputState = inputState;
        self.captureWithOptions = captureWithOptions;
        self.pointerPreview = pointerPreview;
        self.focusApplication = focusApplication;
        self.prepareControl = prepareControl;
        self.validatePlatformAction = validatePlatformAction
    }
    public func start() async {
        await manager.receive(channel: "computer") { [weak self] peer, bytes in await self?.receive(peer, bytes) }
        await updateCapabilities()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1));
                guard let self, !self.stopped else { return }
                let online = await self.manager.currentSessions()
                if let c = self.control {
                    if let reason = self.unavailable(c) {
                        self.endControl(reason: reason)
                    } else if c.owner != self.id
                        && !online.contains(where: { $0.peerID == c.owner && $0.sessionID == c.ownerSession })
                    {
                        self.endControl(reason: "peer_disconnected")
                    }
                }
                for (key, p) in self.pending
                where !online.contains(where: { $0.peerID == p.peer && $0.sessionID == p.session }) {
                    self.pending.removeValue(forKey: key)?.result.resume(
                        throwing: ComputerUseError.message("peer_disconnected"))
                }
                self.incoming = self.incoming.filter { Date().timeIntervalSince($0.value.created) < 60 }
            }
        }
    }
    public func updateCapabilities() async {
        await manager.setCapabilities([Self.capability: true, "computer-open-ack-v1": true])
    }
    /// During MCP control, let local input reach the OS without routing it through sharing.
    /// Only an explicit user exit ends control; accidental movement is not a takeover.
    public func physicalInput(_ event: CapturedInput) -> Bool { controlling }
    public func endControl(reason: String = "closed") {
        let old = control;
        control = nil
        for button in heldButtons { try? inject(CapturedInput("buttonUp", button: button), nil, 0, 0) }
        for key in heldKeys { try? inject(CapturedInput("keyUp", key: key), nil, 0, 0) }
        heldButtons = [];
        heldKeys = [];
        if let old {
            lastEnded = (old.token, old.owner, reason)
            diagnostic("ComputerUseEnded reason=\(reason) ageMs=\(Int(now().timeIntervalSince(old.started) * 1000))")
            controlChanged(false, reason);
            restore(old.restoreSharing)
        }
    }
    public func stop() {
        stopped = true;
        watcher?.cancel();
        endControl(reason: "server_stopped");
        for p in pending.values { p.result.resume(throwing: ComputerUseError.message("server_stopped")) };
        pending = [:];
        incoming = [:]
    }
    private func receive(_ peer: String, _ bytes: Data) async {
        guard !stopped, let packet = try? JSONDecoder().decode(Packet.self, from: bytes),
            UUID(uuidString: packet.requestID) != nil
        else { return }
        if ["open_ack", "open_cancel"].contains(packet.type) {
            guard packet.total == 0, packet.offset == 0, packet.data.isEmpty, control?.owner == peer,
                control?.openRequest == packet.requestID
            else { return }
            if packet.type == "open_ack" {
                control?.openRequest = nil;
                diagnostic("ComputerOpenConfirmed")
            } else {
                endControl(reason: "open_request_cancelled")
            }
            return
        }
        guard ["request", "response"].contains(packet.type), packet.total > 0,
            packet.total <= (packet.type == "request" ? 262144 : 16 * 1024 * 1024), packet.data.count <= 20000
        else { return }
        if packet.type == "response", pending[packet.requestID]?.peer != peer { return }
        let key = peer + ":" + packet.type + ":" + packet.requestID
        if working.contains(key) { return }
        if incoming[key] == nil {
            guard packet.offset == 0, incoming.count < 12 else { return };
            incoming[key] = Assembly(total: packet.total)
        }
        guard var state = incoming[key], state.total == packet.total, state.data.count == packet.offset,
            packet.offset + packet.data.count <= packet.total
        else {
            incoming.removeValue(forKey: key);
            return
        }
        state.data.append(packet.data);
        incoming[key] = state
        guard state.data.count == state.total else { return };
        incoming.removeValue(forKey: key)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: state.data) else { return }
        if packet.type == "response" {
            if let p = pending.removeValue(forKey: packet.requestID) {
                if value["ok"] == .bool(true) {
                    if p.operation == "open" {
                        try? await sendOpenSignal(peer, type: "open_ack", request: packet.requestID)
                    }
                    p.result.resume(returning: value["value"])
                } else {
                    p.result.resume(
                        throwing: ComputerUseError.detailed(
                            value["error"].string ?? "remote_failure", value["error_details"]))
                }
            }
        } else {
            if control?.owner == peer, value["operation"] != .string("open"),
                value["arguments"]["control_session_id"].string == control?.token
            {
                control?.openRequest = nil
            }
            working.insert(key)
            Task {
                defer { working.remove(key) }
                let result: JSONValue
                do {
                    result = .object([
                        "ok": .bool(true),
                        "value": try await execute(
                            value.required("operation"), value["arguments"], owner: peer, requestID: packet.requestID),
                    ])
                } catch {
                    result = .object([
                        "ok": .bool(false), "error": .string(error.localizedDescription),
                        "error_details": Self.errorDetails(error),
                    ])
                }
                try? await transmit(peer, type: "response", request: packet.requestID, value: result)
            }
        }
    }
    private func sendOpenSignal(_ peer: String, type: String, request: String) async throws {
        try await manager.send(
            peerID: peer, channel: "computer",
            payload: JSONEncoder().encode(Packet(type: type, requestID: request, offset: 0, total: 0, data: Data())))
    }
    private func transmit(_ peer: String, type: String, request: String, value: JSONValue) async throws {
        let data = try value.data();
        guard data.count <= 16 * 1024 * 1024 else { throw ComputerUseError.message("payload_too_large") }
        let encoder = JSONEncoder();
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for offset in stride(from: 0, to: data.count, by: 20000) {
            let part = data.subdata(in: offset..<min(offset + 20000, data.count))
            try await manager.send(
                peerID: peer, channel: "computer",
                payload: encoder.encode(
                    Packet(type: type, requestID: request, offset: offset, total: data.count, data: part)))
        }
    }
    public func call(_ peer: String, operation: String, arguments: JSONValue) async throws -> JSONValue {
        guard !stopped else { throw ComputerUseError.message("server_stopped") }
        if peer == id || peer == "local" { return try await execute(operation, arguments, owner: id) }
        guard
            let session = await manager.currentSessions().first(where: {
                $0.peerID == peer && $0.capabilities.contains(Self.capability)
            }), pending.count < 8
        else { throw ComputerUseError.message("peer_offline_or_capability_unavailable") }
        let request = UUID().uuidString.lowercased()
        return try await withCheckedThrowingContinuation { continuation in
            pending[request] = Pending(
                peer: peer, session: session.sessionID, operation: operation, result: continuation)
            Task {
                do {
                    try await transmit(
                        peer, type: "request", request: request,
                        value: .object(["operation": .string(operation), "arguments": arguments]))
                } catch { pending.removeValue(forKey: request)?.result.resume(throwing: error) }
            }
            Task {
                try? await Task.sleep(for: .seconds(60))
                if let expired = pending.removeValue(forKey: request) {
                    if expired.operation == "open" {
                        Task { try? await sendOpenSignal(peer, type: "open_cancel", request: request) }
                    }
                    expired.result.resume(
                        throwing: ComputerUseError.detailed(
                            "remote_timeout_execution_unknown",
                            .object([
                                "code": .string("remote_timeout_execution_unknown"), "request_id": .string(request),
                                "input_outcome": .string(operation == "open" ? "not_attempted" : "unknown"),
                                "next_step": .string("query_control_status_before_retry"),
                                "cleanup_requested": .bool(operation == "open"),
                            ])))
                }
            }
        }
    }
    private func unavailable(_ c: Control) -> String? {
        if c.openRequest != nil && now().timeIntervalSince(c.started) > 45 { return "open_response_unconfirmed" }
        if c.expires <= now() { return "lease_expired" }
        if !allowComputer { return "computer_access_disabled" }
        if !canControl() { return "input_permission_or_desktop_unavailable" }
        if c.context["mode"].string == "independent", inputState?()["control_target_window"]["window_id"].string == nil
        {
            return "application_window_unavailable"
        }
        if !screens().contains(c.screen) { return "screen_changed" }
        return nil
    }
    private func pruneUnavailableControl(_ online: [SessionInfo]) {
        guard let c = control else { return }
        if let reason = unavailable(c) {
            endControl(reason: reason)
        } else if c.owner != id && !online.contains(where: { $0.peerID == c.owner && $0.sessionID == c.ownerSession }) {
            endControl(reason: "peer_disconnected")
        }
    }
    private func openBlocker(_ snapshot: JSONValue? = nil) -> String? {
        if !allowComputer { return "computer_access_disabled" }
        let permissions = (snapshot ?? info())["permissions"]
        if permissions["desktop_available"] == .bool(false) { return "desktop_locked_or_unavailable" }
        if permissions["input_injection"] == .bool(false) { return "input_permission_missing" }
        if permissions["input_monitoring"] == .bool(false) { return "input_monitoring_permission_missing" }
        if permissions["screen_capture"] == .bool(false) { return "screen_capture_permission_missing" }
        if !canControl() { return "input_permission_or_desktop_unavailable" }
        if screens().isEmpty { return "screen_unavailable" }
        return nil
    }
    // A peer may host multiple MCP clients. Matching the peer does not grant its control token.
    private func controlState(owner: String, snapshot: JSONValue? = nil) -> JSONValue {
        let c = control, reason = c.flatMap { unavailable($0) }, blocker = openBlocker(snapshot)
        let occupied = c != nil && reason == nil
        return .object([
            "session_present": .bool(c != nil), "active": .bool(occupied), "busy": .bool(c?.busy ?? false),
            "can_open": .bool(!occupied && blocker == nil),
            "open_blocker": (blocker ?? (occupied ? "computer_control_in_use" : nil)).map(JSONValue.string) ?? .null,
            "unavailable_reason": reason.map(JSONValue.string) ?? .null,
            "owner_peer_id": c.map { .string($0.owner) } ?? .null,
            "owner_client_id": c?.clientID.map(JSONValue.string) ?? .null,
            "owner_client_name": c?.clientName.map(JSONValue.string) ?? .null,
            "owner_is_local": c.map { .bool($0.owner == id) } ?? .null,
            "owner_matches_requesting_peer": c.map { .bool($0.owner == owner) } ?? .null,
            "control_mode": c?.context["mode"] ?? .null, "input_sharing_isolated": .bool(occupied),
            "screen_id": c.map { .string($0.screen.id) } ?? .null,
            "started_at": c.map { .string(ISO8601DateFormatter().string(from: $0.started)) } ?? .null,
            "lease_remaining_ms": c.map { .number(max(0, $0.expires.timeIntervalSince(now()) * 1000)) } ?? .null,
            "control_session_expires_at": c.map { .string(ISO8601DateFormatter().string(from: $0.expires)) } ?? .null,
            "renews_lease": .bool(false),
        ])
    }
    private func ensureCanOpen(owner: String) throws {
        guard let blocker = openBlocker() ?? (control != nil ? "computer_control_in_use" : nil) else { return }
        var details = Self.errorDetails(ComputerUseError.message(blocker));
        details["input_outcome"] = .string("not_attempted");
        details["control_state"] = controlState(owner: owner)
        diagnostic("ComputerUseOpenRejected reason=\(blocker) ownerPeer=\(control?.owner ?? "none")")
        throw ComputerUseError.detailed(blocker, details)
    }
    private func checked(_ args: JSONValue, owner: String) throws -> Control {
        let token = try args.required("control_session_id")
        if let c = control, c.token == token, c.owner == owner {
            if let reason = unavailable(c) { endControl(reason: reason) } else { return c }
        }
        let reason =
            lastEnded?.token == token && lastEnded?.owner == owner ? lastEnded!.reason : "session_mismatch_or_replaced"
        throw ComputerUseError.message("control_session_unavailable:" + reason)
    }
    private func capture(_ c: Control, options: JSONValue) async throws -> JSONValue {
        let token = c.token
        var adjusted = options;
        adjusted["_control_context"] = c.context
        if let peer = await manager.currentSessions().first(where: { $0.peerID == c.owner }),
            peer.capabilities.contains("ble"), !peer.capabilities.contains("tcp"), !peer.capabilities.contains("quic")
        {
            adjusted["_transport_jpeg"] = .bool(true)
        }
        if let captureWithOptions {
            return try await captureWithOptions(
                c.screen, adjusted,
                { [weak self] in
                    guard let self, let active = self.control, active.token == token else { return false };
                    return self.unavailable(active) == nil
                })
        }
        return try await screenshot(c.screen)
    }
    private func observe(_ args: JSONValue, owner: String) async throws -> JSONValue {
        try Self.validateObservationOptions(args)
        var c = try checked(args, owner: owner);
        let started = ContinuousClock.now
        let image = try await capture(c, options: args)
        c = try checked(args, owner: owner)
        c.observation = UUID().uuidString.lowercased();
        c.width = Int(image["width"].number ?? 0);
        c.height = Int(image["height"].number ?? 0)
        c.region =
            image["normalized_capture_region"] == .null
            ? .object(["x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1)])
            : image["normalized_capture_region"]
        c.expires = now().addingTimeInterval(c.idleSeconds);
        c.lastCapturedAt = image["captured_at"]
        var state = image["input_state"] == .null ? inputState?() ?? .null : image["input_state"]
        let coordinates = Self.coordinates(image)
        state["cursor_position_screenshot"] = Self.mapCursor(
            c.context["mode"].string == "independent" ? state["ai_cursor_position"] : state["cursor_position"],
            image: image)
        c.lastWindowID =
            (c.context["mode"].string == "independent" ? state["control_target_window"] : state["foreground_window"])[
                "window_id"
            ].string;
        control = c
        return .object([
            "peer_id": .string(id), "control_session_id": .string(c.token), "screen_id": .string(c.screen.id),
            "observation_id": .string(c.observation), "screenshot": image, "control_mode": c.context["mode"],
            "input_sharing_isolated": .bool(true), "coordinate_space": .string("screenshot_pixels"),
            "coordinate_transform": coordinates, "input_state": state, "analysis": image["analysis"],
            "observation_duration_ms": .number(Self.elapsed(started)),
            "control_session_idle_timeout_ms": .number(c.idleSeconds * 1000),
            "control_session_expires_at": .string(ISO8601DateFormatter().string(from: c.expires)),
        ])
    }
    private func execute(_ operation: String, _ args: JSONValue, owner: String, requestID: String? = nil) async throws
        -> JSONValue
    {
        activity()
        if operation == "info" {
            guard allowComputer || allowFiles else { throw ComputerUseError.message("access_disabled") };
            var result = info();
            result["peer_id"] = .string(id);
            result["name"] = .string(name);
            result["screens"] = try .encoded(screens());
            result["allow_computer"] = .bool(allowComputer);
            result["allow_files"] = .bool(allowFiles);
            result["control_state"] = controlState(owner: owner, snapshot: result)
            if args["read_screen"] == .bool(true) {
                guard allowComputer else { throw ComputerUseError.message("computer_access_disabled") }
                try Self.validateObservationOptions(args)
                guard
                    let screen = screens().first(where: {
                        args["screen_id"] == .null || $0.id == args["screen_id"].string
                    })
                else { throw ComputerUseError.message("screen_unavailable") }
                let image: JSONValue
                var options = args;
                options["_control_context"] = .null
                if args["control_session_id"] != .null {
                    options["_control_context"] = try checked(args, owner: owner).context
                }
                if let captureWithOptions {
                    image = try await captureWithOptions(screen, options, { !self.stopped && self.allowComputer })
                } else {
                    image = try await screenshot(screen)
                }
                result["observation"] = .object([
                    "screenshot": image, "analysis": image["analysis"], "input_state": image["input_state"],
                    "coordinate_transform": Self.coordinates(image), "read_only": .bool(true),
                ])
            }
            return result
        }
        if ["prepare_files", "paste_files", "transfers", "transfer_action"].contains(operation) {
            guard allowFiles, let files else { throw ComputerUseError.message("file_access_disabled") }
            switch operation {
            case "prepare_files":
                let paths = args["paths"].array.compactMap(\.string);
                guard !paths.isEmpty, paths.count <= 100, paths.allSatisfy({ $0.hasPrefix("/") }) else {
                    throw ComputerUseError.message("absolute_source_paths_required")
                }
                try await files.copy(paths, cut: false);
                return .object(["entry_id": .string(clipboard.current?.id ?? ""), "source_peer_id": .string(id)])
            case "paste_files":
                let source = try args.required("source_peer_id"), entry = try args.required("entry_id"),
                    destination = try args.required("destination")
                var directory: ObjCBool = false
                guard destination.hasPrefix("/"),
                    FileManager.default.fileExists(atPath: destination, isDirectory: &directory), directory.boolValue
                else { throw ComputerUseError.message("existing_absolute_destination_directory_required") }
                if source != id { try await clipboard.waitForEntry(entry, from: source) }
                guard clipboard.current?.id == entry, clipboard.current?.sourcePeerID == source else {
                    throw ComputerUseError.message("clipboard_changed")
                }
                let task = try files.beginPaste(destination);
                return .object(["peer_id": .string(id), "task_id": .string(task)])
            case "transfers":
                let tasks = files.currentTasks;
                if let key = args["task_id"].string {
                    guard let task = tasks.first(where: { $0.id == key }) else {
                        throw ComputerUseError.message("task_not_found")
                    };
                    return try .encoded(task)
                }
                return try .encoded(tasks)
            default:
                let key = try args.required("task_id");
                guard files.currentTasks.contains(where: { $0.id == key }) else {
                    throw ComputerUseError.message("task_not_found")
                }
                switch try args.required("action") {
                case "pause": files.pause(key);
                case "cancel": files.cancel(key);
                case "resume", "retry": Task { await files.resume(key) };
                default: throw ComputerUseError.message("invalid_transfer_action")
                }
                return .object(["task_id": .string(key), "accepted": .bool(true)])
            }
        }
        guard allowComputer else { throw ComputerUseError.message("computer_access_disabled") }
        switch operation {
        case "status":
            let c = try checked(args, owner: owner)
            return .object([
                "active": .bool(true), "busy": .bool(c.busy),
                "latest_observation_id": c.observation.isEmpty ? .null : .string(c.observation),
                "last_captured_at": c.lastCapturedAt, "last_action": c.lastResult,
                "input_state": inputState?() ?? .null,
                "lease_remaining_ms": .number(max(0, c.expires.timeIntervalSince(now()) * 1000)),
                "control_session_expires_at": .string(ISO8601DateFormatter().string(from: c.expires)),
                "renews_lease": .bool(false),
            ])
        case "open":
            try Self.validateObservationOptions(args)
            let idleMilliseconds = try Self.integer(
                args, "control_session_idle_timeout_ms", default: Int(Self.idleTimeout * 1000), range: 15000...600000)
            let online = await manager.currentSessions()
            guard !stopped else { throw ComputerUseError.message("server_stopped") }
            pruneUnavailableControl(online);
            try ensureCanOpen(owner: owner)
            guard let screen = screens().first else { throw ComputerUseError.message("screen_unavailable") }
            let selected: ScreenGeometry
            if let requested = args["screen_id"].string {
                guard let found = screens().first(where: { $0.id == requested }) else {
                    throw ComputerUseError.message("screen_unavailable")
                };
                selected = found
            } else {
                selected = screens().first(where: \.primary) ?? screen
            }
            let context = try prepareControl(args);
            try ensureCanOpen(owner: owner)
            let ownerSession = online.first(where: { $0.peerID == owner })?.sessionID
            control = Control(
                token: UUID().uuidString.lowercased(), owner: owner, ownerSession: ownerSession, screen: selected,
                restoreSharing: suspend(), started: now(), expires: now().addingTimeInterval(Self.idleTimeout))
            if let requestID,
                await manager.currentSessions().first(where: { $0.peerID == owner })?.capabilities.contains(
                    "computer-open-ack-v1") == true
            {
                control?.openRequest = requestID
            }
            if args["control_session_idle_timeout_ms"] != .null {
                let idleSeconds = Double(idleMilliseconds) / 1000
                control?.idleSeconds = idleSeconds;
                control?.expires = now().addingTimeInterval(idleSeconds)
            }
            if let client = args["client_id"].string, UUID(uuidString: client) != nil {
                control?.clientID = client;
                control?.clientName = String((args["client_name"].string ?? "MCP client").prefix(80))
            }
            control?.context = context
            diagnostic("ComputerUseStarted idleSeconds=\(Int(control!.idleSeconds))")
            do {
                controlChanged(true, "opened");
                return try await observe(
                    {
                        var v = args;
                        v["control_session_id"] = .string(control!.token);
                        return v
                    }(), owner: owner)
            } catch {
                endControl(reason: "capture_failed");
                throw error
            }
        case "observe":
            guard control?.busy != true else { throw ComputerUseError.message("computer_busy") };
            return try await observe(args, owner: owner)
        case "close":
            _ = try checked(args, owner: owner);
            endControl();
            return .object(["closed": .bool(true)])
        case "actions": return try await actions(args, owner: owner)
        default: throw ComputerUseError.message("unknown_operation")
        }
    }
    private func actions(_ args: JSONValue, owner: String) async throws -> JSONValue {
        var c = try checked(args, owner: owner)
        let request = args["request_id"].string ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: request) != nil else { throw ComputerUseError.message("request_id_must_be_uuid") }
        var body = args.object;
        for key in ["peer_id", "control_session_id", "observation_id", "request_id"] { body.removeValue(forKey: key) }
        let signature = try JSONValue.object(body).data()
        if let old = c.completed[request] {
            guard old.0 == signature else {
                throw ComputerUseError.message("request_id_reused_with_different_actions")
            };
            return old.1
        }
        guard !c.busy else {
            throw ComputerUseError.detailed(
                "computer_busy",
                .object([
                    "code": .string("computer_busy"), "retryable": .bool(true),
                    "next_step": .string("wait_then_observe"), "input_outcome": .string("not_attempted"),
                ]))
        }
        let observation = try args.required("observation_id")
        guard c.observation == observation else {
            throw ComputerUseError.detailed(
                "observation_id_mismatch",
                .object([
                    "code": .string("observation_id_mismatch"), "retryable": .bool(true),
                    "next_step": .string("observe_then_issue_new_request"),
                    "expected_observation_id": .string(c.observation), "input_outcome": .string("not_attempted"),
                ]))
        }
        guard case .array(let list) = args["actions"], (1...20).contains(list.count) else {
            throw ComputerUseError.message("invalid_action_batch_1_to_20_required")
        }
        try Self.validateObservationOptions(args);
        try Self.validateObservationBounds(args, width: c.width, height: c.height)
        let settle = try Self.integer(args, "settle_ms", default: 100, range: 0...5000)
        let checkpoint = try Self.integer(args, "checkpoint_after", default: list.count, range: 1...20)
        if args["expected_window_id"] != .null && args["expected_window_id"].string?.isEmpty != false {
            throw ComputerUseError.message("expected_window_id_must_be_nonempty_string")
        }
        if args["require_same_window"] != .null && args["require_same_window"] != .bool(true)
            && args["require_same_window"] != .bool(false)
        {
            throw ComputerUseError.message("require_same_window_must_be_boolean")
        }
        for item in list { try validate(item, c) }
        let budget = list.reduce(args["settle_ms"] == .null ? 0 : settle) { sum, item in
            sum + Int(item[item["type"].string == "wait" ? "milliseconds" : "duration_ms"].number ?? 0)
        }
        guard budget <= 30000 else { throw ComputerUseError.message("batch_wait_exceeds_30000_ms") }
        let expected =
            args["expected_window_id"].string ?? (args["require_same_window"] == .bool(true) ? c.lastWindowID : nil)
        if args["require_same_window"] == .bool(true) && expected == nil {
            throw ComputerUseError.message("foreground_window_identity_unavailable")
        }
        c.busy = true;
        c.observation = "";
        c.expires = now().addingTimeInterval(max(c.idleSeconds, 60));
        control = c
        let started = ContinuousClock.now;
        var count = 0, steps: [JSONValue] = [], failure: Error?
        for (index, item) in list.prefix(checkpoint).enumerated() {
            let stepStart = ContinuousClock.now;
            injectionAttempted = false;
            successfulInjectionCalls = 0;
            activeExpectedWindow = item["allow_window_change"] == .bool(true) ? nil : expected
            do {
                _ = try checked(args, owner: owner);
                try checkWindow(expected, allow: item["allow_window_change"] == .bool(true))
                try await apply(item, c, expectedWindow: item["allow_window_change"] == .bool(true) ? nil : expected);
                count += 1
                var step: JSONValue = .object([
                    "index": .number(Double(index)), "type": item["type"], "status": .string("completed"),
                    "duration_ms": .number(Self.elapsed(stepStart)), "injection_started": .bool(injectionAttempted),
                    "successful_injection_calls": .number(Double(successfulInjectionCalls)),
                ])
                if args["step_images"] == .bool(true) && index < 3 {
                    var options: JSONValue = .object(["thumbnail_max_dimension": .number(320)])
                    options["include_ocr"] = .bool(false);
                    options["include_controls"] = .bool(false)
                    step["screenshot"] = try await capture(try checked(args, owner: owner), options: options)
                }
                steps.append(step)
            } catch {
                marker(c.screen, 0, 0, "cancel");
                failure = error;
                var details = Self.errorDetails(error)
                details["input_outcome"] = .string(injectionAttempted ? "partial_or_unknown" : "not_attempted")
                steps.append(
                    .object([
                        "index": .number(Double(index)), "type": item["type"], "status": .string("interrupted"),
                        "duration_ms": .number(Self.elapsed(stepStart)), "injection_started": .bool(injectionAttempted),
                        "successful_injection_calls": .number(Double(successfulInjectionCalls)),
                        "error_details": details,
                    ]));
                break
            }
        }
        if control == nil || control?.token == c.token { releaseHeld() }
        var result: JSONValue = .object([
            "request_id": .string(request), "executed_actions": .number(Double(count)),
            "remaining_actions": .number(Double(list.count - count)),
            "execution_status": .string(
                failure != nil ? "interrupted" : count < list.count ? "checkpoint" : "injected"),
            "step_results": .array(steps),
        ])
        if let failure {
            result["error"] = .string(failure.localizedDescription);
            result["error_details"] = steps.last?["error_details"] ?? Self.errorDetails(failure)
        }
        do {
            try await checkedDelay(settle, c);
            result["observation"] = try await observe(args, owner: owner)
        } catch {
            result["observation_error"] = .string(error.localizedDescription);
            result["observation_error_details"] = Self.errorDetails(error)
        }
        result["action_to_observation_ms"] = .number(Self.elapsed(started))
        if control?.token == c.token {
            control?.busy = false;
            control?.lastResult = .object([
                "request_id": .string(request), "execution_status": result["execution_status"],
                "executed_actions": result["executed_actions"], "error": result["error"],
                "action_to_observation_ms": result["action_to_observation_ms"],
            ]);
            if control!.completed.count >= 4 { control?.completed = [:] };
            control?.completed[request] = (signature, result)
        }
        return result
    }
    private var injectionAttempted = false, successfulInjectionCalls = 0
    private var activeExpectedWindow: String?
    private func sendInput(_ input: CapturedInput, _ screen: ScreenGeometry?, _ x: Double, _ y: Double) throws {
        try checkWindow(activeExpectedWindow)
        if inputState?()["input_injection_blocked"] == .bool(true) {
            throw ComputerUseError.message("input_blocked_by_integrity_level:restart_ShareMouse_as_administrator")
        }
        injectionAttempted = true;
        try inject(input, screen, x, y);
        successfulInjectionCalls += 1
    }
    private func checkWindow(_ expected: String?, allow: Bool = false) throws {
        guard let expected, !allow else { return };
        let state = inputState?() ?? .null;
        let window =
            control?.context["mode"].string == "independent"
            ? state["control_target_window"] : state["foreground_window"];
        guard window["window_id"].string == expected else { throw ComputerUseError.message("target_window_changed") }
    }
    private func checkedDelay(_ milliseconds: Int, _ c: Control, expectedWindow: String? = nil) async throws {
        var remaining = milliseconds
        repeat {
            _ = try checked(.object(["control_session_id": .string(c.token)]), owner: c.owner);
            try checkWindow(expectedWindow)
            if remaining <= 0 { return };
            let step = min(50, remaining);
            try await Task.sleep(for: .milliseconds(step));
            remaining -= step
        } while true
    }
    private func point(_ action: JSONValue, _ c: Control) throws -> (Double, Double) {
        guard let x = action["x"].number, let y = action["y"].number, x.isFinite, y.isFinite, x >= 0, y >= 0,
            x < Double(c.width), y < Double(c.height)
        else { throw ComputerUseError.message("coordinate_outside_observation") };
        return (
            (c.region["x"].number ?? 0) + x / Double(c.width) * (c.region["width"].number ?? 1),
            (c.region["y"].number ?? 0) + y / Double(c.height) * (c.region["height"].number ?? 1)
        )
    }
    private func key(_ value: String) -> String {
        let aliases = [
            "CTRL": "ControlLeft", "CONTROL": "ControlLeft", "ALT": "AltLeft", "OPTION": "AltLeft",
            "SHIFT": "ShiftLeft", "CMD": "MetaLeft", "COMMAND": "MetaLeft", "WIN": "MetaLeft", "META": "MetaLeft",
            "ESC": "Escape", "RETURN": "Enter", "ENTER": "Enter", "SPACE": "Space",
        ]
        if let mapped = aliases[value.uppercased()] { return mapped };
        if value.count == 1, value.first!.isASCII {
            return value.first!.isNumber ? "Digit" + value : "Key" + value.uppercased()
        };
        return Self.keyNames.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) ?? value
    }
    private func validate(_ a: JSONValue, _ c: Control) throws {
        if c.context["mode"].string == "independent",
            ["focus_application", "move_relative", "drag", "double_click", "keypress", "key_hold", "scroll"].contains(
                a["type"].string ?? "")
        {
            throw ComputerUseError.message("independent_action_not_supported")
        }
        switch try a.required("type") {
        case "click", "double_click", "move", "scroll":
            _ = try point(a, c);
            if a["type"].string == "scroll" {
                guard let y = a["delta_y"].number, y.isFinite, abs(y) <= 10000, abs(a["delta_x"].number ?? 0) <= 10000
                else { throw ComputerUseError.message("invalid_scroll") }
            }
        case "drag":
            guard (2...100).contains(a["path"].array.count) else {
                throw ComputerUseError.message("invalid_drag_path")
            };
            for p in a["path"].array { _ = try point(p, c) }
        case "focus_application":
            guard let application = a["application"].string, !application.isEmpty, application.count <= 256 else {
                throw ComputerUseError.message("application_name_required")
            }
        case "keypress", "key_hold":
            guard (1...8).contains(a["keys"].array.count),
                a["keys"].array.allSatisfy({ $0.string.map { Self.keyNames.contains(key($0)) } == true })
            else { throw ComputerUseError.message("unsupported_key") }
        case "move_relative":
            guard let dx = a["dx"].number, let dy = a["dy"].number, dx.isFinite, dy.isFinite, abs(dx) <= 10000,
                abs(dy) <= 10000
            else { throw ComputerUseError.message("invalid_relative_movement") }
            _ = try Self.integer(a, "duration_ms", default: 0, range: 0...5000);
            _ = try Self.integer(a, "steps", default: 1, range: 1...100)
        case "type":
            guard let text = a["text"].string, !text.isEmpty, text.utf8.count <= 131072 else {
                throw ComputerUseError.message("invalid_text")
            }
        case "wait":
            guard let ms = a["milliseconds"].number, ms.isFinite, ms.rounded(.towardZero) == ms, ms >= 0, ms <= 30000
            else { throw ComputerUseError.message("wait_must_be_integer_0_to_30000_ms") }
        default: throw ComputerUseError.message("unsupported_action")
        }
        if c.context["mode"].string == "independent" {
            if a["button"].string != nil && a["button"].string != "left" {
                throw ComputerUseError.message("independent_action_not_supported")
            }
            let coordinate: [String] = (a["type"].string == "click" || a["type"].string == "move") ? ["x", "y"] : []
            let p = coordinate.isEmpty ? (0.0, 0.0) : try point(a, c)
            try validatePlatformAction(a, c.screen, p.0, p.1)
        }
        if a["allow_window_change"] != .null && a["allow_window_change"] != .bool(true)
            && a["allow_window_change"] != .bool(false)
        {
            throw ComputerUseError.message("invalid_allow_window_change")
        }
        if a["type"].string == "key_hold" { _ = try Self.integer(a, "duration_ms", default: 0, range: 1...5000) }
        if let button = a["button"].string, !["left", "right", "middle"].contains(button) {
            throw ComputerUseError.message("unsupported_button")
        }
    }
    // Preview draws only a cursor overlay. Native input still makes one endpoint move.
    private func preview(_ a: JSONValue, _ c: Control, expectedWindow: String?) async throws {
        let (x, y) = try point(a, c)
        let milliseconds = min(360, max(0, pointerPreview(c.screen, x, y, a["type"].string ?? "move")))
        if milliseconds > 0 { try await checkedDelay(milliseconds, c, expectedWindow: expectedWindow) }
    }
    private func move(_ a: JSONValue, _ c: Control, kind: String) throws {
        let (x, y) = try point(a, c);
        try sendInput(CapturedInput("move"), c.screen, x, y);
        marker(c.screen, x, y, kind)
    }
    private func apply(_ a: JSONValue, _ c: Control, expectedWindow: String?) async throws {
        let button = ["left": 0, "right": 1, "middle": 2][a["button"].string ?? "left"] ?? 0
        switch a["type"].string {
        case "move":
            try await preview(a, c, expectedWindow: expectedWindow);
            try move(a, c, kind: "move")
        case "click", "double_click":
            try await preview(a, c, expectedWindow: expectedWindow);
            try move(a, c, kind: "position")
            for index in 0..<(a["type"].string == "double_click" ? 2 : 1) {
                guard control?.token == c.token else { throw ComputerUseError.message("control_interrupted") };
                heldButtons.insert(button);
                try sendInput(CapturedInput("buttonDown", button: button, clickCount: index + 1), nil, 0, 0);
                try sendInput(CapturedInput("buttonUp", button: button, clickCount: index + 1), nil, 0, 0);
                heldButtons.remove(button);
                marker(c.screen, try point(a, c).0, try point(a, c).1, "click");
                try await Task.sleep(for: .milliseconds(40))
            }
        case "drag":
            try move(a["path"].array[0], c, kind: "drag");
            heldButtons.insert(button);
            try sendInput(CapturedInput("buttonDown", button: button), nil, 0, 0)
            for p in a["path"].array.dropFirst() {
                guard control?.token == c.token else { throw ComputerUseError.message("control_interrupted") };
                try checkWindow(expectedWindow);
                try move(p, c, kind: "drag");
                try await Task.sleep(for: .milliseconds(16))
            }
            try sendInput(CapturedInput("buttonUp", button: button), nil, 0, 0);
            heldButtons.remove(button)
        case "scroll":
            try await preview(a, c, expectedWindow: expectedWindow);
            try move(a, c, kind: "scroll");
            try sendInput(
                CapturedInput("scroll", deltaX: a["delta_x"].number ?? 0, deltaY: a["delta_y"].number ?? 0), nil, 0, 0)
        case "move_relative":
            marker(c.screen, 0, 0, "relative")
            let duration = try Self.integer(a, "duration_ms", default: 0, range: 0...5000)
            let steps = try Self.integer(a, "steps", default: max(1, min(100, duration / 16)), range: 1...100)
            let dx = a["dx"].number ?? 0, dy = a["dy"].number ?? 0
            for index in 0..<steps {
                _ = try checked(.object(["control_session_id": .string(c.token)]), owner: c.owner);
                try checkWindow(expectedWindow)
                let before = Double(index) / Double(steps), after = Double(index + 1) / Double(steps)
                let x = (dx * after).rounded() - (dx * before).rounded(),
                    y = (dy * after).rounded() - (dy * before).rounded()
                try sendInput(CapturedInput("relativeMove", deltaX: x, deltaY: y), c.screen, 0, 0)
                if duration > 0 {
                    try await checkedDelay(
                        duration / steps + (index < duration % steps ? 1 : 0), c, expectedWindow: expectedWindow)
                }
            }
        case "focus_application":
            try await focusApplication(a.required("application"));
            _ = try checked(.object(["control_session_id": .string(c.token)]), owner: c.owner)
        case "keypress", "key_hold":
            let keys = a["keys"].array.compactMap(\.string).map(key);
            for value in keys {
                heldKeys.insert(value);
                try sendInput(CapturedInput("keyDown", key: value), nil, 0, 0)
            };
            if a["type"].string == "key_hold" {
                try await checkedDelay(
                    try Self.integer(a, "duration_ms", default: 0, range: 1...5000), c, expectedWindow: expectedWindow)
            };
            for value in keys.reversed() {
                try sendInput(CapturedInput("keyUp", key: value), nil, 0, 0);
                heldKeys.remove(value)
            }
        case "type":
            var part = "";
            for scalar in a["text"].string!.unicodeScalars {
                let next = String(scalar);
                if part.utf8.count + next.utf8.count > 4096 {
                    try sendInput(CapturedInput("text", text: part), nil, 0, 0);
                    part = ""
                };
                part += next
            };
            if !part.isEmpty { try sendInput(CapturedInput("text", text: part), nil, 0, 0) }
        case "wait": try await checkedDelay(Int(a["milliseconds"].number!), c, expectedWindow: expectedWindow)
        default: throw ComputerUseError.message("unsupported_action")
        }
    }
    private func releaseHeld() {
        for b in heldButtons { try? inject(CapturedInput("buttonUp", button: b), nil, 0, 0) };
        for k in heldKeys { try? inject(CapturedInput("keyUp", key: k), nil, 0, 0) };
        heldKeys = [];
        heldButtons = []
    }
    public static let keyNames: Set<String> = Set(
        (65...90).map { "Key" + String(UnicodeScalar($0)!) } + (0...9).map { "Digit\($0)" } + (1...12).map { "F\($0)" }
            + [
                "Enter", "Tab", "Space", "Backspace", "Escape", "Delete", "Home", "End", "PageUp", "PageDown",
                "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "ControlLeft", "ControlRight", "AltLeft", "AltRight",
                "ShiftLeft", "ShiftRight", "MetaLeft", "MetaRight", "Minus", "Equal", "BracketLeft", "BracketRight",
                "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash", "Backquote",
            ])
    public func tool(_ name: String, arguments a: JSONValue) async throws -> JSONValue {
        activity()
        if name == "list_computers" {
            var peers: [JSONValue] = [
                .object([
                    "peer_id": .string(id), "name": .string(self.name), "platform": info()["platform"],
                    "local": .bool(true),
                ])
            ]
            for s in await manager.currentSessions() {
                peers.append(
                    .object([
                        "peer_id": .string(s.peerID), "name": .string(s.name), "platform": .string(s.remotePlatform),
                        "capabilities": try .encoded(s.capabilities), "local": .bool(false),
                    ]))
            };
            return .array(peers)
        }
        if name == "send_files" {
            let prepared = try await call(a.required("source_peer_id"), operation: "prepare_files", arguments: a)
            var receive = a;
            receive["entry_id"] = prepared["entry_id"];
            receive["source_peer_id"] = prepared["source_peer_id"]
            return try await call(a.required("target_peer_id"), operation: "paste_files", arguments: receive)
        }
        let operation = [
            "get_computer_info": "info", "get_control_status": "status", "open_computer": "open",
            "observe_computer": "observe", "computer_action": "actions", "release_input": "close",
            "close_computer": "close", "list_transfers": "transfers", "get_transfer": "transfers",
            "control_transfer": "transfer_action",
        ][name]
        guard let operation else { throw ComputerUseError.message("unknown_tool") };
        return try await call(a.required("peer_id"), operation: operation, arguments: a)
    }
}

public extension ComputerUseService {
    static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let value = (ContinuousClock.now - start).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
    static func integer(_ value: JSONValue, _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int
    {
        guard value[key] != .null else {
            guard range.contains(fallback) else { throw ComputerUseError.message("missing_" + key) };
            return fallback
        }
        guard let n = value[key].number, n.isFinite, n.rounded(.towardZero) == n, n >= Double(range.lowerBound),
            n <= Double(range.upperBound)
        else { throw ComputerUseError.message("invalid_" + key) };
        return Int(n)
    }
    static func validateObservationOptions(_ value: JSONValue) throws {
        for key in [
            "include_ocr", "include_controls", "wait_for_stable", "mark_cursor", "step_images", "text_only",
            "read_screen",
        ] {
            if value[key] != .null && value[key] != .bool(true) && value[key] != .bool(false) {
                throw ComputerUseError.message("invalid_" + key)
            }
        }
        _ = try integer(value, "stability_timeout_ms", default: 2000, range: 200...5000)
        _ = try integer(value, "stability_interval_ms", default: 200, range: 100...1000)
        _ = try integer(value, "stability_samples", default: 3, range: 2...5)
        if value["control_mode"] != .null
            && !["user_mouse", "independent"].contains(value["control_mode"].string ?? "")
        {
            throw ComputerUseError.message("invalid_control_mode")
        }
        _ = try integer(value, "max_dimension", default: 0, range: 0...16384)
        _ = try integer(value, "jpeg_quality", default: 80, range: 1...100)
        if value["image_format"] != .null && !["png", "jpeg"].contains(value["image_format"].string ?? "") {
            throw ComputerUseError.message("invalid_image_format")
        }
        if value["text_only"] == .bool(true)
            && (value["wait_for_stable"] == .bool(true) || value["mark_cursor"] == .bool(true)
                || value["preview_point"] != .null)
        {
            throw ComputerUseError.message("text_only_incompatible_with_image_analysis")
        }
        if value["capture_region"] != .null {
            let r = value["capture_region"]
            for field in ["x", "y", "width", "height"] {
                guard let n = r[field].number, n.isFinite, n >= 0, n <= 1 else {
                    throw ComputerUseError.message("invalid_capture_region")
                }
            }
            guard r["width"].number! > 0, r["height"].number! > 0, r["x"].number! + r["width"].number! <= 1.0000001,
                r["y"].number! + r["height"].number! <= 1.0000001
            else { throw ComputerUseError.message("invalid_capture_region") }
        }
        _ = try integer(value, "max_controls", default: 50, range: 1...100)
        _ = try integer(value, "max_ocr_results", default: 100, range: 1...200)
        if let n = value["stability_threshold"].number {
            guard n.isFinite, n >= 0, n <= 25 else { throw ComputerUseError.message("invalid_stability_threshold") }
        } else if value["stability_threshold"] != .null {
            throw ComputerUseError.message("invalid_stability_threshold")
        }
        for key in ["ocr_region", "stability_region"] where value[key] != .null {
            for field in ["x", "y", "width", "height"] {
                guard let n = value[key][field].number, n.isFinite, n >= (field == "x" || field == "y" ? 0 : 1),
                    n <= 10000
                else { throw ComputerUseError.message("invalid_" + key) }
            }
        }
        for key in ["preview_point", "control_point"] where value[key] != .null {
            for field in ["x", "y"] {
                guard let n = value[key][field].number, n.isFinite, n >= 0, n <= 10000 else {
                    throw ComputerUseError.message("invalid_" + key)
                }
            }
        }
        if value["ocr_language"] != .null {
            guard let text = value["ocr_language"].string, !text.isEmpty, text.utf8.count <= 64 else {
                throw ComputerUseError.message("invalid_ocr_language")
            }
        }
    }
    static func validateObservationBounds(_ value: JSONValue, width: Int, height: Int) throws {
        for key in ["ocr_region", "stability_region"] where value[key] != .null {
            if (value[key]["x"].number ?? 0) + (value[key]["width"].number ?? 0) > Double(width)
                || (value[key]["y"].number ?? 0) + (value[key]["height"].number ?? 0) > Double(height)
            {
                throw ComputerUseError.message("analysis_region_outside_observation")
            }
        }
        for key in ["preview_point", "control_point"] where value[key] != .null {
            if (value[key]["x"].number ?? 0) >= Double(width) || (value[key]["y"].number ?? 0) >= Double(height) {
                throw ComputerUseError.message(key + "_outside_observation")
            }
        }
    }
    static func coordinates(_ image: JSONValue) -> JSONValue {
        let rect = image["desktop_bounds"]
        guard let dw = rect["width"].number, let dh = rect["height"].number, let sw = image["width"].number,
            let sh = image["height"].number, dw > 0, dh > 0, sw > 0, sh > 0
        else {
            return .object([
                "status": .string("unavailable"),
                "screenshot_size": .object(["width": image["width"], "height": image["height"]]),
            ])
        }
        return .object([
            "status": .string("available"),
            "screenshot_size": .object(["width": image["width"], "height": image["height"]]), "desktop_bounds": rect,
            "desktop_coordinate_space": image["desktop_coordinate_space"],
            "display_pixel_size": image["display_pixel_size"],
            "normalized_capture_region": image["normalized_capture_region"],
            "desktop_origin": .object(["x": rect["x"], "y": rect["y"]]),
            "screenshot_pixels_per_desktop_unit": .object(["x": .number(sw / dw), "y": .number(sh / dh)]),
            "desktop_units_per_screenshot_pixel": .object(["x": .number(dw / sw), "y": .number(dh / sh)]),
        ])
    }
    static func mapCursor(_ cursor: JSONValue, image: JSONValue) -> JSONValue {
        guard let x = cursor["x"].number, let y = cursor["y"].number, let left = image["desktop_bounds"]["x"].number,
            let top = image["desktop_bounds"]["y"].number, let width = image["desktop_bounds"]["width"].number,
            let height = image["desktop_bounds"]["height"].number, width > 0, height > 0
        else { return .null }
        let inside = x >= left && y >= top && x < left + width && y < top + height
        return .object([
            "coordinate_space": .string("screenshot_pixels"), "inside_screen": .bool(inside),
            "x": inside ? .number((x - left) / width * (image["width"].number ?? 0)) : .null,
            "y": inside ? .number((y - top) / height * (image["height"].number ?? 0)) : .null,
        ])
    }
    static func errorDetails(_ error: Error) -> JSONValue {
        if case ComputerUseError.detailed(_, let details) = error, details != .null { return details }
        let message = error.localizedDescription
        var code = message.components(separatedBy: ":").first ?? "native_failure"
        if code == "control_session_unavailable" {
            code = message.components(separatedBy: ":").dropFirst().first ?? code
        }
        let retryable = [
            "computer_busy", "observation_id_mismatch", "target_window_changed", "lease_expired",
            "computer_control_in_use", "desktop_locked_or_unavailable",
        ].contains(code)
        let next =
            code == "user_exit"
            ? "wait_for_user_authorization"
            : code == "computer_busy"
                ? "wait_then_observe"
                : code == "computer_control_in_use"
                    ? "use_existing_session_or_wait_for_release"
                    : code == "desktop_locked_or_unavailable"
                        ? "wait_for_user_to_unlock_desktop"
                        : code == "input_permission_missing"
                            ? "ask_user_to_grant_input_permission"
                            : code == "input_monitoring_permission_missing"
                                ? "ask_user_to_grant_input_monitoring_permission"
                                : code == "screen_capture_permission_missing"
                                    ? "ask_user_to_grant_screen_capture_permission"
                                    : code == "lease_expired"
                                        ? "open_new_session"
                                        : code == "input_blocked_by_integrity_level"
                                            ? "ask_user_to_restart_as_administrator"
                                            : retryable
                                                ? "observe_then_issue_new_request" : "inspect_error_before_retry"
        return .object([
            "code": .string(code), "message": .string(message), "retryable": .bool(retryable),
            "next_step": .string(next),
        ])
    }
}
