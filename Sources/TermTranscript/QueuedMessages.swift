import Foundation

public enum QueuedMessages {
    public static func parse(_ lines: [String]) -> [String] {
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\u{23BF}"), t.lowercased().contains("queued") else { continue }
            var parts: [String] = []
            var j = i - 1
            while j >= 0 {
                let row = lines[j].trimmingCharacters(in: .whitespaces)
                if row.isEmpty || row.hasPrefix("\u{23BF}") { break }
                parts.insert(row, at: 0)
                if row.hasPrefix("> ") || row.hasPrefix("\u{276F} ") || row == ">" || row == "\u{276F}" { break }
                j -= 1
            }
            guard var first = parts.first else { continue }
            for prefix in ["> ", "\u{276F} "] where first.hasPrefix(prefix) {
                first = String(first.dropFirst(prefix.count))
            }
            parts[0] = first
            let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(text) }
        }
        return out
    }
}
