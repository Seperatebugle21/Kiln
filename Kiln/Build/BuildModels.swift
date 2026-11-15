import Foundation

struct BuildDiagnostic: Identifiable, Hashable, Sendable {
    enum Severity: String, Sendable {
        case error, warning, note
    }

    let id = UUID()
    var severity: Severity
    var file: String
    var line: Int
    var column: Int
    var message: String

    var summary: String {
        "\(file):\(line):\(column): \(severity.rawValue): \(message)"
    }
}

struct SourceFile: Sendable {
    /// Path relative to the project folder.
    var path: String
    var text: String
}

/// Everything a backend needs to turn a project into a loadable dylib.
struct BuildRequest: Sendable {
    var projectName: String
    /// The app's Swift sources with `@main` removed, plus the generated entry point.
    var sources: [SourceFile]
    /// A fresh, writable folder for this build's intermediate files and product.
    var workDirectory: URL
    /// Package modules to build first, and the app's C sources and bridging header.
    var plan = BuildPlan()
}

struct BuildProduct: Sendable {
    var dylib: URL
    /// The app's own resources (strings, images, files), which Bundle.main falls back to while it runs.
    var resourceBundle: URL? = nil
}

enum BuildError: LocalizedError {
    case diagnostics([BuildDiagnostic])
    case backendUnavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .diagnostics(let diagnostics):
            return "\(diagnostics.filter { $0.severity == .error }.count) error(s)"
        case .backendUnavailable(let reason):
            return reason
        case .failed(let reason):
            return reason
        }
    }
}

/// Turns prepared sources into a dylib that exports `kiln_entry`.
protocol BuildBackend: Sendable {
    var name: String { get }
    func build(_ request: BuildRequest, log: @escaping @Sendable (String) -> Void) async throws -> BuildProduct
}
