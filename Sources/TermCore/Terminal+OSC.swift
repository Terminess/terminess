import Foundation

extension Terminal {

    public func oscDispatch(_ data: [UInt8]) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = Int(parts[0]) else { return }
        let rest = parts.count > 1 ? String(parts[1]) : ""

        switch code {
        case 0, 2:
            title = rest
            delegate?.terminal(self, titleChanged: rest)
            version &+= 1
        case 4: paletteOSC(rest)
        case 7:
            workingDirectory = rest
            delegate?.terminal(self, workingDirectoryChanged: rest)
        case 8: hyperlinkOSC(rest)
        case 9:
            if !rest.hasPrefix("4;") { delegate?.terminal(self, notify: "", body: rest) }
        case 10, 11, 12: dynamicColorOSC(start: code, rest)
        case 52: clipboardOSC(rest)
        case 104: resetPalette(rest)
        case 110: palette.foreground = Palette().foreground; touchAll()
        case 111: palette.background = Palette().background; touchAll()
        case 112: palette.cursor = Palette().cursor; version &+= 1
        case 133:
            let fields = rest.split(separator: ";").map(String.init)
            if let kind = fields.first?.first {
                switch kind {
                case "A": screen.rows[cursor.y].mark.insert(.prompt)
                case "C": screen.rows[cursor.y].mark.insert(.output)
                case "D": markFinished(status: fields.count > 1 ? Int(fields[1]) ?? 0 : 0)
                default: break
                }
                delegate?.terminal(self, semanticMark: kind, params: Array(fields.dropFirst()))
            }
        case 1337: inlineImage(rest)
        case 777:
            let fields = rest.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if fields.first == "notify" {
                delegate?.terminal(self, notify: fields.count > 1 ? fields[1] : "", body: fields.count > 2 ? fields[2] : "")
            }
        default: break
        }
    }

    private func markFinished(status: Int) {
        let flags: RowMark = status == 0 ? [.finished] : [.finished, .failed]
        var y = cursor.y
        while y >= 0 {
            if screen.rows[y].mark.contains(.prompt) {
                if y < cursor.y || !screen.rows[y].mark.contains(.finished) {
                    screen.rows[y].mark.formUnion(flags)
                    touch(y)
                    return
                }
            }
            y -= 1
        }
        var i = screen.scrollback.count - 1
        while i >= 0 && i >= screen.scrollback.count - 500 {
            if screen.scrollback[i].mark.contains(.prompt) {
                screen.scrollback[i].mark.formUnion(flags)
                return
            }
            i -= 1
        }
    }

    private func paletteOSC(_ rest: String) {
        let fields = rest.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var k = 0
        while k + 1 < fields.count {
            if let idx = Int(fields[k]), idx >= 0, idx < 256 {
                let spec = fields[k + 1]
                if spec == "?" {
                    respond("\u{1B}]4;\(idx);\(palette.colors[idx].xtermSpec)\u{1B}\\")
                } else if let c = RGB(spec: spec) {
                    palette.colors[idx] = c
                    touchAll()
                }
            }
            k += 2
        }
    }

    private func resetPalette(_ rest: String) {
        let defaults = Palette.xterm256
        if rest.isEmpty {
            palette.colors = defaults
        } else {
            for f in rest.split(separator: ";") {
                if let i = Int(f), i >= 0, i < 256 { palette.colors[i] = defaults[i] }
            }
        }
        touchAll()
    }

    private func dynamicColorOSC(start: Int, _ rest: String) {
        var code = start
        for spec in rest.split(separator: ";", omittingEmptySubsequences: false).map(String.init) {
            guard code <= 12 else { break }
            if spec == "?" {
                let c: RGB
                switch code {
                case 10: c = palette.foreground
                case 11: c = palette.background
                default: c = palette.cursor
                }
                respond("\u{1B}]\(code);\(c.xtermSpec)\u{1B}\\")
            } else if let c = RGB(spec: spec) {
                switch code {
                case 10: palette.foreground = c
                case 11: palette.background = c
                default: palette.cursor = c
                }
                touchAll()
            }
            code += 1
        }
    }

    private func hyperlinkOSC(_ rest: String) {
        let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let uri = parts.count > 1 ? String(parts[1]) : ""
        if uri.isEmpty {
            cursor.attrs.link = 0
            return
        }
        let params = String(parts[0])
        let explicitID = params.split(separator: ":").first { $0.hasPrefix("id=") }.map { String($0.dropFirst(3)) }
        let key = explicitID.map { "\($0)\u{0}\(uri)" } ?? uri + "\u{0}\(nextHyperlink)"
        if let existing = hyperlinkIDs[key] {
            cursor.attrs.link = existing
            return
        }
        let id = nextHyperlink
        nextHyperlink = nextHyperlink == UInt16.max ? 1 : nextHyperlink + 1
        if hyperlinks[id] != nil { hyperlinkIDs = hyperlinkIDs.filter { $0.value != id } }
        hyperlinks[id] = uri
        hyperlinkIDs[key] = id
        cursor.attrs.link = id
    }

    private func clipboardOSC(_ rest: String) {
        let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let payload = String(parts[1])
        guard payload != "?" else { return }
        if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
            delegate?.terminal(self, setClipboard: [UInt8](data))
        }
    }


    public func dcsHook(_ p: CSIParams, _ i: Intermediates, final: UInt8) {
        dcsBuffer.removeAll(keepingCapacity: true)
        switch (i.first, final) {
        case (UInt8(ascii: "$"), UInt8(ascii: "q")): dcsKind = .requestStatus
        case (UInt8(ascii: "+"), UInt8(ascii: "q")): dcsKind = .getTermcap
        default: dcsKind = .ignore
        }
    }

    public func dcsPut(_ byte: UInt8) {
        guard dcsKind != .ignore, dcsBuffer.count < 4096 else { return }
        dcsBuffer.append(byte)
    }

    public func dcsUnhook() {
        let data = String(decoding: dcsBuffer, as: UTF8.self)
        switch dcsKind {
        case .requestStatus: requestStatus(data)
        case .getTermcap: getTermcap(data)
        case .ignore: break
        }
        dcsKind = .ignore
        dcsBuffer.removeAll(keepingCapacity: true)
    }

    private func requestStatus(_ what: String) {
        let reply: String?
        switch what {
        case "m": reply = sgrString(cursor.attrs) + "m"
        case "r": reply = "\(scrollTop + 1);\(scrollBottom + 1)r"
        case " q":
            let n: Int
            switch cursorShape {
            case .block: n = modes.cursorBlink ? 1 : 2
            case .underline: n = modes.cursorBlink ? 3 : 4
            case .bar: n = modes.cursorBlink ? 5 : 6
            }
            reply = "\(n) q"
        default: reply = nil
        }
        if let reply {
            respond("\u{1B}P1$r\(reply)\u{1B}\\")
        } else {
            respond("\u{1B}P0$r\u{1B}\\")
        }
    }

    private func getTermcap(_ data: String) {
        for hexName in data.split(separator: ";") {
            let name = Terminal.unhex(String(hexName))
            let value: String?
            switch name {
            case "TN", "name": value = "xterm-256color"
            case "Co", "colors": value = "256"
            case "RGB": value = "8"
            default: value = nil
            }
            if let value {
                respond("\u{1B}P1+r\(hexName)=\(Terminal.hex(value))\u{1B}\\")
            } else {
                respond("\u{1B}P0+r\(hexName)\u{1B}\\")
            }
        }
    }

    static func hex(_ s: String) -> String {
        s.utf8.map { b in
            let h = String(b, radix: 16, uppercase: true)
            return h.count == 1 ? "0" + h : h
        }.joined()
    }

    static func unhex(_ s: String) -> String {
        var bytes: [UInt8] = []
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next() {
            if let v = UInt8(String([a, b]), radix: 16) { bytes.append(v) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func sgrString(_ a: Attributes) -> String {
        var p = ["0"]
        if a.flags.contains(.bold) { p.append("1") }
        if a.flags.contains(.faint) { p.append("2") }
        if a.flags.contains(.italic) { p.append("3") }
        switch a.underline {
        case .none: break
        case .single: p.append("4")
        case .double: p.append("4:2")
        case .curly: p.append("4:3")
        case .dotted: p.append("4:4")
        case .dashed: p.append("4:5")
        }
        if a.flags.contains(.blink) { p.append("5") }
        if a.flags.contains(.inverse) { p.append("7") }
        if a.flags.contains(.invisible) { p.append("8") }
        if a.flags.contains(.strikethrough) { p.append("9") }
        func color(_ c: Color, _ base: Int) {
            if let i = c.index { p.append("\(base);5;\(i)") }
            if let c = c.rgb { p.append("\(base);2;\(c.r);\(c.g);\(c.b)") }
        }
        color(a.fg, 38)
        color(a.bg, 48)
        return p.joined(separator: ";")
    }
}
