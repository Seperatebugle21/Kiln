import SwiftDiagnostics
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// Parses Swift with SwiftSyntax and reports syntax errors instantly, before any compiler runs.
enum SyntaxChecker {
    static func check(_ file: SourceFile) -> [BuildDiagnostic] {
        let tree = Parser.parse(source: file.text)
        let converter = SourceLocationConverter(fileName: file.path, tree: tree)
        return ParseDiagnosticsGenerator.diagnostics(for: tree).map { diagnostic in
            let location = diagnostic.location(converter: converter)
            let severity: BuildDiagnostic.Severity
            switch diagnostic.diagMessage.severity {
            case .error: severity = .error
            case .warning: severity = .warning
            default: severity = .note
            }
            return BuildDiagnostic(
                severity: severity,
                file: file.path,
                line: location.line,
                column: location.column,
                message: diagnostic.message
            )
        }
    }
}
