import Foundation

public struct ScreenMenu: Equatable, Sendable {
    public var text: [String]
    public var options: [String]
    public var selected: Int

    public init(text: [String], options: [String], selected: Int) {
        self.text = text
        self.options = options
        self.selected = selected
    }

    public static func find(in terminal: Terminal) -> ScreenMenu? {
        find(lines: terminal.screen.rows.map { $0.plainText() }, width: terminal.columns)
    }

    private static let cursors: Set<Character> = ["\u{276F}", "\u{203A}", ">"]
    private static let frame = CharacterSet(charactersIn: "\u{2502}\u{2503}\u{2551}\u{256D}\u{256E}\u{2570}\u{256F}\u{2500}\u{2501}\u{2550}\u{250C}\u{2510}\u{2514}\u{2518}")

    public static func find(lines raw: [String], width: Int? = nil) -> ScreenMenu? {
        let lines = raw.map(unframe)
        guard let footer = lines.lastIndex(where: isFooter) else { return nil }

        func blank(_ i: Int) -> Bool {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.unicodeScalars.allSatisfy { frame.contains($0) }
        }
        var bottom = footer - 1
        while bottom >= 0, blank(bottom) { bottom -= 1 }
        var y = bottom
        while y >= 0, !blank(y) { y -= 1 }
        let block = Array(lines[(y + 1)..<(bottom + 1)])
        let cursorLines = block.indices.filter { i in
            block[i].trimmingCharacters(in: .whitespaces).first.map(cursors.contains) == true
        }
        guard cursorLines.count == 1, let c = cursorLines.first else { return nil }
        let cursorColumn = indent(block[c])
        let optionColumn = cursorColumn + 2
        func isOption(_ i: Int) -> Bool { abs(indent(block[i]) - optionColumn) <= 1 }
        func isDescription(_ i: Int) -> Bool { indent(block[i]) > optionColumn + 1 }
        var first = c
        while first > 0, isOption(first - 1) || isDescription(first - 1) { first -= 1 }
        while first < c, !isOption(first) { first += 1 }
        var options: [String] = []
        var selected = 0
        for i in first..<block.count {
            let trimmed = block[i].trimmingCharacters(in: .whitespaces)
            if i == c {
                selected = options.count
                options.append(clean(String(trimmed.dropFirst())))
            } else if isOption(i) {
                options.append(clean(trimmed))
            } else if !isDescription(i) {
                return nil
            }
        }
        guard options.count >= 2, options.count <= 12 else { return nil }
        y += first

        var text: [String] = []
        var paragraph: [(text: String, full: Bool)] = []
        func joined(_ p: [(text: String, full: Bool)]) -> String {
            var out = ""
            for (i, line) in p.reversed().enumerated() {
                if i > 0 && !out.isEmpty { out += p.reversed()[i - 1].full ? "" : " " }
                out += line.text
            }
            return out
        }
        func fills(_ rawLine: String) -> Bool {
            guard let width, width > 0 else { return false }
            let trimmed = rawLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if let last = trimmed.unicodeScalars.last, frame.contains(last) {
                let inner = String(trimmed.dropLast())
                return inner.count >= width - 1 && !inner.hasSuffix(" ")
            }
            return trimmed.count >= width
        }
        var top = y
        while top >= 0, y - top < 20 {
            let rawLine = raw[top].trimmingCharacters(in: .whitespaces)
            if !rawLine.isEmpty, rawLine.unicodeScalars.allSatisfy({ frame.contains($0) }) { break }
            let line = lines[top].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !paragraph.isEmpty { text.append(joined(paragraph)); paragraph = [] }
            } else {
                paragraph.append((line, fills(raw[top])))
            }
            top -= 1
        }
        if !paragraph.isEmpty { text.append(joined(paragraph)) }
        return ScreenMenu(text: text.reversed(), options: options, selected: selected)
    }

    public func keys(toChoose index: Int) -> [Key] {
        let delta = index - selected
        return Array(repeating: delta < 0 ? Key.up : Key.down, count: abs(delta)) + [.enter]
    }

    private static func isFooter(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["enter to confirm", "enter to select", "enter to continue", "enter confirm", "enter select", "press enter"]
            .contains { l.contains($0) }
    }

    private static func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }

    private static func isNumbered(_ s: String) -> Bool {
        let digits = s.prefix { $0.isNumber }
        return !digits.isEmpty && s.dropFirst(digits.count).hasPrefix(". ")
    }

    private static func unframe(_ line: String) -> String {
        var s = Substring(line)
        let side: Set<Character> = ["\u{2502}", "\u{2503}", "\u{2551}"]
        if let i = s.firstIndex(where: { $0 != " " }), side.contains(s[i]) { s = s[s.index(after: i)...] }
        while s.last == " " { s.removeLast() }
        if let last = s.last, side.contains(last) { s.removeLast() }
        return String(s)
    }

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if isNumbered(t) { t = String(t.drop { $0.isNumber }.dropFirst(2)) }
        return t
    }
}
