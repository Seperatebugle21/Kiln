import Foundation

/// One module to compile before the app: a Swift or C-family package target.
struct BuildModule: Sendable {
    enum Language: Sendable {
        case swift, clang
    }

    var name: String
    var language: Language
    var sources: [URL]
    /// C targets: the public headers folder that becomes the module's interface.
    var publicHeaders: URL?
    var headerSearchPaths: [URL]
    var defines: [String]
    var swiftDefines: [String]
    var dependencies: [String]
}

/// What to compile for a project: package modules in dependency order, then the app.
struct BuildPlan: Sendable {
    var modules: [BuildModule] = []
    var appSources: [URL] = []
    /// C, C++ and Objective-C files of the app itself, exposed to Swift through the bridging header.
    var appCSources: [URL] = []
    var bridgingHeader: URL?
    var warnings: [String] = []
}

/// Reads a project (Swift package, Xcode project, XcodeGen project or plain folder) into a BuildPlan,
/// resolving and downloading package dependencies.
enum BuildPlanner {
    static let swiftExtensions: Set<String> = ["swift"]
    static let clangExtensions: Set<String> = ["c", "m", "mm", "cc", "cpp", "cxx"]
    /// A folder that only wraps one Swift Playgrounds app (a repo with `MyApp.swiftpm/` in it)
    /// builds that app.
    static func packageRoot(in folder: URL) -> URL {
        let fileManager = FileManager.default
        func has(_ name: String) -> Bool { fileManager.fileExists(atPath: folder.appendingPathComponent(name).path) }
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        if has("Package.swift") || has("project.yml") || names.contains(where: { $0.hasSuffix(".xcodeproj") }) {
            return folder
        }
        let playgrounds = names.filter { $0.hasSuffix(".swiftpm") }
            .map { folder.appendingPathComponent($0, isDirectory: true) }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("Package.swift").path) }
        return playgrounds.count == 1 ? playgrounds[0] : folder
    }

    private static let skippedFolders: Set<String> = [".build", "build", "DerivedData", "Pods", "node_modules", "xcuserdata", ".git", ".kiln"]

    static func plan(root folder: URL, resolver: PackageResolver) async throws -> BuildPlan {
        let root = packageRoot(in: folder)
        var plan = BuildPlan()
        var directDependencies: [PackageManifest.Dependency] = []
        var dependencyBase = root
        var appRequirements: [PackageManifest.TargetDependency] = []
        var rootPackage: ResolvedPackage?

        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            // A Swift package or a Swift Playgrounds app (.swiftpm): the executable target is the app.
            let manifest = try PackageManifest.load(from: root)
            let package = ResolvedPackage(identity: manifest.name.lowercased(), root: root, manifest: manifest)
            rootPackage = package
            let candidates = manifest.targets.filter { $0.kind == .executable } + manifest.targets.filter { $0.kind == .regular }
            guard let app = candidates.first else { throw PlanError.noAppTarget }
            let directory = targetDirectory(app, in: root)
            let otherTargets = manifest.targets.filter { $0.name != app.name }.map { targetDirectory($0, in: root) }
            plan.appSources = files(in: [directory], extensions: swiftExtensions, excluding: excluded(app, in: directory) + otherTargets)
            appRequirements = app.dependencies
            directDependencies = manifest.dependencies
        } else {
            // An Xcode project, an XcodeGen project or a folder of Swift files.
            let project = XcodeProjectReader.read(root)
            plan.bridgingHeader = project.bridgingHeader
            dependencyBase = root
            directDependencies = project.packages
            appRequirements = project.products.map { .byName($0) }
            let packageFolders = findPackageFolders(in: root)
            if directDependencies.isEmpty {
                // A plain folder: every Swift package inside it is a dependency of the app.
                directDependencies = packageFolders.map { folder in
                    let relative = String(folder.path.dropFirst(root.standardizedFileURL.path.count + 1))
                    return PackageManifest.Dependency(location: .path(relative), requirement: .none, name: nil)
                }
            }
            plan.appSources = files(in: [root], extensions: swiftExtensions, excluding: packageFolders, skipTests: true)
            if plan.bridgingHeader != nil {
                plan.appCSources = files(in: [root], extensions: clangExtensions, excluding: packageFolders, skipTests: true)
            }
        }

        // Resolve every package in the dependency graph.
        var packages: [String: ResolvedPackage] = [:]
        if let rootPackage { packages[rootPackage.identity] = rootPackage }
        var queue: [(PackageManifest.Dependency, URL)] = directDependencies.map { ($0, dependencyBase) }
        while !queue.isEmpty {
            let (dependency, base) = queue.removeFirst()
            guard packages[dependency.identity] == nil else { continue }
            let resolved = try await resolver.resolve(dependency, relativeTo: base)
            packages[dependency.identity] = resolved
            queue += resolved.manifest.dependencies.map { ($0, resolved.root) }
        }

        // Without explicit product dependencies (a folder project), use every library product.
        if appRequirements.isEmpty {
            for dependency in directDependencies {
                guard let package = packages[dependency.identity] else { continue }
                appRequirements += package.manifest.products.map { .byName($0.name) }
            }
        }

        // Collect the targets the app needs, through products and target dependencies.
        var needed: [String: (ResolvedPackage, PackageManifest.Target)] = [:]
        var order: [String] = []
        func visit(_ requirement: PackageManifest.TargetDependency, from package: ResolvedPackage?) {
            for (owner, target) in targets(for: requirement, from: package, in: packages) {
                guard needed[target.name] == nil else { continue }
                needed[target.name] = (owner, target)
                for dependency in target.dependencies { visit(dependency, from: owner) }
                order.append(target.name)
            }
        }
        for requirement in appRequirements { visit(requirement, from: rootPackage) }

        for name in order {
            guard let entry = needed[name] else { continue }
            let package = entry.0
            let target = entry.1
            switch target.kind {
            case .regular, .executable:
                break
            case .binary:
                plan.warnings.append("\(target.name): binary targets (.xcframework) are not supported yet; skipped.")
                continue
            case .macro, .plugin, .test, .system:
                plan.warnings.append("\(target.name): \(target.kind) targets are not supported; skipped.")
                continue
            }
            if let module = module(for: target, in: package) {
                plan.modules.append(module)
            } else {
                plan.warnings.append("\(target.name): no sources found; skipped.")
            }
        }
        let known = Set(plan.modules.map(\.name))
        plan.modules = plan.modules.map { module in
            var module = module
            module.dependencies = module.dependencies.filter { known.contains($0) }
            return module
        }
        return plan
    }

    enum PlanError: LocalizedError {
        case noAppTarget
        var errorDescription: String? { "Package.swift has no executable or library target to run." }
    }

    // MARK: Targets

    /// The targets behind a dependency: a target of the same package, or a product of any package.
    private static func targets(
        for requirement: PackageManifest.TargetDependency,
        from package: ResolvedPackage?,
        in packages: [String: ResolvedPackage]
    ) -> [(ResolvedPackage, PackageManifest.Target)] {
        let name: String
        var packageName: String?
        var targetOnly = false
        switch requirement {
        case .byName(let value): name = value
        case .target(let value): name = value; targetOnly = true
        case .product(let value, let owner): name = value; packageName = owner
        }

        if let package, let target = package.manifest.targets.first(where: { $0.name == name }), packageName == nil {
            return [(package, target)]
        }
        if targetOnly { return [] }
        let candidates = packages.values.filter { candidate in
            guard let packageName else { return true }
            return candidate.identity == packageName.lowercased() || candidate.manifest.name == packageName
        }
        for candidate in candidates.sorted(by: { $0.identity < $1.identity }) {
            if let product = candidate.manifest.products.first(where: { $0.name == name }) {
                return product.targets.compactMap { targetName in
                    candidate.manifest.targets.first { $0.name == targetName }.map { (candidate, $0) }
                }
            }
        }
        // Older manifests sometimes depend on a target name directly.
        for candidate in candidates {
            if let target = candidate.manifest.targets.first(where: { $0.name == name }) { return [(candidate, target)] }
        }
        return []
    }

    private static func module(for target: PackageManifest.Target, in package: ResolvedPackage) -> BuildModule? {
        let directory = targetDirectory(target, in: package.root)
        var roots = [directory]
        if let sources = target.sources {
            roots = sources.map { directory.appendingPathComponent($0) }
        }
        let otherTargets = package.manifest.targets
            .filter { $0.name != target.name }
            .map { targetDirectory($0, in: package.root) }
            .filter { $0.path.hasPrefix(directory.path + "/") }
        let excludes = excluded(target, in: directory) + otherTargets
        let swiftFiles = files(in: roots, extensions: swiftExtensions, excluding: excludes)
        let clangFiles = files(in: roots, extensions: clangExtensions, excluding: excludes)

        let dependencies = target.dependencies.map { dependency -> String in
            switch dependency {
            case .byName(let name), .target(let name), .product(let name, _): return name
            }
        }
        if !swiftFiles.isEmpty {
            return BuildModule(name: target.name, language: .swift, sources: swiftFiles, publicHeaders: nil,
                               headerSearchPaths: [], defines: [], swiftDefines: target.swiftDefines, dependencies: dependencies)
        }
        guard !clangFiles.isEmpty else { return nil }
        let headers = directory.appendingPathComponent(target.publicHeadersPath ?? "include")
        return BuildModule(
            name: target.name,
            language: .clang,
            sources: clangFiles,
            publicHeaders: FileManager.default.fileExists(atPath: headers.path) ? headers : nil,
            headerSearchPaths: target.headerSearchPaths.map { directory.appendingPathComponent($0) } + [directory],
            defines: target.defines,
            swiftDefines: [],
            dependencies: dependencies
        )
    }

    private static func targetDirectory(_ target: PackageManifest.Target, in root: URL) -> URL {
        if let path = target.path { return root.appendingPathComponent(path).standardizedFileURL }
        let base = target.kind == .test ? ["Tests"] : ["Sources", "Source", "src", "srcs"]
        for folder in base {
            let candidate = root.appendingPathComponent(folder).appendingPathComponent(target.name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return root.appendingPathComponent("Sources").appendingPathComponent(target.name).standardizedFileURL
    }

    private static func excluded(_ target: PackageManifest.Target, in directory: URL) -> [URL] {
        target.exclude.map { directory.appendingPathComponent($0).standardizedFileURL }
    }

    // MARK: Files

    static func files(in roots: [URL], extensions: Set<String>, excluding: [URL] = [], skipTests: Bool = false) -> [URL] {
        let excludedPaths = excluding.map { $0.standardizedFileURL.path }
        var result: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if extensions.contains(root.pathExtension.lowercased()) { result.append(root.standardizedFileURL) }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                if excludedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants()
                    continue
                }
                let name = url.lastPathComponent
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if skippedFolders.contains(name) || url.pathExtension == "xcodeproj" || (skipTests && name.hasSuffix("Tests")) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if extensions.contains(url.pathExtension.lowercased()), name != "Package.swift" {
                    result.append(url.standardizedFileURL)
                }
            }
        }
        return Array(Set(result)).sorted { $0.path < $1.path }
    }

    /// Folders inside the project that are Swift packages (their sources are not part of the app).
    private static func findPackageFolders(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var folders: [URL] = []
        for case let url as URL in enumerator {
            if skippedFolders.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
            } else if url.lastPathComponent == "Package.swift", url.deletingLastPathComponent() != root {
                folders.append(url.deletingLastPathComponent().standardizedFileURL)
            }
        }
        return folders
    }
}

