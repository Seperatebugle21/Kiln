import Darwin
import Foundation

/// Compiles on the device with the Swift compiler and lld linked into Kiln.
///
/// The bundled `Toolchain/` folder holds what the compiler reads:
///   iPhoneOS.sdk.aar        the iOS SDK (Swift interfaces, headers, .tbd stubs), unpacked on first use
///   resources/              the compiler's resource directory (Clang headers, Swift shims)
///   lib/libclang_rt.ios.a   Clang's runtime helpers (for example #available checks)
///
/// Pipeline: swift-frontend in frontend mode (whole module) → object file → lld → dylib.
/// The dylib is then signed with the certificate imported in Settings (MachOSigner), because iOS only
/// loads code signed by the same team as Kiln.
struct LocalToolchainBackend: BuildBackend {
    let name = "On-device compiler"

    static let target = "arm64-apple-ios26.0"

    static var toolchainURL: URL? {
        Bundle.main.url(forResource: "Toolchain", withExtension: nil)
    }

    static var isInstalled: Bool {
        kiln_toolchain_available() == 1 && toolchainURL != nil
    }

    /// Precompiled SDK modules; reused between builds, so only the first build is slow.
    static var moduleCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("KilnModuleCache", isDirectory: true)
    }

    func build(_ request: BuildRequest, log: @escaping @Sendable (String) -> Void) async throws -> BuildProduct {
        guard kiln_toolchain_available() == 1, let toolchain = Self.toolchainURL else {
            throw BuildError.backendUnavailable("This build of Kiln does not include the on-device compiler.")
        }
        let sdk = try SDKInstaller.sdk(in: toolchain, log: log)
        let resources = toolchain.appendingPathComponent("resources")
        let builtins = toolchain.appendingPathComponent("lib/libclang_rt.ios.a")
        let fileManager = FileManager.default

        // Write the prepared sources where the compiler can read them.
        let sourceRoot = request.workDirectory.appendingPathComponent("Sources", isDirectory: true)
        var sourcePaths: [String] = []
        for file in request.sources {
            let url = sourceRoot.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            sourcePaths.append(url.path)
        }
        try fileManager.createDirectory(at: Self.moduleCacheURL, withIntermediateDirectories: true)

        let moduleName = Self.moduleName(for: request.projectName)
        let object = request.workDirectory.appendingPathComponent("\(moduleName).o")
        let dylib = request.workDirectory.appendingPathComponent("\(moduleName).dylib")
        let modulesDirectory = request.workDirectory.appendingPathComponent("Modules", isDirectory: true)
        let objectsDirectory = request.workDirectory.appendingPathComponent("Objects", isDirectory: true)
        try fileManager.createDirectory(at: modulesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: objectsDirectory, withIntermediateDirectories: true)
        let firstBuild = (try? fileManager.contentsOfDirectory(atPath: Self.moduleCacheURL.path))?.isEmpty ?? true
        if firstBuild {
            log("The first build prepares SwiftUI, UIKit and Foundation and can take a few minutes.")
        }

        let swiftCommon = [
            "-target", Self.target,
            "-sdk", sdk.path,
            "-resource-dir", resources.path,
            "-parse-as-library",
            "-Onone",
            "-module-cache-path", Self.moduleCacheURL.path,
            "-I", modulesDirectory.path,
        ] + Self.macroPluginArguments()
        let clangCommon = [
            "-target", Self.target,
            "-isysroot", sdk.path,
            "-resource-dir", resources.appendingPathComponent("clang").path,
            "-O2",
        ]
        var objects: [URL] = []
        var usesCxx = false
        /// Module maps and header paths of the C modules built so far, for the modules that import them.
        var clangImportFlags: [String] = []
        var clangHeaderPaths: [String] = []

        // 1. Package modules, in dependency order.
        for module in request.plan.modules {
            let started = Date()
            switch module.language {
            case .clang:
                log("Compiling \(module.name) (C, \(module.sources.count) file(s))…")
                let headerFlags = (module.publicHeaders.map { [$0.path] } ?? []).flatMap { ["-I", $0] }
                    + module.headerSearchPaths.flatMap { ["-I", $0.path] }
                    + clangHeaderPaths.flatMap { ["-I", $0] }
                for (index, source) in module.sources.enumerated() {
                    let output = objectsDirectory.appendingPathComponent("\(module.name)-\(index)-\(source.deletingPathExtension().lastPathComponent).o")
                    try await compileC(source, to: output, flags: clangCommon + headerFlags + module.defines.flatMap { ["-D", $0] }, log: log)
                    if ["cc", "cpp", "cxx", "mm"].contains(source.pathExtension.lowercased()) { usesCxx = true }
                    objects.append(output)
                }
                if let headers = module.publicHeaders {
                    let map = try Self.writeModuleMap(for: module.name, headers: headers, in: modulesDirectory)
                    clangImportFlags += ["-Xcc", "-fmodule-map-file=\(map.path)", "-Xcc", "-I", "-Xcc", headers.path]
                    clangHeaderPaths.append(headers.path)
                }
            case .swift:
                log("Compiling \(module.name) (Swift, \(module.sources.count) file(s))…")
                let output = objectsDirectory.appendingPathComponent("\(module.name).o")
                let arguments = ["swift-frontend", "-frontend", "-c"] + module.sources.map(\.path) + swiftCommon + clangImportFlags
                    + module.swiftDefines.flatMap { ["-D", $0] }
                    + ["-module-name", module.name,
                       "-emit-module-path", modulesDirectory.appendingPathComponent("\(module.name).swiftmodule").path,
                       "-o", output.path]
                try await compileSwift(arguments, output: output, sourceRoot: request.workDirectory, log: log)
                objects.append(output)
            }
            log(String(format: "  %@ done in %.1f s.", module.name, Date().timeIntervalSince(started)))
        }

        // 2. The app's own C, C++ and Objective-C files (used from Swift through the bridging header).
        var bridgingFlags: [String] = []
        if let header = request.plan.bridgingHeader {
            bridgingFlags = ["-import-objc-header", header.path, "-Xcc", "-I", "-Xcc", header.deletingLastPathComponent().path]
            for (index, source) in request.plan.appCSources.enumerated() {
                let output = objectsDirectory.appendingPathComponent("app-\(index)-\(source.deletingPathExtension().lastPathComponent).o")
                try await compileC(source, to: output, flags: clangCommon + ["-I", header.deletingLastPathComponent().path] + clangHeaderPaths.flatMap { ["-I", $0] }, log: log)
                if ["cc", "cpp", "cxx", "mm"].contains(source.pathExtension.lowercased()) { usesCxx = true }
                objects.append(output)
            }
        }

        // 3. The app.
        log("Compiling \(sourcePaths.count) app file(s)…")
        let compileArguments = ["swift-frontend", "-frontend", "-c"] + sourcePaths + swiftCommon + clangImportFlags + bridgingFlags + [
            "-module-name", moduleName,
            "-o", object.path,
        ]
        let started = Date()
        try await compileSwift(compileArguments, output: object, sourceRoot: sourceRoot, log: log)
        objects.append(object)
        log(String(format: "Compiled in %.1f s.", Date().timeIntervalSince(started)))

        // 2. Link into a dylib that Kiln can load.
        log("Linking…")
        let sdkVersion = Self.sdkVersion(at: sdk) ?? "26.0"
        let linkArguments = [
            "ld64.lld", "-dylib",
            "-arch", "arm64",
            "-platform_version", "ios", "26.0", sdkVersion,
            "-syslibroot", sdk.path,
            "-L", sdk.appendingPathComponent("usr/lib/swift").path,
            "-lSystem",
            "-install_name", "@rpath/\(moduleName).dylib",
            "-adhoc_codesign",
        ] + objects.map(\.path) + (usesCxx ? ["-lc++"] : []) + [
            builtins.path,
            "-o", dylib.path,
        ]
        var linkerOutput: UnsafeMutablePointer<CChar>?
        let linkStatus = Self.withCArguments(linkArguments) { argc, argv in
            kiln_lld_link(argc, argv, &linkerOutput)
        }
        let linkerText = linkerOutput.map { String(cString: $0) } ?? ""
        free(linkerOutput)
        for line in linkerText.split(separator: "\n") where !line.contains("auto-linked framework not found") {
            log(String(line))
        }
        guard linkStatus == 0, fileManager.fileExists(atPath: dylib.path) else {
            throw BuildError.failed("Linking failed.")
        }

        // 3. Sign with the certificate from Settings, so iOS accepts it without JIT.
        if let identity = try SigningIdentityStore.load(appleCertificates: SigningIdentityStore.bundledAppleCertificates()) {
            log("Signing with \(identity.name) (\(identity.teamID))…")
            let signer = MachOSigner(privateKey: identity.privateKey, certificates: identity.certificates, teamID: identity.teamID)
            try signer.sign(fileAt: dylib, identifier: "app.kiln.build.\(moduleName)")
        } else {
            log("No signing certificate in Settings: the app is ad-hoc signed, which iOS rejects unless code signing checks are bypassed.")
        }
        return BuildProduct(dylib: dylib)
    }

    // MARK: Compiling

    private func compileSwift(_ arguments: [String], output: URL, sourceRoot: URL, log: @Sendable (String) -> Void) async throws {
        let (status, text) = await Self.runOnLargeStack {
            Self.capturingStandardError {
                Self.withCArguments(arguments) { argc, argv in kiln_swift_frontend(argc, argv) }
            }
        }
        let diagnostics = Self.parseDiagnostics(text, sourceRoot: sourceRoot)
        if status != 0 || !FileManager.default.fileExists(atPath: output.path) {
            if diagnostics.isEmpty {
                log(text.isEmpty ? "The compiler failed with status \(status)." : text)
                throw BuildError.failed("The compiler failed with status \(status).")
            }
            throw BuildError.diagnostics(diagnostics)
        }
    }

    private func compileC(_ source: URL, to output: URL, flags: [String], log: @Sendable (String) -> Void) async throws {
        var arguments = ["clang", "-c", source.path, "-o", output.path] + flags
        switch source.pathExtension.lowercased() {
        case "m": arguments += ["-fobjc-arc"]
        case "mm": arguments += ["-fobjc-arc", "-std=gnu++17"]
        case "cc", "cpp", "cxx": arguments += ["-std=gnu++17"]
        default: arguments += ["-std=gnu11"]
        }
        let finalArguments = arguments
        let (status, text) = await Self.runOnLargeStack {
            Self.capturingStandardError {
                Self.withCArguments(finalArguments) { argc, argv in kiln_clang(argc, argv) }
            }
        }
        if status == -1, text.isEmpty {
            throw BuildError.backendUnavailable("This build of Kiln cannot compile C files yet (the clang driver is not included).")
        }
        let diagnostics = Self.parseDiagnostics(text, sourceRoot: source.deletingLastPathComponent())
        if status != 0 || !FileManager.default.fileExists(atPath: output.path) {
            if diagnostics.isEmpty {
                log(text.isEmpty ? "clang failed with status \(status) on \(source.lastPathComponent)." : text)
                throw BuildError.failed("Compiling \(source.lastPathComponent) failed.")
            }
            throw BuildError.diagnostics(diagnostics)
        }
    }

    /// A Clang module map for a C target's public headers, so Swift can `import` it
    /// (SwiftPM's rules: the target's own module.modulemap, an umbrella header named after the
    /// target, or the whole headers folder).
    static func writeModuleMap(for name: String, headers: URL, in directory: URL) throws -> URL {
        let existing = headers.appendingPathComponent("module.modulemap")
        if FileManager.default.fileExists(atPath: existing.path) { return existing }
        let folder = directory.appendingPathComponent("\(name).modulemaps", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let umbrellaHeader = headers.appendingPathComponent("\(name).h")
        let body = FileManager.default.fileExists(atPath: umbrellaHeader.path)
            ? "umbrella header \"\(umbrellaHeader.path)\""
            : "umbrella \"\(headers.path)\""
        let map = folder.appendingPathComponent("module.modulemap")
        try "module \(name) {\n    \(body)\n    export *\n}\n".write(to: map, atomically: true, encoding: .utf8)
        return map
    }

    // MARK: Helpers

    /// Macros run as plug-ins. iOS cannot start the usual plug-in processes, so the compiler loads
    /// them in-process through libSwiftInProcPluginServer; Kiln embeds both in its Frameworks folder
    /// (signed with the app), named lib<Module>.dylib (ObservationMacros, PreviewsMacros, …).
    static func macroPluginArguments() -> [String] {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return [] }
        let server = frameworks.appendingPathComponent("libSwiftInProcPluginServer.dylib")
        guard FileManager.default.fileExists(atPath: server.path) else { return [] }
        return ["-in-process-plugin-server-path", server.path, "-plugin-path", frameworks.path]
    }

    /// A Swift module name from the project name: letters, digits and underscores.
    static func moduleName(for projectName: String) -> String {
        let cleaned = String(projectName.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "_"
        })
        guard let first = cleaned.first else { return "App" }
        return first.isNumber ? "_" + cleaned : cleaned
    }

    static func sdkVersion(at sdk: URL) -> String? {
        guard let data = try? Data(contentsOf: sdk.appendingPathComponent("SDKSettings.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["Version"] as? String
    }

    /// The compiler recurses deeply; secondary threads get only 512 KB of stack by default.
    static func runOnLargeStack<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: body())
            }
            thread.stackSize = 64 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Runs `body` with C `argc`/`argv` built from `arguments`.
    static func withCArguments<R>(_ arguments: [String], _ body: (Int32, UnsafeMutablePointer<UnsafePointer<CChar>>) -> R) -> R {
        let copies = arguments.map { strdup($0)! }
        defer { copies.forEach { free($0) } }
        var pointers = copies.map { UnsafePointer<CChar>($0) }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(Int32(buffer.count), buffer.baseAddress!)
        }
    }

    /// The compiler writes diagnostics to stderr; route it to a file while it runs.
    static func capturingStandardError(_ body: () -> Int32) -> (Int32, String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-compiler-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = open(url.path, O_WRONLY | O_TRUNC)
        guard file >= 0 else { return (body(), "") }
        fflush(stderr)
        let saved = dup(STDERR_FILENO)
        dup2(file, STDERR_FILENO)
        let status = body()
        fflush(stderr)
        dup2(saved, STDERR_FILENO)
        close(saved)
        close(file)
        let output = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: url)
        return (status, output)
    }

    /// Parses `path:line:column: severity: message` lines into project-relative diagnostics.
    static func parseDiagnostics(_ output: String, sourceRoot: URL) -> [BuildDiagnostic] {
        let rootPrefix = sourceRoot.standardizedFileURL.path + "/"
        var diagnostics: [BuildDiagnostic] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5,
                  let lineNumber = Int(parts[1]),
                  let column = Int(parts[2])
            else { continue }
            let severity: BuildDiagnostic.Severity
            switch parts[3].trimmingCharacters(in: .whitespaces) {
            case "error": severity = .error
            case "warning": severity = .warning
            case "note": severity = .note
            default: continue
            }
            var path = String(parts[0])
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if standardized.hasPrefix(rootPrefix) {
                path = String(standardized.dropFirst(rootPrefix.count))
            }
            diagnostics.append(BuildDiagnostic(
                severity: severity,
                file: path,
                line: lineNumber,
                column: column,
                message: parts[4].trimmingCharacters(in: .whitespaces)
            ))
        }
        return diagnostics
    }
}
