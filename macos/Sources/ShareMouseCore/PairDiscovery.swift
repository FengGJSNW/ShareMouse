import Darwin
import Foundation

/// Unauthenticated discovery hints only. Pairing always verifies the TLS identity.
public struct PairDiscoveryHint: Codable, Sendable {
    public var protocolID = "sharemouse-discovery-v1"
    public var peerID: String
    public var pairCode: String
    public var port: UInt16 = 49160
}
public final class PairDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ShareMouse.PairDiscovery")
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var local: PairDiscoveryHint
    private var enabled = true
    private var peers: [String: (PairDiscoveryHint, String, Date)] = [:]
    private let changed: @Sendable ([(PairDiscoveryHint, String)]) -> Void
    public init(peerID: String, code: String, changed: @escaping @Sendable ([(PairDiscoveryHint, String)]) -> Void) {
        local = PairDiscoveryHint(peerID: peerID, pairCode: code);
        self.changed = changed
    }
    public func start() {
        queue.async { [self] in
            guard socketFD < 0 else { return }
            let fd = socket(AF_INET, SOCK_DGRAM, 0);
            guard fd >= 0 else { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            var address = sockaddr_in();
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size);
            address.sin_family = sa_family_t(AF_INET);
            address.sin_port = UInt16(49161).bigEndian
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                close(fd);
                return
            };
            socketFD = fd
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.receive() };
            reader.setCancelHandler { close(fd) }
            source = reader;
            reader.resume()
            let tick = DispatchSource.makeTimerSource(queue: queue);
            tick.schedule(deadline: .now(), repeating: 10)
            tick.setEventHandler { [weak self] in
                self?.announce();
                self?.publish()
            };
            timer = tick;
            tick.resume()
        }
    }
    public func update(code: String, enabled: Bool) {
        queue.async { [self] in
            local.pairCode = code;
            self.enabled = enabled;
            if !enabled {
                peers = [:];
                publish()
            };
            announce()
        }
    }
    private func send(_ host: String) {
        guard enabled, socketFD >= 0, let bytes = try? JSONEncoder().encode(local) else { return }
        var address = sockaddr_in();
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size);
        address.sin_family = sa_family_t(AF_INET);
        address.sin_port = UInt16(49161).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }
        bytes.withUnsafeBytes { data in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(socketFD, data.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    public func announce() {
        send("255.255.255.255")
        var list: UnsafeMutablePointer<ifaddrs>?;
        guard getifaddrs(&list) == 0 else { return };
        defer { freeifaddrs(list) }
        var item = list
        while let node = item {
            defer { item = node.pointee.ifa_next }
            guard let address = node.pointee.ifa_addr, address.pointee.sa_family == AF_INET,
                node.pointee.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) == UInt32(IFF_UP | IFF_BROADCAST),
                let mask = node.pointee.ifa_netmask
            else { continue }
            let a = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let m = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            var target = in_addr(s_addr: a | ~m);
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &target, &text, socklen_t(text.count)) != nil {
                send(String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
    }
    private func receive() {
        guard enabled else {
            var buffer = [UInt8](repeating: 0, count: 1024);
            while recv(socketFD, &buffer, buffer.count, 0) > 0 {};
            return
        }
        var buffer = [UInt8](repeating: 0, count: 1024)
        for _ in 0..<32 {
            var address = sockaddr_in();
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketFD, &buffer, buffer.count, 0, $0, &size)
                }
            }
            guard count > 0 else { return }
            guard let hint = try? JSONDecoder().decode(PairDiscoveryHint.self, from: Data(buffer.prefix(count))),
                hint.protocolID == local.protocolID, UUID(uuidString: hint.peerID) != nil, hint.peerID != local.peerID,
                hint.pairCode.count == 6, hint.pairCode.allSatisfy({ $0.isASCII && $0.isNumber }), hint.port > 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN));
            inet_ntop(AF_INET, &address.sin_addr, &host, socklen_t(host.count))
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self);
            guard NetworkEndpoint(host: text, port: hint.port).valid() else { continue }
            let isNew = peers[hint.peerID] == nil;
            if peers.count < 128 || !isNew {
                peers[hint.peerID] = (hint, text, Date());
                publish()
            }
            if isNew { send(text) }
        }
    }
    private func publish() {
        peers = peers.filter { Date().timeIntervalSince($0.value.2) < 35 };
        changed(peers.values.map { ($0.0, $0.1) })
    }
    public func stop() {
        queue.async { [self] in
            timer?.cancel();
            timer = nil;
            source?.cancel();
            source = nil;
            socketFD = -1
        }
    }
}
