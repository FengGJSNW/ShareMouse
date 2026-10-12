import Foundation
import Security

public final class IdentityKeychain: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificatePeer: CertificatePeer
    public let certificateData: Data

    public init(peerID: String) throws {
        let label = "ShareMouse identity " + peerID
        let tag = Data(("com.sharemouse.identity." + peerID).utf8)
        let certificateQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(certificateQuery as CFDictionary, &result)
        let certificate: SecCertificate
        if status == errSecSuccess {
            certificate = result as! SecCertificate
        } else {
            guard status == errSecItemNotFound else { throw KeychainError.status(status) }
            let keyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecReturnRef as String: true
            ]
            var keyResult: CFTypeRef?
            let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyResult)
            let key: SecKey
            if keyStatus == errSecSuccess {
                key = keyResult as! SecKey
            } else {
                guard keyStatus == errSecItemNotFound else { throw KeychainError.status(keyStatus) }
                var error: Unmanaged<CFError>?
                let attributes: [String: Any] = [
                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
                    kSecPrivateKeyAttrs as String: [
                        kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag,
                        kSecAttrLabel as String: label
                    ]
                ]
                guard let generated = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                    throw error!.takeRetainedValue()
                }
                key = generated
            }
            // System LibreSSL creates X.509; private key material travels through an in-memory pipe, never a file.
            var exportError: Unmanaged<CFError>?
            guard let raw = SecKeyCopyExternalRepresentation(key, &exportError) as Data? else {
                throw exportError!.takeRetainedValue()
            }
            let pem = "-----BEGIN RSA PRIVATE KEY-----\n"
                + raw.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                + "\n-----END RSA PRIVATE KEY-----\n"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = ["req", "-new", "-x509", "-sha256", "-days", "3650",
                                 "-key", "/dev/stdin", "-subj", "/CN=ShareMouse-" + peerID,
                                 "-outform", "DER"]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(pem.utf8))
            try input.fileHandleForWriting.close()
            let der = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let created = SecCertificateCreateWithData(nil, der as CFData) else {
                throw KeychainError.certificateCreationFailed
            }
            certificate = created
            let add: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                      kSecValueRef as String: created, kSecAttrLabel as String: label]
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        }
        var localIdentity: SecIdentity?
        let identityStatus = SecIdentityCreateWithCertificate(nil, certificate, &localIdentity)
        guard identityStatus == errSecSuccess, let localIdentity else { throw KeychainError.status(identityStatus) }
        identity = localIdentity
        certificateData = SecCertificateCopyData(certificate) as Data
        certificatePeer = try Self.describe(certificate)
        guard certificatePeer.peerID == peerID else { throw PairingError.identityChanged }
    }

    public static func describe(_ certificate: SecCertificate) throws -> CertificatePeer {
        var commonName: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess,
              let name = commonName as String?, name.hasPrefix("ShareMouse-"),
              let id = UUID(uuidString: String(name.dropFirst(11))),
              let key = SecCertificateCopyKey(certificate) else { throw PairingError.invalidMessage }
        let attributes = SecKeyCopyAttributes(key) as! [String: Any]
        guard attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String,
              (attributes[kSecAttrKeySizeInBits as String] as? Int ?? 0) >= 2048 else { throw PairingError.invalidMessage }
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw PairingError.invalidMessage }
        return CertificatePeer(peerID: id.uuidString.lowercased(), publicKey: raw.base64EncodedString())
    }

    public enum KeychainError: Error { case status(OSStatus), certificateCreationFailed }
}
