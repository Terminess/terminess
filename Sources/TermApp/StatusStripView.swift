import AppKit
import TermCore

final class StatusStripView: NSView {
    var rows: [Row] = [] { didSet { rebuild() } }
    var palette = Palette() { didSet { rebuild() } }
    var native = true { didSet { if native != oldValue { rebuild() } } }

    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private let chipFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private let hintFont = NSFont.systemFont(ofSize: 11.5)
    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 3 }

    struct Chip {
        var text: String
        var hint: String
        var color: NSColor?
        var symbol: String?
        var percent: Double?
        var rowStart: Bool
    }
    private var chips: [Chip] = []
    private let chipHeight: CGFloat = 20
    private let gap: CGFloat = 6
    private let inset: CGFloat = 18

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard !rows.isEmpty else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        if native {
            let w = bounds.width > 0 ? bounds.width : 800
            return NSSize(width: NSView.noIntrinsicMetric, height: layoutChips(width: w).height + 10)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows.count) * lineHeight + 8)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed && native { invalidateIntrinsicContentSize(); superview?.needsLayout = true }
    }

    private func rebuild() {
        chips = native ? Self.parseChips(rows, palette: palette) : []
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsDisplay = true
    }

    private func color(_ c: RGB, alpha: CGFloat = 1) -> NSColor { Self.color(c, alpha: alpha) }

    static func color(_ c: RGB, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: alpha)
    }


    private static let barCharacters = Set("█▉▊▋▌▍▎▏▓▒░■□▰▱▮▯⣿⣀━─".unicodeScalars.map { $0.value })
    private static let models = ["opus", "sonnet", "haiku", "fable", "claude", "gpt", "o3", "o4", "codex"]

    static func parseChips(_ rows: [Row], palette: Palette) -> [Chip] {
        var out: [Chip] = []
        for row in rows {
            var parts: [(text: String, fg: RGB?)] = []
            var current = "", fg: RGB?
            func flush() {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { parts.append((t, fg)) }
                current = ""; fg = nil
            }
            var x = 0
            while x < row.count {
                let cell = row.cells[x]
                if cell.isWideTail { x += 1; continue }
                let s = cell.isEmpty ? " " : row.text(at: x)
                let isSep = (s == "|" || s == "│" || s == "·" || s == "•")
                    && (x == 0 || row.cells[x - 1].isEmpty || row.text(at: x - 1) == " ")
                if isSep { flush() } else {
                    current += s
                    if fg == nil, s != " ", !cell.attrs.fg.isDefault, !Self.barCharacters.contains(cell.scalar) {
                        fg = palette.resolve(cell.attrs.fg, isForeground: true)
                    }
                }
                x += 1
            }
            flush()
            for (i, part) in parts.enumerated() {
                out.append(chip(part.text, fg: part.fg, rowStart: i == 0))
            }
        }
        return out
    }

    private static func chip(_ raw: String, fg: RGB?, rowStart: Bool) -> Chip {
        var text = raw
        var percent: Double?
        if let r = text.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) {
            percent = Double(text[r].dropLast()).map { min(max($0 / 100, 0), 1) }
        }
        if text.unicodeScalars.contains(where: { Self.barCharacters.contains($0.value) }) {
            text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !Self.barCharacters.contains($0.value) }))
            text = text.replacingOccurrences(of: "[]", with: "").replacingOccurrences(of: "[ ]", with: "")
        }
        var symbol: String?
        let arrows: Set<Character> = ["⏵", "▶", "►", "▸", "»", "⏩"]
        if let first = text.first, arrows.contains(first) {
            text = String(text.drop { arrows.contains($0) || $0 == " " })
            symbol = "forward.fill"
        }
        var hint = ""
        if let open = text.lastIndex(of: "("), text.hasSuffix(")"), open != text.startIndex {
            hint = String(text[open...])
            text = String(text[..<open])
        }
        text = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let lower = text.lowercased()
        if symbol == nil {
            if text.hasPrefix("~") || text.hasPrefix("/") { symbol = "folder" }
            else if Self.models.contains(where: { lower.hasPrefix($0) }) { symbol = "sparkle" }
            else if percent != nil && (lower.hasPrefix("5h") || lower.hasPrefix("7d") || lower.contains("week")) { symbol = "clock" }
        }
        return Chip(text: text, hint: hint, color: fg.map { color($0) }, symbol: symbol, percent: percent, rowStart: rowStart)
    }


    private func size(of chip: Chip) -> CGFloat {
        var w: CGFloat = 16
        if chip.symbol != nil { w += 16 }
        if chip.percent != nil { w += 34 }
        w += (chip.text as NSString).size(withAttributes: [.font: chipFont]).width
        if !chip.hint.isEmpty { w += 4 + (chip.hint as NSString).size(withAttributes: [.font: hintFont]).width }
        return ceil(w)
    }

    private func layoutChips(width: CGFloat) -> (frames: [NSRect], height: CGFloat) {
        var frames: [NSRect] = []
        var x = inset, y: CGFloat = 5
        for chip in chips {
            let w = min(size(of: chip), width - 2 * inset)
            let extra: CGFloat = chip.rowStart && x > inset ? 10 : 0
            if x + extra + w > width - inset && x > inset {
                x = inset; y += chipHeight + 4
            } else {
                x += extra
            }
            frames.append(NSRect(x: x, y: y, width: w, height: chipHeight))
            x += w + gap
        }
        return (frames, chips.isEmpty ? 0 : y + chipHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        native ? drawChips() : drawRows()
    }

    private func drawChips() {
        let frames = layoutChips(width: bounds.width).frames
        let defaultText = NSColor.labelColor.withAlphaComponent(0.8)
        for (chip, f) in zip(chips, frames) {
            let tint = chip.color ?? NSColor.labelColor
            tint.withAlphaComponent(chip.color == nil ? 0.07 : 0.14).setFill()
            NSBezierPath(roundedRect: f, xRadius: chipHeight / 2, yRadius: chipHeight / 2).fill()
            let textColor = chip.color ?? defaultText
            var x = f.minX + 8
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: f).addClip()
            if let name = chip.symbol, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [textColor]))) {
                let s = image.size
                image.draw(in: NSRect(x: x + (12 - s.width) / 2, y: f.midY - s.height / 2, width: s.width, height: s.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += 16
            }
            if let p = chip.percent {
                let track = NSRect(x: x, y: f.midY - 2, width: 28, height: 4)
                textColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                let meter = p >= 0.8 ? NSColor.systemRed : p >= 0.5 ? NSColor.systemOrange : (chip.color ?? NSColor.systemGreen)
                meter.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: track.minY, width: max(4, 28 * p), height: 4), xRadius: 2, yRadius: 2).fill()
                x += 34
            }
            let main = NSAttributedString(string: chip.text, attributes: [.font: chipFont, .foregroundColor: textColor])
            let ts = main.size()
            main.draw(at: NSPoint(x: x, y: f.midY - ts.height / 2))
            x += ts.width + 4
            if !chip.hint.isEmpty {
                let hint = NSAttributedString(string: chip.hint, attributes: [.font: hintFont, .foregroundColor: NSColor.secondaryLabelColor])
                hint.draw(at: NSPoint(x: x, y: f.midY - hint.size().height / 2))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawRows() {
        for (i, row) in rows.enumerated() {
            let line = NSMutableAttributedString()
            for x in 0..<row.count {
                let cell = row.cells[x]
                if cell.isWideTail { continue }
                let a = cell.attrs
                var fg = palette.resolve(a.fg, isForeground: true)
                var bg: RGB? = a.bg.isDefault ? nil : palette.resolve(a.bg, isForeground: false)
                if a.flags.contains(.inverse) { let f = fg; fg = bg ?? palette.background; bg = f }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: a.flags.contains(.bold) ? bold : font,
                    .foregroundColor: color(fg, alpha: a.flags.contains(.faint) ? 0.6 : 1),
                ]
                if let bg { attrs[.backgroundColor] = color(bg) }
                line.append(NSAttributedString(string: cell.isEmpty ? " " : row.text(at: x), attributes: attrs))
            }
            line.draw(at: NSPoint(x: inset, y: 4 + CGFloat(i) * lineHeight))
        }
    }
}


