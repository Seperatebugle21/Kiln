import Foundation

// Usage: kiln-build <project folder>
// Environment: KILN_SWIFT_FRONTEND, KILN_LLD, KILN_SWIFT_RESOURCES, KILN_PLUGIN_ARGS (space separated),
// KILN_GITHUB_TOKEN (optional, for the GitHub API).

let environment = ProcessInfo.processInfo.environment
guard CommandLine.arguments.count > 1 else {
    print("usage: kiln-build <project folder>")
    exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL

func shell(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

let sdk = URL(fileURLWithPath: shell("xcrun --sdk iphoneos --show-sdk-path"))
let clangResources = URL(fileURLWithPath: shell("xcrun clang -print-resource-dir"))
LocalToolchainBackend.host = .init(
    sdk: sdk,
    swiftResources: URL(fileURLWithPath: environment["KILN_SWIFT_RESOURCES"] ?? ""),
    clangResources: clangResources,
    builtins: clangResources.appendingPathComponent("lib/darwin/libclang_rt.ios.a"),
    pluginArguments: (environment["KILN_PLUGIN_ARGS"] ?? "").split(separator: " ").map(String.init)
)

func log(_ line: String) {
    print(line)
    fflush(stdout)
}

let started = Date()
let resolver = PackageResolver(projectRoot: root, token: environment["KILN_GITHUB_TOKEN"], log: log)
let plan: BuildPlan
do {
    plan = try await BuildPlanner.plan(root: root, resolver: resolver)
} catch {
    log("PLAN FAILED: \(error.localizedDescription)")
    exit(1)
}
plan.warnings.forEach(log)
log("Packages: \(plan.modules.map(\.name).joined(separator: ", "))")
// How Kiln reads mlx-swift's manifest: every target's folder and excludes under "mlx".
let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KilnPackages/mlx-swift")
for version in (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
    guard let manifest = try? PackageManifest.load(from: version) else { continue }
    for target in manifest.targets {
        let directory = BuildPlanner.targetDirectory(target, in: version)
        let mlxExcludes = target.exclude.filter { $0 == "mlx" || $0.hasPrefix("mlx/mlx") || $0.hasSuffix("/") || $0.isEmpty }
        log("  [manifest] \(target.name) kind=\(target.kind) dir=\(directory.path.dropFirst(version.path.count)) excludes=\(target.exclude.count) sources=\(target.sources ?? []) mlx-related=\(mlxExcludes)")
    }
}
// What is on disk in mlx-swift's Cmlx/mlx (the mlx submodule), by extension and top folders.
for version in (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
    let mlx = version.appendingPathComponent("Source/Cmlx/mlx")
    var byExtension: [String: Int] = [:]
    var folders = Set<String>()
    var symlinks = 0
    if let enumerator = FileManager.default.enumerator(at: mlx, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
        for case let url as URL in enumerator {
            byExtension[url.pathExtension, default: 0] += 1
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { symlinks += 1 }
            let relative = url.path.dropFirst(mlx.path.count + 1).split(separator: "/")
            if relative.count >= 2 { folders.insert(relative.prefix(2).joined(separator: "/")) }
        }
    }
    log("  [disk] Cmlx/mlx: \(byExtension.sorted { $0.value > $1.value }.prefix(12)) symlinks=\(symlinks) folders=\(folders.sorted().prefix(30))")
    let cpp = BuildPlanner.files(in: [mlx], extensions: BuildPlanner.clangExtensions)
    log("  [disk] files() finds \(cpp.count) C-family files in Cmlx/mlx")
}
// Where each C module's sources come from, to spot missing folders.
for module in plan.modules where module.language == .clang && module.sources.count > 5 {
    var folders: [String: Int] = [:]
    for source in module.sources {
        let parts = source.path.split(separator: "/")
        let key = parts.suffix(4).dropLast().joined(separator: "/")
        folders[key, default: 0] += 1
    }
    log("  \(module.name): \(module.sources.count) files: " + folders.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
}

let rootPath = root.path + "/"
var sources: [SourceFile] = []
for url in plan.appSources {
    let path = url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.lastPathComponent
    sources.append(SourceFile(path: path, text: (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
}
let syntaxErrors = sources.flatMap(SyntaxChecker.check).filter { $0.severity == .error }
if !syntaxErrors.isEmpty {
    syntaxErrors.forEach { log($0.summary) }
    log("SYNTAX CHECK FAILED")
    exit(1)
}
log("Syntax check passed for \(sources.count) file(s).")

let prepared: [SourceFile]
do {
    prepared = try EntryPointGenerator.prepare(sources)
} catch {
    log("ENTRY POINT FAILED: \(error.localizedDescription)")
    exit(1)
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-build-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let request = BuildRequest(projectName: root.deletingPathExtension().lastPathComponent, sources: prepared, workDirectory: work, plan: plan)
do {
    let product = try await LocalToolchainBackend().build(request, log: log)
    log(String(format: "BUILD SUCCEEDED in %.0f s: %@", Date().timeIntervalSince(started), product.dylib.path))
} catch BuildError.diagnostics(let diagnostics) {
    diagnostics.forEach { log($0.summary) }
    log("BUILD FAILED with \(diagnostics.filter { $0.severity == .error }.count) error(s)")
    exit(1)
} catch {
    log("BUILD FAILED: \(error.localizedDescription)")
    exit(1)
}
