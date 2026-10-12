import Foundation

public struct PeerIdentityStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func loadOrCreate() throws -> PeerID {
        let file = directory.appendingPathComponent("peer-id")
        if FileManager.default.fileExists(atPath: file.path) {
            let text = try String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let uuid = UUID(uuidString: text) else {
                throw IdentityError.invalidStoredIdentity
            }
            return PeerID(uuid)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = PeerID()
        try id.value.uuidString.lowercased().write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    public enum IdentityError: Error {
        case invalidStoredIdentity
    }
}
