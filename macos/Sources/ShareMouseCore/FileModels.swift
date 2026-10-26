import Foundation

public struct FileItem: Codable, Sendable, Equatable {
    public var id: String
    public var rootID: String
    public var relativePath: String
    public var directory: Bool
    public var size: Int64
    public var modified: Int64
    public var hash: String? = nil
    public var available: Bool = true
    public var linkTarget: String? = nil
    public var linkDirectory: Bool? = nil
}
public struct LocalFile: Codable, Sendable {
    public var item: FileItem
    public var path: String
    public var identity: String
}
public struct LocalRoot: Codable, Sendable {
    public var id: String;
    public var path: String
}
public struct FileTransaction: Codable, Sendable {
    public var entry: ClipboardEntry
    public var groupID: String
    public var roots: [LocalRoot]
    public var files: [LocalFile]
    public var originalCut: Bool
}
public struct FilePermit: Codable, Sendable {
    public var taskID: String
    public var peerID: String
    public var transaction: FileTransaction
    public var verified: [String]
    public var cutSource: FileTransaction? = nil
}
public final class TransferFile: Codable, @unchecked Sendable {
    public var item: FileItem
    public var provider: String
    public var target: String
    public var partial: String
    public var received: Int64 = 0
    public var completed = false
    public var completedIdentity: String? = nil
    public var skipped = false
    public var error: String? = nil
    public init(item: FileItem, provider: String, target: String, partial: String) {
        self.item = item;
        self.provider = provider;
        self.target = target;
        self.partial = partial
    }
}
public final class TransferTask: Codable, @unchecked Sendable {
    public var id: String
    public var entry: ClipboardEntry
    public var groupID: String
    public var destination: String
    public var direction: String? = nil
    public var transport: String? = nil
    public var remotePeerID: String? = nil
    public var controlRevision: UInt64? = nil
    public var receivedControls: [String: UInt64]? = nil
    public var pausedBy: String? = nil
    public var state = "queued"
    public var files: [TransferFile] = []
    public var error: String? = nil
    public var created = Int64(Date().timeIntervalSince1970 * 1000)
    public var received: Int64 {
        files.filter { !$0.item.directory }.reduce(0) { $0 + ($1.completed ? $1.item.size : $1.received) }
    }
    public var total: Int64 { files.isEmpty ? entry.totalBytes ?? 0 : files.reduce(0) { $0 + $1.item.size } }
    public init(id: String, entry: ClipboardEntry, groupID: String, destination: String) {
        self.id = id;
        self.entry = entry;
        self.groupID = groupID;
        self.destination = destination
    }
}
struct FileTransferStore: Codable {
    var transactions: [FileTransaction];
    var permits: [FilePermit];
    var tasks: [TransferTask];
    var replicas: [FileTransaction]? = nil
    var progressGeneration: String? = nil
}
// Progress is small and separate from the immutable catalogue/history. A full
// save changes generation so a crash cannot replay offsets over newer state.
struct FileProgressStore: Codable {
    var generation: String
    var tasks: [String: [String: Int64]]
}
struct FilePacket: Codable, Sendable {
    var type: String
    var groupID: String
    var entryID: String
    var taskID: String
    var controlRevision: UInt64? = nil
    var state: String? = nil
    var requestID: String?
    var entry: ClipboardEntry?
    var items: [FileItem]?
    var itemID: String?
    var index: Int?
    var final: Bool?
    var offset: Int64?
    var maximumBytes: Int?
    var data: Data?
    var checksum: UInt32?
    var hash: String?
    var error: String?
    var expandedCatalogue: Bool?
    var verified: [String]?
    init(_ type: String, groupID: String, entryID: String, taskID: String) {
        self.type = type;
        self.groupID = groupID;
        self.entryID = entryID;
        self.taskID = taskID
    }
}
public enum ChunkCheck {
    public static func adler32(_ bytes: Data) -> UInt32 {
        var a: UInt32 = 1;
        var b: UInt32 = 0;
        for value in bytes {
            a = (a + UInt32(value)) % 65521;
            b = (b + a) % 65521
        };
        return (b << 16) | a
    }
}
public enum FileTransferError: Error, Equatable {
    case unavailable, changed, invalidPath, invalidDataSize, corrupt, cancelled, paused
}
