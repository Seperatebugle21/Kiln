import Foundation

/// Keeps the log of every build as a text file in Documents/Build Logs (visible in the Files app),
/// written line by line, so a build that crashes Kiln still leaves its log behind.
enum BuildLogStore {
    static let keep = 30
    private static let resultPrefix = "Result: "

    struct Entry: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let project: String
        let date: Date
        let result: Result

        enum Result: String {
            case succeeded, failed, crashed, running
        }
    }

    static var folder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Build Logs", isDirectory: true)
    }

    /// Creates the log file for a new build.
    static func start(project: String) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeName = project.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent("\(formatter.string(from: Date())) \(safeName).log")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        prune()
        return url
    }

    static func append(_ text: String, to url: URL?) {
        guard let url, let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((text + "\n").utf8))
    }

    static func finish(_ url: URL?, result: Entry.Result) {
        append(resultPrefix + result.rawValue, to: url)
    }

    static func entries() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.pathExtension == "log" }.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            // "2026-11-15 15.30.12 Echo"
            let parts = name.split(separator: " ", maxSplits: 2).map(String.init)
            let project = parts.count == 3 ? parts[2] : name
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Entry(url: url, project: project, date: date, result: result(of: url))
        }
        .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    private static func result(of url: URL) -> Entry.Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .crashed }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 200 ? size - 200 : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        guard let line = tail.split(separator: "\n").last, line.hasPrefix(resultPrefix) else { return .running }
        return Entry.Result(rawValue: String(line.dropFirst(resultPrefix.count))) ?? .failed
    }

    private static func prune() {
        let all = entries()
        for entry in all.dropFirst(keep) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}
