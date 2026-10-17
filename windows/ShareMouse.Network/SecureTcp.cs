using System.Buffers.Binary;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using ShareMouse.Core;

namespace ShareMouse.Network;

public interface ISessionTransport : IAsyncDisposable
{
    string Kind
    {
        get;
    }
    string? RemoteHost
    {
        get;
    }
    string? LocalHost
    {
        get;
    }
    CertificatePeer RemoteCertificate
    {
        get;
    }
    Task SendAsync(SessionMessage message, CancellationToken cancellation);
    Task<SessionMessage> ReceiveAsync(CancellationToken cancellation);
}

public sealed class SecureTcp : ISessionTransport
{
    private readonly TcpClient client;
    private readonly SslStream stream;
    private readonly SemaphoreSlim sendGate = new(1, 1);
    public string Kind
    {
        get;
    }
    public string? RemoteHost => Kind == "ble" ? null : Host((client.Client.RemoteEndPoint as System.Net.IPEndPoint)?.Address);
    public string? LocalHost => Kind == "ble" ? null : Host((client.Client.LocalEndPoint as System.Net.IPEndPoint)?.Address);
    private static string? Host(System.Net.IPAddress? address) => address?.IsIPv4MappedToIPv6 == true ? address.MapToIPv4().ToString() : address?.ToString();
    public CertificatePeer RemoteCertificate { get; private set; } = null!;
    private static readonly JsonSerializerOptions json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    private SecureTcp(TcpClient client, Func<CertificatePeer, bool> verify, string kind)
    {
        this.client = client;
        Kind = kind;
        stream = new SslStream(client.GetStream(), false, (_, certificate, _, _) =>
        {
            if (certificate is null)
                return false;
            try
            {
                using var peer = new X509Certificate2(certificate);
                RemoteCertificate = IdentityStore.Describe(peer);
                return verify(RemoteCertificate);
            }
            catch { return false; }
        });
    }

    public static async Task<SecureTcp> ConnectAsync(string host, int port, IdentityStore identity,
        Func<CertificatePeer, bool> verify, CancellationToken cancellation, string kind = "tcp")
    {
        var client = new TcpClient { NoDelay = true };
        SecureTcp? transport = null;
        try
        {
            await client.ConnectAsync(host, port, cancellation);
            transport = new SecureTcp(client, verify, kind);
            await transport.stream.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
            {
                TargetHost = "ShareMouse",
                ClientCertificates = new X509CertificateCollection { identity.Certificate },
                LocalCertificateSelectionCallback = (_, _, _, _, _) => identity.Certificate,
                EnabledSslProtocols = SslProtocols.Tls13,
                AllowTlsResume = false,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            }, cancellation);
            return transport;
        }
        catch { if (transport is not null) await transport.DisposeAsync(); else client.Dispose(); throw; }
    }

    public static async Task<SecureTcp> AcceptAsync(TcpClient client, IdentityStore identity,
        Func<CertificatePeer, bool> verify, CancellationToken cancellation, string kind = "tcp")
    {
        client.NoDelay = true;
        var transport = new SecureTcp(client, verify, kind);
        try
        {
            await transport.stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = identity.Certificate,
                ClientCertificateRequired = true,
                EnabledSslProtocols = SslProtocols.Tls13,
                AllowTlsResume = false,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            }, cancellation);
            return transport;
        }
        catch { await transport.DisposeAsync(); throw; }
    }

    public async Task SendAsync(SessionMessage message, CancellationToken cancellation)
    {
        var payload = SessionFrameCodec.Encode(message);
        if (payload.Length > 65536)
            throw new InvalidDataException("Frame too large.");
        var frame = new byte[4 + payload.Length];
        BinaryPrimitives.WriteInt32BigEndian(frame, payload.Length);
        payload.CopyTo(frame, 4);
        await sendGate.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            await stream.WriteAsync(frame, cancellation).ConfigureAwait(false);
        }
        finally { sendGate.Release(); }
    }
    public async Task<SessionMessage> ReceiveAsync(CancellationToken cancellation)
    {
        var header = new byte[4];
        await stream.ReadExactlyAsync(header, cancellation).ConfigureAwait(false);
        var count = BinaryPrimitives.ReadInt32BigEndian(header);
        if (count is <= 0 or > 65536)
            throw new InvalidDataException("Invalid frame size.");
        var payload = new byte[count];
        await stream.ReadExactlyAsync(payload, cancellation).ConfigureAwait(false);
        return SessionFrameCodec.Decode(payload);
    }
    public async ValueTask DisposeAsync()
    {
        await stream.DisposeAsync();
        client.Dispose();
    }
}
