import Foundation
public struct HistoryEntry: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var timestamp: Int64
    public var favorite: Bool
}
private struct HistoryPacket: Codable, Sendable {
    var type: String
    var groupID: String
    var requestID: String
    var entry: HistoryEntry?
    var total: Int?
    var offset: Int?
    var data: Data?
    var sharing: Bool? = nil
}
@MainActor
public final class HistoryService {
    private struct Saved: Codable { var entries: [HistoryEntry]; var capacity: Int; var shortcutKey: String; var modifiers: [String]; var visibleCount: Int?; var preferredSide: String? }
    private let id: String; private let file: URL; private let manager: SessionManager; private let changed: () -> Void
    private var group: SharedGroup?; private var online: Set<String> = []
    public private(set) var entries: [HistoryEntry] = []
    public private(set) var visibleCount = 5
    public private(set) var preferredSide = "right"
    public private(set) var capacity = 50
    public private(set) var shortcutKey = "KeyV"
    public private(set) var modifiers = ["Control", "Alt"]
    public private(set) var status = "在线设备实时同步；离线历史保留在本机"
    private var held: Set<String> = []; private var consumed: Set<String> = []
    public var opened: (() -> Void)?
    private struct Incoming { var peer: String; var entry: HistoryEntry?; var total = 0; var data = Data(); var count = 0; var completion: CheckedContinuation<Void, Error>? }
    private var incoming: [String: Incoming] = [:]
    private var stopped = false
    private var started = false
    private var syncing = false
    private var syncAgain = false
    public init(id: String, directory: URL, manager: SessionManager, changed: @escaping () -> Void) throws {
        self.id = id; self.manager = manager; self.changed = changed; file = directory.appendingPathComponent("clipboard-history.json")
        if let data = try? Data(contentsOf: file) { let saved = try JSONDecoder().decode(Saved.self, from: data); entries = saved.entries; capacity = saved.capacity; shortcutKey = saved.shortcutKey; modifiers = saved.modifiers; visibleCount = min(9, max(1, saved.visibleCount ?? 5)); preferredSide = saved.preferredSide == "left" ? "left" : "right" }
    }
    public func start() async { await manager.receive(channel: "history") { [weak self] peer, data in Task { @MainActor in await self?.receive(peer, data) } }; await manager.setCapability("clipboard-history", enabled: true); started = true; if online.contains(where: { $0 != id }) { Task { await self.sync() } } }
    public func update(_ group: SharedGroup?, online: [String]) {
        let different = self.group?.id != group?.id; let joined = Set(online).subtracting(self.online).subtracting([id]); self.group = group; self.online = Set(online)
        for (key, value) in incoming where different || !self.online.contains(value.peer) { incoming.removeValue(forKey: key)?.completion?.resume(throwing: ClipboardError.unavailable) }
        if started, group != nil, different || !joined.isEmpty { Task { await self.sync() } }
    }
    private func save() throws {
        entries.sort { $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp }
        var remaining = max(1, capacity - entries.filter(\.favorite).count)
        entries = entries.filter { if $0.favorite { return true }; if remaining > 0 { remaining -= 1; return true }; return false }
        try JSONEncoder().encode(Saved(entries: entries, capacity: capacity, shortcutKey: shortcutKey, modifiers: modifiers, visibleCount: visibleCount, preferredSide: preferredSide)).write(to: file, options: .atomic); changed()
    }
    public func remember(_ text: String, entryID: String? = nil, timestamp: Int64? = nil, favorite: Bool = false, broadcast: Bool = true) throws {
        guard text.utf8.count <= ClipboardService.maximumTextBytes else { throw ClipboardError.tooLarge }
        let old = entries.first { $0.text == text }; entries.removeAll { $0.text == text }
        entries.append(HistoryEntry(id: (old?.timestamp ?? 0) > (timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)) ? old!.id : entryID ?? old?.id ?? UUID().uuidString.lowercased(), text: text, timestamp: max(timestamp ?? Int64(Date().timeIntervalSince1970 * 1000), old?.timestamp ?? 0), favorite: favorite || old?.favorite == true)); try save()
        if broadcast, let item = entries.first(where: { $0.text == text }) { Task { await self.broadcast(item) } }
    }
    private func broadcast(_ entry: HistoryEntry) async {
        guard let group, !stopped else { return }
        for peer in online.subtracting([id]) { do { try await transmit(peer, group.id, UUID().uuidString.lowercased(), [entry], sharing: true) } catch { status = "部分设备同步未完成；可点击同步重试"; changed() } }
    }
    public func text(_ entryID: String) -> String? { entries.first { $0.id == entryID }?.text }
    public func favorite(_ entryID: String) throws { guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }; entries[index].favorite.toggle(); try save() }
    public func configure(capacity: Int, key: String, modifiers: [String]) throws {
        guard (1...1000).contains(capacity), key.utf8.count <= 32, !key.isEmpty, !modifiers.isEmpty, modifiers.allSatisfy({ ["Control", "Alt", "Shift", "Meta"].contains($0) }) else { throw ClipboardError.invalidData }
        self.capacity = capacity; shortcutKey = key; self.modifiers = modifiers; try save()
    }
    public func configurePopup(visibleCount: Int, preferredSide: String) throws {
        guard (1...9).contains(visibleCount), ["left", "right"].contains(preferredSide) else { throw ClipboardError.invalidData }
        self.visibleCount = visibleCount; self.preferredSide = preferredSide; try save()
    }
    public func capture(_ input: CapturedInput) -> Bool {
        guard let key = input.key, ["keyDown", "keyUp"].contains(input.type) else { return false }
        if input.type == "keyUp" { held.remove(key); return consumed.remove(key) != nil }
        held.insert(key); if consumed.contains(key) { return true }
        let current = held.subtracting([key]); if key == shortcutKey, modifiers.allSatisfy({ mod in current.contains { $0.hasPrefix(mod) } }), current.allSatisfy({ key in modifiers.contains { key.hasPrefix($0) } }) { consumed.insert(key); opened?(); return true }; return false
    }
    public func sync() async {
        guard let group else { status = "连接设备后自动同步；离线历史保留在本机"; changed(); return }
        guard !stopped else { return }
        if syncing { syncAgain = true; return }; syncing = true
        defer { syncing = false; if syncAgain, !stopped { syncAgain = false; Task { await self.sync() } } }
        status = "正在拉取在线设备历史…"; changed()
        var failed = false
        for peer in online where peer != id {
            let request = UUID().uuidString.lowercased()
            do { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                incoming[request] = Incoming(peer: peer, completion: continuation)
                Task { do { try await self.send(peer, HistoryPacket(type: "pull", groupID: group.id, requestID: request)) } catch { self.incoming.removeValue(forKey: request)?.completion?.resume(throwing: error) } }
                Task { try? await Task.sleep(for: .seconds(600)); self.incoming.removeValue(forKey: request)?.completion?.resume(throwing: ClipboardError.unavailable) }
            } } catch { failed = true }
        }
        status = failed ? "部分设备不可达；已收到的历史已保存" : "同步完成"; changed()
    }
    public func shareFavorites() async {
        guard let group else { return }; for peer in online where peer != id { do { try await transmit(peer, group.id, UUID().uuidString.lowercased(), entries.filter(\.favorite), sharing: true) } catch { status = "收藏分享未全部完成"; changed() } }
    }
    private func send(_ peer: String, _ packet: HistoryPacket) async throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]; if packet.type == "item" || packet.type == "done" {try await manager.sendBackground(peerID:peer,channel:"history",payload:encoder.encode(packet))} else {try await manager.send(peerID:peer,channel:"history",payload:encoder.encode(packet))} }
    private func transmit(_ peer: String, _ groupID: String, _ request: String, _ list: [HistoryEntry], sharing: Bool) async throws {
        for item in list {
            let bytes = Data(item.text.utf8); var metadata = item; metadata.text = ""; var offset = 0
            repeat { guard !stopped, group?.id == groupID else { return }; let count = min(await manager.backgroundPayloadLimit(peer), bytes.count - offset)
                try await send(peer, HistoryPacket(type: "item", groupID: groupID, requestID: request, entry: metadata, total: bytes.count, offset: offset, data: bytes.subdata(in: offset..<(offset + count)), sharing: sharing)); offset += count
            } while offset < bytes.count
        }
        try await send(peer, HistoryPacket(type: "done", groupID: groupID, requestID: request, sharing: sharing))
    }
    private func receive(_ peer: String, _ bytes: Data) async {
        guard !stopped, let group, online.contains(peer), let packet = try? JSONDecoder().decode(HistoryPacket.self, from: bytes), packet.groupID == group.id, UUID(uuidString: packet.requestID) != nil else { return }
        if packet.type == "pull" { try? await transmit(peer, group.id, packet.requestID, entries, sharing: false); return }
        if incoming[packet.requestID] == nil, packet.sharing == true, incoming.count < 4 { incoming[packet.requestID] = Incoming(peer: peer); Task { try? await Task.sleep(for: .seconds(600)); self.incoming.removeValue(forKey: packet.requestID) } }
        guard var state = incoming[packet.requestID], state.peer == peer else { return }
        if packet.type == "done" { guard state.entry == nil else { incoming.removeValue(forKey: packet.requestID)?.completion?.resume(throwing: ClipboardError.invalidData); return }; incoming.removeValue(forKey: packet.requestID)?.completion?.resume(); changed(); return }
        guard packet.type == "item", let entry = packet.entry, UUID(uuidString: entry.id) != nil, entry.text.isEmpty,
              let total = packet.total, (0...ClipboardService.maximumTextBytes).contains(total), let offset = packet.offset, let data = packet.data, data.count <= 20000, state.count < 10000 else { return }
        if state.entry == nil { guard offset == 0 else { return }; state.entry = entry; state.total = total; state.data = Data() }
        guard state.entry == entry, state.total == total, offset == state.data.count, state.data.count + data.count <= total else { return }
        state.data.append(data)
        if state.data.count == total { guard let text = String(data: state.data, encoding: .utf8) else { return }; try? remember(text, entryID: entry.id, timestamp: entry.timestamp, favorite: entry.favorite, broadcast: false); state.entry = nil; state.data = Data(); state.count += 1 }
        incoming[packet.requestID] = state
    }
    public func resetCapture() { held = []; consumed = [] }
    public func stop() { stopped = true; for state in incoming.values { state.completion?.resume(throwing: ClipboardError.unavailable) }; incoming = [:]; held = []; consumed = [] }
}
