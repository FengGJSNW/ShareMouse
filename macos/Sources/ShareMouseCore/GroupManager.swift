import Foundation

public actor GroupManager {
    private let localID: String
    private let name: String
    private let publicKey: String
    private let manager: SessionManager
    private let registry: PeerRegistry
    private let file: URL
    private let confirm: @Sendable (GroupMember) async -> Bool
    private let changed: @Sendable (SharedGroup?, [GroupEditLock], [String], [SharedGroup]) -> Void
    private let event: @Sendable (String) -> Void
    private let connectMember: (@Sendable (GroupMember, String) async throws -> Void)?
    private let automaticSharing: Bool
    private var reconcilingSharing = false
    private var desktopStates: [String: SharedGroup] = [:]
    private var seenPresence: Set<String> = []
    private var ownConfigs: [KeyboardConfig]
    private let configFile: URL
    private var librarySelected = ""
    private var offeredConfigs: Set<String> = []
    private var connectionConfigs: [String: KeyboardConfig] = [:]
    private var connectionLibraries: [String: [KeyboardConfig]] = [:]
    public var confirmConfig: (@Sendable (String, KeyboardConfig, KeyboardConfig?) async -> String)?
    public func setConfigConfirmation(
        _ callback: @escaping @Sendable (String, KeyboardConfig, KeyboardConfig?) async -> String
    ) { confirmConfig = callback }
    public var keyboardLibrary: [KeyboardConfig] { ownConfigs }
    public var selectedKeyboardConfig: String { librarySelected }
    private var store: GroupStore
    private var screens: [ScreenGeometry]
    private var sessions: [String: SessionInfo] = [:]
    private var presence: [String: String] = [:]
    private var admitted: Set<String> = []  // Runtime admission never changes Trusted/AutoConnect.
    private var locks: [GroupEditLock] = []
    private var joining: String?
    private var invitationID: String?
    private var invitationLeader: String?
    private var invited: Set<String> = []
    private var proposing = false
    private var votes: [String: (peer: String, value: CheckedContinuation<Bool, Never>)] = [:]
    private var lockRequests: [String: CheckedContinuation<GroupEditLock?, Never>] = [:]
    private var commitRequests: [String: CheckedContinuation<Bool, Never>] = [:]
    private var recovering = false
    private var recoveryReplies: Set<String> = []
    private var recovered: SharedGroup?
    private var recoveryGeneration = 0
    public var active: SharedGroup? { store.groups.first { $0.id == store.activeGroupID } }

    public init(
        localID: String, name: String, publicKey: String, screens: [ScreenGeometry], directory: URL,
        manager: SessionManager, registry: PeerRegistry, confirm: @escaping @Sendable (GroupMember) async -> Bool,
        changed: @escaping @Sendable (SharedGroup?, [GroupEditLock], [String], [SharedGroup]) -> Void,
        event: @escaping @Sendable (String) -> Void,
        connectMember: (@Sendable (GroupMember, String) async throws -> Void)? = nil, automaticSharing: Bool = false
    ) throws {
        self.localID = localID;
        self.name = name;
        self.publicKey = publicKey;
        self.screens = screens
        self.manager = manager;
        self.registry = registry;
        self.confirm = confirm;
        self.changed = changed;
        self.event = event
        self.connectMember = connectMember;
        self.automaticSharing = automaticSharing
        file = directory.appendingPathComponent("groups.json")
        let loaded =
            FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(GroupStore.self, from: Data(contentsOf: file))
            : GroupStore(groups: [], activeGroupID: nil)
        configFile = directory.appendingPathComponent("keyboard-configs.json")
        let cached =
            FileManager.default.fileExists(atPath: configFile.path)
            ? try JSONDecoder().decode([KeyboardConfig].self, from: Data(contentsOf: configFile)) : []
        ownConfigs = cached
        if ownConfigs.isEmpty {
            ownConfigs = [
                KeyboardConfig(
                    id: UUID().uuidString.lowercased(), ownerPeerID: localID, name: "默认配置", windowsToMac: [:],
                    macToWindows: [:], revision: 1)
            ]
        }
        let initialConfigs = ownConfigs
        let initialSelected =
            (try? JSONDecoder().decode(
                String.self, from: Data(contentsOf: directory.appendingPathComponent("keyboard-selection.json")))) ?? ""
        librarySelected =
            initialConfigs.contains(where: { $0.id == initialSelected }) ? initialSelected : initialConfigs[0].id
        try JSONEncoder().encode(ownConfigs).write(to: configFile, options: .atomic)
        store = loaded;
        admitted = [localID];
        recovering = loaded.activeGroupID != nil
        if let current = loaded.groups.first(where: { $0.id == loaded.activeGroupID }),
            !current.members.contains(where: { $0.peerID == localID && $0.publicKey == publicKey })
        {
            throw GroupError.invalidState
        }
    }
    public func start() async {
        await manager.setApplicationCapabilities(["group"])
        await manager.receive(channel: "group") { [weak self] peer, bytes in await self?.receive(peer, bytes) }
        await manager.receive(channel: "keyboard-config") { [weak self] peer, bytes in
            Task { await self?.receiveConfig(peer, bytes) };
            return
        }
        await authorize();
        notify()
    }
    private func notify() {
        changed(active, locks, online(), store.groups);
        Task { await self.offerConfigs() }
    }
    private func online(_ group: SharedGroup? = nil) -> [String] {
        guard let current = group ?? active else { return [] }
        return current.members.filter {
            $0.peerID == localID || sessions[$0.peerID] != nil && presence[$0.peerID] == current.id
        }.sorted { $0.joinOrder < $1.joinOrder }.map(\.peerID)
    }
    private func authorize() async {
        let allowed =
            active.map { admitted.intersection(Set($0.members.map(\.peerID))).union(invited) }
            ?? Set([localID, invitationLeader].compactMap { $0 })
        await manager.authorizeGroup(active?.id ?? invitationID, members: allowed)
    }
    private func save(_ group: SharedGroup? = nil) throws {
        var next = store
        if let group {
            if let index = next.groups.firstIndex(where: { $0.id == group.id }) {
                next.groups[index] = group
            } else {
                next.groups.append(group)
            }
        }
        try JSONEncoder().encode(next).write(to: file, options: .atomic);
        store = next
        if let group {
            if online().count > 1 {
                librarySelected = group.currentConfigID;
                try? JSONEncoder().encode(librarySelected).write(
                    to: configFile.deletingLastPathComponent().appendingPathComponent("keyboard-selection.json"),
                    options: .atomic)
            }
            for config in group.configs {
                ownConfigs.removeAll { $0.id == config.id };
                ownConfigs.append(config)
            }
            do { try JSONEncoder().encode(ownConfigs).write(to: configFile, options: .atomic) } catch {
                event("KeyboardConfigSaveFailed")
            }
        }
    }
    private func send(_ peer: String, _ packet: GroupPacket) async throws {
        try await manager.send(peerID: peer, channel: "group", payload: JSONEncoder().encode(packet))
    }
    private func announce() async {
        var packet = GroupPacket("presence");
        packet.groupID = active?.id;
        packet.requestID = UUID().uuidString;
        if automaticSharing { packet.state = active }
        for peer in sessions.keys { try? await send(peer, packet) }
    }
    private func broadcast() async {
        guard let current = active else { return }
        var packet = GroupPacket("state");
        packet.groupID = current.id;
        packet.state = current;
        packet.locks = locks
        for peer in online() where peer != localID { try? await send(peer, packet) }
        notify()
    }
    public func create(name: String = "我的桌面") async throws {
        guard active == nil else { throw GroupError.alreadyActive }
        let config = ownConfigs.first(where: { $0.id == librarySelected }) ?? ownConfigs[0]
        let member = GroupMember(
            peerID: localID, name: self.name, publicKey: publicKey, joinOrder: 0,
            host: sessions.values.first?.localHost, port: await manager.listenPort)
        let group = SharedGroup(
            id: UUID().uuidString.lowercased(), name: String(name.prefix(128)), leaderID: localID, revision: 1,
            members: [member], layout: screens, configs: ownConfigs, currentConfigID: config.id)
        store.activeGroupID = group.id;
        recovering = false;
        try save(group)
        await authorize();
        await announce();
        notify();
        event("GroupCreated groupId=\(group.id)")
    }
    public func activate(_ id: String) async throws {
        guard active == nil, store.groups.contains(where: { $0.id == id }) else { throw GroupError.alreadyActive }
        store.activeGroupID = id;
        admitted = [localID];
        recovering = true;
        try save()
        await authorize();
        await announce();
        await updateLeader();
        notify()
    }
    public func leave() async throws {
        store.activeGroupID = nil;
        locks = [];
        admitted = [localID];
        joining = nil;
        invited = []
        invitationID = nil;
        invitationLeader = nil;
        recovering = false;
        try save()
        await authorize();
        await announce();
        notify();
        event("GroupLeft")
    }
    public func join(_ peer: String) async throws {
        guard active == nil, joining == nil else { throw GroupError.alreadyActive }
        guard sessions[peer]?.capabilities.contains("group") == true else { throw GroupError.offline }
        joining = peer
        var packet = GroupPacket("join");
        packet.screens = screens;
        packet.configs = []
        do { try await send(peer, packet) } catch {
            joining = nil;
            throw error
        }
        Task {
            try? await Task.sleep(for: .seconds(65));
            await self.expireJoin(peer)
        }
    }
    public func updateScreens(_ values: [ScreenGeometry]) async {
        screens = values
        guard let current = active else { return }
        var packet = GroupPacket("screensChanged");
        packet.groupID = current.id;
        packet.screens = values
        if current.leaderID == localID {
            await applyScreens(localID, packet)
        } else {
            try? await send(current.leaderID, packet)
        }
    }
    private func applyScreens(_ peer: String, _ packet: GroupPacket) async {
        guard var current = active, current.leaderID == localID, current.id == packet.groupID, online().contains(peer),
            let values = packet.screens, values.count <= 16, Set(values.map(\.id)).count == values.count,
            values.allSatisfy({ $0.peerID == peer && $0.pixelWidth > 0 && $0.pixelHeight > 0 })
        else { return }
        var layout = current.layout.filter { $0.peerID != peer };
        var offset = layout.map { $0.x + $0.width }.max() ?? 0
        for var value in values {
            if let previous = current.layout.first(where: { $0.id == value.id }) {
                value.x = previous.x;
                value.y = previous.y;
                value.scale = previous.scale;
                value.scaleX = previous.scaleX;
                value.scaleY = previous.scaleY;
                value.rotation = previous.rotation
            } else {
                value.x = offset;
                value.y = 0
            }
            layout.append(value);
            offset = max(offset, value.x + value.width)
        }
        if !ScreenGeometry.validLayout(layout) {
            offset = 0;
            layout = layout.map { screen in
                var next = screen;
                next.x = offset;
                next.y = 0;
                offset += next.width;
                return next
            }
        }
        guard !layout.isEmpty,
            layout.count != current.layout.count
                || layout.contains(where: { screen in current.layout.first(where: { $0.id == screen.id }) != screen })
        else { return }
        current.layout = layout;
        current.revision += 1
        do {
            try validate(current);
            try save(current);
            locks = [];
            await broadcast()
        } catch { event("ScreenUpdateRejected") }
    }
    private func expireJoin(_ peer: String) async {
        if joining == peer {
            joining = nil;
            invitationID = nil;
            invitationLeader = nil;
            event("GroupJoinTimedOut")
        }
        await authorize()
    }
    public func recommend(_ peer: String) async throws {
        guard let current = active, let known = registry.find(peer), known.trust == .trusted,
            let session = sessions[peer], !current.members.contains(where: { $0.peerID == peer })
        else { throw GroupError.denied }
        var packet = GroupPacket("recommend");
        packet.groupID = current.id
        packet.member = GroupMember(
            peerID: peer, name: session.name, publicKey: known.publicKey, joinOrder: 0, host: session.lanHost,
            port: session.listenPort)
        if current.leaderID == localID {
            await processRecommendation(localID, packet)
        } else {
            try await send(current.leaderID, packet)
        }
    }
    private func processRecommendation(_ peer: String, _ packet: GroupPacket) async {
        guard let current = active, current.id == packet.groupID, current.leaderID == localID, online().contains(peer),
            let member = packet.member, await admit(member, explicitConfirmation: true), active?.id == current.id,
            active?.leaderID == localID
        else { return }
        invited.insert(member.peerID);
        await authorize()
        var leader = current.members.first { $0.peerID == localID }!
        leader.host = sessions[peer]?.localHost ?? leader.host
        var invite = GroupPacket("invite");
        invite.groupID = current.id;
        invite.member = leader;
        invite.targetPeerID = member.peerID
        try? await send(peer == localID ? member.peerID : peer, invite)
        Task {
            try? await Task.sleep(for: .seconds(65));
            await self.expireInvitation(member.peerID)
        }
    }
    private func expireInvitation(_ peer: String) async {
        invited.remove(peer);
        await authorize()
    }
    private func receiveInvite(_ peer: String, _ packet: GroupPacket) async {
        if let current = active {
            guard current.leaderID == peer, current.id == packet.groupID, let target = packet.targetPeerID,
                registry.find(target)?.trust == .trusted, sessions[target] != nil
            else { return }
            try? await send(target, packet);
            return
        }
        guard joining == nil, let id = packet.groupID, let leader = packet.member, packet.targetPeerID == localID,
            registry.find(peer)?.trust == .trusted, await admit(leader, explicitConfirmation: true), active == nil,
            joining == nil
        else { return }
        invitationID = id;
        invitationLeader = leader.peerID;
        await authorize()
        do {
            try await connect(leader, id);
            try await join(leader.peerID)
        } catch {
            invitationID = nil;
            invitationLeader = nil;
            await authorize();
            event("GroupRecommendationUnavailable")
        }
    }
    public func connectionsChanged(_ values: [SessionInfo]) async {
        let old = Set(sessions.keys)
        for item in values where !old.contains(item.peerID) {
            connectionConfigs[item.peerID] = ownConfigs.first { $0.id == librarySelected } ?? ownConfigs.first;
            connectionLibraries[item.peerID] = ownConfigs
        }
        sessions = Dictionary(uniqueKeysWithValues: values.map { ($0.peerID, $0) })
        for id in old.subtracting(sessions.keys) {
            connectionConfigs.removeValue(forKey: id);
            connectionLibraries.removeValue(forKey: id);
            offeredConfigs.remove(id);
            presence.removeValue(forKey: id);
            seenPresence.remove(id);
            desktopStates.removeValue(forKey: id)
        }
        if let current = active {
            admitted.formUnion(current.members.filter { sessions[$0.peerID] != nil }.map(\.peerID))
            locks.removeAll { $0.ownerPeerID != localID && sessions[$0.ownerPeerID] == nil }
        }
        await authorize()
        if old != Set(sessions.keys) {
            await announce();
            await updateLeader()
        }
        await reconcileSharing();
        notify()
    }
    private func reconcileSharing() async {
        guard automaticSharing, !reconcilingSharing, joining == nil else { return }
        guard
            let session = sessions.values.sorted(by: { $0.peerID < $1.peerID }).first(where: {
                $0.capabilities.contains("group") && seenPresence.contains($0.peerID)
                    && (active == nil || presence[$0.peerID] != active?.id)
            })
        else { return }
        let peer = session.peerID
        // Never abandon a desktop that still has other online participants.
        if online().count > 1 { return }
        reconcilingSharing = true;
        defer { reconcilingSharing = false }
        let remote = desktopStates[peer]
        let localContainsPeer = active?.members.contains(where: { $0.peerID == peer }) == true
        let remoteContainsLocal = remote?.members.contains(where: { $0.peerID == localID }) == true
        let hosts: Bool
        if localContainsPeer != remoteContainsLocal {
            hosts = localContainsPeer
        } else if localContainsPeer, let current = active, let remote {
            hosts = current.id < remote.id
        } else {
            hosts = session.initiatorPeerID == localID
        }
        do {
            if hosts {
                let saved = store.groups.filter { $0.members.contains(where: { $0.peerID == peer }) }.max(by: {
                    $0.revision < $1.revision
                })
                if active?.members.contains(where: { $0.peerID == peer }) != true, let saved {
                    if active != nil { try await leave() }
                    try await activate(saved.id)
                } else if active == nil {
                    try await create(name: name + "的连续桌面")
                }
                await announce()
            } else if let remote, remote.leaderID == peer {
                if active != nil { try await leave() }
                try await join(peer)
            }
        } catch { event("AutomaticDesktopPending peerId=\(peer)") }
    }
    private func updateLeader() async {
        guard var current = active, let next = online().first else { return }
        let changedLeader = current.leaderID != next
        if changedLeader {
            current.leaderID = next;
            locks = [];
            try? save(current);
            event("GroupLeaderChanged peerId=\(next)")
        }
        if next == localID {
            if recovering && !recoveryReplies.isEmpty { return }
            if recovering && online().count > 1 {
                recoveryReplies = Set(online().filter { $0 != localID });
                recovered = current
                recoveryGeneration += 1;
                let generation = recoveryGeneration
                var query = GroupPacket("replicaRequest");
                query.groupID = current.id
                for peer in recoveryReplies { try? await send(peer, query) }
                Task {
                    try? await Task.sleep(for: .seconds(10));
                    await self.finishRecovery(generation)
                }
            } else if !recovering || online().count == 1 {
                if changedLeader { await broadcast() }
            }
        } else {
            recovering = false
            var query = GroupPacket("stateRequest");
            query.groupID = current.id;
            try? await send(next, query)
        }
    }
    private func finishRecovery(_ generation: Int) async {
        guard recovering, generation == recoveryGeneration, var current = recovered ?? active else { return }
        for member in current.members {
            guard await admit(member) else {
                try? await leave();
                event("GroupAdmissionDeclined");
                return
            }
        }
        guard active?.id == current.id else { return }
        current.leaderID = online(current).first ?? localID;
        current.revision += 1
        recovering = false;
        recoveryReplies = [];
        recovered = nil;
        locks = [];
        try? save(current)
        await authorize();
        await broadcast()
    }
    private func reconcileReplica(_ peer: String, _ state: SharedGroup?) async {
        guard let state, let current = active, state.id == current.id, current.leaderID == localID,
            online().contains(peer), !recovering
        else { return }
        do { try validate(state) } catch { return }
        if state.revision > current.revision {
            // A returning member may hold the newest committed layout. Reconcile
            // through the existing replica recovery before granting more edits.
            recovering = true;
            await updateLeader()
        } else if state != current {
            await broadcast()
        }
    }
    private func validate(_ group: SharedGroup) throws {
        guard UUID(uuidString: group.id) != nil, !group.members.isEmpty,
            Set(group.members.map(\.peerID)).count == group.members.count,
            Set(group.members.map(\.joinOrder)).count == group.members.count,
            group.members.contains(where: { $0.peerID == localID && $0.publicKey == publicKey }),
            group.members.allSatisfy({
                UUID(uuidString: $0.peerID) != nil && $0.port > 0 && $0.publicKey.utf8.count <= 1024
            }), group.members.contains(where: { $0.peerID == group.leaderID }),
            ScreenGeometry.validLayout(group.layout),
            group.layout.allSatisfy({ screen in group.members.contains { $0.peerID == screen.peerID } }),
            KeyboardMapping.valid(
                group.configs, members: Set(group.members.map(\.peerID)), selected: group.currentConfigID)
        else { throw GroupError.invalidState }
        for member in group.members {
            if let stored = registry.find(member.peerID), stored.publicKey != member.publicKey {
                throw PairingError.identityChanged
            }
        }
    }
    private func admit(_ member: GroupMember, explicitConfirmation: Bool = false) async -> Bool {
        guard UUID(uuidString: member.peerID) != nil, member.publicKey.utf8.count <= 1024, member.port > 0 else {
            return false
        }
        if member.peerID == localID { return member.publicKey == publicKey }
        if let known = registry.find(member.peerID), known.publicKey != member.publicKey { return false }
        if (explicitConfirmation || !admitted.contains(member.peerID) && !sessions.keys.contains(member.peerID)),
            !(await confirm(member))
        {
            return false
        }
        do {
            try registry.remember(
                CertificatePeer(peerID: member.peerID, publicKey: member.publicKey), name: member.name);
            admitted.insert(member.peerID);
            return true
        } catch { return false }
    }
    private func acceptState(_ peer: String, _ packet: GroupPacket) async {
        guard var state = packet.state,
            (packet.type == "joined" && joining == peer && active == nil)
                || (active?.id == state.id && state.members.contains(where: { $0.peerID == peer }))
        else { return }
        do {
            try validate(state)
            if packet.type == "replica" {
                guard recovering, recoveryReplies.contains(peer) else { return }
                if state.revision > (recovered?.revision ?? 0) { recovered = state }
                recoveryReplies.remove(peer)
                if recoveryReplies.isEmpty { await finishRecovery(recoveryGeneration) };
                return
            }
            guard state.leaderID == peer, packet.type == "joined" || online(state).first == peer else { return }
            if let current = active, state.revision < current.revision { return }
            for member in state.members { guard await admit(member) else { throw GroupError.denied } }
            guard packet.type == "joined" ? joining == peer && active == nil : active?.id == state.id else { return }
            let activated = store.activeGroupID != state.id
            store.activeGroupID = state.id;
            joining = nil;
            invitationID = nil;
            invitationLeader = nil;
            recovering = false;
            presence[peer] = state.id
            state.leaderID = online(state).first ?? state.leaderID
            try save(state);
            locks = packet.locks ?? [];
            await authorize();
            if activated { await announce() };
            notify()
            await connectMesh();
            event("GroupStateApplied groupId=\(state.id) revision=\(state.revision)")
        } catch {
            joining = nil;
            event("GroupStateRejected")
        }
    }
    private func connectMesh() async {
        guard let current = active else { return }
        for member in current.members
        where member.peerID != localID && sessions[member.peerID] == nil && admitted.contains(member.peerID) {
            try? await connect(member, current.id)
        }
    }
    private func connect(_ member: GroupMember, _ id: String) async throws {
        if sessions[member.peerID] != nil { return }
        if let connectMember {
            try await connectMember(member, id)
        } else if let host = member.host {
            _ = try await manager.connect(
                endpoint: .hostPort(host: .init(host), port: .init(rawValue: member.port)!), pairCode: nil,
                password: nil, autoOnly: true, groupID: id, expectedPeerID: member.peerID)
        } else {
            throw GroupError.offline
        }
    }
    private func receive(_ peer: String, _ bytes: Data) async {
        guard let packet = try? JSONDecoder().decode(GroupPacket.self, from: bytes) else { return }
        switch packet.type {
        case "presence":
            seenPresence.insert(peer)
            if let state = packet.state, state.id == packet.groupID,
                state.members.contains(where: { $0.peerID == peer && $0.publicKey == registry.find(peer)?.publicKey })
            {
                desktopStates[peer] = state
            } else {
                desktopStates.removeValue(forKey: peer)
            }
            let previous = presence[peer]
            if let id = packet.groupID { presence[peer] = id } else { presence.removeValue(forKey: peer) }
            let oldLocks = locks.count
            if packet.groupID != active?.id { locks.removeAll { $0.ownerPeerID == peer } }
            if previous != packet.groupID { await updateLeader() }
            await reconcileReplica(peer, packet.state)
            if oldLocks != locks.count, active?.leaderID == localID { await broadcast() };
            await reconcileSharing();
            notify()
            // A restarted peer has forgotten our presence even when its PeerId,
            // desktop and merged SessionId are unchanged on this side.
            if packet.requestID != nil {
                var reply = GroupPacket("presence");
                reply.groupID = active?.id;
                if automaticSharing { reply.state = active }
                try? await send(peer, reply)
            }
        case "join": Task { await self.processJoin(peer, packet) }
        case "recommend": Task { await self.processRecommendation(peer, packet) }
        case "invite": Task { await self.receiveInvite(peer, packet) }
        case "screensChanged": await applyScreens(peer, packet)
        case "proposal":
            Task {
                var result = GroupPacket("vote");
                result.groupID = packet.groupID;
                result.requestID = packet.requestID
                result.approved =
                    active?.id == packet.groupID && active?.leaderID == peer && packet.member != nil
                    ? await admit(packet.member!) : false
                try? await send(peer, result)
            }
        case "vote":
            if let id = packet.requestID, let pending = votes[id], pending.peer == peer {
                votes.removeValue(forKey: id);
                pending.value.resume(returning: packet.approved == true)
            }
        case "joined", "state", "replica": Task { await self.acceptState(peer, packet) }
        case "stateRequest", "replicaRequest":
            guard let current = active, current.id == packet.groupID,
                current.members.contains(where: { $0.peerID == peer })
            else { return }
            var reply = GroupPacket(
                packet.type != "replicaRequest" && current.leaderID == localID ? "state" : "replica")
            reply.groupID = current.id;
            reply.state = current;
            reply.locks = locks;
            try? await send(peer, reply)
        case "lockRequest", "release", "commit": await edit(peer, packet)
        case "lockResult":
            if peer == active?.leaderID, let id = packet.requestID, let pending = lockRequests.removeValue(forKey: id) {
                pending.resume(returning: packet.editLock)
            }
        case "commitResult":
            if peer == active?.leaderID, let id = packet.requestID, let pending = commitRequests.removeValue(forKey: id)
            {
                var applied = false
                if packet.approved == true, let state = packet.state, let current = active, state.id == current.id,
                    state.revision >= current.revision,
                    Set(state.members.map(\.peerID)) == Set(current.members.map(\.peerID))
                {
                    do {
                        try validate(state);
                        try save(state);
                        locks = [];
                        applied = true;
                        notify()
                    } catch { event("GroupCommitStateRejected") }
                }
                pending.resume(returning: applied)
            }
        case "error", "redirect":
            joining = nil;
            event(packet.type == "redirect" ? "GroupJoinRequiresLeader" : "GroupOperationRejected")
        default: break
        }
    }
    private func processJoin(_ peer: String, _ request: GroupPacket) async {
        guard !proposing, let session = sessions[peer], let certificate = registry.find(peer) else { return }
        proposing = true;
        defer { proposing = false }
        do {
            if let current = active, current.leaderID != localID {
                var redirect = GroupPacket("redirect");
                redirect.leaderID = current.leaderID;
                try await send(peer, redirect);
                return
            }
            var member = GroupMember(
                peerID: peer, name: session.name, publicKey: certificate.publicKey,
                joinOrder: (active?.members.map(\.joinOrder).max() ?? 0) + 1, host: session.lanHost,
                port: session.listenPort)
            if !automaticSharing, !(await confirm(member)) { throw GroupError.denied }
            if active == nil { try await create() }
            guard var current = active else { throw GroupError.noActiveGroup }
            if current.members.contains(where: { $0.peerID == peer }) {
                var reply = GroupPacket("joined");
                reply.state = current;
                reply.locks = locks;
                try await send(peer, reply);
                return
            }
            for voter in online() where voter != localID && voter != peer {
                let id = UUID().uuidString
                let approved = await withCheckedContinuation { continuation in
                    votes[id] = (voter, continuation)
                    var proposal = GroupPacket("proposal");
                    proposal.groupID = current.id;
                    proposal.requestID = id;
                    proposal.member = member
                    Task { try? await self.send(voter, proposal) }
                    Task {
                        try? await Task.sleep(for: .seconds(60));
                        self.expireVote(id)
                    }
                }
                guard approved else { throw GroupError.denied }
            }
            guard active?.id == current.id, active?.leaderID == localID else { throw GroupError.notLeader }
            current = active!;
            member.joinOrder = (current.members.map(\.joinOrder).max() ?? 0) + 1
            current.members.append(member);
            admitted.insert(peer)
            let added = request.configs ?? []
            guard
                added.allSatisfy({ c in
                    c.ownerPeerID == peer && !current.configs.contains(where: { old in old.id == c.id })
                })
            else { throw GroupError.invalidState }
            current.configs += added
            if let index = current.members.firstIndex(where: { $0.peerID == localID }), let host = session.localHost {
                current.members[index].host = host
            }
            var offset = current.layout.map { $0.x + $0.width }.max() ?? 0
            for var screen in request.screens ?? [] where screen.peerID == peer {
                screen.x = offset;
                screen.y = 0;
                offset += screen.width;
                current.layout.append(screen)
            }
            current.revision += 1;
            locks = [];
            try validate(current);
            try save(current);
            presence[peer] = current.id
            await authorize()
            var reply = GroupPacket("joined");
            reply.state = current;
            reply.locks = locks;
            try await send(peer, reply)
            await broadcast();
            await connectMesh()
        } catch {
            var failed = GroupPacket("error");
            failed.error = "admissionRejected";
            try? await send(peer, failed);
            event("GroupJoinRejected")
        }
    }
    private func expireVote(_ id: String) { votes.removeValue(forKey: id)?.value.resume(returning: false) }
    public func beginEdit(_ resource: String) async throws -> GroupEditLock {
        guard let current = active, online().count > 1, !recovering else { throw GroupError.offline }
        let id = UUID().uuidString;
        var packet = GroupPacket("lockRequest");
        packet.groupID = current.id;
        packet.resource = resource;
        packet.requestID = id
        let granted: GroupEditLock? = await withCheckedContinuation { continuation in
            lockRequests[id] = continuation
            Task {
                if current.leaderID == localID {
                    await self.edit(localID, packet)
                } else {
                    try? await self.send(current.leaderID, packet)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(15));
                self.expireLock(id)
            }
        }
        guard let granted else { throw GroupError.denied };
        return granted
    }
    private func expireLock(_ id: String) { lockRequests.removeValue(forKey: id)?.resume(returning: nil) }
    public func commitLayout(_ layout: [ScreenGeometry], lock: GroupEditLock) async throws {
        guard let current = active, online().count > 1, ScreenGeometry.validLayout(layout), lock.ownerPeerID == localID
        else { throw GroupError.invalidState }
        let id = UUID().uuidString;
        var packet = GroupPacket("commit")
        packet.groupID = current.id;
        packet.editLock = lock;
        packet.screens = layout;
        packet.requestID = id
        let approved = await withCheckedContinuation { continuation in
            commitRequests[id] = continuation
            Task {
                if current.leaderID == localID {
                    await self.edit(localID, packet)
                } else {
                    try? await self.send(current.leaderID, packet)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(15));
                self.commitRequests.removeValue(forKey: id)?.resume(returning: false)
            }
        }
        guard approved else { throw GroupError.denied }
    }
    public func saveKeyboardLibrary(_ configs: [KeyboardConfig], selected: String) async throws {
        guard KeyboardMapping.valid(configs, members: Set(configs.map(\.ownerPeerID)), selected: selected) else {
            throw GroupError.invalidState
        }
        let beforeIDs = Set(ownConfigs.map(\.id))
        // Save the native library first. A remote failure never erases the user's draft.
        try JSONEncoder().encode(configs).write(to: configFile, options: .atomic);
        ownConfigs = configs;
        librarySelected = selected
        try JSONEncoder().encode(selected).write(
            to: configFile.deletingLastPathComponent().appendingPathComponent("keyboard-selection.json"),
            options: .atomic)
        if active != nil, online().count > 1 {
            let lease = try await beginEdit("config")
            do {
                let shared = (active?.configs ?? []).filter {
                    !beforeIDs.contains($0.id) && !Set(configs.map(\.id)).contains($0.id)
                }
                try await commitConfigs(configs + shared, selected: selected, lock: lease)
            } catch {
                await release(lease);
                throw error
            }
            await release(lease)
        }
    }
    private struct ConfigOffer: Codable { var config: KeyboardConfig }
    private func offerConfigs() async {
        for peer in online() where peer != localID && !offeredConfigs.contains(peer) {
            guard let config = connectionConfigs[peer] else { continue };
            offeredConfigs.insert(peer)
            try? await manager.send(
                peerID: peer, channel: "keyboard-config", payload: JSONEncoder().encode(ConfigOffer(config: config)))
        }
    }
    private func receiveConfig(_ peer: String, _ bytes: Data) async {
        guard online().contains(peer), bytes.count <= 32_768,
            let offer = try? JSONDecoder().decode(ConfigOffer.self, from: bytes),
            KeyboardMapping.valid([offer.config], members: [offer.config.ownerPeerID], selected: offer.config.id)
        else { return }
        let remote = offer.config,
            local = connectionLibraries[peer]?.first { $0.id == remote.id } ?? ownConfigs.first { $0.id == remote.id }
        let same =
            local.map {
                $0.name == remote.name && $0.windowsToMac == remote.windowsToMac
                    && $0.macToWindows == remote.macToWindows
            } ?? false
        if same, active?.configs.contains(where: { $0.id == remote.id }) == true { return }
        let choice = same ? "remote" : await confirmConfig?(sessions[peer]?.name ?? peer, remote, local) ?? "skip"
        guard choice != "skip", online().contains(peer), let current = active else { return }
        var configs = ownConfigs
        for config in current.configs where !configs.contains(where: { $0.id == config.id }) { configs.append(config) }
        var selected = remote
        if choice == "local", let local { selected = local }
        if choice == "copy" {
            if let local {
                if let i = configs.firstIndex(where: { $0.id == local.id }) {
                    configs[i] = local
                } else {
                    configs.append(local)
                }
            };
            selected.id = UUID().uuidString.lowercased();
            selected.ownerPeerID = localID;
            selected.name += "（副本）";
            selected.revision = 1
        }
        if let index = configs.firstIndex(where: { $0.id == selected.id }) {
            configs[index] = selected
        } else {
            configs.append(selected)
        }
        do { try await saveKeyboardLibrary(configs, selected: selected.id) } catch {
            event("KeyboardConfigSyncPending")
        }
    }
    public func commitConfigs(_ configs: [KeyboardConfig], selected: String, lock: GroupEditLock) async throws {
        guard let current = active, online().count > 1, lock.ownerPeerID == localID else { throw GroupError.offline }
        let id = UUID().uuidString;
        var packet = GroupPacket("commit")
        packet.groupID = current.id;
        packet.editLock = lock;
        packet.configs = configs;
        packet.currentConfigID = selected;
        packet.requestID = id
        let approved = await withCheckedContinuation { continuation in
            commitRequests[id] = continuation
            Task {
                if current.leaderID == localID {
                    await self.edit(localID, packet)
                } else {
                    try? await self.send(current.leaderID, packet)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(15));
                self.commitRequests.removeValue(forKey: id)?.resume(returning: false)
            }
        }
        guard approved else { throw GroupError.denied }
    }
    public func release(_ lock: GroupEditLock) async {
        guard let current = active else { return };
        var packet = GroupPacket("release");
        packet.groupID = current.id;
        packet.editLock = lock
        if current.leaderID == localID {
            await edit(localID, packet)
        } else {
            try? await send(current.leaderID, packet)
        }
    }
    private func edit(_ peer: String, _ packet: GroupPacket) async {
        guard var current = active, current.leaderID == localID, packet.groupID == current.id, online().contains(peer),
            online().count > 1, !recovering
        else { return }
        if packet.type == "lockRequest", let resource = packet.resource, let id = packet.requestID {
            var reply = GroupPacket("lockResult");
            reply.groupID = current.id;
            reply.requestID = id
            if resource == "layout" || resource == "config" {
                if let existing = locks.first(where: { $0.resource == resource }) {
                    if existing.ownerPeerID == peer { reply.editLock = existing }
                } else {
                    let lock = GroupEditLock(
                        resource: resource, ownerPeerID: peer, token: UUID().uuidString, baseRevision: current.revision)
                    locks.append(lock);
                    reply.editLock = lock
                }
            }
            if peer == localID {
                lockRequests.removeValue(forKey: id)?.resume(returning: reply.editLock)
            } else {
                try? await send(peer, reply)
            }
            await broadcast();
            return
        }
        guard let lease = packet.editLock, locks.contains(lease), lease.ownerPeerID == peer else {
            if packet.type == "commit" { await commitResult(peer, packet, approved: false) };
            return
        }
        if packet.type == "commit" {
            guard lease.baseRevision == current.revision else {
                locks.removeAll { $0.token == lease.token };
                await commitResult(peer, packet, approved: false);
                await broadcast();
                return
            }
            if lease.resource == "layout", let layout = packet.screens, ScreenGeometry.validLayout(layout),
                Set(layout.map(\.id)) == Set(current.layout.map(\.id))
            {
                guard
                    layout.allSatisfy({ next in
                        current.layout.contains {
                            $0.id == next.id && $0.peerID == next.peerID && $0.pixelWidth == next.pixelWidth
                                && $0.pixelHeight == next.pixelHeight
                        }
                    })
                else {
                    await commitResult(peer, packet, approved: false);
                    return
                }
                current.layout = layout
            } else if lease.resource == "config", let configs = packet.configs, let selected = packet.currentConfigID,
                KeyboardMapping.valid(configs, members: Set(current.members.map(\.peerID)), selected: selected),
                configs.allSatisfy({ c in
                    current.configs.first(where: { $0.id == c.id }).map { $0.ownerPeerID == c.ownerPeerID }
                        ?? (UUID(uuidString: c.ownerPeerID) != nil)
                })
            {
                current.configs = configs.map { candidate in
                    var config = candidate
                    let old = current.configs.first { $0.id == config.id }
                    if old?.name != config.name || old?.windowsToMac != config.windowsToMac
                        || old?.macToWindows != config.macToWindows
                    {
                        config.modified = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    config.revision =
                        (old?.revision ?? 1)
                        + ((old?.name != config.name || old?.windowsToMac != config.windowsToMac
                            || old?.macToWindows != config.macToWindows) ? 1 : 0)
                    return config
                };
                current.currentConfigID = selected
            } else {
                await commitResult(peer, packet, approved: false);
                return
            }
            current.revision += 1;
            do { try save(current) } catch {
                event("GroupSaveFailed");
                await commitResult(peer, packet, approved: false);
                return
            }
            locks = [];
            await commitResult(peer, packet, approved: true)
        }
        locks.removeAll { $0.token == lease.token };
        await broadcast()
    }
    private func commitResult(_ peer: String, _ packet: GroupPacket, approved: Bool) async {
        guard let id = packet.requestID else { return }
        if peer == localID {
            commitRequests.removeValue(forKey: id)?.resume(returning: approved)
        } else {
            var reply = GroupPacket("commitResult");
            reply.groupID = packet.groupID;
            reply.requestID = id;
            reply.approved = approved;
            reply.state = approved ? active : nil;
            try? await send(peer, reply)
        }
    }
}
