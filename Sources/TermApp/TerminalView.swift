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
    private(set) var cellSize = NSSize(width: 8, height: 16)
    let padding: CGFloat = 6


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
    override var isOpaque: Bool { true }

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
        cellSize = NSSize(width: advance.width, height: height)
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
        let frame = 1.0 / 120
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
        if scrollOffset > 0 {
            scrollOffset = min(scrollOffset + max(0, scrolled), t.screen.scrollback.count)
            needsDisplay = true
        } else {
            for y in dirty { setNeedsDisplay(rowRect(y)) }
        }
        let c = (t.cursor.x, t.cursor.y)
        if c != lastCursor {
            setNeedsDisplay(rowRect(lastCursor.y))
            setNeedsDisplay(rowRect(c.1))
            lastCursor = c
        }
        updateCursorDisplay()
    }

    private func updateCursorDisplay() {
        guard let t = terminal else { return }
        setNeedsDisplay(rowRect(t.cursor.y))
    }

    private func rowRect(_ y: Int) -> NSRect {
        NSRect(x: 0, y: padding + CGFloat(y) * cellSize.height - 1, width: bounds.width, height: cellSize.height + 2)
    }

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
        if scrollOffset == 0 { return t.screen.rows[vy] }
        let k = sb.count - scrollOffset + vy
        return k < sb.count ? sb[max(0, k)] : t.screen.rows[min(k - sb.count, t.rows - 1)]
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
        if scrollOffset != 0 { scrollOffset = 0; needsDisplay = true }
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
        ctx.setFillColor(cgColor(p.background))
        ctx.fill(dirtyRect)
        guard let t = terminal else { return }

        let first = max(0, Int((dirtyRect.minY - padding) / cellSize.height))
        let last = min(t.rows - 1, Int((dirtyRect.maxY - padding) / cellSize.height))
        guard first <= last else { return }
        let selection = normalisedSelection()
        for vy in first...last {
            drawRow(viewportRow(vy, t), vy: vy, line: absoluteLine(vy, t), selection: selection, t, p, ctx)
        }
        drawImages(t)
        drawCursor(t, p, ctx)
        if dimmed {
            ctx.setFillColor(cgColor(p.background, alpha: 0.38))
            ctx.fill(dirtyRect)
        }
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
                    if BoxDrawing.draw(cell.scalar, in: rect, color: cgColor(fg, alpha: a.flags.contains(.faint) ? 0.55 : 1),
                                       lineWidth: max(1, (fontSize / 13).rounded()), scale: scale, ctx) {
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
        if fakeBold && a.flags.contains(.bold) {
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -7.0
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
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
        guard t.modes.cursorVisible || !markedText.isEmpty, scrollOffset == 0 else { return }
        if !cursorOn && markedText.isEmpty { return }
        let x = t.cursor.x, y = t.cursor.y
        let row = t.screen.rows[y]
        let wide = x < row.count && row.cells[x].isWide
        let rect = CGRect(x: padding + CGFloat(x) * cellSize.width, y: padding + CGFloat(y) * cellSize.height,
                          width: cellSize.width * (wide ? 2 : 1), height: cellSize.height)
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
            ctx.fill(rect)
            if x < row.count, !row.cells[x].isEmpty {
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
        if event.modifierFlags.contains(.command), openLink(at: event) { return }
        if reportsMouse(event) {
            mouseReporting = true
            sendMouse(.left, .press, event)
            return
        }
        mouseReporting = false
        guard let t = terminal else { return }
        let c = cell(for: event)
        let point = GridPoint(line: absoluteLine(c.y, t), col: c.x)
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
        selectionHead = GridPoint(line: absoluteLine(c.y, t), col: c.x)
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
        guard let t = terminal, t.modes.mouseTracking == .any else { return }
        sendMouse(.none, .move, event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let t = terminal else { return }
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
        if new != scrollOffset {
            scrollOffset = new
            needsDisplay = true
        }
    }

    private func openLink(at event: NSEvent) -> Bool {
        guard let t = terminal else { return false }
        let c = cell(for: event)
        let row = viewportRow(c.y, t)
        guard c.x < row.count else { return false }
        if let uri = t.hyperlink(id: row.cells[c.x].attrs.link), let url = URL(string: uri) {
            NSWorkspace.shared.open(url)
            return true
        }
        let text = row.plainText(trimTrailing: false)
        let chars = Array(text)
        guard c.x < chars.count else { return false }
        var start = c.x, end = c.x
        let stop: Set<Character> = [" ", "\t", "\"", "'", "<", ">", "(", ")", "[", "]", "{", "}", "`"]
        while start > 0, !stop.contains(chars[start - 1]) { start -= 1 }
        while end < chars.count - 1, !stop.contains(chars[end + 1]) { end += 1 }
        let candidate = String(chars[start...end])
        if candidate.hasPrefix("http://") || candidate.hasPrefix("https://"), let url = URL(string: candidate) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
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
