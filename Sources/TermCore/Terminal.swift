public enum Charset: Sendable {
    case ascii
    case decSpecialGraphics
}

public enum MouseTracking: Sendable {
    case off
    case x10
    case normal
    case button
    case any
}

public enum MouseEncoding: Sendable {
    case legacy
    case utf8
    case sgr
    case urxvt
    case sgrPixels
}

public enum CursorShape: Sendable {
    case block, underline, bar
}

public struct TerminalModes: Sendable {
    public var insert = false
    public var newline = false
    public var applicationCursorKeys = false
    public var applicationKeypad = false
    public var reverseVideo = false
    public var originMode = false
    public var autowrap = true
    public var cursorBlink = false
    public var cursorVisible = true
    public var mouseTracking: MouseTracking = .off
    public var mouseEncoding: MouseEncoding = .legacy
    public var focusEvents = false
    public var alternateScroll = false
    public var bracketedPaste = false
    public var synchronizedOutput = false
    public var graphemeClustering = true
    public var inBandResize = false

    public init() {}
}

public protocol TerminalDelegate: AnyObject {
    func terminalBell(_ t: Terminal)
    func terminal(_ t: Terminal, titleChanged title: String)
    func terminal(_ t: Terminal, workingDirectoryChanged url: String)
    func terminal(_ t: Terminal, notify title: String, body: String)
    func terminal(_ t: Terminal, setClipboard data: [UInt8])
    func terminal(_ t: Terminal, semanticMark kind: Character, params: [String])
}

public extension TerminalDelegate {
    func terminalBell(_ t: Terminal) {}
    func terminal(_ t: Terminal, titleChanged title: String) {}
    func terminal(_ t: Terminal, workingDirectoryChanged url: String) {}
    func terminal(_ t: Terminal, notify title: String, body: String) {}
    func terminal(_ t: Terminal, setClipboard data: [UInt8]) {}
    func terminal(_ t: Terminal, semanticMark kind: Character, params: [String]) {}
}

public struct Cursor: Sendable {
    public var x = 0
    public var y = 0
    public var attrs = Attributes()
    public var pendingWrap = false
    var g0: Charset = .ascii
    var g1: Charset = .ascii
    var useG1 = false
    var originMode = false

    var charset: Charset { useG1 ? g1 : g0 }
}

public final class Terminal: ParserHandler {

    public internal(set) var columns: Int
    public internal(set) var rows: Int
    public let primary: Screen
    public let alternate: Screen
    public internal(set) var isAlternate = false
    public var screen: Screen { isAlternate ? alternate : primary }

    public internal(set) var cursor = Cursor()
    public internal(set) var modes = TerminalModes()
    public internal(set) var cursorShape: CursorShape = .block
    public internal(set) var title = ""
    public internal(set) var workingDirectory: String?
    public var palette = Palette()

    public internal(set) var scrollTop = 0
    public internal(set) var scrollBottom: Int

    public var kittyKeyboardFlags: Int { kittyStack.last ?? 0 }
    public var supportsKittyKeyboard = false

    public var softwareName = "terminal"
    public var softwareVersion = "0.1"

    public var onResponse: (([UInt8]) -> Void)?
    public weak var delegate: TerminalDelegate?

    public internal(set) var dirty: [Bool]
    public internal(set) var version: UInt64 = 0

    public var cellPixelWidth = 8
    public var cellPixelHeight = 16


    let parser = Parser()
    var savedPrimaryCursor = Cursor()
    var savedAlternateCursor = Cursor()
    var tabStops: [Bool]
    var lastPrinted: Unicode.Scalar?
    var titleStack: [String] = []
    var kittyStack: [Int] = []
    var hyperlinks: [UInt16: String] = [:]
    var hyperlinkIDs: [String: UInt16] = [:]
    var nextHyperlink: UInt16 = 1
    var dcsBuffer: [UInt8] = []
    var dcsKind: DCSKind = .ignore

    enum DCSKind { case ignore, requestStatus, getTermcap }

    public init(columns: Int = 80, rows: Int = 24, scrollback: Int = 10_000) {
        self.columns = max(2, columns)
        self.rows = max(1, rows)
        primary = Screen(columns: self.columns, rows: self.rows, scrollback: scrollback)
        alternate = Screen(columns: self.columns, rows: self.rows, scrollback: 0)
        scrollBottom = self.rows - 1
        tabStops = Terminal.defaultTabStops(self.columns)
        dirty = Array(repeating: true, count: self.rows)
    }

