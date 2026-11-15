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
        switch url.pathExtension.lowercased() {
        case "swiftpm": return "shippingbox"
        case "zip": return "doc.zipper"
        case "xcodeproj", "xcworkspace": return "hammer"
        case "xcassets": return "photo.on.rectangle"
        case "pbxproj", "xcscheme", "xcworkspacedata": return "doc.badge.gearshape"
        default: break
        }
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

/// A project opened from outside Kiln. `scopeBookmark` is the folder iOS granted access to;
/// the project is at `relativePath` inside it (empty when it is that folder).
struct RecentProject: Codable, Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var scopeBookmark: Data
    var relativePath: String

    static func load(key: String) -> [RecentProject] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentProject].self, from: data)) ?? []
    }

    static func save(_ recents: [RecentProject], key: String) {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: key)
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
    /// Goes up every time a file is opened, so the UI can show the editor even for the same file.
    private(set) var fileOpenCount = 0
    var errorMessage: String?

    private var securityScopedURL: URL?
    private static let reopenKey = "kiln.reopenLastProject"
    private static let lastProjectKey = "kiln.lastProject"
    private static let recentsKey = "kiln.recentProjects"
    private static let grantsKey = "kiln.folderGrants"

    /// Projects opened from outside Kiln (Files, iCloud Drive, other apps), newest first.
    private(set) var recentProjects: [RecentProject] = RecentProject.load(key: ProjectStore.recentsKey)

    /// Folders that never contain project sources.
    static let ignoredDirectoryNames: Set<String> = [
        "build", ".build", "DerivedData", "xcuserdata", "Pods", "node_modules",
    ]

    /// Bundles that are shown as one item instead of being expanded (prebuilt binaries).
    /// Xcode projects, workspaces and asset catalogs open like folders, so project.pbxproj,
    /// schemes and Contents.json can be read and edited.
    static let opaqueExtensions: Set<String> = ["xcframework", "framework"]

    var name: String { root?.deletingPathExtension().lastPathComponent ?? "" }

    // MARK: Opening and closing

    /// Opens a project folder (or a zipped project) that the user picked or tapped.
    func open(_ url: URL) {
        open(url, scope: nil)
    }

    /// The name of the project being copied into Kiln, while that runs.
    private(set) var importingName: String?

    /// Opens `url`. `scope` is a security-scoped folder that contains it and is already being accessed.
    private func open(_ url: URL, scope: URL?) {
        // Projects from outside Kiln are copied into its Projects folder first, so they always reopen.
        if let local = try? Self.localProjectsFolder(), !Self.path(url, isInside: local) {
            importCopy(of: url, scope: scope, into: local)
            return
        }
        // A zipped project (a .swiftpm sent as one file): unpack it into Kiln's Projects folder first.
        if !Self.isDirectory(url) {
            scope?.stopAccessingSecurityScopedResource()
            importArchive(url)
            return
        }
        // Opening a folder inside the current project (a .swiftpm in a repo) keeps the parent's access.
        var keptScope = scope
        if keptScope == nil, let current = securityScopedURL, Self.path(url, isInside: current) {
            keptScope = current
            securityScopedURL = nil
        }
        close(forget: false)
        if let keptScope {
            securityScopedURL = keptScope
        } else if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
        root = url
        kind = ProjectDetector.kind(of: url)
        remember(url, scope: securityScopedURL ?? url)
        reloadTree()
        if let main = ProjectDetector.preferredStartFile(in: swiftFiles()) {
            select(main)
        }
    }

    private func importCopy(of url: URL, scope: URL?, into projects: URL) {
        guard importingName == nil else { return }
        let accessing = scope == nil && url.startAccessingSecurityScopedResource()
        importingName = url.deletingPathExtension().lastPathComponent
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ProjectImporter.importProject(url, into: projects) }
            }.value
            if accessing { url.stopAccessingSecurityScopedResource() }
            scope?.stopAccessingSecurityScopedResource()
            importingName = nil
            switch result {
            case .success(let copy):
                open(copy, scope: nil)
            case .failure(let error):
                errorMessage = "Could not copy \(url.lastPathComponent) into Kiln: \(error.localizedDescription)"
            }
        }
    }

    /// Opens an .xcodeproj that was picked on its own. iOS only gives access to the picked bundle,
    /// but the sources live next to it, so Kiln opens the surrounding folder when it can already
    /// read it: Kiln's own Projects folder, or a folder the user granted before (Kiln remembers
    /// those). Returns false when Kiln has to ask for the folder.
    func openXcodeProject(_ project: URL) -> Bool {
        let folder = project.deletingLastPathComponent()
        if let local = try? Self.localProjectsFolder(), Self.path(folder, isInside: local) {
            open(folder)
            return true
        }
        if let scope = grantedScope(covering: folder) {
            open(folder, scope: scope)
            return true
        }
        return false
    }

    /// The user picked `folder` to give Kiln access to `project`'s sources. Kiln remembers the
    /// folder, so other projects inside it open without asking again.
    func grantFolder(_ folder: URL, for project: URL?) {
        guard folder.startAccessingSecurityScopedResource() else {
            open(folder)
            return
        }
        if let bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            var grants = (UserDefaults.standard.array(forKey: Self.grantsKey) as? [Data]) ?? []
            grants.insert(bookmark, at: 0)
            UserDefaults.standard.set(Array(grants.prefix(20)), forKey: Self.grantsKey)
        }
        if let project, Self.path(project, isInside: folder) {
            open(project.deletingLastPathComponent(), scope: folder)
        } else {
            open(folder, scope: folder)
        }
    }

    /// A remembered folder (a grant or a recent project) that contains `folder`, with access started.
    private func grantedScope(covering folder: URL) -> URL? {
        let grants = (UserDefaults.standard.array(forKey: Self.grantsKey) as? [Data]) ?? []
        for bookmark in grants + recentProjects.map(\.scopeBookmark) {
            var isStale = false
            guard let scope = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale),
                  folder.standardizedFileURL.path == scope.standardizedFileURL.path || Self.path(folder, isInside: scope),
                  scope.startAccessingSecurityScopedResource()
            else { continue }
            if FileManager.default.isReadableFile(atPath: folder.path) {
                return scope
            }
            scope.stopAccessingSecurityScopedResource()
        }
        return nil
    }

    func openRecent(_ recent: RecentProject) {
        var isStale = false
        guard let scope = try? URL(resolvingBookmarkData: recent.scopeBookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            forgetRecent(recent)
            errorMessage = "Kiln can no longer find \(recent.name). Open it again with Open Project."
            return
        }
        let accessing = scope.startAccessingSecurityScopedResource()
        let url = recent.relativePath.isEmpty ? scope : scope.appendingPathComponent(recent.relativePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if accessing { scope.stopAccessingSecurityScopedResource() }
            forgetRecent(recent)
            errorMessage = "\(recent.name) is no longer there. Open it again with Open Project."
            return
        }
        open(url, scope: accessing ? scope : nil)
    }

    func forgetRecent(_ recent: RecentProject) {
        recentProjects.removeAll { $0.id == recent.id }
        RecentProject.save(recentProjects, key: Self.recentsKey)
    }

    /// Adds the project to the recent list (projects outside Kiln's own folder) and marks it to reopen.
    private func remember(_ url: URL, scope: URL) {
        UserDefaults.standard.set(true, forKey: Self.reopenKey)
        if let local = try? Self.localProjectsFolder(), Self.path(url, isInside: local) {
            UserDefaults.standard.set("local:" + String(url.standardizedFileURL.path.dropFirst(local.standardizedFileURL.path.count + 1)), forKey: Self.lastProjectKey)
            return
        }
        guard let bookmark = try? scope.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let scopePath = scope.standardizedFileURL.path
        let rootPath = url.standardizedFileURL.path
        let relative = rootPath.hasPrefix(scopePath + "/") ? String(rootPath.dropFirst(scopePath.count + 1)) : ""
        let recent = RecentProject(name: url.deletingPathExtension().lastPathComponent, path: rootPath, scopeBookmark: bookmark, relativePath: relative)
        recentProjects.removeAll { $0.id == recent.id }
        recentProjects.insert(recent, at: 0)
        recentProjects = Array(recentProjects.prefix(20))
        RecentProject.save(recentProjects, key: Self.recentsKey)
        UserDefaults.standard.set("recent:" + rootPath, forKey: Self.lastProjectKey)
    }

    static func path(_ url: URL, isInside folder: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// Unpacks a zipped project into Kiln's Projects folder and opens it.
    func importArchive(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard ZipArchive.isZip(url) else {
            errorMessage = "\(url.lastPathComponent) is not a folder or a zip archive, so Kiln cannot open it as a project."
            return
        }
        do {
            let folder = try ZipArchive.importProject(url, into: Self.localProjectsFolder())
            open(folder)
        } catch {
            errorMessage = "Could not unpack \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// True for folders, including packages such as .swiftpm that iOS may report as a file.
    static func isDirectory(_ url: URL) -> Bool {
        if let value = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
           value.isDirectory == true || value.isPackage == true {
            return true
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Bundles that are themselves a project and can be opened on their own.
    static func isOpenableProject(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "swiftpm"
    }

    /// Reopens the project that was open when Kiln was last closed.
    func restoreLastProject() {
        guard root == nil, UserDefaults.standard.bool(forKey: Self.reopenKey),
              let last = UserDefaults.standard.string(forKey: Self.lastProjectKey)
        else { return }
        if last.hasPrefix("local:"), let local = try? Self.localProjectsFolder() {
            let url = local.appendingPathComponent(String(last.dropFirst(6)), isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { open(url) }
        } else if last.hasPrefix("recent:"), let recent = recentProjects.first(where: { $0.path == String(last.dropFirst(7)) }) {
            openRecent(recent)
        }
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
            UserDefaults.standard.set(false, forKey: Self.reopenKey)
        }
    }

    /// Creates a project from a template in Kiln's Projects folder and opens it.
    func createProject(named rawName: String, template: ProjectTemplate) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let baseName = name.isEmpty || name.hasPrefix(".") ? "My App" : name
        do {
            let projectsFolder = try Self.localProjectsFolder()
            var folder = projectsFolder.appendingPathComponent(baseName, isDirectory: true)
            var index = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = projectsFolder.appendingPathComponent("\(baseName) \(index)", isDirectory: true)
                index += 1
            }
            for (path, contents) in template.files(projectName: baseName) {
                let url = folder.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            open(folder)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Documents/Projects, which the Files app shows under On My iPhone › Kiln.
    static func localProjectsFolder() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Projects stored inside Kiln, newest first.
    func localProjects() -> [URL] {
        guard let folder = try? Self.localProjectsFolder(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { modified($0) > modified($1) }
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
            let isDirectory = Self.isDirectory(url)
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
            let isDirectory = Self.isDirectory(url)
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
        guard !Self.isDirectory(url) else { return }
        save()
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                // A zipped .swiftpm or project inside the folder: unpack and open it.
                if ZipArchive.isZip(url), ["swiftpm", "zip", "xcodeproj"].contains(url.pathExtension.lowercased()) {
                    importArchive(url)
                    return
                }
                throw ProjectError.notText(url.lastPathComponent)
            }
            selectedFile = url
            fileOpenCount += 1
            buffer = text
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-reads the tree and the open file after something else (such as a pull) changed the files.
    func reloadFromDisk() {
        reloadTree()
        guard let selectedFile else { return }
        if let data = try? Data(contentsOf: selectedFile), let text = String(data: data, encoding: .utf8) {
            buffer = text
            isDirty = false
        } else {
            self.selectedFile = nil
            buffer = ""
            isDirty = false
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
