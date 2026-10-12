import Foundation

@MainActor
public final class FileTransferService {
    private let id: String
    private let file: URL
    private let manager: SessionManager
    private let clipboard: ClipboardService
    private let changed: ([TransferTask]) -> Void
    private let event: (String) -> Void
    private let additionalFiles: ([String]) async -> String
    private let sourceChanged: ([String]) async -> Bool
    private let conflict: (String, Bool, Bool) async -> String
    private var conflictRules: [String: String] = [:]
    private let partialFailure: (TransferTask) async -> String
    private let deleteAll: ([String]) async -> Bool
    private var group: SharedGroup?
    private var online: Set<String> = []
    private var transactions: [String: FileTransaction] = [:]
    private var pendingCopies: [String: Task<(roots: [LocalRoot], files: [LocalFile]), Error>] = [:]
    private var pendingPaths: [String: [String]] = [:]
    private var replicas: [String: FileTransaction] = [:]
    private var permits: [String: FilePermit] = [:]
    private var tasks: [String: TransferTask] = [:]
    private var running: Set<String> = []
    private var transports: [String: String] = [:]
    private var sourceBusy: Set<String> = []
    private var sourceWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cutOwners: [String: String] = [:]
    private var cutJobs: [String: Task<Void, Error>] = [:]
    private var stopped = false
    public var currentTasks: [TransferTask] { tasks.values.sorted { $0.created > $1.created } }
    private struct Pending {
        var peer: String
        var request: FilePacket
        var packets: [FilePacket] = []
        var continuation: CheckedContinuation<[FilePacket], Error>
    }
    private var pending: [String: Pending] = [:]
    private var chunkRequests: [String:Int] = [:]
    public init(id: String, directory: URL, manager: SessionManager, clipboard: ClipboardService,
                changed: @escaping ([TransferTask]) -> Void, event: @escaping (String) -> Void,
                sourceChanged: @escaping ([String]) async -> Bool, conflict: @escaping (String, Bool, Bool) async -> String,
                partialFailure: @escaping (TransferTask) async -> String, deleteAll: @escaping ([String]) async -> Bool, additionalFiles: @escaping ([String]) async -> String = { _ in "exclude" }) throws {
        self.id = id; self.manager = manager; self.clipboard = clipboard; self.changed = changed; self.event = event
        self.additionalFiles = additionalFiles
        self.sourceChanged = sourceChanged; self.conflict = conflict; self.partialFailure = partialFailure; self.deleteAll = deleteAll
        file = directory.appendingPathComponent("file-transfers.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let saved = try JSONDecoder().decode(FileTransferStore.self, from: Data(contentsOf: file))
            transactions = Dictionary(uniqueKeysWithValues: saved.transactions.map { ($0.entry.id, $0) })
            replicas = Dictionary(uniqueKeysWithValues: (saved.replicas ?? []).map { ($0.entry.id, $0) })
            permits = Dictionary(uniqueKeysWithValues: saved.permits.map { ($0.taskID, $0) })
            for task in saved.tasks { if ["running", "queued"].contains(task.state) { task.state = "paused"; task.pausedBy = task.direction == "send" ? task.remotePeerID : id }; tasks[task.id] = task }
        }
    }
    public func start() async {
        await manager.receive(channel: "files") { [weak self] peer, bytes in Task { @MainActor in await self?.receive(peer, bytes) } }
        await manager.setCapability("files", enabled: true)
        await manager.setCapability("file-symlink-v1",enabled:true)
        await manager.setCapability("compact-file-v1",enabled:true)
    }
    private var checkpoints: [String: (bytes: Int64, time: ContinuousClock.Instant)] = [:]
    private func progress(_ task: TransferTask, bytes: Int64) throws { if let previous = checkpoints[task.id], previous.time.duration(to: .now) < .milliseconds(500), bytes - previous.bytes < 1024 * 1024 { return }; checkpoints[task.id] = (bytes, .now); try save() }
    private func save() throws {
        try JSONEncoder().encode(FileTransferStore(transactions: Array(transactions.values), permits: Array(permits.values), tasks: currentTasks, replicas: Array(replicas.values))).write(to: file, options: .atomic)
        changed(currentTasks)
    }
    public func clipboardChanged(_ entry: ClipboardEntry?) {
        guard let entry else { return }; var updated = false
        for (key, job) in cutJobs where key != entry.id { job.cancel() }
        for key in Array(transactions.keys) where transactions[key]?.originalCut == true && key != entry.id { transactions[key]?.originalCut = false; updated = true }
        for key in Array(permits.keys) where permits[key]?.transaction.originalCut == true && permits[key]?.transaction.entry.id != entry.id { permits[key]?.transaction.originalCut = false; permits[key]?.cutSource?.originalCut = false; updated = true }
        if updated { try? save() }
    }
    public func update(_ value: SharedGroup?, online: [String], sessions: [SessionInfo]) {
        let different = group?.id != value?.id; group = value; self.online = Set(online)
        for session in sessions {
            let selected = session.capabilities.contains("tcp") ? "tcp" : session.capabilities.contains("quic") ? "quic" : session.capabilities.contains("ble") ? "ble" : "none"
            if let old = transports[session.peerID], old != selected, tasks.values.contains(where: { $0.state == "running" && $0.files.contains { $0.provider == session.peerID } }) { event("TransferTransportChanged kind=\(selected)") }
            transports[session.peerID] = selected
        }
        if different { for job in cutJobs.values { job.cancel() }; for task in tasks.values where task.state == "running" { task.state = "paused" } }
        var taskChanged = false; for task in tasks.values where task.direction == "send" && ["queued", "running"].contains(task.state) && task.remotePeerID.map({ !self.online.contains($0) }) == true { task.state = "paused"; task.pausedBy = task.remotePeerID; stopCut(task); taskChanged = true }
        for (key, request) in pending where different || !self.online.contains(request.peer) { fail(key, FileTransferError.unavailable) }
        if let group, clipboard.current == nil, let restored = transactions.values.filter({ $0.groupID == group.id }).max(by: { $0.entry.counter < $1.entry.counter }) { clipboard.restoreFiles(restored.entry, groupID: group.id) }
        if different || taskChanged { try? save() }
    }
    public func copy(_ paths: [String], cut: Bool, stillCurrent: (() -> Bool)? = nil) async throws {
        guard let group, !paths.isEmpty else { throw FileTransferError.unavailable }
        let scan = Task { let (roots, files) = try await FileStorage.scan(paths); return (roots: roots, files: files) }
        var entry = try await clipboard.publishFiles(count: 0, bytes: 0, cut: cut) { entry in self.pendingCopies[entry.id] = scan; self.pendingPaths[entry.id] = paths }
        defer { pendingCopies.removeValue(forKey: entry.id); pendingPaths.removeValue(forKey: entry.id) }
        do { let result = try await scan.value
            guard self.group?.id == group.id, clipboard.current?.id == entry.id, stillCurrent?() != false else { throw FileTransferError.changed }
            entry = try await clipboard.fileVersion(count: result.files.count, bytes: result.files.reduce(0) { $0 + $1.item.size })
            transactions[entry.id] = FileTransaction(entry: entry, groupID: group.id, roots: result.roots, files: result.files, originalCut: cut && clipboard.current?.id == entry.id); try save()
        } catch { if clipboard.current?.id == entry.id { await clipboard.provideFiles(false) }; throw error }
    }
    private func replicaUnchanged(_ file: LocalFile) -> Bool { guard file.item.directory else { return FileStorage.unchanged(file) }; return (try? FileStorage.inspect(file.path, template: file.item).identity) == file.identity }
    private func send(_ peer: String, _ packet: FilePacket) async throws {
        let compact=await manager.hasCapability(peer,"compact-file-v1")
        let bytes = try FilePacketCodec.encode(packet,compact:compact)
        if peer == id { Task { await self.receive(self.id, bytes) }; return }
        let kind = try await manager.sendBulkTracked(peerID: peer, channel: "files", payload: bytes)
        if let task = tasks[packet.taskID], task.transport != kind { task.transport = kind; changed(currentTasks) }
    }
    private func exchange(_ peer: String, _ request: FilePacket) async throws -> [FilePacket] {
        var packet = request; let requestID = UUID().uuidString.lowercased(); packet.requestID = requestID
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = Pending(peer: peer, request: packet, continuation: continuation)
            Task { do { try await self.send(peer, packet) } catch { self.fail(requestID, error) } }
            Task { try? await Task.sleep(for: .seconds(["offer", "receipt", "delete-all"].contains(packet.type) ? 600 : 20)); self.fail(requestID, FileTransferError.unavailable) }
        }
    }
    private func fail(_ request: String, _ error: Error) { pending.removeValue(forKey: request)?.continuation.resume(throwing: error) }
    private func receive(_ peer: String, _ bytes: Data) async {
        let compact=await manager.hasCapability(peer,"compact-file-v1")
        guard !stopped, let group, online.contains(peer), let packet = try? FilePacketCodec.decode(bytes,compact:compact),
              packet.groupID == group.id, UUID(uuidString: packet.taskID) != nil, UUID(uuidString: packet.entryID) != nil else { return }
        if ["offer-data", "chunk-data", "receipt-ok", "delete-ok", "error"].contains(packet.type) {
            guard let requestID = packet.requestID, var waiting = pending[requestID], waiting.peer == peer,
                  waiting.request.entryID == packet.entryID, waiting.request.taskID == packet.taskID else { return }
            let expected = ["offer":"offer-data", "chunk":"chunk-data", "receipt":"receipt-ok", "delete-all":"delete-ok"][waiting.request.type]
            if packet.type == "error" { fail(requestID, packet.error == "cancelledByUser" ? FileTransferError.cancelled : FileTransferError.unavailable); return }
            guard packet.type == expected, waiting.packets.count < 12501, packet.index == waiting.packets.count else { fail(requestID, FileTransferError.corrupt); return }
            waiting.packets.append(packet); pending[requestID] = waiting
            if packet.final == true { pending.removeValue(forKey: requestID); waiting.continuation.resume(returning: waiting.packets) }; return
        }
        if packet.type == "finish", let task = tasks[packet.taskID], task.direction == "send", task.remotePeerID == peer, task.entry.id == packet.entryID,
           let state = packet.state, ["completed", "failed", "paused", "cancelled"].contains(state), task.pausedBy != id, (packet.controlRevision ?? 0) >= (task.receivedControls?[peer] ?? 0), packet.entry?.fileRevision == task.entry.fileRevision {
            task.state = task.error == nil ? state : "failed"; task.error = task.error ?? packet.error; try? save(); return
        }
        if ["pause", "resume", "cancel"].contains(packet.type), let task = tasks[packet.taskID], task.entry.id == packet.entryID,
           task.direction == "send" ? task.remotePeerID == peer : task.files.contains(where: { $0.provider == peer }) {
            guard let revision = packet.controlRevision, revision > (task.receivedControls?[peer] ?? 0) else { return }; if task.receivedControls == nil { task.receivedControls = [:] }; task.receivedControls?[peer] = revision
            if packet.type == "resume" { if task.pausedBy == peer || task.pausedBy == nil && task.direction == "send" && task.state == "paused" { task.pausedBy = nil; if task.direction == "send" { task.state = "running" } else { Task { await self.run(task) } }; try? save() } }
            else { task.pausedBy = peer; task.state = packet.type == "pause" ? "paused" : "cancelled"; stopCut(task); for (key, request) in pending where request.request.taskID == task.id { fail(key, FileTransferError.paused) }; try? save() }; return
        }
        if packet.type == "offer", peer != id, tasks[packet.taskID] == nil, let paths = pendingPaths[packet.entryID], let preparing = clipboard.current, preparing.id == packet.entryID {
            let task = TransferTask(id: packet.taskID, entry: preparing, groupID: packet.groupID, destination: URL(fileURLWithPath: paths[0]).deletingLastPathComponent().path); task.direction = "send"; task.remotePeerID = peer; tasks[packet.taskID] = task; try? save()
        }
        if packet.type == "offer", peer != id, tasks[packet.taskID] == nil, let preview = transactions[packet.entryID], let root = preview.roots.first {
            let task = TransferTask(id: packet.taskID, entry: preview.entry, groupID: preview.groupID, destination: URL(fileURLWithPath: root.path).deletingLastPathComponent().path)
            task.direction = "send"; task.remotePeerID = peer; task.files = preview.files.map { TransferFile(item: $0.item, provider: id, target: $0.path, partial: "") }; tasks[packet.taskID] = task; try? save()
        }
        Task { await self.serve(peer, packet) }
    }
    private func reply(_ request: FilePacket, _ type: String) -> FilePacket {
        var packet = FilePacket(type, groupID: request.groupID, entryID: request.entryID, taskID: request.taskID)
        packet.requestID = request.requestID; packet.index = 0; packet.final = true; return packet
    }
    private func acquireSource(_ entryID: String) async {
        if sourceBusy.contains(entryID) { await withCheckedContinuation { sourceWaiters[entryID, default: []].append($0) } }
        else { sourceBusy.insert(entryID) }
    }
    private func releaseSource(_ entryID: String) {
        if sourceWaiters[entryID]?.isEmpty == false { sourceWaiters[entryID]!.removeFirst().resume() }
        else { sourceBusy.remove(entryID) }
    }
    private func serve(_ peer: String, _ request: FilePacket) async {
        let locked = ["offer", "receipt", "delete-all"].contains(request.type)
        if locked { await acquireSource(request.entryID) }; defer { if locked { releaseSource(request.entryID) } }
        do {
            guard !stopped, group?.id == request.groupID, online.contains(peer), let requestID = request.requestID, requestID.utf8.count <= 64 else { throw FileTransferError.unavailable }
            if request.type == "offer" {
                if let scan = pendingCopies[request.entryID] { _ = try await scan.value; while pendingCopies[request.entryID] != nil { try await Task.sleep(for: .milliseconds(10)) } }
                if let task = tasks[request.taskID], task.direction == "send", ["paused", "cancelled"].contains(task.state) { throw FileTransferError.paused }
                let previous = permits[request.taskID]
                if let previous, previous.peerID != peer || previous.transaction.entry.id != request.entryID { throw FileTransferError.invalidPath }
                guard var transaction = transactions[request.entryID], transaction.groupID == request.groupID,
                      clipboard.current?.id == request.entryID || previous != nil else { throw FileTransferError.unavailable }
                // Completed targets remain providers. Rescan their directories too: a folder's
                // identity alone cannot reveal a newly added descendant.
                let livePaths = transaction.roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
                if previous == nil, !livePaths.isEmpty, transaction.files.contains(where: { $0.item.directory }) {
                    let (roots, scanned) = try await FileStorage.scan(livePaths, previous: transaction)
                    let added = FileStorage.additions(indexed: transaction.files, scanned: scanned)
                    if !added.isEmpty {
                        let choice = await additionalFiles(added.map { $0.item.relativePath })
                        guard choice != "cancel" else { throw FileTransferError.cancelled }
                        guard clipboard.current?.id == request.entryID else { throw FileTransferError.changed }
                        if choice == "include" {
                            transaction.roots = roots; transaction.files = scanned
                            transaction.entry.fileCount = scanned.count; transaction.entry.totalBytes = scanned.reduce(0) { $0 + $1.item.size }
                        } else {
                            // Refresh directory timestamps only; declining additions must not
                            // reopen the generic source-version dialog or include them later.
                            let directories = Dictionary(uniqueKeysWithValues: scanned.filter { $0.item.directory }.map { ($0.item.id,$0) })
                            transaction.files = transaction.files.map { old in
                                guard old.item.directory, let actual = directories[old.item.id], actual.identity == old.identity else { return old }; return actual
                            }
                        }
                    }
                }
                if transaction.entry.sourcePeerID == id, transaction.files.filter({ $0.item.available }).contains(where: { !FileStorage.unchanged($0) }) {
                    guard await sourceChanged(transaction.roots.map(\.path)) else { throw FileTransferError.changed }
                    let (roots, files) = try await FileStorage.scan(transaction.roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }, previous: transaction)
                    guard !files.isEmpty else { throw FileTransferError.unavailable }
                    if clipboard.current?.id == transaction.entry.id { transaction.entry = try await clipboard.fileVersion(count: files.count, bytes: files.reduce(0) { $0 + $1.item.size }) }
                    transaction.roots = roots; transaction.files = files
                }
                if peer != id,transaction.files.contains(where:{$0.item.linkTarget != nil}),await manager.currentSessions().first(where:{$0.peerID==peer})?.capabilities.contains("file-symlink-v1") != true {event("FilePeerNeedsLinkSupport");throw FileTransferError.unavailable}
                var prepared: [LocalFile] = []
                for index in transaction.files.indices {
                    let originalLocal = transaction.files[index]; var local = originalLocal
                    if !local.item.available || !FileStorage.unchanged(local), let replica = replicas[request.entryID], replica.entry.fileRevision == transaction.entry.fileRevision,
                       let alternate = replica.files.first(where: { $0.item.id == local.item.id && $0.item.available && replicaUnchanged($0) }) { local = alternate }
                    let valid = local.path == originalLocal.path && transaction.entry.sourcePeerID == id ? FileStorage.unchanged(local) : replicaUnchanged(local)
                    if !local.item.available || !valid { local.item.available = false }
                    else if !local.item.directory, local.item.linkTarget == nil, local.item.hash == nil {
                        do { local.item.hash = try await FileStorage.hash(local.path); guard FileStorage.unchanged(local) else { throw FileTransferError.changed }; if local.path == originalLocal.path { transaction.files[index] = local } }
                        catch { local.item.available = false }
                    }
                    prepared.append(local)
                }
                guard !stopped, group?.id == request.groupID, online.contains(peer) else { throw FileTransferError.unavailable }
                transaction.originalCut = transaction.originalCut && transactions[request.entryID]?.originalCut == true && clipboard.current?.id == request.entryID
                transactions[request.entryID] = transaction
                if let task = tasks[request.taskID], task.direction == "send", ["paused", "cancelled"].contains(task.state) { throw FileTransferError.paused }
                var snapshot = transaction; snapshot.files = prepared
                permits[request.taskID] = FilePermit(taskID: request.taskID, peerID: peer, transaction: snapshot, verified: [], cutSource: transaction.originalCut ? transaction : nil)
                if peer != id {
                    let existing = tasks[request.taskID]; guard existing == nil || existing?.direction == "send" else { throw FileTransferError.invalidPath }
                    let outgoing = existing ?? TransferTask(id: request.taskID, entry: snapshot.entry, groupID: snapshot.groupID, destination: URL(fileURLWithPath: snapshot.roots[0].path).deletingLastPathComponent().path)
                    outgoing.direction = "send"; outgoing.remotePeerID = peer; outgoing.state = "running"; outgoing.error = nil; outgoing.pausedBy = nil; outgoing.entry = snapshot.entry
                    let old = Dictionary(uniqueKeysWithValues: outgoing.files.map { ($0.item.id, $0.received) })
                    outgoing.files = snapshot.files.map { file in let state = TransferFile(item: file.item, provider: id, target: file.path, partial: ""); state.received = old[file.item.id] ?? 0; return state }; tasks[request.taskID] = outgoing
                }; try save()
                let pages = max(1, (snapshot.files.count + 7) / 8)
                for index in 0..<pages {
                    var packet = reply(request, "offer-data"); packet.entry = snapshot.entry; packet.index = index; packet.final = index == pages - 1
                    packet.expandedCatalogue = snapshot.entry.fileCount != clipboard.current?.fileCount
                    packet.items = Array(snapshot.files.dropFirst(index * 8).prefix(8)).map(\.item); try await send(peer, packet)
                }
            } else {
                guard var permit = permits[request.taskID], permit.peerID == peer, permit.transaction.entry.id == request.entryID else { throw FileTransferError.unavailable }
                if request.type == "chunk", let itemID = request.itemID, let offset = request.offset,
                   let local = permit.transaction.files.first(where: { $0.item.id == itemID && !$0.item.directory && $0.item.linkTarget == nil && $0.item.available }) {
                    if let task = tasks[request.taskID], task.direction == "send", task.state != "running" { throw FileTransferError.paused }
                    let window = await manager.fileTransferWindow(peer)
                    if let maximum=request.maximumBytes,!(1...32000).contains(maximum) {throw FileTransferError.invalidDataSize}
                    let data = try await FileStorage.read(local, offset: offset, maximum: min(window.bytes,request.maximumBytes ?? window.bytes))
                    if let task = tasks[request.taskID], task.direction == "send", let progress = task.files.first(where: { $0.item.id == itemID }) { progress.received = max(progress.received, offset + Int64(data.count)); try self.progress(task, bytes: progress.received) }
                    var packet = reply(request, "chunk-data"); packet.itemID = itemID; packet.offset = offset; packet.data = data; packet.checksum = ChunkCheck.adler32(data); try await send(peer, packet)
                } else if request.type == "receipt", let received = request.items {
                    if let task = tasks[request.taskID], task.direction == "send", ["paused", "cancelled"].contains(task.state) { throw FileTransferError.paused }
                    var verified = Set(permit.verified)
                    for item in received {
                        guard let expected = permit.transaction.files.first(where: { $0.item.id == item.id }),
                              expected.item.size == item.size, expected.item.hash == item.hash, expected.item.directory == item.directory, expected.item.linkTarget == item.linkTarget else { throw FileTransferError.corrupt }
                        verified.insert(item.id)
                        if let task = tasks[request.taskID], task.direction == "send" { task.files.first { $0.item.id == item.id }?.completed = true }
                    }
                    permit.verified = Array(verified); permits[request.taskID] = permit
                    if permit.transaction.originalCut { try save() }
                    else if let outgoing=tasks[request.taskID] { try progress(outgoing,bytes:outgoing.received) }
                    let cutSource = permit.cutSource ?? permit.transaction
                    if cutSource.originalCut, clipboard.current?.id == request.entryID, (clipboard.current?.fileRevision ?? 1) == (cutSource.entry.fileRevision ?? 1) {
                        for _ in 0..<30 { if clipboard.current?.providers?.contains(peer) == true { break }; try? await Task.sleep(for: .milliseconds(100)) }
                        guard clipboard.current?.providers?.contains(peer) == true else { throw FileTransferError.unavailable }
                        for root in cutSource.roots {
                            let originals = cutSource.files.filter { $0.item.rootID == root.id }
                            guard !originals.isEmpty, originals.allSatisfy({ original in verified.contains(original.item.id) && permit.transaction.files.contains(where: { provided in provided.item.id == original.item.id && provided.item.hash == original.item.hash && provided.item.size == original.item.size }) && (original.item.available || !FileManager.default.fileExists(atPath: original.path)) }), FileManager.default.fileExists(atPath: root.path) else { continue }
                            guard clipboard.current?.id == request.entryID, permits[request.taskID]?.transaction.originalCut == true, !stopped else { break }
                            let job = Task { try await FileStorage.deleteVerifiedRoot(cutSource, rootID: root.id) }; cutJobs[request.entryID] = job; cutOwners[request.entryID] = request.taskID
                            do { try await job.value }
                            catch {
                                cutJobs.removeValue(forKey: request.entryID)
                                if var remaining = transactions[request.entryID] {
                                    for index in remaining.files.indices {
                                        let local = remaining.files[index]
                                        guard permit.transaction.files.contains(where: { $0.item.id == local.item.id && $0.path == local.path }) else { continue }
                                        if !FileManager.default.fileExists(atPath: local.path) { remaining.files[index].item.available = false }
                                        else if local.item.directory { let actual = try FileStorage.inspect(local.path, template: local.item); if actual.identity == local.identity { remaining.files[index] = actual } }
                                    }
                                    transactions[request.entryID] = remaining; try save()
                                }
                                throw error
                            }
                            cutJobs.removeValue(forKey: request.entryID)
                            if var current = transactions[request.entryID] {
                                for index in current.files.indices where current.files[index].item.rootID == root.id && permit.transaction.files.contains(where: { $0.item.id == current.files[index].item.id && $0.path == current.files[index].path }) { current.files[index].item.available = false }
                                transactions[request.entryID] = current; try save(); event("CutRootDeletedAfterVerification")
                            }
                        }
                        if transactions[request.entryID]?.files.allSatisfy({ !$0.item.available }) == true, replicas[request.entryID]?.files.contains(where: { $0.item.available }) != true { await clipboard.provideFiles(false) }
                    }
                    if let task = tasks[request.taskID], task.direction == "send", task.state == "running", task.files.allSatisfy(\.completed) { task.state = "completed"; try save() }
                    try await send(peer, reply(request, "receipt-ok"))
                } else if request.type == "delete-all", (permit.cutSource ?? permit.transaction).originalCut, clipboard.current?.id == request.entryID, clipboard.current?.cut == true,
                          var transaction = transactions[request.entryID] {
                    guard await deleteAll((permit.cutSource ?? permit.transaction).roots.map(\.path)), clipboard.current?.id == request.entryID else { throw FileTransferError.cancelled }
                    try FileStorage.deleteAll(permit.cutSource ?? permit.transaction)
                    for index in transaction.files.indices where permit.transaction.files.contains(where: { $0.path == transaction.files[index].path }) { transaction.files[index].item.available = false }
                    transactions[request.entryID] = transaction; try save(); if transaction.files.allSatisfy({ !$0.item.available }), replicas[request.entryID]?.files.contains(where: { $0.item.available }) != true { await clipboard.provideFiles(false) }; try await send(peer, reply(request, "delete-ok"))
                } else { throw FileTransferError.unavailable }
            }
        } catch {
            if ["offer", "receipt", "delete-all"].contains(request.type), let task = tasks[request.taskID], task.direction == "send", ["queued", "running", "completed"].contains(task.state) { task.state = (error as? FileTransferError) == .cancelled ? "cancelled" : "failed"; task.error = (error as? FileTransferError) == .cancelled ? nil : request.type == "offer" ? "来源不可用或当前版本未获确认" : "目标已保存；源删除或确认未完成"; try? save() }
            let failure = error as NSError
            event("FileRequestFailed type=\(request.type) domain=\(failure.domain) code=\(failure.code)")
            var packet = reply(request, "error"); packet.error = (error as? FileTransferError) == .cancelled ? "cancelledByUser" : "providerUnavailableOrSourceChanged"; try? await send(peer, packet)
        }
    }
    public func paste(_ destination: String) async throws -> String {
        guard let group, let entry = clipboard.current, entry.kind == "files" else { throw FileTransferError.unavailable }
        let task = TransferTask(id: UUID().uuidString.lowercased(), entry: entry, groupID: group.id, destination: URL(fileURLWithPath: destination).standardizedFileURL.path)
        tasks[task.id] = task; try save(); await run(task); return task.id
    }
    public func beginPaste(_ destination: String) throws -> String {
        guard let group, let entry = clipboard.current, entry.kind == "files" else { throw FileTransferError.unavailable }
        let task = TransferTask(id: UUID().uuidString.lowercased(), entry: entry, groupID: group.id, destination: URL(fileURLWithPath: destination).standardizedFileURL.path)
        tasks[task.id] = task; try save(); Task { await run(task) }; return task.id
    }
    private func stopCut(_ task: TransferTask) { if cutOwners[task.entry.id] == task.id { cutJobs[task.entry.id]?.cancel() } }
    private func control(_ task: TransferTask, _ type: String) async {
        task.controlRevision = (task.controlRevision ?? 0) + 1; let revision = task.controlRevision; try? save()
        let peers = task.direction == "send" ? Set([task.remotePeerID ?? ""]) : Set(task.files.isEmpty ? task.entry.providers ?? [task.entry.sourcePeerID] : task.files.map(\.provider)).subtracting([id])
        for peer in peers where !peer.isEmpty { var packet = FilePacket(type, groupID: task.groupID, entryID: task.entry.id, taskID: task.id); packet.controlRevision = revision; try? await send(peer, packet) }
    }
    public func pause(_ taskID: String) {
        guard let task = tasks[taskID], ["running", "queued"].contains(task.state) else { return }; task.pausedBy = id; task.state = "paused"; stopCut(task)
        for (key, request) in pending where request.request.taskID == taskID { fail(key, FileTransferError.paused) }; Task { await self.control(task, "pause") }; try? save()
    }
    public func cancel(_ taskID: String) {
        guard let task = tasks[taskID] else { return }; task.pausedBy = id; task.state = "cancelled"; stopCut(task)
        for (key, request) in pending where request.request.taskID == taskID { fail(key, FileTransferError.cancelled) }; Task { await self.control(task, "cancel") }; try? save()
    }
    public func resume(_ taskID: String) async { guard let task = tasks[taskID] else { return }; task.pausedBy = nil; if task.direction == "send" { task.state = "running" }; await control(task, "resume"); if task.direction == "send" { try? save() } else { await run(task) } }
    private func unique(_ target: String, directory: Bool, reserved: Set<String>) -> String {
        let url = URL(fileURLWithPath: target); let parent = url.deletingLastPathComponent()
        let stem = directory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let ext = directory || url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        var number = 2
        while true { let candidate = parent.appendingPathComponent("\(stem) (\(number))\(ext)").path
            if !FileManager.default.fileExists(atPath: candidate), !reserved.contains(candidate) { return candidate }; number += 1 }
    }
    private func run(_ task: TransferTask) async {
        guard !stopped, running.insert(task.id).inserted else { return }
        task.state = "running"; task.error = nil; if let current = clipboard.current, current.id == task.entry.id, current.fileRevision == task.entry.fileRevision { task.entry = current }; try? save()
        defer { running.remove(task.id); conflictRules.removeValue(forKey: task.id); try? save(); for peer in Set(task.entry.providers ?? [task.entry.sourcePeerID]).union(task.files.map(\.provider)).subtracting([id]) { var packet = FilePacket("finish", groupID: task.groupID, entryID: task.entry.id, taskID: task.id); packet.state = task.state; packet.error = task.error; packet.controlRevision = task.controlRevision; packet.entry = task.entry; let finished = packet; Task { try? await self.send(peer, finished) } }; if task.state == "queued" { Task { await self.run(task) } } }
        do {
            guard group?.id == task.groupID else { throw FileTransferError.unavailable }
            var catalogue: [String: (item: FileItem, peer: String)] = [:]
            for peer in task.entry.providers ?? [task.entry.sourcePeerID] where online.contains(peer) {
                do {
                    let packets = try await exchange(peer, FilePacket("offer", groupID: task.groupID, entryID: task.entry.id, taskID: task.id))
                    guard let entry = packets.first?.entry, entry.id == task.entry.id, entry.sourcePeerID == task.entry.sourcePeerID, entry.kind == "files",
                          entry.counter == task.entry.counter, entry.timestamp == task.entry.timestamp, let count = entry.fileCount, (1...100000).contains(count) else { throw FileTransferError.corrupt }
                    if (entry.fileRevision ?? 1) > (task.entry.fileRevision ?? 1), peer == task.entry.sourcePeerID { task.entry = entry; catalogue = [:] }
                    guard (entry.fileRevision ?? 1) == (task.entry.fileRevision ?? 1) else { continue }
                    if packets.first?.expandedCatalogue == true { task.entry = entry; catalogue = [:] }
                    for item in packets.flatMap({ $0.items ?? [] }) {
                        guard UUID(uuidString: item.id) != nil, UUID(uuidString: item.rootID) != nil, item.size >= 0, item.relativePath.utf8.count <= 1024,
                              item.directory || item.linkTarget != nil && item.size == 0 && FileStorage.validLink(relative:item.relativePath,target:item.linkTarget!) || !item.available || item.hash?.count == 64 && item.hash?.allSatisfy({ $0.isHexDigit }) == true else { throw FileTransferError.corrupt }
                        if let link=item.linkTarget {guard !item.directory,item.size==0,item.id != item.rootID,FileStorage.validLink(relative:item.relativePath,target:link) else{throw FileTransferError.corrupt}}
                        _ = try FileStorage.target(task.destination, relative: item.relativePath)
                        if catalogue[item.id] == nil || catalogue[item.id]?.item.available == false && item.available { catalogue[item.id] = (item, peer) }
                    }
                    // Check all completed providers for new descendants before choosing a catalogue.
                } catch FileTransferError.cancelled { throw FileTransferError.cancelled }
                catch { event("FileProviderUnavailable") }
            }
            guard !catalogue.isEmpty, catalogue.count == task.entry.fileCount else { throw FileTransferError.unavailable }
            var reserved: Set<String> = []; var roots: [String: String] = [:]; var skipped: Set<String> = []
            for root in catalogue.values.filter({ $0.item.id == $0.item.rootID }).sorted(by: { $0.item.relativePath < $1.item.relativePath }) {
                let previous = task.files.first { $0.item.id == root.item.id }
                var target = try previous?.target ?? FileStorage.target(task.destination, relative: root.item.relativePath)
                var isDirectory: ObjCBool = false; let exists = FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory)
                if previous?.completed != true, exists || reserved.contains(target) {
                    let allow = !reserved.contains(target) && root.item.directory == isDirectory.boolValue
                    let action = await resolveConflict(task, target, root.item.directory, allow)
                    guard action != "overwrite" || allow else { throw FileTransferError.invalidPath }
                    if action == "cancel" { task.state = "cancelled"; return }
                    if action == "skip" { skipped.insert(root.item.rootID) }
                    if action == "keepBoth" { target = unique(target, directory: root.item.directory, reserved: reserved) }
                    guard ["skip", "keepBoth", "overwrite"].contains(action) else { throw FileTransferError.cancelled }
                }
                reserved.insert(target); roots[root.item.rootID] = target
            }
            let previous = Dictionary(uniqueKeysWithValues: task.files.map { ($0.item.id, $0) })
            let ordered = catalogue.values.sorted { a, b in
                if (a.item.linkTarget != nil) != (b.item.linkTarget != nil) {return a.item.linkTarget == nil}
                let left = a.item.relativePath.filter { $0 == "/" }.count, right = b.item.relativePath.filter { $0 == "/" }.count
                if left != right { return left < right }; if a.item.directory != b.item.directory { return a.item.directory }; return a.item.relativePath < b.item.relativePath
            }
            task.files = []
            for pair in ordered {
                let item = pair.item
                guard let root = roots[item.rootID], let rootItem = catalogue[item.rootID]?.item, !rootItem.relativePath.contains("/"),
                      item.id == rootItem.id || rootItem.directory && item.relativePath.hasPrefix(rootItem.relativePath + "/") else { throw FileTransferError.invalidPath }
                let target = root + item.relativePath.dropFirst(rootItem.relativePath.count)
                let partial = try FileStorage.partial(task.destination, taskID: task.id, itemID: item.id)
                let old = previous[item.id]
                let state = old?.item.hash == item.hash && old?.item.linkTarget == item.linkTarget && old?.item.size == item.size && old?.target == target ? old! : TransferFile(item: item, provider: pair.peer, target: target, partial: partial)
                state.item = item; state.provider = pair.peer; state.partial = partial; state.skipped = skipped.contains(item.rootID); state.error = nil
                if state.completed, !FileStorage.completedUnchanged(state) { state.completed = false; state.received = 0 }
                if !state.completed {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: partial)
                    let length = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                    state.received = min(state.received, length)
                }
                task.files.append(state)
            }
            try save()
            for transfer in task.files {
                guard task.state == "running" else { return }
                if transfer.completed || transfer.skipped { continue }
                do { try await download(task, transfer) } catch { transfer.error = "文件不可达、源变化或校验失败；已保留进度"; try save() }
            }
            guard task.state == "running" else { return }
            for transfer in task.files where transfer.completed && !FileStorage.completedUnchanged(transfer) { transfer.completed = false; transfer.received = 0; transfer.error = "已校验的目标文件发生变化，请重试" }
            let completed = task.files.filter(\.completed)
            if !completed.isEmpty, clipboard.current?.id == task.entry.id, (clipboard.current?.fileRevision ?? 1) == (task.entry.fileRevision ?? 1) {
                let existing = transactions[task.entry.id]; var locals: [LocalFile] = []
                for transfer in task.files {
                    if transfer.completed { var item = transfer.item; item.available = true; locals.append(try FileStorage.inspect(transfer.target, template: item)) }
                    else if let old = existing?.files.first(where: { $0.item.id == transfer.item.id && $0.item.available }), FileStorage.unchanged(old) { locals.append(old) }
                    else { var item = transfer.item; item.available = false; locals.append(LocalFile(item: item, path: transfer.target, identity: "")) }
                }
                let localProvider = FileTransaction(entry: task.entry, groupID: task.groupID, roots: roots.map { LocalRoot(id: $0.key, path: $0.value) }, files: locals, originalCut: false)
                if task.entry.sourcePeerID == id, transactions[task.entry.id] != nil { replicas[task.entry.id] = localProvider } else { transactions[task.entry.id] = localProvider }
                try save(); await clipboard.provideFiles(true)
            }
            for provider in Set(completed.map(\.provider)) {
                do {
                    let items = completed.filter { $0.provider == provider }.map(\.item)
                    for offset in stride(from: 0, to: items.count, by: 8) {
                        var request = FilePacket("receipt", groupID: task.groupID, entryID: task.entry.id, taskID: task.id); request.items = Array(items.dropFirst(offset).prefix(8)); _ = try await exchange(provider, request)
                    }
                } catch { task.error = "文件已保存，但源删除或完成确认尚未完成" }
            }
            if task.files.contains(where: { $0.error != nil || task.entry.cut == true && $0.skipped }) {
                task.state = "failed"; task.error = task.error ?? "部分所选文件未完成传输"; try save()
                if task.entry.cut == true {
                    let decision = await partialFailure(task)
                    if decision == "deleteAll" { _ = try await exchange(task.entry.sourcePeerID, FilePacket("delete-all", groupID: task.groupID, entryID: task.entry.id, taskID: task.id)) }
                    if decision == "retry" { task.state = "queued" } else if decision == "abort" { task.state = "cancelled" }
                }
            } else { task.state = task.error == nil ? "completed" : "failed" }
        } catch FileTransferError.cancelled { task.state = "cancelled"; task.error = nil }
        catch {
            if task.state == "running" { task.state = "failed" }; task.error = "提供者不可达、当前文件版本变化或磁盘操作未完成"; event("TransferFailed taskId=\(task.id)")
        }
    }
    private func resolveConflict(_ task: TransferTask, _ path: String, _ directory: Bool, _ allow: Bool) async -> String {
        if let rule = conflictRules[task.id], rule != "overwrite" || allow { return rule }
        let decision = await conflict(path, directory, allow)
        let action = decision.hasSuffix(":all") ? String(decision.dropLast(4)) : decision
        guard ["overwrite", "keepBoth", "skip", "cancel"].contains(action), action != "overwrite" || allow else { return "cancel" }
        if decision.hasSuffix(":all"), action != "cancel" { conflictRules[task.id] = action }
        return action
    }
    private func download(_ task: TransferTask, _ transfer: TransferFile) async throws {
        let item = transfer.item
        guard item.available else { throw FileTransferError.unavailable }
        try FileStorage.ensureParent(task.destination, target: transfer.target)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: transfer.target, isDirectory: &directory), !transfer.completed, transfer.received == 0, item.id != item.rootID {
            let allow = item.directory == directory.boolValue; let action = await resolveConflict(task, transfer.target, item.directory, allow)
            if action == "cancel" { task.state = "cancelled"; return }
            guard action != "overwrite" || allow else { throw FileTransferError.invalidPath }
            if action == "skip" { for child in task.files where child.target == transfer.target || item.directory && child.target.hasPrefix(transfer.target + "/") { child.skipped = true }; try save(); return }
            if action == "keepBoth" { let old = transfer.target; let target = unique(old, directory: item.directory, reserved: [])
                for child in task.files where child.target == old || item.directory && child.target.hasPrefix(old + "/") { child.target = target + child.target.dropFirst(old.count) }
            }
            guard ["overwrite", "keepBoth"].contains(action) else { throw FileTransferError.cancelled }
        }
        if item.linkTarget != nil {
            guard let root=task.files.first(where:{$0.item.id==item.rootID})?.target else{throw FileTransferError.invalidPath}
            try FileStorage.finishLink(transfer,destination:task.destination,root:root);transfer.completed=true;try progress(task,bytes:task.received);return
        }
        if item.directory {
            if !FileManager.default.fileExists(atPath: transfer.target) { try FileManager.default.createDirectory(atPath: transfer.target, withIntermediateDirectories: false) }
            transfer.completedIdentity = try FileStorage.inspect(transfer.target, template: item).identity; transfer.completed = true; try progress(task,bytes:task.received); return
        }
        // A previous file may have removed the now-empty staging directory.
        transfer.partial = try FileStorage.partial(task.destination, taskID: task.id, itemID: item.id)
        if item.size == 0 { try await FileStorage.append(transfer, data: Data()) }
        while transfer.received < item.size {
            guard task.state == "running" else { return }
            let window=await manager.fileTransferWindow(transfer.provider)
            let start=transfer.received, remaining=item.size-start
            let offsets=(0..<window.count).map{start+Int64($0*window.bytes)}.filter{$0<item.size}
            let groupID=task.groupID,entryID=task.entry.id,taskID=task.id,provider=transfer.provider,itemID=item.id,total=item.size
            let parts=await withTaskGroup(of:(Int64,Data?).self) { group in
                for offset in offsets {group.addTask {let value=try? await self.readChunk(provider,groupID:groupID,entryID:entryID,taskID:taskID,itemID:itemID,offset:offset,maximum:Int(min(Int64(window.bytes),total-offset)));return (offset,value)}}
                var result:[(Int64,Data?)]=[];for await part in group{result.append(part)};return result.sorted{$0.0<$1.0}
            }
            guard task.state == "running" else { return }
            var batch=Data()
            for (offset,data) in parts {guard offset==start+Int64(batch.count),let data else{break};batch.append(data)}
            guard !batch.isEmpty,Int64(batch.count)<=remaining else {throw FileTransferError.corrupt}
            // A bounded ordered batch is flushed durably before progress is recorded.
            try await FileStorage.append(transfer,data:batch);transfer.received+=Int64(batch.count);try progress(task,bytes:transfer.received)
        }
        guard try await FileStorage.hash(transfer.partial) == item.hash else { transfer.received = 0; throw FileTransferError.corrupt }
        guard task.state == "running" else { return }
        try FileStorage.finish(transfer, destination: task.destination); transfer.completed = true; try progress(task,bytes:task.received)
    }
    private func readChunk(_ provider:String,groupID:String,entryID:String,taskID:String,itemID:String,offset:Int64,maximum:Int) async throws -> Data {
        // Concurrent tasks share one peer budget; slow ACKs cannot multiply windows.
        while true {
            guard !stopped,tasks[taskID]?.state == "running" else {throw FileTransferError.paused}
            let window=await manager.fileTransferWindow(provider)
            guard !stopped,tasks[taskID]?.state == "running" else {throw FileTransferError.paused}
            if chunkRequests[provider,default:0] < window.count {chunkRequests[provider,default:0] += 1;break}
            try await Task.sleep(for:.milliseconds(5))
        }
        defer {chunkRequests[provider,default:1] -= 1}
        for _ in 0..<3 {
            do {
                var request=FilePacket("chunk",groupID:groupID,entryID:entryID,taskID:taskID);request.itemID=itemID;request.offset=offset
                if await manager.hasCapability(provider,"adaptive-file-window-v1") {request.maximumBytes=maximum}
                let packets=try await exchange(provider,request)
                if packets.count==1,let response=packets.first,response.itemID==itemID,response.offset==offset,let data=response.data,!data.isEmpty,data.count<=maximum,response.checksum==ChunkCheck.adler32(data){return data}
            } catch {if tasks[taskID]?.state != "running" {throw FileTransferError.paused}}
        }
        throw FileTransferError.corrupt
    }
    public func stop() {
        stopped = true; for scan in pendingCopies.values { scan.cancel() }; for job in cutJobs.values { job.cancel() }; for task in tasks.values where task.state == "running" { task.state = "paused"; task.pausedBy = task.direction == "send" ? task.remotePeerID : id }
        for key in Array(pending.keys) { fail(key, FileTransferError.unavailable) }; try? save()
    }
}
