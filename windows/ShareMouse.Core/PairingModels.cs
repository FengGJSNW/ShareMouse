using System.Text.Json;

namespace ShareMouse.Core;

public sealed record CertificatePeer(string PeerID, string PublicKey);
public sealed record KnownPeer(string PeerID, string Name, string PublicKey, string Trust, bool AutoConnect, NetworkEndpoint[]? NetworkEndpoints = null);
public sealed record SessionInfo(string SessionID, string PeerID, string Name, string[] Capabilities, string InitiatorPeerID, string? LanHost = null, string? LocalHost = null, int ListenPort = 49160, string RemotePlatform = "unknown", string? RemoteInstanceID = null);

public sealed class PeerRegistry
{
    private readonly object gate = new();
    private readonly string file;
    private readonly List<KnownPeer> peers;
    private static readonly JsonSerializerOptions json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public PeerRegistry(string directory)
    {
        file = Path.Combine(directory, "known-peers.json");
        peers = File.Exists(file) ? JsonSerializer.Deserialize<List<KnownPeer>>(File.ReadAllText(file), json)
            ?? throw new InvalidDataException("Invalid peer registry.") : [];
    }
    public KnownPeer[] All()
    {
        lock (gate)
            return peers.ToArray();
    }
    public KnownPeer? Find(string id)
    {
        lock (gate)
            return peers.FirstOrDefault(p => p.PeerID == id);
    }
    public void Remember(CertificatePeer certificate, string name)
    {
        lock (gate)
        {
            var index = peers.FindIndex(p => p.PeerID == certificate.PeerID);
            if (index >= 0)
            {
                if (peers[index].PublicKey != certificate.PublicKey)
                    throw new InvalidDataException("Peer identity changed.");
                peers[index] = peers[index] with
                {
                    Name = name[..Math.Min(name.Length, 128)]
                };
            }
            else
                peers.Add(new(certificate.PeerID, name[..Math.Min(name.Length, 128)], certificate.PublicKey, "known", false));
            Save();
        }
    }
    public void SetPreferences(string id, bool trusted, bool autoConnect)
    {
        lock (gate)
        {
            var index = peers.FindIndex(p => p.PeerID == id);
            if (index < 0)
                throw new InvalidDataException("Unknown peer.");
            peers[index] = peers[index] with
            {
                Trust = trusted ? "trusted" : "known",
                AutoConnect = trusted && autoConnect
            };
            Save();
        }
    }
    public void Remove(string id)
    {
        lock (gate)
        {
            peers.RemoveAll(p => p.PeerID == id);
            Save();
        }
    }
    public void RememberNetworkEndpoint(string id, NetworkEndpoint endpoint)
    {
        if (!endpoint.Valid(allowLoopback: true))
            return;
        lock (gate)
        {
            var index = peers.FindIndex(p => p.PeerID == id);
            if (index < 0)
                return;
            var previous = peers[index].NetworkEndpoints ?? [];
            var next = new[] { endpoint }.Concat(previous.Where(p => p != endpoint)).Take(8).ToArray();
            if (next.SequenceEqual(previous))
                return;
            peers[index] = peers[index] with
            {
                NetworkEndpoints = next
            };
            Save();
        }
    }
    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        var temporary = file + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(peers, json));
        File.Move(temporary, file, overwrite: true);
    }
}

public sealed class SessionMessage
{
    public int Version { get; set; } = 2;
    public required string Type
    {
        get; set;
    }
    public required string SourcePeerID
    {
        get; set;
    }
    public string? TargetPeerID
    {
        get; set;
    }
    public string? SessionID
    {
        get; set;
    }
    public string? InstanceID
    {
        get; set;
    }
    public ulong Sequence
    {
        get; set;
    }
    public string? Name
    {
        get; set;
    }
    public string? Platform
    {
        get; set;
    }
    public string[]? Capabilities
    {
        get; set;
    }
    public string? Mode
    {
        get; set;
    }
    public bool? AutoConnection
    {
        get; set;
    }
    public string? PairCode
    {
        get; set;
    }
    public string? Password
    {
        get; set;
    }
    public int? ListenPort
    {
        get; set;
    }
    public string? GroupID
    {
        get; set;
    }
    public string? Error
    {
        get; set;
    }
    public string? Channel
    {
        get; set;
    }
    public string? DeliveryID
    {
        get; set;
    }
    public byte[]? Payload
    {
        get; set;
    }
}
