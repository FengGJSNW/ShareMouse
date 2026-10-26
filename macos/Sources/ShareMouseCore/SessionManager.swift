import Darwin
import Foundation
@preconcurrency import Network

private final class InputLinkPreference: @unchecked Sendable {
    private let lock = NSLock();
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func read() -> Bool { lock.withLock { value } }
    func set(_ next: Bool) { lock.withLock { value = next } }
}
public actor SessionManager {
    private nonisolated let inputLinkPreference: InputLinkPreference
    // Legacy name kept for saved preferences; this now means Bluetooth preferred.
    public nonisolated var bluetoothInputOnly: Bool { inputLinkPreference.read() }
    public func setInputLinkPreference(bluetooth: Bool) {
        inputLinkPreference.set(bluetooth);
        for id in routePolicies.keys { routePolicies[id]?.resetPreference() }
    }
    public let localID: String
    public nonisolated let discoveryName = UUID().uuidString
    private let name: String
    private let identity: IdentityKeychain
    private let registry: PeerRegistry
    private let queue = DispatchQueue(label: "ShareMouse.TLS", qos: .userInteractive)
    private var listener: NWListener?
    private var bluetoothListener: NWListener?
    private var quicListener: NWListener?
    private var bleCheckStarted = false
    private var links: [String: [String: SecureNetwork]] = [:]
    private var sessions: [String: SessionInfo] = [:]
    private var sent: [String: UInt64] = [:]
    private var routePolicies: [String: InputRoutePolicy] = [:]
    private var heartbeatSent: [ObjectIdentifier: Double] = [:]
    private var lastSeen: [ObjectIdentifier: Date] = [:]
    private let instanceID = UUID().uuidString.lowercased()
    private var remoteInstances: [String: String] = [:]
    private var pendingHandshakes: [String: Int] = [:]
    private var linkInitiators: [ObjectIdentifier: String] = [:]
    private var receivers: [String: @Sendable (String, Data, SecureNetwork) async -> Void] = [:]
    private var pairCode: String
    private var password: String
    private var authorizedGroup: String?
    private var groupMembers: Set<String> = []
    public private(set) var listenPort: UInt16 = 49160
    private var applicationCapabilities: Set<String> = [
        "network-endpoints-v1", "compact-diagnostics-v1", "background-flow-v1", "throughput-test-v1", "compact-data-v1",
        "bulk-fragments-v1", "adaptive-file-window-v1",
    ]
    private var remoteCapabilities: [String: Set<String>] = [:]
    private var remoteCapabilitySequences: [String: UInt64] = [:]
    private var bulkNetworkDeadline: [String: ContinuousClock.Instant] = [:]
    private var traffic: [String: (sent: Int, sentBytes: Int, received: Int, receivedBytes: Int)] = [:]
    private var trafficReportAt = ProcessInfo.processInfo.systemUptime
    private var probeTimes:
        [String: (run: String, kind: String, index: Int, peer: String, at: ContinuousClock.Instant)] = [:]
    private var probeResults: [String: [String: [LatencySample]]] = [:]
    private var failedAttempts: [Date] = []
    private var declinedConnections: Set<String> = []
    private let confirmCertificate: @Sendable (CertificatePeer) async -> Bool
    private let confirmConnection: @Sendable (String) async -> Bool
    private let confirmBluetoothConnection: @Sendable (String) async -> Bool
    private let confirmPeerConnection: (@Sendable (String, String, Bool) async -> Bool)?
    private let changed: @Sendable ([SessionInfo]) -> Void
    private let event: @Sendable (String) -> Void

    public init(
        localID: String, name: String, identity: IdentityKeychain, registry: PeerRegistry, pairCode: String,
        password: String, confirmCertificate: @escaping @Sendable (CertificatePeer) async -> Bool,
        confirmConnection: @escaping @Sendable (String) async -> Bool,
        changed: @escaping @Sendable ([SessionInfo]) -> Void, event: @escaping @Sendable (String) -> Void,
        confirmBluetoothConnection: (@Sendable (String) async -> Bool)? = nil,
        confirmPeerConnection: (@Sendable (String, String, Bool) async -> Bool)? = nil, bluetoothInputOnly: Bool? = nil
    ) {
        self.inputLinkPreference = InputLinkPreference(
            bluetoothInputOnly ?? ProcessInfo.processInfo.arguments.contains("--bluetooth-input"))
        self.localID = localID;
        self.name = name;
        self.identity = identity;
        self.registry = registry
        self.pairCode = pairCode;
        self.password = password
        self.confirmCertificate = confirmCertificate;
        self.confirmConnection = confirmConnection
        self.confirmBluetoothConnection = confirmBluetoothConnection ?? confirmConnection
        self.confirmPeerConnection = confirmPeerConnection
        self.changed = changed;
        self.event = event
    }

    private var recoveryStopped = false
    private var recoveryBusy = false
    private var recoveryNext: [String: Date] = [:]
    private var recoveryFailures: [String: Int] = [:]
    private var recoveryIndex: [String: Int] = [:]
    private var networkHints: [String: NetworkAdvertisement] = [:]
    private var networkAdvertised: [String: Data] = [:]
    private var networkAdvertising: Set<String> = []

    private func advertiseNetwork(to peer: String, force: Bool = false) async {
        guard !recoveryStopped, sessions[peer]?.capabilities.contains("network-endpoints-v1") == true,
            !networkAdvertising.contains(peer)
        else { return }
        let value = NetworkAdvertisement(
            enabled: networkAvailable, endpoints: networkAvailable ? NetworkEndpoint.local(port: listenPort) : [])
        let encoder = JSONEncoder();
        encoder.outputFormatting = .sortedKeys
        guard let payload = try? encoder.encode(value), force || networkAdvertised[peer] != payload else { return }
        networkAdvertising.insert(peer);
        defer { networkAdvertising.remove(peer) }
        do {
            _ = try await sendFrame(
                "data", peerID: peer, channel: "network-endpoints", payload: payload,
                transport: links[peer]?["ble"] ?? links[peer]?["tcp"])
            networkAdvertised[peer] = payload
        } catch { event("NetworkAdvertisementFailed peerId=\(peer)") }
    }
    private func receiveNetworkAdvertisement(peer: String, payload: Data) {
        guard payload.count <= 2048, registry.find(peer) != nil,
            sessions[peer]?.capabilities.contains("network-endpoints-v1") == true,
            let value = try? JSONDecoder().decode(NetworkAdvertisement.self, from: payload), value.endpoints.count <= 8,
            value.endpoints.allSatisfy({ $0.valid() })
        else { return }
        let old = networkHints[peer]
        networkHints[peer] = value
        if old?.enabled != value.enabled || old?.endpoints != value.endpoints {
            recoveryNext.removeValue(forKey: peer);
            recoveryFailures[peer] = 0;
            recoveryIndex[peer] = 0
            event("NetworkEndpointsUpdated peerId=\(peer) count=\(value.endpoints.count) enabled=\(value.enabled)")
        }
    }
    /// Called by the existing background connection loop; no second reconnect timer.
    public func recoverNetworkLinks(excluding suppressed: Set<String> = []) async {
        guard !recoveryBusy, !recoveryStopped else { return }
        recoveryBusy = true;
        defer { recoveryBusy = false }
        for peer in Array(sessions.keys) { await advertiseNetwork(to: peer) }
        guard networkAvailable, !recoveryStopped else { return }
        for peer in registry.all() where !suppressed.contains(peer.peerID) && !declinedConnections.contains(peer.peerID)
        {
            let id = peer.peerID
            guard links[id]?["tcp"] == nil, (peer.trust == .trusted && peer.autoConnect) || sessions[id] != nil,
                sessions[id] == nil || networkHints[id]?.enabled != false
            else { continue }
            var endpoints: [NetworkEndpoint] = []
            if let host = sessions[id]?.lanHost {
                endpoints.append(NetworkEndpoint(host: host, port: sessions[id]?.listenPort ?? 49160))
            }
            let cached = peer.networkEndpoints ?? []
            endpoints += cached.prefix(1);
            endpoints += networkHints[id]?.endpoints ?? [];
            endpoints += cached.dropFirst()
            endpoints = endpoints.filter { $0.valid(allowLoopback: true) }.reduce(into: []) {
                if !$0.contains($1), $0.count < 8 { $0.append($1) }
            }
            guard !endpoints.isEmpty else { continue }
            if recoveryNext[id] == nil, localID > id {
                recoveryNext[id] = Date().addingTimeInterval(5);
                continue
            }
            guard (recoveryNext[id] ?? .distantPast) <= Date() else { continue }
            let index = recoveryIndex[id, default: 0];
            let endpoint = endpoints[index % endpoints.count]
            recoveryIndex[id] = index + 1
            recoveryNext[id] = Date().addingTimeInterval(30)
            event("NetworkRecoveryAttempt peerId=\(id) host=\(endpoint.host) port=\(endpoint.port)")
            do {
                _ = try await connect(
                    endpoint: .hostPort(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!),
                    pairCode: nil, password: nil, autoOnly: true, expectedPeerID: id, timeout: 4)
                recoveryFailures[id] = 0
                event("NetworkRecoveryConnected peerId=\(id)")
            } catch {
                let failures = min(recoveryFailures[id, default: 0] + 1, 5);
                recoveryFailures[id] = failures
                let delay = min(30, pow(2, Double(failures)))
                recoveryNext[id] = Date().addingTimeInterval(delay)
                let problem = error as NSError
                event(
                    "NetworkRecoveryFailed peerId=\(id) retrySeconds=\(Int(delay)) domain=\(problem.domain) code=\(problem.code)"
                )
            }
            if recoveryStopped { return }
        }
    }

    private var bluetoothAvailable = true
    public func setBluetoothAvailable(_ enabled: Bool) { bluetoothAvailable = enabled }
    private var networkAvailable = true
    public func setNetworkAvailable(_ enabled: Bool) {
        networkAvailable = enabled
        listener?.service = enabled ? NWListener.Service(name: discoveryName, type: "_sharemouse._tcp") : nil
    }

    public func updateCredentials(pairCode: String, password: String) throws {
        guard pairCode.count == 6, pairCode.allSatisfy(\.isASCII), pairCode.allSatisfy(\.isNumber) else {
            throw PairingError.invalidMessage
        }
        self.pairCode = pairCode;
        self.password = password
    }

    public func start(port: UInt16 = 49160) throws {
        listenPort = port
        let registry = self.registry
        let parameters = SecureNetwork.parameters(
            identity: identity,
            verify: { peer, done in
                // Unknown inbound identities are quarantined until PairCode/Password and explicit approval succeed.
                if let stored = registry.find(peer.peerID) {
                    done(stored.publicKey == peer.publicKey)
                } else {
                    done(true)
                }
            }, queue: queue)
        let created = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        created.service = networkAvailable ? NWListener.Service(name: discoveryName, type: "_sharemouse._tcp") : nil
        created.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        created.stateUpdateHandler = { [event] state in
            switch state {
            case .ready: event("ListenerReady transport=tcp")
            case .failed: event("ListenerFailed transport=tcp")
            default: break
            }
        }
        listener = created
        created.start(queue: queue)
    }

    public func startBluetoothListener(port: UInt16 = 49165) throws {
        guard bluetoothListener == nil else { return }
        let registry = self.registry
        let parameters = SecureNetwork.parameters(
            identity: identity,
            verify: { peer, done in done(registry.find(peer.peerID).map { $0.publicKey == peer.publicKey } ?? true) },
            queue: queue)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
        let created = try NWListener(using: parameters)
        created.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection, kind: "ble") }
        }
        created.start(queue: queue);
        bluetoothListener = created
    }

    public func startQuicListener(port: UInt16 = 49164) throws {
        guard quicListener == nil else { return }
        let registry = self.registry
        let parameters = SecureNetwork.parameters(
            identity: identity,
            verify: { peer, done in done(registry.find(peer.peerID).map { $0.publicKey == peer.publicKey } ?? true) },
            queue: queue, kind: "quic")
        let created = try NWListener(using: parameters, on: .init(rawValue: port)!)
        created.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection, kind: "quic") }
        }
        created.stateUpdateHandler = { [event] state in
            if case .ready = state {
                event("ListenerReady transport=quic")
            } else if case .failed = state {
                event("QUICUnavailable")
            }
        }
        quicListener = created;
        created.start(queue: queue)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 172 && (16...31).contains(parts[1]) || parts[0] == 192 && parts[1] == 168
            || parts[0] == 169 && parts[1] == 254
    }

    @discardableResult public func connect(
        endpoint: NWEndpoint, pairCode: String?, password: String?, autoOnly: Bool = false, kind: String = "tcp",
        groupID: String? = nil, expectedPeerID: String? = nil, timeout: TimeInterval? = nil, quickOnly: Bool = false,
        directLAN: Bool = true
    ) async throws -> String {
        let registry = self.registry
        let connected = Set(sessions.keys)
        let allowedMembers = groupMembers
        let groupAllowed = groupID != nil && authorizedGroup == groupID
        let parameters = SecureNetwork.parameters(
            identity: identity,
            verify: { peer, done in
                if let expectedPeerID, peer.peerID != expectedPeerID {
                    done(false);
                    return
                }
                if let stored = registry.find(peer.peerID) {
                    done(
                        stored.publicKey == peer.publicKey
                            && (!autoOnly || connected.contains(peer.peerID)
                                || groupAllowed && allowedMembers.contains(peer.peerID)
                                || stored.trust == .trusted && stored.autoConnect)
                    )
                } else {
                    done(!autoOnly)
                }  // Quarantine only; no credentials sent before explicit key verification below.
            }, queue: queue, kind: kind)
        var physical = false
        if directLAN, kind != "ble", case .hostPort(let host, _) = endpoint,
            Self.isPrivateIPv4(String(describing: host))
        {
            // Excluding .other alone leaves an unsatisfied route while a TUN
            // owns the default path. Require Wi-Fi for the first LAN attempt.
            // Ethernet/VPN-only environments retain the normal-path fallback.
            parameters.requiredInterfaceType = .wifi;
            physical = true
        }
        let transport = SecureNetwork(
            connection: NWConnection(to: endpoint, using: parameters), queue: queue, kind: kind)
        do {
            do { try await transport.startAsync(timeout: physical ? min(timeout ?? 4, 4) : timeout) } catch {
                transport.cancel()
                if physical {
                    event("NetworkDirectPathUnavailable transport=\(kind)");
                    return try await connect(
                        endpoint: endpoint, pairCode: pairCode, password: password, autoOnly: autoOnly, kind: kind,
                        groupID: groupID, expectedPeerID: expectedPeerID, timeout: timeout, quickOnly: quickOnly,
                        directLAN: false)
                }
                throw error
            }
            if kind != "ble" {
                event(
                    "NetworkPath transport=\(kind) direct=\(physical) local=\(transport.localHost ?? "unknown") interfaces=\(transport.pathDescription)"
                )
            }
            if kind == "quic" { try await transport.streamPreface(incoming: false) }
            guard let certificate = transport.certificate, certificate.peerID != localID else {
                throw PairingError.invalidMessage
            }
            if links[certificate.peerID]?[kind] != nil {
                transport.cancel();
                return certificate.peerID
            }
            let hello = try await transport.receiveAsync()
            try validate(hello, certificate: certificate)
            guard hello.type == "hello", hello.capabilities?.contains(kind) == true else {
                throw PairingError.invalidMessage
            }
            let stored = registry.find(certificate.peerID)
            if quickOnly, stored == nil || hello.mode != "trusted" { throw PairingError.authenticationFailed }
            let attaching =
                stored != nil && sessions[certificate.peerID]?.sessionID == hello.sessionID && hello.sessionID != nil
            let groupJoining = groupAllowed && allowedMembers.contains(certificate.peerID) && stored != nil
            let known = stored != nil && hello.mode == "known" && pairCode == nil && password == nil
            let trusted = stored != nil && hello.mode == "trusted" && pairCode == nil && password == nil
            if autoOnly && !trusted && !known && !attaching && !groupJoining { throw PairingError.authenticationFailed }
            if kind == "ble", let pairCode, !pairCode.isEmpty, hello.pairCode != pairCode {
                throw PairingError.authenticationFailed
            }
            if !autoOnly {
                declinedConnections.remove(certificate.peerID)
            } else if declinedConnections.contains(certificate.peerID) {
                throw PairingError.authenticationFailed
            }
            if stored == nil && kind != "ble" {
                guard await confirmCertificate(certificate) else { throw PairingError.authenticationFailed }
            }
            var request = message("pair", target: certificate.peerID)
            request.mode =
                attaching
                ? "attach"
                : groupJoining
                    ? "group" : trusted ? "trusted" : known ? "known" : kind == "ble" ? "bluetooth" : "password"
            request.autoConnection = autoOnly
            request.sessionID = attaching ? hello.sessionID : nil
            request.groupID = groupJoining ? groupID : nil
            request.listenPort = listenPort
            request.pairCode = trusted || known || attaching || groupJoining ? nil : pairCode
            request.password = trusted || known || attaching || groupJoining ? nil : password
            request.instanceID = instanceID
            request.name = name;
            request.platform = "macOS";
            request.capabilities = Array(applicationCapabilities.union([kind]))
            try await transport.sendAsync(request)
            let response = try await transport.receiveAsync()
            try validate(response, certificate: certificate)
            guard response.type == "accepted", let id = response.sessionID, UUID(uuidString: id) != nil else {
                if response.error == "connectionDeclined", autoOnly { declinedConnections.insert(certificate.peerID) }
                throw PairingError.authenticationFailed
            }
            var ready = message("ready", target: certificate.peerID)
            ready.sessionID = id
            try await transport.sendAsync(ready)
            let established = try await transport.receiveAsync()
            try validate(established, certificate: certificate)
            guard established.type == "established", established.sessionID == id else {
                throw PairingError.authenticationFailed
            }
            try registry.remember(certificate, name: hello.name ?? certificate.peerID)
            var info = SessionInfo(
                sessionID: id, peerID: certificate.peerID, name: hello.name ?? certificate.peerID,
                capabilities: Array(Set(hello.capabilities ?? []).intersection(applicationCapabilities.union([kind]))),
                initiatorPeerID: localID)
            info.listenPort = hello.listenPort ?? 49160;
            info.remotePlatform = hello.platform?.lowercased() ?? "unknown"
            register(
                transport, info: info, remoteCaps: hello.capabilities ?? [], attaching: attaching,
                remoteInstance: hello.instanceID)
            return certificate.peerID
        } catch {
            transport.cancel();
            throw error
        }
    }

    private func accept(_ connection: NWConnection, kind: String = "tcp") async {
        let transport = SecureNetwork(connection: connection, queue: queue, kind: kind)
        var handshakeStep = "tls"
        do {
            try await transport.startAsync()
            guard kind == "ble" ? bluetoothAvailable : networkAvailable else { throw PairingError.authenticationFailed }
            handshakeStep = "stream"
            if kind == "quic" { try await transport.streamPreface(incoming: true) }
            guard let certificate = transport.certificate, certificate.peerID != localID else {
                throw PairingError.invalidMessage
            }
            pendingHandshakes[certificate.peerID, default: 0] += 1
            defer { finishHandshake(certificate.peerID) }
            let stored = registry.find(certificate.peerID)
            var hello = message("hello", target: certificate.peerID)
            hello.name = name;
            hello.platform = "macOS";
            hello.capabilities = Array(applicationCapabilities.union([kind]))
            hello.listenPort = listenPort;
            hello.instanceID = instanceID
            hello.sessionID = sessions[certificate.peerID]?.sessionID
            hello.mode =
                stored?.trust == .trusted
                ? "trusted" : stored != nil ? "known" : kind == "ble" ? "bluetooth" : "password"
            // BLE code locates the selected device; approval authenticates it.
            hello.pairCode = kind == "ble" ? pairCode : nil
            handshakeStep = "hello"
            try await transport.sendAsync(hello)
            handshakeStep = "pair"
            let request = try await transport.receiveAsync()
            try validate(request, certificate: certificate)
            guard request.type == "pair",
                ["password", "trusted", "known", "attach", "group", "bluetooth"].contains(request.mode ?? "")
            else { throw PairingError.invalidMessage }
            guard (request.mode != "bluetooth" || kind == "ble"),
                (kind == "ble" ? bluetoothAvailable : networkAvailable)
            else { throw PairingError.invalidMessage }
            if request.autoConnection != true { declinedConnections.remove(certificate.peerID) }
            let accepted: Bool
            if request.mode == "bluetooth" {
                failedAttempts.removeAll { Date().timeIntervalSince($0) >= 60 }
                let correct =
                    failedAttempts.count < 5 && (request.pairCode == nil || equalSecret(request.pairCode, pairCode))
                    && equalSecret(request.password, password)
                if !correct { failedAttempts.append(Date()) }
                accepted =
                    correct
                    ? await approveConnection(
                        certificate.peerID, name: request.name ?? certificate.peerID, bluetooth: true) : false
            } else if request.mode == "group" {
                let authorized =
                    stored != nil && request.groupID != nil && request.groupID == authorizedGroup
                    && groupMembers.contains(certificate.peerID)
                accepted =
                    authorized
                    ? await approveConnection(
                        certificate.peerID, name: stored?.name ?? certificate.peerID, bluetooth: kind == "ble") : false
            } else if request.mode == "attach" {
                accepted =
                    stored != nil && request.sessionID != nil
                    && request.sessionID == sessions[certificate.peerID]?.sessionID
            } else if request.mode == "known" {
                if stored?.publicKey == certificate.publicKey {
                    accepted = await approveConnection(
                        certificate.peerID, name: stored?.name ?? certificate.peerID, bluetooth: kind == "ble")
                } else {
                    accepted = false
                }
            } else if request.mode == "trusted" {
                if stored?.trust != .trusted || stored?.publicKey != certificate.publicKey {
                    accepted = false
                } else {
                    accepted = await approveConnection(
                        certificate.peerID, name: stored?.name ?? certificate.peerID, bluetooth: kind == "ble")
                }
            } else {
                failedAttempts.removeAll { Date().timeIntervalSince($0) >= 60 }
                let correct =
                    failedAttempts.count < 5 && equalSecret(request.pairCode, pairCode)
                    && equalSecret(request.password, password)
                if !correct { failedAttempts.append(Date()) }
                if !correct {
                    accepted = false
                } else if stored != nil {
                    declinedConnections.remove(certificate.peerID);
                    accepted = true
                } else {
                    accepted = await confirmCertificate(certificate)
                }
            }
            if !accepted {
                var rejected = message("rejected", target: certificate.peerID)
                rejected.error =
                    declinedConnections.contains(certificate.peerID) ? "connectionDeclined" : "authenticationFailed"
                try await transport.sendAsync(rejected)
                event("PairingRejected")
                throw PairingError.authenticationFailed
            }
            let id =
                request.mode == "attach"
                ? request.sessionID!
                : (sessions[certificate.peerID]?.sessionID ?? pendingSessionIDs[certificate.peerID]
                    ?? UUID().uuidString.lowercased())
            pendingSessionIDs[certificate.peerID] = id
            handshakeStep = "accepted"
            var response = message("accepted", target: certificate.peerID)
            response.sessionID = id;
            response.capabilities = [kind]
            try await transport.sendAsync(response)
            let ready = try await transport.receiveAsync()
            try validate(ready, certificate: certificate)
            guard ready.type == "ready", ready.sessionID == id else { throw PairingError.invalidMessage }
            try registry.remember(certificate, name: request.name ?? certificate.peerID)
            var info = SessionInfo(
                sessionID: id, peerID: certificate.peerID, name: request.name ?? certificate.peerID,
                capabilities: Array(
                    Set(request.capabilities ?? []).intersection(applicationCapabilities.union([kind]))),
                initiatorPeerID: certificate.peerID)
            info.listenPort = request.listenPort ?? 49160;
            info.remotePlatform = request.platform?.lowercased() ?? "unknown"
            guard
                register(
                    transport, info: info, remoteCaps: request.capabilities ?? [], publish: false,
                    attaching: request.mode == "attach", remoteInstance: request.instanceID)
            else { throw PairingError.disconnected }
            var established = message("established", target: certificate.peerID);
            established.sessionID = id
            try await transport.sendAsync(established)
            publishSession(transport, info: sessions[certificate.peerID]!)
        } catch {
            transport.cancel()
            if let certificate = transport.certificate, links[certificate.peerID]?[kind] === transport {
                links[certificate.peerID]?.removeValue(forKey: kind);
                lastSeen.removeValue(forKey: ObjectIdentifier(transport))
                if links[certificate.peerID]?.isEmpty == true {
                    links.removeValue(forKey: certificate.peerID);
                    sessions.removeValue(forKey: certificate.peerID);
                    sent.removeValue(forKey: certificate.peerID)
                }
                changed(Array(sessions.values))
            }
            let failure = error as NSError
            event(
                "ConnectionRejected transport=\(kind) step=\(handshakeStep) domain=\(failure.domain) code=\(failure.code)"
            )
        }
    }

    private func message(_ type: String, target: String) -> SessionMessage {
        var result = SessionMessage(type: type, sourcePeerID: localID);
        result.targetPeerID = target;
        return result
    }
    private var pendingSessionIDs: [String: String] = [:]
    private var pendingApprovals: [String: Task<Bool, Never>] = [:]
    private func approveConnection(_ peer: String, name: String, bluetooth: Bool = false) async -> Bool {
        guard !declinedConnections.contains(peer) else { return false }
        if links[peer]?.isEmpty == false { return true }
        if let pending = pendingApprovals[peer] { return await pending.value }
        let confirm = bluetooth ? confirmBluetoothConnection : confirmConnection
        let pending = Task { [confirmPeerConnection] in
            if let confirmPeerConnection { return await confirmPeerConnection(peer, name, bluetooth) }
            return await confirm(name)
        }
        pendingApprovals[peer] = pending
        let accepted = await pending.value
        if !accepted {
            declinedConnections.insert(peer);
            event("SessionConnectionDeclined peerId=\(peer)")
        }
        return accepted
    }

    private func finishHandshake(_ peer: String) {
        let count = (pendingHandshakes[peer] ?? 1) - 1
        if count > 0 {
            pendingHandshakes[peer] = count
        } else {
            pendingHandshakes.removeValue(forKey: peer);
            pendingSessionIDs.removeValue(forKey: peer);
            pendingApprovals.removeValue(forKey: peer)
        }
    }

    private func equalSecret(_ supplied: String?, _ expected: String) -> Bool {
        let supplied = supplied ?? ""
        let left = Data(supplied.utf8), right = Data(expected.utf8)
        guard left.count == right.count else { return false };
        if left.isEmpty { return true }
        return left.withUnsafeBytes { a in
            right.withUnsafeBytes { b in timingsafe_bcmp(a.baseAddress!, b.baseAddress!, left.count) == 0 }
        }
    }
    private func validate(_ message: SessionMessage, certificate: CertificatePeer) throws {
        guard message.instanceID == nil || UUID(uuidString: message.instanceID!) != nil else {
            throw PairingError.invalidMessage
        }
        guard message.version == 2 else { throw PairingError.incompatibleVersion }
        guard message.sourcePeerID == certificate.peerID, message.targetPeerID == localID else {
            throw PairingError.invalidMessage
        }
    }

    @discardableResult private func register(
        _ transport: SecureNetwork, info: SessionInfo, remoteCaps: [String], publish: Bool = true,
        attaching: Bool = false, remoteInstance: String? = nil
    ) -> Bool {
        transport.markEstablished()
        var selected = info
        selected.lanHost = transport.remoteHost;
        selected.localHost = transport.localHost
        let restarted =
            remoteInstance != nil && remoteInstances[info.peerID] != nil
            && remoteInstances[info.peerID] != remoteInstance
        if let existing = sessions[info.peerID] {
            if !restarted, let remoteInstance, remoteInstances[info.peerID] == remoteInstance,
                let live = links[info.peerID]?[transport.kind], let origin = linkInitiators[ObjectIdentifier(live)],
                attaching || origin <= info.initiatorPeerID
            {
                event("SessionDuplicateLinkIgnored peerId=\(info.peerID) transport=\(transport.kind)");
                transport.cancel();
                return false
            }
            if restarted {
                event("SessionPeerRestarted peerId=\(info.peerID)")
                links[info.peerID]?.values.forEach { $0.cancel() };
                links[info.peerID] = [:]
            }
            if existing.sessionID == info.sessionID {
                // Simultaneous fresh requests can finish after another direction is live.
                // Both ends choose the same initiator, preserving the winning physical link.
                // An explicit attach still replaces a stale link after a process restart.
                if !attaching, !restarted, let prior = links[info.peerID]?[transport.kind],
                    let origin = linkInitiators[ObjectIdentifier(prior)], origin <= info.initiatorPeerID
                {
                    event("SessionDuplicateLinkIgnored peerId=\(info.peerID) transport=\(transport.kind)")
                    transport.cancel();
                    return false
                }
                selected = SessionInfo(
                    sessionID: info.sessionID, peerID: info.peerID, name: info.name,
                    capabilities: Array(Set(existing.capabilities + info.capabilities)),
                    initiatorPeerID: existing.initiatorPeerID)
                selected.lanHost = transport.remoteHost ?? existing.lanHost;
                selected.localHost = transport.localHost ?? existing.localHost;
                selected.listenPort = existing.listenPort;
                selected.remotePlatform = existing.remotePlatform
            } else {
                if !restarted, existing.initiatorPeerID < info.initiatorPeerID {
                    transport.cancel();
                    return false
                }
                links[info.peerID]?.values.forEach { $0.cancel() };
                links[info.peerID] = [:];
                sent[info.peerID] = 0
            }
        }
        links[info.peerID]?[transport.kind]?.cancel()
        if links[info.peerID] == nil {
            links[info.peerID] = [:];
            sent[info.peerID] = 0
        }
        routePolicies[info.peerID]?.resetPreference()
        links[info.peerID]?[transport.kind] = transport
        linkInitiators[ObjectIdentifier(transport)] = info.initiatorPeerID
        // An attach hello can precede a newer capabilities frame on the other link.
        // Only a genuine new session/process invalidates that ordered snapshot.
        if restarted || sessions[info.peerID]?.sessionID != selected.sessionID {
            filePolicies.removeValue(forKey: info.peerID);
            inputSent.removeValue(forKey: info.peerID);
            fileHints.removeValue(forKey: info.peerID)
            remoteCapabilitySequences.removeValue(forKey: info.peerID)
            bulkNetworkDeadline[info.peerID] = .now.advanced(by: .seconds(5))
        }
        let negotiated =
            remoteCapabilitySequences[info.peerID] == nil
            ? Set(remoteCaps) : remoteCapabilities[info.peerID] ?? Set(remoteCaps)
        selected.capabilities = Array(
            negotiated.intersection(applicationCapabilities).union(Set(links[info.peerID]?.keys.map { $0 } ?? [])))
        selected.remoteInstanceID = remoteInstance
        sessions[info.peerID] = selected
        remoteInstances[info.peerID] = remoteInstance
        remoteCapabilities[info.peerID] = negotiated
        lastSeen[ObjectIdentifier(transport)] = Date()
        if publish { publishSession(transport, info: selected) }
        return true
    }
    private func publishSession(_ transport: SecureNetwork, info: SessionInfo) {
        if transport.kind == "tcp", let host = transport.remoteHost {
            try? registry.rememberNetworkEndpoint(
                info.peerID, endpoint: NetworkEndpoint(host: host, port: info.listenPort))
            recoveryFailures[info.peerID] = 0;
            recoveryIndex[info.peerID] = 0;
            recoveryNext.removeValue(forKey: info.peerID)
        }
        event(
            "SessionEstablished peerId=\(info.peerID) sessionId=\(info.sessionID) transport=\(transport.kind) tls=1.3")
        event(
            "SessionTopology peerId=\(info.peerID) links=\((links[info.peerID]?.keys.sorted() ?? []).joined(separator: ","))"
        )
        changed(Array(sessions.values))
        Task { await readSession(transport, info: info) };
        Task { await heartbeat(transport, info: info) }
        // An attach hello can predate InputService enabling while another link is live.
        // Publish current capabilities on the new stream after the handshake commits.
        Task {
            await advertiseNetwork(to: info.peerID, force: true)
            _ = try? await sendFrame(
                "data", peerID: info.peerID, channel: "capabilities",
                payload: JSONEncoder().encode(Array(applicationCapabilities)), transport: transport)
        }
        if !bleCheckStarted,
            ProcessInfo.processInfo.arguments.contains("--link-latency-check")
                || transport.kind == "ble" && ProcessInfo.processInfo.arguments.contains("--ble-link-check")
        {
            bleCheckStarted = true
            Task {
                try? await Task.sleep(for: .seconds(5))
                if let result = try? await testLatency(
                    peerID: info.peerID,
                    onlyKind: ProcessInfo.processInfo.arguments.contains("--link-latency-check") ? nil : "ble")
                {
                    for link in result {
                        event(
                            "BLELinkCheck transport=\(link.kind) samples=\(link.samples.count) lost=\(link.lost) averageMs=\(link.average) p95Ms=\(link.p95) p99Ms=\(link.p99) maximumMs=\(link.maximum)"
                        )
                    }
                } else {
                    event("BLELinkCheck unavailable")
                }
            }
        }
    }

    private func readSession(_ transport: SecureNetwork, info: SessionInfo) async {
        var lastSequence: UInt64 = 0
        var assemblies: [Data: BulkFrameCodec.Assembly] = [:]
        do {
            while true {
                var request = try await transport.receiveAsync()
                if request.type == "compact-input-v3",
                    sessions[info.peerID]?.capabilities.contains("compact-input-v3") != true
                {
                    throw PairingError.invalidMessage
                }
                if request.type == "compact-diagnostics",
                    sessions[info.peerID]?.capabilities.contains("compact-diagnostics-v1") != true
                {
                    throw PairingError.invalidMessage
                }
                if request.type == "compact-data",
                    sessions[info.peerID]?.capabilities.contains("compact-data-v1") != true
                {
                    throw PairingError.invalidMessage
                }
                if ["compact-input-v3", "compact-diagnostics", "compact-data"].contains(request.type) {
                    request.sessionID = info.sessionID
                }
                if ["compact-input", "compact-input-v3", "compact-diagnostics", "compact-data"].contains(request.type) {
                    request.type = "data";
                    request.sourcePeerID = info.peerID;
                    request.targetPeerID = localID
                }
                guard sessions[info.peerID]?.sessionID == info.sessionID,
                    links[info.peerID]?[transport.kind] === transport, request.version == 2,
                    request.sourcePeerID == info.peerID, request.targetPeerID == localID,
                    request.sessionID == info.sessionID, request.sequence > lastSequence
                else {
                    event(
                        "SessionFrameRejected transport=\(transport.kind) sequence=\(request.sequence) previous=\(lastSequence)"
                    )
                    throw PairingError.invalidMessage
                }
                if transport.kind == "ble", ["ping", "pong"].contains(request.type) {
                    event("BLEHeartbeatReceived type=\(request.type)")
                }
                lastSequence = request.sequence
                recordTraffic(
                    kind: transport.kind, channel: request.channel ?? request.type, payload: request.payload,
                    sent: false)
                lastSeen[ObjectIdentifier(transport)] = Date()
                if request.type == "ping" {
                    try await sendFrame("pong", peerID: info.peerID, transport: transport)
                } else if request.type == "pong" {
                    if let began = heartbeatSent.removeValue(forKey: ObjectIdentifier(transport)) {
                        routePolicies[info.peerID, default: InputRoutePolicy()].observe(
                            transport.kind, milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000,
                            now: ProcessInfo.processInfo.systemUptime)
                    }
                } else if request.type == "data", let channel = request.channel, let payload = request.payload,
                    channel.utf8.count <= 32, payload.count <= 32768
                {
                    if channel == "input" || channel == "diagnostics" || channel == "throughput" {
                        inputActivity[info.peerID] = ProcessInfo.processInfo.systemUptime
                    }
                    if let token = request.deliveryID,
                        UUID(uuidString: token) == nil
                            || sessions[info.peerID]?.capabilities.contains("background-flow-v1") != true
                    {
                        throw PairingError.invalidMessage
                    }
                    if channel == "background-ack" {
                        if let token = String(data: payload, encoding: .utf8), let pending = deliveryWaiters[token],
                            pending.peer == info.peerID, pending.link == ObjectIdentifier(transport)
                        {
                            finishDelivery(token)
                        }
                    } else if channel == "bulk-window" {
                        guard hasCapability(info.peerID, "adaptive-file-window-v1"), payload.count == 1,
                            let count = payload.first, (1...8).contains(count)
                        else { throw PairingError.invalidMessage }
                        filePolicies[info.peerID, default: FileWindowPolicy()].remoteLimit(
                            Int(count), sequence: request.sequence, now: ProcessInfo.processInfo.systemUptime)
                    } else if channel == "bulk" {
                        guard request.deliveryID != nil,
                            sessions[info.peerID]?.capabilities.contains("bulk-fragments-v1") == true
                        else { throw PairingError.invalidMessage }
                        if let (original, complete) = try BulkFrameCodec.consume(payload, assemblies: &assemblies),
                            let receiver = receivers[original]
                        {
                            await receiver(info.peerID, complete, transport)
                        }
                    } else if channel == "throughput" {
                        guard request.deliveryID != nil,
                            sessions[info.peerID]?.capabilities.contains("throughput-test-v1") == true
                        else { throw PairingError.invalidMessage }
                    } else if channel == "diagnostics" {
                        if let probe = try? JSONDecoder().decode(LatencyProbe.self, from: payload),
                            probe.token.utf8.count <= 80
                        {
                            if probe.type == "probe" {
                                try await sendFrame(
                                    "data", peerID: info.peerID, channel: "diagnostics",
                                    payload: JSONEncoder().encode(LatencyProbe(type: "reply", token: probe.token)),
                                    transport: transport)
                            } else if probe.type == "reply", let sample = probeTimes[probe.token],
                                sample.peer == info.peerID, sample.kind == transport.kind
                            {
                                probeTimes.removeValue(forKey: probe.token)
                                let d = sample.at.duration(to: .now).components
                                probeResults[sample.run]?[sample.kind]?[sample.index].milliseconds =
                                    (Double(d.seconds) + Double(d.attoseconds) / 1e18) * 1000
                            }
                        }
                    } else if channel == "network-endpoints" {
                        receiveNetworkAdvertisement(peer: info.peerID, payload: payload)
                    } else if channel == "capabilities" {
                        if let values = try? JSONDecoder().decode([String].self, from: payload), values.count <= 32,
                            values.allSatisfy({ $0.utf8.count <= 32 })
                        {
                            applyRemoteCapabilities(info.peerID, values: Set(values), sequence: request.sequence)
                        }
                    } else if let receiver = receivers[channel] {
                        await receiver(info.peerID, payload, transport)
                    }
                    if let token = request.deliveryID {
                        try await sendFrame(
                            "data", peerID: info.peerID, channel: "background-ack", payload: Data(token.utf8),
                            transport: transport)
                    }
                } else if request.type != "pong" {
                    throw PairingError.invalidMessage
                }
            }
        } catch {
            let failure = error as NSError
            event("SessionLinkClosed transport=\(transport.kind) domain=\(failure.domain) code=\(failure.code)")
            transport.cancel()
            for (token, pending) in deliveryWaiters
            where pending.peer == info.peerID && pending.link == ObjectIdentifier(transport) {
                finishDelivery(token, error: PairingError.disconnected)
            }
            lastSeen.removeValue(forKey: ObjectIdentifier(transport))
            linkInitiators.removeValue(forKey: ObjectIdentifier(transport))
            if links[info.peerID]?[transport.kind] === transport {
                links[info.peerID]?.removeValue(forKey: transport.kind)
                if links[info.peerID]?.isEmpty == true {
                    routePolicies.removeValue(forKey: info.peerID);
                    filePolicies.removeValue(forKey: info.peerID);
                    inputSent.removeValue(forKey: info.peerID);
                    fileHints.removeValue(forKey: info.peerID)
                    sessions.removeValue(forKey: info.peerID);
                    recoveryIndex[info.peerID] = 0;
                    recoveryNext.removeValue(forKey: info.peerID);
                    remoteInstances.removeValue(forKey: info.peerID);
                    remoteCapabilities.removeValue(forKey: info.peerID);
                    remoteCapabilitySequences.removeValue(forKey: info.peerID);
                    bulkNetworkDeadline.removeValue(forKey: info.peerID);
                    links.removeValue(forKey: info.peerID);
                    sent.removeValue(forKey: info.peerID)
                    event("SessionClosed peerId=\(info.peerID)")
                } else if let current = sessions[info.peerID] {
                    if transport.kind != "ble", links[info.peerID]?["tcp"] == nil, links[info.peerID]?["quic"] == nil {
                        bulkNetworkDeadline[info.peerID] = .now.advanced(by: .seconds(5))
                    }
                    var updated = SessionInfo(
                        sessionID: current.sessionID, peerID: current.peerID, name: current.name,
                        capabilities: current.capabilities.filter { !["tcp", "ble", "quic"].contains($0) }
                            + Array(links[info.peerID]!.keys), initiatorPeerID: current.initiatorPeerID)
                    updated.lanHost = current.lanHost;
                    updated.localHost = current.localHost;
                    updated.listenPort = current.listenPort;
                    updated.remotePlatform = current.remotePlatform;
                    updated.remoteInstanceID = current.remoteInstanceID;
                    sessions[info.peerID] = updated
                }
                changed(Array(sessions.values))
            }
        }
    }

    public func setApplicationCapabilities(_ capabilities: Set<String>) {
        applicationCapabilities = capabilities.union([
            "network-endpoints-v1", "compact-diagnostics-v1", "background-flow-v1", "throughput-test-v1",
            "compact-data-v1", "bulk-fragments-v1", "adaptive-file-window-v1",
        ])
    }
    public func setCapability(_ capability: String, enabled: Bool) async {
        await setCapabilities([capability: enabled])
    }
    public func setCapabilities(_ values: [String: Bool]) async {
        var next = applicationCapabilities
        for (capability, enabled) in values { if enabled { next.insert(capability) } else { next.remove(capability) } }
        guard next != applicationCapabilities else { return }
        applicationCapabilities = next
        for peer in Array(sessions.keys) {
            refreshCapabilities(peer)
            try? await send(
                peerID: peer, channel: "capabilities", payload: JSONEncoder().encode(Array(applicationCapabilities)))
        }
        changed(Array(sessions.values))
    }
    // Session sequences are shared by all links. A delayed BLE frame must not
    // undo a newer TCP capability snapshot, including an explicit input pause.
    func applyRemoteCapabilities(_ peer: String, values: Set<String>, sequence: UInt64) {
        guard sessions[peer] != nil, sequence > remoteCapabilitySequences[peer, default: 0] else { return }
        remoteCapabilitySequences[peer] = sequence
        guard values != remoteCapabilities[peer] else { return }
        remoteCapabilities[peer] = values;
        refreshCapabilities(peer);
        changed(Array(sessions.values))
    }
    private func refreshCapabilities(_ peer: String) {
        guard var info = sessions[peer] else { return }
        info.capabilities = Array(
            (remoteCapabilities[peer] ?? []).intersection(applicationCapabilities).union(
                Set(links[peer]?.keys.map { $0 } ?? [])))
        sessions[peer] = info
    }
    public func authorizeGroup(_ groupID: String?, members: Set<String>) {
        authorizedGroup = groupID;
        groupMembers = members
    }
    public func receive(channel: String, handler: @escaping @Sendable (String, Data) async -> Void) {
        receivers[channel] = { peer, bytes, _ in await handler(peer, bytes) }
    }
    public func receiveWithTransport(
        channel: String, handler: @escaping @Sendable (String, Data, SecureNetwork) async -> Void
    ) { receivers[channel] = handler }
    public func sendOnTransport(peerID: String, channel: String, payload: Data, transport: SecureNetwork) async throws {
        guard !channel.isEmpty, channel.utf8.count <= 32, payload.count <= 32768 else {
            throw PairingError.invalidMessage
        }
        guard links[peerID]?[transport.kind] === transport else { throw PairingError.disconnected }
        try await sendFrame("data", peerID: peerID, channel: channel, payload: payload, transport: transport)
    }

    private struct DeliveryWaiter {
        let peer: String;
        let link: ObjectIdentifier
        let completion: CheckedContinuation<Void, Error>;
        let timer: Task<Void, Never>
    }
    private var deliveryWaiters: [String: DeliveryWaiter] = [:]
    private var backgroundSending: Set<String> = []
    private var inputActivity: [String: Double] = [:]
    private var speedTests: Set<String> = []
    private var filePolicies: [String: FileWindowPolicy] = [:]
    private var inputSent: [String: [UInt64: (at: Double, link: ObjectIdentifier)]] = [:]
    private var fileHints: [String: (at: Double, count: Int)] = [:]
    public func sendInput(peerID: String, payload: Data, acknowledgedSequence: UInt64?) async throws {
        guard payload.count <= 32768 else { throw PairingError.invalidMessage }
        try await sendFrame(
            "data", peerID: peerID, channel: "input", payload: payload, inputSequence: acknowledgedSequence)
    }
    public func inputReceived(_ peer: String, transport: SecureNetwork) {
        guard links[peer]?[transport.kind] === transport else { return }
        filePolicies[peer, default: FileWindowPolicy()].markInput(now: ProcessInfo.processInfo.systemUptime)
        publishFileWindow(peer)
    }
    public func inputAcknowledged(_ peer: String, sequence: UInt64, transport: SecureNetwork) {
        guard links[peer]?[transport.kind] === transport else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let completed = inputSent[peer, default: [:]].filter { $0.key <= sequence }
        for key in completed.keys { inputSent[peer]?.removeValue(forKey: key) }
        guard let oldest = completed.values.filter({ $0.link == ObjectIdentifier(transport) }).map(\.at).min() else {
            return
        }
        filePolicies[peer, default: FileWindowPolicy()].observe(
            transport.kind, milliseconds: (now - oldest) * 1000, now: now)
        publishFileWindow(peer)
    }
    private func publishFileWindow(_ peer: String) {
        guard hasCapability(peer, "adaptive-file-window-v1"), let link = links[peer]?["quic"] ?? links[peer]?["tcp"]
        else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let count = filePolicies[peer, default: FileWindowPolicy()].localWindow(now: now)
        if let previous = fileHints[peer], now - previous.at < (previous.count == count ? 1 : 0.5) { return }
        fileHints[peer] = (now, count)
        event("FileWindowFeedback peerId=\(peer) count=\(count)")
        Task {
            try? await self.sendOnTransport(
                peerID: peer, channel: "bulk-window", payload: Data([UInt8(count)]), transport: link)
        }
    }
    public func backgroundPayloadLimit(_ peer: String) -> Int {
        links[peer]?["tcp"] != nil || links[peer]?["quic"] != nil ? 20000 : 128
    }
    public func hasCapability(_ peer: String, _ capability: String) -> Bool {
        sessions[peer]?.capabilities.contains(capability) == true
    }
    public func fileTransferWindow(_ peer: String) -> (bytes: Int, count: Int) {
        let compact = hasCapability(peer, "compact-file-v1") && hasCapability(peer, "compact-data-v1")
        let active = ProcessInfo.processInfo.systemUptime - inputActivity[peer, default: 0] < 0.3
        guard links[peer]?["tcp"] != nil || links[peer]?["quic"] != nil else { return (compact ? 256 : 512, 1) }
        guard hasCapability(peer, "adaptive-file-window-v1") else { return (compact ? 32000 : 20000, active ? 2 : 8) }
        let count = filePolicies[peer, default: FileWindowPolicy()].window(now: ProcessInfo.processInfo.systemUptime)
        publishFileWindow(peer)
        return (compact ? 32000 : 20000, count)
    }
    private func finishDelivery(_ token: String, error: Error? = nil) {
        guard let value = deliveryWaiters.removeValue(forKey: token) else { return }
        value.timer.cancel()
        if let error { value.completion.resume(throwing: error) } else { value.completion.resume() }
    }
    private func sendAcknowledged(_ peer: String, channel: String, payload: Data, link: SecureNetwork) async throws {
        guard payload.count <= 32768, sessions[peer]?.capabilities.contains("background-flow-v1") == true else {
            throw PairingError.invalidMessage
        }
        let token = UUID().uuidString.lowercased()
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            let timer = Task {
                do { try await Task.sleep(for: .seconds(6)) } catch { return };
                self.finishDelivery(token, error: PairingError.timedOut)
            }
            deliveryWaiters[token] = DeliveryWaiter(
                peer: peer, link: ObjectIdentifier(link), completion: completion, timer: timer)
            Task {
                do {
                    try await self.sendFrame(
                        "data", peerID: peer, channel: channel, payload: payload, transport: link, deliveryID: token)
                } catch { self.finishDelivery(token, error: error) }
            }
        }
    }
    public func sendBackground(peerID: String, channel: String, payload: Data) async throws {
        while true {
            guard let choices = links[peerID] else { throw PairingError.disconnected }
            if choices["tcp"] != nil || choices["quic"] != nil {
                try await send(peerID: peerID, channel: channel, payload: payload);
                return
            }
            guard let link = choices["ble"] else { throw PairingError.disconnected }
            guard payload.count <= 2048 else { throw PairingError.invalidMessage }
            // Idle history cannot hold admission while foreground files need it.
            if backgroundSending.contains(peerID)
                || ProcessInfo.processInfo.systemUptime - inputActivity[peerID, default: 0] < 0.15
            {
                try await Task.sleep(for: .milliseconds(30));
                continue
            }
            backgroundSending.insert(peerID);
            defer { backgroundSending.remove(peerID) }
            // One small packet waits for the receiver before admitting another. No ciphertext reordering.
            try await sendAcknowledged(peerID, channel: channel, payload: payload, link: link);
            return
        }
    }
    private var bulkServiceAt: [String: Double] = [:]
    private var bulkYieldUntil: [String: Double] = [:]
    public func yieldBulkForInput(_ peer: String) {
        let now = ProcessInfo.processInfo.systemUptime
        bulkYieldUntil[peer] = now + 0.25
        filePolicies[peer, default: FileWindowPolicy()].congested(now: now);
        publishFileWindow(peer)
    }
    public func sendBulkTracked(peerID: String, channel: String, payload: Data) async throws -> String {
        guard BulkFrameCodec.channels.contains(channel), payload.count <= 32768 else {
            throw PairingError.invalidMessage
        }
        if links[peerID]?["tcp"] != nil || links[peerID]?["quic"] != nil {
            return try await sendTracked(peerID: peerID, channel: channel, payload: payload)
        }
        while backgroundSending.contains(peerID) {
            guard sessions[peerID] != nil else { throw PairingError.disconnected };
            try await Task.sleep(for: .milliseconds(5))
        }
        backgroundSending.insert(peerID);
        defer { backgroundSending.remove(peerID) }
        // Re-check after admission: another task may have attached the LAN route.
        if links[peerID]?["tcp"] != nil || links[peerID]?["quic"] != nil {
            return try await sendTracked(peerID: peerID, channel: channel, payload: payload)
        }
        guard let link = links[peerID]?["ble"] else { throw PairingError.disconnected }
        let fragments = hasCapability(peerID, "bulk-fragments-v1")
        let active = ProcessInfo.processInfo.systemUptime - inputActivity[peerID, default: 0] < 0.15
        let packets =
            fragments
            ? BulkFrameCodec.fragments(channel: channel, payload: payload, size: active ? 160 : 384) : [payload]
        for packet in packets {
            // During continuous input, reserve radio time rather than starving files
            // indefinitely. During idle periods ACK/backpressure sets the pace.
            while ProcessInfo.processInfo.systemUptime - inputActivity[peerID, default: 0] < 0.15,
                ProcessInfo.processInfo.systemUptime - bulkServiceAt[peerID, default: 0] < 0.1
                    || ProcessInfo.processInfo.systemUptime < bulkYieldUntil[peerID, default: 0]
            { try await Task.sleep(for: .milliseconds(5)) }
            guard links[peerID]?["ble"] === link else { throw PairingError.disconnected }
            bulkServiceAt[peerID] = ProcessInfo.processInfo.systemUptime
            if hasCapability(peerID, "background-flow-v1") {
                try await sendAcknowledged(peerID, channel: fragments ? "bulk" : channel, payload: packet, link: link)
            } else {
                try await sendFrame("data", peerID: peerID, channel: channel, payload: packet, transport: link)
            }
        }
        return "ble"
    }
    public func testThroughput(peerID: String) async throws -> [LinkThroughput] {
        guard !speedTests.contains(peerID), sessions[peerID]?.capabilities.contains("throughput-test-v1") == true else {
            throw PairingError.invalidMessage
        }
        guard let choices = links[peerID], !choices.isEmpty else { throw PairingError.disconnected }
        speedTests.insert(peerID);
        defer { speedTests.remove(peerID) }
        var selected: [SecureNetwork] = []
        if let tcp = choices["tcp"] { selected.append(tcp) }
        if let quic = choices["quic"] { selected.append(quic) }
        if let ble = choices["ble"] { selected.append(ble) }
        return await withTaskGroup(of: LinkThroughput.self) { group in
            for link in selected { group.addTask { await self.measureThroughput(peerID, link: link) } }
            var results: [LinkThroughput] = [];
            for await result in group { results.append(result) }
            return results.sorted { $0.kind < $1.kind }
        }
    }
    private func measureThroughput(_ peer: String, link: SecureNetwork) async -> LinkThroughput {
        let began = ProcessInfo.processInfo.systemUptime, size = link.kind == "ble" ? 512 : 24000,
            window = link.kind == "ble" ? 2 : 8, limit = link.kind == "ble" ? 65536 : 33554432
        let bytes = Data(repeating: 0xa5, count: size);
        var confirmed = 0;
        var failure: String?
        while ProcessInfo.processInfo.systemUptime - began < 4, confirmed < limit {
            let successes = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<window {
                    group.addTask {
                        do {
                            try await self.sendAcknowledged(peer, channel: "throughput", payload: bytes, link: link);
                            return true
                        } catch { return false }
                    }
                }
                var count = 0;
                for await success in group { if success { count += 1 } };
                return count
            }
            confirmed += successes * size
            if successes != window {
                failure = "确认超时或链路中断";
                break
            }
        }
        return LinkThroughput(
            kind: link.kind, bytes: confirmed, seconds: ProcessInfo.processInfo.systemUptime - began, error: failure)
    }
    public func testLatency(peerID: String, onlyKind: String? = nil) async throws -> [LinkLatency] {
        let choices = (links[peerID] ?? [:]).filter { onlyKind == nil || $0.key == onlyKind }
        guard !choices.isEmpty else { throw PairingError.disconnected }
        let run = UUID().uuidString;
        let start = ContinuousClock.now
        probeResults[run] = Dictionary(uniqueKeysWithValues: choices.keys.map { ($0, []) })
        defer {
            probeResults.removeValue(forKey: run);
            probeTimes = probeTimes.filter { $0.value.run != run }
        }
        await withTaskGroup(of: Void.self) { group in
            for (kind, link) in choices {
                group.addTask {
                    await self.measureLatency(run: run, peer: peerID, kind: kind, link: link, start: start)
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline, probeTimes.values.contains(where: { $0.run == run }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return (probeResults[run] ?? [:]).sorted { $0.key < $1.key }.map {
            LinkLatency(kind: $0.key, samples: $0.value)
        }
    }

    private func measureLatency(
        run: String, peer: String, kind: String, link: SecureNetwork, start: ContinuousClock.Instant
    ) async {
        for _ in 0..<200 {
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            if seconds >= 10 { break }
            let slot = probeResults[run]?[kind]?.count ?? 0
            probeResults[run]?[kind]?.append(LatencySample(index: slot, seconds: seconds, milliseconds: nil))
            let token = UUID().uuidString.lowercased(), began = ContinuousClock.now
            probeTimes[token] = (run, kind, slot, peer, began)
            _ = try? await sendFrame(
                "data", peerID: peer, channel: "diagnostics",
                payload: JSONEncoder().encode(LatencyProbe(type: "probe", token: token)), transport: link)
            // Each link owns its schedule; a late BLE send cannot bunch network probes.
            let next = began.advanced(by: .milliseconds(50))
            if ContinuousClock.now < next { try? await Task.sleep(until: next, clock: .continuous) }
        }
    }

    public func send(peerID: String, channel: String, payload: Data) async throws {
        _ = try await sendTracked(peerID: peerID, channel: channel, payload: payload)
    }
    public func sendTracked(peerID: String, channel: String, payload: Data) async throws -> String {
        guard !channel.isEmpty, channel.utf8.count <= 32, payload.count <= 32768 else {
            throw PairingError.invalidMessage
        }
        // BLE may win the handshake by a few seconds. Do not fill its TLS byte
        // stream with history/screenshot/file data just before TCP attaches.
        // Wait outside the send queue, once per link transition, with a BLE-only fallback.
        if channel == "history" || payload.count > 2048 && ["clipboard", "files", "computer"].contains(channel),
            networkAvailable, let deadline = bulkNetworkDeadline[peerID], let session = sessions[peerID]?.sessionID
        {
            let began = ContinuousClock.now
            while networkAvailable, sessions[peerID]?.sessionID == session, links[peerID]?["ble"] != nil,
                links[peerID]?["tcp"] == nil, links[peerID]?["quic"] == nil, ContinuousClock.now < deadline
            { try await Task.sleep(for: .milliseconds(50)) }
            let duration = began.duration(to: .now).components
            let elapsed = Int(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            if elapsed >= 50 {
                event(
                    "BulkRouteWait channel=\(channel) waitMs=\(elapsed) networkReady=\(links[peerID]?["tcp"] != nil || links[peerID]?["quic"] != nil)"
                )
            }
        }
        return try await sendFrame("data", peerID: peerID, channel: channel, payload: payload)
    }

    @discardableResult private func sendFrame(
        _ type: String, peerID: String, channel: String? = nil, payload: Data? = nil, transport: SecureNetwork? = nil,
        deliveryID: String? = nil, inputSequence: UInt64? = nil
    ) async throws -> String {
        let choices = links[peerID]
        let preferred = channel == "input" ? "quic" : "tcp"
        let ordinary = choices?[preferred] ?? choices?["tcp"] ?? choices?["quic"]
        let route =
            channel == "input"
            ? routePolicies[peerID, default: InputRoutePolicy()].choose(
                Set(choices?.keys.map { $0 } ?? []), bluetoothPreferred: bluetoothInputOnly,
                now: ProcessInfo.processInfo.systemUptime) : nil
        let selected = route.flatMap { choices?[$0] } ?? ordinary ?? choices?["ble"]
        guard let info = sessions[peerID], let link = transport ?? selected else { throw PairingError.disconnected }
        let sequence = (sent[peerID] ?? 0) + 1
        sent[peerID] = sequence
        var frame = message(type, target: peerID)
        frame.sessionID = info.sessionID;
        frame.sequence = sequence;
        frame.channel = channel;
        frame.deliveryID = deliveryID
        if channel == "input" || channel == "diagnostics" || channel == "throughput" {
            inputActivity[peerID] = ProcessInfo.processInfo.systemUptime
        }
        if channel == "diagnostics", info.capabilities.contains("compact-diagnostics-v1") {
            frame.mode = "compact-diagnostics-v1"
        } else if info.capabilities.contains("compact-data-v1"), type == "data", channel != "capabilities" {
            frame.mode = "compact-data-v1"
        }
        frame.payload = channel == "capabilities" ? try JSONEncoder().encode(Array(applicationCapabilities)) : payload
        recordTraffic(kind: link.kind, channel: channel ?? type, payload: frame.payload, sent: true)
        if let inputSequence {
            let now = ProcessInfo.processInfo.systemUptime
            if inputSent[peerID, default: [:]].count >= 64, let oldest = inputSent[peerID]?.keys.min() {
                inputSent[peerID]?.removeValue(forKey: oldest)
            }
            inputSent[peerID, default: [:]][inputSequence] = (now, ObjectIdentifier(link))
            filePolicies[peerID, default: FileWindowPolicy()].markInput(now: now)
        }
        // Bound background writes too: a stuck file write must not hold pongs forever.
        let pending = link.enqueueSend(frame, timeout: channel == "input" ? 3 : link.kind == "ble" ? 60 : 10)
        try await pending.wait()
        return link.kind
    }
    private func recordTraffic(kind: String, channel: String, payload: Data?, sent: Bool) {
        let category =
            channel == "input" ? (payload.map(MotionCodec.isCompact) == true ? "input-compact" : "input-json") : channel
        let key = "transport=\(kind) channel=\(category)"
        var value = traffic[key] ?? (0, 0, 0, 0)
        if sent {
            value.sent += 1;
            value.sentBytes += payload?.count ?? 0
        } else {
            value.received += 1;
            value.receivedBytes += payload?.count ?? 0
        }
        traffic[key] = value
        let now = ProcessInfo.processInfo.systemUptime
        guard now - trafficReportAt >= 5 else { return }
        let interval = Int((now - trafficReportAt) * 1000);
        trafficReportAt = now
        for (key, value) in traffic.sorted(by: { $0.key < $1.key }) {
            event(
                "SessionTraffic \(key) intervalMs=\(interval) txFrames=\(value.sent) txPayloadBytes=\(value.sentBytes) rxFrames=\(value.received) rxPayloadBytes=\(value.receivedBytes)"
            )
        }
        traffic = [:]
    }

    private func heartbeat(_ transport: SecureNetwork, info: SessionInfo) async {
        while links[info.peerID]?[transport.kind] === transport {
            do {
                try await Task.sleep(for: .seconds(5))
                guard links[info.peerID]?[transport.kind] === transport else { return }
                guard Date().timeIntervalSince(lastSeen[ObjectIdentifier(transport)] ?? .distantPast) < 20 else {
                    event("SessionHeartbeatTimeout transport=\(transport.kind)")
                    transport.cancel();
                    return
                }
                heartbeatSent[ObjectIdentifier(transport)] = ProcessInfo.processInfo.systemUptime
                try await sendFrame("ping", peerID: info.peerID, transport: transport)
                if transport.kind == "ble" { event("BLEHeartbeatSent") }
            } catch {
                transport.cancel();
                return
            }
        }
    }

    public func disconnectTransport(_ peerID: String, kind: String) { links[peerID]?[kind]?.cancel() }
    // An authenticated session with input enabled can survive a stalled native UI dispatcher.
    // Two missed 5s heartbeats still count as link loss; no input receipt is fabricated here.
    public func inputSessionAlive(_ peer: String) -> Bool {
        guard sessions[peer]?.capabilities.contains("input") == true else { return false }
        let now = Date()
        return links[peer]?.values.contains {
            now.timeIntervalSince(lastSeen[ObjectIdentifier($0)] ?? .distantPast) < 12
        } == true
    }
    public func disconnect(_ peerID: String) { links[peerID]?.values.forEach { $0.cancel() } }
    public func stop() {
        recoveryStopped = true;
        listener?.cancel();
        bluetoothListener?.cancel();
        quicListener?.cancel();
        listener = nil;
        bluetoothListener = nil;
        quicListener = nil;
        links.values.forEach { $0.values.forEach { $0.cancel() } }
    }
    public func autoConnectionDeclined(_ peer: String) -> Bool { declinedConnections.contains(peer) }
    public func currentSessions() -> [SessionInfo] { Array(sessions.values) }
}
