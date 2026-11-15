import CryptoKit
import Foundation
import Security

/// Signs a thin arm64 Mach-O (a dylib from lld, linked with -adhoc_codesign so it already has an
/// LC_CODE_SIGNATURE at the end of __LINKEDIT) with a developer or enterprise certificate.
///
/// iOS only loads a dylib into Kiln when its signature chains to Apple and carries the same Team ID
/// as Kiln ("library validation"); an ad-hoc signature is rejected with "code signature invalid".
///
/// The signature is a SuperBlob with a SHA-256 CodeDirectory, an empty requirements set and a CMS
/// (PKCS #7) signature over the CodeDirectory, the same structure `codesign` writes.
struct MachOSigner {
    enum Failure: LocalizedError {
        case notMachO
        case noSignatureCommand
        case malformed(String)
        case signing(String)

        var errorDescription: String? {
            switch self {
            case .notMachO: return "The built app is not a 64-bit Mach-O file."
            case .noSignatureCommand: return "The built app has no code signature load command."
            case .malformed(let detail): return "The built app could not be signed: \(detail)"
            case .signing(let detail): return "Signing failed: \(detail)"
            }
        }
    }

    /// The signing key and certificates: the leaf first, then intermediates (and optionally the root).
    let privateKey: SecKey
    let certificates: [[UInt8]]
    /// The Team ID written into the CodeDirectory; must match the certificate's.
    let teamID: String

    private static let pageSize = 4096
    /// Room reserved for the CMS signature (certificates and signature), which is unknown up front.
    private static let cmsReserve = 18_000

    func sign(fileAt url: URL, identifier: String) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count > 32, bytes.readUInt32(at: 0) == 0xFEED_FACF else { throw Failure.notMachO }

        // Find LC_CODE_SIGNATURE, __LINKEDIT and __TEXT.
        let commandCount = Int(bytes.readUInt32(at: 16))
        var offset = 32
        var signatureCommand: Int?
        var linkedit: Int?
        var textFileOffset: UInt64 = 0
        var textFileSize: UInt64 = 0
        for _ in 0..<commandCount {
            guard offset + 8 <= bytes.count else { throw Failure.malformed("truncated load commands") }
            let command = bytes.readUInt32(at: offset)
            let size = Int(bytes.readUInt32(at: offset + 4))
            if command == 0x1D { signatureCommand = offset }
            if command == 0x19 {
                let name = String(decoding: bytes[(offset + 8)..<(offset + 24)].prefix { $0 != 0 }, as: UTF8.self)
                if name == "__LINKEDIT" { linkedit = offset }
                if name == "__TEXT" {
                    textFileOffset = bytes.readUInt64(at: offset + 40)
                    textFileSize = bytes.readUInt64(at: offset + 48)
                }
            }
            offset += size
        }
        guard let signatureCommand else { throw Failure.noSignatureCommand }
        guard let linkedit else { throw Failure.malformed("no __LINKEDIT segment") }

        let codeLimit = Int(bytes.readUInt32(at: signatureCommand + 8))
        let linkeditFileOffset = Int(bytes.readUInt64(at: linkedit + 40))
        guard codeLimit <= bytes.count, codeLimit > linkeditFileOffset else { throw Failure.malformed("unexpected signature position") }

        // Layout of the new signature, with a fixed reserve for the CMS blob.
        let requirements = Self.emptyRequirements()
        let codeSlots = (codeLimit + Self.pageSize - 1) / Self.pageSize
        let codeDirectoryLength = Self.codeDirectoryLength(identifier: identifier, teamID: teamID, codeSlots: codeSlots)
        let superBlobHeader = 12 + 3 * 8
        let reserved = Self.align(superBlobHeader + codeDirectoryLength + requirements.count + 8 + Self.cmsReserve, to: 16)

        // Resize the signature and __LINKEDIT before hashing: the header is part of the first page.
        bytes.removeSubrange(codeLimit...)
        bytes.writeUInt32(UInt32(reserved), at: signatureCommand + 12)
        let linkeditFileSize = UInt64(codeLimit + reserved - linkeditFileOffset)
        bytes.writeUInt64(linkeditFileSize, at: linkedit + 48)
        bytes.writeUInt64(UInt64(Self.align(Int(linkeditFileSize), to: 0x4000)), at: linkedit + 32)

