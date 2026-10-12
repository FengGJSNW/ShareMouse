using System.Text.Json;
using ShareMouse.Core;

namespace ShareMouse.Network;

public sealed class GroupManager
{
    private readonly string localId, name, publicKey, file;
    private readonly SessionManager manager;
    private readonly PeerRegistry registry;
    private readonly Func<GroupMember, Task<bool>> confirm;
    private readonly Action<string> log;
    private readonly Func<GroupMember, string, Task>? connectMember;
    private readonly bool automaticSharing;
    private bool reconcilingSharing;
    private readonly Dictionary<string,SharedGroup> desktopStates = new();
    private readonly HashSet<string> seenPresence = new();
    private readonly object gate = new();
    private GroupStore store;
    private ScreenGeometry[] screens;
    private Dictionary<string, SessionInfo> sessions = new();
    private readonly Dictionary<string, string> presence = new();
    private readonly HashSet<string> admitted = new();
    private readonly List<GroupEditLock> locks = new();
    private readonly Dictionary<string, (string Peer, TaskCompletionSource<bool> Result)> votes = new();
    private readonly Dictionary<string, TaskCompletionSource<GroupEditLock?>> lockRequests = new();
    private readonly Dictionary<string, TaskCompletionSource<bool>> commits = new();
    private string? joining;
    private KeyboardConfig[] ownConfigs;
    private readonly string configFile;
    private string librarySelected="";
    private readonly HashSet<string> offeredConfigs=new();
    private readonly Dictionary<string,KeyboardConfig> connectionConfigs=new();
    private readonly Dictionary<string,KeyboardConfig[]> connectionLibraries=new();
    public Func<string,KeyboardConfig,KeyboardConfig?,Task<string>>? ConfirmConfig {get;set;}
    public KeyboardConfig[] KeyboardLibrary {get{lock(gate)return ownConfigs.ToArray();}}
    public string SelectedKeyboardConfig {get{lock(gate)return librarySelected;}}
    private string? invitationID, invitationLeader;
    private readonly HashSet<string> invited = new();
    private bool proposing, recovering;
    private HashSet<string> recoveryReplies = new();
    private SharedGroup? recovered;
    private int generation;
    private static readonly JsonSerializerOptions json = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };
    public event Action<SharedGroup?, GroupEditLock[], string[], SharedGroup[]>? Changed;
    public SharedGroup? Active { get { lock (gate) return Current(); } }
    public string[] Online { get { lock (gate) return OnlineMembers(); } }
    public GroupEditLock[] EditLocks { get { lock (gate) return locks.ToArray(); } }

    public GroupManager(string localId, string name, string publicKey, ScreenGeometry[] screens, string directory,
        SessionManager manager, PeerRegistry registry, Func<GroupMember, Task<bool>> confirm, Action<string> log,
        Func<GroupMember, string, Task>? connectMember = null, bool automaticSharing = false)
    {
        this.localId = localId; this.name = name; this.publicKey = publicKey; this.screens = screens;
        this.manager = manager; this.registry = registry; this.confirm = confirm; this.log = log;
        this.connectMember = connectMember; this.automaticSharing = automaticSharing;
        file = Path.Combine(directory, "groups.json");
        store = File.Exists(file) ? JsonSerializer.Deserialize<GroupStore>(File.ReadAllText(file), json)
            ?? throw new InvalidDataException("Invalid group store.") : new([], null);
        configFile = Path.Combine(directory,"keyboard-configs.json");
        ownConfigs = File.Exists(configFile) ? JsonSerializer.Deserialize<KeyboardConfig[]>(File.ReadAllText(configFile),json) ?? throw new InvalidDataException("Invalid keyboard configs.") : [];

        if (ownConfigs.Length==0) ownConfigs=[new(Guid.NewGuid().ToString("D"),localId,"默认配置",new(),new(),1)];
        var selectionFile=Path.Combine(directory,"keyboard-selection.json");librarySelected=File.Exists(selectionFile)?JsonSerializer.Deserialize<string>(File.ReadAllText(selectionFile))??ownConfigs[0].Id:ownConfigs[0].Id;
        File.WriteAllText(configFile,JsonSerializer.Serialize(ownConfigs,json));
        admitted.Add(localId); recovering = store.ActiveGroupID is not null;
        if (Current() is { } current && !current.Members.Any(m => m.PeerID == localId && m.PublicKey == publicKey))
            throw new InvalidDataException("Group identity mismatch.");
    }
    public void Start()
    {
        if(!ownConfigs.Any(c=>c.Id==librarySelected))librarySelected=ownConfigs[0].Id;
        manager.SetApplicationCapabilities("group"); manager.Receive("keyboard-config",(peer,bytes)=>{_=ReceiveConfig(peer,bytes);return Task.CompletedTask;});
        manager.Receive("group", Receive); Authorize(); Notify();
    }
    private SharedGroup? Current() => store.Groups.FirstOrDefault(g => g.Id == store.ActiveGroupID);
    private string[] OnlineMembers(SharedGroup? group = null) => (group ?? Current())?.Members
        .Where(m => m.PeerID == localId || sessions.ContainsKey(m.PeerID) && presence.GetValueOrDefault(m.PeerID) == (group ?? Current())?.Id)
        .OrderBy(m => m.JoinOrder).Select(m => m.PeerID).ToArray() ?? [];
    private void Authorize()
    {
        lock (gate) { manager.AuthorizeGroup(Current()?.Id ?? invitationID,
            Current() is { } current ? admitted.Intersect(current.Members.Select(m => m.PeerID)).Union(invited)
                : invitationLeader is { } leader ? [localId, leader] : []); }
    }
    private void Notify()
    {
        SharedGroup? current; GroupEditLock[] leases; string[] online; SharedGroup[] saved;
        lock (gate) { current = Current(); leases = locks.ToArray(); online = OnlineMembers(); saved = store.Groups.ToArray(); }
        Changed?.Invoke(current, leases, online, saved);
        _=OfferConfigs();
    }
    private void Save(SharedGroup? group = null)
    {
        var next = group is null ? store : store with { Groups = store.Groups.Where(g => g.Id != group.Id).Append(group).ToArray() };
        var temporary = file + ".tmp"; File.WriteAllText(temporary, JsonSerializer.Serialize(next, json)); File.Move(temporary, file, true); store = next;
        if (group is not null) {
            if(OnlineMembers().Length>1){librarySelected=group.CurrentConfigID;File.WriteAllText(Path.Combine(Path.GetDirectoryName(configFile)!,"keyboard-selection.json"),JsonSerializer.Serialize(librarySelected));}
            var shared=group.Configs;
            ownConfigs=ownConfigs.Where(c=>!shared.Any(n=>n.Id==c.Id)).Concat(shared).ToArray();
            try { File.WriteAllText(configFile+".tmp",JsonSerializer.Serialize(ownConfigs,json)); File.Move(configFile+".tmp",configFile,true); } catch { log("KeyboardConfigSaveFailed"); }
        }
    }
    private Task Send(string peer, GroupPacket packet) => manager.SendAsync(peer, "group", JsonSerializer.SerializeToUtf8Bytes(packet, json));
    private async Task Announce()
    {
        string[] peers; string? id; SharedGroup? state; lock (gate) { peers = sessions.Keys.ToArray(); id = Current()?.Id; state=automaticSharing?Current():null; }
        foreach (var peer in peers) try { await Send(peer, new() { Type = "presence", GroupID = id, State=state, RequestID=Guid.NewGuid().ToString("D") }); } catch { }
    }
    private async Task Broadcast()
    {
        GroupPacket packet; string[] peers;
        lock (gate) {
            if (Current() is not { } current) return;
            packet = new() { Type = "state", GroupID = current.Id, State = current, Locks = locks.ToArray() };
            peers = OnlineMembers().Where(p => p != localId).ToArray();
        }
        foreach (var peer in peers) try { await Send(peer, packet); } catch { }
        Notify();
    }
    public async Task Create(string groupName = "我的桌面")
    {
        lock (gate) {
            if (Current() is not null) throw new InvalidOperationException("Leave the current group first.");
            var config = ownConfigs.FirstOrDefault(c=>c.Id==librarySelected)??ownConfigs[0];
            var member = new GroupMember(localId, name, publicKey, 0, sessions.Values.FirstOrDefault()?.LocalHost, manager.ListenPort);
            var group = new SharedGroup(Guid.NewGuid().ToString("D"), groupName[..Math.Min(groupName.Length, 128)], localId,
                1, [member], screens, ownConfigs, config.Id);
            store = store with { ActiveGroupID = group.Id }; recovering = false; Save(group);
            log("GroupCreated groupId=" + group.Id);
        }
        Authorize(); await Announce(); Notify();
    }
    public async Task Activate(string id)
    {
        lock (gate) {
            if (Current() is not null || !store.Groups.Any(g => g.Id == id)) throw new InvalidOperationException("Group already active or unavailable.");
            store = store with { ActiveGroupID = id }; admitted.Clear(); admitted.Add(localId); recovering = true; Save();
        }
        Authorize(); await Announce(); await UpdateLeader(); Notify();
    }
    public async Task Leave()
    {
        lock (gate) {
            store = store with { ActiveGroupID = null }; locks.Clear(); admitted.Clear(); admitted.Add(localId);
            joining = null; invitationID = invitationLeader = null; invited.Clear(); recovering = false; Save();
        }
        Authorize(); await Announce(); Notify(); log("GroupLeft");
    }
    public async Task Join(string peer)
    {
        lock (gate) {
            if (Current() is not null || joining is not null) throw new InvalidOperationException("Leave the current group first.");
            if (!sessions.TryGetValue(peer, out var session) || !session.Capabilities.Contains("group")) throw new IOException("Group peer offline.");
            joining = peer;
        }
        try { await Send(peer, new() { Type = "join", Screens = screens, Configs = [] }); }
        catch { lock (gate) joining = null; throw; }
        _ = ExpireJoin(peer);
    }
    public async Task UpdateScreens(ScreenGeometry[] values) {
        lock (gate) screens = values;
        if (Active is not { } current) return;
        var packet = new GroupPacket { Type = "screensChanged", GroupID = current.Id, Screens = values };
        if (current.LeaderID == localId) await ApplyScreens(localId, packet); else try { await Send(current.LeaderID, packet); } catch { }
    }
    private async Task ApplyScreens(string peer, GroupPacket packet) {
        lock (gate) {
            if (Current() is not { } current || current.LeaderID != localId || current.Id != packet.GroupID || !OnlineMembers().Contains(peer)
                || packet.Screens is not { Length: <= 16 } values || values.Any(s => s.PeerID != peer || s.PixelWidth <= 0 || s.PixelHeight <= 0)
                || values.Select(s => s.Id).Distinct().Count() != values.Length) return;
            var layout = current.Layout.Where(s => s.PeerID != peer).ToList();
            var offset = layout.Select(s => s.X + s.Width).DefaultIfEmpty().Max();
            foreach (var value in values) {
                var old = current.Layout.FirstOrDefault(s => s.Id == value.Id);
                var next = old is null ? value with { X=offset, Y=0 } : value with { X=old.X, Y=old.Y, Scale=old.Scale, ScaleX=old.ScaleX, ScaleY=old.ScaleY, Rotation=old.Rotation };
                layout.Add(next); offset = Math.Max(offset, next.X + next.Width);
            }
            if (!ScreenGeometry.ValidLayout(layout.ToArray())) {
                offset = 0; layout = layout.Select(s => { var next=s with { X=offset, Y=0 }; offset+=s.Width; return next; }).ToList();
            }
            if (layout.Count == 0 || layout.Count==current.Layout.Length && layout.All(screen=>current.Layout.FirstOrDefault(old=>old.Id==screen.Id)==screen)) return;
            current = current with { Layout=layout.ToArray(), Revision=current.Revision+1 }; Validate(current); Save(current); locks.Clear();
        }
        await Broadcast();
    }
    private async Task ExpireJoin(string peer) {
        await Task.Delay(TimeSpan.FromSeconds(65));
        lock (gate) if (joining == peer) { joining = null; invitationID = invitationLeader = null; log("GroupJoinTimedOut"); }
        Authorize();
    }
    public async Task Recommend(string peer) {
        GroupPacket packet; string leader;
        lock (gate) {
            var current = Current() ?? throw new InvalidOperationException("No active group.");
            if (registry.Find(peer) is not { Trust: "trusted" } known || !sessions.TryGetValue(peer, out var session)
                || current.Members.Any(m => m.PeerID == peer)) throw new InvalidOperationException("Recommend an online Trusted peer outside the group.");
            leader = current.LeaderID;
            packet = new() { Type = "recommend", GroupID = current.Id,
                Member = new(peer, session.Name, known.PublicKey, 0, session.LanHost, session.ListenPort) };
        }
        if (leader == localId) await ProcessRecommendation(localId, packet); else await Send(leader, packet);
    }
    private async Task ProcessRecommendation(string peer, GroupPacket packet) {
        SharedGroup current;
        lock (gate) {
            current = Current()!;
            if (current is null || current.Id != packet.GroupID || current.LeaderID != localId
                || !OnlineMembers().Contains(peer) || packet.Member is null) return;
        }
        var member = packet.Member;
        if (!await Admit(member, true)) return;
        lock (gate) { if (Current()?.Id != current.Id || Current()?.LeaderID != localId) return; invited.Add(member.PeerID); }
        Authorize();
        var leader = current.Members.First(m => m.PeerID == localId);
        lock (gate) if (sessions.TryGetValue(peer, out var session)) leader = leader with { Host = session.LocalHost ?? leader.Host };
        var invite = new GroupPacket { Type = "invite", GroupID = current.Id, Member = leader, TargetPeerID = member.PeerID };
        try { if (peer == localId) await Send(member.PeerID, invite); else await Send(peer, invite); } catch { }
        _ = ExpireInvitation(member.PeerID);
    }
    private async Task ExpireInvitation(string peer) { await Task.Delay(TimeSpan.FromSeconds(65)); lock (gate) invited.Remove(peer); Authorize(); }
    private async Task ReceiveInvite(string peer, GroupPacket packet) {
        lock (gate) {
            if (Current() is { } current) {
                if (current.LeaderID != peer || packet.GroupID != current.Id || packet.TargetPeerID is not { } target
                    || registry.Find(target)?.Trust != "trusted" || !sessions.ContainsKey(target)) return;
                _ = Send(target, packet); return;
            }
            if (joining is not null || packet.GroupID is null || packet.Member is null || packet.TargetPeerID != localId
                || registry.Find(peer)?.Trust != "trusted") return;
        }
        var leader = packet.Member!;
        if (!await Admit(leader, true)) return;
        lock (gate) { if (Current() is not null || joining is not null) return; invitationID = packet.GroupID; invitationLeader = leader.PeerID; }
        Authorize();
        try { await ConnectMember(leader, packet.GroupID!); await Join(leader.PeerID); }
        catch { lock (gate) { invitationID = invitationLeader = null; } Authorize(); log("GroupRecommendationUnavailable"); }
    }
    public async Task ConnectionsChanged(SessionInfo[] values)
    {
        bool changedPeers;
        lock (gate) {
            changedPeers = !sessions.Keys.ToHashSet().SetEquals(values.Select(s => s.PeerID));
            foreach(var next in values.Where(v=>!sessions.ContainsKey(v.PeerID))) { connectionConfigs[next.PeerID]=ownConfigs.FirstOrDefault(c=>c.Id==librarySelected)??ownConfigs[0]; connectionLibraries[next.PeerID]=ownConfigs.ToArray(); }
            foreach(var old in sessions.Keys.Where(p=>!values.Any(v=>v.PeerID==p)).ToArray()){connectionConfigs.Remove(old);connectionLibraries.Remove(old);offeredConfigs.Remove(old);}
            sessions = values.ToDictionary(s => s.PeerID);
            foreach (var peer in seenPresence.Where(p => !sessions.ContainsKey(p)).ToArray()) { presence.Remove(peer); seenPresence.Remove(peer); desktopStates.Remove(peer); }
            if (Current() is { } current) {
                admitted.UnionWith(current.Members.Where(m => sessions.ContainsKey(m.PeerID)).Select(m => m.PeerID));
                locks.RemoveAll(l => l.OwnerPeerID != localId && !sessions.ContainsKey(l.OwnerPeerID));
            }
        }
        Authorize(); if (changedPeers) { await Announce(); await UpdateLeader(); } await ReconcileSharing(); Notify();
    }
    private async Task ReconcileSharing() {
        SessionInfo? session; SharedGroup? current,remote; bool hosts;
        lock(gate) {
            if(!automaticSharing || reconcilingSharing || joining is not null || OnlineMembers().Length>1) return;
            current=Current(); session=sessions.Values.OrderBy(s=>s.PeerID).FirstOrDefault(s=>s.Capabilities.Contains("group") && seenPresence.Contains(s.PeerID) && (current is null || presence.GetValueOrDefault(s.PeerID)!=current.Id));
            if(session is null) return; remote=desktopStates.GetValueOrDefault(session.PeerID);
            var localContainsPeer=current?.Members.Any(m=>m.PeerID==session.PeerID)==true;
            var remoteContainsLocal=remote?.Members.Any(m=>m.PeerID==localId)==true;
            hosts=localContainsPeer!=remoteContainsLocal?localContainsPeer:localContainsPeer && current is not null && remote is not null?string.CompareOrdinal(current.Id,remote.Id)<0:session.InitiatorPeerID==localId;
            reconcilingSharing=true;
        }
        try {
            if(hosts) {
                SharedGroup? saved; lock(gate) saved=store.Groups.Where(g=>g.Members.Any(m=>m.PeerID==session.PeerID)).OrderByDescending(g=>g.Revision).FirstOrDefault();
                if(Active?.Members.Any(m=>m.PeerID==session.PeerID)!=true && saved is not null) {
                    if(Active is not null) await Leave();
                    await Activate(saved.Id);
                } else if(Active is null) {
                    await Create(name+"的连续桌面");
                }
                await Announce();
            } else if(remote is not null && remote.LeaderID==session.PeerID) {
                if(Active is not null) await Leave();
                await Join(session.PeerID);
            }
        } catch { log("AutomaticDesktopPending peerId="+session.PeerID); }
        finally { lock(gate) reconcilingSharing=false; }
    }
    private async Task UpdateLeader()
    {
        string[] queries = []; bool broadcast = false; int round = 0; string? id = null;
        lock (gate) {
            if (Current() is not { } current || OnlineMembers().FirstOrDefault() is not { } next) return;
            if (current.LeaderID != next) {
                current = current with { LeaderID = next }; locks.Clear(); Save(current);
                log("GroupLeaderChanged peerId=" + next); broadcast = next == localId;
            }
            id = current.Id;
            if (next == localId && recovering && recoveryReplies.Count == 0 && OnlineMembers().Length > 1) {
                recoveryReplies = OnlineMembers().Where(p => p != localId).ToHashSet(); recovered = current; queries = recoveryReplies.ToArray(); round = ++generation;
            } else if (next != localId) { recovering = false; queries = [next]; }
        }
        foreach (var peer in queries) try { await Send(peer, new() { Type = round > 0 ? "replicaRequest" : "stateRequest", GroupID = id }); } catch { }
        if (round > 0) _ = FinishRecoveryLater(round);
        else if (broadcast) await Broadcast();
    }
    private async Task FinishRecoveryLater(int round) { await Task.Delay(TimeSpan.FromSeconds(10)); await FinishRecovery(round); }
    private async Task FinishRecovery(int round)
    {
        SharedGroup? candidate; lock (gate) { if (!recovering || round != generation) return; candidate = recovered ?? Current(); }
        if (candidate is null) return;
        foreach (var member in candidate.Members) if (!await Admit(member)) { await Leave(); log("GroupAdmissionDeclined"); return; }
        lock (gate) {
            if (Current()?.Id != candidate.Id || !recovering || round != generation) return;
            candidate = candidate with { LeaderID = OnlineMembers(candidate).FirstOrDefault() ?? localId, Revision = candidate.Revision + 1 };
            recovering = false; recoveryReplies.Clear(); recovered = null; locks.Clear(); Save(candidate);
        }
        Authorize(); await Broadcast();
    }
    private async Task ReconcileReplica(string peer, SharedGroup? state)
    {
        bool recover=false, broadcast=false;
        lock(gate) {
            if(state is null || Current() is not {} current || state.Id!=current.Id || current.LeaderID!=localId || !OnlineMembers().Contains(peer) || recovering) return;
            try { Validate(state); } catch { return; }
            if(state.Revision>current.Revision) { recovering=true;recover=true; }
            else broadcast=state.Revision!=current.Revision || state.LeaderID!=current.LeaderID || !state.Layout.SequenceEqual(current.Layout)
                || state.CurrentConfigID!=current.CurrentConfigID || !state.Members.SequenceEqual(current.Members);
        }
        if(recover) await UpdateLeader(); else if(broadcast) await Broadcast();
    }
    private void Validate(SharedGroup group)
    {
        if (!Guid.TryParse(group.Id, out _) || group.Members.Length == 0
            || group.Members.Select(m => m.PeerID).Distinct().Count() != group.Members.Length
            || group.Members.Select(m => m.JoinOrder).Distinct().Count() != group.Members.Length
            || !group.Members.Any(m => m.PeerID == localId && m.PublicKey == publicKey)
            || group.Members.Any(m => !Guid.TryParse(m.PeerID, out _) || m.PublicKey.Length > 1024 || m.Port is < 1 or > 65535)
            || !group.Members.Any(m => m.PeerID == group.LeaderID) || !ScreenGeometry.ValidLayout(group.Layout)
            || group.Layout.Any(s => !group.Members.Any(m => m.PeerID == s.PeerID)) || !KeyboardMapping.Valid(group.Configs,group.Members.Select(m=>m.PeerID),group.CurrentConfigID))
            throw new InvalidDataException("Invalid group state.");
        foreach (var member in group.Members) if (registry.Find(member.PeerID) is { } known && known.PublicKey != member.PublicKey)
            throw new InvalidDataException("Group member identity changed.");
    }
    private async Task<bool> Admit(GroupMember member, bool explicitConfirmation = false)
    {
        if (!Guid.TryParse(member.PeerID, out _) || member.PublicKey.Length > 1024 || member.Port is < 1 or > 65535) return false;
        if (member.PeerID == localId) return member.PublicKey == publicKey;
        if (registry.Find(member.PeerID) is { } known && known.PublicKey != member.PublicKey) return false;
        bool approved; lock (gate) approved = admitted.Contains(member.PeerID) || sessions.ContainsKey(member.PeerID);
        if ((explicitConfirmation || !approved) && !await confirm(member)) return false;
        try { registry.Remember(new(member.PeerID, member.PublicKey), member.Name); lock (gate) admitted.Add(member.PeerID); return true; }
        catch { return false; }
    }
    private async Task AcceptState(string peer, GroupPacket packet)
    {
        if (packet.State is not { } state) return;
        lock (gate) {
            if (!(packet.Type == "joined" && joining == peer && Current() is null)
                && !(Current()?.Id == state.Id && state.Members.Any(m => m.PeerID == peer))) return;
        }
        try {
            Validate(state);
            if (packet.Type == "replica") {
                int round; bool done;
                lock (gate) {
                    if (!recovering || !recoveryReplies.Contains(peer)) return;
                    if (state.Revision > (recovered?.Revision ?? 0)) recovered = state;
                    recoveryReplies.Remove(peer); round = generation; done = recoveryReplies.Count == 0;
                }
                if (done) await FinishRecovery(round); return;
            }
            lock (gate) {
                if (state.LeaderID != peer || packet.Type != "joined" && OnlineMembers(state).FirstOrDefault() != peer
                    || Current() is { } current && state.Revision < current.Revision) return;
            }
            foreach (var member in state.Members) if (!await Admit(member)) throw new InvalidDataException("Membership declined.");
            bool activated;
            lock (gate) {
                if (packet.Type == "joined" ? joining != peer || Current() is not null : Current()?.Id != state.Id) return;
                activated = store.ActiveGroupID != state.Id;
                store = store with { ActiveGroupID = state.Id }; joining = null; invitationID = invitationLeader = null; recovering = false; presence[peer] = state.Id;
                state = state with { LeaderID = OnlineMembers(state).FirstOrDefault() ?? state.LeaderID }; Save(state);
                locks.Clear(); locks.AddRange(packet.Locks ?? []);
            }
            Authorize(); if (activated) await Announce(); Notify(); await ConnectMesh(); log($"GroupStateApplied groupId={state.Id} revision={state.Revision}");
        } catch { lock (gate) joining = null; log("GroupStateRejected"); }
    }
    private async Task ConnectMesh()
    {
        SharedGroup? current; GroupMember[] missing;
        lock (gate) { current = Current(); missing = current?.Members.Where(m => m.PeerID != localId && !sessions.ContainsKey(m.PeerID) && admitted.Contains(m.PeerID)).ToArray() ?? []; }
        if (current is null) return;
        foreach (var member in missing) try { await ConnectMember(member, current.Id); } catch { }
    }
    private async Task ConnectMember(GroupMember member, string id) {
        if (manager.CurrentSessions().Any(s => s.PeerID == member.PeerID)) return;
        if (connectMember is not null) await connectMember(member, id);
        else if (member.Host is { } host) await manager.ConnectAsync(host, member.Port, null, null, autoOnly: true, groupId: id, expectedPeerId: member.PeerID);
        else throw new IOException("Member endpoint unavailable.");
    }
    private async Task Receive(string peer, byte[] bytes)
    {
        GroupPacket? packet; try { packet = JsonSerializer.Deserialize<GroupPacket>(bytes, json); } catch { return; }
        if (packet is null) return;
        switch (packet.Type) {
            case "presence":
                bool changedPresence;
                bool releasedLease;
                lock (gate) { seenPresence.Add(peer);
                    if(packet.State is {} state && state.Id==packet.GroupID && state.Members.Any(m=>m.PeerID==peer && m.PublicKey==registry.Find(peer)?.PublicKey)) desktopStates[peer]=state; else desktopStates.Remove(peer);
                    changedPresence = presence.GetValueOrDefault(peer) != packet.GroupID; if (packet.GroupID is { } id) presence[peer] = id; else presence.Remove(peer);
                    releasedLease=packet.GroupID!=Current()?.Id && locks.RemoveAll(l=>l.OwnerPeerID==peer)>0; }
                if (changedPresence) await UpdateLeader(); await ReconcileReplica(peer,packet.State); if (releasedLease && Active?.LeaderID==localId) await Broadcast(); await ReconcileSharing(); Notify();
                if(packet.RequestID is not null) {
                    SharedGroup? current; lock(gate) current=Current();
                    try {await Send(peer,new(){Type="presence",GroupID=current?.Id,State=automaticSharing?current:null});}catch{}
                }
                break;
            case "join": _ = ProcessJoin(peer, packet); break;
            case "recommend": _ = ProcessRecommendation(peer, packet); break;
            case "invite": _ = ReceiveInvite(peer, packet); break;
            case "screensChanged": try { await ApplyScreens(peer, packet); } catch { log("ScreenUpdateRejected"); } break;
            case "proposal": _ = Vote(peer, packet); break;
            case "vote":
                lock (gate) if (packet.RequestID is { } voteId && votes.TryGetValue(voteId, out var vote) && vote.Peer == peer) { votes.Remove(voteId); vote.Result.TrySetResult(packet.Approved == true); }
                break;
            case "joined": case "state": case "replica": _ = AcceptState(peer, packet); break;
            case "stateRequest": case "replicaRequest":
                GroupPacket? reply = null;
                lock (gate) if (Current() is { } state && state.Id == packet.GroupID && state.Members.Any(m => m.PeerID == peer))
                    reply = new() { Type = packet.Type != "replicaRequest" && state.LeaderID == localId ? "state" : "replica", GroupID = state.Id, State = state, Locks = locks.ToArray() };
                if (reply is not null) try { await Send(peer, reply); } catch { }
                break;
            case "lockRequest": case "commit": case "release": await Edit(peer, packet); break;
            case "lockResult":
                lock (gate) if (peer == Current()?.LeaderID && packet.RequestID is { } lockId && lockRequests.Remove(lockId, out var pendingLock)) pendingLock.TrySetResult(packet.EditLock);
                break;
            case "commitResult":
                lock (gate) if (peer == Current()?.LeaderID && packet.RequestID is { } commitId && commits.Remove(commitId, out var pendingCommit)) {
                    var applied=packet.Approved==true && packet.State is { } state && state.Id==Current()?.Id && state.Revision>=Current()!.Revision
                        && state.Members.Select(m=>m.PeerID).Order().SequenceEqual(Current()!.Members.Select(m=>m.PeerID).Order());
                    if(applied) { try { Validate(packet.State!); Save(packet.State); locks.Clear(); } catch { applied=false; } }
                    pendingCommit.TrySetResult(applied);
                }
                Notify();
                break;
            case "error": case "redirect": lock (gate) joining = null; log(packet.Type == "redirect" ? "GroupJoinRequiresLeader" : "GroupOperationRejected"); break;
        }
    }
    private async Task Vote(string peer, GroupPacket packet)
    {
        bool valid; lock (gate) valid = Current()?.Id == packet.GroupID && Current()?.LeaderID == peer;
        var approved = valid && packet.Member is { } member && await Admit(member);
        try { await Send(peer, new() { Type = "vote", GroupID = packet.GroupID, RequestID = packet.RequestID, Approved = approved }); } catch { }
    }
    private async Task ProcessJoin(string peer, GroupPacket request)
    {
        SessionInfo session; KnownPeer certificate;
        lock (gate) {
            if (proposing || !sessions.TryGetValue(peer, out session!) || registry.Find(peer) is not { } known) return;
            certificate = known; proposing = true;
        }
        try {
            if (Active is { } existing && existing.LeaderID != localId) {
                await Send(peer, new() { Type = "redirect", LeaderID = existing.LeaderID }); return;
            }
            var member = new GroupMember(peer, session.Name, certificate.PublicKey, 0, session.LanHost, session.ListenPort);
            if (!automaticSharing && !await confirm(member)) throw new InvalidOperationException("Admission declined.");
            if (Active is null) await Create();
            var current = Active!;
            if (current.Members.Any(m => m.PeerID == peer)) { await Send(peer, new() { Type = "joined", State = current, Locks = EditLocks }); return; }
            foreach (var voter in Online.Where(p => p != localId && p != peer)) {
                var id = Guid.NewGuid().ToString("D"); var result = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                lock (gate) votes[id] = (voter, result);
                try {
                    await Send(voter, new() { Type = "proposal", GroupID = current.Id, RequestID = id, Member = member });
                    if (!await result.Task.WaitAsync(TimeSpan.FromSeconds(60))) throw new InvalidOperationException("Membership declined.");
                } finally { lock (gate) votes.Remove(id); }
            }
            lock (gate) {
                if (Current()?.Id != current.Id || Current()?.LeaderID != localId) throw new InvalidOperationException("Group changed.");
                current = Current()!; member = member with { JoinOrder = current.Members.Max(m => m.JoinOrder) + 1 };
                var members = current.Members.Select(m => m.PeerID == localId && session.LocalHost is not null ? m with { Host = session.LocalHost } : m).Append(member).ToArray();
                var layout = current.Layout.ToList(); var offset = layout.Select(s => s.X + s.Width).DefaultIfEmpty().Max();
                foreach (var screen in (request.Screens ?? []).Where(s => s.PeerID == peer)) { layout.Add(screen with { X = offset, Y = 0 }); offset += screen.Width; }
                var added=request.Configs ?? [];
                if (added.Any(c=>c.OwnerPeerID!=peer || current.Configs.Any(old=>old.Id==c.Id))) throw new InvalidDataException("Invalid joining configs.");
                current = current with { Members = members, Layout = layout.ToArray(), Configs=current.Configs.Concat(added).ToArray(), Revision = current.Revision + 1 };
                Validate(current); admitted.Add(peer); presence[peer] = current.Id; locks.Clear(); Save(current);
            }
            Authorize(); await Send(peer, new() { Type = "joined", State = current, Locks = EditLocks }); await Broadcast(); await ConnectMesh();
        } catch { try { await Send(peer, new() { Type = "error", Error = "admissionRejected" }); } catch { } log("GroupJoinRejected"); }
        finally { lock (gate) proposing = false; }
    }
    public async Task<GroupEditLock> BeginEdit(string resource)
    {
        SharedGroup current; var id = Guid.NewGuid().ToString("D"); var result = new TaskCompletionSource<GroupEditLock?>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate) {
            current = Current() ?? throw new InvalidOperationException("No active group.");
            if (OnlineMembers().Length < 2 || recovering) throw new IOException("Group offline or restoring.");
            lockRequests[id] = result;
        }
        try {
            var packet = new GroupPacket { Type = "lockRequest", GroupID = current.Id, Resource = resource, RequestID = id };
            if (current.LeaderID == localId) await Edit(localId, packet); else await Send(current.LeaderID, packet);
            return await result.Task.WaitAsync(TimeSpan.FromSeconds(15)) ?? throw new InvalidOperationException("Resource is being edited.");
        } finally { lock (gate) lockRequests.Remove(id); }
    }
    public Task CommitLayout(ScreenGeometry[] layout, GroupEditLock lease) => Commit(new() { Type = "commit", Screens = layout, EditLock = lease });
    public async Task SaveKeyboardLibrary(KeyboardConfig[] configs,string selected) {
        if(!KeyboardMapping.Valid(configs,configs.Select(c=>c.OwnerPeerID),selected))throw new InvalidDataException("Invalid keyboard configuration.");
        HashSet<string> beforeIDs;lock(gate)beforeIDs=ownConfigs.Select(c=>c.Id).ToHashSet();
        lock(gate){File.WriteAllText(configFile,JsonSerializer.Serialize(configs,json));ownConfigs=configs.ToArray();librarySelected=selected;File.WriteAllText(Path.Combine(Path.GetDirectoryName(configFile)!,"keyboard-selection.json"),JsonSerializer.Serialize(selected));}
        if(Active is not null&&Online.Length>1){var lease=await BeginEdit("config");try{var shared=(Active?.Configs??[]).Where(c=>!beforeIDs.Contains(c.Id)&&!configs.Any(n=>n.Id==c.Id));await CommitConfigs(configs.Concat(shared).ToArray(),selected,lease);}finally{await Release(lease);}}
    }
    private sealed record ConfigOffer(KeyboardConfig Config);
    private async Task OfferConfigs() {
        (string Peer,KeyboardConfig Config)[] values;
        lock(gate){values=OnlineMembers().Where(p=>p!=localId&&!offeredConfigs.Contains(p)&&connectionConfigs.ContainsKey(p)).Select(p=>(p,connectionConfigs[p])).ToArray();foreach(var v in values)offeredConfigs.Add(v.Peer);}
        foreach(var value in values)try{await manager.SendAsync(value.Peer,"keyboard-config",JsonSerializer.SerializeToUtf8Bytes(new ConfigOffer(value.Config),json));}catch{}
    }
    private async Task ReceiveConfig(string peer,byte[] bytes) {
        if(!Online.Contains(peer)||bytes.Length>32768)return;
        ConfigOffer? offer;try{offer=JsonSerializer.Deserialize<ConfigOffer>(bytes,json);}catch{return;}
        if(offer is null||!KeyboardMapping.Valid([offer.Config],[offer.Config.OwnerPeerID],offer.Config.Id))return;
        var remote=offer.Config; KeyboardConfig? local;lock(gate)local=connectionLibraries.GetValueOrDefault(peer,[]).FirstOrDefault(c=>c.Id==remote.Id)??ownConfigs.FirstOrDefault(c=>c.Id==remote.Id);
        var same=local is not null&&local.Name==remote.Name&&KeyboardMapping.Same(local,remote);
        if(same&&Active?.Configs.Any(c=>c.Id==remote.Id)==true)return;
        var choice=same?"remote":ConfirmConfig is {} confirm?await confirm(manager.CurrentSessions().FirstOrDefault(s=>s.PeerID==peer)?.Name??peer,remote,local):"skip";
        if(choice=="skip"||!Online.Contains(peer)||Active is not {} current)return;
        var selected=choice=="local"&&local is not null?local:remote;
        if(choice=="copy")selected=selected with{Id=Guid.NewGuid().ToString("D"),OwnerPeerID=localId,Name=selected.Name+"（副本）",Revision=1};
        var configs=KeyboardLibrary.Concat(current.Configs).GroupBy(c=>c.Id).Select(g=>g.First()).Where(c=>c.Id!=selected.Id).Append(selected).ToArray();
        if(choice=="copy"&&local is not null)configs=configs.Where(c=>c.Id!=local.Id).Append(local).ToArray();
        try{await SaveKeyboardLibrary(configs,selected.Id);}catch{log("KeyboardConfigSyncPending");}
    }
    public Task CommitConfigs(KeyboardConfig[] configs, string selected, GroupEditLock lease) => Commit(new() { Type = "commit", Configs = configs, CurrentConfigID = selected, EditLock = lease });
    private async Task Commit(GroupPacket packet)
    {
        SharedGroup current; var id = Guid.NewGuid().ToString("D"); var result = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate) {
            current = Current() ?? throw new InvalidOperationException("No active group.");
            if (OnlineMembers().Length < 2 || recovering || packet.EditLock?.OwnerPeerID != localId) throw new IOException("Group offline or restoring.");
            commits[id] = result; packet.RequestID = id; packet.GroupID = current.Id;
        }
        try {
            if (current.LeaderID == localId) await Edit(localId, packet); else await Send(current.LeaderID, packet);
            if (!await result.Task.WaitAsync(TimeSpan.FromSeconds(15))) throw new InvalidOperationException("Shared state changed; reacquire the edit lock.");
        } finally { lock (gate) commits.Remove(id); }
    }
    public async Task Release(GroupEditLock lease)
    {
        if (Active is not { } current) return;
        var packet = new GroupPacket { Type = "release", GroupID = current.Id, EditLock = lease };
        if (current.LeaderID == localId) await Edit(localId, packet); else try { await Send(current.LeaderID, packet); } catch { }
    }
    private async Task Edit(string peer, GroupPacket packet)
    {
        GroupPacket? result = null; bool broadcast = false;
        lock (gate) {
            var current = Current();
            if (current is null || current.LeaderID != localId || current.Id != packet.GroupID || !OnlineMembers().Contains(peer) || OnlineMembers().Length < 2 || recovering) return;
            if (packet.Type == "lockRequest" && packet.Resource is { } resource) {
                GroupEditLock? granted = null;
                if (resource is "layout" or "config") {
                    if(locks.FirstOrDefault(l=>l.Resource==resource) is {} existing) { if(existing.OwnerPeerID==peer) granted=existing; }
                    else {granted=new(resource,peer,Guid.NewGuid().ToString("D"),current.Revision);locks.Add(granted);}
                }
                result = new() { Type = "lockResult", GroupID = current.Id, RequestID = packet.RequestID, EditLock = granted }; broadcast = true;
            } else if (packet.EditLock is { } lease && lease.OwnerPeerID == peer && locks.Contains(lease)) {
                if (packet.Type == "release") { locks.Remove(lease); broadcast = true; }
                else if (packet.Type == "commit") {
                    var valid = lease.BaseRevision == current.Revision;
                    if (valid && lease.Resource == "layout" && packet.Screens is { } layout && ScreenGeometry.ValidLayout(layout)
                        && layout.Length == current.Layout.Length && layout.All(next => current.Layout.Any(old => old.Id == next.Id && old.PeerID == next.PeerID && old.PixelWidth == next.PixelWidth && old.PixelHeight == next.PixelHeight))) current = current with { Layout = layout };
                    else if (valid && lease.Resource == "config" && packet.Configs is { } configs && packet.CurrentConfigID is { } selected && KeyboardMapping.Valid(configs,current.Members.Select(m=>m.PeerID),selected)
                        && configs.All(c=>current.Configs.FirstOrDefault(old=>old.Id==c.Id) is { } old ? old.OwnerPeerID==c.OwnerPeerID : Guid.TryParse(c.OwnerPeerID,out _))) {
                        var before=current.Configs;
                        current=current with { Configs=configs.Select(c=> {
                            var old=before.FirstOrDefault(o=>o.Id==c.Id);
                            var changed=old is null || old.Name!=c.Name || !old.WindowsToMac.OrderBy(p=>p.Key).SequenceEqual(c.WindowsToMac.OrderBy(p=>p.Key)) || !old.MacToWindows.OrderBy(p=>p.Key).SequenceEqual(c.MacToWindows.OrderBy(p=>p.Key));
                            return c with { Revision=(old?.Revision ?? 1)+(changed?1UL:0UL),Modified=changed?DateTimeOffset.UtcNow.ToUnixTimeMilliseconds():c.Modified };
                        }).ToArray(), CurrentConfigID=selected };
                    }
                    else valid = false;
                    if (valid) { current = current with { Revision = current.Revision + 1 }; try { Save(current); locks.Clear(); } catch { valid = false; log("GroupSaveFailed"); } }
                    else locks.Remove(lease);
                    result = new() { Type = "commitResult", GroupID = current.Id, RequestID = packet.RequestID, Approved = valid, State=valid?current:null }; broadcast = true;
                }
            } else if (packet.Type == "commit") result = new() { Type = "commitResult", GroupID = current.Id, RequestID = packet.RequestID, Approved = false };
            if (peer == localId && result?.RequestID is { } requestId) {
                if (result.Type == "lockResult" && lockRequests.Remove(requestId, out var lockResult)) lockResult.TrySetResult(result.EditLock);
                if (result.Type == "commitResult" && commits.Remove(requestId, out var commitResult)) commitResult.TrySetResult(result.Approved == true);
                result = null;
            }
        }
        if (result is not null) try { await Send(peer, result); } catch { }
        if (broadcast) await Broadcast();
    }
}
