import Foundation
@preconcurrency import Network

// GATT carries opaque TLS bytes. The loopback socket adapts Network.framework to a byte stream;
// it has no discovery advertisement and never leaves 127.0.0.1.
final class BLEByteBridge: @unchecked Sendable {
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var listener: NWListener?
    private var queued = 0
    private var early: [Data] = []
    private var closed = false
    private var forwardingGeneration = 0
    private var fragments = BLEStreamFraming()
    private let status: @Sendable (String) -> Void
    private var receivedBytes = 0, forwardedBytes = 0
    private var lastProgress = Date.distantPast
    private let forward: @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void
    private let ended: @Sendable () -> Void

    init(
        queue: DispatchQueue, forward: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        ended: @escaping @Sendable () -> Void, status: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.queue = queue;
        self.forward = forward;
        self.ended = ended;
        self.status = status
    }
    func listen(ready: @escaping @Sendable (Result<NWEndpoint, Error>) -> Void) throws {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let created = try NWListener(using: parameters)
        created.stateUpdateHandler = { state in
            if case .ready = state, let port = created.port {
                ready(.success(.hostPort(host: "127.0.0.1", port: port)))
            } else if case .failed(let error) = state {
                ready(.failure(error))
            }
        }
        created.newConnectionHandler = { [weak self] connection in
            guard let self, self.connection == nil, !self.closed else {
                connection.cancel();
                return
            }
            created.cancel();
            self.listener = nil;
            self.start(connection)
        }
        listener = created;
        created.start(queue: queue)
    }
    func connect(port: UInt16) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        start(NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: parameters))
    }
    private func start(_ connection: NWConnection) {
        self.connection = connection
        let waiting = early;
        early = [];
        queued = 0
        for bytes in waiting { receive(bytes) }
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.read()
            } else if case .failed = state {
                self?.close()
            } else if case .cancelled = state {
                self?.close()
            }
        }
        connection.start(queue: queue)
    }
    func receiveFragment(_ bytes: Data) {
        do {
            for part in try fragments.receive(bytes) {
                receivedBytes += part.count;
                receive(part)
            };
            progress()
        } catch {
            status("BLEFragmentRejected error=\(error)");
            close()
        }
    }
    func receive(_ bytes: Data) {
        guard !closed, queued + bytes.count <= 262144 else {
            close();
            return
        }
        queued += bytes.count
        // Notifications may precede the local TLS client accepting the endpoint.
        // Preserve these bytes: dropping even one fragment corrupts the TLS stream.
        guard let connection else {
            early.append(bytes);
            return
        }
        connection.send(
            content: bytes,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queued -= bytes.count
                if error != nil { self.close() }
            })
    }
    private func read() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, final, error in
            guard let self else { return }
            if error != nil {
                self.close();
                return
            }
            guard let data, !data.isEmpty else {
                if final { self.close() } else { self.read() };
                return
            }
            self.forwardedBytes += data.count;
            self.progress()
            self.forwardingGeneration += 1
            let round = self.forwardingGeneration
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.closed, self.forwardingGeneration == round else { return }
                self.status("BLEBridgeForwardTimeout")
                self.close()
            }
            self.forward(data) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard !self.closed else { return };
                    self.forwardingGeneration += 1;
                    if error != nil || final { self.close() } else { self.read() }
                }
            }
        }
    }
    func close() {
        guard !closed else { return };
        closed = true
        status(
            "BLEBridgeClosed rxBytes=\(receivedBytes) txBytes=\(forwardedBytes) nextExpected=\(fragments.nextExpected) pending=\(fragments.pendingCount) duplicates=\(fragments.duplicates)"
        )
        early = [];
        listener?.cancel();
        connection?.cancel();
        ended()
    }
    private func progress() {
        guard Date().timeIntervalSince(lastProgress) >= 5 else { return };
        lastProgress = Date()
        status(
            "BLEBridgeProgress rxBytes=\(receivedBytes) txBytes=\(forwardedBytes) nextExpected=\(fragments.nextExpected) pending=\(fragments.pendingCount) duplicates=\(fragments.duplicates)"
        )
    }
}
