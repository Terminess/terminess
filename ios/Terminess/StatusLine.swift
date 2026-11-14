import Foundation
import TermCore

struct StatusChip: Identifiable, Hashable {
    let id: Int
    let text: String
    let symbol: String?
    let percent: Double?
}

enum StatusLine {
    private static let bars = Set("█▉▊▋▌▍▎▏▓▒░■□▰▱▮▯⣿⣀━─[]".unicodeScalars.map { $0.value })
    private static let models = ["opus", "sonnet", "haiku", "fable", "claude", "gpt", "o3", "o4", "codex"]

    static func chips(_ t: Terminal) -> [StatusChip] {
        let rows = t.screen.rows
        guard rows.count == t.rows, t.rows > 4 else { return [] }
        let lowest = max(0, t.rows - 30)
        func isRule(_ r: Row) -> Bool {
            var n = 0
            for c in r.cells where c.scalar == 0x2500 || c.scalar == 0x2501 { n += 1 }
            return n >= max(10, r.count * 6 / 10)
        }
        var bottom: Int?
        var y = t.rows - 1
        while y > lowest, bottom == nil {
            if isRule(rows[y]) {
                var top = y - 1
                while top >= max(lowest, y - 14), !isRule(rows[top]) { top -= 1 }
                if top >= lowest, top < y - 1, isRule(rows[top]) {
                    let prompt = rows[top + 1].plainText().trimmingCharacters(in: .whitespaces)
                    if prompt.hasPrefix("\u{276F}") || prompt.hasPrefix(">") { bottom = y }
                }
            }
            y -= 1
        }
        guard let b = bottom, b + 1 < t.rows else { return [] }
        var out: [StatusChip] = []
        for row in rows[(b + 1)...] {
            let text = row.plainText()
            for raw in text.components(separatedBy: CharacterSet(charactersIn: "|│·•")) {
                if let chip = chip(raw, id: out.count) { out.append(chip) }
            }
        }
        return out
    }

    private static func chip(_ raw: String, id: Int) -> StatusChip? {
        var text = raw
        var percent: Double?
        if let r = text.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) {
            percent = Double(text[r].dropLast()).map { min(max($0 / 100, 0), 1) }
        }
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !bars.contains($0.value) }))
        var symbol: String?
        let arrows: Set<Character> = ["⏵", "▶", "►", "▸", "»", "⏩"]
        if let first = text.trimmingCharacters(in: .whitespaces).first, arrows.contains(first) {
            text = String(text.trimmingCharacters(in: .whitespaces).drop { arrows.contains($0) || $0 == " " })
            symbol = "forward.fill"
        }
        if let open = text.lastIndex(of: "("), text.trimmingCharacters(in: .whitespaces).hasSuffix(")"), open != text.startIndex {
            text = String(text[..<open])
        }
        text = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if symbol == nil {
            if text.hasPrefix("~") || text.hasPrefix("/") { symbol = "folder" }
            else if models.contains(where: { lower.hasPrefix($0) }) { symbol = "sparkle" }
            else if percent != nil && (lower.hasPrefix("5h") || lower.hasPrefix("7d") || lower.contains("week")) { symbol = "clock" }
            else if percent != nil { symbol = "gauge.with.dots.needle.33percent" }
        }
        return StatusChip(id: id, text: text, symbol: symbol, percent: percent)
    }
}
