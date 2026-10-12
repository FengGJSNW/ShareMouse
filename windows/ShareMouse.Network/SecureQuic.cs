using System.Buffers.Binary;
using System.Net;
using System.Net.Quic;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using ShareMouse.Core;

namespace ShareMouse.Network;

// Standard QUIC uses UDP with TLS 1.3. No custom UDP encryption or plaintext input packets.
public sealed class SecureQuic : ISessionTransport
{
    public const string Alpn = "sharemouse-1";
    public string Kind => "quic";
    public string? RemoteHost => (connection.RemoteEndPoint as IPEndPoint)?.Address.ToString();
    public string? LocalHost => (connection.LocalEndPoint as IPEndPoint)?.Address.ToString();
    public CertificatePeer RemoteCertificate { get; }
    private readonly QuicConnection connection;
    private readonly QuicStream stream;
    private readonly SemaphoreSlim sendGate = new(1, 1);
    private static readonly JsonSerializerOptions json = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };
    private SecureQuic(QuicConnection connection, QuicStream stream)
    {
        this.connection = connection; this.stream = stream;
        using var certificate = new X509Certificate2(connection.RemoteCertificate!);
        RemoteCertificate = IdentityStore.Describe(certificate);
    }
    public static bool Verify(X509Certificate? certificate, Func<CertificatePeer, bool> verify)
    {
        if (certificate is null) return false;
        try { using var peer = new X509Certificate2(certificate); return verify(IdentityStore.Describe(peer)); }
        catch { return false; }
    }
    public static async Task<SecureQuic> ConnectAsync(string host, int port, IdentityStore identity,
        Func<CertificatePeer, bool> verify, CancellationToken cancellation)
    {
        var addresses = await Dns.GetHostAddressesAsync(host, cancellation);
        var address = addresses.FirstOrDefault(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork) ?? addresses.First();
        var connection = await QuicConnection.ConnectAsync(new QuicClientConnectionOptions {
            RemoteEndPoint = new IPEndPoint(address, port), DefaultCloseErrorCode = 0, DefaultStreamErrorCode = 0,
            MaxInboundBidirectionalStreams = 1, MaxInboundUnidirectionalStreams = 0,
            ClientAuthenticationOptions = new SslClientAuthenticationOptions {
                ApplicationProtocols = [new SslApplicationProtocol(Alpn)], TargetHost = "ShareMouse",
                ClientCertificates = new X509CertificateCollection { identity.Certificate },
                LocalCertificateSelectionCallback = (_, _, _, _, _) => identity.Certificate,
                RemoteCertificateValidationCallback = (_, certificate, _, _) => Verify(certificate, verify),
                EnabledSslProtocols = SslProtocols.Tls13, AllowTlsResume = false,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            }
        }, cancellation);
        try {
            var stream = await connection.OpenOutboundStreamAsync(QuicStreamType.Bidirectional, cancellation);
            await stream.WriteAsync(new byte[] { 1 }, cancellation);
            return new(connection, stream);
        } catch { await connection.DisposeAsync(); throw; }
    }
    public static async Task<SecureQuic> AcceptAsync(QuicConnection connection, CancellationToken cancellation)
    {
        try {
            var stream = await connection.AcceptInboundStreamAsync(cancellation);
            var open = new byte[1]; await stream.ReadExactlyAsync(open, cancellation);
            if (open[0] != 1) throw new InvalidDataException("Invalid QUIC stream preface.");
            return new(connection, stream);
        }
        catch { await connection.DisposeAsync(); throw; }
    }
    public async Task SendAsync(SessionMessage message, CancellationToken cancellation)
    {
        var payload = SessionFrameCodec.Encode(message);
        if (payload.Length > 65536) throw new InvalidDataException("Frame too large.");
        var frame = new byte[4+payload.Length]; BinaryPrimitives.WriteInt32BigEndian(frame, payload.Length); payload.CopyTo(frame,4);
        await sendGate.WaitAsync(cancellation).ConfigureAwait(false);
        try { await stream.WriteAsync(frame, cancellation).ConfigureAwait(false); }
        finally { sendGate.Release(); }
    }
    public async Task<SessionMessage> ReceiveAsync(CancellationToken cancellation)
    {
        var header = new byte[4]; await stream.ReadExactlyAsync(header, cancellation).ConfigureAwait(false);
        var count = BinaryPrimitives.ReadInt32BigEndian(header);
        if (count is <= 0 or > 65536) throw new InvalidDataException("Invalid frame size.");
        var payload = new byte[count]; await stream.ReadExactlyAsync(payload, cancellation).ConfigureAwait(false);
        return SessionFrameCodec.Decode(payload);
    }
    public async ValueTask DisposeAsync() { await stream.DisposeAsync(); await connection.DisposeAsync(); }
}
