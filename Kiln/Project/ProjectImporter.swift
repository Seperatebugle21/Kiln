import Foundation

/// Copies a project from the Files app (iCloud Drive, another app, a USB drive…) into Kiln's
/// own Projects folder. Access to files outside Kiln can be lost between launches, and some
/// locations cannot be bookmarked at all, so Kiln works on its own copy, which always reopens.
enum ProjectImporter {
    enum Failure: LocalizedError {
        case notAProject(String)

        var errorDescription: String? {
            switch self {
            case .notAProject(let name): return "\(name) is not a folder or a zip archive, so Kiln cannot open it as a project."
            }
        }
    }

    /// Folders that are rebuilt anyway and can be large.
    static let skippedNames: Set<String> = [".build", "build", "DerivedData", "node_modules", ".DS_Store"]

    private static let markerFolder = ".kiln"
    private static let markerFile = "source"

    /// Copies `source` (a folder or a zipped project) and returns the copy. A project that was
    /// copied before from the same place opens its existing copy, so your changes there stay.
    static func importProject(_ source: URL, into projects: URL) throws -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if !exists || !isDirectory.boolValue {
            guard ZipArchive.isZip(source) else { throw Failure.notAProject(source.lastPathComponent) }
            return try ZipArchive.importProject(source, into: projects)
        }

        let sourcePath = source.standardizedFileURL.path
        if let existing = existingCopy(of: sourcePath, in: projects) { return existing }

        let name = source.lastPathComponent
        let fileExtension = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var target = projects.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: target.path) {
            let numbered = fileExtension.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(fileExtension)"
            target = projects.appendingPathComponent(numbered, isDirectory: true)
            index += 1
        }

        let staging = projects.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        do {
            // A coordinated read makes file providers (iCloud Drive and others) hand over current files.
            var placeholders = 0
            try coordinatedRead(source, options: []) { url in
                try copyFolder(url, to: staging, placeholders: &placeholders)
            }
            if placeholders > 0 {
                // Some files were not downloaded. Reading "for uploading" makes the provider deliver
                // the whole folder (as a zip), downloading what is missing.
                try? fileManager.removeItem(at: staging)
                try coordinatedRead(source, options: .forUploading) { zip in
                    let unpacked = projects.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
                    defer { try? fileManager.removeItem(at: unpacked) }
                    try ZipArchive.extract(zip, to: unpacked)
                    let entries = try fileManager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    let root = entries.count == 1 ? entries[0] : unpacked
                    try fileManager.moveItem(at: root, to: staging)
                }
            }
            let marker = staging.appendingPathComponent(markerFolder, isDirectory: true)
            try fileManager.createDirectory(at: marker, withIntermediateDirectories: true)
            try sourcePath.write(to: marker.appendingPathComponent(markerFile), atomically: true, encoding: .utf8)
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return target
    }

    /// Where a copy came from, if Kiln imported it.
    static func originalLocation(of project: URL) -> String? {
        try? String(contentsOf: project.appendingPathComponent(markerFolder).appendingPathComponent(markerFile), encoding: .utf8)
    }

    private static func existingCopy(of sourcePath: String, in projects: URL) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.first { originalLocation(of: $0) == sourcePath }
    }

    private static func coordinatedRead(_ url: URL, options: NSFileCoordinator.ReadingOptions, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: options, error: &coordinationError) { readURL in
            do { try body(readURL) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    private static func copyFolder(_ source: URL, to destination: URL, placeholders: inout Int) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) where !skippedNames.contains(name) {
            let child = source.appendingPathComponent(name)
            // iCloud files that are not downloaded yet show up as ".name.icloud" placeholders.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                placeholders += 1
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try copyFolder(child, to: destination.appendingPathComponent(name), placeholders: &placeholders)
            } else {
                try fileManager.copyItem(at: child, to: destination.appendingPathComponent(name))
            }
        }
    }
}