        // CodeDirectory: hashes of every page, the requirements, identifier and Team ID.
        var pageHashes: [UInt8] = []
        var page = 0
        while page < codeLimit {
            let end = min(page + Self.pageSize, codeLimit)
            pageHashes += Array(SHA256.hash(data: bytes[page..<end]))
            page = end
        }
        let codeDirectory = Self.codeDirectory(
            identifier: identifier,
            teamID: teamID,
            codeLimit: codeLimit,
            pageHashes: pageHashes,
            codeSlots: codeSlots,
            requirementsHash: Array(SHA256.hash(data: requirements)),
            execSegBase: textFileOffset,
            execSegLimit: textFileSize
        )
        precondition(codeDirectory.count == codeDirectoryLength)

        let cms = try cmsSignature(over: codeDirectory)
        var cmsBlob: [UInt8] = []
        cmsBlob.appendUInt32(0xFADE_0B01)
        cmsBlob.appendUInt32(UInt32(8 + cms.count))
        cmsBlob += cms

        // SuperBlob: index of CodeDirectory (slot 0), requirements (slot 2) and CMS (0x10000).
        var superBlob: [UInt8] = []
        let blobs: [(UInt32, [UInt8])] = [(0, codeDirectory), (2, requirements), (0x10000, cmsBlob)]
        let used = superBlobHeader + blobs.reduce(0) { $0 + $1.1.count }
        guard used <= reserved else { throw Failure.signing("the signature is larger than the reserved space") }
        superBlob.appendUInt32(0xFADE_0CC0)
        superBlob.appendUInt32(UInt32(used))
        superBlob.appendUInt32(UInt32(blobs.count))
        var blobOffset = superBlobHeader
        for (type, blob) in blobs {
            superBlob.appendUInt32(type)
            superBlob.appendUInt32(UInt32(blobOffset))
            blobOffset += blob.count
        }
        for (_, blob) in blobs { superBlob += blob }
        superBlob += [UInt8](repeating: 0, count: reserved - superBlob.count)

