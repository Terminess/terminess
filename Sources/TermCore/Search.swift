import Foundation

public struct SearchMatch: Equatable, Sendable {
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int

    public func contains(line: Int, column: Int) -> Bool {
        if line < startLine || line > endLine { return false }
        if line == startLine && column < startColumn { return false }
        if line == endLine && column > endColumn { return false }
        return true
    }
}

extension Terminal {
    public var firstAbsoluteLine: Int { screen.scrolledOff - screen.scrollback.count }

    public func search(_ query: String, regex: Bool = false, caseSensitive: Bool = false,
                       limit: Int = 5_000) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else {
            return []
        }
        let rows = screen.scrollback.rows + screen.rows
        let base = firstAbsoluteLine
        var out: [SearchMatch] = []
        var i = 0
        while i < rows.count && out.count < limit {
            var text = ""
            var map: [(line: Int, col: Int)] = []
            var j = i
            while j < rows.count {
                let row = rows[j]
                for x in 0..<row.count where !row.cells[x].isWideTail {
                    let piece = row.cells[x].isEmpty ? " " : row.text(at: x)
                    text += piece
                    for _ in 0..<piece.utf16.count { map.append((base + j, x)) }
                }
                if !row.wrapped { break }
                j += 1
            }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                let a = map[m.range.location]
                let b = map[m.range.location + m.range.length - 1]
                out.append(SearchMatch(startLine: a.line, startColumn: a.col, endLine: b.line, endColumn: b.col))
                if out.count >= limit { break }
            }
            i = j + 1
        }
        return out
    }
}

extension Terminal {
    public func promptLines() -> [Int] {
        let rows = screen.scrollback.rows + screen.rows
        let base = firstAbsoluteLine
        return rows.indices.filter { rows[$0].mark.contains(.prompt) }.map { base + $0 }
    }

    public func lastCommandOutput() -> String? {
        let rows = screen.scrollback.rows + screen.rows
        guard let start = rows.indices.last(where: { rows[$0].mark.contains(.output) }),
              let end = rows.indices.first(where: { $0 >= start && rows[$0].mark.contains(.prompt) }) else { return nil }
        guard end > start else { return "" }
        var lines: [String] = []
        var current = ""
        for row in rows[start..<end] {
            current += row.plainText(trimTrailing: !row.wrapped)
            if !row.wrapped { lines.append(current); current = "" }
        }
        if !current.isEmpty { lines.append(current) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
