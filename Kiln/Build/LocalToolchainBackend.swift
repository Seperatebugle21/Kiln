import Darwin
import Foundation

/// Compiles on the device with the Swift compiler and lld linked into Kiln.
///
/// The bundled `Toolchain/` folder holds what the compiler reads:
///   SDK/iPhoneOS.sdk        Swift interfaces, headers and .tbd stubs of the iOS SDK
///   resources/              the compiler's resource directory (Clang headers, Swift shims)
///   lib/libclang_rt.ios.a   Clang's runtime helpers (for example #available checks)
///
/// Pipeline: swift-frontend in frontend mode (whole module) → object file → lld → dylib.
/// The dylib is ad-hoc signed for now, which iOS only loads while JIT (a debugger) is enabled;
/// signing with the developer certificate comes next.
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
        let sdk = toolchain.appendingPathComponent("SDK/iPhoneOS.sdk")
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

        // 1. Compile.
        let firstBuild = (try? fileManager.contentsOfDirectory(atPath: Self.moduleCacheURL.path))?.isEmpty ?? true
        log(firstBuild
            ? "Compiling \(sourcePaths.count) file(s). The first build prepares SwiftUI, UIKit and Foundation and can take a few minutes."
            : "Compiling \(sourcePaths.count) file(s)…")
        let compileArguments = ["swift-frontend", "-frontend", "-c"] + sourcePaths + [
            "-target", Self.target,
            "-sdk", sdk.path,
            "-resource-dir", resources.path,
            "-module-name", moduleName,
            "-parse-as-library",
            "-Onone",
            "-module-cache-path", Self.moduleCacheURL.path,
            "-o", object.path,
        ]
        let started = Date()
        let (compileStatus, compilerOutput) = await Self.runOnLargeStack {
            Self.capturingStandardError {
                Self.withCArguments(compileArguments) { argc, argv in
                    kiln_swift_frontend(argc, argv)
                }
            }
        }
        let diagnostics = Self.parseDiagnostics(compilerOutput, sourceRoot: sourceRoot)
        if compileStatus != 0 || !fileManager.fileExists(atPath: object.path) {
            if diagnostics.isEmpty {
                log(compilerOutput.isEmpty ? "The compiler failed with status \(compileStatus)." : compilerOutput)
                throw BuildError.failed("The compiler failed with status \(compileStatus).")
            }
            throw BuildError.diagnostics(diagnostics)
        }
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
            object.path,
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
        return BuildProduct(dylib: dylib)
    }

    // MARK: Helpers

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
