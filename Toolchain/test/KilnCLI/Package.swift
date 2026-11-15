// swift-tools-version: 5.9
// kiln-build: Kiln's build system (project reader, package resolver, planner and backend) as a Mac
// command-line tool, so CI can build real projects the way Kiln does on the iPhone. The workflow
// copies Kiln/Build/*.swift next to main.swift before building.
import PackageDescription

let package = Package(
    name: "KilnCLI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "kiln-build",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
            ],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
    ]
)
