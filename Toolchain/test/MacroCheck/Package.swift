// swift-tools-version: 5.9
// Builds Kiln's FoundationModelsMacros (Toolchain/macros/FoundationModelsMacros, copied in by the
// workflow) as a Mac plug-in executable, so CI can expand @Generable with it instead of Apple's.
import PackageDescription

let package = Package(
    name: "MacroCheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "FoundationModelsMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
    ]
)
