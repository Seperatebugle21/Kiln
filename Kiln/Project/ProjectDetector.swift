import Foundation

enum ProjectDetector {
    static func kind(of folder: URL) -> ProjectKind {
        if folder.pathExtension == "swiftpm" { return .swiftPackage }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if names.contains(where: { $0.hasSuffix(".xcodeproj") }) { return .xcodeProject }
        if names.contains("Package.swift") { return .swiftPackage }
        return .folder
    }

    /// The file to show first: the one with `@main`, otherwise ContentView, otherwise any Swift file.
    static func preferredStartFile(in swiftFiles: [URL]) -> URL? {
        if let contentView = swiftFiles.first(where: { $0.lastPathComponent == "ContentView.swift" }) {
            return contentView
        }
        if let main = swiftFiles.first(where: { containsMainAttribute($0) }) {
            return main
        }
        return swiftFiles.first
    }

    static func containsMainAttribute(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("@main")
    }
}

enum SampleProject {
    static let appSource = """
    import SwiftUI

    @main
    struct HelloKilnApp: App {
        var body: some Scene {
            WindowGroup {
                ContentView()
            }
        }
    }

    """

    static let contentViewSource = """
    import SwiftUI

    struct ContentView: View {
        @State private var count = 0

        var body: some View {
            VStack(spacing: 24) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                Text("Hello from Kiln")
                    .font(.largeTitle.bold())
                Text("Tapped \\(count) times")
                    .foregroundStyle(.secondary)
                Button("Tap me") {
                    count += 1
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    """

    static func newViewSource(named name: String) -> String {
        let typeName = name.replacingOccurrences(of: " ", with: "")
        return """
        import SwiftUI

        struct \(typeName): View {
            var body: some View {
                Text("\(typeName)")
            }
        }

        """
    }
}
