import CryptoKit
import Foundation

/// What a project folder last synced with: stored in `.kiln/sync.json` inside the project.
struct SyncState: Codable, Sendable {
    struct FileEntry: Codable, Sendable, Equatable {
        var sha: String
        var mode: String
    }

    var owner: String
    var repo: String
    var branch: String
    /// The commit the local files are based on.
    var commit: String
    var tree: String
    /// Path → blob at `commit`, for every file Kiln checked out.
    var files: [String: FileEntry]

    var repositoryName: String { "\(owner)/\(repo)" }

    private static func url(in root: URL) -> URL {
        root.appendingPathComponent(".kiln", isDirectory: true).appendingPathComponent("sync.json")
    }

    static func load(from root: URL) -> SyncState? {
        guard let data = try? Data(contentsOf: url(in: root)) else { return nil }
        return try? JSONDecoder().decode(SyncState.self, from: data)
    }

    func save(to root: URL) throws {
        let url = Self.url(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct LocalChange: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case added = "A", modified = "M", deleted = "D"
    }

    var id: String { path }
    var path: String
    var kind: Kind
}

struct PullResult: Sendable {
    var state: SyncState
    var updated: [String] = []
    var deleted: [String] = []
    /// Files changed both here and on GitHub. The local file is kept; GitHub's version is saved as `<file>.remote`.
    var conflicts: [String] = []
    var upToDate = false
}

enum SyncError: LocalizedError {
    case remoteChanged
    case nothingToPush
    case emptyRepository
    case repositoryTooLarge
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .remoteChanged: return "GitHub has newer commits. Pull first, then push."
        case .nothingToPush: return "There are no local changes to push."
        case .emptyRepository: return "The repository has no commits yet. Add a file on GitHub first (for example a README)."
        case .repositoryTooLarge: return "The repository is too large to sync with Kiln."
        case .invalidResponse: return "GitHub returned data Kiln could not read."
        }
    }
}

/// Syncs a project folder with a GitHub branch through the Git data API (no git binary needed).
struct GitSync: Sendable {
    let client: GitHubClient

    static let maxFileSize = 20_000_000
    private static let excludedComponents: Set<String> = [
        ".git", ".kiln", "build", ".build", "DerivedData", "xcuserdata", "Pods", "node_modules",
    ]

