import Foundation

/// A package checked out on disk, with its manifest.
struct ResolvedPackage {
    var identity: String
    var root: URL
    var manifest: PackageManifest
}

/// Finds and downloads Swift package dependencies: local ones by path, remote ones from GitHub
/// (source tarballs from codeload.github.com), at the version pinned in Package.resolved or the
/// newest tag that satisfies the requirement.
final class PackageResolver: @unchecked Sendable {
    enum Failure: LocalizedError {
        case notGitHub(String)
        case noMatchingVersion(String, String)
        case download(String, Int)
        case missingManifest(String)

        var errorDescription: String? {
            switch self {
            case .notGitHub(let url):
                return "\(url): Kiln can only download packages hosted on GitHub."
            case .noMatchingVersion(let package, let requirement):
                return "\(package): no version matches \(requirement)."
            case .download(let package, let status):
                return "\(package): download failed (HTTP \(status))."
            case .missingManifest(let path):
                return "No Package.swift in \(path)."
            }
        }
    }

    private let pins: [String: String]
    private let token: String?
    private let log: @Sendable (String) -> Void

    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KilnPackages", isDirectory: true)
    }

    init(projectRoot: URL, token: String?, log: @escaping @Sendable (String) -> Void) {
        self.pins = Self.readPins(in: projectRoot)
        self.token = token
        self.log = log
    }

    func resolve(_ dependency: PackageManifest.Dependency, relativeTo base: URL) async throws -> ResolvedPackage {
        switch dependency.location {
        case .path(let path):
            let root = base.appendingPathComponent(path).standardizedFileURL
            return try load(identity: dependency.identity, root: root)
        case .url(let url):
            guard let repository = Self.gitHubRepository(url) else { throw Failure.notGitHub(url) }
            let owner = repository.owner
            let repo = repository.repo
            let revision = try await revision(for: dependency, owner: owner, repo: repo)
            let root = Self.cacheRoot
                .appendingPathComponent(dependency.identity, isDirectory: true)
                .appendingPathComponent(revision.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
                log("Downloading \(owner)/\(repo) @ \(revision)…")
                try await download(owner: owner, repo: repo, revision: revision, to: root)
            }
            return try load(identity: dependency.identity, root: root)
        }
    }

    private func load(identity: String, root: URL) throws -> ResolvedPackage {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
            throw Failure.missingManifest(root.path)
        }
        return ResolvedPackage(identity: identity, root: root, manifest: try PackageManifest.load(from: root))
    }

    // MARK: Versions

    private func revision(for dependency: PackageManifest.Dependency, owner: String, repo: String) async throws -> String {
        if let pinned = pins[dependency.identity] { return pinned }
        switch dependency.requirement {
        case .revision(let revision), .branch(let revision):
            return revision
        case .exact(let version):
            return try await tag(owner: owner, repo: repo) { Self.version($0) == Self.version(version) } ?? version
        case .from(let lower):
            guard let minimum = Self.version(lower) else { throw Failure.noMatchingVersion(repo, "from: \(lower)") }
            let tag = try await tag(owner: owner, repo: repo) { candidate in
                guard let version = Self.version(candidate) else { return false }
                return version.first == minimum.first && !version.lexicographicallyPrecedes(minimum)
            }
            guard let tag else { throw Failure.noMatchingVersion(repo, "from: \(lower)") }
            return tag
        case .range(let lower, let upper):
            guard let minimum = Self.version(lower), let maximum = Self.version(upper) else {
                throw Failure.noMatchingVersion(repo, "\(lower)..<\(upper)")
            }
            let tag = try await tag(owner: owner, repo: repo) { candidate in
                guard let version = Self.version(candidate) else { return false }
                return !version.lexicographicallyPrecedes(minimum) && version.lexicographicallyPrecedes(maximum)
            }
            guard let tag else { throw Failure.noMatchingVersion(repo, "\(lower)..<\(upper)") }
            return tag
        case .none:
            return "HEAD"
        }
    }

    /// The highest tag accepted by `matches`.
    private func tag(owner: String, repo: String, where matches: (String) -> Bool) async throws -> String? {
        var tags: [String] = []
        for page in 1...5 {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/tags?per_page=100&page=\(page)")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { break }
            tags += list.compactMap { $0["name"] as? String }
            if list.count < 100 { break }
        }
        return tags
            .filter { Self.version($0) != nil && matches($0) }
            .max { (Self.version($0) ?? []).lexicographicallyPrecedes(Self.version($1) ?? []) }
    }

    /// "v1.2.3" or "1.2" → [1, 2, 3] / [1, 2, 0]; pre-release tags are skipped.
    static func version(_ text: String) -> [Int]? {
        var value = text
        if value.hasPrefix("v") { value.removeFirst() }
        guard !value.contains("-") else { return nil }
        let parts = value.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        return numbers + [Int](repeating: 0, count: 3 - numbers.count)
    }

    // MARK: Download

    private func download(owner: String, repo: String, revision: String, to root: URL) async throws {
        let url = URL(string: "https://codeload.github.com/\(owner)/\(repo)/tar.gz/\(revision)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.download(repo, status) }
        let staging = root.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: staging)
        try TarGzip.extract(data, to: staging, stripComponents: 1)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: root)
    }

    static func gitHubRepository(_ url: String) -> (owner: String, repo: String)? {
        var value = url
        for prefix in ["https://", "http://", "git@", "ssh://git@"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        value = value.replacingOccurrences(of: "github.com:", with: "github.com/")
        guard value.hasPrefix("github.com/") else { return nil }
        let parts = value.dropFirst("github.com/".count).split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        return (owner: parts[0], repo: repo)
    }

    // MARK: Package.resolved

    /// identity → revision, from every Package.resolved in the project (SwiftPM and Xcode locations).
    private static func readPins(in root: URL) -> [String: String] {
        var files: [URL] = [root.appendingPathComponent("Package.resolved")]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if url.pathComponents.contains(where: { ["build", ".build", "DerivedData", "Pods", "node_modules"].contains($0) }) {
                    enumerator.skipDescendants()
                    continue
                }
                if url.lastPathComponent == "Package.resolved" { files.append(url) }
            }
        }
        var pins: [String: String] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let list = (json["pins"] as? [[String: Any]]) ?? ((json["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
            for pin in list {
                let location = (pin["location"] as? String) ?? (pin["repositoryURL"] as? String) ?? ""
                let identity = (pin["identity"] as? String)
                    ?? PackageManifest.Dependency(location: .url(location), requirement: .none, name: nil).identity
                if let state = pin["state"] as? [String: Any], let revision = state["revision"] as? String {
                    pins[identity.lowercased()] = revision
                }
            }
        }
        return pins
    }
}