/// Package references and settings from Xcode projects (project.pbxproj) and XcodeGen (project.yml).
enum XcodeProjectReader {
    struct Project {
        var packages: [PackageManifest.Dependency] = []
        /// Product names the app target depends on.
        var products: [String] = []
        var bridgingHeader: URL?
    }

    static func read(_ root: URL) -> Project {
        var project = Project()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasSuffix(".xcodeproj") {
            readPBXProject(root.appendingPathComponent(name).appendingPathComponent("project.pbxproj"), root: root, into: &project)
        }
        let yml = root.appendingPathComponent("project.yml")
        if FileManager.default.fileExists(atPath: yml.path) {
            readXcodeGen(yml, root: root, into: &project)
        }
        return project
    }

    private static func readPBXProject(_ url: URL, root: URL, into project: inout Project) {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]]
        else { return }

        for object in objects.values {
            switch object["isa"] as? String {
            case "XCLocalSwiftPackageReference":
                if let path = object["relativePath"] as? String {
                    project.packages.append(.init(location: .path(path), requirement: .none, name: nil))
                }
            case "XCRemoteSwiftPackageReference":
                guard let url = object["repositoryURL"] as? String else { continue }
                let requirement = object["requirement"] as? [String: Any] ?? [:]
                var parsed = PackageManifest.Requirement.none
                switch requirement["kind"] as? String {
                case "upToNextMajorVersion":
                    if let version = requirement["minimumVersion"] as? String { parsed = .from(version) }
                case "upToNextMinorVersion":
                    if let version = requirement["minimumVersion"] as? String { parsed = .upToNextMinor(version) }
                case "exactVersion":
                    if let version = requirement["version"] as? String { parsed = .exact(version) }
                case "versionRange":
                    if let lower = requirement["minimumVersion"] as? String, let upper = requirement["maximumVersion"] as? String {
                        parsed = .range(lower: lower, upper: upper)
                    }
                case "branch":
                    if let branch = requirement["branch"] as? String { parsed = .branch(branch) }
                case "revision":
                    if let revision = requirement["revision"] as? String { parsed = .revision(revision) }
                default:
                    break
                }
                project.packages.append(.init(location: .url(url), requirement: parsed, name: nil))
            case "XCSwiftPackageProductDependency":
                if let product = object["productName"] as? String { project.products.append(product) }
            case "XCBuildConfiguration":
                if project.bridgingHeader == nil,
                   let settings = object["buildSettings"] as? [String: Any],
                   let header = settings["SWIFT_OBJC_BRIDGING_HEADER"] as? String, !header.isEmpty {
                    project.bridgingHeader = resolve(header, root: root)
                }
            default:
                break
            }
        }
    }

    /// The `packages:` block and `- package:` dependencies of an XcodeGen project.yml.
    private static func readXcodeGen(_ url: URL, root: URL, into project: inout Project) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func value(_ line: String) -> String {
            guard let colon = line.firstIndex(of: ":") else { return "" }
            var result = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let comment = result.range(of: " #") { result = String(result[..<comment.lowerBound]) }
            return result.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        func key(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespaces).split(separator: ":").first.map(String.init) ?? ""
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("packages:") {
                index += 1
                var current: [String: String] = [:]
                var packageIndent = -1
                func flush() {
                    guard !current.isEmpty else { return }
                    defer { current = [:] }
                    var requirement = PackageManifest.Requirement.none
                    if let version = current["from"] ?? current["majorVersion"] { requirement = .from(version) }
                    if let version = current["minorVersion"] { requirement = .upToNextMinor(version) }
                    if let version = current["exactVersion"] ?? current["version"] { requirement = .exact(version) }
                    if let branch = current["branch"] { requirement = .branch(branch) }
                    if let revision = current["revision"] { requirement = .revision(revision) }
                    if let lower = current["minVersion"], let upper = current["maxVersion"] { requirement = .range(lower: lower, upper: upper) }
                    if let path = current["path"] {
                        project.packages.append(.init(location: .path(path), requirement: .none, name: nil))
                    } else if let url = current["url"] {
                        project.packages.append(.init(location: .url(url), requirement: requirement, name: nil))
                    } else if let github = current["github"] {
                        project.packages.append(.init(location: .url("https://github.com/\(github)"), requirement: requirement, name: nil))
                    }
                }
                while index < lines.count {
                    let entry = lines[index]
                    if entry.trimmingCharacters(in: .whitespaces).isEmpty || entry.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                        index += 1
                        continue
                    }
                    let level = indent(entry)
                    if level == 0 { break }
                    if packageIndent < 0 { packageIndent = level }
                    if level == packageIndent {
                        flush()
                    } else {
                        current[key(entry)] = value(entry)
                    }
                    index += 1
                }
                flush()
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- package:") {
                var product = value(trimmed)
                if index + 1 < lines.count, lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("product:") {
                    product = value(lines[index + 1])
                }
                if !product.isEmpty { project.products.append(product) }
            }
            if trimmed.hasPrefix("SWIFT_OBJC_BRIDGING_HEADER:"), project.bridgingHeader == nil {
                project.bridgingHeader = resolve(value(trimmed), root: root)
            }
            index += 1
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
