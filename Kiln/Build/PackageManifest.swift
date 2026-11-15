import Foundation
import SwiftParser
import SwiftSyntax

/// What Kiln needs from a Package.swift, read with SwiftSyntax instead of running it
/// (iOS cannot run SwiftPM). Covers the common declarative forms:
/// `Package(name:products:dependencies:targets:)` with `.target`, `.executableTarget`,
/// `.package(url:from:)` / `exact:` / `branch:` / `revision:` / ranges / `path:`.
struct PackageManifest {
    enum TargetKind: Equatable {
        case regular, executable, test, binary, macro, plugin, system
    }

    struct Target {
        var name: String
        var kind: TargetKind
        var dependencies: [TargetDependency]
        var path: String?
        var exclude: [String]
        var sources: [String]?
        var publicHeadersPath: String?
        var headerSearchPaths: [String]
        var defines: [String]
        var swiftDefines: [String]
    }

    enum TargetDependency: Equatable {
        /// A target or product with this name (`"Foo"`, `.byName(name:)`).
        case byName(String)
        case target(String)
        case product(name: String, package: String?)
    }

    enum Requirement: Equatable {
        case from(String)
        case exact(String)
        case branch(String)
        case revision(String)
        case range(lower: String, upper: String)
        case none
    }

    struct Dependency {
        enum Location: Equatable {
            case path(String)
            case url(String)
        }

        var location: Location
        var requirement: Requirement
        var name: String?

        /// SwiftPM's package identity: the last path component, lowercased, without `.git`.
        var identity: String {
            let raw: String
            switch location {
            case .path(let path): raw = path
            case .url(let url): raw = url
            }
            var last = raw.split(separator: "/").last.map(String.init) ?? raw
            if last.hasSuffix(".git") { last.removeLast(4) }
            return last.lowercased()
        }
    }

    struct Product {
        var name: String
        var targets: [String]
    }

    var name: String
    var products: [Product]
    var dependencies: [Dependency]
    var targets: [Target]

