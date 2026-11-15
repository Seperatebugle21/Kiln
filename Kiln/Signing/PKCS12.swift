import CommonCrypto
import CryptoKit
import Foundation

/// A PKCS #12 (.p12) reader for files that `SecPKCS12Import` rejects with errSecDecode, typically
/// because of their encryption (old RC2/3DES, or AES with PBKDF2, depending on the iOS version).
///
/// Supports the encryptions OpenSSL and Keychain Access write: pbeWithSHAAnd40BitRC2-CBC,
/// pbeWithSHAAnd128BitRC2-CBC, pbeWithSHAAnd3-KeyTripleDES-CBC and PBES2 (PBKDF2 with HMAC-SHA1 or
/// HMAC-SHA256, AES-128/192/256-CBC or 3DES-CBC). Accepts BER (indefinite lengths, constructed
/// octet strings). Only RSA keys, which is what Apple issues for code signing.
enum PKCS12 {
    struct Contents {
        /// The RSA private key as PKCS #1 RSAPrivateKey DER.
        var rsaPrivateKey: Data
        /// All certificates in the file, DER.
        var certificates: [[UInt8]]
    }

    enum Failure: LocalizedError {
        case malformed(String)
        case wrongPassword
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let detail): return "The .p12 file could not be read (\(detail))."
            case .wrongPassword: return "The password for this certificate is wrong."
            case .unsupported(let detail): return "This .p12 file uses an unsupported \(detail)."
            }
        }
    }

    static func parse(_ data: Data, password: String) throws -> Contents {
        let pfx = try BER.element(in: [UInt8](data)[...])
        let parts = pfx.children
        guard parts.count >= 2 else { throw Failure.malformed("no content") }
        let authSafeBytes = try dataContent(of: parts[1])
        if parts.count >= 3 {
            try verifyMAC(parts[2], content: authSafeBytes, password: password)
        }
        let authSafe = try BER.element(in: authSafeBytes[...])

        var keys: [Data] = []
        var certificates: [[UInt8]] = []
        for contentInfo in authSafe.children {
            let fields = contentInfo.children
            guard fields.count >= 2 else { continue }
            let type = fields[0].oid
            var safeContents: [UInt8]
            if type == "1.2.840.113549.1.7.1" {
                safeContents = try octets(of: fields[1].children.first)
            } else if type == "1.2.840.113549.1.7.6" {
                // EncryptedData: version, EncryptedContentInfo { type, algorithm, [0] content }
                guard let encryptedData = fields[1].children.first,
                      encryptedData.children.count >= 2 else { throw Failure.malformed("encrypted data") }
                let info = encryptedData.children[1].children
                guard info.count >= 3 else { throw Failure.malformed("encrypted content info") }
                safeContents = try decrypt(BER.flattenedOctets(info[2]), algorithm: info[1], password: password)
            } else {
                continue
            }
            let bags = try BER.element(in: safeContents[...])
            for bag in bags.children {
                try read(bag, password: password, keys: &keys, certificates: &certificates)
            }
        }
        guard let key = keys.first else { throw Failure.malformed("no private key") }
        return Contents(rsaPrivateKey: key, certificates: certificates)
    }

    private static func read(_ bag: BER.Element, password: String, keys: inout [Data], certificates: inout [[UInt8]]) throws {
        let fields = bag.children
        guard fields.count >= 2, let value = fields[1].children.first else { return }
        switch fields[0].oid {
        case "1.2.840.113549.1.12.10.1.1": // keyBag: PrivateKeyInfo
            keys.append(try rsaKey(fromPKCS8: Array(value.encoded)))
        case "1.2.840.113549.1.12.10.1.2": // pkcs8ShroudedKeyBag: EncryptedPrivateKeyInfo
            let parts = value.children
            guard parts.count >= 2 else { throw Failure.malformed("encrypted key") }
            let pkcs8 = try decrypt(BER.flattenedOctets(parts[1]), algorithm: parts[0], password: password)
            keys.append(try rsaKey(fromPKCS8: pkcs8))
        case "1.2.840.113549.1.12.10.1.3": // certBag: { x509Certificate, [0] OCTET STRING }
            let parts = value.children
            if parts.count >= 2, parts[0].oid == "1.2.840.113549.1.9.22.1" {
                certificates.append(try octets(of: parts[1].children.first))
            }
        default:
            break
        }
    }

    private static func rsaKey(fromPKCS8 bytes: [UInt8]) throws -> Data {
        // PrivateKeyInfo: version, AlgorithmIdentifier, OCTET STRING privateKey
        let info = try BER.element(in: bytes[...]).children
        guard info.count >= 3 else { throw Failure.wrongPassword }
        guard info[1].children.first?.oid == "1.2.840.113549.1.1.1" else {
            throw Failure.unsupported("key type (only RSA keys are supported)")
        }
        return Data(try BER.flattenedOctets(info[2]))
    }

    // MARK: Decryption

    private static func decrypt(_ ciphertext: [UInt8], algorithm: BER.Element, password: String) throws -> [UInt8] {
        let parts = algorithm.children
        guard let oid = parts.first?.oid else { throw Failure.malformed("algorithm") }
        let parameters = parts.count > 1 ? parts[1].children : []

        switch oid {
        case "1.2.840.113549.1.12.1.3", "1.2.840.113549.1.12.1.6", "1.2.840.113549.1.12.1.5":
            // PKCS #12 PBE: SEQUENCE { salt, iterations }
            guard parameters.count >= 2 else { throw Failure.malformed("PBE parameters") }
            let salt = Array(parameters[0].content)
            let iterations = parameters[1].integer
            let password = bmpPassword(password)
            let (cipher, keyLength, blockSize): (CCAlgorithm, Int, Int)
            switch oid {
            case "1.2.840.113549.1.12.1.3": (cipher, keyLength, blockSize) = (CCAlgorithm(kCCAlgorithm3DES), 24, 8)
            case "1.2.840.113549.1.12.1.6": (cipher, keyLength, blockSize) = (CCAlgorithm(kCCAlgorithmRC2), 5, 8)
            default: (cipher, keyLength, blockSize) = (CCAlgorithm(kCCAlgorithmRC2), 16, 8)
            }
            let key = pkcs12KDF(password: password, salt: salt, id: 1, iterations: iterations, length: keyLength)
            let iv = pkcs12KDF(password: password, salt: salt, id: 2, iterations: iterations, length: blockSize)
            return try cbcDecrypt(ciphertext, cipher: cipher, key: key, iv: iv)

        case "1.2.840.113549.1.5.13":
            // PBES2: { keyDerivationFunc (PBKDF2), encryptionScheme }
            guard parameters.count >= 2 else { throw Failure.malformed("PBES2 parameters") }
            let kdf = parameters[0].children
            guard kdf.first?.oid == "1.2.840.113549.1.5.12", kdf.count >= 2 else {
                throw Failure.unsupported("key derivation")
            }
            let kdfParameters = kdf[1].children
            guard kdfParameters.count >= 2 else { throw Failure.malformed("PBKDF2 parameters") }
            let salt = Array(kdfParameters[0].content)
            let iterations = kdfParameters[1].integer
            var prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            for extra in kdfParameters.dropFirst(2) where extra.tag == 0x30 {
                switch extra.children.first?.oid {
                case "1.2.840.113549.2.9": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
                case "1.2.840.113549.2.10": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
                case "1.2.840.113549.2.11": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
                default: break
                }
            }

            let scheme = parameters[1].children
            guard let schemeOID = scheme.first?.oid, scheme.count >= 2 else { throw Failure.malformed("encryption scheme") }
            let iv = Array(scheme[1].content)
            let (cipher, keyLength): (CCAlgorithm, Int)
            switch schemeOID {
            case "2.16.840.1.101.3.4.1.2": (cipher, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 16)
            case "2.16.840.1.101.3.4.1.22": (cipher, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 24)
            case "2.16.840.1.101.3.4.1.42": (cipher, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 32)
            case "1.2.840.113549.3.7": (cipher, keyLength) = (CCAlgorithm(kCCAlgorithm3DES), 24)
            default: throw Failure.unsupported("encryption (\(schemeOID))")
            }
            let key = pbkdf2(password: Array(password.utf8), salt: salt, iterations: iterations, prf: prf, length: keyLength)
            return try cbcDecrypt(ciphertext, cipher: cipher, key: key, iv: iv)

        default:
            throw Failure.unsupported("encryption (\(oid))")
        }
    }

    private static func cbcDecrypt(_ input: [UInt8], cipher: CCAlgorithm, key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count + 32)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), cipher, CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, input, input.count, &output, output.count, &moved
        )
        // A wrong password yields a wrong key, which shows up as a padding error.
        guard status == CCCryptorStatus(kCCSuccess) else { throw Failure.wrongPassword }
        return Array(output.prefix(moved))
    }

    private static func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int, prf: CCPseudoRandomAlgorithm, length: Int) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: length)
        let passwordString = password.map { CChar(bitPattern: $0) }
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), passwordString, password.count, salt, salt.count,
            prf, UInt32(iterations), &key, length
        )
        return key
    }

    /// The password as a BMPString (UTF-16 big-endian) with a terminating zero, as PKCS #12 PBE uses it.
    private static func bmpPassword(_ password: String) -> [UInt8] {
        password.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } + [0, 0]
    }

    /// Checks the password with the file's MAC (HMAC over the content, key from the PKCS #12 KDF).
    private static func verifyMAC(_ macData: BER.Element, content: [UInt8], password: String) throws {
        let fields = macData.children
        guard fields.count >= 2, let digestInfo = Optional(fields[0].children), digestInfo.count >= 2,
              let algorithm = digestInfo[0].children.first?.oid
        else { return }
        let expected = Array(digestInfo[1].content)
        let salt = Array(fields[1].content)
        let iterations = fields.count >= 3 ? fields[2].integer : 1
        let bmp = bmpPassword(password)

        let actual: [UInt8]
        switch algorithm {
        case "1.3.14.3.2.26":
            let key = pkcs12KDF(password: bmp, salt: salt, id: 3, iterations: iterations, length: 20, hash: { Array(Insecure.SHA1.hash(data: $0)) })
            actual = Array(HMAC<Insecure.SHA1>.authenticationCode(for: content, using: SymmetricKey(data: key)))
        case "2.16.840.1.101.3.4.2.1":
            let key = pkcs12KDF(password: bmp, salt: salt, id: 3, iterations: iterations, length: 32, hash: { Array(SHA256.hash(data: $0)) })
            actual = Array(HMAC<SHA256>.authenticationCode(for: content, using: SymmetricKey(data: key)))
        default:
            return // Unknown MAC: rely on decryption to detect a wrong password.
        }
        guard actual == expected else { throw Failure.wrongPassword }
    }

    /// RFC 7292 appendix B key derivation (SHA-1 unless another hash is given; v = 64 bytes).
    private static func pkcs12KDF(
        password: [UInt8], salt: [UInt8], id: UInt8, iterations: Int, length: Int,
        hash: ([UInt8]) -> [UInt8] = { Array(Insecure.SHA1.hash(data: $0)) }
    ) -> [UInt8] {
        let v = 64
        let diversifier = [UInt8](repeating: id, count: v)
        func stretch(_ bytes: [UInt8]) -> [UInt8] {
            guard !bytes.isEmpty else { return [] }
            let count = v * ((bytes.count + v - 1) / v)
            return (0..<count).map { bytes[$0 % bytes.count] }
        }
        var input = stretch(salt) + stretch(password)
        var result: [UInt8] = []
        while result.count < length {
            var block = hash(diversifier + input)
            for _ in 1..<max(iterations, 1) {
                block = hash(block)
            }
            result += block
            guard result.count < length else { break }
            let b = stretch(block)
            for start in stride(from: 0, to: input.count, by: v) {
                var carry = 1
                for index in stride(from: v - 1, through: 0, by: -1) {
                    let sum = Int(input[start + index]) + Int(b[index]) + carry
                    input[start + index] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
        }
        return Array(result.prefix(length))
    }

    // MARK: Helpers

    /// The content of a ContentInfo of type data: [0] EXPLICIT OCTET STRING.
    private static func dataContent(of contentInfo: BER.Element) throws -> [UInt8] {
        let fields = contentInfo.children
        guard fields.count >= 2, fields[0].oid == "1.2.840.113549.1.7.1" else { throw Failure.malformed("not a data container") }
        return try octets(of: fields[1].children.first)
    }

    private static func octets(of element: BER.Element?) throws -> [UInt8] {
        guard let element else { throw Failure.malformed("missing octet string") }
        return try BER.flattenedOctets(element)
    }
}

/// BER decoding: like DER, plus indefinite lengths and constructed (segmented) octet strings.
enum BER {
    struct Element {
        let tag: UInt8
        let encoded: ArraySlice<UInt8>
        let content: ArraySlice<UInt8>
        let isIndefinite: Bool

        var isConstructed: Bool { tag & 0x20 != 0 }

        var children: [Element] {
            guard isConstructed else { return [] }
            return (try? BER.elements(in: content)) ?? []
        }

        var oid: String? {
            guard tag == 0x06, let first = content.first else { return nil }
            var arcs = [Int(first) / 40, Int(first) % 40]
            var value = 0
            for byte in content.dropFirst() {
                value = (value << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 {
                    arcs.append(value)
                    value = 0
                }
            }
            return arcs.map(String.init).joined(separator: ".")
        }

        var integer: Int {
            content.reduce(0) { ($0 << 8) | Int($1) }
        }
    }

    struct DecodingError: Error {}

    static func element(in bytes: ArraySlice<UInt8>) throws -> Element {
        var index = bytes.startIndex
        guard index < bytes.endIndex else { throw DecodingError() }
        let tag = bytes[index]
        index += 1
        guard index < bytes.endIndex else { throw DecodingError() }
        let first = Int(bytes[index])
        index += 1

        if first == 0x80 {
            // Indefinite length: children until an end-of-contents marker (00 00).
            let contentStart = index
            var cursor = index
            while true {
                guard cursor + 1 < bytes.endIndex else { throw DecodingError() }
                if bytes[cursor] == 0, bytes[cursor + 1] == 0 { break }
                let child = try element(in: bytes[cursor...])
                cursor = child.encoded.endIndex
            }
            return Element(tag: tag, encoded: bytes[bytes.startIndex..<(cursor + 2)], content: bytes[contentStart..<cursor], isIndefinite: true)
        }

        var count = first
        if first & 0x80 != 0 {
            let lengthBytes = first & 0x7F
            guard lengthBytes > 0, lengthBytes <= 4, index + lengthBytes <= bytes.endIndex else { throw DecodingError() }
            count = 0
            for _ in 0..<lengthBytes {
                count = (count << 8) | Int(bytes[index])
                index += 1
            }
        }
        guard index + count <= bytes.endIndex else { throw DecodingError() }
        return Element(tag: tag, encoded: bytes[bytes.startIndex..<(index + count)], content: bytes[index..<(index + count)], isIndefinite: false)
    }

    static func elements(in bytes: ArraySlice<UInt8>) throws -> [Element] {
        var result: [Element] = []
        var rest = bytes
        while !rest.isEmpty {
            let next = try element(in: rest)
            result.append(next)
            rest = rest[next.encoded.endIndex...]
        }
        return result
    }

    /// The bytes of an OCTET STRING (or an implicitly tagged one), joining constructed segments.
    static func flattenedOctets(_ element: Element) throws -> [UInt8] {
        if element.isConstructed {
            return try element.children.flatMap { try flattenedOctets($0) }
        }
        return Array(element.content)
    }
}