    static func defaultTabStops(_ n: Int) -> [Bool] {
        (0..<n).map { $0 % 8 == 0 && $0 != 0 }
    }


    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { parser.feed($0, to: self) }
    }

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        parser.feed(bytes, to: self)
    }

    public func feed(_ text: String) {
        feed(Array(text.utf8))
    }


    public func hyperlink(id: UInt16) -> String? { hyperlinks[id] }

    public func clearScrollback() {
        primary.scrollback.removeAll()
        touchAll()
    }

    public func takeDirtyRows() -> [Int] {
        var out: [Int] = []
        for y in 0..<dirty.count where dirty[y] { out.append(y); dirty[y] = false }
        return out
    }

    public func screenText() -> String {
        screen.rows.map { $0.plainText() }.joined(separator: "\n")
    }

    public func allText() -> String {
        var lines: [String] = []
        var current = ""
        let all = screen.scrollback.rows + screen.rows
        for row in all {
            current += row.plainText(trimTrailing: !row.wrapped)
            if !row.wrapped { lines.append(current); current = "" }
        }
        if !current.isEmpty { lines.append(current) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }


    @inline(__always) func touch(_ y: Int) {
        if y >= 0 && y < dirty.count { dirty[y] = true }
        version &+= 1
    }

    func touchAll() {
        for i in 0..<dirty.count { dirty[i] = true }
        version &+= 1
    }

    func respond(_ s: String) {
        onResponse?(Array(s.utf8))
    }


    public func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
        if cursor.charset != .ascii || modes.insert {
            for b in bytes { print(Unicode.Scalar(b)) }
            return
        }
        for b in bytes {
            if cursor.pendingWrap && modes.autowrap { wrapLine() }
            let x = cursor.x, y = cursor.y
            var row = screen.rows[y]
            if row.cells[x].isWide || row.cells[x].isWideTail { fixWideOverwrite(&row, at: x) }
            row.cells[x] = Cell(scalar: UInt32(b), attrs: cursor.attrs)
            if !row.clusters.isEmpty { row.clusters[x] = nil }
            screen.rows[y] = row
            touch(y)
            if x + 1 >= columns {
                cursor.pendingWrap = modes.autowrap
            } else {
                cursor.x = x + 1
            }
        }
        if let last = bytes.last { lastPrinted = Unicode.Scalar(last) }
    }

    public func print(_ scalar: Unicode.Scalar) {
        var s = scalar
        if cursor.charset == .decSpecialGraphics, let mapped = Terminal.decGraphics(s) { s = mapped }

        let w = CharWidth.of(s)
        if joinsPrevious(s, width: w) {
            joinPrevious(s)
            return
        }
        if w == 0 { return }

        if cursor.pendingWrap && modes.autowrap { wrapLine() }

        if w == 2 && cursor.x == columns - 1 {
            if modes.autowrap {
                var row = screen.rows[cursor.y]
                fixWideOverwrite(&row, at: cursor.x)
                row.cells[cursor.x] = Cell(attrs: cursor.attrs.erased)
                screen.rows[cursor.y] = row
                wrapLine()
            } else {
                return
            }
        }

        if modes.insert { insertBlankCells(w) }

        let x = cursor.x, y = cursor.y
        var row = screen.rows[y]
        fixWideOverwrite(&row, at: x)
        if w == 2 { fixWideOverwrite(&row, at: x + 1) }
        var attrs = cursor.attrs
        if w == 2 { attrs.flags.insert(.wide) }
        row.cells[x] = Cell(scalar: s.value, attrs: attrs)
        row.clusters[x] = nil
        if w == 2 {
            var tail = cursor.attrs
            tail.flags.insert(.wideTail)
            row.cells[x + 1] = Cell(scalar: 0, attrs: tail)
            row.clusters[x + 1] = nil
        }
        screen.rows[y] = row
        touch(y)
        lastPrinted = s

        let next = x + w
        if next >= columns {
            cursor.x = columns - 1
            cursor.pendingWrap = modes.autowrap
        } else {
            cursor.x = next
        }
    }

    private func previousCellPosition() -> (x: Int, y: Int)? {
        let y = cursor.y
        var x: Int
        if cursor.pendingWrap {
            x = cursor.x
        } else {
            guard cursor.x > 0 else { return nil }
            x = cursor.x - 1
        }
        let row = screen.rows[y]
        if row.cells[x].isWideTail && x > 0 { x -= 1 }
        return row.cells[x].isEmpty ? nil : (x, y)
    }

    private func joinsPrevious(_ s: Unicode.Scalar, width w: Int) -> Bool {
        guard modes.graphemeClustering else { return w == 0 && previousCellPosition() != nil }
        if w == 0 { return previousCellPosition() != nil }
        let regional = CharWidth.isRegionalIndicator(s)
        let modifier = CharWidth.isEmojiModifier(s)
        guard let (px, py) = previousCellPosition() else { return false }
        let row = screen.rows[py]
        let text = row.text(at: px)
        if text.unicodeScalars.last?.value == 0x200D {
            return s.value >= 0x80 && s.properties.isEmoji
        }
        if modifier && row.cells[px].isWide { return true }
        if regional {
            let scalars = text.unicodeScalars
            return scalars.count == 1 && CharWidth.isRegionalIndicator(scalars.first!)
        }
        return false
    }

    private func joinPrevious(_ s: Unicode.Scalar) {
        guard let (px, py) = previousCellPosition() else { return }
        var row = screen.rows[py]
        let combined = row.text(at: px) + String(Character(s))
        row.clusters[px] = combined
        row.cells[px].attrs.flags.insert(.cluster)
        let newWidth = CharWidth.ofCluster(combined.unicodeScalars)
        let wasWide = row.cells[px].isWide

        if newWidth == 2 && !wasWide && px + 1 < columns && !cursor.pendingWrap && cursor.x == px + 1 {
            fixWideOverwrite(&row, at: px + 1)
            row.cells[px].attrs.flags.insert(.wide)
            var tail = row.cells[px].attrs
            tail.flags.remove(.wide)
            tail.flags.remove(.cluster)
            tail.flags.insert(.wideTail)
            row.cells[px + 1] = Cell(scalar: 0, attrs: tail)
            screen.rows[py] = row
            touch(py)
            if px + 2 >= columns {
                cursor.x = columns - 1
                cursor.pendingWrap = modes.autowrap
            } else {
                cursor.x = px + 2
            }
            return
        }
        if newWidth == 1 && wasWide {
            row.cells[px].attrs.flags.remove(.wide)
            if px + 1 < columns { row.cells[px + 1] = Cell(attrs: row.cells[px].attrs.erased) }
            if !cursor.pendingWrap && cursor.x == px + 2 { cursor.x = px + 1 }
            if cursor.pendingWrap && px + 1 == columns - 1 { cursor.pendingWrap = false; cursor.x = px + 1 }
        }
        screen.rows[py] = row
        touch(py)
    }

    func fixWideOverwrite(_ row: inout Row, at x: Int) {
        guard x >= 0 && x < row.count else { return }
        let c = row.cells[x]
        if c.isWideTail && x > 0 {
            row.cells[x - 1] = Cell(attrs: row.cells[x - 1].attrs.erased)
            row.clusters[x - 1] = nil
        } else if c.isWide && x + 1 < row.count {
            row.cells[x + 1] = Cell(attrs: row.cells[x + 1].attrs.erased)
        }
    }

    func wrapLine() {
        screen.rows[cursor.y].wrapped = true
        cursor.x = 0
        cursor.pendingWrap = false
        index()
    }


    public func execute(_ b: UInt8) {
        switch b {
        case 0x07: delegate?.terminalBell(self)
        case 0x08: backspace()
        case 0x09: tab(forward: 1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if modes.newline { carriageReturn() }
        case 0x0D: carriageReturn()
        case 0x0E: cursor.useG1 = true
        case 0x0F: cursor.useG1 = false
        default: break
        }
    }

    func backspace() {
        if cursor.pendingWrap { cursor.pendingWrap = false; return }
        if cursor.x > 0 { cursor.x -= 1 }
    }

    func carriageReturn() {
        cursor.x = 0
        cursor.pendingWrap = false
    }

    func index() {
        cursor.pendingWrap = false
        if cursor.y == scrollBottom {
            scrollUp(1)
        } else if cursor.y < rows - 1 {
            cursor.y += 1
        }
    }

    func reverseIndex() {
        cursor.pendingWrap = false
        if cursor.y == scrollTop {
            scrollDown(1)
        } else if cursor.y > 0 {
            cursor.y -= 1
        }
    }

    func scrollUp(_ n: Int) {
        let toScrollback = !isAlternate && scrollTop == 0
        screen.scrollUp(top: scrollTop, bottom: scrollBottom, count: n,
                        fill: Cell(attrs: cursor.attrs.erased), toScrollback: toScrollback)
        touchAll()
    }

    func scrollDown(_ n: Int) {
        screen.scrollDown(top: scrollTop, bottom: scrollBottom, count: n, fill: Cell(attrs: cursor.attrs.erased))
        touchAll()
    }

    func tab(forward n: Int) {
        guard n > 0 else { return }
        var left = n
        var x = cursor.x
        while left > 0 && x < columns - 1 {
            x += 1
            if tabStops[x] { left -= 1 }
        }
        cursor.x = x
        cursor.pendingWrap = false
    }

    func tab(backward n: Int) {
        var left = n
        var x = cursor.x
        while left > 0 && x > 0 {
            x -= 1
            if tabStops[x] { left -= 1 }
        }
        cursor.x = x
        cursor.pendingWrap = false
    }


    public func escDispatch(_ i: Intermediates, final: UInt8) {
        switch (i.first, final) {
        case (0, UInt8(ascii: "7")): saveCursor()
        case (0, UInt8(ascii: "8")): restoreCursor()
        case (0, UInt8(ascii: "D")): index()
        case (0, UInt8(ascii: "E")): index(); carriageReturn()
        case (0, UInt8(ascii: "M")): reverseIndex()
        case (0, UInt8(ascii: "H")): tabStops[cursor.x] = true
        case (0, UInt8(ascii: "c")): fullReset()
        case (0, UInt8(ascii: "=")): modes.applicationKeypad = true
        case (0, UInt8(ascii: ">")): modes.applicationKeypad = false
        case (UInt8(ascii: "#"), UInt8(ascii: "8")): screenAlignment()
        case (UInt8(ascii: "("), _): cursor.g0 = Terminal.charset(final)
        case (UInt8(ascii: ")"), _): cursor.g1 = Terminal.charset(final)
        default: break
        }
    }

    static func charset(_ final: UInt8) -> Charset {
        final == UInt8(ascii: "0") ? .decSpecialGraphics : .ascii
    }

    func saveCursor() {
        var c = cursor
        c.originMode = modes.originMode
        if isAlternate { savedAlternateCursor = c } else { savedPrimaryCursor = c }
    }

    func restoreCursor() {
        let c = isAlternate ? savedAlternateCursor : savedPrimaryCursor
        cursor = c
        cursor.x = min(c.x, columns - 1)
        cursor.y = min(c.y, rows - 1)
        modes.originMode = c.originMode
    }

    func screenAlignment() {
        for y in 0..<rows {
            screen.rows[y] = Row(columns: columns, fill: Cell(scalar: UInt32(UInt8(ascii: "E"))))
        }
        scrollTop = 0
        scrollBottom = rows - 1
        cursor.x = 0
        cursor.y = 0
        cursor.pendingWrap = false
        touchAll()
    }

    public func fullReset() {
        if isAlternate { isAlternate = false }
        primary.clearAll()
        primary.scrollback.removeAll()
        alternate.clearAll()
        cursor = Cursor()
        savedPrimaryCursor = Cursor()
        savedAlternateCursor = Cursor()
        modes = TerminalModes()
        cursorShape = .block
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Terminal.defaultTabStops(columns)
        titleStack = []
        kittyStack = []
        lastPrinted = nil
        parser.reset()
        touchAll()
    }


    static func decGraphics(_ s: Unicode.Scalar) -> Unicode.Scalar? {
        switch s.value {
        case 0x5F: return " "
        case 0x60: return "\u{25C6}"
        case 0x61: return "\u{2592}"
        case 0x62: return "\u{2409}"
        case 0x63: return "\u{240C}"
        case 0x64: return "\u{240D}"
        case 0x65: return "\u{240A}"
        case 0x66: return "\u{00B0}"
        case 0x67: return "\u{00B1}"
        case 0x68: return "\u{2424}"
        case 0x69: return "\u{240B}"
        case 0x6A: return "\u{2518}"
        case 0x6B: return "\u{2510}"
        case 0x6C: return "\u{250C}"
        case 0x6D: return "\u{2514}"
        case 0x6E: return "\u{253C}"
        case 0x6F: return "\u{23BA}"
        case 0x70: return "\u{23BB}"
        case 0x71: return "\u{2500}"
        case 0x72: return "\u{23BC}"
        case 0x73: return "\u{23BD}"
        case 0x74: return "\u{251C}"
        case 0x75: return "\u{2524}"
        case 0x76: return "\u{2534}"
        case 0x77: return "\u{252C}"
        case 0x78: return "\u{2502}"
        case 0x79: return "\u{2264}"
        case 0x7A: return "\u{2265}"
        case 0x7B: return "\u{03C0}"
        case 0x7C: return "\u{2260}"
        case 0x7D: return "\u{00A3}"
        case 0x7E: return "\u{00B7}"
        default: return nil
        }
    }
}