    static func load(from packageRoot: URL) throws -> PackageManifest {
        let url = packageRoot.appendingPathComponent("Package.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        return parse(source, fallbackName: packageRoot.deletingPathExtension().lastPathComponent)
    }

    static func parse(_ source: String, fallbackName: String) -> PackageManifest {
        let tree = Parser.parse(source: source)
        let finder = PackageCallFinder()
        finder.walk(tree)
        var manifest = PackageManifest(name: fallbackName, products: [], dependencies: [], targets: [])
        guard let call = finder.call else { return manifest }

        for argument in call.arguments {
            switch argument.label?.text {
            case "name":
                manifest.name = string(argument.expression) ?? fallbackName
            case "products":
                manifest.products = elements(argument.expression).compactMap(product)
            case "dependencies":
                manifest.dependencies = elements(argument.expression).compactMap(dependency)
            case "targets":
                manifest.targets = elements(argument.expression).compactMap(target)
            default:
                break
            }
        }
        return manifest
    }

    // MARK: Pieces

    private static func product(_ expression: ExprSyntax) -> Product? {
        guard let parsed = call(expression), let name = string(parsed.arguments["name"]) else { return nil }
        let arguments = parsed.arguments
        return Product(name: name, targets: elements(arguments["targets"]).compactMap(string))
    }

    private static func dependency(_ expression: ExprSyntax) -> Dependency? {
        guard let parsed = call(expression), parsed.name == "package" else { return nil }
        let arguments = parsed.arguments
        let name = string(arguments["name"])
        if let path = string(arguments["path"]) {
            return Dependency(location: .path(path), requirement: .none, name: name)
        }
        guard let url = string(arguments["url"]) else { return nil }

        var requirement = Requirement.none
        if let version = string(arguments["from"]) {
            requirement = .from(version)
        } else if let version = string(arguments["exact"]) {
            requirement = .exact(version)
        } else if let branch = string(arguments["branch"]) {
            requirement = .branch(branch)
        } else if let revision = string(arguments["revision"]) {
            requirement = .revision(revision)
        } else if let unlabeled = arguments[""] {
            requirement = rangeRequirement(unlabeled)
        }
        return Dependency(location: .url(url), requirement: requirement, name: name)
    }

    /// `"1.0.0"..<"2.0.0"`, `.upToNextMajor(from:)`, `.upToNextMinor(from:)`, `.exact(...)`.
    private static func rangeRequirement(_ expression: ExprSyntax) -> Requirement {
        if let parsed = call(expression) {
            let arguments = parsed.arguments
            switch parsed.name {
            case "upToNextMajor", "upToNextMinor":
                if let version = string(arguments["from"]) { return .from(version) }
            case "exact":
                if let version = string(arguments[""]) { return .exact(version) }
            case "branch":
                if let branch = string(arguments[""]) { return .branch(branch) }
            case "revision":
                if let revision = string(arguments[""]) { return .revision(revision) }
            default:
                break
            }
        }
        let strings = StringCollector()
        strings.walk(expression)
        if strings.values.count == 2 {
            return .range(lower: strings.values[0], upper: strings.values[1])
        }
        return .none
    }

    private static func target(_ expression: ExprSyntax) -> Target? {
        guard let parsed = call(expression), let name = string(parsed.arguments["name"]) else { return nil }
        let arguments = parsed.arguments
        let kind: TargetKind
        switch parsed.name {
        case "target": kind = .regular
        case "executableTarget": kind = .executable
        case "testTarget": kind = .test
        case "binaryTarget": kind = .binary
        case "macro": kind = .macro
        case "plugin": kind = .plugin
        case "systemLibrary": kind = .system
        default: return nil
        }

        var headerSearchPaths: [String] = []
        var defines: [String] = []
        for setting in elements(arguments["cSettings"]) + elements(arguments["cxxSettings"]) {
            guard let parsed = call(setting), let value = string(parsed.arguments[""]) else { continue }
            if parsed.name == "headerSearchPath" { headerSearchPaths.append(value) }
            if parsed.name == "define" {
                if let assigned = string(parsed.arguments["to"]) {
                    defines.append("\(value)=\(assigned)")
                } else {
                    defines.append(value)
                }
            }
        }
        var swiftDefines: [String] = []
        for setting in elements(arguments["swiftSettings"]) {
            if let parsed = call(setting), parsed.name == "define",
               let value = string(parsed.arguments[""]) {
                swiftDefines.append(value)
            }
        }

        return Target(
            name: name,
            kind: kind,
            dependencies: elements(arguments["dependencies"]).compactMap(targetDependency),
            path: string(arguments["path"]),
            exclude: elements(arguments["exclude"]).compactMap(string),
            sources: arguments["sources"].map { elements($0).compactMap(string) },
            publicHeadersPath: string(arguments["publicHeadersPath"]),
            headerSearchPaths: headerSearchPaths,
            defines: defines,
            swiftDefines: swiftDefines
        )
    }

    private static func targetDependency(_ expression: ExprSyntax) -> TargetDependency? {
        if let name = string(expression) { return .byName(name) }
        guard let parsed = call(expression) else { return nil }
        let arguments = parsed.arguments
        switch parsed.name {
        case "target":
            return string(arguments["name"]).map { .target($0) }
        case "product":
            return string(arguments["name"]).map { .product(name: $0, package: string(arguments["package"])) }
        case "byName":
            return string(arguments["name"]).map { .byName($0) }
        default:
            return nil
        }
    }

    // MARK: Syntax helpers

    /// `.name(label: value, …)` or `Name(…)`: the function name and arguments by label ("" if none;
    /// the first unlabeled one wins).
    private struct Call {
        let name: String
        let arguments: [String: ExprSyntax]
    }

    private static func call(_ expression: ExprSyntax?) -> Call? {
        guard let call = expression?.as(FunctionCallExprSyntax.self) else { return nil }
        let name: String
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            name = member.declName.baseName.text
        } else if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            name = reference.baseName.text
        } else {
            return nil
        }
        var arguments: [String: ExprSyntax] = [:]
        for argument in call.arguments {
            let label = argument.label?.text ?? ""
            if arguments[label] == nil { arguments[label] = argument.expression }
        }
        return Call(name: name, arguments: arguments)
    }

    private static func elements(_ expression: ExprSyntax?) -> [ExprSyntax] {
        guard let array = expression?.as(ArrayExprSyntax.self) else { return [] }
        return array.elements.map(\.expression)
    }

    /// The value of a plain string literal (interpolations are dropped).
    private static func string(_ expression: ExprSyntax?) -> String? {
        guard let literal = expression?.as(StringLiteralExprSyntax.self) else { return nil }
        return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
    }
}

private final class PackageCallFinder: SyntaxVisitor {
    var call: FunctionCallExprSyntax?

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard call == nil else { return .skipChildren }
        if node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Package" {
            call = node
            return .skipChildren
        }
        return .visitChildren
    }
}

private final class StringCollector: SyntaxVisitor {
    var values: [String] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        values.append(node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined())
        return .skipChildren
    }
}
