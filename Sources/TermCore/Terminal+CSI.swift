extension Terminal {
    public func csiDispatch(_ p: CSIParams, _ i: Intermediates, final: UInt8) {
        let f = final
        switch (i.prefix, i.first) {
        case (0, 0): csiPlain(p, f)
        case (UInt8(ascii: "?"), 0): csiPrivate(p, f)
        case (UInt8(ascii: ">"), 0): csiGreater(p, f)
        case (UInt8(ascii: "<"), 0): if f == UInt8(ascii: "u") { kittyPop(p.get(0, 1)) }
        case (UInt8(ascii: "="), 0): if f == UInt8(ascii: "u") { kittySet(p.raw(0, 0), mode: p.get(1, 1)) }
        case (0, UInt8(ascii: " ")): if f == UInt8(ascii: "q") { setCursorStyle(p.raw(0, 0)) }
        case (0, UInt8(ascii: "!")): if f == UInt8(ascii: "p") { softReset() }
        case (0, UInt8(ascii: "$")): if f == UInt8(ascii: "p") { reportMode(p.raw(0, 0), isPrivate: false) }
        case (UInt8(ascii: "?"), UInt8(ascii: "$")): if f == UInt8(ascii: "p") { reportMode(p.raw(0, 0), isPrivate: true) }
        default: break
        }
    }

    private func csiPlain(_ p: CSIParams, _ f: UInt8) {
        switch f {
        case UInt8(ascii: "@"): insertBlankCells(p.get(0, 1))
        case UInt8(ascii: "A"): moveCursor(dy: -p.get(0, 1))
        case UInt8(ascii: "B"), UInt8(ascii: "e"): moveCursor(dy: p.get(0, 1))
        case UInt8(ascii: "C"), UInt8(ascii: "a"): moveCursor(dx: p.get(0, 1))
        case UInt8(ascii: "D"): moveCursor(dx: -p.get(0, 1))
        case UInt8(ascii: "E"): moveCursor(dy: p.get(0, 1)); carriageReturn()
        case UInt8(ascii: "F"): moveCursor(dy: -p.get(0, 1)); carriageReturn()
        case UInt8(ascii: "G"), UInt8(ascii: "`"): setCursorColumn(p.get(0, 1) - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"): setCursorPosition(row: p.get(0, 1) - 1, column: p.get(1, 1) - 1)
        case UInt8(ascii: "I"): tab(forward: p.get(0, 1))
        case UInt8(ascii: "J"): eraseInDisplay(p.raw(0, 0))
        case UInt8(ascii: "K"): eraseInLine(p.raw(0, 0))
        case UInt8(ascii: "L"): insertLines(p.get(0, 1))
        case UInt8(ascii: "M"): deleteLines(p.get(0, 1))
        case UInt8(ascii: "P"): deleteCells(p.get(0, 1))
        case UInt8(ascii: "S"): scrollUp(p.get(0, 1))
        case UInt8(ascii: "T"): if p.count <= 1 { scrollDown(p.get(0, 1)) }
        case UInt8(ascii: "X"): eraseCells(p.get(0, 1))
        case UInt8(ascii: "Z"): tab(backward: p.get(0, 1))
        case UInt8(ascii: "b"): repeatLast(p.get(0, 1))
        case UInt8(ascii: "c"): if p.raw(0, 0) == 0 { respond("\u{1B}[?62;22c") }
        case UInt8(ascii: "d"): setCursorRow(p.get(0, 1) - 1)
        case UInt8(ascii: "g"): clearTabStops(p.raw(0, 0))
        case UInt8(ascii: "h"): setANSIModes(p, on: true)
        case UInt8(ascii: "l"): setANSIModes(p, on: false)
        case UInt8(ascii: "m"): selectGraphicRendition(p)
        case UInt8(ascii: "n"): deviceStatus(p.raw(0, 0), isPrivate: false)
        case UInt8(ascii: "r"): setScrollRegion(top: p.get(0, 1) - 1, bottom: p.get(1, rows) - 1)
        case UInt8(ascii: "s"): saveCursor()
        case UInt8(ascii: "t"): windowOperation(p)
        case UInt8(ascii: "u"): restoreCursor()
        default: break
        }
    }

    private func csiPrivate(_ p: CSIParams, _ f: UInt8) {
        switch f {
        case UInt8(ascii: "h"): setDECModes(p, on: true)
        case UInt8(ascii: "l"): setDECModes(p, on: false)
        case UInt8(ascii: "J"): eraseInDisplay(p.raw(0, 0))
        case UInt8(ascii: "K"): eraseInLine(p.raw(0, 0))
        case UInt8(ascii: "n"): deviceStatus(p.raw(0, 0), isPrivate: true)
        case UInt8(ascii: "u"): if supportsKittyKeyboard { respond("\u{1B}[?\(kittyKeyboardFlags)u") }
        default: break
        }
    }

    private func csiGreater(_ p: CSIParams, _ f: UInt8) {
        switch f {
        case UInt8(ascii: "c"): if p.raw(0, 0) == 0 { respond("\u{1B}[>1;10;0c") }
        case UInt8(ascii: "q"): if p.raw(0, 0) == 0 { respond("\u{1B}P>|\(softwareName) \(softwareVersion)\u{1B}\\") }
        case UInt8(ascii: "u"): if supportsKittyKeyboard { kittyPush(p.raw(0, 0)) }
        default: break
        }
    }


    var regionTop: Int { modes.originMode ? scrollTop : 0 }
    var regionBottom: Int { modes.originMode ? scrollBottom : rows - 1 }

    func moveCursor(dx: Int = 0, dy: Int = 0) {
        cursor.pendingWrap = false
        if dx != 0 { cursor.x = min(max(cursor.x + dx, 0), columns - 1) }
        if dy != 0 {
            let top = cursor.y >= scrollTop ? scrollTop : 0
            let bottom = cursor.y <= scrollBottom ? scrollBottom : rows - 1
            cursor.y = min(max(cursor.y + dy, top), bottom)
        }
    }

    func setCursorPosition(row: Int, column: Int) {
        cursor.pendingWrap = false
        let top = regionTop, bottom = regionBottom
        cursor.y = min(max(row + top, top), bottom)
        cursor.x = min(max(column, 0), columns - 1)
    }

    func setCursorColumn(_ x: Int) {
        cursor.pendingWrap = false
        cursor.x = min(max(x, 0), columns - 1)
    }

    func setCursorRow(_ y: Int) {
        cursor.pendingWrap = false
        let top = regionTop, bottom = regionBottom
        cursor.y = min(max(y + top, top), bottom)
    }


    var eraseFill: Cell { Cell(attrs: cursor.attrs.erased) }

    func clearCells(row y: Int, _ range: Range<Int>) {
        let lo = max(range.lowerBound, 0), hi = min(range.upperBound, columns)
        guard lo < hi else { return }
        let scr = screen
        if scr.rows[y].cells[lo].isWideTail { fixWideOverwrite(&scr.rows[y], at: lo) }
        if hi < columns && scr.rows[y].cells[hi].isWideTail { fixWideOverwrite(&scr.rows[y], at: hi) }
        scr.rows[y].clear(lo..<hi, with: eraseFill)
        touch(y)
    }

    func clearRow(_ y: Int) {
        screen.rows[y] = screen.blankRow(eraseFill)
        touch(y)
    }

    func eraseInDisplay(_ mode: Int) {
        cursor.pendingWrap = false
        switch mode {
        case 0:
            clearCells(row: cursor.y, cursor.x..<columns)
            screen.rows[cursor.y].wrapped = false
            for y in (cursor.y + 1)..<max(rows, cursor.y + 1) { clearRow(y) }
        case 1:
            for y in 0..<cursor.y { clearRow(y) }
            clearCells(row: cursor.y, 0..<(cursor.x + 1))
        case 2:
            for y in 0..<rows { clearRow(y) }
            pruneImages(clearingVisible: true)
        case 3:
            screen.scrollback.removeAll()
            pruneImages()
            touchAll()
        default: break
        }
    }

    func eraseInLine(_ mode: Int) {
        cursor.pendingWrap = false
        switch mode {
        case 0:
            clearCells(row: cursor.y, cursor.x..<columns)
            screen.rows[cursor.y].wrapped = false
        case 1: clearCells(row: cursor.y, 0..<(cursor.x + 1))
        case 2:
            clearRow(cursor.y)
        default: break
        }
    }

    func eraseCells(_ n: Int) {
        cursor.pendingWrap = false
        clearCells(row: cursor.y, cursor.x..<min(cursor.x + n, columns))
    }


    func insertBlankCells(_ n: Int) {
        let x = cursor.x, y = cursor.y
        let n = min(n, columns - x)
        guard n > 0 else { return }
        var row = screen.rows[y]
        fixWideOverwrite(&row, at: x)
        let cut = columns - n
        if cut > 0 && cut < columns && row.cells[cut].isWideTail { row.cells[cut - 1] = eraseFill }
        row.cells.removeLast(n)
        row.cells.insert(contentsOf: repeatElement(eraseFill, count: n), at: x)
        if !row.clusters.isEmpty {
            var moved: [Int: String] = [:]
            for (k, v) in row.clusters where k < x { moved[k] = v }
            for (k, v) in row.clusters where k >= x && k + n < columns { moved[k + n] = v }
            row.clusters = moved
        }
        row.wrapped = false
        screen.rows[y] = row
        cursor.pendingWrap = false
        touch(y)
    }

    func deleteCells(_ n: Int) {
        let x = cursor.x, y = cursor.y
        let n = min(n, columns - x)
        guard n > 0 else { return }
        var row = screen.rows[y]
        fixWideOverwrite(&row, at: x)
        if x + n < columns && row.cells[x + n].isWideTail { fixWideOverwrite(&row, at: x + n) }
        row.cells.removeSubrange(x..<(x + n))
        row.cells.append(contentsOf: repeatElement(eraseFill, count: n))
        if !row.clusters.isEmpty {
            var moved: [Int: String] = [:]
            for (k, v) in row.clusters where k < x { moved[k] = v }
            for (k, v) in row.clusters where k >= x + n { moved[k - n] = v }
            row.clusters = moved
        }
        row.wrapped = false
        screen.rows[y] = row
        cursor.pendingWrap = false
        touch(y)
    }

    func insertLines(_ n: Int) {
        guard cursor.y >= scrollTop && cursor.y <= scrollBottom else { return }
        screen.scrollDown(top: cursor.y, bottom: scrollBottom, count: n, fill: eraseFill)
        carriageReturn()
        touchAll()
    }

    func deleteLines(_ n: Int) {
        guard cursor.y >= scrollTop && cursor.y <= scrollBottom else { return }
        screen.scrollUp(top: cursor.y, bottom: scrollBottom, count: n, fill: eraseFill, toScrollback: false)
        carriageReturn()
        touchAll()
    }

    func repeatLast(_ n: Int) {
        guard let s = lastPrinted else { return }
        for _ in 0..<min(n, 65_535) { print(s) }
    }


    func clearTabStops(_ mode: Int) {
        switch mode {
        case 0: tabStops[cursor.x] = false
        case 3: tabStops = Array(repeating: false, count: columns)
        default: break
        }
    }

    func setScrollRegion(top: Int, bottom: Int) {
        let t = max(0, top), b = min(rows - 1, bottom)
        guard t < b else { return }
        scrollTop = t
        scrollBottom = b
        setCursorPosition(row: 0, column: 0)
    }


    func setANSIModes(_ p: CSIParams, on: Bool) {
        for k in 0..<p.count {
            switch p.raw(k, 0) {
            case 4: modes.insert = on
            case 20: modes.newline = on
            default: break
            }
        }
    }

    func setDECModes(_ p: CSIParams, on: Bool) {
        for k in 0..<p.count { setDECMode(p.raw(k, 0), on: on) }
    }

    func setDECMode(_ mode: Int, on: Bool) {
        switch mode {
        case 1: modes.applicationCursorKeys = on
        case 5: modes.reverseVideo = on; touchAll()
        case 6: modes.originMode = on; setCursorPosition(row: 0, column: 0)
        case 7: modes.autowrap = on
        case 9: modes.mouseTracking = on ? .x10 : .off
        case 12: modes.cursorBlink = on
        case 25: modes.cursorVisible = on; version &+= 1
        case 47: switchScreen(toAlternate: on, clear: false)
        case 1047:
            if on { switchScreen(toAlternate: true, clear: false) }
            else { if isAlternate { alternate.clearAll() }; switchScreen(toAlternate: false, clear: false) }
        case 1049:
            if on {
                if !isAlternate { saveCursor() }
                switchScreen(toAlternate: true, clear: true)
            } else if isAlternate {
                switchScreen(toAlternate: false, clear: false)
                restoreCursor()
            }
        case 1048: if on { saveCursor() } else { restoreCursor() }
        case 1000: modes.mouseTracking = on ? .normal : .off
        case 1002: modes.mouseTracking = on ? .button : .off
        case 1003: modes.mouseTracking = on ? .any : .off
        case 1004: modes.focusEvents = on
        case 1005: modes.mouseEncoding = on ? .utf8 : .legacy
        case 1006: modes.mouseEncoding = on ? .sgr : .legacy
        case 1015: modes.mouseEncoding = on ? .urxvt : .legacy
        case 1016: modes.mouseEncoding = on ? .sgrPixels : .legacy
        case 1007: modes.alternateScroll = on
        case 2004: modes.bracketedPaste = on
        case 2026: modes.synchronizedOutput = on; version &+= 1
        case 2031:
            modes.colorSchemeReports = on
            if on { reportColorScheme() }
        case 2048:
            modes.inBandResize = on
            if on { reportSize() }
        default: break
        }
    }

    func switchScreen(toAlternate alt: Bool, clear: Bool) {
        guard alt != isAlternate else {
            if alt && clear { alternate.clearAll(fill: eraseFill); touchAll() }
            return
        }
        if !alt {
            kittyStackAlternate = []
            imagePlacements.removeAll { $0.onAlternate }
        }
        isAlternate = alt
        if alt && clear { alternate.clearAll(fill: eraseFill) }
        touchAll()
    }

    func reportMode(_ mode: Int, isPrivate: Bool) {
        let state: Int
        if isPrivate {
            func b(_ v: Bool) -> Int { v ? 1 : 2 }
            switch mode {
            case 1: state = b(modes.applicationCursorKeys)
            case 5: state = b(modes.reverseVideo)
            case 6: state = b(modes.originMode)
            case 7: state = b(modes.autowrap)
            case 9: state = b(modes.mouseTracking == .x10)
            case 12: state = b(modes.cursorBlink)
            case 25: state = b(modes.cursorVisible)
            case 47, 1047, 1049: state = b(isAlternate)
            case 1000: state = b(modes.mouseTracking == .normal)
            case 1002: state = b(modes.mouseTracking == .button)
            case 1003: state = b(modes.mouseTracking == .any)
            case 1004: state = b(modes.focusEvents)
            case 1005: state = b(modes.mouseEncoding == .utf8)
            case 1006: state = b(modes.mouseEncoding == .sgr)
            case 1007: state = b(modes.alternateScroll)
            case 1015: state = b(modes.mouseEncoding == .urxvt)
            case 1016: state = b(modes.mouseEncoding == .sgrPixels)
            case 2004: state = b(modes.bracketedPaste)
            case 2026: state = b(modes.synchronizedOutput)
            case 2027: state = 3
            case 2031: state = b(modes.colorSchemeReports)
            case 2048: state = b(modes.inBandResize)
            default: state = 0
            }
            respond("\u{1B}[?\(mode);\(state)$y")
        } else {
            switch mode {
            case 4: state = modes.insert ? 1 : 2
            case 20: state = modes.newline ? 1 : 2
            default: state = 0
            }
            respond("\u{1B}[\(mode);\(state)$y")
        }
    }


    func deviceStatus(_ code: Int, isPrivate: Bool) {
        switch code {
        case 5: respond("\u{1B}[0n")
        case 996 where isPrivate:
            reportColorScheme()
        case 6:
            let row = cursor.y - (modes.originMode ? scrollTop : 0) + 1
            let col = cursor.x + 1
            respond(isPrivate ? "\u{1B}[?\(row);\(col)R" : "\u{1B}[\(row);\(col)R")
        default: break
        }
    }

    func windowOperation(_ p: CSIParams) {
        switch p.raw(0, 0) {
        case 14: respond("\u{1B}[4;\(rows * cellPixelHeight);\(columns * cellPixelWidth)t")
        case 16: respond("\u{1B}[6;\(cellPixelHeight);\(cellPixelWidth)t")
        case 18: respond("\u{1B}[8;\(rows);\(columns)t")
        case 22: titleStack.append(title); if titleStack.count > 32 { titleStack.removeFirst() }
        case 23:
            if let t = titleStack.popLast() {
                title = t
                delegate?.terminal(self, titleChanged: t)
            }
        default: break
        }
    }

    func reportSize() {
        respond("\u{1B}[48;\(rows);\(columns);\(rows * cellPixelHeight);\(columns * cellPixelWidth)t")
    }


    func setCursorStyle(_ n: Int) {
        switch n {
        case 0: cursorShape = defaultCursorShape; modes.cursorBlink = defaultCursorBlink
        case 1: cursorShape = .block; modes.cursorBlink = true
        case 2: cursorShape = .block; modes.cursorBlink = false
        case 3: cursorShape = .underline; modes.cursorBlink = true
        case 4: cursorShape = .underline; modes.cursorBlink = false
        case 5: cursorShape = .bar; modes.cursorBlink = true
        case 6: cursorShape = .bar; modes.cursorBlink = false
        default: break
        }
        version &+= 1
    }

    func softReset() {
        modes.insert = false
        modes.originMode = false
        modes.autowrap = true
        modes.cursorVisible = true
        modes.applicationCursorKeys = false
        modes.applicationKeypad = false
        scrollTop = 0
        scrollBottom = rows - 1
        cursor.attrs = Attributes()
        cursor.g0 = .ascii
        cursor.g1 = .ascii
        cursor.useG1 = false
        cursor.pendingWrap = false
        savedPrimaryCursor = Cursor()
        savedAlternateCursor = Cursor()
    }

    func kittyPush(_ flags: Int) {
        kittyStack.append(max(0, flags) & 0x1F)
        if kittyStack.count > 16 { kittyStack.removeFirst() }
    }

    func kittyPop(_ n: Int) {
        kittyStack.removeLast(min(n, kittyStack.count))
    }

    func kittySet(_ flags: Int, mode: Int) {
        guard supportsKittyKeyboard else { return }
        let current = kittyKeyboardFlags
        let f = max(0, flags) & 0x1F
        let new: Int
        switch mode {
        case 2: new = current | f
        case 3: new = current & ~f
        default: new = f
        }
        if kittyStack.isEmpty { kittyStack.append(new) } else { kittyStack[kittyStack.count - 1] = new }
    }
}
