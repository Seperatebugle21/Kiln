import Foundation

/// Reads the app target of an Xcode project (project.pbxproj) or an XcodeGen project (project.yml):
/// its source files, resources, Swift settings, package products and linked .xcframeworks, plus the
/// project's package references. Other targets (widgets, extensions, tests) are left out, as Xcode
/// would when building the app scheme.
enum XcodeProjectReader {
    struct Project {
        var packages: [PackageManifest.Dependency] = []
        /// Product names the app target depends on.
        var products: [String] = []
        var bridgingHeader: URL?
        /// The app target's name, when the project has one.
        var targetName: String?
        /// The app target's source files (Swift and C-family); nil when unknown.
        var sources: [URL]?
        var resources: [URL] = []
        var swiftFlags: [String] = []
        /// .xcframework or .framework folders the app links.
        var frameworks: [URL] = []
        var warnings: [String] = []
    }

    static func read(_ root: URL) -> Project {
        var project = Project()
        let yml = root.appendingPathComponent("project.yml")
        if FileManager.default.fileExists(atPath: yml.path) {
            readXcodeGen(yml, root: root, into: &project)
            return project
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if let name = names.sorted().first(where: { $0.hasSuffix(".xcodeproj") }) {
            let file = root.appendingPathComponent(name).appendingPathComponent("project.pbxproj")
            readPBXProject(file, projectName: (name as NSString).deletingPathExtension, root: root, into: &project)
        }
        return project
    }

    // MARK: Source files

    static let sourceExtensions = BuildPlanner.swiftExtensions.union(BuildPlanner.clangExtensions)
    /// Files that are part of a target folder but neither compiled nor copied as resources.
    private static let ignoredExtensions: Set<String> = [
        "h", "hh", "hpp", "inc", "modulemap", "entitlements", "xcconfig", "md", "plist", "pch", "xctestplan", "xcscheme",
    ]
    /// Folders that are one resource (copied whole), not walked into.
    private static let bundleExtensions: Set<String> = [
        "xcassets", "lproj", "bundle", "xcdatamodeld", "scnassets", "storyboardc", "rcproject", "reality", "docc",
    ]
    private static let skippedFolders: Set<String> = [".build", "build", "DerivedData", "xcuserdata", ".git", ".kiln", "Pods", "node_modules"]

    /// Sorts a file or folder into sources and resources, skipping excluded paths.
    private static func collect(_ url: URL, excluded: (URL) -> Bool, sources: inout [URL], resources: inout [URL]) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !excluded(url) else { return }
        let fileExtension = url.pathExtension.lowercased()
        if isDirectory.boolValue {
            if bundleExtensions.contains(fileExtension) {
                if fileExtension != "docc" { resources.append(url) }
                return
            }
            if skippedFolders.contains(url.lastPathComponent) || fileExtension == "xcodeproj" || fileExtension == "swiftpm"
                || fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return
            }
            for child in ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .sorted(by: { $0.path < $1.path }) {
                collect(child, excluded: excluded, sources: &sources, resources: &resources)
            }
            return
        }
        if sourceExtensions.contains(fileExtension) {
            sources.append(url.standardizedFileURL)
        } else if !ignoredExtensions.contains(fileExtension), url.lastPathComponent != "Package.swift" {
            resources.append(url.standardizedFileURL)
        }
    }

    /// Matches XcodeGen-style globs (`*`, `**`, `?`) against a relative path.
    static func glob(_ pattern: String, matches path: String) -> Bool {
        var regex = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    regex += ".*"
                    index = pattern.index(after: next)
                    if index < pattern.endIndex, pattern[index] == "/" { index = pattern.index(after: index) }
                    continue
                }
                regex += "[^/]*"
            } else if character == "?" {
                regex += "[^/]"
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        regex += "(/.*)?$"
        return path.range(of: regex, options: .regularExpression) != nil
    }

    // MARK: XcodeGen

    private static func readXcodeGen(_ url: URL, root: URL, into project: inout Project) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let yaml = YAMLValue.parse(text)

        for (name, spec) in yaml["packages"]?.entries ?? [] {
            func value(_ key: String) -> String? { spec[key]?.string }
            var requirement = PackageManifest.Requirement.none
            if let version = value("from") ?? value("majorVersion") { requirement = .from(version) }
            if let version = value("minorVersion") { requirement = .upToNextMinor(version) }
            if let version = value("exactVersion") ?? value("version") { requirement = .exact(version) }
            if let branch = value("branch") { requirement = .branch(branch) }
            if let revision = value("revision") { requirement = .revision(revision) }
            if let lower = value("minVersion"), let upper = value("maxVersion") { requirement = .range(lower: lower, upper: upper) }
            if let path = value("path") {
                project.packages.append(.init(location: .path(path), requirement: .none, name: name))
            } else if let url = value("url") {
                project.packages.append(.init(location: .url(url), requirement: requirement, name: name))
            } else if let github = value("github") {
                project.packages.append(.init(location: .url("https://github.com/\(github)"), requirement: requirement, name: name))
            }
        }

        let targets = yaml["targets"]?.entries ?? []
        let applications = targets.filter { $0.value["type"]?.string == "application" }
        let projectName = yaml["name"]?.string
        guard let application = applications.first(where: { $0.key == projectName }) ?? applications.first else {
            if !targets.isEmpty { project.warnings.append("project.yml has no application target; building every Swift file.") }
            return
        }
        let name = application.key
        let target = application.value
        project.targetName = name

        // Settings: the target's over the project's; base, then Debug.
        func setting(_ key: String) -> YAMLValue? {
            for settings in [target["settings"], yaml["settings"]].compactMap({ $0 }) {
                if let value = settings["base"]?[key] ?? settings["configs"]?["Debug"]?[key] ?? settings["configs"]?["debug"]?[key] ?? settings[key] {
                    return value
                }
            }
            return nil
        }
        applySettings(setting, root: root, into: &project)

        var sources: [URL] = []
        var resources: [URL] = []
        for item in target["sources"]?.items ?? [] {
            let path = item.string ?? item["path"]?.string ?? ""
            guard !path.isEmpty else { continue }
            let url = root.appendingPathComponent(path).standardizedFileURL
            let excludes = (item["excludes"]?.items ?? []).compactMap(\.string)
            let phase = item["buildPhase"]?.string ?? (item["buildPhase"]?.entries.first?.key)
            let excluded: (URL) -> Bool = { candidate in
                guard !excludes.isEmpty else { return false }
                let relative = candidate.standardizedFileURL.path.dropFirst(url.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return excludes.contains { glob($0, matches: relative) }
            }
            switch phase {
            case "resources", "copyFiles":
                resources.append(url)
            case "none", "headers":
                continue
            default:
                if item["type"]?.string == "folder" {
                    resources.append(url)
                } else {
                    collect(url, excluded: excluded, sources: &sources, resources: &resources)
                }
            }
        }
        project.sources = sources
        project.resources = resources

        for dependency in target["dependencies"]?.items ?? [] {
            if let package = dependency["package"]?.string {
                let products = (dependency["products"]?.items ?? []).compactMap(\.string)
                if let product = dependency["product"]?.string {
                    project.products.append(product)
                } else if !products.isEmpty {
                    project.products += products
                } else {
                    project.products.append(package)
                }
            } else if let framework = dependency["framework"]?.string {
                addFramework(root.appendingPathComponent(framework).standardizedFileURL, into: &project)
            } else if let other = dependency["target"]?.string, other != name {
                project.warnings.append("\(other): app extensions and other targets are not built; Kiln runs the \(name) app only.")
            }
        }
    }

    // MARK: Xcode project

    private static func readPBXProject(_ url: URL, projectName: String, root: URL, into project: inout Project) {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]]
        else { return }
        let rootObject = (plist["rootObject"] as? String).flatMap { objects[$0] } ?? [:]

        // Package references.
        for object in objects.values {
            switch object["isa"] as? String {
            case "XCLocalSwiftPackageReference":
                if let path = object["relativePath"] as? String {
                    project.packages.append(.init(location: .path(path), requirement: .none, name: nil))
                }
            case "XCRemoteSwiftPackageReference":
                guard let url = object["repositoryURL"] as? String else { continue }
                project.packages.append(.init(location: .url(url), requirement: requirement(object["requirement"] as? [String: Any] ?? [:]), name: nil))
            default:
                break
            }
        }

        // Where each file and group is: groups are relative to their parent group.
        var parents: [String: String] = [:]
        for (id, object) in objects {
            for child in object["children"] as? [String] ?? [] { parents[child] = id }
        }
        let mainGroup = rootObject["mainGroup"] as? String
        var pathCache: [String: URL?] = [:]
        func location(of id: String, depth: Int = 0) -> URL? {
            if let cached = pathCache[id] { return cached }
            guard depth < 64, let object = objects[id] else { return nil }
            let path = object["path"] as? String
            var result: URL?
            switch object["sourceTree"] as? String ?? "<group>" {
            case "<absolute>":
                result = path.map { URL(fileURLWithPath: $0) }
            case "SOURCE_ROOT":
                result = path.map { root.appendingPathComponent($0) } ?? root
            case "<group>":
                let base = id == mainGroup ? root : (parents[id].flatMap { location(of: $0, depth: depth + 1) } ?? root)
                result = path.map { base.appendingPathComponent($0) } ?? base
            default:
                result = nil // Built products, the SDK, developer folders.
            }
            result = result?.standardizedFileURL
            pathCache[id] = result
            return result
        }

        // The app target.
        let targetIDs = rootObject["targets"] as? [String] ?? Array(objects.keys)
        let applications = targetIDs.compactMap { id in objects[id].map { (id, $0) } }
            .filter { $0.1["isa"] as? String == "PBXNativeTarget" && $0.1["productType"] as? String == "com.apple.product-type.application" }
        guard let application = applications.first(where: { $0.1["name"] as? String == projectName }) ?? applications.first else {
            for object in objects.values where object["isa"] as? String == "XCSwiftPackageProductDependency" {
                if let product = object["productName"] as? String { project.products.append(product) }
            }
            return
        }
        let targetID = application.0
        let target = application.1
        let targetName = target["name"] as? String ?? projectName
        project.targetName = targetName

        for id in target["packageProductDependencies"] as? [String] ?? [] {
            if let product = objects[id]?["productName"] as? String { project.products.append(product) }
        }

        // Build settings (Debug), the target's over the project's.
        func configuration(_ listID: String?) -> [String: Any] {
            guard let listID, let list = objects[listID], let ids = list["buildConfigurations"] as? [String] else { return [:] }
            let configurations = ids.compactMap { objects[$0] }
            let debug = configurations.first { $0["name"] as? String == "Debug" } ?? configurations.first
            return debug?["buildSettings"] as? [String: Any] ?? [:]
        }
        let targetSettings = configuration(target["buildConfigurationList"] as? String)
        let projectSettings = configuration(rootObject["buildConfigurationList"] as? String)
        applySettings({ key in
            let value = targetSettings[key] ?? projectSettings[key]
            if let string = value as? String { return .scalar(string) }
            if let list = value as? [String] { return .list(list.map { .scalar($0) }) }
            return nil
        }, root: root, into: &project)

        var sources: [URL] = []
        var resources: [URL] = []
        for phaseID in target["buildPhases"] as? [String] ?? [] {
            guard let phase = objects[phaseID] else { continue }
            let files = (phase["files"] as? [String] ?? []).compactMap { objects[$0]?["fileRef"] as? String }
            switch phase["isa"] as? String {
            case "PBXSourcesBuildPhase":
                sources += files.compactMap { location(of: $0) }.filter { sourceExtensions.contains($0.pathExtension.lowercased()) }
            case "PBXResourcesBuildPhase":
                resources += files.compactMap { location(of: $0) }
            case "PBXFrameworksBuildPhase":
                for url in files.compactMap({ location(of: $0) }) where ["xcframework", "framework"].contains(url.pathExtension) {
                    addFramework(url, into: &project)
                }
            default:
                break
            }
        }

        // Xcode 16 folders: everything inside belongs to the target, except its exceptions.
        for groupID in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
            guard let group = objects[groupID], let folder = location(of: groupID) else { continue }
            var excludedPaths = Set<String>()
            for exceptionID in group["exceptions"] as? [String] ?? [] {
                guard let exception = objects[exceptionID], exception["target"] as? String == targetID else { continue }
                for path in exception["membershipExceptions"] as? [String] ?? [] {
                    excludedPaths.insert(folder.appendingPathComponent(path).standardizedFileURL.path)
                }
            }
            collect(folder, excluded: { excludedPaths.contains($0.standardizedFileURL.path) || $0.lastPathComponent == "Info.plist" },
                    sources: &sources, resources: &resources)
        }

        project.sources = Array(Set(sources)).sorted { $0.path < $1.path }
        project.resources = resources

        let otherTargets = targetIDs.compactMap { objects[$0]?["name"] as? String }.filter { $0 != targetName }
        if !otherTargets.isEmpty {
            project.warnings.append("Building the \(targetName) app; other targets (\(otherTargets.joined(separator: ", "))) are left out.")
        }
    }

    private static func requirement(_ requirement: [String: Any]) -> PackageManifest.Requirement {
        switch requirement["kind"] as? String {
        case "upToNextMajorVersion":
            return (requirement["minimumVersion"] as? String).map { .from($0) } ?? .none
        case "upToNextMinorVersion":
            return (requirement["minimumVersion"] as? String).map { .upToNextMinor($0) } ?? .none
        case "exactVersion":
            return (requirement["version"] as? String).map { .exact($0) } ?? .none
        case "versionRange":
            if let lower = requirement["minimumVersion"] as? String, let upper = requirement["maximumVersion"] as? String {
                return .range(lower: lower, upper: upper)
            }
            return .none
        case "branch":
            return (requirement["branch"] as? String).map { .branch($0) } ?? .none
        case "revision":
            return (requirement["revision"] as? String).map { .revision($0) } ?? .none
        default:
            return .none
        }
    }

    // MARK: Settings

    private static func applySettings(_ setting: (String) -> YAMLValue?, root: URL, into project: inout Project) {
        func words(_ key: String) -> [String] {
            guard let value = setting(key) else { return [] }
            let raw = value.string.map { $0.split(separator: " ").map(String.init) } ?? value.items.compactMap(\.string)
            return raw.filter { !$0.isEmpty && !$0.hasPrefix("$(inherited)") && !$0.hasPrefix("${inherited}") }
        }
        project.swiftFlags += words("SWIFT_ACTIVE_COMPILATION_CONDITIONS").flatMap { ["-D", $0] }
        project.swiftFlags += PackageManifestFlags.safeSwiftFlags(words("OTHER_SWIFT_FLAGS"))
        if setting("SWIFT_ENABLE_BARE_SLASH_REGEX")?.string == "YES" {
            project.swiftFlags += ["-enable-bare-slash-regex"]
        }
        if let header = setting("SWIFT_OBJC_BRIDGING_HEADER")?.string, !header.isEmpty {
            project.bridgingHeader = resolve(header, root: root)
        }
    }

    private static func addFramework(_ url: URL, into project: inout Project) {
        if FileManager.default.fileExists(atPath: url.path) {
            project.frameworks.append(url)
        } else {
            project.warnings.append("\(url.lastPathComponent) is linked by the project but missing (it may be made by a script); left out.")
        }
    }

    private static func resolve(_ path: String, root: URL) -> URL {
        var cleaned = path
        for variable in ["$(SRCROOT)/", "$(PROJECT_DIR)/", "${SRCROOT}/", "${PROJECT_DIR}/"] {
            cleaned = cleaned.replacingOccurrences(of: variable, with: "")
        }
        return root.appendingPathComponent(cleaned).standardizedFileURL
    }
}
