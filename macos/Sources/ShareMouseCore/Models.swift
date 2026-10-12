import Foundation

public struct PeerID: Codable, Equatable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}

public struct GroupID: Codable, Equatable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}

public struct SessionID: Equatable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}

public enum PeerPlatform: String, Codable, Sendable {
    case windows, macOS
}

public enum Capability: String, Codable, Sendable {
    case keyboard, pointer, scroll, textClipboard, fileTransfer
    case tcp, udp, ble, bluetoothClassic
}

public struct Peer: Sendable {
    public let id: PeerID
    public let name: String
    public let platform: PeerPlatform
    public let capabilities: Set<Capability>

    public init(id: PeerID, name: String, platform: PeerPlatform, capabilities: Set<Capability>) {
        self.id = id
        self.name = name
        self.platform = platform
        self.capabilities = capabilities
    }
}