struct StatusSummary: Equatable {
    var folder: String?
    var branch: String?
    var model: String?
    var mode: String?
    var shells: String?
    var context: Double?
    var contextText: String?
    var usage: String?
    var usagePercent: Double?
    var others: [String] = []

    var isEmpty: Bool { folder == nil && branch == nil && model == nil && mode == nil && context == nil && others.isEmpty }

    var details: String {
        var lines: [String] = []
        if let contextText { lines.append("Context: \(contextText)") }
        if let usage { lines.append("Usage: \(usage)") }
        lines += others
        return lines.joined(separator: "\n")
    }

    init() {}

    init(rows: [Row], palette: Palette) {
        for chip in StatusStripView.parseChips(rows, palette: palette) {
            let text = chip.text, lower = text.lowercased()
            let full = chip.hint.isEmpty ? text : text + " " + chip.hint
            if chip.symbol == "folder", folder == nil { folder = text }
            else if chip.symbol == "sparkle", model == nil { model = text }
            else if chip.symbol == "clock" { usage = full; usagePercent = chip.percent }
            else if chip.symbol == "forward.fill" { mode = text }
            else if lower.hasPrefix("branch:") || lower.hasPrefix("\u{2387}") {
                branch = text.drop { $0 != ":" && $0 != "\u{2387}" }.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            else if lower.contains("shell") && lower.count < 14 { shells = text }
            else if let p = chip.percent, context == nil { context = p; contextText = text }
            else { others.append(full) }
        }
    }
}
