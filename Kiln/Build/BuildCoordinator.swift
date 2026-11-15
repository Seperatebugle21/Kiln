import Foundation
import Observation
import UIKit

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

    /// This build's file in Documents/Build Logs.
    private var logFile: URL?

    init() {
        recoverCrashedLog()
    }

    @discardableResult
    func build(_ project: ProjectStore) async -> Bool {
        guard phase != .building, project.root != nil else { return false }
        project.save()
        phase = .building
        // Large builds (MLX has hundreds of C++ files) take a while; iOS stops them if the screen locks.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            UserDefaults.standard.removeObject(forKey: Self.stepKey)
            UserDefaults.standard.removeObject(forKey: Self.logFileKey)
        }
        log = []
        diagnostics = []
        product = nil
        reportPreviousCrash()
        logFile = BuildLogStore.start(project: project.name)
        UserDefaults.standard.set(logFile?.path, forKey: Self.logFileKey)
        for line in log { BuildLogStore.append(line, to: logFile) }
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
            BuildLogStore.finish(logFile, result: .succeeded)
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
        BuildLogStore.append(line, to: logFile)
        if phase == .building {
            UserDefaults.standard.set(line, forKey: Self.stepKey)
        }
    }

    /// The last log line of a build in progress; still set at the next launch if Kiln crashed.
    private static let stepKey = "kiln.buildStepInProgress"
    private static let logFileKey = "kiln.buildLogFileInProgress"

    /// At launch: completes the log file of a build that crashed Kiln with the compiler's last output.
    private func recoverCrashedLog() {
        guard let path = UserDefaults.standard.string(forKey: Self.logFileKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.logFileKey)
        let file = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        BuildLogStore.append("", to: file)
        BuildLogStore.append("⚠️ Kiln stopped during this build (a crash).", to: file)
        let output = (try? String(contentsOf: LocalToolchainBackend.compilerLogURL, encoding: .utf8)) ?? ""
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BuildLogStore.append("Last compiler output:\n" + output.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n"), to: file)
        }
        BuildLogStore.finish(file, result: .crashed)
    }

    /// If the previous build ended in a crash, shows where, and what the compiler said last.
    private func reportPreviousCrash() {
        guard let step = UserDefaults.standard.string(forKey: Self.stepKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        log.append("⚠️ The previous build stopped Kiln during: \(step)")
        let output = (try? String(contentsOf: LocalToolchainBackend.compilerLogURL, encoding: .utf8)) ?? ""
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(60)
        if !lines.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log.append("Last compiler output before the crash:\n" + lines.joined(separator: "\n"))
        }
    }

    private func fail(_ message: String) -> Bool {
        append(message)
        for diagnostic in diagnostics {
            BuildLogStore.append(diagnostic.summary, to: logFile)
        }
        BuildLogStore.finish(logFile, result: .failed)
        phase = .failed
        return false
    }
}
