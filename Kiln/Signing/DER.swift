import Foundation

/// Minimal DER (ASN.1) encoding and decoding, enough to read certificates and write CMS signatures.
enum DER {
    // MARK: Encoding

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] {
        tlv(0x30, items.flatMap { $0 })
    }

    /// A DER SET OF: elements sorted by their encoding.
    static func set(_ items: [[UInt8]]) -> [UInt8] {
        tlv(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 })
    }

    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }

    static let null: [UInt8] = [0x05, 0x00]

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        precondition(arcs.count >= 2, "invalid OID \(dotted)")
        var body: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var value = arc >> 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            body += chunk
        }
        return tlv(0x06, body)
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(formatter.string(from: date).utf8))
    }

    /// `[n]` EXPLICIT (constructed, context-specific).
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        tlv(0xA0 | number, content)
    }

    // MARK: Decoding

    struct Element {
        let tag: UInt8
        /// The whole element: tag, length and content.
        let encoded: ArraySlice<UInt8>
        let content: ArraySlice<UInt8>

        var children: [Element] { (try? DER.elements(in: content)) ?? [] }
    }

    struct DecodingError: Error {}

    static func element(in bytes: ArraySlice<UInt8>) throws -> Element {
        var index = bytes.startIndex
        guard index < bytes.endIndex else { throw DecodingError() }
        let tag = bytes[index]
        index += 1
        guard index < bytes.endIndex else { throw DecodingError() }
        var count = Int(bytes[index])
        index += 1
        if count & 0x80 != 0 {
            let lengthBytes = count & 0x7F
            guard lengthBytes > 0, lengthBytes <= 4, index + lengthBytes <= bytes.endIndex else { throw DecodingError() }
            count = 0
            for _ in 0..<lengthBytes {
                count = (count << 8) | Int(bytes[index])
                index += 1
            }
        }
        guard index + count <= bytes.endIndex else { throw DecodingError() }
        return Element(tag: tag, encoded: bytes[bytes.startIndex..<(index + count)], content: bytes[index..<(index + count)])
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
}

/// The parts of an X.509 certificate that code signing needs.
struct CertificateInfo {
    let der: [UInt8]
    /// Full DER encodings of the issuer and subject names and the serial number.
    let issuer: [UInt8]
    let subject: [UInt8]
    let serialNumber: [UInt8]
    /// The subject's organizational unit, which is the Apple Team ID on signing certificates.
    let organizationalUnit: String?
    let commonName: String?

    init(der: [UInt8]) throws {
        self.der = der
        let certificate = try DER.element(in: der[...])
        guard let tbs = certificate.children.first else { throw DER.DecodingError() }
        var fields = tbs.children
        if fields.first?.tag == 0xA0 { fields.removeFirst() } // [0] version
        guard fields.count >= 5 else { throw DER.DecodingError() }
        serialNumber = Array(fields[0].encoded)
        issuer = Array(fields[2].encoded)
        subject = Array(fields[4].encoded)
        organizationalUnit = Self.attribute("2.5.4.11", in: fields[4])
        commonName = Self.attribute("2.5.4.3", in: fields[4])
    }

    private static func attribute(_ oid: String, in name: DER.Element) -> String? {
        let wanted = Array(DER.oid(oid))
        for relativeName in name.children {
            for pair in relativeName.children {
                let parts = pair.children
                guard parts.count == 2, Array(parts[0].encoded) == wanted else { continue }
                return String(decoding: parts[1].content, as: UTF8.self)
            }
        }
        return nil
    }
}
