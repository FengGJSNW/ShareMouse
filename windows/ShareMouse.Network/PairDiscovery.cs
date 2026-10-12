using System.Net;
using System.Net.Sockets;
using System.Net.NetworkInformation;
using System.Text.Json;

namespace ShareMouse.Network;
public sealed record PairDiscoveryHint(string PeerID, string PairCode, int Port = 49160, string ProtocolID = "sharemouse-discovery-v1");
/// Discovery is a hint; TLS certificates and receiver approval authorize connections.
public sealed class PairDiscovery : IDisposable {
    private readonly UdpClient socket = new(AddressFamily.InterNetwork);
    private readonly CancellationTokenSource lifetime = new();
    private readonly object gate = new();
    private readonly Dictionary<string,(PairDiscoveryHint Hint,string Host,long Seen)> peers = new();
    private static readonly JsonSerializerOptions json = new() { PropertyNamingPolicy=JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive=true };
    private PairDiscoveryHint local;
    private bool enabled=true;
    public event Action<(PairDiscoveryHint Hint,string Host)[]>? Changed;
    public PairDiscovery(string id,string code) { local=new(id,code); }
    public void Start() {
        try { socket.Client.SetSocketOption(SocketOptionLevel.Socket,SocketOptionName.ReuseAddress,true); socket.EnableBroadcast=true; socket.Client.Bind(new IPEndPoint(IPAddress.Any,49161)); }
        catch { socket.Dispose();return; }
        _=Receive();_=AnnounceLoop();
    }
    public void Update(string code,bool available) { lock(gate) {local=local with {PairCode=code};enabled=available;if(!available)peers.Clear();}Publish();_=Announce(); }
    private async Task Send(IPAddress address) {
        PairDiscoveryHint hint;lock(gate){if(!enabled)return;hint=local;}
        try {await socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(hint,json),new IPEndPoint(address,49161),lifetime.Token);}catch(Exception) when(!lifetime.IsCancellationRequested){ }
    }
    private async Task Announce() {
        var targets=new HashSet<IPAddress>{IPAddress.Broadcast};
        try {foreach(var network in NetworkInterface.GetAllNetworkInterfaces().Where(n=>n.OperationalStatus==OperationalStatus.Up))
            foreach(var value in network.GetIPProperties().UnicastAddresses.Where(a=>a.Address.AddressFamily==AddressFamily.InterNetwork&&!IPAddress.IsLoopback(a.Address))) {
                var a=value.Address.GetAddressBytes();var m=value.IPv4Mask.GetAddressBytes();targets.Add(new IPAddress(a.Zip(m,(b,mask)=>(byte)(b|~mask)).ToArray()));
            }}catch { }
        foreach(var target in targets) {if(lifetime.IsCancellationRequested)return;await Send(target);}
    }
    private async Task AnnounceLoop() {try {while(!lifetime.IsCancellationRequested){await Announce();Publish();await Task.Delay(10000,lifetime.Token);}}catch(OperationCanceledException){} }
    private void Publish() {
        (PairDiscoveryHint Hint,string Host)[] values;
        lock(gate){foreach(var id in peers.Where(p=>Environment.TickCount64-p.Value.Seen>=35000).Select(p=>p.Key).ToArray())peers.Remove(id);values=peers.Values.Select(v=>(v.Hint,v.Host)).ToArray();}
        Changed?.Invoke(values);
    }
    private async Task Receive() {try {while(!lifetime.IsCancellationRequested) {
        var packet=await socket.ReceiveAsync(lifetime.Token);if(packet.Buffer.Length>1024)continue;
        PairDiscoveryHint? hint;try{hint=JsonSerializer.Deserialize<PairDiscoveryHint>(packet.Buffer,json);}catch{continue;}
        if(hint is null||hint.ProtocolID!="sharemouse-discovery-v1"||hint.PeerID==local.PeerID||!Guid.TryParse(hint.PeerID,out _)||hint.PairCode is not {Length:6}||hint.PairCode.Any(c=>c<'0'||c>'9')||hint.Port is <=0 or >65535||!new ShareMouse.Core.NetworkEndpoint(packet.RemoteEndPoint.Address.ToString(),hint.Port).Valid())continue;
        bool fresh;lock(gate){if(!enabled)continue;fresh=!peers.ContainsKey(hint.PeerID);if(peers.Count<128||!fresh)peers[hint.PeerID]=(hint,packet.RemoteEndPoint.Address.ToString(),Environment.TickCount64);}
        Publish();if(fresh)await Send(packet.RemoteEndPoint.Address);
    }}catch(OperationCanceledException){}catch(ObjectDisposedException){}catch(SocketException){} }
    public void Dispose(){lifetime.Cancel();socket.Dispose();}
}
