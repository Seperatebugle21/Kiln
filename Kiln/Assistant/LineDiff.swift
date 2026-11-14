import Foundation

struct DiffLine: Identifiable, Hashable {
    enum Kind: Hashable {
        case unchanged, added, removed, gap
    }

    let id: Int
    let kind: Kind
    let text: String
}

/// A line diff (longest common subsequence) with unchanged runs collapsed around the changes.
enum LineDiff {
    static func diff(old: String, new: String, context: Int = 3) -> [DiffLine] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var raw: [(DiffLine.Kind, String)] = []

        if a.count * b.count > 4_000_000 {
            raw = a.map { (.removed, $0) } + b.map { (.added, $0) }
        } else {
            let n = a.count, m = b.count
            var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
            func index(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[index(i, j)] = a[i] == b[j]
                            ? table[index(i + 1, j + 1)] + 1
                            : max(table[index(i + 1, j)], table[index(i, j + 1)])
                    }
                }
            }
            var i = 0, j = 0
            while i < n && j < m {
                if a[i] == b[j] {
                    raw.append((.unchanged, a[i])); i += 1; j += 1
                } else if table[index(i + 1, j)] >= table[index(i, j + 1)] {
                    raw.append((.removed, a[i])); i += 1
                } else {
                    raw.append((.added, b[j])); j += 1
                }
            }
            while i < n { raw.append((.removed, a[i])); i += 1 }
            while j < m { raw.append((.added, b[j])); j += 1 }
        }

        // Keep only unchanged lines close to a change.
        let changed = raw.indices.filter { raw[$0].0 != .unchanged }
        var keep = Set<Int>()
        for position in changed {
            for offset in -context...context where raw.indices.contains(position + offset) {
                keep.insert(position + offset)
            }
        }

        var result: [DiffLine] = []
        var skipped = false
        for (position, line) in raw.enumerated() {
            if keep.contains(position) {
                if skipped {
                    result.append(DiffLine(id: result.count, kind: .gap, text: "…"))
                    skipped = false
                }
                result.append(DiffLine(id: result.count, kind: line.0, text: line.1))
            } else {
                skipped = true
            }
        }
        return result
    }
}
