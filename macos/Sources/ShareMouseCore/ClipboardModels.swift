import Foundation

public struct ClipboardEntry: Codable, Sendable, Equatable {
    public var id: String
    public var sourcePeerID: String
    public var counter: UInt64
    public var timestamp: Int64
    public var kind: String
    public var byteCount: Int
    public var providers: [String]? = nil
    public var cut: Bool? = nil
    public var fileCount: Int? = nil
    public var totalBytes: Int64? = nil
    public var fileRevision: UInt64? = nil
    public static func newer(_ a: ClipboardEntry, than b: ClipboardEntry?) -> Bool {
        guard let b else { return true }
        if a.counter != b.counter { return a.counter > b.counter }
        if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
        return a.sourcePeerID > b.sourcePeerID
    }
}
struct ClipboardPacket: Codable, Sendable {
    var type: String
    var groupID: String
    var entry: ClipboardEntry?
    var entryID: String?
    var requestID: String?
    var offset: Int?
    var total: Int?
    var data: Data?
    var error: String?
    var present: Bool?
    init(_ type: String, _ groupID: String) { self.type = type; self.groupID = groupID }
}
public enum ClipboardError: Error { case unavailable, changed, tooLarge, invalidData }

public struct ClipboardContent: Codable, Sendable, Equatable {
    public var kind: String
    public var data: Data
    public var plainText: String?
    public init(kind: String, data: Data, plainText: String? = nil) { self.kind = kind; self.data = data; self.plainText = plainText }
    public static func text(_ value: String) -> ClipboardContent { ClipboardContent(kind: "text", data: Data(value.utf8), plainText: value) }
    public func validate() throws {
        guard ["text", "png", "url", "html", "rtf"].contains(kind), data.count <= (kind == "text" ? ClipboardService.maximumTextBytes : 16 * 1024 * 1024), (plainText?.utf8.count ?? 0) <= ClipboardService.maximumTextBytes else { throw ClipboardError.tooLarge }
        if kind == "png" {
            let bytes = [UInt8](data.prefix(24)); guard bytes.count == 24, Array(bytes.prefix(8)) == [137,80,78,71,13,10,26,10], Array(bytes[12..<16]) == [73,72,68,82] else { throw ClipboardError.invalidData }
            func number(_ start: Int) -> UInt64 { bytes[start..<(start + 4)].reduce(0) { ($0 << 8) | UInt64($1) } }
            let w = number(16), h = number(20); guard w > 0, h > 0, w <= 16384, h <= 16384, w * h <= 64_000_000 else { throw ClipboardError.tooLarge }
        } else if kind != "rtf" { guard let text = String(data: data, encoding: .utf8) else { throw ClipboardError.invalidData }; if kind == "url", URL(string: text)?.scheme == nil { throw ClipboardError.invalidData } }
    }
}
