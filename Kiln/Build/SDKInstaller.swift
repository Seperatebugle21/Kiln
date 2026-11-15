import AppleArchive
import Foundation
import System

/// Extracts the bundled iOS SDK archive (Toolchain/iPhoneOS.sdk.aar) once into Application Support.
///
/// The SDK ships as one archive because, as a folder, its many .framework directories (headers and
/// .tbd stubs without binaries) make third-party signers fail when they try to sign them as bundles.
enum SDKInstaller {
    enum Failure: LocalizedError {
        case missingArchive
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingArchive:
                return "This build of Kiln does not contain the iOS SDK archive."
            case .extractionFailed(let reason):
                return "Could not unpack the iOS SDK: \(reason)"
            }
        }
    }

    /// The extracted SDK, unpacking it first if this version is not there yet.
    static func sdk(in toolchain: URL, log: (String) -> Void) throws -> URL {
        let archive = toolchain.appendingPathComponent("iPhoneOS.sdk.aar")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path),
              let size = attributes[.size] as? NSNumber
        else { throw Failure.missingArchive }

        // A new Kiln build with a different SDK gets its own folder.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("KilnSDK", isDirectory: true)
        let folder = root.appendingPathComponent("sdk-\(size.int64Value)", isDirectory: true)
        let sdk = folder.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        let marker = folder.appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: marker.path) {
            return sdk
        }

        log("Unpacking the iOS SDK (first build only)…")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try extract(archive, to: folder)
        guard FileManager.default.fileExists(atPath: sdk.appendingPathComponent("SDKSettings.json").path) else {
            throw Failure.extractionFailed("the archive does not contain iPhoneOS.sdk")
        }
        FileManager.default.createFile(atPath: marker.path, contents: nil)

        // Recreated from the app whenever needed, so keep it out of backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)
        return sdk
    }

    private static func extract(_ archive: URL, to destination: URL) throws {
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(archive.path),
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw Failure.extractionFailed("cannot open the archive") }
        defer { try? file.close() }

        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else {
            throw Failure.extractionFailed("cannot decompress the archive")
        }
        defer { try? decompressed.close() }

        guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else {
            throw Failure.extractionFailed("cannot read the archive")
        }
        defer { try? decoder.close() }

        guard let extractor = ArchiveStream.extractStream(
            extractingTo: FilePath(destination.path),
            flags: [.ignoreOperationNotPermitted]
        ) else { throw Failure.extractionFailed("cannot write to \(destination.lastPathComponent)") }
        defer { try? extractor.close() }

        do {
            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
        } catch {
            throw Failure.extractionFailed(error.localizedDescription)
        }
    }
}
