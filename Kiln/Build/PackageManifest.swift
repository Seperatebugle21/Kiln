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
        /// Other compiler flags: upcoming and experimental features, C++ interop, safe unsafeFlags.
        var swiftFlags: [String] = []
        /// Extra flags for C, C++ and Objective-C files (from unsafeFlags).
        var cFlags: [String] = []
        /// `-framework X` / `-lX` from linkerSettings.
        var linkFlags: [String] = []
        var resources: [Resource] = []
        /// Binary targets: a local `path:` or a downloadable `url:` (with `checksum:`).
        var binaryPath: String?
        var binaryURL: String?
        var checksum: String?
    }

    struct Resource: Equatable {
        enum Rule: Equatable { case process, copy }
        var rule: Rule
        var path: String
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
        /// `lower..<upper`; with `inclusive`, `lower...upper` (both ends allowed).
        case range(lower: String, upper: String, inclusive: Bool = false)
        /// `.upToNextMinor(from:)`: the same major and minor version.
        case upToNextMinor(String)
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
    /// `cxxLanguageStandard: .gnucxx20` → "gnu++20".
    var cxxStandard: String? = nil
    var cStandard: String? = nil
    /// Feature flags found anywhere in the manifest (also in helper code), for targets Kiln infers
    /// from the folder layout because the manifest builds them with code.
    var codeSwiftFlags: [String] = []

    static func load(from packageRoot: URL) throws -> PackageManifest {
        let url = packageRoot.appendingPathComponent("Package.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        return parse(source, fallbackName: packageRoot.deletingPathExtension().lastPathComponent)
    }

    static func parse(_ source: String, fallbackName: String) -> PackageManifest {
        ManifestReader(source: source).read(fallbackName: fallbackName)
    }
}

/// Reads the manifest's syntax tree. Besides the literal `Package(...)` call it follows
/// top-level constants (`let targets: [Target] = [...]`), `+` between arrays, and
/// `package.targets.append(...)` / `package.dependencies += [...]` after the declaration.
private final class ManifestReader {
    typealias Target = PackageManifest.Target
    typealias Dependency = PackageManifest.Dependency
    typealias Requirement = PackageManifest.Requirement
    typealias TargetDependency = PackageManifest.TargetDependency

    private let tree: SourceFileSyntax
    private var constants: [String: ExprSyntax] = [:]

    init(source: String) {
        tree = Parser.parse(source: source)
        for statement in tree.statements {
            guard let variable = statement.item.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                   let value = binding.initializer?.value {
                    constants[name] = value
                }
            }
        }
    }

    func read(fallbackName: String) -> PackageManifest {
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
            case "cxxLanguageStandard":
                manifest.cxxStandard = languageStandard(argument.expression)
            case "cLanguageStandard":
                manifest.cStandard = languageStandard(argument.expression)
            default:
                break
            }
        }

        manifest.codeSwiftFlags = settingsInCode()

        // `package.targets.append(...)`, `package.targets += [...]` and the like.
        for statement in tree.statements {
            if let call = statement.item.as(FunctionCallExprSyntax.self),
               let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               ["append", "append(contentsOf:)"].contains(member.declName.baseName.text),
               let list = member.base?.as(MemberAccessExprSyntax.self)?.declName.baseName.text {
                let items = call.arguments.flatMap { argument in
                    argument.label?.text == "contentsOf" ? elements(argument.expression) : [argument.expression]
                }
                add(items, to: list, in: &manifest)
            } else if let sequence = statement.item.as(SequenceExprSyntax.self) {
                let parts = Array(sequence.elements)
                if parts.count == 3,
                   parts[1].as(BinaryOperatorExprSyntax.self)?.operator.text == "+=",
                   let list = parts[0].as(MemberAccessExprSyntax.self)?.declName.baseName.text {
                    add(elements(parts[2]), to: list, in: &manifest)
                }
            }
        }
        return manifest
    }

    /// Every `.enableExperimentalFeature("…")` / `.enableUpcomingFeature("…")` in the file, and
    /// availability macros from a `let availabilityMacros = ["Name": "macOS …, iOS …"]` table.
    private func settingsInCode() -> [String] {
        let collector = CallCollector()
        collector.walk(tree)
        var flags: [String] = []
        for node in collector.calls {
            guard let parsed = call(ExprSyntax(node)), let value = string(parsed.arguments[""]) else { continue }
            switch parsed.name {
            case "enableExperimentalFeature": flags += ["-enable-experimental-feature", value]
            case "enableUpcomingFeature": flags += ["-enable-upcoming-feature", value]
            default: break
            }
        }
        for (name, value) in constants.sorted(by: { $0.key < $1.key }) where name.lowercased().contains("availability") {
            guard let dictionary = value.as(DictionaryExprSyntax.self),
                  let elements = dictionary.content.as(DictionaryElementListSyntax.self) else { continue }
            for element in elements {
                if let key = string(element.key), let macro = string(element.value) {
                    flags += ["-enable-experimental-feature", "AvailabilityMacro=\(key): \(macro)"]
                }
            }
        }
        // Keep the first occurrence of each flag pair.
        var seen = Set<String>()
        var unique: [String] = []
        var index = 0
        while index + 1 < flags.count {
            if seen.insert(flags[index] + " " + flags[index + 1]).inserted { unique += [flags[index], flags[index + 1]] }
            index += 2
        }
        return unique
    }

    private func add(_ items: [ExprSyntax], to list: String, in manifest: inout PackageManifest) {
        switch list {
        case "targets": manifest.targets += items.compactMap(target)
        case "products": manifest.products += items.compactMap(product)
        case "dependencies": manifest.dependencies += items.compactMap(dependency)
        default: break
        }
    }

    // MARK: Pieces

    private func product(_ expression: ExprSyntax) -> PackageManifest.Product? {
        guard let parsed = call(expression), let name = string(parsed.arguments["name"]) else { return nil }
        return PackageManifest.Product(name: name, targets: elements(parsed.arguments["targets"]).compactMap(string))
    }

    private func dependency(_ expression: ExprSyntax) -> Dependency? {
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

    /// `"1.0.0"..<"2.0.0"`, `"1.0.0"..."1.2.0"`, `.upToNextMajor(from:)`, `.upToNextMinor(from:)`, `.exact(...)`.
    private func rangeRequirement(_ expression: ExprSyntax) -> Requirement {
        if let parsed = call(expression) {
            let arguments = parsed.arguments
            switch parsed.name {
            case "upToNextMajor":
                if let version = string(arguments["from"]) { return .from(version) }
            case "upToNextMinor":
                if let version = string(arguments["from"]) { return .upToNextMinor(version) }
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
            // `"6.0.1" ... "6.0.1"` (closed, as mlx-swift-examples pins GzipSwift) or `"1.0.0"..<"2.0.0"`.
            let inclusive = !expression.description.contains("..<")
            return .range(lower: strings.values[0], upper: strings.values[1], inclusive: inclusive)
        }
        return .none
    }

    private func target(_ expression: ExprSyntax) -> Target? {
        guard let parsed = call(expression), let name = string(parsed.arguments["name"]) else { return nil }
        let arguments = parsed.arguments
        let kind: PackageManifest.TargetKind
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
        var cFlags: [String] = []
        for setting in elements(arguments["cSettings"]) + elements(arguments["cxxSettings"]) {
            guard let parsed = call(setting), appliesToIOS(parsed) else { continue }
            switch parsed.name {
            case "headerSearchPath":
                if let value = string(parsed.arguments[""]) { headerSearchPaths.append(value) }
            case "define":
                if let value = string(parsed.arguments[""]) {
                    defines.append(string(parsed.arguments["to"]).map { "\(value)=\($0)" } ?? value)
                }
            case "unsafeFlags":
                cFlags += elements(parsed.arguments[""]).compactMap(string).filter(PackageManifestFlags.isSafeClangFlag)
            default:
                break
            }
        }

        var swiftDefines: [String] = []
        var swiftFlags: [String] = []
        for setting in elements(arguments["swiftSettings"]) {
            guard let parsed = call(setting), appliesToIOS(parsed) else { continue }
            let value = string(parsed.arguments[""])
            switch parsed.name {
            case "define":
                if let value { swiftDefines.append(value) }
            case "enableUpcomingFeature":
                if let value { swiftFlags += ["-enable-upcoming-feature", value] }
            case "enableExperimentalFeature":
                if let value { swiftFlags += ["-enable-experimental-feature", value] }
            case "interoperabilityMode":
                if parsed.arguments[""]?.description.contains("Cxx") == true {
                    swiftFlags.append("-cxx-interoperability-mode=default")
                }
            case "swiftLanguageMode", "swiftLanguageVersion":
                // .v5, .v6, .version("6")
                let mode = (parsed.arguments[""]?.trimmedDescription ?? "").filter { $0.isNumber || $0 == "." }
                if !mode.isEmpty { swiftFlags += ["-swift-version", mode] }
            case "unsafeFlags":
                swiftFlags += PackageManifestFlags.safeSwiftFlags(elements(parsed.arguments[""]).compactMap(string))
            default:
                break
            }
        }

        var linkFlags: [String] = []
        for setting in elements(arguments["linkerSettings"]) {
            guard let parsed = call(setting), appliesToIOS(parsed), let value = string(parsed.arguments[""]) else { continue }
            switch parsed.name {
            case "linkedFramework": linkFlags += ["-framework", value]
            case "linkedLibrary": linkFlags.append("-l\(value)")
            default: break
            }
        }

        var resources: [PackageManifest.Resource] = []
        for resource in elements(arguments["resources"]) {
            guard let parsed = call(resource), let path = string(parsed.arguments[""]) else { continue }
            resources.append(.init(rule: parsed.name == "copy" ? .copy : .process, path: path))
        }

        var target = Target(
            name: name,
            kind: kind,
            dependencies: elements(arguments["dependencies"]).compactMap(targetDependency),
            path: kind == .binary ? nil : string(arguments["path"]),
            exclude: elements(arguments["exclude"]).compactMap(string),
            sources: arguments["sources"].map { elements($0).compactMap(string) },
            publicHeadersPath: string(arguments["publicHeadersPath"]),
            headerSearchPaths: headerSearchPaths,
            defines: defines,
            swiftDefines: swiftDefines
        )
        target.swiftFlags = swiftFlags
        target.cFlags = cFlags
        target.linkFlags = linkFlags
        target.resources = resources
        if kind == .binary {
            target.binaryPath = string(arguments["path"])
            target.binaryURL = string(arguments["url"])
            target.checksum = string(arguments["checksum"])
        }
        return target
    }

    private func targetDependency(_ expression: ExprSyntax) -> TargetDependency? {
        if let name = string(expression) { return .byName(name) }
        guard let parsed = call(expression), appliesToIOS(parsed) else { return nil }
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

    /// False for settings and dependencies limited to other platforms or to release builds
    /// (`.when(platforms: [.macOS])`, `.when(configuration: .release)`); Kiln makes iOS debug builds.
    private func appliesToIOS(_ call: Call) -> Bool {
        let condition = call.arguments["condition"] ?? call.allArguments.dropFirst().first(where: { $0.label == nil })?.expression
        guard let condition, let when = self.call(condition), when.name == "when" else { return true }
        if let platforms = when.arguments["platforms"] {
            let names = elements(platforms).map { $0.trimmedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            if !names.contains("iOS") && !names.contains("macCatalyst") { return false }
        }
        if let configuration = when.arguments["configuration"], configuration.trimmedDescription.contains("release") {
            return false
        }
        return true
    }

    private func languageStandard(_ expression: ExprSyntax) -> String? {
        // .gnucxx20 → gnu++20, .cxx17 → c++17, .c11 → c11, .gnu99 → gnu99
        let name = expression.trimmedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let standard = name.replacingOccurrences(of: "cxx", with: "++")
        return standard.hasPrefix("++") ? "c" + standard : standard
    }

    // MARK: Syntax helpers

    /// `.name(label: value, …)` or `Name(…)`: the function name and arguments by label ("" if none;
    /// the first unlabeled one wins).
    struct Call {
        let name: String
        let arguments: [String: ExprSyntax]
        let allArguments: [(label: String?, expression: ExprSyntax)]
    }

    private func call(_ expression: ExprSyntax?) -> Call? {
        guard let expression = resolved(expression), let call = expression.as(FunctionCallExprSyntax.self) else { return nil }
        let name: String
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            name = member.declName.baseName.text
        } else if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            name = reference.baseName.text
        } else {
            return nil
        }
        var arguments: [String: ExprSyntax] = [:]
        var all: [(label: String?, expression: ExprSyntax)] = []
        for argument in call.arguments {
            let label = argument.label?.text ?? ""
            if arguments[label] == nil { arguments[label] = argument.expression }
            all.append((argument.label?.text, argument.expression))
        }
        return Call(name: name, arguments: arguments, allArguments: all)
    }

    /// Follows a reference to a top-level constant.
    private func resolved(_ expression: ExprSyntax?, depth: Int = 0) -> ExprSyntax? {
        guard let expression else { return nil }
        if depth < 8, let reference = expression.as(DeclReferenceExprSyntax.self),
           let value = constants[reference.baseName.text] {
            return resolved(value, depth: depth + 1)
        }
        return expression
    }

    /// Array elements, following constants and `a + b`.
    private func elements(_ expression: ExprSyntax?, depth: Int = 0) -> [ExprSyntax] {
        guard depth < 8, let expression = resolved(expression) else { return [] }
        if let array = expression.as(ArrayExprSyntax.self) {
            return array.elements.map(\.expression)
        }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            return sequence.elements.filter { !$0.is(BinaryOperatorExprSyntax.self) }
                .flatMap { elements($0, depth: depth + 1) }
        }
        return []
    }

    /// The value of a plain string literal (interpolations are dropped), or of a string constant.
    /// Escapes such as `\"` are decoded, as the compiler would (raw `#"…"#` strings are left as they are).
    private func string(_ expression: ExprSyntax?) -> String? {
        guard let literal = resolved(expression)?.as(StringLiteralExprSyntax.self) else { return nil }
        let text = literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
        return literal.openingPounds == nil ? Self.unescape(text) : text
    }

    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "u":
                // \u{1F600}
                var hex = ""
                while let digit = iterator.next(), digit != "}" { if digit != "{" { hex.append(digit) } }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { result.unicodeScalars.append(scalar) }
            default: result.append(next) // \" \' \\
            }
        }
        return result
    }
}

/// Which compiler flags from a project or package Kiln passes on.
enum PackageManifestFlags {
    /// unsafeFlags Kiln can pass on: defines, include paths, warnings and language options.
    /// Others (optimisation levels, linker or architecture flags) are left out.
    static func isSafeClangFlag(_ flag: String) -> Bool {
        ["-D", "-U", "-I", "-W", "-f", "-std="].contains { flag.hasPrefix($0) }
            && !flag.hasPrefix("-fprofile") && !flag.hasPrefix("-fsanitize") && !flag.hasPrefix("-Wl,")
    }

    static func safeSwiftFlags(_ flags: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            if ["-enable-upcoming-feature", "-enable-experimental-feature", "-Xcc", "-swift-version"].contains(flag),
               index + 1 < flags.count {
                result += [flag, flags[index + 1]]
                index += 2
                continue
            }
            if flag.hasPrefix("-D") || flag.hasPrefix("-enable-") || flag.hasPrefix("-disable-") || flag.hasPrefix("-warn") {
                result.append(flag)
            }
            index += 1
        }
        return result
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

private final class CallCollector: SyntaxVisitor {
    var calls: [FunctionCallExprSyntax] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        calls.append(node)
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
