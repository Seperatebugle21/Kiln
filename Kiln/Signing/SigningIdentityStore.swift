import Foundation
import Security

/// The certificate Kiln signs built apps with: a .p12 (developer or enterprise) and its password,
/// kept in the Keychain. It must be the certificate Kiln itself is signed with, so the Team IDs match.
enum SigningIdentityStore {
    struct Identity {
        let privateKey: SecKey
        /// Leaf first, then intermediates and root.
        let certificates: [[UInt8]]
        let teamID: String
        let name: String
    }

    enum Failure: LocalizedError {
        case wrongPassword
        case unreadable(OSStatus)
        case noTeamID

        var errorDescription: String? {
            switch self {
            case .wrongPassword: return "The password for this certificate is wrong."
            case .unreadable(let status): return "The certificate could not be read (error \(status))."
            case .noTeamID: return "The certificate has no Team ID (organizational unit)."
            }
        }
    }

    private static let p12Account = "signing-p12"
    private static let passwordAccount = "signing-p12-password"

    static var isConfigured: Bool {
        Keychain.read(p12Account) != nil
    }

    /// Validates and stores a .p12; returns the identity so the UI can show what was imported.
    @discardableResult
    static func save(p12: Data, password: String, appleCertificates: [[UInt8]]) throws -> Identity {
        let identity = try makeIdentity(p12: p12, password: password, appleCertificates: appleCertificates)
        Keychain.write(p12.base64EncodedString(), for: p12Account)
        Keychain.write(password, for: passwordAccount)
        return identity
    }

    static func load(appleCertificates: [[UInt8]]) throws -> Identity? {
        guard let encoded = Keychain.read(p12Account), let p12 = Data(base64Encoded: encoded) else { return nil }
        return try makeIdentity(p12: p12, password: Keychain.read(passwordAccount) ?? "", appleCertificates: appleCertificates)
    }

    static func remove() {
        Keychain.write(nil, for: p12Account)
        Keychain.write(nil, for: passwordAccount)
    }

    /// Apple's intermediate and root certificates bundled with Kiln (Toolchain/certs/*.cer), used to
    /// complete the chain when the .p12 holds only the leaf certificate.
    static func bundledAppleCertificates() -> [[UInt8]] {
        guard let folder = Bundle.main.url(forResource: "Toolchain", withExtension: nil)?.appendingPathComponent("certs"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "cer" }.compactMap { try? [UInt8](Data(contentsOf: $0)) }
    }

    private static func makeIdentity(p12: Data, password: String, appleCertificates: [[UInt8]]) throws -> Identity {
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if status == errSecAuthFailed { throw Failure.wrongPassword }
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]],
              let first = entries.first,
              let identityRef = first[kSecImportItemIdentity as String]
        else { throw Failure.unreadable(status) }
        let identity = identityRef as! SecIdentity

        var key: SecKey?
        var certificate: SecCertificate?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
              SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate
        else { throw Failure.unreadable(status) }

        let leafDER = [UInt8](SecCertificateCopyData(certificate) as Data)
        let leaf = try CertificateInfo(der: leafDER)
        guard let teamID = leaf.organizationalUnit else { throw Failure.noTeamID }

        let chainFromP12 = (first[kSecImportItemCertChain as String] as? [SecCertificate] ?? [])
            .map { [UInt8](SecCertificateCopyData($0) as Data) }
        let chain = buildChain(leaf: leaf, candidates: chainFromP12 + appleCertificates)

        return Identity(
            privateKey: key,
            certificates: chain,
            teamID: teamID,
            name: leaf.commonName ?? "Certificate"
        )
    }

    /// The leaf followed by its issuers, found by matching issuer and subject names.
    static func buildChain(leaf: CertificateInfo, candidates: [[UInt8]]) -> [[UInt8]] {
        let parsed = candidates.compactMap { try? CertificateInfo(der: $0) }
        var chain = [leaf]
        while let last = chain.last, last.issuer != last.subject,
              let parent = parsed.first(where: { $0.subject == last.issuer && $0.der != last.der }),
              chain.count < 4 {
            chain.append(parent)
        }
        return chain.map(\.der)
    }
}