    /// Whether Kiln syncs this path. Build output, git metadata and conflict copies are left out.
    static func isTracked(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { excludedComponents.contains($0) }) { return false }
        if components.last == ".DS_Store" || path.hasSuffix(".remote") { return false }
        return true
    }

    /// Git's object id for a file: SHA-1 of "blob <size>\0" followed by the contents.
    static func blobSHA(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\u{0}".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every tracked regular file in the folder, by relative path.
    static func localFiles(in root: URL) -> [String: URL] {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else { return [:] }

        var files: [String: URL] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if excludedComponents.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if isTracked(relative) { files[relative] = url }
        }
        return files
    }

    static func changes(in root: URL, since state: SyncState) -> [LocalChange] {
        let local = localFiles(in: root)
        var changes: [LocalChange] = []
        for (path, url) in local {
            guard let data = try? Data(contentsOf: url), data.count <= maxFileSize else { continue }
            if let base = state.files[path] {
                if base.sha != blobSHA(data) { changes.append(LocalChange(path: path, kind: .modified)) }
            } else {
                changes.append(LocalChange(path: path, kind: .added))
            }
        }
        for path in state.files.keys where local[path] == nil {
            changes.append(LocalChange(path: path, kind: .deleted))
        }
        return changes.sorted { $0.path < $1.path }
    }

    // MARK: Remote

    private func repoPath(_ state: SyncState) -> String {
        "/repos/\(state.owner)/\(state.repo)"
    }

    func defaultBranch(owner: String, repo: String) async throws -> String {
        let info = try await client.get("/repos/\(owner)/\(repo)")
        return info["default_branch"]?.stringValue ?? "main"
    }

    func headCommit(_ state: SyncState) async throws -> String {
        do {
            let ref = try await client.get(repoPath(state) + "/git/ref/heads/\(state.branch)")
            guard let sha = ref["object"]?["sha"]?.stringValue else { throw SyncError.invalidResponse }
            return sha
        } catch let error as GitHubClient.Failure where error.status == 409 {
            throw SyncError.emptyRepository
        }
    }

    // MARK: Pull

    /// Brings the folder to the branch's latest commit while keeping local edits.
    /// With `overwriteLocal`, local edits to synced files are replaced by GitHub's version.
    func pull(
        root: URL,
        state: SyncState,
        overwriteLocal: Bool,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> PullResult {
        progress("Checking \(state.repositoryName)…")
        let head = try await headCommit(state)
        if head == state.commit && !overwriteLocal {
            return PullResult(state: state, upToDate: true)
        }

        let commit = try await client.get(repoPath(state) + "/git/commits/\(head)")
        guard let treeSHA = commit["tree"]?["sha"]?.stringValue else { throw SyncError.invalidResponse }
        let tree = try await client.get(repoPath(state) + "/git/trees/\(treeSHA)?recursive=1")
        if tree["truncated"] == .bool(true) { throw SyncError.repositoryTooLarge }

        var remote: [String: SyncState.FileEntry] = [:]
        for entry in tree["tree"]?.arrayValue ?? [] {
            guard entry["type"]?.stringValue == "blob",
                  let path = entry["path"]?.stringValue,
                  let sha = entry["sha"]?.stringValue,
                  let mode = entry["mode"]?.stringValue,
                  mode != "120000",
                  Self.isTracked(path)
            else { continue }
            if case .number(let size) = entry["size"], Int(size) > Self.maxFileSize { continue }
            remote[path] = SyncState.FileEntry(sha: sha, mode: mode)
        }

        let local = Self.localFiles(in: root)
        var downloads: [(path: String, sha: String)] = []
        var result = PullResult(state: state)

        for path in Set(remote.keys).union(state.files.keys).sorted() {
            let remoteSHA = remote[path]?.sha
            let baseSHA = state.files[path]?.sha
            let localSHA = local[path].flatMap { try? Data(contentsOf: $0) }.map(Self.blobSHA)

            if localSHA == remoteSHA { continue }
            if remoteSHA == baseSHA && !overwriteLocal { continue } // Only changed here: keep it.

            if overwriteLocal || localSHA == baseSHA {
                if let remoteSHA {
                    downloads.append((path, remoteSHA))
                    result.updated.append(path)
                } else {
                    result.deleted.append(path)
                }
            } else {
                result.conflicts.append(path)
                if let remoteSHA { downloads.append((path + ".remote", remoteSHA)) }
            }
        }

        try await download(downloads, from: state, into: root, progress: progress)
        for path in result.deleted {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
        }

        result.state.commit = head
        result.state.tree = treeSHA
        result.state.files = remote
        try result.state.save(to: root)
        return result
    }

    private func download(
        _ files: [(path: String, sha: String)],
        from state: SyncState,
        into root: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        var done = 0
        for start in stride(from: 0, to: files.count, by: 8) {
            let batch = Array(files[start..<min(start + 8, files.count)])
            try await withThrowingTaskGroup(of: (String, Data).self) { group in
                for file in batch {
                    group.addTask {
                        let blob = try await client.get(repoPath(state) + "/git/blobs/\(file.sha)")
                        guard let content = blob["content"]?.stringValue,
                              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters)
                        else { throw SyncError.invalidResponse }
                        return (file.path, data)
                    }
                }
                for try await (path, data) in group {
                    let url = root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    done += 1
                    progress("Downloaded \(done) of \(files.count) files")
                }
            }
        }
    }

    // MARK: Push

    /// Commits every local change as one commit on the branch.
    func push(
        root: URL,
        state: SyncState,
        message: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> SyncState {
        progress("Checking \(state.repositoryName)…")
        let head = try await headCommit(state)
        guard head == state.commit else { throw SyncError.remoteChanged }

        let changes = Self.changes(in: root, since: state)
        guard !changes.isEmpty else { throw SyncError.nothingToPush }

        var entries: [JSONValue] = []
        var files = state.files
        for (index, change) in changes.enumerated() {
            let mode = state.files[change.path]?.mode ?? "100644"
            if change.kind == .deleted {
                entries.append(["path": .string(change.path), "mode": .string(mode), "type": "blob", "sha": .null])
                files[change.path] = nil
                continue
            }
            progress("Uploading \(index + 1) of \(changes.count): \(change.path)")
            let data = try Data(contentsOf: root.appendingPathComponent(change.path))
            let blob = try await client.send(
                "POST", repoPath(state) + "/git/blobs",
                body: ["content": .string(data.base64EncodedString()), "encoding": "base64"]
            )
            guard let sha = blob["sha"]?.stringValue else { throw SyncError.invalidResponse }
            entries.append(["path": .string(change.path), "mode": .string(mode), "type": "blob", "sha": .string(sha)])
            files[change.path] = SyncState.FileEntry(sha: sha, mode: mode)
        }

        progress("Creating commit…")
        var treeBody: [String: JSONValue] = ["tree": .array(entries)]
        if !state.tree.isEmpty { treeBody["base_tree"] = .string(state.tree) }
        let tree = try await client.send("POST", repoPath(state) + "/git/trees", body: .object(treeBody))
        guard let treeSHA = tree["sha"]?.stringValue else { throw SyncError.invalidResponse }

        let commit = try await client.send(
            "POST", repoPath(state) + "/git/commits",
            body: ["message": .string(message), "tree": .string(treeSHA), "parents": [.string(head)]]
        )
        guard let commitSHA = commit["sha"]?.stringValue else { throw SyncError.invalidResponse }

        progress("Pushing to \(state.branch)…")
        do {
            _ = try await client.send(
                "PATCH", repoPath(state) + "/git/refs/heads/\(state.branch)",
                body: ["sha": .string(commitSHA), "force": false]
            )
        } catch let error as GitHubClient.Failure where error.status == 422 {
            throw SyncError.remoteChanged
        }

        var newState = state
        newState.commit = commitSHA
        newState.tree = treeSHA
        newState.files = files
        try newState.save(to: root)
        return newState
    }
}
