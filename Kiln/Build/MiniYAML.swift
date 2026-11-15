import Foundation

/// A small YAML reader for project files such as XcodeGen's project.yml: block mappings and
/// sequences, `- key: value` items, quoted and plain scalars, `[a, b]` flow lists, `|`/`>` block
/// scalars and comments. Anchors, tags and multi-document files are not supported.
indirect enum YAMLValue {
    case scalar(String)
    case list([YAMLValue])
    case map([(key: String, value: YAMLValue)])

    var string: String? {
        if case .scalar(let value) = self { return value }
        return nil
    }

    var items: [YAMLValue] {
        switch self {
        case .list(let values): return values
        case .scalar(let value) where !value.isEmpty: return [.scalar(value)]
        case .map: return [self]
        default: return []
        }
    }

    var entries: [(key: String, value: YAMLValue)] {
        if case .map(let entries) = self { return entries }
        return []
    }

    subscript(key: String) -> YAMLValue? {
        entries.first { $0.key == key }?.value
    }

    static func parse(_ text: String) -> YAMLValue {
        var parser = Parser(text: text)
        return parser.parseDocument()
    }

    private struct Line {
        var indent: Int
        var text: String
        var raw: String
    }

    private struct Parser {
        var lines: [Line] = []
        var index = 0

        init(text: String) {
            for raw in text.components(separatedBy: .newlines) {
                let withoutTabs = raw.replacingOccurrences(of: "\t", with: "  ")
                let stripped = Self.stripComment(withoutTabs)
                let trimmed = stripped.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "---" { continue }
                let indent = stripped.prefix { $0 == " " }.count
                lines.append(Line(indent: indent, text: trimmed, raw: withoutTabs))
            }
        }

        mutating func parseDocument() -> YAMLValue {
            guard !lines.isEmpty else { return .map([]) }
            return parseBlock(indent: lines[0].indent)
        }

        private mutating func parseBlock(indent: Int) -> YAMLValue {
            guard index < lines.count else { return .scalar("") }
            if Self.isSequenceItem(lines[index].text) {
                return parseSequence(indent: indent)
            }
            return parseMapping(indent: indent)
        }

        private mutating func parseSequence(indent: Int) -> YAMLValue {
            var items: [YAMLValue] = []
            while index < lines.count, lines[index].indent == indent, Self.isSequenceItem(lines[index].text) {
                let line = lines[index]
                let rest = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    index += 1
                    if index < lines.count, lines[index].indent > indent {
                        items.append(parseBlock(indent: lines[index].indent))
                    } else {
                        items.append(.scalar(""))
                    }
                } else if Self.keyValue(rest) != nil && !rest.hasPrefix("[") && !rest.hasPrefix("{") {
                    // `- key: value` starts a mapping whose other keys line up with `key`.
                    let offset = line.text.count - rest.count
                    lines[index] = Line(indent: indent + offset, text: rest, raw: line.raw)
                    items.append(parseMapping(indent: indent + offset))
                } else {
                    index += 1
                    items.append(Self.scalar(rest))
                }
            }
            return .list(items)
        }

        private mutating func parseMapping(indent: Int) -> YAMLValue {
            var entries: [(key: String, value: YAMLValue)] = []
            while index < lines.count, lines[index].indent == indent, !Self.isSequenceItem(lines[index].text) {
                guard let (key, value) = Self.keyValue(lines[index].text) else {
                    index += 1
                    continue
                }
                index += 1
                if value.isEmpty {
                    if index < lines.count, lines[index].indent > indent {
                        entries.append((key, parseBlock(indent: lines[index].indent)))
                    } else if index < lines.count, lines[index].indent == indent, Self.isSequenceItem(lines[index].text) {
                        entries.append((key, parseSequence(indent: indent)))
                    } else {
                        entries.append((key, .scalar("")))
                    }
                } else if value.hasPrefix("|") || value.hasPrefix(">") {
                    var block: [String] = []
                    while index < lines.count, lines[index].indent > indent {
                        block.append(lines[index].raw.trimmingCharacters(in: .whitespaces))
                        index += 1
                    }
                    entries.append((key, .scalar(block.joined(separator: value.hasPrefix(">") ? " " : "\n"))))
                } else {
                    entries.append((key, Self.scalar(value)))
                }
            }
            return .map(entries)
        }

        private static func isSequenceItem(_ text: String) -> Bool {
            text == "-" || text.hasPrefix("- ")
        }

        /// `key: value` → (key, value); nil when the text is not a mapping entry.
        private static func keyValue(_ text: String) -> (String, String)? {
            var inQuote: Character?
            var previous: Character = " "
            for (offset, character) in text.enumerated() {
                if let quote = inQuote {
                    if character == quote { inQuote = nil }
                } else if character == "\"" || character == "'" {
                    if offset == 0 || previous == " " { inQuote = character }
                } else if character == ":" {
                    let next = text.index(text.startIndex, offsetBy: offset + 1)
                    if next == text.endIndex || text[next] == " " {
                        let key = String(text.prefix(offset)).trimmingCharacters(in: .whitespaces)
                        let value = String(text[next...]).trimmingCharacters(in: .whitespaces)
                        return (unquote(key), value)
                    }
                }
                previous = character
            }
            return nil
        }

        private static func scalar(_ text: String) -> YAMLValue {
            if text.hasPrefix("["), text.hasSuffix("]") {
                let inner = text.dropFirst().dropLast()
                return .list(inner.split(separator: ",").map { .scalar(unquote(String($0).trimmingCharacters(in: .whitespaces))) }
                    .filter { $0.string?.isEmpty == false })
            }
            if text.hasPrefix("{"), text.hasSuffix("}") {
                let inner = text.dropFirst().dropLast()
                var entries: [(key: String, value: YAMLValue)] = []
                for part in inner.split(separator: ",") {
                    if let (key, value) = keyValue(String(part).trimmingCharacters(in: .whitespaces)) {
                        entries.append((key, .scalar(unquote(value))))
                    }
                }
                return .map(entries)
            }
            return .scalar(unquote(text))
        }

        private static func unquote(_ text: String) -> String {
            if text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" {
                return String(text.dropFirst().dropLast())
            }
            return text
        }

        /// Removes a `# comment` that is not inside quotes.
        private static func stripComment(_ line: String) -> String {
            var inQuote: Character?
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if let quote = inQuote {
                    if character == quote { inQuote = nil }
                } else if character == "\"" || character == "'" {
                    if offset == 0 || previous == " " || previous == ":" { inQuote = character }
                } else if character == "#", previous == " " || offset == 0 {
                    return String(line.prefix(offset))
                }
                previous = character
            }
            return line
        }
    }
}
