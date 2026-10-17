import Foundation

public struct CertificatePeer: Sendable, Equatable {
    public let peerID: String
    public let publicKey: String
    public init(peerID: String, publicKey: String) {
        self.peerID = peerID;
        self.publicKey = publicKey
    }
}

public enum TrustState: String, Codable, Sendable { case known, trusted }

public struct KnownPeer: Codable, Sendable {
    public let peerID: String
    public var name: String
    public let publicKey: String
    public var trust: TrustState
    public var autoConnect: Bool
    public var networkEndpoints: [NetworkEndpoint]? = nil
}

public final class PeerRegistry: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var peers: [KnownPeer]

    public init(directory: URL) throws {
        file = directory.appendingPathComponent("known-peers.json")
        peers =
            FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([KnownPeer].self, from: Data(contentsOf: file)) : []
    }

    public func all() -> [KnownPeer] { lock.withLock { peers } }
    public func find(_ id: String) -> KnownPeer? { lock.withLock { peers.first { $0.peerID == id } } }

    public func remember(_ certificate: CertificatePeer, name: String) throws {
        try lock.withLock {
            if let index = peers.firstIndex(where: { $0.peerID == certificate.peerID }) {
                guard peers[index].publicKey == certificate.publicKey else { throw PairingError.identityChanged }
                peers[index].name = String(name.prefix(128))
            } else {
                peers.append(
                    KnownPeer(
                        peerID: certificate.peerID, name: String(name.prefix(128)), publicKey: certificate.publicKey,
                        trust: .known, autoConnect: false))
            }
            try save()
        }
    }

    public func setPreferences(_ id: String, trusted: Bool, autoConnect: Bool) throws {
        try lock.withLock {
            guard let index = peers.firstIndex(where: { $0.peerID == id }) else { throw PairingError.invalidMessage }
            peers[index].trust = trusted ? .trusted : .known
            peers[index].autoConnect = trusted && autoConnect
            try save()
        }
    }

    public func remove(_ id: String) throws {
        try lock.withLock {
            peers.removeAll { $0.peerID == id };
            try save()
        }
    }

    public func rememberNetworkEndpoint(_ id: String, endpoint: NetworkEndpoint) throws {
        guard endpoint.valid(allowLoopback: true) else { return }
        try lock.withLock {
            guard let index = peers.firstIndex(where: { $0.peerID == id }) else { return }
            let previous = peers[index].networkEndpoints ?? []
            let next = Array(([endpoint] + previous.filter { $0 != endpoint }).prefix(8))
            guard next != previous else { return }
            peers[index].networkEndpoints = next;
            try save()
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(peers).write(to: file, options: .atomic)
    }
}

public enum PairingError: Error {
    case identityChanged, invalidMessage, authenticationFailed, disconnected, incompatibleVersion, timedOut
}

// JSON inside TLS only; 4-byte network-order frame length, maximum 64 KiB.
public struct SessionMessage: Codable, Sendable {
    public var version = 2
    public var type: String
    public var sourcePeerID: String
    public var targetPeerID: String?
    public var sessionID: String?
    public var instanceID: String?
    public var sequence: UInt64 = 0
    public var name: String?
    public var platform: String?
    public var capabilities: [String]?
    public var mode: String?
    public var autoConnection: Bool?
    public var pairCode: String?
    public var password: String?
    public var listenPort: UInt16?
    public var groupID: String?
    public var error: String?
    public var channel: String?
    public var deliveryID: String?
    public var payload: Data?

    public init(type: String, sourcePeerID: String) {
        self.type = type;
        self.sourcePeerID = sourcePeerID
    }
}

public struct SessionInfo: Sendable {
    public let sessionID: String
    public let peerID: String
    public let name: String
    public var capabilities: [String]
    public let initiatorPeerID: String
    public var lanHost: String? = nil
    public var localHost: String? = nil
    public var listenPort: UInt16 = 49160
    public var remotePlatform: String = "unknown"
    public var remoteInstanceID: String? = nil
}
