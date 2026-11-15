//===----------------------------------------------------------------------===//
// Kiln's stand-in for Apple's PreviewsMacros plug-in (closed source), which the iOS SDK names
// for every #Preview:
//   #externalMacro(module: "PreviewsMacros", type: "SwiftUIView")   SwiftUI views
//   #externalMacro(module: "PreviewsMacros", type: "KitViewMacro")  UIView / UIViewController
//   #externalMacro(module: "PreviewsMacros", type: "Common")        widgets and live activities
// Kiln runs the app itself and never shows Xcode-style previews, so each #Preview expands to
// nothing. Its arguments are still type-checked, so mistakes inside a preview are reported.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros

public struct SwiftUIView: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct KitViewMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct Common: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
