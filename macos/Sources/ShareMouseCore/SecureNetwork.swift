import Foundation
@preconcurrency import Network
import Security

public protocol SessionTransport: AnyObject, Sendable {
    var certificate: CertificatePeer? { get }
    func send(_ message: SessionMessage, completion: @escaping @Sendable (Error?) -> Void)
    func receive(_ completion: @escaping @Sendable (Result<SessionMessage, Error>) -> Void)
    func cancel()
}

public final class SecureNetwork: SessionTransport, @unchecked Sendable {
    public let kind: String
    public var remoteHost: String? { host(connection.currentPath?.remoteEndpoint) }
    public var localHost: String? { host(connection.currentPath?.localEndpoint) }
    public var pathDescription: String {
        connection.currentPath?.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            ?? "unavailable"
    }
    private func host(_ endpoint: NWEndpoint?) -> String? {
        guard kind != "ble", case .hostPort(let host, _) = endpoint else { return nil }
        return String(describing: host)
    }
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let certificateLock = NSLock()
    private var remoteCertificate: CertificatePeer?
    private var established = false
    public var certificate: CertificatePeer? { certificateLock.withLock { remoteCertificate } }
    public var onClosed: (@Sendable () -> Void)?
    private var startCompletion: (@Sendable (Error?) -> Void)?

    public init(connection: NWConnection, queue: DispatchQueue, kind: String = "tcp") {
        self.kind = kind;
        self.connection = connection;
        self.queue = queue
    }

    public func setCertificate(_ value: CertificatePeer) { certificateLock.withLock { remoteCertificate = value } }

