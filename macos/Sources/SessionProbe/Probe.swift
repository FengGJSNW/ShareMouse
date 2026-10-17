import Darwin
import Foundation
import Network
import ShareMouseCore

struct ProbeConfig: Decodable, Sendable {
    let mode: String
    let directory: String
    let host: String?
    let port: UInt16
    let pairCode: String
    let password: String
    let expectedPeerID: String?
    let expectedPublicKey: String?
    let trusted: Bool
    let seconds: Int
    let secondaryTransport: String?
    let disconnectPrimary: Bool?
    let transport: String?
    let workload: String?
}

@main struct SessionProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw PairingError.invalidMessage }
        let config = try JSONDecoder().decode(
            ProbeConfig.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let directory = URL(fileURLWithPath: config.directory, isDirectory: true)
        if config.mode == "ble" {
            let discovery = BLEDiscovery(
                status: { print($0) }, found: { locator, _ in print("BLECandidate id=" + locator) })
            discovery.start()
            try await Task.sleep(for: .seconds(config.seconds));
            discovery.stop();
            return
        }
        let id = try PeerIdentityStore(directory: directory).loadOrCreate().value.uuidString.lowercased()
        let identity = try IdentityKeychain(peerID: id)
        if config.mode == "identity" {
            let json = [
                "peerID": id, "publicKey": identity.certificatePeer.publicKey,
                "certificate": identity.certificateData.base64EncodedString(),
            ]
            print(String(data: try JSONEncoder().encode(json), encoding: .utf8)!)
            return
        }
        let registry = try PeerRegistry(directory: directory)
        if config.trusted, let expectedID = config.expectedPeerID, let key = config.expectedPublicKey {
            try registry.remember(CertificatePeer(peerID: expectedID, publicKey: key), name: "Integration peer")
            try registry.setPreferences(expectedID, trusted: true, autoConnect: true)
        }
        let result = ProbeResult()
        let manager = SessionManager(
            localID: id, name: "Mac integration peer", identity: identity, registry: registry,
            pairCode: config.pairCode, password: config.password,
            confirmCertificate: { peer in
                peer.peerID == config.expectedPeerID && peer.publicKey == config.expectedPublicKey
            }, confirmConnection: { _ in true },
            changed: { sessions in
                if sessions.contains(where: { $0.peerID == config.expectedPeerID }) { result.mark() }
                print("SessionCount=" + String(sessions.count));
                fflush(nil)
            },
            event: {
                print($0);
                fflush(nil)
            })
        let echoes = ProbeEchoes()
        await manager.receive(channel: "probe") { peerID, payload in
            if config.mode == "listen" {
                try? await manager.send(peerID: peerID, channel: "probe", payload: payload)
            } else {
                await echoes.record(payload, workload: config.workload ?? "strings")
            }
        }
        try await manager.start(port: config.port)
        if config.transport == "quic" || config.secondaryTransport == "quic" {
            try await manager.startQuicListener(port: config.port)
        }
        let discovery = LANDiscovery(
            changed: { candidates in for candidate in candidates { print("LANCandidate endpoint=" + candidate.id) } },
            status: { print($0) })
        discovery.start()
        if config.mode == "connect", let host = config.host {
            try await manager.connect(
                endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: config.port)!),
                pairCode: config.pairCode, password: config.password, autoOnly: config.trusted,
                kind: config.transport ?? "tcp")
            if let secondary = config.secondaryTransport, let peerID = config.expectedPeerID {
                let before = await manager.currentSessions().first!.sessionID
                try await manager.connect(
                    endpoint: .hostPort(host: NWEndpoint.Host(host), port: .init(rawValue: config.port)!),
                    pairCode: nil, password: nil, kind: secondary)
                let combined = await manager.currentSessions().first!
                guard combined.sessionID == before, combined.capabilities.contains("tcp"),
                    combined.capabilities.contains(secondary)
                else { throw PairingError.invalidMessage }
                print("PASS: multiple transports share one Session")
                if config.disconnectPrimary == true {
                    await manager.disconnectTransport(peerID, kind: "tcp")
                    let deadline = Date().addingTimeInterval(5)
                    while await manager.currentSessions().contains(where: { $0.capabilities.contains("tcp") })
                        && Date() < deadline
                    { try await Task.sleep(for: .milliseconds(50)) }
                    guard await manager.currentSessions().first?.sessionID == before else {
                        throw PairingError.disconnected
                    }
                    print("PASS: Session retained after TCP disconnect")
                }
            }
        }
        if config.mode == "connect", let workload = config.workload, let peerID = config.expectedPeerID {
            let count = workload == "load" ? 256 : 100
            for index in 0..<count {
                try await manager.send(
                    peerID: peerID, channel: "probe", payload: ProbeEchoes.block(index, workload: workload))
                if workload != "load" { try await Task.sleep(for: .milliseconds(20)) }
            }
            let deadline = Date().addingTimeInterval(20)
            while await echoes.count() < count && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            guard await echoes.count() == count else { throw PairingError.invalidMessage }
            print("PASS: TLS transport \(workload) blocks=\(count) bytes=\(await echoes.bytes())");
            fflush(nil)
        }
        try await Task.sleep(for: .seconds(config.seconds))
        let connected = result.passed()
        await manager.stop();
        discovery.stop()
        guard connected else { throw PairingError.authenticationFailed }
        print("PASS: authenticated TLS 1.3 Session")
    }
}

final class ProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    func mark() { lock.withLock { connected = true } }
    func passed() -> Bool { lock.withLock { connected } }
}

actor ProbeEchoes {
    private var received = 0
    private var byteCount = 0
    private var invalid = false
    static func block(_ index: Int, workload: String) -> Data {
        let text = Data("ShareMouse 双向通信 #\(index)\n".utf8)
        if workload != "load" { return text }
        return text + Data(repeating: UInt8(index % 251), count: 32768 - text.count)
    }
    func record(_ data: Data, workload: String) {
        if data != Self.block(received, workload: workload) { invalid = true }
        received += 1;
        byteCount += data.count
    }
    func count() -> Int { invalid ? -1 : received }
    func bytes() -> Int { byteCount }
}
