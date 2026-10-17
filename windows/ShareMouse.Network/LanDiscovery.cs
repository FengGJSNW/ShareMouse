using System.Net;
using System.Net.Sockets;
using Makaretu.Dns;

namespace ShareMouse.Network;

public sealed record LanCandidate(string Id, string Host, int Port, string? PeerID = null, string? PairCode = null);

public sealed class LanDiscovery : IDisposable
{
    private readonly ServiceDiscovery discovery = new();
    private readonly ServiceProfile profile;
    private readonly Timer refresh;
    private readonly object gate = new();
    private readonly Dictionary<string, SRVRecord> services = [];
    private readonly Dictionary<string, IPAddress> addresses = [];
    public event Action<LanCandidate[]>? Changed;

    public LanDiscovery(int port)
    {
        profile = new ServiceProfile(Guid.NewGuid().ToString("N"), "_sharemouse._tcp", (ushort)port,
            MulticastService.GetIPAddresses().Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a)
                && !(a.GetAddressBytes()[0] == 169 && a.GetAddressBytes()[1] == 254)));
        discovery.Mdns.AnswerReceived += (_, e) => Receive(e.Message);
        discovery.Advertise(profile);
        discovery.Announce(profile);
        refresh = new Timer(_ => discovery.QueryServiceInstances("_sharemouse._tcp"), null, TimeSpan.Zero, TimeSpan.FromSeconds(10));
    }
    private void Receive(Message message)
    {
        var records = message.Answers.Concat(message.AdditionalRecords).ToArray();
        LanCandidate[] candidates;
        lock (gate)
        {
            foreach (var address in records.OfType<ARecord>())
                addresses[address.Name.ToString()] = address.Address;
            foreach (var service in records.OfType<SRVRecord>().Where(s => s.Name.ToString().Contains("._sharemouse._tcp.local")))
            {
                if (service.Name == profile.FullyQualifiedName)
                    continue;
                if (service.TTL == TimeSpan.Zero)
                    services.Remove(service.Name.ToString());
                else
                    services[service.Name.ToString()] = service;
                if (!addresses.ContainsKey(service.Target.ToString()))
                    discovery.Mdns.SendQuery(service.Target, type: DnsType.A);
            }
            candidates = services.Values.Where(s => addresses.ContainsKey(s.Target.ToString()))
                .Select(s => new LanCandidate(s.Name.ToString(), addresses[s.Target.ToString()].ToString(), s.Port)).ToArray();
        }
        Changed?.Invoke(candidates);
    }
    public void SetAvailable(bool enabled)
    {
        if (enabled)
        {
            discovery.Advertise(profile);
            discovery.Announce(profile);
        }
        else
            discovery.Unadvertise(profile);
    }
    public void Dispose()
    {
        refresh.Dispose();
        discovery.Unadvertise(profile);
        discovery.Dispose();
    }
}
