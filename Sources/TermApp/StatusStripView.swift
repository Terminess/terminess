import AppKit
import TermCore

final class StatusStripView: NSView {
    var rows: [Row] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var palette = Palette() { didSet { needsDisplay = true } }
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 3 }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rows.isEmpty ? 0 : CGFloat(rows.count) * lineHeight + 8)
    }

    private func color(_ c: RGB, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: alpha)
    }

    override func draw(_ dirtyRect: NSRect) {
        color(palette.background).setFill()
        dirtyRect.fill()
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
            line.draw(at: NSPoint(x: 18, y: 4 + CGFloat(i) * lineHeight))
        }
    }
}
