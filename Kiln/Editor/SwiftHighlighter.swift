import UIKit

/// Fast, regex-based Swift syntax colouring for the editor.
struct SwiftHighlighter {
    static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    private static let keywords = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
        "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "inout",
        "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator",
        "override", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self",
        "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
        "typealias", "var", "weak", "where", "while",
    ]

    private struct Rule {
        let regex: NSRegularExpression
        let color: UIColor
    }

    // Later rules win, so strings and comments come last.
    private static let rules: [Rule] = {
        func rule(_ pattern: String, _ color: UIColor, _ options: NSRegularExpression.Options = []) -> Rule {
            // The patterns are constants, so a failure here is a programming error.
            Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), color: color)
        }
        return [
            rule("\\b[A-Z][A-Za-z0-9_]*\\b", .systemTeal),
            rule("\\.[a-z][A-Za-z0-9_]*\\b", .systemIndigo),
            rule("\\b(" + keywords.joined(separator: "|") + ")\\b", .systemPink),
            rule("@[A-Za-z_][A-Za-z0-9_]*", .systemOrange),
            rule("#[A-Za-z_][A-Za-z0-9_]*", .systemOrange),
            rule("\\b[0-9][0-9_]*(\\.[0-9_]+)?\\b", .systemPurple),
            rule("\"\"\"[\\s\\S]*?\"\"\"", .systemRed),
            rule("\"(\\\\.|[^\"\\\\\\n])*\"", .systemRed),
            rule("//[^\\n]*", .systemGreen),
            rule("/\\*[\\s\\S]*?\\*/", .systemGreen),
        ]
    }()

    func highlight(_ storage: NSTextStorage) {
        let string = storage.string
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: Self.font, .foregroundColor: UIColor.label], range: fullRange)
        for rule in Self.rules {
            rule.regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
                if let range = match?.range {
                    storage.addAttribute(.foregroundColor, value: rule.color, range: range)
                }
            }
        }
        storage.endEditing()
    }
}
