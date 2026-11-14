import Foundation
import Observation

enum ProjectKind: String {
    case xcodeProject = "Xcode project"
    case swiftPackage = "Swift package"
    case folder = "Folder"
}

struct FileNode: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    var systemImage: String {
        if isDirectory { return "folder" }
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "xcodeproj", "xcworkspace": return "hammer"
        case "xcassets": return "photo.on.rectangle"
        case "plist", "json", "yml", "yaml", "entitlements": return "doc.badge.gearshape"
        case "md", "txt": return "doc.text"
        default: return "doc"
        }
    }
}

enum ProjectError: LocalizedError {
    case noProject
    case outsideProject(String)
    case notText(String)

    var errorDescription: String? {
        switch self {
        case .noProject: return "No project is open."
        case .outsideProject(let path): return "\(path) is outside the project folder."
        case .notText(let path): return "\(path) is not a UTF-8 text file."
        }
    }
}

/// The open project: its files on disk, the file in the editor and its unsaved text.
@MainActor
@Observable
final class ProjectStore {
    private(set) var root: URL?
    private(set) var kind: ProjectKind = .folder
    private(set) var tree: [FileNode] = []
    private(set) var selectedFile: URL?
    private(set) var buffer = ""
    private(set) var isDirty = false
    var errorMessage: String?

    private var securityScopedURL: URL?
    private static let bookmarkKey = "kiln.lastProjectBookmark"

    /// Folders that never contain project sources.
    static let ignoredDirectoryNames: Set<String> = [
        "build", ".build", "DerivedData", "xcuserdata", "Pods", "node_modules",
    ]

    /// Bundles that are shown as one item instead of being expanded.
    static let opaqueExtensions: Set<String> = ["xcodeproj", "xcworkspace", "xcassets", "xcframework"]

    var name: String { root?.deletingPathExtension().lastPathComponent ?? "" }

    // MARK: Opening and closing

    func open(_ url: URL) {
        close(forget: false)
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
        root = url
        kind = ProjectDetector.kind(of: url)
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        reloadTree()
        if let main = ProjectDetector.preferredStartFile(in: swiftFiles()) {
            select(main)
        }
    }

    func restoreLastProject() {
        guard root == nil, let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return
        }
        open(url)
    }

    func close(forget: Bool = true) {
        save()
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        root = nil
        tree = []
        selectedFile = nil
        buffer = ""
        isDirty = false
        if forget {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        }
    }

    /// Creates a small SwiftUI app in the app's Documents folder and opens it.
    func createSampleProject() {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let projectsFolder = documents.appendingPathComponent("Projects", isDirectory: true)
            var folder = projectsFolder.appendingPathComponent("HelloKiln", isDirectory: true)
            var index = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = projectsFolder.appendingPathComponent("HelloKiln \(index)", isDirectory: true)
                index += 1
            }
            let sources = folder.appendingPathComponent("HelloKiln", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try SampleProject.appSource.write(to: sources.appendingPathComponent("HelloKilnApp.swift"), atomically: true, encoding: .utf8)
            try SampleProject.contentViewSource.write(to: sources.appendingPathComponent("ContentView.swift"), atomically: true, encoding: .utf8)
            open(folder)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: File tree

    func reloadTree() {
        guard let root else { tree = []; return }
        tree = Self.children(of: root, depth: 0)
    }

    private static func children(of directory: URL, depth: Int) -> [FileNode] {
        guard depth < 16,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        let nodes: [FileNode] = urls.compactMap { url in
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory && ignoredDirectoryNames.contains(name) { return nil }
            if isDirectory && !opaqueExtensions.contains(url.pathExtension) {
                return FileNode(url: url, name: name, isDirectory: true, children: children(of: url, depth: depth + 1))
            }
            return FileNode(url: url, name: name, isDirectory: false, children: nil)
        }
        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Every file in the project, relative to the project folder.
    func allFilePaths() -> [String] {
        guard let root else { return [] }
        return Self.walk(root).map { relativePath(of: $0) }.sorted()
    }

    /// The Swift sources that make up the app (tests are left out).
    func swiftFiles() -> [URL] {
        guard let root else { return [] }
        return Self.walk(root)
            .filter { $0.pathExtension == "swift" }
            .filter { url in
                !url.pathComponents.contains { $0.hasSuffix("Tests") || $0 == "Package.swift" }
            }
            .sorted { $0.path < $1.path }
    }

    private static func walk(_ root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if ignoredDirectoryNames.contains(url.lastPathComponent) || opaqueExtensions.contains(url.pathExtension) {
                    enumerator.skipDescendants()
                }
                continue
            }
            files.append(url)
        }
        return files
    }

    // MARK: Paths

    func relativePath(of url: URL) -> String {
        guard let root else { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    /// Resolves a project-relative path and refuses paths that leave the project folder.
    func resolve(_ relativePath: String) throws -> URL {
        guard let root else { throw ProjectError.noProject }
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let url = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw ProjectError.outsideProject(relativePath)
        }
        return url
    }

    // MARK: Editor

    func select(_ url: URL) {
        save()
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ProjectError.notText(url.lastPathComponent)
            }
            selectedFile = url
            buffer = text
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateBuffer(_ text: String) {
        guard text != buffer else { return }
        buffer = text
        isDirty = true
    }

    func save() {
        guard isDirty, let selectedFile else { return }
        do {
            try buffer.write(to: selectedFile, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Reading and writing (used by the editor and the assistant)

    func readFile(_ relativePath: String) throws -> String {
        let url = try resolve(relativePath)
        if url == selectedFile?.standardizedFileURL { return buffer }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw ProjectError.notText(relativePath) }
        return text
    }

    func fileExists(_ relativePath: String) -> Bool {
        guard let url = try? resolve(relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func writeFile(_ relativePath: String, contents: String) throws {
        let url = try resolve(relativePath)
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if url == selectedFile?.standardizedFileURL {
            buffer = contents
            isDirty = false
        }
        if isNew { reloadTree() }
    }

    func createFile(named name: String, in directory: URL?) {
        guard let root else { return }
        let folder = directory ?? root
        let fileName = name.contains(".") ? name : name + ".swift"
        let url = folder.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "\(fileName) already exists."
            return
        }
        let typeName = url.deletingPathExtension().lastPathComponent
        let contents = url.pathExtension == "swift" ? SampleProject.newViewSource(named: typeName) : ""
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            reloadTree()
            select(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            if let selectedFile, selectedFile.path.hasPrefix(url.path) {
                self.selectedFile = nil
                buffer = ""
                isDirty = false
            }
            reloadTree()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
