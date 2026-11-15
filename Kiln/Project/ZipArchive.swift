import Foundation

/// Extracts .zip archives. A .swiftpm or project that was downloaded, mailed or AirDropped
/// often arrives as one zipped file instead of a folder.
enum ZipArchive {
    enum Failure: LocalizedError {
        case notZip
        case corrupt(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notZip: return "The file is not a zip archive."
            case .corrupt(let detail): return "The zip archive is damaged (\(detail))."
            case .unsupported(let detail): return "This zip archive is not supported (\(detail))."
            }
        }
    }

    static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
    }

    /// Extracts every entry of `archive` into `destination`, skipping macOS metadata.
    static func extract(_ archive: URL, to destination: URL) throws {
        let bytes = [UInt8](try Data(contentsOf: archive, options: .mappedIfSafe))
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        // Find the end-of-central-directory record (it can be followed by a comment).
        guard bytes.count >= 22 else { throw Failure.notZip }
        var end = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while end >= lowest, u32(end) != 0x0605_4B50 { end -= 1 }
        guard end >= lowest else { throw Failure.notZip }
        let count = u16(end + 10)
        var offset = u32(end + 16)
        guard count != 0xFFFF, offset != 0xFFFF_FFFF else { throw Failure.unsupported("zip64") }

        let fileManager = FileManager.default
        let base = destination.standardizedFileURL.path
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4B50 else { throw Failure.corrupt("central directory") }
            let flags = u16(offset + 8)
            let method = u16(offset + 10)
            let compressedSize = u32(offset + 20)
            let size = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let externalAttributes = u32(offset + 38)
            let localHeader = u32(offset + 42)
            guard offset + 46 + nameLength <= bytes.count else { throw Failure.corrupt("entry name") }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            let components = name.split(separator: "/").map(String.init)
            if components.isEmpty || components.contains("__MACOSX") || components.last?.hasPrefix("._") == true
                || components.last == ".DS_Store" {
                continue
            }
            guard !components.contains(".."), flags & 0x1 == 0 else {
                if flags & 0x1 != 0 { throw Failure.unsupported("encrypted") }
                continue
            }
            let target = destination.appendingPathComponent(components.joined(separator: "/"))
            guard target.standardizedFileURL.path.hasPrefix(base + "/") else { continue }

            let unixMode = (externalAttributes >> 16) & 0o170000
            if name.hasSuffix("/") || unixMode == 0o040000 {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            if unixMode == 0o120000 { continue } // Symbolic links are left out.

            guard localHeader + 30 <= bytes.count, u32(localHeader) == 0x0403_4B50 else { throw Failure.corrupt("local header") }
            let dataStart = localHeader + 30 + u16(localHeader + 26) + u16(localHeader + 28)
            guard dataStart + compressedSize <= bytes.count else { throw Failure.corrupt(name) }
            let payload = Array(bytes[dataStart..<(dataStart + compressedSize)])

            let contents: Data
            switch method {
            case 0: contents = Data(payload)
            case 8: contents = size == 0 ? Data() : try TarGzip.inflate(payload)
            default: throw Failure.unsupported("compression method \(method)")
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target)
        }
    }

    /// Extracts a zipped project into Kiln's own Projects folder and returns the folder to open.
    /// An archive holding one top-level folder (`MyApp.swiftpm/…`) yields that folder.
    static func importProject(_ archive: URL, into projectsFolder: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging = projectsFolder.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        try extract(archive, to: staging)

        let entries = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var source = staging
        var name = archive.lastPathComponent
        if name.lowercased().hasSuffix(".zip") { name = String(name.dropLast(4)) }
        if entries.count == 1, (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            source = entries[0]
            name = entries[0].lastPathComponent
        }

        let fileExtension = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var target = projectsFolder.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: target.path) {
            let numbered = fileExtension.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(fileExtension)"
            target = projectsFolder.appendingPathComponent(numbered, isDirectory: true)
            index += 1
        }
        try fileManager.moveItem(at: source, to: target)
        return target
    }
}
