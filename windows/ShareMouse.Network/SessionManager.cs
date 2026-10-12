using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Net.Quic;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Security.Cryptography;
using System.Text;
using ShareMouse.Core;

namespace ShareMouse.Network;

public sealed class SessionManager : IAsyncDisposable
{
    private volatile bool bluetoothInputPreferred;
    public bool BluetoothInputOnly => bluetoothInputPreferred;
    public void SetInputLinkPreference(bool bluetooth) {bluetoothInputPreferred=bluetooth;foreach(var policy in routePolicies.Values)lock(policy)policy.ResetPreference();}
    private readonly string localId, name;
    private readonly IdentityStore identity;
    private readonly PeerRegistry registry;
    private readonly Func<CertificatePeer, bool> confirmCertificate;
    private readonly Func<string, bool> confirmConnection;
    private readonly Func<string, bool> confirmBluetoothConnection;
    private readonly Func<string,string,bool,Task<bool>>? confirmPeerConnection;
    private readonly string instanceID=Guid.NewGuid().ToString("D");
    private readonly Dictionary<string,string> remoteInstances=new();
    private readonly Dictionary<string,int> pendingHandshakes=new();
    private readonly ConcurrentDictionary<ISessionTransport,string> linkInitiators = new();
    private readonly Action<string> log;
    private readonly CancellationTokenSource lifetime = new();
    private readonly ConcurrentDictionary<string, SessionLink> sessions = new();
    private readonly object credentialsGate = new();
    private readonly object sessionsGate = new();
    private sealed record ProbePending(string Peer,string Kind,long Start,Action<double> Received);
    private readonly ConcurrentDictionary<string,ProbePending> probeTimes=new();
    private readonly List<DateTime> failedAttempts = [];
    private readonly ConcurrentDictionary<string,bool> declinedConnections = new();
    private string pairCode, password;
    private string? authorizedGroup;
    private readonly object groupGate = new();
    private HashSet<string> groupMembers = new();
    private string[] applicationCapabilities = ["network-endpoints-v1","compact-diagnostics-v1","background-flow-v1","throughput-test-v1","compact-data-v1","bulk-fragments-v1","adaptive-file-window-v1"];
    private readonly SemaphoreSlim capabilityGate = new(1,1);
    private readonly Dictionary<string,ulong> remoteCapabilitySequences = new();
    private readonly ConcurrentDictionary<string,long> bulkNetworkDeadline = new();
    private readonly object trafficGate = new();
    private readonly Dictionary<string,(int Sent,long SentBytes,int Received,long ReceivedBytes)> traffic = new();
    private long trafficReportAt=Environment.TickCount64;
    private readonly ConcurrentDictionary<string, string[]> remoteCapabilities = new();
    public int ListenPort { get; private set; } = 49160;
    public void SetApplicationCapabilities(params string[] capabilities) => applicationCapabilities = capabilities.Concat(new[]{"network-endpoints-v1","compact-diagnostics-v1","background-flow-v1","throughput-test-v1","compact-data-v1","bulk-fragments-v1","adaptive-file-window-v1"}).Distinct().ToArray();
    public Task SetCapabilityAsync(string capability, bool enabled) => SetCapabilitiesAsync(new Dictionary<string,bool> {[capability]=enabled});
    public async Task SetCapabilitiesAsync(IReadOnlyDictionary<string,bool> values) {
        await capabilityGate.WaitAsync();
        try {
            lock(sessionsGate) {
                var next=applicationCapabilities.ToHashSet();
                foreach(var item in values) {if(item.Value)next.Add(item.Key);else next.Remove(item.Key);}
                if(next.SetEquals(applicationCapabilities))return;
                applicationCapabilities=next.ToArray();
                foreach(var item in sessions.Values)
                    item.Info=item.Info with {Capabilities=remoteCapabilities.GetValueOrDefault(item.Info.PeerID,[]).Intersect(applicationCapabilities).Concat(item.Links.Keys).Distinct().ToArray()};
            }
            foreach(var peer in sessions.Keys) {
                try {await SendAsync(peer,"capabilities",[]);}catch { }
            }
            Changed?.Invoke(CurrentSessions());
        } finally {capabilityGate.Release();}
    }
    internal void ApplyRemoteCapabilities(string peer,ulong sequence,byte[] bytes,ISessionTransport? source=null) {
        try {
            var values=System.Text.Json.JsonSerializer.Deserialize<string[]>(bytes);
            if(values is null || values.Length>32 || values.Any(v=>v.Length>32))return;
            lock(sessionsGate) {
                if(!sessions.TryGetValue(peer,out var item) || sequence<=remoteCapabilitySequences.GetValueOrDefault(peer))return;
                if(source is not null && (!item.Links.TryGetValue(source.Kind,out var live) || !ReferenceEquals(live,source)))return;
                remoteCapabilitySequences[peer]=sequence;
                if(values.ToHashSet().SetEquals(remoteCapabilities.GetValueOrDefault(peer,[])))return;
                remoteCapabilities[peer]=values;
                item.Info=item.Info with {Capabilities=values.Intersect(applicationCapabilities).Concat(item.Links.Keys).Distinct().ToArray()};
                Changed?.Invoke(CurrentSessions());
            }
        } catch { }
    }
    public void AuthorizeGroup(string? id, IEnumerable<string> members) { lock (groupGate) { authorizedGroup = id; groupMembers = members.ToHashSet(); } }
    private bool GroupAuthorized(string? id, string peerId) { lock (groupGate) return id is not null && id == authorizedGroup && groupMembers.Contains(peerId); }
    private TcpListener? listener, bluetoothListener;
    private QuicListener? quicListener;
    public event Action<SessionInfo[]>? Changed;
    private readonly ConcurrentDictionary<string, Func<string, byte[],ISessionTransport, Task>> receivers = new();
    private sealed class SessionLink(ISessionTransport link, SessionInfo info)
    {
        public ConcurrentDictionary<string, ISessionTransport> Links { get; } = new(new[] { new KeyValuePair<string, ISessionTransport>(link.Kind, link) });
        public SessionInfo Info = info;
        public ConcurrentDictionary<string, SemaphoreSlim> SendGates { get; } = new();
        public ulong Sent;
    }
    private readonly ConcurrentDictionary<ISessionTransport, long> lastReceived = new();

