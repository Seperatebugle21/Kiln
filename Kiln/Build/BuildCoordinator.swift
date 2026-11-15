import Foundation
import Observation

/// Runs a build: save, syntax check, entry point generation, then the backend.
@MainActor
@Observable
final class BuildCoordinator {
    enum Phase: Equatable {
        case idle, building, succeeded, failed
    }

    private(set) var phase: Phase = .idle
    private(set) var log: [String] = []
    private(set) var diagnostics: [BuildDiagnostic] = []
    private(set) var product: BuildProduct?
    var backend: any BuildBackend = LocalToolchainBackend()

    var errors: [BuildDiagnostic] { diagnostics.filter { $0.severity == .error } }

    @discardableResult
    func build(_ project: ProjectStore) async -> Bool {
        guard phase != .building, project.root != nil else { return false }
        project.save()
        phase = .building
        log = []
        diagnostics = []
        product = nil
        append("Building \(project.name) with \(backend.name)")

        // Work out the modules: package dependencies (downloaded if needed), then the app.
        guard let root = project.root else { return false }
        let resolver = PackageResolver(projectRoot: root, token: Keychain.read(SyncController.tokenAccount)) { line in
            Task { @MainActor in self.append(line) }
        }
        let plan: BuildPlan
        do {
            plan = try await BuildPlanner.plan(root: root, resolver: resolver)
        } catch {
            return fail(error.localizedDescription)
        }
        plan.warnings.forEach(append)
        if !plan.modules.isEmpty {
            append("Packages: \(plan.modules.map(\.name).joined(separator: ", "))")
        }

        var sources: [SourceFile] = []
        for url in plan.appSources {
            let path = project.relativePath(of: url)
            do {
                sources.append(SourceFile(path: path, text: try project.readFile(path)))
            } catch {
                return fail("Could not read \(path): \(error.localizedDescription)")
            }
        }
        guard !sources.isEmpty else { return fail("The project has no Swift files.") }

        let inputs = sources
        let found = await Task.detached(priority: .userInitiated) {
            inputs.flatMap(SyntaxChecker.check)
        }.value
        diagnostics = found
        if !errors.isEmpty {
            return fail("Syntax check found \(errors.count) error(s).")
        }
        append("Syntax check passed for \(sources.count) file(s).")

        let prepared: [SourceFile]
        do {
            prepared = try EntryPointGenerator.prepare(sources)
        } catch {
            return fail(error.localizedDescription)
        }
        append("Generated entry point \(EntryPointGenerator.entrySymbol).")

        let request: BuildRequest
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("KilnBuilds", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            request = BuildRequest(projectName: project.name, sources: prepared, workDirectory: work, plan: plan)
        } catch {
            return fail(error.localizedDescription)
        }

        do {
            let result = try await backend.build(request) { line in
                Task { @MainActor in self.append(line) }
            }
            product = result
            phase = .succeeded
            append("Build succeeded.")
            return true
        } catch BuildError.diagnostics(let compilerDiagnostics) {
            diagnostics = compilerDiagnostics
            return fail("Compilation failed with \(errors.count) error(s).")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// A plain-text summary, used by the assistant's build tool.
    func report() -> String {
        var lines = log
        if !diagnostics.isEmpty {
            lines.append("")
            lines.append(contentsOf: diagnostics.map(\.summary))
        }
        return lines.joined(separator: "\n")
    }

    private func append(_ line: String) {
        log.append(line)
    }

    private func fail(_ message: String) -> Bool {
        append(message)
        phase = .failed
        return false
    }
}
