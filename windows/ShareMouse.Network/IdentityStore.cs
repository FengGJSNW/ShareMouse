using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using ShareMouse.Core;

namespace ShareMouse.Network;

public sealed class IdentityStore : IDisposable
{
    public X509Certificate2 Certificate { get; }
    public CertificatePeer Identity { get; }

    public IdentityStore(string peerId)
    {
        using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadWrite);
        var subject = "CN=ShareMouse-" + peerId;
        var existing = store.Certificates.Cast<X509Certificate2>().FirstOrDefault(c => c.Subject == subject);
        if (existing is not null)
        {
            if (!existing.HasPrivateKey) throw new CryptographicException("Stored identity has no private key; preserved.");
            Certificate = existing;
        }
        else
        {
            var keyName = "ShareMouse-" + peerId;
            using var key = CngKey.Exists(keyName) ? CngKey.Open(keyName) : CngKey.Create(CngAlgorithm.Rsa, keyName,
                new CngKeyCreationParameters {
                    Provider = CngProvider.MicrosoftSoftwareKeyStorageProvider,
                    ExportPolicy = CngExportPolicies.None,
                    KeyUsage = CngKeyUsages.Signing | CngKeyUsages.Decryption,
                    Parameters = { new CngProperty("Length", BitConverter.GetBytes(2048), CngPropertyOptions.None) }
                });
            using var rsa = new RSACng(key);
            var request = new CertificateRequest(subject, rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
            request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
                new OidCollection { new("1.3.6.1.5.5.7.3.1"), new("1.3.6.1.5.5.7.3.2") }, false));
            using var created = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddYears(10));
            store.Add(created);
            Certificate = store.Certificates.Cast<X509Certificate2>().First(c => c.Subject == subject && c.HasPrivateKey);
        }
        Identity = Describe(Certificate);
        if (Identity.PeerID != peerId) throw new CryptographicException("Identity mismatch.");
    }

    public static CertificatePeer Describe(X509Certificate2 certificate)
    {
        var name = certificate.GetNameInfo(X509NameType.SimpleName, false);
        if (!name.StartsWith("ShareMouse-") || !Guid.TryParse(name[11..], out var id))
            throw new CryptographicException("Invalid peer certificate.");
        using var rsa = certificate.GetRSAPublicKey() ?? throw new CryptographicException("Unsupported identity key.");
        if (rsa.KeySize < 2048 || DateTime.UtcNow < certificate.NotBefore.ToUniversalTime()
            || DateTime.UtcNow > certificate.NotAfter.ToUniversalTime()) throw new CryptographicException("Invalid peer certificate.");
        return new(id.ToString("D"), Convert.ToBase64String(rsa.ExportRSAPublicKey()));
    }
    public void Dispose() => Certificate.Dispose();
}
