import Foundation

@MainActor
public final class ClipboardService {
    nonisolated public static let maximumTextBytes = 4 * 1024 * 1024
    nonisolated public static let maximumContentBytes = 32 * 1024 * 1024
    private let id: String
    private let manager: SessionManager
    private let changed: (ClipboardEntry?) -> Void
    private let event: (String) -> Void
    private var group: SharedGroup?
    private var online: Set<String> = []
    private var clock: UInt64 = 0
    public var textForEntry: ((String) -> String?)?
    public private(set) var current: ClipboardEntry?
    private var owned: Data?
    private var cached: Data?
    private struct Download {
        var entry: ClipboardEntry
        var peer: String
        var data = Data()
        var continuation: CheckedContinuation<Data, Error>
    }
    private var downloads: [String: Download] = [:]
    private var stopped = false
    private struct Saved: Codable { var groupID: String?; var clock: UInt64; var current: ClipboardEntry?; var body: Data? }
    private var restored: Saved?
    private var stateFile: URL?
    private func notify(_ entry: ClipboardEntry?) {
        if let stateFile, let group { let saved = Saved(groupID: group.id, clock: clock, current: entry, body: entry?.sourcePeerID == id ? owned : cached); restored = saved
            do { try JSONEncoder().encode(saved).write(to: stateFile, options: .atomic) } catch { self.stateFile = nil; event("ClipboardPersistenceDisabled") }
        }; changed(entry)
    }
    public init(id: String, manager: SessionManager, changed: @escaping (ClipboardEntry?) -> Void, event: @escaping (String) -> Void, directory: URL? = nil) {
        self.id = id; self.manager = manager; self.changed = changed; self.event = event
        stateFile = directory?.appendingPathComponent("clipboard-current.json")
        if let stateFile, FileManager.default.fileExists(atPath: stateFile.path) { do { let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: stateFile)); restored = saved; clock = saved.clock } catch { self.stateFile = nil; event("ClipboardPersistenceDisabled") } }
    }
    public func start() async {
        await manager.receive(channel: "clipboard") { [weak self] peer, bytes in Task { @MainActor in await self?.receive(peer, bytes) } }
        await manager.setCapability("clipboard-text", enabled: true)
        await manager.setCapability("clipboard-rich", enabled: true)
        if let group { for peer in online where peer != id { try? await send(peer, ClipboardPacket("current", group.id)) } }
    }
    public func update(_ group: SharedGroup?, online: [String]) {
        let added = Set(online).subtracting(self.online)
        if self.group?.id != group?.id { cancelDownloads(ClipboardError.changed); current = nil; owned = nil; cached = nil }
        self.group = group; self.online = Set(online)
        if current == nil, let restored, restored.groupID == group?.id, group != nil { current = restored.current; if let bytes = restored.body, bytes.count == current?.byteCount, bytes.count <= Self.maximumContentBytes { if current?.sourcePeerID == id { owned = bytes } else { cached = bytes } }; notify(current) }
        else if current == nil { notify(nil) }
        for (request, download) in downloads where !self.online.contains(download.peer) { downloads.removeValue(forKey: request)?.continuation.resume(throwing: ClipboardError.unavailable) }
        for peer in added where peer != id { Task { if let current = self.current { try? await self.sendMetadata(peer, current) }; if let group = self.group { try? await self.send(peer, ClipboardPacket("current", group.id)) } } }
    }
    public func publishText(_ text: String?) async throws { try await publishContent(text.map(ClipboardContent.text)) }
    public func publishContent(_ content: ClipboardContent?) async throws {
        guard let group else { return }
        var bytes: Data?; var accepted = content; var failure: Error?
        do { if let content { try content.validate(); bytes = content.kind == "text" ? content.data : try JSONEncoder().encode(content); guard bytes!.count <= Self.maximumContentBytes else { throw ClipboardError.tooLarge } } }
        catch { accepted = nil; bytes = nil; failure = error }
        guard clock < UInt64.max - 1 else { throw ClipboardError.tooLarge }; clock += 1
        let entry = ClipboardEntry(id: UUID().uuidString.lowercased(), sourcePeerID: id, counter: clock,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000), kind: accepted?.kind ?? "unsupported", byteCount: bytes?.count ?? 0)
        cancelDownloads(ClipboardError.changed); current = entry; owned = bytes; cached = nil; notify(entry)
        for peer in online where peer != id { try? await sendMetadata(peer, entry) }
        event("ClipboardMetadataPublished groupId=\(group.id)"); if let failure { throw failure }
    }
    public func publishFiles(count: Int, bytes: Int64, cut: Bool, prepare: ((ClipboardEntry) throws -> Void)? = nil) async throws -> ClipboardEntry {
        guard let group, clock < UInt64.max - 1 else { throw ClipboardError.unavailable }
        clock += 1
        var entry = ClipboardEntry(id: UUID().uuidString.lowercased(), sourcePeerID: id, counter: clock,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000), kind: "files", byteCount: 0)
        entry.providers = [id]; entry.cut = cut; entry.fileCount = count; entry.totalBytes = bytes; entry.fileRevision = 1
        try prepare?(entry)
        cancelDownloads(ClipboardError.changed); current = entry; owned = nil; cached = nil; notify(entry)
        for peer in online where peer != id { try? await sendMetadata(peer, entry) }
        event("FileClipboardPublished groupId=\(group.id)"); return entry
    }
    public func restoreFiles(_ entry: ClipboardEntry, groupID: String) {
        guard group?.id == groupID, current == nil, restored == nil, entry.kind == "files" else { return }
        current = entry; clock = max(clock, entry.counter); notify(entry)
        for peer in online where peer != id { Task { try? await self.sendMetadata(peer, entry) } }
    }
    public func fileVersion(count: Int, bytes: Int64) async throws -> ClipboardEntry {
        guard let group, var entry = current, entry.sourcePeerID == id, entry.kind == "files" else { throw ClipboardError.changed }
        entry.fileRevision = (entry.fileRevision ?? 1) + 1; entry.fileCount = count; entry.totalBytes = bytes; entry.providers = [id]
        current = entry; notify(entry)
        var packet = ClipboardPacket("fileVersion", group.id); packet.entry = entry
        for peer in online where peer != id { try? await send(peer, packet) }; return entry
    }
    private func applyProvider(_ peer: String, present: Bool) {
        guard var entry = current else { return }
        var providers = Set(entry.providers ?? [])
        if present { providers.insert(peer) } else { providers.remove(peer) }
        entry.providers = providers.sorted { a, b in a == entry.sourcePeerID ? true : b == entry.sourcePeerID ? false : a < b }
        current = entry; notify(entry)
    }
    public func provideFiles(_ present: Bool) async {
        guard let group, let entry = current, entry.kind == "files" else { return }
        applyProvider(id, present: present)
        var packet = ClipboardPacket("provider", group.id); packet.entryID = entry.id; packet.present = present
        for peer in online where peer != id { try? await send(peer, packet) }
    }
    private func body() async throws -> Data {
        guard !stopped, let entry = current, ["text", "png", "url", "html", "rtf"].contains(entry.kind) else { throw ClipboardError.unavailable }
        let bytes: Data
        if entry.kind == "text", entry.sourcePeerID == id, owned == nil, let text = textForEntry?(entry.id), text.utf8.count == entry.byteCount { owned = Data(text.utf8) }
        if let stored = entry.sourcePeerID == id ? owned : cached { bytes = stored }
        else {
            guard entry.sourcePeerID != id, online.contains(entry.sourcePeerID), downloads.count < 4, let group else { throw ClipboardError.unavailable }
            let request = UUID().uuidString.lowercased()
            bytes = try await withCheckedThrowingContinuation { continuation in
                downloads[request] = Download(entry: entry, peer: entry.sourcePeerID, continuation: continuation)
                var packet = ClipboardPacket("request", group.id); packet.entryID = entry.id; packet.requestID = request
                Task { do { try await self.send(entry.sourcePeerID, packet) } catch { self.fail(request, ClipboardError.unavailable) } }
                Task { try? await Task.sleep(for: .seconds(600)); self.fail(request, ClipboardError.unavailable) }
            }
            guard current?.id == entry.id else { throw ClipboardError.changed }; cached = bytes; notify(current)
        }
        return bytes
    }
    public func content() async throws -> ClipboardContent {
        guard let entry = current else { throw ClipboardError.unavailable }; let bytes = try await body()
        guard current?.id == entry.id else { throw ClipboardError.changed }
        let result: ClipboardContent
        if entry.kind == "text" { guard let text = String(data: bytes, encoding: .utf8) else { throw ClipboardError.invalidData }; result = .text(text) }
        else { result = try JSONDecoder().decode(ClipboardContent.self, from: bytes); guard result.kind == entry.kind else { throw ClipboardError.invalidData } }
        try result.validate(); return result
    }
    public func text() async throws -> String { guard let text = try await content().plainText else { throw ClipboardError.unavailable }; return text }
    public func waitForEntry(_ entryID: String, from peer: String) async throws {
        guard UUID(uuidString: entryID) != nil, let groupID = group?.id, !stopped else { throw ClipboardError.changed }
        if current?.id == entryID { return }
        guard online.contains(peer), peer != id else { throw ClipboardError.unavailable }
        try await send(peer, ClipboardPacket("current", groupID))
        let deadline = ContinuousClock.now + .seconds(2)
        while current?.id != entryID {
            guard !stopped, group?.id == groupID, online.contains(peer), ContinuousClock.now < deadline else { throw ClipboardError.changed }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard group?.id == groupID, !stopped else { throw ClipboardError.changed }
    }
    private func send(_ peer: String, _ packet: ClipboardPacket) async throws { try await manager.send(peerID: peer, channel: "clipboard", payload: JSONEncoder().encode(packet)) }
    private func sendMetadata(_ peer: String, _ entry: ClipboardEntry) async throws {
        guard let group else { return }; var packet = ClipboardPacket("metadata", group.id); packet.entry = entry; try await send(peer, packet)
    }
    private func receive(_ peer: String, _ bytes: Data) async {
        guard !stopped, let group, online.contains(peer), let packet = try? JSONDecoder().decode(ClipboardPacket.self, from: bytes), packet.groupID == group.id else { return }
        switch packet.type {
        case "current": if let current { try? await sendMetadata(peer, current) }
        case "metadata":
            guard let entry = packet.entry, UUID(uuidString: entry.id) != nil, group.members.contains(where: { $0.peerID == entry.sourcePeerID }),
                  entry.counter < UInt64.max - 1, ["text", "unsupported", "files", "png", "url", "html", "rtf"].contains(entry.kind), (0...(entry.kind == "text" ? Self.maximumTextBytes : Self.maximumContentBytes)).contains(entry.byteCount) else { return }
            clock = max(clock, entry.counter)
            if ClipboardEntry.newer(entry, than: current) { cancelDownloads(ClipboardError.changed); current = entry; owned = nil; cached = nil; notify(entry); event("ClipboardMetadataReceived") }
            else if let old = current, old.id == entry.id, old.kind == "files", entry.kind == "files", old.sourcePeerID == entry.sourcePeerID, old.counter == entry.counter {
                if peer == entry.sourcePeerID, (entry.fileRevision ?? 1) > (old.fileRevision ?? 1) { current = entry; notify(entry) }
                else if entry.fileRevision == old.fileRevision { applyProvider(peer, present: entry.providers?.contains(peer) == true) }
            }
        case "provider":
            guard current?.kind == "files", current?.id == packet.entryID, let present = packet.present else { return }
            applyProvider(peer, present: present)
        case "fileVersion":
            guard let entry = packet.entry, let current, entry.id == current.id, entry.sourcePeerID == peer,
                  entry.kind == "files", (entry.fileRevision ?? 1) > (current.fileRevision ?? 1) else { return }
            self.current = entry; notify(entry)
        case "request":
            guard let request = packet.requestID, request.utf8.count <= 64, let entry = current else { return }
            if entry.kind == "text", entry.sourcePeerID == id, owned == nil, let text = textForEntry?(entry.id), text.utf8.count == entry.byteCount { owned = Data(text.utf8) }
            guard entry.sourcePeerID == id, entry.id == packet.entryID, let owned else {
                var reply = ClipboardPacket("error", group.id); reply.requestID = request; reply.error = "sourceUnavailable"; try? await send(peer, reply); return
            }
            event("ClipboardTextRequested")
            var offset = 0
            repeat {
                guard self.group?.id == group.id, current?.id == entry.id else { return }
                let count = min(20000, owned.count - offset)
                var reply = ClipboardPacket("data", group.id); reply.requestID = request; reply.entryID = entry.id
                reply.offset = offset; reply.total = owned.count; reply.data = owned.subdata(in: offset..<(offset + count))
                do { try await send(peer, reply) } catch { return }; offset += count
            } while offset < owned.count
        case "data":
            guard let request = packet.requestID, var download = downloads[request], download.peer == peer, download.entry.id == packet.entryID,
                  let data = packet.data, data.count <= 20000, packet.offset == download.data.count, packet.total == download.entry.byteCount,
                  download.data.count + data.count <= download.entry.byteCount else { return }
            download.data.append(data); downloads[request] = download
            if download.data.count == download.entry.byteCount { downloads.removeValue(forKey: request); download.continuation.resume(returning: download.data) }
        case "error": if let request = packet.requestID, downloads[request]?.peer == peer { fail(request, ClipboardError.unavailable) }
        default: break
        }
    }
    private func fail(_ request: String, _ error: Error) { downloads.removeValue(forKey: request)?.continuation.resume(throwing: error) }
    private func cancelDownloads(_ error: Error) { let pending = downloads; downloads = [:]; for download in pending.values { download.continuation.resume(throwing: error) } }
    public func stop() { stopped = true; cancelDownloads(ClipboardError.unavailable) }
}
