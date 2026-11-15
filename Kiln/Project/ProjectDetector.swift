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

    /// A local Swift package with a C target and a Swift wrapper, like CLame in Echo.
    static let packageFiles: [String: String] = [
        "Packages/Greeting/Package.swift": """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Greeting",
            products: [
                .library(name: "Greeting", targets: ["Greeting"]),
            ],
            targets: [
                .target(name: "CGreeting"),
                .target(name: "Greeting", dependencies: ["CGreeting"]),
            ]
        )

        """,
        "Packages/Greeting/Sources/CGreeting/include/CGreeting.h": """
        #ifndef CGREETING_H
        #define CGREETING_H

        /// Written in C and compiled on the iPhone by Kiln.
        const char *greeting_text(void);
        int greeting_answer(void);

        #endif

        """,
        "Packages/Greeting/Sources/CGreeting/greeting.c": """
        #include "CGreeting.h"

        const char *greeting_text(void) {
            return "Hello from C";
        }

        int greeting_answer(void) {
            return 6 * 7;
        }

        """,
        "Packages/Greeting/Sources/Greeting/Greeting.swift": """
        import CGreeting

        public enum Greeting {
            /// Calls into the C target.
            public static var text: String {
                "\\(String(cString: greeting_text())) (\\(greeting_answer()))"
            }
        }

        """,
    ]

    static let contentViewSource = """
    import Greeting
    import Observation
    import SwiftUI

    @Observable
    final class Counter {
        var count = 0
    }

    struct ContentView: View {
        @State private var counter = Counter()

        var body: some View {
            VStack(spacing: 24) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                Text("Hello from Kiln")
                    .font(.largeTitle.bold())
                Text(Greeting.text)
                    .font(.headline)
                Text("Tapped \\(counter.count) times")
                    .foregroundStyle(.secondary)
                Button("Tap me") {
                    counter.count += 1
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    #Preview {
        ContentView()
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
