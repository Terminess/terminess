import TermTranscript
import AppKit
import CoreText
import TermCore

@MainActor
final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    var session: TerminalSession? {
        didSet { lastScrolledOff = terminal?.screen.scrolledOff ?? 0 }
    }
    var terminal: Terminal? { session?.terminal }


    private var zoom: CGFloat = 0
    private var fontSize: CGFloat { max(6, CGFloat(Settings.shared.fontSize) + zoom) }
    private var regular: CTFont!
    private var bold: CTFont!
    private var italic: CTFont!
    private var boldItalic: CTFont!
    private var fakeBold = false
    private var fakeItalic = false
    private var ascent: CGFloat = 0
    private struct LineKey: Hashable {
        let text: String
        let face: Int
        let color: RGB
        let faint: Bool
        let bold: Bool
        let kern: CGFloat
    }
    private var lineCache: [LineKey: CTLine] = [:]
    private(set) var cellSize = NSSize(width: 8, height: 16)
    private(set) var padding: CGFloat = 6
    private var kern: CGFloat = 0
    private var cursorShown: CGPoint?
    private var cursorTimer: Timer?
    private var scrollPixel: CGFloat = 0


    private var scrollOffset = 0
    private var scrollRemainder: CGFloat = 0
    private var lastScrolledOff = 0
    private var syncStarted: Date?
    private var lastCursor: (x: Int, y: Int) = (0, 0)
    private var colorCache: [UInt32: CGColor] = [:]
    private var imageCache: [Int: NSImage] = [:]
    private var markedText = ""
    private var trackingArea: NSTrackingArea?


    private struct GridPoint: Comparable {
        var line: Int
        var col: Int
        static func < (a: GridPoint, b: GridPoint) -> Bool {
            a.line != b.line ? a.line < b.line : a.col < b.col
        }
    }
    private enum SelectionUnit { case character, word, line }
    private var selectionAnchor: GridPoint?
    private var selectionHead: GridPoint?
    private var selectionUnit: SelectionUnit = .character
    private var mouseReporting = false

    private var findBar: FindBar?
    private var matches: [SearchMatch] = []
    private var matchIndex: Int?
    private var matchesByLine: [Int: [SearchMatch]] = [:]
    private var lastSearch = Date.distantPast

    override init(frame: NSRect) {
        super.init(frame: frame)
        loadFonts()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .terminalSettingsChanged, object: nil)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blinkTick() }
        }
    }


    private var blinkTimer: Timer?
    private var cursorOn = true

    private func blinkTick() {
        guard let t = terminal, t.modes.cursorBlink, window?.isKeyWindow == true else {
            if !cursorOn { cursorOn = true; updateCursorDisplay() }
            return
        }
        cursorOn.toggle()
        updateCursorDisplay()
    }

    private func wakeCursor() {
        cursorOn = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { !Settings.shared.isModern || Settings.shared.backgroundOpacity >= 1 }

    private var backgroundAlpha: CGFloat {
        Settings.shared.isModern ? CGFloat(Settings.shared.backgroundOpacity) : 1
    }

    var backgroundNSColor: NSColor {
        let c = (terminal?.palette ?? Palette()).background
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    private func loadFonts() {
        let size = fontSize
        let base = Settings.shared.font(size: size)
        let fm = NSFontManager.shared
        let heavy = fm.convert(base, toHaveTrait: .boldFontMask)
        fakeBold = heavy.fontName == base.fontName
        regular = base as CTFont
        bold = (fakeBold ? base : heavy) as CTFont
        func italicFace(_ f: CTFont) -> CTFont? {
            guard let real = CTFontCreateCopyWithSymbolicTraits(f, size, nil, .traitItalic, .traitItalic),
                  (CTFontCopyPostScriptName(real) as String) != (CTFontCopyPostScriptName(f) as String) else { return nil }
            return real
        }
        let realItalic = italicFace(regular)
        fakeItalic = realItalic == nil
        italic = realItalic ?? regular
        boldItalic = italicFace(bold) ?? bold

        var glyph = CGGlyph(0)
        var ch: UniChar = 0x4D
        CTFontGetGlyphsForCharacters(regular, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        ascent = CTFontGetAscent(regular)
        let natural = ceil(ascent + CTFontGetDescent(regular) + CTFontGetLeading(regular))
        let height = ceil(max(natural, ceil(size * 1.2)) * CGFloat(Settings.shared.lineSpacing))
        kern = Settings.shared.isModern ? CGFloat(Settings.shared.letterSpacing) : 0
        padding = Settings.shared.isModern ? 18 : 6
        lineCache.removeAll()
        cellSize = NSSize(width: advance.width + kern, height: height)
    }

    @objc private func settingsChanged() {
        loadFonts()
        applyCursorDefaults()
        colorCache.removeAll()
        updateGridSize()
        needsDisplay = true
    }

    func applyCursorDefaults() {
        guard let t = terminal else { return }
        t.defaultCursorShape = Settings.shared.engineCursorShape
        t.defaultCursorBlink = Settings.shared.cursorBlink
    }

    func contentSize(columns: Int, rows: Int) -> NSSize {
        NSSize(width: CGFloat(columns) * cellSize.width + padding * 2,
               height: CGFloat(rows) * cellSize.height + padding * 2)
    }


    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
    }

    private func updateGridSize() {
        guard let session else { return }
        let cols = max(2, Int((bounds.width - padding * 2) / cellSize.width))
        let rows = max(1, Int((bounds.height - padding * 2) / cellSize.height))
        if cols != session.terminal.columns || rows != session.terminal.rows {
            clearSelection()
            scrollOffset = 0
        }
        session.resize(columns: cols, rows: rows,
                       cellWidth: Int(cellSize.width.rounded()), cellHeight: Int(cellSize.height.rounded()))
        lastScrolledOff = session.terminal.screen.scrolledOff
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }


    private var flushScheduled = false
    private var lastFlush = Date.distantPast

    func terminalDidUpdate() {
        guard !flushScheduled else { return }
        let since = Date().timeIntervalSince(lastFlush)
        let onScreenFrame = NSApp.isActive ? 1.0 / 60 : 1.0 / 20
        let frame: TimeInterval = isOnScreen ? onScreenFrame : (window == nil && hostWindowShowing?() == true ? 0.1 : 1.0)
        if since >= frame {
            flushUpdates()
        } else {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (frame - since)) { [weak self] in
                MainActor.assumeIsolated {
                    self?.flushScheduled = false
                    self?.flushUpdates()
                }
            }
        }
    }

    private func flushUpdates() {
        lastFlush = Date()
        guard let t = terminal else { return }
        if findBar != nil, Date().timeIntervalSince(lastSearch) > 0.3 { runSearch(keepCurrent: true) }
        if t.modes.synchronizedOutput {
            if syncStarted == nil {
                syncStarted = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    MainActor.assumeIsolated { self?.flushUpdates() }
                }
            }
            if let s = syncStarted, Date().timeIntervalSince(s) < 0.2 { return }
        }
        syncStarted = nil

        let scrolled = t.screen.scrolledOff - lastScrolledOff
        lastScrolledOff = t.screen.scrolledOff
        let dirty = t.takeDirtyRows()
        if hideAgentInput || onAgentScreen != nil { analyseAgentScreen() }
        if scrollOffset > 0 {
            scrollOffset = min(scrollOffset + max(0, scrolled), t.screen.scrollback.count)
            needsDisplay = true
        } else if !isOnScreen {
            staleWhileHidden = true
        } else if hiddenBand != nil || hideAgentInput || staleWhileHidden {
            staleWhileHidden = false
            needsDisplay = true
        } else {
            for y in dirty { setNeedsDisplay(rowRect(y)) }
        }
        let c = (t.cursor.x, t.cursor.y)
        if c != lastCursor && Settings.shared.isModern {
            if isOnScreen && NSApp.isActive { glideCursor(to: c, from: lastCursor) } else { cursorShown = nil }
        }
        if c != lastCursor {
            setNeedsDisplay(rowRect(lastCursor.y))
            setNeedsDisplay(rowRect(c.1))
            lastCursor = c
        }
        updateCursorDisplay()
    }

    private func glideCursor(to c: (Int, Int), from old: (x: Int, y: Int)) {
        let target = CGPoint(x: padding + CGFloat(c.0) * cellSize.width, y: padding + CGFloat(c.1) * cellSize.height)
        let start = cursorShown ?? CGPoint(x: padding + CGFloat(old.x) * cellSize.width, y: padding + CGFloat(old.y) * cellSize.height)
        if abs(c.1 - old.y) > 2 || abs(c.0 - old.x) > 30 {
            cursorShown = target
            return
        }
        cursorShown = start
        guard cursorTimer == nil else { return }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let t = self.terminal, let shown = self.cursorShown else {
                    self.cursorTimer?.invalidate()
                    self.cursorTimer = nil
                    return
                }
                let goal = CGPoint(x: self.padding + CGFloat(t.cursor.x) * self.cellSize.width,
                                   y: self.padding + CGFloat(t.cursor.y) * self.cellSize.height)
                let next = CGPoint(x: shown.x + (goal.x - shown.x) * 0.38, y: shown.y + (goal.y - shown.y) * 0.38)
                let done = hypot(goal.x - next.x, goal.y - next.y) < 0.5
                self.cursorShown = done ? goal : next
                let area = NSRect(x: min(shown.x, goal.x) - 2, y: min(shown.y, goal.y) - 2,
                                  width: abs(goal.x - shown.x) + self.cellSize.width * 2 + 4,
                                  height: abs(goal.y - shown.y) + self.cellSize.height + 4)
                self.setNeedsDisplay(area)
                if done {
                    self.cursorTimer?.invalidate()
                    self.cursorTimer = nil
                }
            }
        }
    }

    private func updateCursorDisplay() {
        guard let t = terminal else { return }
        setNeedsDisplay(rowRect(t.cursor.y))
    }

    private func rowRect(_ y: Int) -> NSRect {
        NSRect(x: 0, y: padding + CGFloat(y) * cellSize.height - 1, width: bounds.width, height: cellSize.height + 2)
    }

    var hideAgentInput = false { didSet { if hideAgentInput != oldValue { updateAgentScreen(); needsDisplay = true } } }
    var hideAgentStatus = false { didSet { if hideAgentStatus != oldValue { updateAgentScreen(); needsDisplay = true } } }
    var onAgentScreen: ((Bool, [Row], Bool) -> Void)?
    private var lastMenuArea = ""
    private var hiddenBand: ClosedRange<Int>?
    private var lastStatusText = ""
    private var lastInputVisible: Bool?
    private var lastBusy = false

    func agentLooksBusy() -> Bool {
        guard let t = terminal else { return false }
        for y in max(0, t.rows - 30)..<t.rows where t.screen.rows[y].plainText().lowercased().contains("esc to interrupt") {
            return true
        }
        return false
    }

    var isOnScreen: Bool { window?.occlusionState.contains(.visible) == true }

    private func analyseAgentScreen() {
        let interval: TimeInterval = isOnScreen ? 0 : (window == nil && hostWindowShowing?() == true ? 0.2 : 1.0)
        let since = Date().timeIntervalSince(lastAnalysis)
        if since >= interval {
            lastAnalysis = Date()
            updateAgentScreen()
        } else if !analysisScheduled {
            analysisScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval - since)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.analysisScheduled = false
                    self.lastAnalysis = Date()
                    self.updateAgentScreen()
                }
            }
        }
    }
    private var lastAnalysis = Date.distantPast
    private var staleWhileHidden = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, terminal != nil { cameOnScreen() }
    }

    func cameOnScreen() {
        staleWhileHidden = false
        needsDisplay = true
        flushScheduled = false
        flushUpdates()
    }
    private var analysisScheduled = false
    var hostWindowShowing: (() -> Bool)?

    var onQueued: (([String]) -> Void)?
    private var lastQueued: [String] = []

    func updateAgentScreen(force: Bool = false) {
        guard let t = terminal else { return }
        let input = detectInputBand(t)
        if hideAgentInput, let input {
            hiddenBand = hideAgentStatus ? input.lowerBound...(t.rows - 1) : input
        } else {
            hiddenBand = nil
        }
        var status: [Row] = []
        if let input, input.upperBound + 1 < t.rows {
            status = Array(t.screen.rows[(input.upperBound + 1)...])
            while let last = status.last, last.plainText().isEmpty { status.removeLast() }
        }
        let text = status.map { $0.plainText() }.joined(separator: "\n")
        let visible = input != nil
        let busy = agentLooksBusy()
        if let report = onQueued {
            var queued: [String] = []
            if let input {
                let top = max(0, input.lowerBound - 40)
                queued = QueuedMessages.parse(t.screen.rows[top..<input.lowerBound].map { $0.plainText() })
            }
            if queued != lastQueued {
                lastQueued = queued
                report(queued)
            }
        }
        let menuArea = visible ? "" : t.screen.rows.suffix(16).map { $0.plainText() }.joined(separator: "\n")
        if force || text != lastStatusText || visible != lastInputVisible || busy != lastBusy || menuArea != lastMenuArea {
            lastMenuArea = menuArea
            lastStatusText = text
            lastInputVisible = visible
            lastBusy = busy
            onAgentScreen?(visible, status, busy)
        }
    }

    private func detectInputBand(_ t: Terminal) -> ClosedRange<Int>? {
        guard scrollOffset == 0, scrollPixel == 0, !t.isAlternate || t.screen.rows.count > 0 else { return nil }
        let rows = t.screen.rows
        let lowest = max(0, t.rows - 30)
        func isRule(_ r: Row) -> Bool {
            var n = 0
            for c in r.cells where c.scalar == 0x2500 || c.scalar == 0x2501 { n += 1 }
            return n >= max(10, r.count * 6 / 10)
        }
        func firstText(_ r: Row) -> String {
            r.plainText().trimmingCharacters(in: .whitespaces)
        }
        var y = t.rows - 1
        while y > lowest {
            if isRule(rows[y]) {
                var top = y - 1
                while top >= max(lowest, y - 14), !isRule(rows[top]) { top -= 1 }
                if top >= lowest, top < y - 1, isRule(rows[top]) {
                    let prompt = firstText(rows[top + 1])
                    if prompt.hasPrefix("\u{276F}") || prompt.hasPrefix(">") { return top...y }
                }
            }
            y -= 1
        }
        y = t.rows - 1
        while y > lowest {
            let r = rows[y]
            if firstText(r).hasPrefix("\u{203A}"), let bg = r.cells.first(where: { !$0.attrs.bg.isDefault })?.attrs.bg {
                var top = y, bottom = y
                func shaded(_ i: Int) -> Bool { rows[i].cells.prefix(4).contains { $0.attrs.bg == bg } }
                while top > lowest, shaded(top - 1) { top -= 1 }
                while bottom < t.rows - 1, shaded(bottom + 1) { bottom += 1 }
                return top...bottom
            }
            y -= 1
        }
        let cy = t.cursor.y
        if cy >= 0, cy < t.rows, firstText(rows[cy]).hasPrefix("\u{203A}"),
           !rows[cy].cells.contains(where: { !$0.attrs.bg.isDefault }),
           ((cy + 1)..<t.rows).allSatisfy({ firstText(rows[$0]).isEmpty }) {
            return cy...cy
        }
        return nil
    }

    private func sourceRow(_ d: Int) -> Int {
        guard let band = hiddenBand else { return d }
        let k = band.count
        return d < band.lowerBound + k ? d - k : d
    }

    var parkedNotice: String? { didSet { needsDisplay = true } }

    var onFocus: (() -> Void)?
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }

    override func becomeFirstResponder() -> Bool {
        updateCursorDisplay()
        onFocus?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        updateCursorDisplay()
        return true
    }

    func focusChanged(_ isFocused: Bool) {
        if let t = terminal { session?.send(InputEncoder.focus(isFocused, modes: t.modes)) }
        updateCursorDisplay()
    }


    private func viewportRow(_ vy: Int, _ t: Terminal) -> Row {
        let sb = t.screen.scrollback
        if scrollOffset == 0 && vy >= 0 { return t.screen.rows[vy] }
        let k = sb.count - scrollOffset + vy
        if k < 0 { return Row(columns: t.columns) }
        return k < sb.count ? sb[k] : t.screen.rows[min(k - sb.count, t.rows - 1)]
    }

    private func absoluteLine(_ vy: Int, _ t: Terminal) -> Int {
        let sb = t.screen.scrollback.count
        return (t.screen.scrolledOff - sb) + (sb - scrollOffset + vy)
    }

    private func row(atAbsolute line: Int, _ t: Terminal) -> Row? {
        let sb = t.screen.scrollback
        let k = line - (t.screen.scrolledOff - sb.count)
        if k < 0 { return nil }
        if k < sb.count { return sb[k] }
        let y = k - sb.count
        return y < t.rows ? t.screen.rows[y] : nil
    }

    private func scrollToBottom() {
        if scrollOffset != 0 || scrollPixel != 0 { scrollOffset = 0; scrollPixel = 0; needsDisplay = true }
    }


    private func cgColor(_ rgb: RGB, alpha: CGFloat = 1) -> CGColor {
        let key = UInt32(rgb.r) << 24 | UInt32(rgb.g) << 16 | UInt32(rgb.b) << 8 | UInt32(alpha * 255)
        if let c = colorCache[key] { return c }
        let c = CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: alpha)
        colorCache[key] = c
        return c
    }

    private func colors(for a: Attributes, _ p: Palette, reverseScreen: Bool) -> (fg: RGB, bg: RGB) {
        var fg = p.resolve(a.fg, isForeground: true)
        var bg = p.resolve(a.bg, isForeground: false)
        if a.flags.contains(.bold), let i = a.fg.index, i < 8 { fg = p.colors[Int(i) + 8] }
        if a.flags.contains(.inverse) != reverseScreen { swap(&fg, &bg) }
        return (fg, bg)
    }

    private func font(for a: Attributes) -> CTFont {
        switch (a.flags.contains(.bold), a.flags.contains(.italic)) {
        case (true, true): return boldItalic
        case (true, false): return bold
        case (false, true): return italic
        default: return regular
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldSmoothFonts(!Settings.shared.thinStrokes)
        let p = terminal?.palette ?? Palette()
        if backgroundAlpha < 1 {
            ctx.clear(dirtyRect)
        } else {
            ctx.setFillColor(cgColor(p.background))
            ctx.fill(dirtyRect)
        }
        guard let t = terminal else { return }

        let shift = scrollPixel
        ctx.saveGState()
        if shift > 0 { ctx.translateBy(x: 0, y: shift) }
        let first = max(shift > 0 ? -1 : 0, Int((dirtyRect.minY - shift - padding) / cellSize.height))
        let last = min(t.rows - 1, Int((dirtyRect.maxY - padding) / cellSize.height))
        drawBlocks(t, p, ctx)
        if first <= last {
            let selection = normalisedSelection()
            for vy in first...last {
                let src = sourceRow(vy)
                drawRow(viewportRow(src, t), vy: vy, line: absoluteLine(src, t), selection: selection, t, p, ctx)
            }
            drawImages(t)
            if let link = hoverLink {
                var vy = link.line - absoluteLine(0, t)
                if let band = hiddenBand, vy < band.lowerBound { vy += band.count }
                let y = padding + CGFloat(vy + 1) * cellSize.height - 1.5
                ctx.setStrokeColor(cgColor(p.colors[4]))
                ctx.setLineWidth(1)
                ctx.strokeLineSegments(between: [CGPoint(x: padding + CGFloat(link.from) * cellSize.width, y: y),
                                                 CGPoint(x: padding + CGFloat(link.to + 1) * cellSize.width, y: y)])
            }
        }
        ctx.restoreGState()
        drawCursor(t, p, ctx)
        if dimmed {
            ctx.setFillColor(cgColor(p.background, alpha: 0.38))
            ctx.fill(dirtyRect)
        }
        if let notice = parkedNotice { drawNotice(notice, p) }
    }

    private func drawRow(_ row: Row, vy: Int, line: Int, selection: (GridPoint, GridPoint)?,
                         _ t: Terminal, _ p: Palette, _ ctx: CGContext) {
        let top = padding + CGFloat(vy) * cellSize.height
        let cw = cellSize.width, ch = cellSize.height
        let baseline = top + floor((ch - (ascent + CTFontGetDescent(regular))) / 2) + ascent
        let reverse = t.modes.reverseVideo
        let cols = min(row.count, t.columns)

        func selected(_ x: Int) -> Bool {
            guard let (a, b) = selection else { return false }
            let g = GridPoint(line: line, col: x)
            return g >= a && g <= b
        }

        var x = 0
        while x < cols {
            let cell = row.cells[x]
            let bg = selected(x) ? p.selection : colors(for: cell.attrs, p, reverseScreen: reverse).bg
            var end = x + 1
            while end < cols {
                let next = row.cells[end]
                let nbg = selected(end) ? p.selection : colors(for: next.attrs, p, reverseScreen: reverse).bg
                if nbg != bg { break }
                end += 1
            }
            if bg != p.background {
                ctx.setFillColor(cgColor(bg))
                ctx.fill(CGRect(x: padding + CGFloat(x) * cw, y: top, width: CGFloat(end - x) * cw, height: ch))
            }
            x = end
        }

        if let found = matchesByLine[line] {
            let current = matchIndex.map { matches[$0] }
            for m in found {
                let from = m.startLine == line ? m.startColumn : 0
                let to = m.endLine == line ? m.endColumn : cols - 1
                let isCurrent = current == m
                ctx.setFillColor(isCurrent ? CGColor(srgbRed: 1, green: 0.62, blue: 0.1, alpha: 0.75)
                                           : CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 0.35))
                ctx.fill(CGRect(x: padding + CGFloat(from) * cw, y: top,
                                width: CGFloat(to - from + 1) * cw, height: ch))
            }
        }

        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        x = 0
        while x < cols {
            let cell = row.cells[x]
            if cell.isEmpty || cell.isWideTail || cell.attrs.flags.contains(.invisible) { x += 1; continue }
            let a = cell.attrs
            let ascii = cell.scalar < 0x7F && !a.flags.contains(.cluster)
            if ascii {
                var end = x + 1
                var text = String(UnicodeScalar(UInt8(cell.scalar)))
                while end < cols {
                    let n = row.cells[end]
                    guard n.attrs == a, n.scalar < 0x7F, !n.isEmpty else { break }
                    text.append(Character(UnicodeScalar(UInt8(n.scalar))))
                    end += 1
                }
                drawText(text, at: x, baseline: baseline, attrs: a, p: p, reverse: reverse, ctx)
                drawDecorations(from: x, to: end, top: top, baseline: baseline, attrs: a, p: p, reverse: reverse, ctx)
                x = end
            } else {
                let w = cell.isWide ? 2 : 1
                if !a.flags.contains(.cluster), BoxDrawing.handles(cell.scalar) {
                    let fg = colors(for: a, p, reverseScreen: reverse).fg
                    let rect = CGRect(x: padding + CGFloat(x) * cw, y: top, width: CGFloat(w) * cw, height: ch)
                    let scale = window?.backingScaleFactor ?? 2
                    let modern = Settings.shared.isModern
                    let isLine = cell.scalar < 0x2580
                    var glyph = cell.scalar
                    if modern {
                        switch glyph {
                        case 0x250C: glyph = 0x256D
                        case 0x2510: glyph = 0x256E
                        case 0x2514: glyph = 0x2570
                        case 0x2518: glyph = 0x256F
                        default: break
                        }
                    }
                    let alpha: CGFloat = a.flags.contains(.faint) ? 0.55 : 1
                    var ink = fg
                    if modern && isLine {
                        func mix(_ f: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(f) * 0.55 + Double(b) * 0.45).rounded()) }
                        ink = RGB(mix(fg.r, p.background.r), mix(fg.g, p.background.g), mix(fg.b, p.background.b))
                    }
                    let width: CGFloat = modern && isLine ? 0.75 : max(1, (fontSize / 13).rounded())
                    if BoxDrawing.draw(glyph, in: rect, color: cgColor(ink, alpha: alpha),
                                       lineWidth: width, scale: scale, ctx) {
                        x += w
                        continue
                    }
                }
                drawText(row.text(at: x), at: x, baseline: baseline, attrs: a, p: p, reverse: reverse, ctx, span: w)
                drawDecorations(from: x, to: x + w, top: top, baseline: baseline, attrs: a, p: p, reverse: reverse, ctx)
                x += w
            }
        }
        ctx.restoreGState()
    }

    private func drawNotice(_ text: String, _ p: Palette) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor(cgColor: cgColor(p.background)) ?? .white]
        let label = NSAttributedString(string: "⏾  " + text, attributes: attrs)
        let size = label.size()
        let rect = NSRect(x: (bounds.width - size.width) / 2 - 14, y: bounds.height - size.height - 26,
                          width: size.width + 28, height: size.height + 12)
        NSColor(cgColor: cgColor(p.foreground, alpha: 0.85))?.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        label.draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + 6))
    }

    private func drawImages(_ t: Terminal) {
        let images = t.images
        guard !images.isEmpty else {
            if !imageCache.isEmpty { imageCache.removeAll() }
            return
        }
        let top = absoluteLine(0, t)
        var live = Set<Int>()
        for img in images where img.onAlternate == t.isAlternate {
            live.insert(img.id)
            let vy = img.line - top
            guard vy + img.heightCells > 0, vy < t.rows else { continue }
            let image = imageCache[img.id] ?? NSImage(data: img.data)
            guard let image else { continue }
            imageCache[img.id] = image
            let rect = NSRect(x: padding + CGFloat(img.column) * cellSize.width,
                              y: padding + CGFloat(vy) * cellSize.height,
                              width: CGFloat(img.widthCells) * cellSize.width,
                              height: CGFloat(img.heightCells) * cellSize.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        imageCache = imageCache.filter { live.contains($0.key) }
    }

    private func drawText(_ text: String, at x: Int, baseline: CGFloat, attrs a: Attributes, p: Palette,
                          reverse: Bool, _ ctx: CGContext, span: Int = 0, colorOverride: RGB? = nil) {
        guard !text.isEmpty else { return }
        let fg = colorOverride ?? colors(for: a, p, reverseScreen: reverse).fg
        let color = cgColor(fg, alpha: a.flags.contains(.faint) ? 0.55 : 1)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(for: a),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
        ]
        if kern > 0 { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = kern }
        if fakeBold && a.flags.contains(.bold) {
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -7.0
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color
        }
        let face = (a.flags.contains(.bold) ? 1 : 0) + (a.flags.contains(.italic) ? 2 : 0)
        let key = LineKey(text: text, face: face, color: fg,
                          faint: a.flags.contains(.faint), bold: fakeBold && a.flags.contains(.bold), kern: kern)
        let line: CTLine
        if let cached = lineCache[key] {
            line = cached
        } else {
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            if lineCache.count > 4000 { lineCache.removeAll(keepingCapacity: true) }
            lineCache[key] = line
        }
        var px = padding + CGFloat(x) * cellSize.width
        if span > 0 {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let room = CGFloat(span) * cellSize.width
            if width < room { px += (room - width) / 2 }
        }
        ctx.textPosition = CGPoint(x: px, y: baseline)
        if fakeItalic && a.flags.contains(.italic) {
            let saved = ctx.textMatrix
            ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: -1, tx: 0, ty: 0)
            ctx.textPosition = CGPoint(x: px, y: baseline)
            CTLineDraw(line, ctx)
            ctx.textMatrix = saved
        } else {
            CTLineDraw(line, ctx)
        }
    }

    private func drawDecorations(from x0: Int, to x1: Int, top: CGFloat, baseline: CGFloat, attrs a: Attributes,
                                 p: Palette, reverse: Bool, _ ctx: CGContext) {
        let hasLine = a.underline != .none || a.flags.contains(.strikethrough) || a.flags.contains(.overline)
        guard hasLine else { return }
        let fg = colors(for: a, p, reverseScreen: reverse).fg
        let lineColor = a.underlineColor.isDefault ? fg : p.resolve(a.underlineColor, isForeground: true)
        let left = padding + CGFloat(x0) * cellSize.width
        let right = padding + CGFloat(x1) * cellSize.width
        let thickness = max(1, (fontSize / 13).rounded())
        ctx.saveGState()
        ctx.setLineWidth(thickness)
        ctx.setStrokeColor(cgColor(lineColor))
        let uy = min(baseline + 2 * thickness, top + cellSize.height - thickness)

        switch a.underline {
        case .none: break
        case .single:
            ctx.strokeLineSegments(between: [CGPoint(x: left, y: uy), CGPoint(x: right, y: uy)])
        case .double:
            ctx.strokeLineSegments(between: [CGPoint(x: left, y: uy - thickness), CGPoint(x: right, y: uy - thickness),
                                             CGPoint(x: left, y: uy + thickness), CGPoint(x: right, y: uy + thickness)])
        case .curly:
            let path = CGMutablePath()
            let amp = 1.5 * thickness, period = cellSize.width / 1.5
            path.move(to: CGPoint(x: left, y: uy))
            var px = left
            while px < right {
                let step = min(period / 2, right - px)
                let up = Int((px - left) / (period / 2)) % 2 == 0
                path.addQuadCurve(to: CGPoint(x: px + step, y: uy),
                                  control: CGPoint(x: px + step / 2, y: uy + (up ? -amp : amp) * 2))
                px += step
            }
            ctx.addPath(path)
            ctx.strokePath()
        case .dotted:
            ctx.setLineDash(phase: 0, lengths: [thickness, thickness * 2])
            ctx.strokeLineSegments(between: [CGPoint(x: left, y: uy), CGPoint(x: right, y: uy)])
        case .dashed:
            ctx.setLineDash(phase: 0, lengths: [thickness * 4, thickness * 2])
            ctx.strokeLineSegments(between: [CGPoint(x: left, y: uy), CGPoint(x: right, y: uy)])
        }
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(cgColor(fg))
        if a.flags.contains(.strikethrough) {
            let sy = baseline - CTFontGetXHeight(regular) / 2
            ctx.strokeLineSegments(between: [CGPoint(x: left, y: sy), CGPoint(x: right, y: sy)])
        }
        if a.flags.contains(.overline) {
            ctx.strokeLineSegments(between: [CGPoint(x: left, y: top + thickness), CGPoint(x: right, y: top + thickness)])
        }
        ctx.restoreGState()
    }

    private func drawCursor(_ t: Terminal, _ p: Palette, _ ctx: CGContext) {
        guard t.modes.cursorVisible || !markedText.isEmpty, scrollOffset == 0, hiddenBand == nil else { return }
        if !cursorOn && markedText.isEmpty { return }
        let x = t.cursor.x, y = t.cursor.y
        let row = t.screen.rows[y]
        let wide = x < row.count && row.cells[x].isWide
        let target = CGPoint(x: padding + CGFloat(x) * cellSize.width, y: padding + CGFloat(y) * cellSize.height)
        let origin = Settings.shared.isModern ? (cursorShown ?? target) : target
        let settled = hypot(origin.x - target.x, origin.y - target.y) < 1
        let rect = CGRect(x: origin.x, y: origin.y, width: cellSize.width * (wide ? 2 : 1), height: cellSize.height)
        let color = cgColor(p.cursor)

        if !markedText.isEmpty {
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let baseline = rect.minY + floor((cellSize.height - (ascent + CTFontGetDescent(regular))) / 2) + ascent
            drawText(markedText, at: x, baseline: baseline, attrs: Attributes(), p: p, reverse: false, ctx)
            let width = CGFloat(markedText.count) * cellSize.width
            ctx.setStrokeColor(color)
            ctx.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.maxY - 1), CGPoint(x: rect.minX + width, y: rect.maxY - 1)])
            ctx.restoreGState()
            return
        }

        let isFocused = window?.isKeyWindow == true && window?.firstResponder === self
        if !isFocused {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            return
        }
        switch t.cursorShape {
        case .block:
            ctx.setFillColor(color)
            if Settings.shared.isModern {
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
                ctx.fillPath()
            } else {
                ctx.fill(rect)
            }
            if settled, x < row.count, !row.cells[x].isEmpty {
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                let baseline = rect.minY + floor((cellSize.height - (ascent + CTFontGetDescent(regular))) / 2) + ascent
                drawText(row.text(at: x), at: x, baseline: baseline, attrs: row.cells[x].attrs, p: p,
                         reverse: false, ctx, span: wide ? 2 : 1, colorOverride: p.background)
                ctx.restoreGState()
            }
        case .underline:
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case .bar:
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        }
    }


    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, markedText.isEmpty, let b = KeyBinding.match(event) {
            scrollToBottom()
            session?.send(b.bytes)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let t = terminal else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        wakeCursor()
        if markedText.isEmpty, let b = KeyBinding.match(event) {
            scrollToBottom()
            session?.send(b.bytes)
            return
        }

        if !markedText.isEmpty {
            interpretKeyEvents([event])
            return
        }

        if t.kittyKeyboardFlags != 0, sendKitty(event, event.isARepeat ? .repeat : .press) { return }

        let flags = event.modifierFlags
        let leftOption = optionIsMeta(flags)
        var mods: KeyModifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if leftOption { mods.insert(.option) }

        if let key = specialKey(event) {
            scrollToBottom()
            var m = mods
            if flags.contains(.option) { m.insert(.option) }
            session?.send(InputEncoder.encode(key, modifiers: m, modes: t.modes))
            return
        }
        if flags.contains(.control) || leftOption {
            let base = event.charactersIgnoringModifiers ?? ""
            let text = flags.contains(.shift) && !flags.contains(.control) ? base.uppercased() : base
            if !text.isEmpty {
                scrollToBottom()
                session?.send(InputEncoder.encode(.character(text), modifiers: mods, modes: t.modes))
                return
            }
        }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        guard let t = terminal, t.kittyKeyboardFlags & KittyFlags.eventTypes.rawValue != 0, markedText.isEmpty else { return }
        _ = sendKitty(event, .release)
    }

    private func sendKitty(_ event: NSEvent, _ type: KeyEventType) -> Bool {
        guard let t = terminal else { return false }
        let f = event.modifierFlags
        let leftOption = optionIsMeta(f)
        var m: KittyModifiers = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if leftOption { m.insert(.alt) }
        if f.contains(.command) { m.insert(.super) }
        if f.contains(.capsLock) { m.insert(.capsLock) }
        let flags = t.kittyKeyboardFlags
        let allKeys = flags & KittyFlags.allKeysAsCodes.rawValue != 0

        let key: Key
        var text: String?
        var shifted: String?
        if let special = specialKey(event) {
            key = special
            if f.contains(.option) { m.insert(.alt) }
        } else {
            let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
            guard !base.isEmpty else { return false }
            let significant = m.subtracting([.shift, .capsLock])
            if significant.isEmpty && !allKeys { return false }
            key = base == " " ? .space : .character(base)
            text = event.characters
            shifted = event.characters(byApplyingModifiers: .shift)
        }
        if type == .press { scrollToBottom() }
        if let bytes = InputEncoder.kitty(key, modifiers: m, event: type, text: text, shiftedKey: shifted,
                                          flags: flags, modes: t.modes) {
            session?.send(bytes)
        }
        return true
    }

    private func optionIsMeta(_ f: NSEvent.ModifierFlags) -> Bool {
        guard f.contains(.option) else { return false }
        switch Settings.shared.optionKey {
        case "both": return true
        case "none": return false
        default: return f.rawValue & 0x20 != 0
        }
    }

    private func specialKey(_ e: NSEvent) -> Key? {
        if e.keyCode == 53 { return .escape }
        guard let sk = e.specialKey else { return nil }
        switch sk {
        case .upArrow: return .up
        case .downArrow: return .down
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .deleteForward: return .delete
        case .delete, .backspace: return .backspace
        case .carriageReturn, .enter, .newline: return .enter
        case .tab: return .tab
        case .backTab: return .tab
        case .insert, .help: return .insert
        default:
            let fkeys: [NSEvent.SpecialKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
                                               .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20]
            if let i = fkeys.firstIndex(of: sk) { return .function(i + 1) }
            return nil
        }
    }


    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        guard !text.isEmpty else { updateCursorDisplay(); return }
        scrollToBottom()
        session?.send(Array(text.utf8))
        updateCursorDisplay()
    }

    override func doCommand(by selector: Selector) {
        guard let t = terminal else { return }
        let key: Key?
        switch selector {
        case #selector(insertNewline(_:)): key = .enter
        case #selector(deleteBackward(_:)): key = .backspace
        case #selector(insertTab(_:)): key = .tab
        case #selector(cancelOperation(_:)): key = .escape
        case #selector(moveUp(_:)): key = .up
        case #selector(moveDown(_:)): key = .down
        case #selector(moveLeft(_:)): key = .left
        case #selector(moveRight(_:)): key = .right
        default: key = nil
        }
        if let key { session?.send(InputEncoder.encode(key, modifiers: [], modes: t.modes)) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        updateCursorDisplay()
    }

    func unmarkText() {
        markedText = ""
        updateCursorDisplay()
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let t = terminal, let window else { return .zero }
        let r = NSRect(x: padding + CGFloat(t.cursor.x) * cellSize.width,
                       y: padding + CGFloat(t.cursor.y) * cellSize.height,
                       width: cellSize.width, height: cellSize.height)
        return window.convertToScreen(convert(r, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }


    @objc func showFind(_ sender: Any?) {
        if findBar == nil {
            let bar = FindBar(frame: .zero)
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
            bar.onChange = { [weak self] _, _, _ in self?.runSearch(keepCurrent: false) }
            bar.onNext = { [weak self] in self?.step(1) }
            bar.onPrevious = { [weak self] in self?.step(-1) }
            bar.onClose = { [weak self] in self?.closeFind() }
            findBar = bar
            if let selected = selectedText(), !selected.isEmpty, !selected.contains("\n") {
                bar.field.stringValue = selected
                runSearch(keepCurrent: false)
            }
        }
        window?.makeFirstResponder(findBar?.field)
    }

    func debugSetFindQuery(_ q: String) {
        findBar?.field.stringValue = q
        runSearch(keepCurrent: false)
    }

    @objc func findNext(_ sender: Any?) { if findBar == nil { showFind(nil) } else { step(1) } }
    @objc func findPrevious(_ sender: Any?) { if findBar == nil { showFind(nil) } else { step(-1) } }

    private func closeFind() {
        findBar?.removeFromSuperview()
        findBar = nil
        matches = []
        matchesByLine = [:]
        matchIndex = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    private func runSearch(keepCurrent: Bool) {
        guard let t = terminal, let bar = findBar else { return }
        lastSearch = Date()
        let query = bar.field.stringValue
        let previous = matchIndex.map { matches[$0] }
        matches = t.search(query, regex: bar.regex, caseSensitive: bar.caseSensitive)
        var byLine: [Int: [SearchMatch]] = [:]
        for m in matches { for l in m.startLine...m.endLine { byLine[l, default: []].append(m) } }
        matchesByLine = byLine
        let valid = !bar.regex || (try? NSRegularExpression(pattern: query)) != nil || query.isEmpty
        if keepCurrent, let previous, let i = matches.firstIndex(of: previous) {
            matchIndex = i
        } else {
            matchIndex = matches.isEmpty ? nil : matches.count - 1
            if let i = matchIndex { reveal(matches[i]) }
        }
        bar.setCount(current: matchIndex, total: matches.count, valid: valid)
        needsDisplay = true
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let i = ((matchIndex ?? matches.count - 1) + delta + matches.count) % matches.count
        matchIndex = i
        reveal(matches[i])
        findBar?.setCount(current: i, total: matches.count, valid: true)
        needsDisplay = true
    }

    private func reveal(_ m: SearchMatch) {
        guard let t = terminal else { return }
        let sb = t.screen.scrollback.count
        let top = absoluteLine(0, t), bottom = absoluteLine(t.rows - 1, t)
        guard m.startLine < top || m.endLine > bottom else { return }
        let wanted = t.firstAbsoluteLine + sb + t.rows / 2 - m.startLine
        scrollOffset = min(max(wanted, 0), sb)
        needsDisplay = true
    }


    @objc func previousPrompt(_ sender: Any?) { jumpToPrompt(-1) }
    @objc func nextPrompt(_ sender: Any?) { jumpToPrompt(1) }

    private func jumpToPrompt(_ direction: Int) {
        guard let t = terminal, !t.isAlternate else { return }
        let prompts = t.promptLines()
        let top = absoluteLine(0, t)
        let target = direction < 0 ? prompts.last(where: { $0 < top }) : prompts.first(where: { $0 > top })
        guard let line = target else {
            if direction > 0 { scrollToBottom() } else { NSSound.beep() }
            return
        }
        let sb = t.screen.scrollback.count
        scrollOffset = min(max(t.firstAbsoluteLine + sb - line, 0), sb)
        needsDisplay = true
    }

    @objc func copyLastOutput(_ sender: Any?) {
        guard let text = terminal?.lastCommandOutput(), !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }


    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let t = terminal, let text = NSPasteboard.general.string(forType: .string) else { return }
        scrollToBottom()
        session?.send(InputEncoder.paste(text, modes: t.modes))
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let t = terminal else { return }
        let firstLine = t.screen.scrolledOff - t.screen.scrollback.count
        selectionAnchor = GridPoint(line: firstLine, col: 0)
        selectionHead = GridPoint(line: t.screen.scrolledOff + t.rows - 1, col: t.columns - 1)
        selectionUnit = .character
        needsDisplay = true
    }

    @objc func clearScrollback(_ sender: Any?) {
        terminal?.clearScrollback()
        scrollOffset = 0
        clearSelection()
        needsDisplay = true
    }


    @objc func increaseFontSize(_ sender: Any?) { setZoom(min(zoom + 1, 24)) }
    @objc func decreaseFontSize(_ sender: Any?) { setZoom(max(zoom - 1, -6)) }
    @objc func resetFontSize(_ sender: Any?) { setZoom(0) }

    private func setZoom(_ z: CGFloat) {
        guard z != zoom else { return }
        let before = fontSize
        zoom = z
        setFontSize(fontSize, from: before)
    }

    private func setFontSize(_ size: CGFloat, from before: CGFloat) {
        guard size != before, let window, let t = terminal else { return }
        let cols = t.columns, rows = t.rows
        loadFonts()
        var frame = window.frame
        let content = contentSize(columns: cols, rows: rows)
        let old = window.contentRect(forFrameRect: frame)
        frame.size.width += content.width - old.width
        frame.size.height += content.height - old.height
        frame.origin.y -= content.height - old.height
        window.setFrame(frame, display: true)
        needsDisplay = true
    }


    private func cell(for event: NSEvent) -> (x: Int, y: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let t = terminal
        let x = Int((p.x - padding) / cellSize.width)
        let y = Int((p.y - padding) / cellSize.height)
        return (min(max(x, 0), (t?.columns ?? 1) - 1), min(max(y, 0), (t?.rows ?? 1) - 1))
    }

    private func mouseModifiers(_ e: NSEvent) -> KeyModifiers {
        var m: KeyModifiers = []
        if e.modifierFlags.contains(.shift) { m.insert(.shift) }
        if e.modifierFlags.contains(.option) { m.insert(.option) }
        if e.modifierFlags.contains(.control) { m.insert(.control) }
        return m
    }

    private func reportsMouse(_ e: NSEvent) -> Bool {
        guard let t = terminal else { return false }
        return t.modes.mouseTracking != .off && !e.modifierFlags.contains(.shift)
    }

    private func sendMouse(_ button: InputEncoder.MouseButton, _ action: InputEncoder.MouseAction, _ e: NSEvent) {
        guard let t = terminal else { return }
        let c = cell(for: e)
        session?.send(InputEncoder.mouse(button, action, x: c.x, y: c.y, modifiers: mouseModifiers(e), modes: t.modes))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let button = copyButtonRect, let b = hoverBlock, let t = terminal,
           button.contains(convert(event.locationInWindow, from: nil)) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(blockOutput(b, t), forType: .string)
            return
        }
        if event.modifierFlags.contains(.command), openLink(at: event) { return }
        if reportsMouse(event) {
            mouseReporting = true
            sendMouse(.left, .press, event)
            return
        }
        mouseReporting = false
        guard let t = terminal else { return }
        let c = cell(for: event)
        let point = GridPoint(line: absoluteLine(sourceRow(c.y), t), col: c.x)
        switch event.clickCount {
        case 2: selectionUnit = .word
        case 3...: selectionUnit = .line
        default: selectionUnit = .character
        }
        if event.clickCount == 1 && !event.modifierFlags.contains(.shift) {
            selectionAnchor = point
            selectionHead = nil
        } else if selectionAnchor == nil {
            selectionAnchor = point
        }
        if event.clickCount > 1 { selectionHead = point }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseReporting { sendMouse(.left, .drag, event); return }
        guard let t = terminal else { return }
        let p = convert(event.locationInWindow, from: nil)
        if p.y < padding, !t.isAlternate { scrollBy(lines: 1) }
        if p.y > bounds.height - padding, scrollOffset > 0 { scrollBy(lines: -1) }
        let c = cell(for: event)
        selectionHead = GridPoint(line: absoluteLine(sourceRow(c.y), t), col: c.x)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mouseReporting { sendMouse(.left, .release, event); mouseReporting = false; return }
        if selectionHead == nil || selectionHead == selectionAnchor, selectionUnit == .character {
            clearSelection()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event) { sendMouse(.right, .press, event) } else { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if reportsMouse(event) { sendMouse(.right, .release, event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if reportsMouse(event) { sendMouse(.middle, .press, event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if reportsMouse(event) { sendMouse(.middle, .release, event) }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverLink(event)
        if let t = terminal, Settings.shared.isModern {
            let p = convert(event.locationInWindow, from: nil)
            let block = visibleBlocks(t).first { blockRect($0, t).contains(p) }
            if block?.start != hoverBlock?.start {
                hoverBlock = block
                needsDisplay = true
            }
        }
        guard let t = terminal, t.modes.mouseTracking == .any else { return }
        sendMouse(.none, .move, event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let t = terminal else { return }
        if Settings.shared.isModern, event.hasPreciseScrollingDeltas, !reportsMouse(event), !t.isAlternate {
            let ch = cellSize.height
            let maxPixels = CGFloat(t.screen.scrollback.count) * ch
            let total = min(max(CGFloat(scrollOffset) * ch + scrollPixel + event.scrollingDeltaY, 0), maxPixels)
            scrollOffset = Int(total / ch)
            scrollPixel = total - CGFloat(scrollOffset) * ch
            needsDisplay = true
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellSize.height : event.scrollingDeltaY
        scrollRemainder += delta
        let lines = Int(scrollRemainder)
        guard lines != 0 else { return }
        scrollRemainder -= CGFloat(lines)

        if reportsMouse(event) {
            let button: InputEncoder.MouseButton = lines > 0 ? .wheelUp : .wheelDown
            for _ in 0..<min(abs(lines), 10) { sendMouse(button, .press, event) }
        } else if t.isAlternate {
            let key: Key = lines > 0 ? .up : .down
            for _ in 0..<min(abs(lines), 10) { session?.send(InputEncoder.encode(key, modifiers: [], modes: t.modes)) }
        } else {
            scrollBy(lines: lines)
        }
    }

    private func scrollBy(lines: Int) {
        guard let t = terminal else { return }
        let new = min(max(scrollOffset + lines, 0), t.screen.scrollback.count)
        scrollPixel = 0
        if new != scrollOffset {
            scrollOffset = new
            needsDisplay = true
        }
    }

    private struct LinkTarget {
        enum Kind { case url(URL), file(path: String, line: Int?, column: Int?) }
        let kind: Kind
        let line: Int
        let from: Int, to: Int
    }

    private func linkTarget(at event: NSEvent) -> LinkTarget? {
        guard let t = terminal else { return nil }
        let c = cell(for: event)
        let row = viewportRow(sourceRow(c.y), t)
        guard c.x < row.count else { return nil }
        let line = absoluteLine(sourceRow(c.y), t)
        if let uri = t.hyperlink(id: row.cells[c.x].attrs.link), let url = URL(string: uri) {
            var a = c.x, b = c.x
            let id = row.cells[c.x].attrs.link
            while a > 0, row.cells[a - 1].attrs.link == id { a -= 1 }
            while b < row.count - 1, row.cells[b + 1].attrs.link == id { b += 1 }
            return LinkTarget(kind: .url(url), line: line, from: a, to: b)
        }
        var cols: [String] = []
        for x in 0..<row.count { cols.append(row.cells[x].isWideTail ? "" : (row.cells[x].isEmpty ? " " : row.text(at: x))) }
        let stop: Set<String> = [" ", "\t", "\"", "'", "<", ">", "(", ")", "[", "]", "{", "}", "`", "│", ","]
        guard !stop.contains(cols[c.x]) else { return nil }
        var a = c.x, b = c.x
        while a > 0, !stop.contains(cols[a - 1]) { a -= 1 }
        while b < cols.count - 1, !stop.contains(cols[b + 1]) { b += 1 }
        var word = cols[a...b].joined()
        if word.hasPrefix("http://") || word.hasPrefix("https://") {
            while let last = word.last, ".:;!?".contains(last) { word.removeLast(); b -= 1 }
            return URL(string: word).map { LinkTarget(kind: .url($0), line: line, from: a, to: b) }
        }
        while let last = word.last, ".;!?:".contains(last) { word.removeLast(); b -= 1 }
        var lineNo: Int?, colNo: Int?
        let parts = word.split(separator: ":", omittingEmptySubsequences: false)
        var path = word
        if parts.count >= 2, let n = Int(parts[parts.count - 1]) {
            if parts.count >= 3, let l = Int(parts[parts.count - 2]) {
                lineNo = l; colNo = n
                path = parts.dropLast(2).joined(separator: ":")
            } else {
                lineNo = n
                path = parts.dropLast().joined(separator: ":")
            }
        }
        guard path.contains("/") || path.contains(".") else { return nil }
        let base = (window?.windowController as? TerminalWindowController)?.panes.first { $0.view === self }?.currentDirectory
            ?? session?.currentDirectory ?? SidebarModel.home
        var full = path
        if path.hasPrefix("~/") { full = SidebarModel.home + path.dropFirst(1) }
        else if !path.hasPrefix("/") { full = base + "/" + path }
        full = (full as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: full) else { return nil }
        return LinkTarget(kind: .file(path: full, line: lineNo, column: colNo), line: line, from: a, to: b)
    }

    private func openLink(at event: NSEvent) -> Bool {
        guard let target = linkTarget(at: event) else { return false }
        switch target.kind {
        case .url(let url): NSWorkspace.shared.open(url)
        case .file(let path, let line, let col): Editor.open(path, line: line, column: col)
        }
        return true
    }

    private var hoverLink: LinkTarget?

    private func updateHoverLink(_ event: NSEvent) {
        let target = event.modifierFlags.contains(.command) ? linkTarget(at: event) : nil
        let changed = target?.line != hoverLink?.line || target?.from != hoverLink?.from || target?.to != hoverLink?.to
        hoverLink = target
        if target != nil { NSCursor.pointingHand.set() } else if changed { NSCursor.iBeam.set() }
        if changed { needsDisplay = true }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if let w = window, let e = NSEvent.mouseEvent(with: .mouseMoved, location: w.mouseLocationOutsideOfEventStream,
                                                     modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                                     windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 0, pressure: 0) {
            updateHoverLink(e)
        }
    }


    private struct Block { let start: Int; let end: Int; let failed: Bool }
    private var hoverBlock: Block?
    private var copyButtonRect: NSRect?

    private func visibleBlocks(_ t: Terminal) -> [Block] {
        guard Settings.shared.isModern, !t.isAlternate else { return [] }
        let top = absoluteLine(-1, t), bottom = absoluteLine(t.rows - 1, t)
        var start = top
        var scanned = 0
        while start > t.firstAbsoluteLine, scanned < 3_000, !(row(atAbsolute: start, t)?.mark.contains(.prompt) ?? false) {
            start -= 1
            scanned += 1
        }
        var blocks: [Block] = []
        var current: (Int, RowMark)?
        var line = start
        while line <= bottom + 1 {
            let mark = row(atAbsolute: line, t)?.mark ?? []
            if mark.contains(.prompt) || line == bottom + 1 {
                if let (s, m) = current, m.contains(.finished) {
                    blocks.append(Block(start: s, end: line - 1, failed: m.contains(.failed)))
                }
                current = mark.contains(.prompt) ? (line, mark) : nil
            }
            line += 1
        }
        return blocks
    }

    private func blockRect(_ b: Block, _ t: Terminal) -> NSRect {
        let top = absoluteLine(0, t)
        let y0 = padding + CGFloat(b.start - top) * cellSize.height + 3
        let y1 = padding + CGFloat(b.end - top + 1) * cellSize.height - 3
        let inset = max(4, padding - 10)
        return NSRect(x: inset, y: y0, width: bounds.width - inset * 2, height: max(0, y1 - y0))
    }

    private func drawBlocks(_ t: Terminal, _ p: Palette, _ ctx: CGContext) {
        let blocks = visibleBlocks(t)
        for b in blocks {
            let r = blockRect(b, t)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setFillColor(cgColor(p.foreground, alpha: 0.045))
            ctx.fillPath()
            let accent = b.failed ? p.colors[1] : p.colors[2]
            ctx.addPath(CGPath(roundedRect: NSRect(x: r.minX + 1, y: r.minY + 6, width: 2.5, height: max(0, r.height - 12)),
                               cornerWidth: 1.25, cornerHeight: 1.25, transform: nil))
            ctx.setFillColor(cgColor(accent, alpha: 0.75))
            ctx.fillPath()
        }
        copyButtonRect = nil
        if let b = hoverBlock, blocks.contains(where: { $0.start == b.start }) {
            let r = blockRect(b, t)
            let button = NSRect(x: r.maxX - 66, y: r.minY + 4, width: 60, height: 20)
            copyButtonRect = button
            ctx.addPath(CGPath(roundedRect: button, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.setFillColor(cgColor(p.foreground, alpha: 0.12))
            ctx.fillPath()
            let label = NSAttributedString(string: "Copy", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                                         .foregroundColor: NSColor(cgColor: cgColor(p.foreground)) ?? .white])
            let size = label.size()
            label.draw(at: NSPoint(x: button.midX - size.width / 2, y: button.midY - size.height / 2))
        }
    }

    private func blockOutput(_ b: Block, _ t: Terminal) -> String {
        var out: [String] = []
        var current = ""
        var line = b.start
        while line <= b.end {
            if let r = row(atAbsolute: line, t) {
                current += r.plainText(trimTrailing: !r.wrapped)
                if !r.wrapped { out.append(current); current = "" }
            }
            line += 1
        }
        if !current.isEmpty { out.append(current) }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }


    private func clearSelection() {
        if selectionAnchor != nil || selectionHead != nil {
            selectionAnchor = nil
            selectionHead = nil
            needsDisplay = true
        }
    }

    private func isWordCharacter(_ s: String) -> Bool {
        guard let c = s.first else { return false }
        if c.isWhitespace { return false }
        return !"()[]{}<>'\"`|,;:".contains(c)
    }

    private func normalisedSelection() -> (GridPoint, GridPoint)? {
        guard let a = selectionAnchor, let h = selectionHead, let t = terminal else { return nil }
        var (start, end) = a <= h ? (a, h) : (h, a)
        switch selectionUnit {
        case .character: break
        case .line:
            start.col = 0
            end.col = t.columns - 1
        case .word:
            if let row = row(atAbsolute: start.line, t) {
                while start.col > 0, isWordCharacter(row.text(at: start.col - 1)) || row.cells[start.col - 1].isWideTail { start.col -= 1 }
            }
            if let row = row(atAbsolute: end.line, t) {
                while end.col < row.count - 1, isWordCharacter(row.text(at: end.col + 1)) || row.cells[end.col + 1].isWideTail { end.col += 1 }
            }
        }
        return (start, end)
    }

    private func selectedText() -> String? {
        guard let (start, end) = normalisedSelection(), let t = terminal else { return nil }
        var out = ""
        for line in start.line...end.line {
            guard let row = row(atAbsolute: line, t) else { continue }
            let from = line == start.line ? start.col : 0
            let to = line == end.line ? min(end.col, row.count - 1) : row.count - 1
            var piece = ""
            if from <= to {
                for x in from...to { piece += row.text(at: x).isEmpty && !row.cells[x].isWideTail ? " " : row.text(at: x) }
            }
            if line != end.line && row.wrapped {
                out += piece
            } else {
                while piece.hasSuffix(" ") { piece.removeLast() }
                out += piece
                if line != end.line { out += "\n" }
            }
        }
        return out
    }
}
