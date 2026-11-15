import Foundation

/// Builds a target's resource bundle, as SwiftPM does for `resources: [...]`, and the
/// `Bundle.module` accessor that finds it.
///
/// Xcode compiles some resources with tools iOS does not have; Kiln converts them itself:
/// - String catalogs (.xcstrings) become `<language>.lproj/<Table>.strings`.
/// - Asset catalogs (.xcassets): images become loose files (`name.png`, `name@2x.png`), which
///   `UIImage(named:in:with:)` and `Image(_:bundle:)` find; colors and data assets are left out.
/// Everything else is copied. Bundles live in Caches and only changed files are copied again.
enum ResourceBundler {
    static var bundlesRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KilnBundles", isDirectory: true)
    }

    struct Result {
        var bundle: URL
        var warnings: [String]
    }

    static func build(name: String, items: [ResourceItem]) throws -> Result {
        let key = String(items.map(\.url.path).joined(separator: "|").hashValueStable, radix: 16)
        let bundle = bundlesRoot.appendingPathComponent("\(name)-\(key).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var warnings: [String] = []
        for item in items {
            if item.copy {
                try sync(item.url, to: bundle.appendingPathComponent(item.url.lastPathComponent))
            } else {
                try process(item.url, into: bundle, warnings: &warnings)
            }
        }
        return Result(bundle: bundle, warnings: warnings)
    }

    /// The `Bundle.module` SwiftPM generates for a target with resources.
    static func accessorSource(bundle: URL) -> String {
        """
        import Foundation

        extension Foundation.Bundle {
            /// The target's resources, built by Kiln.
            static let module: Bundle = Bundle(path: #"\(bundle.path)"#) ?? Bundle.main
        }

        """
    }

    // MARK: Processing

    private static func process(_ url: URL, into bundle: URL, warnings: inout [String]) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        switch url.pathExtension.lowercased() {
        case "xcstrings":
            try convertStringCatalog(url, into: bundle)
            return
        case "xcassets":
            try flattenAssetCatalog(url, into: bundle, warnings: &warnings)
            return
        case "lproj":
            try sync(url, to: bundle.appendingPathComponent(url.lastPathComponent))
            return
        case "storyboard", "xib", "xcdatamodeld", "xcdatamodel", "mlmodel", "metal":
            warnings.append("\(url.lastPathComponent): this kind of resource needs Xcode to compile; left out.")
            return
        default:
            break
        }
        if isDirectory.boolValue {
            // `.process("Resources")`: every file inside, flattened like SwiftPM does (except .lproj folders).
            let children = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in children {
                try process(child, into: bundle, warnings: &warnings)
            }
        } else {
            try sync(url, to: bundle.appendingPathComponent(url.lastPathComponent))
        }
    }

    /// Copies a file or folder, skipping files that are already up to date.
    private static func sync(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? []
            for child in children where child != ".DS_Store" {
                try sync(source.appendingPathComponent(child), to: destination.appendingPathComponent(child))
            }
            return
        }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        if let old = try? destination.resourceValues(forKeys: keys), let new = try? source.resourceValues(forKeys: keys),
           old.fileSize == new.fileSize, let oldDate = old.contentModificationDate, let newDate = new.contentModificationDate,
           oldDate >= newDate {
            return
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }

    // MARK: String catalogs

    /// `Localizable.xcstrings` → `en.lproj/Localizable.strings`, `nl.lproj/Localizable.strings`, …
    /// Plural and device variations use their "other" form.
    static func convertStringCatalog(_ url: URL, into bundle: URL) throws {
        let data = try Data(contentsOf: url)
        guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = catalog["strings"] as? [String: Any]
        else { return }
        let sourceLanguage = catalog["sourceLanguage"] as? String ?? "en"
        let table = url.deletingPathExtension().lastPathComponent
        var tables: [String: [String: String]] = [:]

        func value(of localization: [String: Any]) -> String? {
            if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                return value
            }
            if let variations = localization["variations"] as? [String: Any] {
                for kind in ["plural", "device"] {
                    if let forms = variations[kind] as? [String: Any],
                       let other = (forms["other"] ?? forms.values.first) as? [String: Any] {
                        return value(of: other)
                    }
                }
            }
            return nil
        }

        for (key, entry) in strings {
            let entry = entry as? [String: Any] ?? [:]
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for (language, localization) in localizations {
                if let localization = localization as? [String: Any], let text = value(of: localization) {
                    tables[language, default: [:]][key] = text
                }
            }
            if tables[sourceLanguage]?[key] == nil, entry["shouldTranslate"] as? Bool != false {
                tables[sourceLanguage, default: [:]][key] = key
            }
        }

        for (language, entries) in tables {
            let folder = bundle.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let body = entries.keys.sorted().map { key in
                "\"\(escape(key))\" = \"\(escape(entries[key] ?? ""))\";"
            }.joined(separator: "\n")
            try (body + "\n").write(to: folder.appendingPathComponent("\(table).strings"), atomically: true, encoding: .utf8)
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: Asset catalogs

    static func flattenAssetCatalog(_ catalog: URL, into bundle: URL, warnings: inout [String]) throws {
        guard let enumerator = FileManager.default.enumerator(at: catalog, includingPropertiesForKeys: nil) else { return }
        var skipped = 0
        for case let url as URL in enumerator {
            switch url.pathExtension {
            case "imageset":
                enumerator.skipDescendants()
                try copyImageSet(url, into: bundle)
            case "appiconset", "colorset", "dataset", "symbolset", "launchimage", "brandassets":
                enumerator.skipDescendants()
                if url.pathExtension != "appiconset" { skipped += 1 }
            default:
                break
            }
        }
        if skipped > 0 {
            warnings.append("\(catalog.lastPathComponent): \(skipped) color, data or symbol asset(s) need Xcode's asset compiler; left out.")
        }
    }

    private static func copyImageSet(_ set: URL, into bundle: URL) throws {
        let name = set.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: set.appendingPathComponent("Contents.json")),
              let contents = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = contents["images"] as? [[String: Any]]
        else { return }
        for image in images {
            guard let filename = image["filename"] as? String else { continue }
            // Dark-mode and other appearance variants have no loose-file equivalent.
            if image["appearances"] != nil { continue }
            let source = set.appendingPathComponent(filename)
            let fileExtension = source.pathExtension
            let scale = (image["scale"] as? String) ?? "1x"
            let suffix = scale == "1x" ? "" : "@\(scale)"
            let idiom = (image["idiom"] as? String).flatMap { $0 == "universal" || $0 == "iphone" ? nil : "~\($0)" } ?? ""
            try sync(source, to: bundle.appendingPathComponent("\(name)\(suffix)\(idiom).\(fileExtension)"))
        }
    }
}