        bytes += superBlob
        try Data(bytes).write(to: url, options: .atomic)
    }

    // MARK: CodeDirectory

    private static let codeDirectoryHeaderLength = 88 // version 0x20400

    private static func codeDirectoryLength(identifier: String, teamID: String, codeSlots: Int) -> Int {
        codeDirectoryHeaderLength + identifier.utf8.count + 1 + teamID.utf8.count + 1 + (2 + codeSlots) * 32
    }

    private static func codeDirectory(
        identifier: String,
        teamID: String,
        codeLimit: Int,
        pageHashes: [UInt8],
        codeSlots: Int,
        requirementsHash: [UInt8],
        execSegBase: UInt64,
        execSegLimit: UInt64
    ) -> [UInt8] {
        let identOffset = codeDirectoryHeaderLength
        let teamOffset = identOffset + identifier.utf8.count + 1
        let specialSlots = 2 // -1 Info.plist (empty), -2 requirements
        let hashOffset = teamOffset + teamID.utf8.count + 1 + specialSlots * 32
        let length = hashOffset + codeSlots * 32

        var blob: [UInt8] = []
        blob.appendUInt32(0xFADE_0C02)        // magic
        blob.appendUInt32(UInt32(length))
        blob.appendUInt32(0x20400)            // version
        blob.appendUInt32(0)                  // flags (not ad hoc)
        blob.appendUInt32(UInt32(hashOffset))
        blob.appendUInt32(UInt32(identOffset))
        blob.appendUInt32(UInt32(specialSlots))
        blob.appendUInt32(UInt32(codeSlots))
        blob.appendUInt32(UInt32(codeLimit))
        blob += [32, 2, 0, 12]                // hashSize, hashType SHA-256, platform, log2(pageSize)
        blob.appendUInt32(0)                  // spare2
        blob.appendUInt32(0)                  // scatterOffset
        blob.appendUInt32(UInt32(teamOffset))
        blob.appendUInt32(0)                  // spare3
        blob.appendUInt64(0)                  // codeLimit64
        blob.appendUInt64(execSegBase)
        blob.appendUInt64(execSegLimit)
        blob.appendUInt64(0)                  // execSegFlags (a dylib, not the main binary)
        precondition(blob.count == codeDirectoryHeaderLength)
        blob += Array(identifier.utf8) + [0]
        blob += Array(teamID.utf8) + [0]
        blob += requirementsHash               // slot -2
        blob += [UInt8](repeating: 0, count: 32) // slot -1
        blob += pageHashes
        return blob
    }

    private static func emptyRequirements() -> [UInt8] {
        var blob: [UInt8] = []
        blob.appendUInt32(0xFADE_0C01)
        blob.appendUInt32(12)
        blob.appendUInt32(0)
        return blob
    }

    // MARK: CMS

    private static let sha256OID = "2.16.840.1.101.3.4.2.1"

    /// A detached CMS SignedData over the CodeDirectory, with Apple's cdhash attributes.
    private func cmsSignature(over codeDirectory: [UInt8]) throws -> [UInt8] {
        guard let leafDER = certificates.first else { throw Failure.signing("no certificate") }
        let leaf = try CertificateInfo(der: leafDER)
        let cdHash = Array(SHA256.hash(data: codeDirectory))

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["cdhashes": [Data(cdHash.prefix(20))]],
            format: .xml,
            options: 0
        )
        let sha256 = DER.sequence([DER.oid(Self.sha256OID)])

        let attributes: [[UInt8]] = [
            DER.sequence([DER.oid("1.2.840.113549.1.9.3"), DER.set([DER.oid("1.2.840.113549.1.7.1")])]), // contentType: data
            DER.sequence([DER.oid("1.2.840.113549.1.9.5"), DER.set([DER.utcTime(Date())])]),             // signingTime
            DER.sequence([DER.oid("1.2.840.113549.1.9.4"), DER.set([DER.octetString(cdHash)])]),         // messageDigest
            DER.sequence([DER.oid("1.2.840.113635.100.9.1"), DER.set([DER.octetString(Array(plist))])]), // Apple cdhashes plist
            DER.sequence([DER.oid("1.2.840.113635.100.9.2"), DER.set([DER.sequence([DER.oid(Self.sha256OID), DER.octetString(cdHash)])])]),
        ]
        // The signature covers the attributes encoded as a SET; in SignerInfo they appear as [0] IMPLICIT.
        let signedAttributes = DER.set(attributes)

        let (signatureAlgorithm, algorithm): ([UInt8], SecKeyAlgorithm)
        let keyAttributes = SecKeyCopyAttributes(privateKey) as? [String: Any]
        let keyType = keyAttributes?[kSecAttrKeyType as String] as? String
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            signatureAlgorithm = DER.sequence([DER.oid("1.2.840.10045.4.3.2")])
            algorithm = .ecdsaSignatureMessageX962SHA256
        } else {
            signatureAlgorithm = DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.null])
            algorithm = .rsaSignatureMessagePKCS1v15SHA256
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, Data(signedAttributes) as CFData, &error) as Data? else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw Failure.signing(reason)
        }

        var implicitAttributes = signedAttributes
        implicitAttributes[0] = 0xA0

        let signerInfo = DER.sequence([
            DER.integer(1),
            DER.sequence([leaf.issuer, leaf.serialNumber]),
            sha256,
            implicitAttributes,
            signatureAlgorithm,
            DER.octetString(Array(signature)),
        ])
        let signedData = DER.sequence([
            DER.integer(1),
            DER.set([sha256]),
            DER.sequence([DER.oid("1.2.840.113549.1.7.1")]), // detached content
            DER.tlv(0xA0, certificates.flatMap { $0 }),        // [0] IMPLICIT certificates
            DER.set([signerInfo]),
        ])
        return DER.sequence([DER.oid("1.2.840.113549.1.7.2"), DER.explicit(0, signedData)])
    }

    private static func align(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}

// MARK: Byte helpers (Mach-O fields are little-endian, code signature blobs big-endian)

private extension Array where Element == UInt8 {
    func readUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << (8 * $1) }
    }

    func readUInt64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[offset + $1]) << (8 * $1) }
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[offset + index] = UInt8((value >> (8 * index)) & 0xFF) }
    }

    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        for index in 0..<8 { self[offset + index] = UInt8((value >> (8 * index)) & 0xFF) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) })
    }

    mutating func appendUInt64(_ value: UInt64) {
        append(contentsOf: [56, 48, 40, 32, 24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) })
    }
}
