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

    /// Where the SDK, resources and plug-ins are when Kiln's build system runs somewhere else than in
    /// the app: the kiln-build tool uses it to build projects on a Mac in CI, with the same planner,
    /// flags and caches as on the iPhone.
    struct HostToolchain: Sendable {
        var sdk: URL
        var swiftResources: URL
        var clangResources: URL
        var builtins: URL
        var pluginArguments: [String]
    }

    nonisolated(unsafe) static var host: HostToolchain?

    /// Precompiled SDK modules; reused between builds, so only the first build is slow.
    static var moduleCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("KilnModuleCache", isDirectory: true)
    }

    func build(_ request: BuildRequest, log: @escaping @Sendable (String) -> Void) async throws -> BuildProduct {
        let sdk: URL
        let resources: URL
        let clangResources: URL
        let builtins: URL
        let pluginArguments: [String]
        if let host = Self.host {
            sdk = host.sdk
            resources = host.swiftResources
            clangResources = host.clangResources
            builtins = host.builtins
            pluginArguments = host.pluginArguments
        } else {
            guard kiln_toolchain_available() == 1, let toolchain = Self.toolchainURL else {
                throw BuildError.backendUnavailable("This build of Kiln does not include the on-device compiler.")
            }
            sdk = try SDKInstaller.sdk(in: toolchain, log: log)
            resources = toolchain.appendingPathComponent("resources")
            clangResources = resources.appendingPathComponent("clang")
            builtins = toolchain.appendingPathComponent("lib/libclang_rt.ios.a")
            pluginArguments = Self.macroPluginArguments()
        }
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

        // Every build gets its own module names. Kiln keeps earlier runs loaded (iOS cannot unload
        // Swift code), and two loaded images with the same module and type names make the Swift and
        // Objective-C runtimes mix up their types, which crashed the second Run. Sources keep using
        // the plain names (`import Greeting`) through -module-alias.
        let buildTag = "_k" + String(UUID().uuidString.prefix(8)).lowercased()
        // The app keeps its own module name (code may write `MyApp.Thing`); only its ABI name, used in
        // symbol and runtime type names, carries the build tag.
        let appModuleName = Self.moduleName(for: request.projectName)
        let moduleName = appModuleName + buildTag
        let object = request.workDirectory.appendingPathComponent("\(moduleName).o")
        let dylib = request.workDirectory.appendingPathComponent("\(moduleName).dylib")
        let firstBuild = (try? fileManager.contentsOfDirectory(atPath: Self.moduleCacheURL.path))?.isEmpty ?? true
        if firstBuild {
            log("The first build prepares SwiftUI, UIKit and Foundation and can take a few minutes.")
        }

        let cache = BuildCache()
        try cache.prepare()
        let swiftCommon = [
            "-target", Self.target,
            "-sdk", sdk.path,
            "-resource-dir", resources.path,
            "-parse-as-library",
            "-Onone",
            "-module-cache-path", Self.moduleCacheURL.path,
        ] + pluginArguments
        let clangCommon = [
            "-target", Self.target,
            "-isysroot", sdk.path,
            "-resource-dir", clangResources.path,
            "-O2",
        ]
        let sdkVersion = Self.sdkVersion(at: sdk) ?? "26.0"
        let linkCommon = [
            "ld64.lld", "-dylib",
            "-arch", "arm64",
            "-platform_version", "ios", "26.0", sdkVersion,
            "-syslibroot", sdk.path,
            "-L", sdk.appendingPathComponent("usr/lib/swift").path,
            "-lSystem",
            "-adhoc_codesign",
        ]
        /// Objects, static libraries and flags of the package modules: linked once into a shared
        /// packages dylib that stays loaded, so later runs only build and load the app.
        var packageObjects: [URL] = []
        var objects: [URL] = []
        var usesCxx = false
        /// Module maps and header paths of the C modules built so far, for the modules that import them.
        var clangImportFlags: [String] = []
        var clangHeaderPaths: [String] = []
        /// `-module-alias Name=Name_p…` for the Swift package modules built so far.
        /// `-I <folder>` for each Swift package module built so far (each in a folder named by its hash).
        var moduleSearchFlags: [String] = []
        var libraries: [URL] = []
        var packageLinkFlags: [String] = []
        var frameworkFlags: [String] = []
        var dynamicFrameworkFlags: [String] = []
        let embeddedFrameworks = cache.root.appendingPathComponent("Frameworks", isDirectory: true)
        let identity = try SigningIdentityStore.load(appleCertificates: SigningIdentityStore.bundledAppleCertificates())
        var reused = 0
        var compiled = 0

        /// Makes a C module's headers importable from Swift and includable from C.
        func exposeHeaders(_ headers: URL, moduleName: String) throws {
            let maps = Self.moduleMaps(in: headers)
            for map in maps {
                clangImportFlags += ["-Xcc", "-fmodule-map-file=\(map.path)"]
            }
            if maps.isEmpty {
                let map = try Self.writeModuleMap(for: moduleName, headers: headers, in: cache.moduleMaps)
                clangImportFlags += ["-Xcc", "-fmodule-map-file=\(map.path)"]
            }
            clangImportFlags += ["-Xcc", "-I", "-Xcc", headers.path]
            clangHeaderPaths.append(headers.path)
        }

        /// Compiles a C-family file, or reuses the object from an earlier build with the same file and flags.
        func compileCached(_ source: URL, flags: [String], cStandard: String?, cxxStandard: String?) async throws -> URL {
            let key = cache.key([cache.fingerprint([source]), source.path, cStandard ?? "", cxxStandard ?? ""] + flags)
            let output = cache.objects.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(key).o")
            if fileManager.fileExists(atPath: output.path) {
                reused += 1
            } else {
                let partial = output.appendingPathExtension("partial")
                try await compileC(source, to: partial, flags: flags, cStandard: cStandard, cxxStandard: cxxStandard, log: log)
                try? fileManager.removeItem(at: output)
                try fileManager.moveItem(at: partial, to: output)
                compiled += 1
            }
            if ["cc", "cpp", "cxx", "mm"].contains(source.pathExtension.lowercased()) { usesCxx = true }
            return output
        }

        // 1. Package modules, in dependency order.
        for module in request.plan.modules {
            let started = Date()
            packageLinkFlags += module.linkFlags
            switch module.language {
            case .binary:
                // Prebuilt code (.xcframework slices), system libraries and header-only targets.
                libraries += module.libraries
                if let headers = module.publicHeaders {
                    try exposeHeaders(headers, moduleName: module.name)
                }
                for framework in module.frameworks {
                    let folder = framework.deletingLastPathComponent()
                    let name = framework.deletingPathExtension().lastPathComponent
                    clangImportFlags += ["-F", folder.path]
                    clangHeaderPaths.append(framework.appendingPathComponent("Headers").path)
                    frameworkFlags += ["-F", folder.path, "-framework", name]
                    if Self.isDynamicLibrary(framework.appendingPathComponent(name)) {
                        // A dynamic framework is loaded next to the app at run time and must be signed like it.
                        dynamicFrameworkFlags += ["-F", folder.path, "-framework", name]
                        let copy = embeddedFrameworks.appendingPathComponent(framework.lastPathComponent)
                        if !fileManager.fileExists(atPath: copy.path) {
                            try fileManager.createDirectory(at: embeddedFrameworks, withIntermediateDirectories: true)
                            try fileManager.copyItem(at: framework, to: copy)
                            if let identity {
                                let signer = MachOSigner(privateKey: identity.privateKey, certificates: identity.certificates, teamID: identity.teamID)
                                try signer.sign(fileAt: copy.appendingPathComponent(name), identifier: name)
                            }
                        }
                    }
                }
                if !module.libraries.isEmpty || !module.frameworks.isEmpty {
                    log("Using \(module.name) (prebuilt).")
                }
                continue
            case .clang:
                log("Compiling \(module.name) (C, \(module.sources.count) file(s))…")
                let headerFlags = (module.publicHeaders.map { [$0.path] } ?? []).flatMap { ["-I", $0] }
                    + module.headerSearchPaths.flatMap { ["-I", $0.path] }
                    + clangHeaderPaths.flatMap { ["-I", $0] }
                let flags = clangCommon + headerFlags + module.defines.flatMap { ["-D", $0] } + module.cFlags
                for (index, source) in module.sources.enumerated() {
                    packageObjects.append(try await compileCached(source, flags: flags, cStandard: module.cStandard, cxxStandard: module.cxxStandard))
                    if module.sources.count >= 20, (index + 1) % 20 == 0 {
                        log("  \(index + 1) of \(module.sources.count) files…")
                    }
                }
                if let headers = module.publicHeaders {
                    try exposeHeaders(headers, moduleName: module.name)
                }
            case .swift:
                var moduleSources = module.sources
                if let bundleName = module.bundleName {
                    moduleSources.append(try resourceAccessor(name: bundleName, items: module.resources, in: cache.generated, log: log))
                }
                // The module's real name includes a hash of its sources and settings, so an unchanged
                // module is reused, and a changed one never clashes with the copy that is still loaded.
                let packageFlags = (module.packageName.map { ["-package-name", $0] } ?? [])
                    + (Self.importsBuiltin(moduleSources) && !module.swiftFlags.contains("BuiltinModule")
                       ? ["-enable-experimental-feature", "BuiltinModule"] : [])
                let settings = clangImportFlags + moduleSearchFlags + packageFlags + module.swiftFlags + module.swiftDefines.flatMap { ["-D", $0] }
                let key = cache.key([cache.fingerprint(moduleSources), module.name] + swiftCommon + settings)
                // The module keeps its name (its code and its clients write `MLX.…`); the ABI name, used in
                // symbols and runtime type names, includes the hash, so a changed package never clashes
                // with a copy that is still loaded.
                let abiName = "\(module.name)_p\(key)"
                let folder = cache.modules.appendingPathComponent("\(module.name)-\(key)", isDirectory: true)
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let output = cache.objects.appendingPathComponent("\(abiName).o")
                let interface = folder.appendingPathComponent("\(module.name).swiftmodule")
                if fileManager.fileExists(atPath: output.path), fileManager.fileExists(atPath: interface.path) {
                    reused += 1
                } else {
                    log("Compiling \(module.name) (Swift, \(module.sources.count) file(s))…")
                    let partial = output.appendingPathExtension("partial")
                    let arguments = ["swift-frontend", "-frontend", "-c"] + moduleSources.map(\.path) + swiftCommon + settings
                        + ["-module-name", module.name, "-module-abi-name", abiName,
                           "-emit-module-path", interface.path, "-o", partial.path]
                    try await compileSwift(arguments, output: partial, sourceRoot: request.workDirectory, log: log)
                    try? fileManager.removeItem(at: output)
                    try fileManager.moveItem(at: partial, to: output)
                    compiled += 1
                    log(String(format: "  %@ done in %.1f s.", module.name, Date().timeIntervalSince(started)))
                }
                packageObjects.append(output)
                moduleSearchFlags += ["-I", folder.path]
            }
        }
        if reused > 0 {
            log("Reused \(reused) compiled package file(s) from earlier builds.")
        }

        // 2. All package code in one dylib, kept by content: unchanged packages are not linked again,
        //    and iOS loads them once however often the app runs.
        var packagesDylib: URL?
        if !packageObjects.isEmpty || !libraries.isEmpty {
            let key = cache.key((packageObjects + libraries).map(\.lastPathComponent) + [cache.fingerprint(libraries)]
                                + frameworkFlags + packageLinkFlags + [usesCxx ? "c++" : "c"])
            let library = cache.dylibs.appendingPathComponent("Packages-\(key).dylib")
            if !fileManager.fileExists(atPath: library.path) {
                log("Linking packages…")
                let partial = cache.dylibs.appendingPathComponent("Packages-\(key).partial.dylib")
                let arguments = linkCommon + ["-install_name", library.path]
                    + packageObjects.map(\.path) + libraries.map(\.path) + frameworkFlags + Self.uniqueLinkFlags(packageLinkFlags)
                    + (fileManager.fileExists(atPath: embeddedFrameworks.path) ? ["-rpath", embeddedFrameworks.path] : [])
                    + (usesCxx || !libraries.isEmpty ? ["-lc++"] : []) + [builtins.path, "-o", partial.path]
                try link(arguments, output: partial, log: log)
                if let identity {
                    let signer = MachOSigner(privateKey: identity.privateKey, certificates: identity.certificates, teamID: identity.teamID)
                    try signer.sign(fileAt: partial, identifier: "app.kiln.packages.\(key)")
                }
                try? fileManager.removeItem(at: library)
                try fileManager.moveItem(at: partial, to: library)
            }
            packagesDylib = library
        }

        // 3. The app's own C, C++ and Objective-C files (used from Swift through the bridging header).
        var bridgingFlags: [String] = []
        if let header = request.plan.bridgingHeader {
            bridgingFlags = ["-import-objc-header", header.path, "-Xcc", "-I", "-Xcc", header.deletingLastPathComponent().path]
            let flags = clangCommon + ["-I", header.deletingLastPathComponent().path] + clangHeaderPaths.flatMap { ["-I", $0] }
            for source in request.plan.appCSources {
                objects.append(try await compileCached(source, flags: flags, cStandard: nil, cxxStandard: nil))
            }
        }

        // 4. The app.
        if let bundleName = request.plan.appBundleName {
            sourcePaths.append(try resourceAccessor(name: bundleName, items: request.plan.appResources, in: cache.generated, log: log).path)
        }
        log("Compiling \(sourcePaths.count) app file(s)…")
        let appPackageFlags = request.plan.appPackageName.map { ["-package-name", $0] } ?? []
        let compileArguments = ["swift-frontend", "-frontend", "-c"] + sourcePaths + swiftCommon + clangImportFlags + moduleSearchFlags
            + appPackageFlags
            + request.plan.appSwiftFlags + bridgingFlags + [
            "-module-name", appModuleName, "-module-abi-name", moduleName,
            "-o", object.path,
        ]
        let started = Date()
        try await compileSwift(compileArguments, output: object, sourceRoot: sourceRoot, log: log)
        objects.append(object)
        log(String(format: "Compiled in %.1f s.", Date().timeIntervalSince(started)))

        // 5. Link the app into a dylib that Kiln can load, against the packages dylib.
        log("Linking…")
        let linkArguments = linkCommon + ["-install_name", "@rpath/\(moduleName).dylib"]
            + objects.map(\.path) + (packagesDylib.map { [$0.path] } ?? []) + dynamicFrameworkFlags
            + Self.uniqueLinkFlags(request.plan.appLinkFlags)
            + (fileManager.fileExists(atPath: embeddedFrameworks.path) ? ["-rpath", embeddedFrameworks.path] : [])
            + (usesCxx ? ["-lc++"] : []) + [builtins.path, "-o", dylib.path]
        try link(linkArguments, output: dylib, log: log)

        // 3. Sign with the certificate from Settings, so iOS accepts it without JIT.
        if let identity {
            log("Signing with \(identity.name) (\(identity.teamID))…")
            let signer = MachOSigner(privateKey: identity.privateKey, certificates: identity.certificates, teamID: identity.teamID)
            try signer.sign(fileAt: dylib, identifier: "app.kiln.build.\(moduleName)")
        } else {
            log("No signing certificate in Settings: the app is ad-hoc signed, which iOS rejects unless code signing checks are bypassed.")
        }
        return BuildProduct(dylib: dylib)
    }

    // MARK: Compiling

    private func link(_ arguments: [String], output: URL, log: @Sendable (String) -> Void) throws {
        var linkerOutput: UnsafeMutablePointer<CChar>?
        let status = Self.withCArguments(arguments) { argc, argv in
            kiln_lld_link(argc, argv, &linkerOutput)
        }
        let text = linkerOutput.map { String(cString: $0) } ?? ""
        free(linkerOutput)
        for line in text.split(separator: "\n") where !line.contains("auto-linked framework not found") {
            log(String(line))
        }
        guard status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw BuildError.failed("Linking failed.")
        }
    }

    private func compileSwift(_ arguments: [String], output: URL, sourceRoot: URL, log: @Sendable (String) -> Void) async throws {
        let (status, text) = await Self.runOnLargeStack {
            Self.capturingStandardError {
                Self.withCArguments(arguments) { argc, argv in kiln_swift_frontend(argc, argv) }
            }
        }
        let diagnostics = Self.parseDiagnostics(text, sourceRoot: sourceRoot)
        if status != 0 || !FileManager.default.fileExists(atPath: output.path) {
            if !diagnostics.contains(where: { $0.severity == .error }) {
                log(text.isEmpty ? "The compiler failed with status \(status)." : text)
                throw BuildError.failed("The compiler failed with status \(status).")
            }
            throw BuildError.diagnostics(diagnostics)
        }
    }

    private func compileC(_ source: URL, to output: URL, flags: [String], cStandard: String?, cxxStandard: String?,
                          log: @Sendable (String) -> Void) async throws {
        // clang normally skips freeing its memory because its process ends right after; inside Kiln
        // that memory would pile up over hundreds of files until iOS stops the app.
        var arguments = ["clang", "-c", source.path, "-o", output.path, "-Xclang", "-no-disable-free"] + flags
        let cxx = "-std=\(cxxStandard ?? "gnu++17")"
        switch source.pathExtension {
        case "m": arguments += ["-fobjc-arc", "-std=\(cStandard ?? "gnu11")"]
        case "mm": arguments += ["-fobjc-arc", cxx]
        case "cc", "cpp", "cxx", "CC", "CPP": arguments += [cxx]
        case "s", "S": break
        default: arguments += ["-std=\(cStandard ?? "gnu11")"]
        }
        // A package's own -std= in unsafeFlags wins over the default.
        if flags.contains(where: { $0.hasPrefix("-std=") }), let index = arguments.lastIndex(where: { $0.hasPrefix("-std=") }),
           index >= arguments.count - 2 {
            arguments.remove(at: index)
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
            if !diagnostics.contains(where: { $0.severity == .error }) {
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
        let folder = directory.appendingPathComponent("\(name)-\(String(headers.path.hashValueStable, radix: 16)).modulemaps", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let umbrellaHeader = headers.appendingPathComponent("\(name).h")
        let body = FileManager.default.fileExists(atPath: umbrellaHeader.path)
            ? "umbrella header \"\(umbrellaHeader.path)\""
            : "umbrella \"\(headers.path)\""
        let map = folder.appendingPathComponent("module.modulemap")
        let contents = "module \(name) {\n    \(body)\n    export *\n}\n"
        if (try? String(contentsOf: map, encoding: .utf8)) != contents {
            try contents.write(to: map, atomically: true, encoding: .utf8)
        }
        return map
    }

    // MARK: Helpers

    /// Builds a resource bundle and writes the `Bundle.module` accessor for it.
    private func resourceAccessor(name: String, items: [ResourceItem], in directory: URL, log: @Sendable (String) -> Void) throws -> URL {
        log("Copying resources for \(name)…")
        let result = try ResourceBundler.build(name: name, items: items)
        result.warnings.forEach(log)
        let accessor = directory.appendingPathComponent("\(name)_resource_bundle_accessor.swift")
        let source = ResourceBundler.accessorSource(bundle: result.bundle)
        // Written only when it changes, so the build cache sees the same file.
        if (try? String(contentsOf: accessor, encoding: .utf8)) != source {
            try source.write(to: accessor, atomically: true, encoding: .utf8)
        }
        return accessor
    }

    /// True when a source file has `import Builtin` (swift-collections, swift-numerics), which needs the
    /// BuiltinModule feature that their manifests enable in ways Kiln cannot always read.
    static func importsBuiltin(_ files: [URL]) -> Bool {
        files.contains { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return text.range(of: #"(?m)^\s*(@\w+\s+)*import\s+Builtin\b"#, options: .regularExpression) != nil
        }
    }

    /// module.modulemap files in a headers folder or one level below it (as in many .xcframeworks).
    static func moduleMaps(in headers: URL) -> [URL] {
        let fileManager = FileManager.default
        var maps: [URL] = []
        let direct = headers.appendingPathComponent("module.modulemap")
        if fileManager.fileExists(atPath: direct.path) { maps.append(direct) }
        for child in (try? fileManager.contentsOfDirectory(at: headers, includingPropertiesForKeys: nil)) ?? [] {
            let map = child.appendingPathComponent("module.modulemap")
            if fileManager.fileExists(atPath: map.path) { maps.append(map) }
        }
        return maps
    }

    /// True for a Mach-O dynamic library (as opposed to a static archive).
    static func isDynamicLibrary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count == 16 else { return false }
        let bytes = [UInt8](header)
        let magic = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let fileType = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        return magic == 0xFEED_FACF && fileType == 6
    }

    /// Linker flags without repeats (`-framework X` counts as one flag).
    static func uniqueLinkFlags(_ flags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var index = 0
        while index < flags.count {
            let item = flags[index] == "-framework" && index + 1 < flags.count ? [flags[index], flags[index + 1]] : [flags[index]]
            index += item.count
            if seen.insert(item.joined(separator: " ")).inserted { result += item }
        }
        return result
    }

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
        // A fixed file that survives a crash: if the compiler aborts Kiln, the next build shows what it said.
        let url = compilerLogURL
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
        return (status, output)
    }

    static var compilerLogURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KilnLastCompilerOutput.log")
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
            case "error", "fatal error": severity = .error
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
