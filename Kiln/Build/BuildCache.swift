import CryptoKit
import Foundation

/// Where compiled package code is kept between builds (in Caches, so iOS may clear it when space
/// runs low; it is rebuilt then). Entries are named by a hash of everything that went into them:
/// the source files (path, size, modification date), the compiler flags and Kiln's own build.
struct BuildCache {
    let root: URL

    init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KilnBuildCache", isDirectory: true)
    }

    var objects: URL { root.appendingPathComponent("Objects", isDirectory: true) }
    var modules: URL { root.appendingPathComponent("Modules", isDirectory: true) }
    var moduleMaps: URL { root.appendingPathComponent("ModuleMaps", isDirectory: true) }
    var generated: URL { root.appendingPathComponent("Generated", isDirectory: true) }
    var dylibs: URL { root.appendingPathComponent("Dylibs", isDirectory: true) }

    func prepare() throws {
        for folder in [objects, modules, moduleMaps, generated, dylibs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// A short hash of the parts plus Kiln's own build, so a new Kiln (with a new compiler) starts fresh.
    func key(_ parts: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(Self.kilnStamp.utf8))
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Path, size and modification date of each file.
    func fingerprint(_ files: [URL]) -> String {
        files.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? -1
            let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(url.path)|\(size)|\(date)"
        }.joined(separator: "\n")
    }

    private static let kilnStamp: String = {
        guard let executable = Bundle.main.executableURL,
              let values = try? executable.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return "unknown" }
        return "\(values.fileSize ?? 0)-\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }()
}
