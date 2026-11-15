//===----------------------------------------------------------------------===//
// Kiln's stand-in for Apple's FoundationModelsMacros plug-in (closed source, part of Xcode), which
// the iOS SDK names for:
//   @Generable  #externalMacro(module: "FoundationModelsMacros", type: "GenerableMacro")
//   @Guide      #externalMacro(module: "FoundationModelsMacros", type: "GuideMacro")
// The expansions follow what Xcode's plug-in produces (generationSchema, generatedContent,
// PartiallyGenerated and init(_:) for structs; string cases or discriminated payloads for enums),
// so @Generable types work with LanguageModelSession at run time.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private let module = "FoundationModels"

/// `@Guide` only carries information for `@Generable`; it adds nothing itself.
public struct GuideMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct GenerableMacro: MemberMacro, ExtensionMacro {
    // MARK: Members

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let access = accessPrefix(declaration)
        let description = describedArgument(node)
        if let structure = declaration.as(StructDeclSyntax.self) {
            let properties = storedProperties(structure.memberBlock)
            return [
                DeclSyntax(stringLiteral: schema(properties: properties, description: description, access: access)),
                DeclSyntax(stringLiteral: generatedContent(properties: properties, explicitNil: representsNilExplicitly(node), access: access)),
                DeclSyntax(stringLiteral: partiallyGenerated(properties: properties, access: access)),
            ]
        }
        if let enumeration = declaration.as(EnumDeclSyntax.self) {
            let cases = enumCases(enumeration)
            if cases.allSatisfy({ $0.values.isEmpty }) {
                let names = cases.map { "\"\($0.name)\"" }.joined(separator: ", ")
                let switchCases = cases.map { "    case .\($0.name):\n        \"\($0.name)\".generatedContent" }.joined(separator: "\n")
                return [
                    DeclSyntax(stringLiteral: """
                    \(access)nonisolated static var generationSchema: \(module).GenerationSchema {
                        \(module).GenerationSchema(type: Self.self\(description.map { ", description: \($0)" } ?? ""), anyOf: [\(names)])
                    }
                    """),
                    DeclSyntax(stringLiteral: """
                    \(access)nonisolated var generatedContent: GeneratedContent {
                        switch self {
                    \(switchCases)
                        }
                    }
                    """),
                ]
            }
            return discriminatedEnumMembers(cases: cases, description: description, access: access)
        }
        return []
    }

    // MARK: Extension

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let access = accessPrefix(declaration)
        let typeName = type.trimmedDescription
        var body = ""
        if let structure = declaration.as(StructDeclSyntax.self) {
            let assignments = storedProperties(structure.memberBlock)
                .filter { !$0.isLetWithValue }
                .map { "        self.\($0.name) = try content.value(forProperty: \"\($0.name)\")" }
                .joined(separator: "\n")
            body = """
                \(access)nonisolated init(_ content: \(module).GeneratedContent) throws {
            \(assignments)
                }
            """
        } else if let enumeration = declaration.as(EnumDeclSyntax.self) {
            let cases = enumCases(enumeration)
            if cases.allSatisfy({ $0.values.isEmpty }) {
                let switchCases = cases.map { "        case \"\($0.name)\":\n            self = .\($0.name)" }.joined(separator: "\n")
                body = """
                    \(access)nonisolated init(_ content: \(module).GeneratedContent) throws {
                        let rawValue = try content.value(String.self)
                        switch rawValue {
                \(switchCases)
                        default:
                            throw \(module).LanguageModelSession.GenerationError.decodingFailure(\(module).LanguageModelSession.GenerationError.Context(debugDescription: "Unexpected value \\"\\(rawValue)\\" for \\(Self.self)"))
                        }
                    }
                """
            } else {
                body = "    " + discriminatedInit(cases: cases, partial: false, access: access)
            }
        } else {
            return []
        }
        let declaration: DeclSyntax = """
        extension \(raw: typeName): nonisolated \(raw: module).Generable {
        \(raw: body)
        }
        """
        guard let extensionDecl = declaration.as(ExtensionDeclSyntax.self) else { return [] }
        return [extensionDecl]
    }

    // MARK: Structs

    struct Property {
        var name: String
        var type: String
        var description: String?
        var guides: [String]
        var isLetWithValue: Bool
    }

    static func storedProperties(_ members: MemberBlockSyntax) -> [Property] {
        var result: [Property] = []
        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { ["static", "class", "lazy"].contains($0.name.text) })
            else { continue }
            let guide = variable.attributes.compactMap { $0.as(AttributeSyntax.self) }
                .first { $0.attributeName.trimmedDescription == "Guide" }
            var description: String?
            var guides: [String] = []
            if case .argumentList(let arguments)? = guide?.arguments {
                for argument in arguments {
                    if argument.label?.text == "description" {
                        description = argument.expression.trimmedDescription
                    } else {
                        guides.append(argument.expression.trimmedDescription)
                    }
                }
            }
            for binding in variable.bindings {
                // Computed properties are not part of the schema.
                if let accessors = binding.accessorBlock {
                    if case .getter = accessors.accessors { continue }
                    if case .accessors(let list) = accessors.accessors,
                       list.contains(where: { ["get", "set", "_read", "_modify"].contains($0.accessorSpecifier.text) }) { continue }
                }
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let type = binding.typeAnnotation?.type.trimmedDescription
                else { continue }
                result.append(Property(
                    name: name, type: type, description: description, guides: guides,
                    isLetWithValue: variable.bindingSpecifier.text == "let" && binding.initializer != nil
                ))
            }
        }
        return result
    }

    static func schema(properties: [Property], description: String?, access: String) -> String {
        let list = properties.map { property in
            var arguments = ["name: \"\(property.name)\""]
            if let description = property.description { arguments.append("description: \(description)") }
            arguments.append("type: \(property.type).self")
            if !property.guides.isEmpty { arguments.append("guides: [\(property.guides.joined(separator: ", "))]") }
            return "            \(module).GenerationSchema.Property(\(arguments.joined(separator: ", ")))"
        }.joined(separator: ",\n")
        return """
        \(access)nonisolated static var generationSchema: \(module).GenerationSchema {
            \(module).GenerationSchema(
                type: Self.self,\(description.map { "\n        description: \($0)," } ?? "")
                properties: [
        \(list)
                ]
            )
        }
        """
    }

    static func generatedContent(properties: [Property], explicitNil: Bool, access: String) -> String {
        let adds = properties.map { "    addProperty(name: \"\($0.name)\", value: self.\($0.name))" }.joined(separator: "\n")
        return """
        \(access)nonisolated var generatedContent: GeneratedContent {
            let explicitNil = \(explicitNil)
            var properties = [(name: String, value: any ConvertibleToGeneratedContent)]()
        \(adds)
            return GeneratedContent(
                properties: properties,
                uniquingKeysWith: { _, second in
                    second
                }
            )
            func addProperty(name: String, value: some Generable) {
              properties.append((name: name, value: value))
            }
            func addProperty(name: String, value: (some Generable)?) {
              if explicitNil || value != nil {
                properties.append((name: name, value: value))
              }
            }
        }
        """
    }

    static func partiallyGenerated(properties: [Property], access: String) -> String {
        let fields = properties.map { "    \(access)var \($0.name): \(partialType($0.type))?" }.joined(separator: "\n")
        let assignments = properties.map { "        self.\($0.name) = try content.value(forProperty: \"\($0.name)\")" }.joined(separator: "\n")
        return """
        \(access)nonisolated struct PartiallyGenerated: Identifiable, nonisolated \(module).ConvertibleFromGeneratedContent {
            \(access)var id: GenerationID
        \(fields)
            \(access)nonisolated init(_ content: \(module).GeneratedContent) throws {
                self.id = content.id ?? GenerationID()
        \(assignments)
            }
        }
        """
    }

    /// `String` → `String.PartiallyGenerated`; optionals keep their `?` (`Double?.PartiallyGenerated`).
    static func partialType(_ type: String) -> String {
        "\(type).PartiallyGenerated"
    }

    // MARK: Enums

    struct EnumCase {
        var name: String
        /// (label, type) of each associated value; unlabeled values are named value, value1, …
        var values: [(label: String, type: String)]
        /// Whether each value has a label in the case declaration.
        var labeled: [Bool] = []
    }

    static func enumCases(_ enumeration: EnumDeclSyntax) -> [EnumCase] {
        var result: [EnumCase] = []
        for member in enumeration.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                var values: [(label: String, type: String)] = []
                var labeled: [Bool] = []
                for (index, parameter) in (element.parameterClause?.parameters ?? []).enumerated() {
                    let fallback = index == 0 ? "value" : "value\(index)"
                    if let label = parameter.firstName?.text, label != "_" {
                        values.append((label, parameter.type.trimmedDescription))
                        labeled.append(true)
                    } else {
                        values.append((fallback, parameter.type.trimmedDescription))
                        labeled.append(false)
                    }
                }
                result.append(EnumCase(name: element.name.text, values: values, labeled: labeled))
            }
        }
        return result
    }

    static func discriminatedEnumMembers(cases: [EnumCase], description: String?, access: String) -> [DeclSyntax] {
        let partialCases = cases.map { item -> String in
            if item.values.isEmpty { return "    case \(item.name)" }
            let values = item.values.map { "\($0.label): \(partialType($0.type))?" }.joined(separator: ", ")
            return "    case \(item.name)(\(values))"
        }.joined(separator: "\n")
        var declarations: [DeclSyntax] = [
            DeclSyntax(stringLiteral: """
            \(access)nonisolated enum PartiallyGenerated: nonisolated \(module).ConvertibleFromGeneratedContent {
            \(partialCases)
                \(discriminatedInit(cases: cases, partial: true, access: access))
            }
            """),
        ]
        let discriminators = cases.map { "            Discriminated\(capitalized($0.name)).self" }.joined(separator: ",\n")
        declarations.append(DeclSyntax(stringLiteral: """
        \(access)nonisolated static var generationSchema: \(module).GenerationSchema {
            \(module).GenerationSchema(
                type: Self.self,\(description.map { "\n        description: \($0)," } ?? "")
                anyOf: [
        \(discriminators)
                ]
            )
        }
        """))
        for item in cases {
            let typeProperty = Property(name: "type", type: "String", description: nil, guides: [".constant(\"\(item.name)\")"], isLetWithValue: false)
            let properties = [typeProperty] + item.values.map {
                Property(name: $0.label, type: $0.type, description: nil, guides: [], isLetWithValue: false)
            }
            let fields = properties.map { property in
                (property.name == "type" ? "    @Guide(.constant(\"\(item.name)\"))\n" : "") + "    let \(property.name): \(property.type)"
            }.joined(separator: "\n")
            let assignments = properties.map { "        self.\($0.name) = try content.value(forProperty: \"\($0.name)\")" }.joined(separator: "\n")
            declarations.append(DeclSyntax(stringLiteral: """
            private nonisolated struct Discriminated\(capitalized(item.name)): nonisolated \(module).Generable {
            \(fields)
                nonisolated init(_ content: \(module).GeneratedContent) throws {
            \(assignments)
                }
                \(indented(schema(properties: properties, description: nil, access: "")))
                \(indented(generatedContent(properties: properties, explicitNil: false, access: "")))
            }
            """))
        }
        let switchCases = cases.map { item -> String in
            let bindings = item.values.isEmpty ? "" : "(" + item.values.map { "let \($0.label)" }.joined(separator: ", ") + ")"
            let entries = (["\"type\": \"\(item.name)\""] + item.values.map { "\"\($0.label)\": \($0.label)" }).joined(separator: ",\n                ")
            return """
                case .\(item.name)\(bindings):
                    GeneratedContent(
                        properties: [
                            \(entries)
                        ]
                    )
            """
        }.joined(separator: "\n")
        declarations.append(DeclSyntax(stringLiteral: """
        \(access)nonisolated var generatedContent: GeneratedContent {
            switch self {
        \(switchCases)
            }
        }
        """))
        return declarations
    }

    /// `init(_ content:)` that reads the "type" discriminator, for the enum or its PartiallyGenerated.
    static func discriminatedInit(cases: [EnumCase], partial: Bool, access: String) -> String {
        let switchCases = cases.map { item -> String in
            if item.values.isEmpty {
                return "        case \"\(item.name)\":\n            self = .\(item.name)"
            }
            // PartiallyGenerated's cases are always labeled; the enum's own cases keep their labels.
            let values = item.values.enumerated().map { index, value in
                let read = "try content.value(forProperty: \"\(value.label)\")"
                let hasLabel = partial || (index < item.labeled.count && item.labeled[index])
                return hasLabel ? "\(value.label): \(read)" : read
            }.joined(separator: ", ")
            return "        case \"\(item.name)\":\n            self = .\(item.name)(\(values))"
        }.joined(separator: "\n")
        return """
        \(access)nonisolated init(_ content: \(module).GeneratedContent) throws {
                let type: String = try content.value(forProperty: "type")
                switch type {
        \(switchCases)
                default:
                    throw \(module).LanguageModelSession.GenerationError.decodingFailure(\(module).LanguageModelSession.GenerationError.Context(debugDescription: "Unexpected type \\"\\(type)\\" for \\(Self.self)"))
                }
            }
        """
    }

    // MARK: Helpers

    /// Indents every line after the first by four spaces (no Foundation in compiler plug-ins).
    static func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n    ")
    }

    /// `@Generable(representNilExplicitlyInGeneratedContent: true)`.
    static func representsNilExplicitly(_ node: AttributeSyntax) -> Bool {
        guard case .argumentList(let arguments)? = node.arguments else { return false }
        return arguments.first { $0.label?.text == "representNilExplicitlyInGeneratedContent" }?
            .expression.trimmedDescription == "true"
    }

    static func capitalized(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    /// `public ` for public types, so the generated members can satisfy public conformances.
    static func accessPrefix(_ declaration: some DeclGroupSyntax) -> String {
        for modifier in declaration.modifiers {
            switch modifier.name.text {
            case "public", "open": return "public "
            case "package": return "package "
            default: continue
            }
        }
        return ""
    }

    /// The `description:` argument of `@Generable(description: "…")`.
    static func describedArgument(_ node: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments)? = node.arguments else { return nil }
        return arguments.first { $0.label?.text == "description" }?.expression.trimmedDescription
    }
}