    public func start(_ completion: @escaping @Sendable (Error?) -> Void, timeout: TimeInterval? = nil) {
        startCompletion = completion
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let tls = (self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?
                    .securityProtocolMetadata
                let quic =
                    (self.connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata)?
                    .securityProtocolMetadata
                if let metadata = tls ?? quic {
                    sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
                        if self.certificate == nil,
                            let peer = try? IdentityKeychain.describe(
                                sec_certificate_copy_ref(certificate).takeRetainedValue())
                        {
                            self.setCertificate(peer)
                        }
                    }
                }
                let done = self.startCompletion;
                self.startCompletion = nil;
                done?(nil)
            case .failed(let error):
                let done = self.startCompletion;
                self.startCompletion = nil;
                done?(error)
                self.onClosed?()
            case .cancelled:
                let done = self.startCompletion;
                self.startCompletion = nil;
                done?(PairingError.disconnected)
                self.onClosed?()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + (timeout ?? (kind == "quic" ? 5 : 60))) { [weak self] in
            guard let self, !self.certificateLock.withLock({ self.established }) else { return }
            let done = self.startCompletion
            self.startCompletion = nil;
            done?(PairingError.timedOut);
            self.cancel()
        }
    }

    public func send(_ message: SessionMessage, completion: @escaping @Sendable (Error?) -> Void) {
        do {
            let payload = try SessionFrameCodec.encode(message)
            guard payload.count <= 65536 else { throw PairingError.invalidMessage }
            var size = UInt32(payload.count).bigEndian
            let frame = withUnsafeBytes(of: &size) { Data($0) } + payload
            connection.send(content: frame, completion: .contentProcessed { completion($0) })
        } catch { completion(error) }
    }

    public func receive(_ completion: @escaping @Sendable (Result<SessionMessage, Error>) -> Void) {
        readExactly(4) { [weak self] header in
            guard let self else { return }
            switch header {
            case .failure(let error): completion(.failure(error))
            case .success(let bytes):
                let count = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard count > 0, count <= 65536 else {
                    completion(.failure(PairingError.invalidMessage));
                    return
                }
                self.readExactly(Int(count)) { payload in
                    completion(payload.flatMap { data in Result { try SessionFrameCodec.decode(data) } })
                }
            }
        }
    }

    private func readExactly(
        _ count: Int, accumulated: Data = Data(), completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) {
            [weak self] data, _, ended, error in
            if let error {
                completion(.failure(error));
                return
            }
            let combined = accumulated + (data ?? Data())
            if combined.count == count {
                completion(.success(combined))
            } else if ended {
                completion(.failure(PairingError.disconnected))
            } else {
                self?.readExactly(count, accumulated: combined, completion: completion)
            }
        }
    }

    public func streamPreface(incoming: Bool) async throws {
        if incoming {
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                readExactly(1) { continuation.resume(with: $0) }
            }
            guard bytes == Data([1]) else { throw PairingError.invalidMessage }
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: Data([1]),
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
            }
        }
    }
    public func cancel() { connection.cancel() }
    public func markEstablished() { certificateLock.withLock { established = true } }

    public func startAsync(timeout: TimeInterval? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            start(
                { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } },
                timeout: timeout)
        }
    }
    public func sendAsync(_ message: SessionMessage, timeout: TimeInterval? = nil) async throws {
        try await enqueueSend(message, timeout: timeout).wait()
    }
    // Called synchronously by SessionManager before its actor suspends.
    func enqueueSend(_ message: SessionMessage, timeout: TimeInterval? = nil) -> PendingSend {
        let pending = PendingSend()
        send(message) { error in _ = pending.finish(error) }
        if let timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if pending.finish(PairingError.timedOut) { self?.cancel() }
            }
        }
        return pending
    }
    public func receiveAsync() async throws -> SessionMessage {
        try await withCheckedThrowingContinuation { continuation in receive { continuation.resume(with: $0) } }
    }

    public static func parameters(
        identity: IdentityKeychain,
        verify: @escaping @Sendable (CertificatePeer, @escaping @Sendable (Bool) -> Void) -> Void, queue: DispatchQueue,
        kind: String = "tcp"
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let quic = NWProtocolQUIC.Options(alpn: ["sharemouse-1"])
        quic.direction = .bidirectional;
        quic.initialMaxStreamsBidirectional = 1
        quic.idleTimeout = 30_000  // Network.framework uses milliseconds.
        let options = kind == "quic" ? quic.securityProtocolOptions : tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_local_identity(options, sec_identity_create(identity.identity)!)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(
            options,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let cert = chain.first,
                    let peer = try? IdentityKeychain.describe(cert)
                else {
                    complete(false);
                    return
                }
                // Explicit pinning replaces CA lookup, but validity and certificate signature checks remain.
                SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509())
                SecTrustSetAnchorCertificates(secTrust, [cert] as CFArray)
                SecTrustSetAnchorCertificatesOnly(secTrust, true)
                guard SecTrustEvaluateWithError(secTrust, nil) else {
                    complete(false);
                    return
                }
                let callback = VerifyCompletion(complete)
                verify(peer) { callback.call($0) }
            }, queue)
        let tcp = NWProtocolTCP.Options();
        tcp.noDelay = true;
        tcp.disableAckStretching = true
        let parameters = kind == "quic" ? NWParameters(quic: quic) : NWParameters(tls: tls, tcp: tcp)
        // Keep listeners and connections on ordinary LAN interfaces. Enabling
        // Apple peer-to-peer Wi-Fi also adds jitter to unrelated LAN traffic.
        parameters.includePeerToPeer = false
        // The UDP/QUIC link carries immediate input; file TCP remains best effort.
        if kind == "quic" { parameters.serviceClass = .interactiveVideo }
        return parameters
    }
}

// Network completion and timeout can race; resume the waiter exactly once.
final class PendingSend: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completed = lock.withLock { () -> Result<Void, Error>? in
                if let result { return result };
                self.continuation = continuation;
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }
    }
    func finish(_ error: Error?) -> Bool {
        let value: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        let completion = lock.withLock { () -> (Bool, CheckedContinuation<Void, Error>?) in
            guard result == nil else { return (false, nil) };
            result = value
            let done = continuation;
            continuation = nil;
            return (true, done)
        }
        completion.1?.resume(with: value);
        return completion.0
    }
}

// Apple's completion block may be invoked from the UI confirmation queue.
private final class VerifyCompletion: @unchecked Sendable {
    private let completion: (Bool) -> Void
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    func call(_ accepted: Bool) { completion(accepted) }
}