    public SessionManager(string localId, string name, IdentityStore identity, PeerRegistry registry,
        string pairCode, string password, Func<CertificatePeer, bool> confirmCertificate,
        Func<string, bool> confirmConnection, Action<string> log, Func<string, bool>? confirmBluetoothConnection = null,
        Func<string,string,bool,Task<bool>>? confirmPeerConnection = null, bool? bluetoothInputOnly = null)
    {
        bluetoothInputPreferred = bluetoothInputOnly ?? Environment.GetCommandLineArgs().Contains("--bluetooth-input");
        this.localId = localId; this.name = name; this.identity = identity; this.registry = registry;
        this.pairCode = pairCode; this.password = password;
        this.confirmCertificate = confirmCertificate; this.confirmConnection = confirmConnection; this.log = log;
        this.confirmBluetoothConnection = confirmBluetoothConnection ?? confirmConnection;
        this.confirmPeerConnection = confirmPeerConnection;
    }
    private readonly ConcurrentDictionary<string,string> pendingSessionIds = new();
    private sealed record NetworkAdvertisement(bool Enabled, NetworkEndpoint[] Endpoints);
    private static readonly System.Text.Json.JsonSerializerOptions networkJson = new() {PropertyNamingPolicy=System.Text.Json.JsonNamingPolicy.CamelCase,PropertyNameCaseInsensitive=true};
    private readonly SemaphoreSlim recoveryGate = new(1,1);
    private readonly ConcurrentDictionary<string,InputRoutePolicy> routePolicies=new();
    private readonly ConcurrentDictionary<ISessionTransport,long> heartbeatSent=new();
    private readonly ConcurrentDictionary<string,long> recoveryNext = new();
    private readonly ConcurrentDictionary<string,int> recoveryFailures = new(), recoveryIndex = new();
    private readonly ConcurrentDictionary<string,NetworkAdvertisement> networkHints = new();
    private readonly ConcurrentDictionary<string,string> networkAdvertised = new();
    private readonly ConcurrentDictionary<string,bool> networkAdvertising = new();
    private NetworkEndpoint[] LocalNetworkEndpoints() {
        try {
            return System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                .Where(n=>n.OperationalStatus==System.Net.NetworkInformation.OperationalStatus.Up)
                .OrderBy(n=>n.NetworkInterfaceType==System.Net.NetworkInformation.NetworkInterfaceType.Ppp?0:1)
                .SelectMany(n=>n.GetIPProperties().UnicastAddresses)
                .Where(a=>a.Address.AddressFamily==AddressFamily.InterNetwork)
                .Select(a=>new NetworkEndpoint(a.Address.ToString(),ListenPort)).Where(e=>e.Valid()).Distinct().Take(8).ToArray();
        } catch {return [];}
    }
    private async Task AdvertiseNetwork(string peer, bool force=false) {
        if(lifetime.IsCancellationRequested || !sessions.TryGetValue(peer,out var session) || !session.Info.Capabilities.Contains("network-endpoints-v1") || !networkAdvertising.TryAdd(peer,true))return;
        try {
            var value=new NetworkAdvertisement(NetworkAvailable,NetworkAvailable?LocalNetworkEndpoints():[]);
            var text=System.Text.Json.JsonSerializer.Serialize(value,networkJson);
            if(!force && networkAdvertised.GetValueOrDefault(peer)==text)return;
            session.Links.TryGetValue("ble",out var link);
            await SendFrame("data",peer,"network-endpoints",System.Text.Encoding.UTF8.GetBytes(text),link);
            networkAdvertised[peer]=text;
        } catch {log("NetworkAdvertisementFailed peerId="+peer);}
        finally {networkAdvertising.TryRemove(peer,out _);}
    }
    private void ReceiveNetworkAdvertisement(string peer, byte[] payload) {
        if(payload.Length>2048 || registry.Find(peer) is null || !sessions.TryGetValue(peer,out var session) || !session.Info.Capabilities.Contains("network-endpoints-v1"))return;
        NetworkAdvertisement? value;try{value=System.Text.Json.JsonSerializer.Deserialize<NetworkAdvertisement>(payload,networkJson);}catch{return;}
        if(value?.Endpoints is not {Length:<=8} endpoints || endpoints.Any(e=>e is null || !e.Valid()))return;
        networkHints.TryGetValue(peer,out var old);networkHints[peer]=value;
        if(old is null || old.Enabled!=value.Enabled || !old.Endpoints.SequenceEqual(endpoints)) {
            recoveryNext.TryRemove(peer,out _);recoveryFailures[peer]=0;recoveryIndex[peer]=0;
            log($"NetworkEndpointsUpdated peerId={peer} count={endpoints.Length} enabled={value.Enabled}");
        }
    }
    public async Task RecoverNetworkLinks(IReadOnlySet<string>? suppressed=null) {
        if(lifetime.IsCancellationRequested || !await recoveryGate.WaitAsync(0))return;
        try {
            foreach(var id in sessions.Keys)await AdvertiseNetwork(id);
            if(!NetworkAvailable || lifetime.IsCancellationRequested)return;
            foreach(var peer in registry.All()) {
                var id=peer.PeerID; sessions.TryGetValue(id,out var session); networkHints.TryGetValue(id,out var hints);
                if(suppressed?.Contains(id)==true || declinedConnections.ContainsKey(id) || session?.Links.ContainsKey("tcp")==true || ((peer.Trust != "trusted" || !peer.AutoConnect) && session is null) || (session is not null && hints?.Enabled==false))continue;
                var observed=session?.Info.LanHost is {} host ? new[]{new NetworkEndpoint(host,session.Info.ListenPort)} : Array.Empty<NetworkEndpoint>();
                var cached=peer.NetworkEndpoints??[];
                var endpoints=observed.Concat(cached.Take(1)).Concat(hints?.Endpoints??[]).Concat(cached.Skip(1)).Where(e=>e.Valid(allowLoopback:true)).Distinct().Take(8).ToArray();
                if(endpoints.Length==0)continue;
                if(!recoveryNext.ContainsKey(id) && string.CompareOrdinal(localId,id)>0){recoveryNext[id]=Environment.TickCount64+5000;continue;}
                if(recoveryNext.GetValueOrDefault(id)>Environment.TickCount64)continue;
                var index=recoveryIndex.GetValueOrDefault(id);var endpoint=endpoints[index%endpoints.Length];recoveryIndex[id]=index+1;
                recoveryNext[id]=Environment.TickCount64+30000;
                log($"NetworkRecoveryAttempt peerId={id} host={endpoint.Host} port={endpoint.Port}");
                try {
                    await ConnectAsync(endpoint.Host,endpoint.Port,null,null,autoOnly:true,expectedPeerId:id,handshakeTimeoutSeconds:4);
                    recoveryFailures[id]=0;log("NetworkRecoveryConnected peerId="+id);
                } catch(Exception error) {
                    var failures=Math.Min(5,recoveryFailures.GetValueOrDefault(id)+1);recoveryFailures[id]=failures;
                    var delay=Math.Min(30,1<<failures);recoveryNext[id]=Environment.TickCount64+delay*1000;
                    log($"NetworkRecoveryFailed peerId={id} retrySeconds={delay} error={error.GetType().Name} code={error.HResult}");
                }
                if(lifetime.IsCancellationRequested)return;
            }
        } finally {recoveryGate.Release();}
    }
    public volatile bool NetworkAvailable = true;
    public volatile bool BluetoothAvailable = true;
    public void UpdateCredentials(string code, string secret)
    {
        if (code.Length != 6 || code.Any(c => c is < '0' or > '9'))
            throw new ArgumentException("Use six digits for the pairing code.");
        lock (credentialsGate) { pairCode = code; password = secret; }
    }
    public void Start(int port = 49160)
    {
        ListenPort = port; listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        log("ListenerReady transport=tcp");
        _ = AcceptLoop(listener, "tcp");
    }
    public void StartBluetoothListener(int port = 49165)
    {
        if (bluetoothListener is not null) return;
        bluetoothListener = new TcpListener(IPAddress.Loopback, port); bluetoothListener.Start();
        _ = AcceptLoop(bluetoothListener, "ble");
    }
    private async Task AcceptLoop(TcpListener source, string kind)
    {
        try { while (!lifetime.IsCancellationRequested) {
            var client = await source.AcceptTcpClientAsync(lifetime.Token);
            client.NoDelay = true;
            _ = Accept(client, kind);
        } } catch (OperationCanceledException) { }
        catch (SocketException) when (lifetime.IsCancellationRequested) { }
    }
    private async Task Accept(TcpClient client, string kind)
    {
        SecureTcp? transport = null;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(60));
        try {
            transport = await SecureTcp.AcceptAsync(client, identity, peer => {
                var stored = registry.Find(peer.PeerID);
                return stored is null || stored.PublicKey == peer.PublicKey;
            }, timeout.Token, kind);
            await AcceptTransport(transport, kind, timeout.Token);
        } catch { if (transport is not null) await transport.DisposeAsync(); else client.Dispose(); log("ConnectionRejected"); }
    }
    private async Task AcceptTransport(ISessionTransport transport, string kind, CancellationToken cancellation)
    {
            if ((kind == "ble" ? !BluetoothAvailable : !NetworkAvailable)) throw new InvalidDataException("Incoming transport disabled.");
            var certificate = transport.RemoteCertificate;
            if (certificate.PeerID == localId) throw new InvalidDataException("Self connection.");
            lock(sessionsGate) pendingHandshakes[certificate.PeerID]=pendingHandshakes.GetValueOrDefault(certificate.PeerID)+1;
            try {
            var stored = registry.Find(certificate.PeerID);
            var hello = Message("hello", certificate.PeerID);
            hello.InstanceID=instanceID; hello.Name = name; hello.Platform = "windows"; hello.Capabilities = applicationCapabilities.Append(kind).ToArray(); hello.ListenPort = ListenPort;
            if (sessions.TryGetValue(certificate.PeerID, out var current)) hello.SessionID = current.Info.SessionID;
            hello.Mode = stored?.Trust == "trusted" ? "trusted" : stored is not null ? "known" : kind == "ble" ? "bluetooth" : "password";
            hello.PairCode=kind=="ble"?pairCode:null; // Device locator only; BLE still requires receiver approval.
            await transport.SendAsync(hello, cancellation);
            var request = await transport.ReceiveAsync(cancellation);
            Validate(request, certificate);
            if (request.Type != "pair" || request.Mode is not ("password" or "trusted" or "known" or "attach" or "group" or "bluetooth")) throw new InvalidDataException("Expected pairing.");
            if (request.Mode == "bluetooth" && kind != "ble" || (kind == "ble" ? !BluetoothAvailable : !NetworkAvailable))
                throw new InvalidDataException("Pairing mode does not match transport.");
            if(request.AutoConnection!=true) declinedConnections.TryRemove(certificate.PeerID,out _);
            bool accepted;
            if(request.Mode=="bluetooth") {
                bool correct;lock(credentialsGate){failedAttempts.RemoveAll(t=>DateTime.UtcNow-t>=TimeSpan.FromMinutes(1));correct=failedAttempts.Count<5&&(request.PairCode is null||EqualSecret(request.PairCode,pairCode))&&EqualSecret(request.Password,password);if(!correct)failedAttempts.Add(DateTime.UtcNow);}
                accepted=correct&&await ApproveConnection(certificate.PeerID,request.Name??certificate.PeerID,true);
            } else if (request.Mode == "group") {
                accepted = stored is not null && GroupAuthorized(request.GroupID, certificate.PeerID) && await ApproveConnection(certificate.PeerID,stored.Name,kind == "ble");
            } else if (request.Mode == "attach") {
                accepted = stored is not null && request.SessionID is not null && sessions.TryGetValue(certificate.PeerID, out var attached)
                    && attached.Info.SessionID == request.SessionID;
            } else if(request.Mode=="known") {
                accepted=stored?.PublicKey==certificate.PublicKey && await ApproveConnection(certificate.PeerID,stored.Name,kind == "ble");
            } else if (request.Mode == "trusted") {
                accepted = stored?.Trust == "trusted" && stored.PublicKey == certificate.PublicKey
                    && await ApproveConnection(certificate.PeerID,stored.Name,kind == "ble");
            } else {
                bool correct;
                lock (credentialsGate) {
                    failedAttempts.RemoveAll(t => DateTime.UtcNow - t >= TimeSpan.FromMinutes(1));
                    correct = failedAttempts.Count < 5 && EqualSecret(request.PairCode, pairCode) && EqualSecret(request.Password, password);
                    if (!correct) failedAttempts.Add(DateTime.UtcNow);
                }
                accepted = correct && (stored is not null || confirmCertificate(certificate));
                if(accepted) declinedConnections.TryRemove(certificate.PeerID,out _);
            }
            if (!accepted) {
                var rejected = Message("rejected", certificate.PeerID); rejected.Error = declinedConnections.ContainsKey(certificate.PeerID)?"connectionDeclined":"authenticationFailed";
                await transport.SendAsync(rejected, cancellation); log("PairingRejected");
                throw new InvalidDataException("Authentication failed.");
            }
            var id = request.Mode == "attach" ? request.SessionID! : sessions.TryGetValue(certificate.PeerID, out var liveSession)
                ? liveSession.Info.SessionID : pendingSessionIds.GetOrAdd(certificate.PeerID, _=>Guid.NewGuid().ToString("D"));
            var response = Message("accepted", certificate.PeerID); response.SessionID = id; response.Capabilities = [kind];
            await transport.SendAsync(response, cancellation);
            var ready = await transport.ReceiveAsync(cancellation);
            Validate(ready, certificate);
            if (ready.Type != "ready" || ready.SessionID != id) throw new InvalidDataException("Expected session acknowledgement.");
            registry.Remember(certificate, request.Name ?? certificate.PeerID);
            var info = new SessionInfo(id, certificate.PeerID, request.Name ?? certificate.PeerID,
                (request.Capabilities ?? []).Intersect(applicationCapabilities.Append(kind)).ToArray(), certificate.PeerID, ListenPort: request.ListenPort ?? 49160, RemotePlatform: request.Platform?.ToLowerInvariant() ?? "unknown");
            if (!Register(transport, info, request.Capabilities ?? [], publish: false, attaching: request.Mode=="attach", remoteInstance:request.InstanceID)) throw new IOException("Superseded Session.");
            try {
                var established = Message("established", certificate.PeerID); established.SessionID = id;
                await transport.SendAsync(established, cancellation);
                PublishSession(transport, sessions[certificate.PeerID].Info);
            } catch { RemoveTransport(transport, info); throw; }
            } finally { FinishHandshake(certificate.PeerID); }
    }
    public async Task<bool> StartQuicListener(int port = 49164)
    {
        if (!QuicListener.IsSupported) { log("QUICUnavailable"); return false; }
        if (quicListener is not null) return true;
        quicListener = await QuicListener.ListenAsync(new QuicListenerOptions {
            ListenEndPoint = new IPEndPoint(IPAddress.Any, port), ApplicationProtocols = [new SslApplicationProtocol(SecureQuic.Alpn)],
            ConnectionOptionsCallback = (_, _, _) => ValueTask.FromResult(new QuicServerConnectionOptions {
                DefaultCloseErrorCode = 0, DefaultStreamErrorCode = 0, MaxInboundBidirectionalStreams = 1, MaxInboundUnidirectionalStreams = 0,
                ServerAuthenticationOptions = new SslServerAuthenticationOptions {
                    ServerCertificate = identity.Certificate, ClientCertificateRequired = true,
                    ApplicationProtocols = [new SslApplicationProtocol(SecureQuic.Alpn)],
                    RemoteCertificateValidationCallback = (_, certificate, _, _) => SecureQuic.Verify(certificate, peer => {
                        var known = registry.Find(peer.PeerID); return known is null || known.PublicKey == peer.PublicKey;
                    }),
                    EnabledSslProtocols = SslProtocols.Tls13, AllowTlsResume = false,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                }
            })
        }, lifetime.Token);
        log("ListenerReady transport=quic"); _ = AcceptQuicLoop(); return true;
    }
    private async Task AcceptQuicLoop()
    {
        try {
            while (!lifetime.IsCancellationRequested) {
                var connection = await quicListener!.AcceptConnectionAsync(lifetime.Token);
                _ = AcceptQuic(connection);
            }
        } catch (Exception) when (lifetime.IsCancellationRequested) { }
        catch { log("QUICListenerFailed"); }
    }
    private async Task AcceptQuic(QuicConnection connection)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(60)); ISessionTransport? transport = null;
        try { transport = await SecureQuic.AcceptAsync(connection, timeout.Token); await AcceptTransport(transport, "quic", timeout.Token); }
        catch { if (transport is not null) await transport.DisposeAsync(); else await connection.DisposeAsync(); log("ConnectionRejected"); }
    }
    private readonly ConcurrentDictionary<string,Lazy<Task<bool>>> pendingApprovals = new();
    private async Task<bool> ApproveConnection(string peer,string peerName,bool bluetooth=false) {
        if(declinedConnections.ContainsKey(peer)) return false;
        if(sessions.ContainsKey(peer)) return true;
        var pending=pendingApprovals.GetOrAdd(peer, _=>new Lazy<Task<bool>>(()=>confirmPeerConnection is {} confirm
            ? confirm(peer,peerName,bluetooth) : Task.Run(()=>(bluetooth?confirmBluetoothConnection:confirmConnection)(peerName))));
        {
            var accepted=await pending.Value;
            if(!accepted) { declinedConnections.TryAdd(peer,true); log("SessionConnectionDeclined peerId="+peer); }
            return accepted;
        }
    }

    private void FinishHandshake(string peer) {
        lock(sessionsGate) {
            var count=pendingHandshakes.GetValueOrDefault(peer)-1;
            if(count>0) pendingHandshakes[peer]=count;
            else {pendingHandshakes.Remove(peer);pendingSessionIds.TryRemove(peer,out _);pendingApprovals.TryRemove(peer,out _);}
        }
    }

    public async Task<string> ConnectAsync(string host, int port, string? code, string? secret, bool autoOnly = false, string kind = "tcp", string? groupId = null, string? expectedPeerId = null, double? handshakeTimeoutSeconds = null, bool quickOnly = false)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(handshakeTimeoutSeconds ?? (kind == "quic" ? 5 : 60)));
        Func<CertificatePeer, bool> verify = peer => {
            if (expectedPeerId is not null && peer.PeerID != expectedPeerId) return false;
            var stored = registry.Find(peer.PeerID);
            return stored is not null ? stored.PublicKey == peer.PublicKey && (!autoOnly || sessions.ContainsKey(peer.PeerID) || GroupAuthorized(groupId, peer.PeerID) || stored.Trust == "trusted" && stored.AutoConnect) : !autoOnly;
        };
        ISessionTransport transport = kind == "quic"
            ? await SecureQuic.ConnectAsync(host, port, identity, verify, timeout.Token)
            : await SecureTcp.ConnectAsync(host, port, identity, verify, timeout.Token, kind);
        try {
            var certificate = transport.RemoteCertificate;
            if (certificate.PeerID == localId) throw new InvalidDataException("Self connection.");
            if (sessions.TryGetValue(certificate.PeerID, out var existing) && existing.Links.ContainsKey(kind)) { await transport.DisposeAsync(); return certificate.PeerID; }
            var hello = await transport.ReceiveAsync(timeout.Token);
            Validate(hello, certificate);
            if (hello.Type != "hello" || hello.Capabilities?.Contains(kind) != true) throw new InvalidDataException("Unexpected transport greeting.");
            if(quickOnly && (registry.Find(certificate.PeerID) is null || hello.Mode!="trusted"))throw new InvalidDataException("The other device has not granted Trusted access.");
            var attaching = registry.Find(certificate.PeerID) is not null && hello.SessionID is not null
                && sessions.TryGetValue(certificate.PeerID, out var attached) && attached.Info.SessionID == hello.SessionID;
            var groupJoining = registry.Find(certificate.PeerID) is not null && GroupAuthorized(groupId, certificate.PeerID);
            var known = registry.Find(certificate.PeerID) is not null && hello.Mode=="known" && code is null && secret is null;
            var trusted = registry.Find(certificate.PeerID) is not null && hello.Mode == "trusted" && code is null && secret is null;
            if (autoOnly && !trusted && !known && !attaching && !groupJoining) throw new InvalidDataException("Not mutually trusted.");
            if(kind=="ble" && !string.IsNullOrEmpty(code) && hello.PairCode!=code) throw new InvalidDataException("Pairing code does not match BLE peer.");
            if(!autoOnly) declinedConnections.TryRemove(certificate.PeerID,out _);
            else if(declinedConnections.ContainsKey(certificate.PeerID)) throw new InvalidDataException("Automatic connection declined.");
            if (kind != "ble" && registry.Find(certificate.PeerID) is null && !confirmCertificate(certificate))
                throw new InvalidDataException("Peer certificate rejected.");
            var request = Message("pair", certificate.PeerID);
            request.Mode = attaching ? "attach" : groupJoining ? "group" : trusted ? "trusted" : known ? "known" : kind=="ble" ? "bluetooth" : "password";
            request.AutoConnection=autoOnly;
            request.SessionID = attaching ? hello.SessionID : null;
            request.GroupID = groupJoining ? groupId : null; request.ListenPort = ListenPort;
            request.PairCode = trusted || known || attaching || groupJoining ? null : code; request.Password = trusted || known || attaching || groupJoining ? null : secret;
            request.InstanceID=instanceID; request.Name = name; request.Platform = "windows"; request.Capabilities = applicationCapabilities.Append(kind).ToArray();
            await transport.SendAsync(request, timeout.Token);
            var response = await transport.ReceiveAsync(timeout.Token);
            Validate(response, certificate);
            if (response.Type != "accepted" || !Guid.TryParse(response.SessionID, out _)) {
                if(autoOnly && response.Error=="connectionDeclined") declinedConnections.TryAdd(certificate.PeerID,true);
                throw new InvalidDataException("Authentication failed.");
            }
            var ready = Message("ready", certificate.PeerID); ready.SessionID = response.SessionID;
            await transport.SendAsync(ready, timeout.Token);
            var established = await transport.ReceiveAsync(timeout.Token); Validate(established, certificate);
            if (established.Type != "established" || established.SessionID != response.SessionID) throw new InvalidDataException("Session was not committed.");
            registry.Remember(certificate, hello.Name ?? certificate.PeerID);
            Register(transport, new(response.SessionID!, certificate.PeerID, hello.Name ?? certificate.PeerID,
                (hello.Capabilities ?? []).Intersect(applicationCapabilities.Append(kind)).ToArray(), localId, ListenPort: hello.ListenPort ?? 49160, RemotePlatform: hello.Platform?.ToLowerInvariant() ?? "unknown"), hello.Capabilities ?? [], attaching: attaching, remoteInstance:hello.InstanceID);
            return certificate.PeerID;
        } catch { await transport.DisposeAsync(); throw; }
    }
    private static bool EqualSecret(string? supplied, string expected) => CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(supplied ?? ""), Encoding.UTF8.GetBytes(expected));
    private SessionMessage Message(string type, string target) => new() { Type = type, SourcePeerID = localId, TargetPeerID = target };
    private void Validate(SessionMessage message, CertificatePeer certificate)
    {
        if(message.InstanceID is not null && !Guid.TryParse(message.InstanceID,out _)) throw new InvalidDataException("Invalid process instance.");
        if (message.Version != 2 || message.SourcePeerID != certificate.PeerID || message.TargetPeerID != localId)
            throw new InvalidDataException("Incompatible or misrouted message.");
    }
    private bool Register(ISessionTransport transport, SessionInfo info, string[] remoteCaps, bool publish = true, bool attaching = false, string? remoteInstance=null)
    {
        info = info with { LanHost = transport.RemoteHost, LocalHost = transport.LocalHost, RemoteInstanceID=remoteInstance };
        lock (sessionsGate) {
            var restarted=remoteInstance is not null && remoteInstances.TryGetValue(info.PeerID,out var oldInstance) && oldInstance!=remoteInstance;
            // Hello was produced before the attach handshake finished; retain the
            // newest ordered snapshot unless this is a new process/session.
            var sameSession=!restarted && sessions.TryGetValue(info.PeerID,out var current) && current.Info.SessionID==info.SessionID;
            if (sessions.TryGetValue(info.PeerID, out var existing)) {
                if(!restarted && remoteInstance is not null && remoteInstances.GetValueOrDefault(info.PeerID)==remoteInstance && existing.Links.TryGetValue(transport.Kind,out var liveLink) && linkInitiators.TryGetValue(liveLink,out var liveOrigin) && (attaching||string.CompareOrdinal(liveOrigin,info.InitiatorPeerID)<=0)) {
                    log($"SessionDuplicateLinkIgnored peerId={info.PeerID} transport={transport.Kind}");_=transport.DisposeAsync();return false;
                }
                if(restarted){log($"SessionPeerRestarted peerId={info.PeerID}");foreach(var old in existing.Links.Values)_=old.DisposeAsync();existing.Links.Clear();}
                if (existing.Info.SessionID == info.SessionID) {
                    if (!attaching && !restarted && existing.Links.TryGetValue(transport.Kind,out var live)
                        && linkInitiators.TryGetValue(live,out var origin) && string.CompareOrdinal(origin,info.InitiatorPeerID)<=0) {
                        log($"SessionDuplicateLinkIgnored peerId={info.PeerID} transport={transport.Kind}");
                        _=transport.DisposeAsync(); return false;
                    }
                    if (existing.Links.TryGetValue(transport.Kind, out var prior)) _ = prior.DisposeAsync();
                    existing.Links[transport.Kind] = transport;
                    existing.Info = existing.Info with { RemoteInstanceID=remoteInstance, Capabilities = remoteCaps.Intersect(applicationCapabilities).Concat(existing.Links.Keys).Distinct().ToArray(), LanHost = info.LanHost ?? existing.Info.LanHost, LocalHost = info.LocalHost ?? existing.Info.LocalHost };
                } else {
                    if (!restarted && string.CompareOrdinal(existing.Info.InitiatorPeerID, info.InitiatorPeerID) < 0) { _ = transport.DisposeAsync(); return false; }
                    foreach (var prior in existing.Links.Values) _ = prior.DisposeAsync();
                    sessions[info.PeerID] = new(transport, info);
                }
            } else sessions[info.PeerID] = new(transport, info);
            if(remoteInstance is not null)remoteInstances[info.PeerID]=remoteInstance;else remoteInstances.Remove(info.PeerID);
            if(!sameSession){fileFeedback.TryRemove(info.PeerID,out _);remoteCapabilitySequences.Remove(info.PeerID);bulkNetworkDeadline[info.PeerID]=Environment.TickCount64+5000;}
            else if(remoteCapabilitySequences.ContainsKey(info.PeerID))remoteCaps=remoteCapabilities.GetValueOrDefault(info.PeerID,remoteCaps);
            remoteCapabilities[info.PeerID]=remoteCaps;
            sessions[info.PeerID].Info=sessions[info.PeerID].Info with {Capabilities=remoteCaps.Intersect(applicationCapabilities).Concat(sessions[info.PeerID].Links.Keys).Distinct().ToArray()};
            if(routePolicies.TryGetValue(info.PeerID,out var policy))lock(policy)policy.ResetPreference();
            linkInitiators[transport] = info.InitiatorPeerID;
        }
        lastReceived[transport] = Environment.TickCount64;
        if (publish) PublishSession(transport, sessions[info.PeerID].Info);
        return true;
    }
    private void PublishSession(ISessionTransport transport, SessionInfo info)
    {
        if (transport.Kind == "tcp" && transport.RemoteHost is {} host) {
            registry.RememberNetworkEndpoint(info.PeerID, new NetworkEndpoint(host, info.ListenPort));
            recoveryFailures[info.PeerID]=0; recoveryIndex[info.PeerID]=0; recoveryNext.TryRemove(info.PeerID,out _);
        }
        log($"SessionEstablished peerId={info.PeerID} sessionId={info.SessionID} transport={transport.Kind} tls=1.3");
        log($"SessionTopology peerId={info.PeerID} links={string.Join(',',sessions[info.PeerID].Links.Keys.Order())}");
        Changed?.Invoke(CurrentSessions());
        // High-rate network framing must not compete with the desktop dispatcher and input hooks.
        _ = Task.Run(() => ReadSession(transport, info)); _ = Task.Run(() => Heartbeat(transport, info));
        // The attach handshake may have captured capabilities before input enabled.
        _ = Task.Run(async () => {
            try { await AdvertiseNetwork(info.PeerID, force:true); await SendFrame("data",info.PeerID,"capabilities",System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(applicationCapabilities),transport); }
            catch { }
        });
    }
    private async Task ReadSession(ISessionTransport transport, SessionInfo info)
    {
        ulong received = 0;
        var assemblies=new Dictionary<Guid,BulkFrameCodec.Assembly>();
        try { while (true) {
            var request = await transport.ReceiveAsync(lifetime.Token);
            var negotiated=sessions.TryGetValue(info.PeerID,out var bound)?bound.Info.Capabilities:Array.Empty<string>();
            if(request.Type=="compact-input-v3"&&!negotiated.Contains("compact-input-v3")||request.Type=="compact-diagnostics"&&!negotiated.Contains("compact-diagnostics-v1")||request.Type=="compact-data"&&!negotiated.Contains("compact-data-v1"))throw new InvalidDataException("Compact frame capability not negotiated.");
            if(request.Type is "compact-input-v3" or "compact-diagnostics" or "compact-data")request.SessionID=info.SessionID;
            if (request.Type is "compact-input" or "compact-input-v3" or "compact-diagnostics" or "compact-data") { request.Type="data"; request.SourcePeerID=info.PeerID; request.TargetPeerID=localId; }
            if (!sessions.TryGetValue(info.PeerID, out var active) || active.Info.SessionID != info.SessionID
                || !active.Links.TryGetValue(transport.Kind,out var live) || !ReferenceEquals(live,transport)
                || request.Version != 2 || request.SourcePeerID != info.PeerID || request.TargetPeerID != localId
                || request.SessionID != info.SessionID || request.Sequence <= received) {
                log($"SessionFrameRejected transport={transport.Kind} sequence={request.Sequence} previous={received}");
                throw new InvalidDataException("Invalid session frame.");
            }
            if(transport.Kind=="ble" && request.Type is "ping" or "pong") log("BLEHeartbeatReceived type="+request.Type);
            received = request.Sequence;
            RecordTraffic(transport.Kind,request.Channel??request.Type,request.Payload,false);
            lastReceived[transport] = Environment.TickCount64;
            if (request.Type == "ping") {
                await SendFrame("pong", info.PeerID, transport: transport);
            } else if(request.Type=="pong"){
                if(heartbeatSent.TryRemove(transport,out var began)){var policy=routePolicies.GetOrAdd(info.PeerID,_=>new());lock(policy)policy.Observe(transport.Kind,System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalMilliseconds,Environment.TickCount64/1000.0);}
            } else if (request.Type == "data" && request.Channel is { Length: > 0 and <= 32 } channel
                && request.Payload is { Length: <= 32768 } payload) {
                if(channel is "input" or "diagnostics" or "throughput")inputActivity[info.PeerID]=Environment.TickCount64;
                if(request.DeliveryID is {} tokenValue&&(!Guid.TryParse(tokenValue,out _)||!active.Info.Capabilities.Contains("background-flow-v1")))throw new InvalidDataException("Unnegotiated delivery acknowledgement.");
                if(channel=="background-ack") {
                    var token=System.Text.Encoding.UTF8.GetString(payload);if(deliveryWaiters.TryGetValue(token,out var pending)&&pending.Peer==info.PeerID&&ReferenceEquals(pending.Link,transport))pending.Completion.TrySetResult();
                } else if(channel=="bulk-window") {
                    if(!active.Info.Capabilities.Contains("adaptive-file-window-v1")||payload.Length!=1||payload[0] is <1 or >8)throw new InvalidDataException("Invalid file window feedback.");
                    var feedback=fileFeedback.GetOrAdd(info.PeerID,_=>new());lock(feedback)feedback.Policy.RemoteLimit(payload[0],request.Sequence,Environment.TickCount64/1000.0);
                } else if(channel=="bulk") {
                    if(request.DeliveryID is null||!active.Info.Capabilities.Contains("bulk-fragments-v1"))throw new InvalidDataException("Unnegotiated bulk fragments.");
                    if(BulkFrameCodec.Consume(payload,assemblies) is {} complete&&receivers.TryGetValue(complete.Channel,out var handler))await handler(info.PeerID,complete.Payload,transport);
                } else if(channel=="throughput") {if(request.DeliveryID is null||!active.Info.Capabilities.Contains("throughput-test-v1"))throw new InvalidDataException("Unnegotiated speed test.");}
                else if(channel=="diagnostics") {
                    LatencyProbe? probe=null; try { probe=System.Text.Json.JsonSerializer.Deserialize<LatencyProbe>(payload,new System.Text.Json.JsonSerializerOptions {PropertyNameCaseInsensitive=true}); } catch { }
                    if(probe?.Token.Length<=80) {
                        if(probe.Type=="probe") await SendFrame("data",info.PeerID,"diagnostics",System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new LatencyProbe("reply",probe.Token),new System.Text.Json.JsonSerializerOptions {PropertyNamingPolicy=System.Text.Json.JsonNamingPolicy.CamelCase}),transport);
                        else if(probe.Type=="reply" && probeTimes.TryGetValue(probe.Token,out var sample) && sample.Peer==info.PeerID && sample.Kind==transport.Kind && probeTimes.TryRemove(probe.Token,out _)) sample.Received(System.Diagnostics.Stopwatch.GetElapsedTime(sample.Start).TotalMilliseconds);
                    }
                } else if(channel=="network-endpoints") ReceiveNetworkAdvertisement(info.PeerID,payload);
                else if(channel=="capabilities")ApplyRemoteCapabilities(info.PeerID,request.Sequence,payload,transport);
                else if (receivers.TryGetValue(channel, out var receiver)) await receiver(info.PeerID, payload,transport);
                if(request.DeliveryID is {} delivery)await SendFrame("data",info.PeerID,"background-ack",System.Text.Encoding.UTF8.GetBytes(delivery),transport);
            } else if (request.Type != "pong") throw new InvalidDataException("Unknown session frame.");
        } } catch (Exception error) {
            log($"SessionLinkClosed transport={transport.Kind} error={error.GetType().Name}");
            if(transport.Kind=="ble") log($"BLESessionFailure code={error.HResult} inner={error.InnerException?.GetType().Name} innerCode={error.InnerException?.HResult} detail={error.Message} innerDetail={error.InnerException?.Message}");
            await transport.DisposeAsync();
            RemoveTransport(transport, info);
        }
    }
    private void RemoveTransport(ISessionTransport transport, SessionInfo info)
    {
        foreach(var p in deliveryWaiters.Values.Where(p=>p.Peer==info.PeerID&&ReferenceEquals(p.Link,transport)))p.Completion.TrySetException(new IOException("Link closed."));
        lastReceived.TryRemove(transport, out _);heartbeatSent.TryRemove(transport,out _);
        linkInitiators.TryRemove(transport, out _);
            lock (sessionsGate) {
                if (sessions.TryGetValue(info.PeerID, out var current) && current.Links.TryGetValue(transport.Kind, out var activeLink)
                    && ReferenceEquals(activeLink, transport)) {
                    current.Links.TryRemove(transport.Kind, out _);
                    if (current.Links.IsEmpty) {fileFeedback.TryRemove(info.PeerID,out _);routePolicies.TryRemove(info.PeerID,out _); sessions.TryRemove(info.PeerID, out _); recoveryIndex[info.PeerID]=0; recoveryNext.TryRemove(info.PeerID,out _); remoteInstances.Remove(info.PeerID); remoteCapabilities.TryRemove(info.PeerID, out _); remoteCapabilitySequences.Remove(info.PeerID); bulkNetworkDeadline.TryRemove(info.PeerID,out _); log($"SessionClosed peerId={info.PeerID}"); }
                    else {
                        if(transport.Kind!="ble" && !current.Links.ContainsKey("tcp") && !current.Links.ContainsKey("quic"))bulkNetworkDeadline[info.PeerID]=Environment.TickCount64+5000;
                        current.Info = current.Info with { Capabilities = current.Info.Capabilities.Except(new[] { "tcp", "quic", "ble" }).Concat(current.Links.Keys).ToArray() };
                    }
                    Changed?.Invoke(CurrentSessions());
                }
            }
    }

    public void Receive(string channel, Func<string, byte[], Task> handler) => receivers[channel] = (peer,bytes,_)=>handler(peer,bytes);
    public void ReceiveWithTransport(string channel,Func<string,byte[],ISessionTransport,Task> handler)=>receivers[channel]=handler;
    public async Task SendOnTransportAsync(string peer,string channel,byte[] payload,ISessionTransport transport) {
        if(channel.Length is <1 or >32||payload.Length>32768)throw new InvalidDataException("Invalid payload boundary.");
        if(!sessions.TryGetValue(peer,out var s)||!s.Links.TryGetValue(transport.Kind,out var current)||!ReferenceEquals(current,transport))throw new IOException("Transport replaced.");
        await SendFrame("data",peer,channel,payload,transport).ConfigureAwait(false);
    }
    private sealed record DeliveryWaiter(string Peer,ISessionTransport Link,TaskCompletionSource Completion);
    private readonly ConcurrentDictionary<string,DeliveryWaiter> deliveryWaiters=new();
    private sealed class FileFeedback {
        public readonly FileWindowPolicy Policy=new();
        public readonly SortedDictionary<ulong,(double At,ISessionTransport Link)> Sent=new();
        public double HintAt=double.NegativeInfinity;
        public int HintCount;
    }
    private readonly ConcurrentDictionary<string,FileFeedback> fileFeedback=new();
    public async Task SendInputAsync(string peer,byte[] payload,ulong? acknowledgedSequence) {
        if(payload.Length>32768)throw new InvalidDataException("Invalid input boundary.");
        await SendFrame("data",peer,"input",payload,inputSequence:acknowledgedSequence).ConfigureAwait(false);
    }
    public void InputReceived(string peer,ISessionTransport transport) {
        if(!sessions.TryGetValue(peer,out var s)||!s.Links.TryGetValue(transport.Kind,out var live)||!ReferenceEquals(live,transport))return;
        var feedback=fileFeedback.GetOrAdd(peer,_=>new());lock(feedback)feedback.Policy.MarkInput(Environment.TickCount64/1000.0);
        PublishFileWindow(peer);
    }
    public void InputAcknowledged(string peer,ulong sequence,ISessionTransport transport) {
        if(!sessions.TryGetValue(peer,out var s)||!s.Links.TryGetValue(transport.Kind,out var live)||!ReferenceEquals(live,transport)||!fileFeedback.TryGetValue(peer,out var feedback))return;
        lock(feedback) {
            var completed=feedback.Sent.Where(p=>p.Key<=sequence).ToArray();
            foreach(var sample in completed)feedback.Sent.Remove(sample.Key);
            var matching=completed.Where(p=>ReferenceEquals(p.Value.Link,transport)).ToArray();
            if(matching.Length==0)return;
            var now=Environment.TickCount64/1000.0;
            feedback.Policy.Observe(transport.Kind,(now-matching.Min(p=>p.Value.At))*1000,now);
        }
        PublishFileWindow(peer);
    }
    private void PublishFileWindow(string peer) {
        if(!sessions.TryGetValue(peer,out var s)||!s.Info.Capabilities.Contains("adaptive-file-window-v1"))return;
        var link=s.Links.GetValueOrDefault("quic")??s.Links.GetValueOrDefault("tcp");if(link is null)return;
        var feedback=fileFeedback.GetOrAdd(peer,_=>new());int count;
        lock(feedback) {
            var now=Environment.TickCount64/1000.0;count=feedback.Policy.LocalWindow(now);
            if(now-feedback.HintAt<(count==feedback.HintCount?1:.5))return;
            feedback.HintAt=now;feedback.HintCount=count;
        }
        log($"FileWindowFeedback peerId={peer} count={count}");
        _=SendFileWindow(peer,count,link);
    }
    private async Task SendFileWindow(string peer,int count,ISessionTransport link) {try{await SendOnTransportAsync(peer,"bulk-window",[(byte)count],link).ConfigureAwait(false);}catch{}}
    private readonly ConcurrentDictionary<string,SemaphoreSlim> backgroundGates=new();
    private readonly ConcurrentDictionary<string,long> inputActivity=new();
    private readonly ConcurrentDictionary<string,byte> speedTests=new();
    public int BackgroundPayloadLimit(string peer)=>sessions.TryGetValue(peer,out var s)&&(s.Links.ContainsKey("tcp")||s.Links.ContainsKey("quic"))?20000:128;
    public bool HasCapability(string peer,string capability)=>sessions.TryGetValue(peer,out var s)&&s.Info.Capabilities.Contains(capability);
    public (int Bytes,int Count) FileTransferWindow(string peer) {
        var compact=HasCapability(peer,"compact-file-v1")&&HasCapability(peer,"compact-data-v1");
        var active=Environment.TickCount64-inputActivity.GetValueOrDefault(peer)<300;
        if(!sessions.TryGetValue(peer,out var s)||(!s.Links.ContainsKey("tcp")&&!s.Links.ContainsKey("quic")))return(compact?256:512,1);
        if(!s.Info.Capabilities.Contains("adaptive-file-window-v1"))return(compact?32000:20000,active?2:8);
        var feedback=fileFeedback.GetOrAdd(peer,_=>new());int count;lock(feedback)count=feedback.Policy.Window(Environment.TickCount64/1000.0);
        PublishFileWindow(peer);return(compact?32000:20000,count);
    }
    private async Task SendAcknowledged(string peer,string channel,byte[] payload,ISessionTransport link) {
        if(payload.Length>32768||!sessions.TryGetValue(peer,out var s)||!s.Info.Capabilities.Contains("background-flow-v1"))throw new IOException("Receiver update required.");
        var token=Guid.NewGuid().ToString("D");var done=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        deliveryWaiters[token]=new(peer,link,done);
        try {await SendFrame("data",peer,channel,payload,link,token);await done.Task.WaitAsync(TimeSpan.FromSeconds(6),lifetime.Token);}finally{deliveryWaiters.TryRemove(token,out _);}
    }
    public async Task SendBackgroundAsync(string peer,string channel,byte[] payload) {
        var gate=backgroundGates.GetOrAdd(peer,_=>new(1,1));
        while(true){
            if(!sessions.TryGetValue(peer,out var s))throw new IOException("Peer disconnected.");
            if(s.Links.ContainsKey("tcp")||s.Links.ContainsKey("quic")){await SendAsync(peer,channel,payload);return;}
            if(!s.Links.TryGetValue("ble",out var link))throw new IOException("Peer disconnected.");
            if(payload.Length>2048)throw new IOException("Background payload needs to be re-chunked for this route.");
            if(Environment.TickCount64-inputActivity.GetValueOrDefault(peer)<150){await Task.Delay(30,lifetime.Token);continue;}
            await gate.WaitAsync(lifetime.Token).ConfigureAwait(false);
            try {if(Environment.TickCount64-inputActivity.GetValueOrDefault(peer)<150)continue;await SendAcknowledged(peer,channel,payload,link);return;}
            finally{gate.Release();}
        }
    }
    private readonly ConcurrentDictionary<string,long> bulkServiceAt=new();
    private readonly ConcurrentDictionary<string,long> bulkYieldUntil=new();
    public void YieldBulkForInput(string peer) {
        bulkYieldUntil[peer]=Environment.TickCount64+250;
        var feedback=fileFeedback.GetOrAdd(peer,_=>new());lock(feedback)feedback.Policy.Congested(Environment.TickCount64/1000.0);
        PublishFileWindow(peer);
    }
    public async Task<string> SendBulkTrackedAsync(string peer,string channel,byte[] payload) {
        if(channel is not("files" or "history" or "clipboard" or "computer")||payload.Length>32768)throw new InvalidDataException("Invalid bulk data.");
        if(sessions.TryGetValue(peer,out var connected)&&(connected.Links.ContainsKey("tcp")||connected.Links.ContainsKey("quic")))return await SendTrackedAsync(peer,channel,payload).ConfigureAwait(false);
        var gate=backgroundGates.GetOrAdd(peer,_=>new(1,1));await gate.WaitAsync(lifetime.Token).ConfigureAwait(false);
        try {
            if(!sessions.TryGetValue(peer,out var s))throw new IOException("Peer disconnected.");
            if(s.Links.ContainsKey("tcp")||s.Links.ContainsKey("quic"))return await SendTrackedAsync(peer,channel,payload).ConfigureAwait(false);
            if(!s.Links.TryGetValue("ble",out var link))throw new IOException("Peer disconnected.");
            var fragments=HasCapability(peer,"bulk-fragments-v1");var active=Environment.TickCount64-inputActivity.GetValueOrDefault(peer)<150;var packets=fragments?BulkFrameCodec.Fragments(channel,payload,active?160:384):new[]{payload};
            foreach(var packet in packets) {
                while(Environment.TickCount64-inputActivity.GetValueOrDefault(peer)<150&&(Environment.TickCount64-bulkServiceAt.GetValueOrDefault(peer)<100||Environment.TickCount64<bulkYieldUntil.GetValueOrDefault(peer)))await Task.Delay(5,lifetime.Token).ConfigureAwait(false);
                if(!s.Links.TryGetValue("ble",out var live)||!ReferenceEquals(live,link))throw new IOException("Peer disconnected.");
                bulkServiceAt[peer]=Environment.TickCount64;
                if(HasCapability(peer,"background-flow-v1"))await SendAcknowledged(peer,fragments?"bulk":channel,packet,link).ConfigureAwait(false);
                else await SendFrame("data",peer,channel,packet,link).ConfigureAwait(false);
            }
            return "ble";
        }finally{gate.Release();}
    }
    public async Task<LinkThroughput[]> TestThroughputAsync(string peer) {
        if(!sessions.TryGetValue(peer,out var s)||!s.Info.Capabilities.Contains("throughput-test-v1"))throw new IOException("Connect the updated receiver first.");
        if(!speedTests.TryAdd(peer,0))throw new IOException("Test already running.");
        try {var selected=new List<ISessionTransport>();if(s.Links.TryGetValue("tcp",out var tcp))selected.Add(tcp);if(s.Links.TryGetValue("quic",out var quic))selected.Add(quic);if(s.Links.TryGetValue("ble",out var ble))selected.Add(ble);
            return (await Task.WhenAll(selected.Select(link=>MeasureThroughput(peer,link)))).OrderBy(r=>r.Kind).ToArray();
        }finally{speedTests.TryRemove(peer,out _);}
    }
    private async Task<LinkThroughput> MeasureThroughput(string peer,ISessionTransport link) {
        var began=System.Diagnostics.Stopwatch.GetTimestamp();var size=link.Kind=="ble"?512:24000;var window=link.Kind=="ble"?2:8;var limit=link.Kind=="ble"?65536:33554432;long confirmed=0;string? failure=null;var data=Enumerable.Repeat((byte)0xa5,size).ToArray();
        while(System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalSeconds<4&&confirmed<limit){
            var results=await Task.WhenAll(Enumerable.Range(0,window).Select(async _=>{try{await SendAcknowledged(peer,"throughput",data,link);return true;}catch{return false;}}));
            confirmed+=results.Count(r=>r)*size;if(results.Any(r=>!r)){failure="确认超时或链路中断";break;}
        }
        return new(link.Kind,confirmed,System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalSeconds,failure);
    }
    public async Task<LinkLatency[]> TestLatencyAsync(string peerId) {
        if(!sessions.TryGetValue(peerId,out var session)) throw new IOException("Peer disconnected.");
        var links=session.Links.ToArray(); var run=Guid.NewGuid().ToString("D");var pendingTokens=new List<string>(); var start=System.Diagnostics.Stopwatch.GetTimestamp();
        var values=links.ToDictionary(p=>p.Key,_=>new List<LatencySample>()); var gate=new object();
        var json=new System.Text.Json.JsonSerializerOptions {PropertyNamingPolicy=System.Text.Json.JsonNamingPolicy.CamelCase};
        try {
            await Task.WhenAll(links.Select(async entry=>{
                var kind=entry.Key;var link=entry.Value;
                for(var index=0;index<200;index++){
                    var seconds=System.Diagnostics.Stopwatch.GetElapsedTime(start).TotalSeconds;if(seconds>=10)break;
                    int slot;lock(gate){slot=values[kind].Count;values[kind].Add(new(slot,seconds,null));}
                    var token=Guid.NewGuid().ToString("D");lock(pendingTokens)pendingTokens.Add(token);
                    var began=System.Diagnostics.Stopwatch.GetTimestamp();
                    probeTimes[token]=new(peerId,kind,began,rtt=>{lock(gate)values[kind][slot]=values[kind][slot] with{Milliseconds=rtt};});
                    try{await SendFrame("data",peerId,"diagnostics",System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new LatencyProbe("probe",token),json),link).ConfigureAwait(false);}catch{}
                    var wait=TimeSpan.FromMilliseconds(50)-System.Diagnostics.Stopwatch.GetElapsedTime(began);if(wait>TimeSpan.Zero)await Task.Delay(wait,lifetime.Token).ConfigureAwait(false);
                }
            })).ConfigureAwait(false);
            var drain=System.Diagnostics.Stopwatch.GetTimestamp();
            while(System.Diagnostics.Stopwatch.GetElapsedTime(drain).TotalSeconds<1&&pendingTokens.Any(probeTimes.ContainsKey))await Task.Delay(10,lifetime.Token).ConfigureAwait(false);
            lock(gate) return values.OrderBy(p=>p.Key).Select(p=>new LinkLatency(p.Key,p.Value.ToArray())).ToArray();
        } finally { foreach(var token in pendingTokens) probeTimes.TryRemove(token,out _); }
    }
    public Task SendAsync(string peerId, string channel, byte[] payload)=>SendTrackedAsync(peerId,channel,payload);
    public async Task<string> SendTrackedAsync(string peerId, string channel, byte[] payload)
    {
        if (channel.Length is < 1 or > 32 || payload.Length > 32768) throw new InvalidDataException("Invalid payload boundary.");
        if((channel=="history" || payload.Length>2048 && (channel is "clipboard" or "files" or "computer"))
            && NetworkAvailable && bulkNetworkDeadline.TryGetValue(peerId,out var deadline) && sessions.TryGetValue(peerId,out var initial)) {
            var began=Environment.TickCount64;var session=initial.Info.SessionID;
            while(NetworkAvailable && sessions.TryGetValue(peerId,out var current) && current.Info.SessionID==session
                && current.Links.ContainsKey("ble") && !current.Links.ContainsKey("tcp") && !current.Links.ContainsKey("quic") && Environment.TickCount64<deadline)
                await Task.Delay(50,lifetime.Token).ConfigureAwait(false);
            var elapsed=Environment.TickCount64-began;
            if(elapsed>=50)log($"BulkRouteWait channel={channel} waitMs={elapsed} networkReady={sessions.TryGetValue(peerId,out var ready) && (ready.Links.ContainsKey("tcp")||ready.Links.ContainsKey("quic"))}");
        }
        return await SendFrame("data", peerId, channel, payload).ConfigureAwait(false);
    }
    private async Task<string> SendFrame(string type, string peerId, string? channel = null, byte[]? payload = null, ISessionTransport? transport = null, string? deliveryID = null,ulong? inputSequence=null)
    {
        if (!sessions.TryGetValue(peerId, out var item)) throw new IOException("Peer disconnected.");
        using var deadline = channel == "input" ? CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token) : null;
        deadline?.CancelAfter(TimeSpan.FromSeconds(3));
        var cancellation = deadline?.Token ?? lifetime.Token;
        var preferred = channel == "input" ? "quic" : "tcp";
        string? route=null;
        if(channel=="input"){var policy=routePolicies.GetOrAdd(peerId,_=>new());lock(policy)route=policy.Choose(item.Links.Keys,BluetoothInputOnly,Environment.TickCount64/1000.0);}
        var link=transport??(route is not null?item.Links.GetValueOrDefault(route):item.Links.GetValueOrDefault(preferred))??item.Links.GetValueOrDefault("tcp")??item.Links.GetValueOrDefault("quic")??item.Links.GetValueOrDefault("ble")??throw new IOException("Peer disconnected.");
        // Serialize sequence allocation and submission per stream, so idle BLE cannot stall LAN input.
        var sendGate=item.SendGates.GetOrAdd(link.Kind,_=>new SemaphoreSlim(1,1));
        await sendGate.WaitAsync(cancellation);
        try {
            if(!sessions.TryGetValue(peerId,out var active)||!ReferenceEquals(active,item)||!active.Links.TryGetValue(link.Kind,out var live)||!ReferenceEquals(live,link))throw new IOException("Transport replaced before submission.");
            var frame = Message(type, peerId);
            frame.SessionID = item.Info.SessionID; frame.DeliveryID=deliveryID; lock(item) frame.Sequence = ++item.Sent;
            if(channel is "input" or "diagnostics" or "throughput")inputActivity[peerId]=Environment.TickCount64;
            if(channel=="diagnostics"&&item.Info.Capabilities.Contains("compact-diagnostics-v1"))frame.Mode="compact-diagnostics-v1";
            else if(type=="data"&&channel != "capabilities"&&item.Info.Capabilities.Contains("compact-data-v1"))frame.Mode="compact-data-v1";
            frame.Channel = channel; frame.Payload = channel=="capabilities" ? System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(applicationCapabilities) : payload;
            RecordTraffic(link.Kind,channel??type,frame.Payload,true);
            if(inputSequence is {} tracked) {
                var feedback=fileFeedback.GetOrAdd(peerId,_=>new());lock(feedback) {
                    var now=Environment.TickCount64/1000.0;
                    if(feedback.Sent.Count>=64)feedback.Sent.Remove(feedback.Sent.First().Key);
                    feedback.Sent[tracked]=(now,link);feedback.Policy.MarkInput(now);
                }
            }
            try { await link.SendAsync(frame, cancellation); }
            catch (OperationCanceledException) when (deadline?.IsCancellationRequested == true && !lifetime.IsCancellationRequested) {
                log("InputWriteTimedOut transport=" + link.Kind);
                _ = link.DisposeAsync(); throw;
            }
        } finally { sendGate.Release(); }
        return link.Kind;
    }
    private void RecordTraffic(string kind,string channel,byte[]? payload,bool sent) {
        var category=channel=="input"?(payload is not null && MotionCodec.IsCompact(payload)?"input-compact":"input-json"):channel;
        var key=$"transport={kind} channel={category}";
        string[] lines;
        lock(trafficGate) {
            var value=traffic.GetValueOrDefault(key);
            if(sent){value.Sent++;value.SentBytes+=payload?.Length??0;}else{value.Received++;value.ReceivedBytes+=payload?.Length??0;}
            traffic[key]=value;var now=Environment.TickCount64;
            if(now-trafficReportAt<5000)return;
            var interval=now-trafficReportAt;trafficReportAt=now;
            lines=traffic.OrderBy(p=>p.Key).Select(p=>$"SessionTraffic {p.Key} intervalMs={interval} txFrames={p.Value.Sent} txPayloadBytes={p.Value.SentBytes} rxFrames={p.Value.Received} rxPayloadBytes={p.Value.ReceivedBytes}").ToArray();traffic.Clear();
        }
        foreach(var line in lines)log(line);
    }
    private async Task Heartbeat(ISessionTransport transport, SessionInfo info)
    {
        try {
            while (!lifetime.IsCancellationRequested) {
                await Task.Delay(TimeSpan.FromSeconds(5), lifetime.Token);
                if (!lastReceived.TryGetValue(transport, out var received)) return;
                if (Environment.TickCount64 - received >= 20000) { log($"SessionHeartbeatTimeout transport={transport.Kind} idleMs={Environment.TickCount64-received}"); await transport.DisposeAsync(); return; }
                heartbeatSent[transport]=System.Diagnostics.Stopwatch.GetTimestamp();
                await SendFrame("ping", info.PeerID, transport: transport);
                if(transport.Kind=="ble")log("BLEHeartbeatSent");
            }
        } catch { await transport.DisposeAsync(); }
    }
    public bool AutoConnectionDeclined(string peer)=>declinedConnections.ContainsKey(peer);
    public SessionInfo[] CurrentSessions() => sessions.Values.Select(s => s.Info).ToArray();
    // Input ACK delay is distinct from loss of a live, authenticated input session.
    public bool InputSessionAlive(string peer) {
        if(!sessions.TryGetValue(peer,out var session)||!session.Info.Capabilities.Contains("input"))return false;
        var now=Environment.TickCount64;
        return session.Links.Values.Any(link=>lastReceived.TryGetValue(link,out var seen)&&now-seen<12000);
    }
    public void DisconnectTransport(string peerId, string kind) { if (sessions.TryGetValue(peerId, out var item) && item.Links.TryGetValue(kind, out var link)) _ = link.DisposeAsync(); }
    public void Disconnect(string peerId) { if (sessions.TryGetValue(peerId, out var item)) foreach (var link in item.Links.Values) _ = link.DisposeAsync(); }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel(); listener?.Stop(); bluetoothListener?.Stop();
        if (quicListener is not null) await quicListener.DisposeAsync();
        foreach (var item in sessions.Values) foreach (var link in item.Links.Values) await link.DisposeAsync();
    }
}
