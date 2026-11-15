import Compression
import Foundation

/// Extracts .tar.gz archives, such as GitHub's source tarballs of Swift packages.
/// iOS has no public tar API, so this reads gzip with the Compression framework and tar by hand.
enum TarGzip {
    enum Failure: LocalizedError {
        case notGzip
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notGzip: return "The download is not a gzip archive."
            case .corrupt(let detail): return "The archive is damaged (\(detail))."
            }
        }
    }

    /// Extracts `archive` into `destination`. With `stripComponents`, leading path components are
    /// removed (GitHub tarballs put everything in one `owner-repo-sha/` folder).
    static func extract(_ archive: Data, to destination: URL, stripComponents: Int = 0) throws {
        let tar = try gunzip(archive)
        try untar(tar, to: destination, stripComponents: stripComponents)
    }

    // MARK: gzip

    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw Failure.notGzip }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw Failure.corrupt("header") }
            offset += 2 + (Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8))
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < bytes.count - 8 else { throw Failure.corrupt("header") }

        // The raw DEFLATE stream (COMPRESSION_ZLIB is raw deflate without a zlib header).
        let deflated = Array(bytes[offset..<(bytes.count - 8)])
        return try inflate(deflated)
    }

    static func inflate(_ input: [UInt8]) throws -> Data {
        var output = Data()
        let bufferSize = 1 << 16
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var stream = compression_stream(dst_ptr: destination, dst_size: 0, src_ptr: destination, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.corrupt("cannot start decompression")
        }
        defer { compression_stream_destroy(&stream) }

        try input.withUnsafeBufferPointer { source in
            stream.src_ptr = source.baseAddress!
            stream.src_size = source.count
            while true {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(destination, count: bufferSize - stream.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return
                default: throw Failure.corrupt("deflate data")
                }
            }
        }
        return output
    }

    // MARK: tar

    private static func untar(_ data: Data, to destination: URL, stripComponents: Int) throws {
        let bytes = [UInt8](data)
        let fileManager = FileManager.default
        var offset = 0
        var longName: String?
        var longLink: String?

        func field(_ start: Int, _ length: Int) -> String {
            let slice = bytes[(offset + start)..<(offset + start + length)]
            return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
        }
        func octal(_ start: Int, _ length: Int) -> Int {
            Int(field(start, length).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
        }

        while offset + 512 <= bytes.count {
            if bytes[offset..<(offset + 512)].allSatisfy({ $0 == 0 }) { break } // end of archive
            var name = field(0, 100)
            let prefix = field(345, 155)
            if !prefix.isEmpty, field(257, 5) == "ustar" { name = prefix + "/" + name }
            let size = octal(124, 12)
            let type = bytes[offset + 156]
            // Read before `offset` moves on to the next header.
            var linkTarget = field(157, 100)
            let contentStart = offset + 512
            guard contentStart + size <= bytes.count else { throw Failure.corrupt("truncated entry") }
            let content = bytes[contentStart..<(contentStart + size)]
            offset = contentStart + (size + 511) / 512 * 512

            switch type {
            case UInt8(ascii: "L"): // GNU long name
                longName = String(decoding: content.prefix { $0 != 0 }, as: UTF8.self)
                continue
            case UInt8(ascii: "x"): // PAX extended header: "len path=value\n"
                for record in String(decoding: content, as: UTF8.self).split(separator: "\n") {
                    if let range = record.range(of: " path=") {
                        longName = String(record[range.upperBound...])
                    }
                    if let range = record.range(of: " linkpath=") {
                        longLink = String(record[range.upperBound...])
                    }
                }
                continue
            case UInt8(ascii: "g"): // PAX global header (GitHub puts the commit here)
                continue
            default:
                break
            }
            if let override = longName {
                name = override
                longName = nil
            }
            if let override = longLink {
                linkTarget = override
                longLink = nil
            }

            let components = name.split(separator: "/").dropFirst(stripComponents)
            guard !components.isEmpty, !components.contains("..") else { continue }
            let target = components.reduce(destination) { $0.appendingPathComponent(String($1)) }

            switch type {
            case UInt8(ascii: "5"):
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content).write(to: target)
            case UInt8(ascii: "2"):
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.removeItem(at: target)
                try? fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
            default:
                continue
            }
        }
    }
}
