import Foundation
import Observation

/// GitHub sync for the open project: clone, pull, and commit & push.
@MainActor
@Observable
final class SyncController {
    static let tokenAccount = "github-token"

    /// Sync information of the open project, or nil when it is not linked to GitHub.
    private(set) var state: SyncState?
    private(set) var isSyncing = false
    private(set) var progress: String?
    private(set) var hasToken = !(Keychain.read(SyncController.tokenAccount) ?? "").isEmpty
    var message: String?
    var errorMessage: String?

    private var engine: GitSync {
        GitSync(client: GitHubClient(token: Keychain.read(Self.tokenAccount)))
    }

    func setToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(trimmed.isEmpty ? nil : trimmed, for: Self.tokenAccount)
        hasToken = !trimmed.isEmpty
    }

    func refresh(for root: URL?) {
        state = root.flatMap(SyncState.load)
    }

    /// Clones `owner/repo` into Kiln's projects folder and opens it.
    @discardableResult
    func clone(_ repository: String, branch: String, projects: ProjectStore) async -> Bool {
        guard let parsed = GitHubClient.parseRepository(repository) else {
            errorMessage = "Enter a repository as owner/name or a github.com link."
            return false
        }
        let owner = parsed.owner
        let repo = parsed.repo
        return await run {
            let engine = self.engine
            let trimmedBranch = branch.trimmingCharacters(in: .whitespaces)
            var branchName = trimmedBranch
            if branchName.isEmpty {
                branchName = try await engine.defaultBranch(owner: owner, repo: repo)
            }
            let folder = try Self.newProjectFolder(named: repo)
            let empty = SyncState(owner: owner, repo: repo, branch: branchName, commit: "", tree: "", files: [:])
            do {
                let result = try await engine.pull(root: folder, state: empty, overwriteLocal: true, progress: self.reporter)
                projects.open(folder)
                self.state = result.state
                self.message = "Cloned \(owner)/\(repo) (\(branchName)), \(result.updated.count) files."
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
    }

    func pull(_ projects: ProjectStore, overwriteLocal: Bool = false) async {
        guard let root = projects.root, let state else { return }
        projects.save()
        await run {
            let result = try await self.engine.pull(root: root, state: state, overwriteLocal: overwriteLocal, progress: self.reporter)
            self.state = result.state
            projects.reloadFromDisk()
            if result.upToDate {
                self.message = "Already up to date with \(state.branch)."
            } else {
                var parts = ["Pulled \(state.branch): \(result.updated.count) updated, \(result.deleted.count) deleted."]
                if !result.conflicts.isEmpty {
                    parts.append("Changed both here and on GitHub (kept yours, GitHub's version saved as .remote): "
                        + result.conflicts.joined(separator: ", "))
                }
                self.message = parts.joined(separator: "\n")
            }
        }
    }

    func changes(in projects: ProjectStore) async -> [LocalChange] {
        guard let root = projects.root, let state else { return [] }
        projects.save()
        return await Task.detached { GitSync.changes(in: root, since: state) }.value
    }

    @discardableResult
    func push(_ projects: ProjectStore, message commitMessage: String) async -> Bool {
        guard let root = projects.root, let state else { return false }
        projects.save()
        return await run {
            let newState = try await self.engine.push(root: root, state: state, message: commitMessage, progress: self.reporter)
            self.state = newState
            self.message = "Pushed to \(state.repositoryName) (\(state.branch))."
        }
    }

    // MARK: Helpers

    private var reporter: @Sendable (String) -> Void {
        { line in Task { @MainActor in self.progress = line } }
    }

    private func run(_ work: () async throws -> Void) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        progress = nil
        defer {
            isSyncing = false
            progress = nil
        }
        do {
            try await work()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private static func newProjectFolder(named name: String) throws -> URL {
        let projects = try ProjectStore.localProjectsFolder()
        var folder = projects.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = projects.appendingPathComponent("\(name) \(index)", isDirectory: true)
            index += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
