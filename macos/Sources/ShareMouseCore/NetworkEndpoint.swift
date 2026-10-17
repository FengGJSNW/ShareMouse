import Darwin
import Foundation

public struct NetworkEndpoint: Codable, Sendable, Equatable, Hashable {
    public var host: String
    public var port: UInt16
    public init(host: String, port: UInt16) {
        self.host = host;
        self.port = port
    }
    public func valid(allowLoopback: Bool = false) -> Bool {
        var address = in_addr()
        guard port > 0, inet_pton(AF_INET, host, &address) == 1 else { return false }
        let bytes = host.split(separator: ".").compactMap { UInt8($0) }
        guard bytes.count == 4, bytes[0] > 0, bytes[0] < 224, allowLoopback || bytes[0] != 127,
            !(bytes[0] == 169 && bytes[1] == 254), !(bytes[0] == 198 && [18, 19].contains(bytes[1]))
        else { return false }
        return true
    }
    static func local(port: UInt16) -> [NetworkEndpoint] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [NetworkEndpoint] = [], cursor = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0, let address = item.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
                    == 0
            else { continue }
            let endpoint = NetworkEndpoint(
                host: String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), port: port
            )
            if endpoint.valid(), !result.contains(endpoint) { result.append(endpoint) }
        }
        return Array(result.prefix(8))
    }
}

struct NetworkAdvertisement: Codable, Sendable {
    var enabled: Bool
    var endpoints: [NetworkEndpoint]
}
