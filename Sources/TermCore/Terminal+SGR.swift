extension Terminal {
    func selectGraphicRendition(_ p: CSIParams) {
        if p.isEmpty { cursor.attrs = Attributes(); return }
        var k = 0
        while k < p.count {
            let group = p.group(k)
            let code = max(group.first ?? 0, 0)
            var a = cursor.attrs
            switch code {
            case 0: a = Attributes()
            case 1: a.flags.insert(.bold)
            case 2: a.flags.insert(.faint)
            case 3: a.flags.insert(.italic)
            case 4:
                if group.count > 1 {
                    switch group[group.startIndex + 1] {
                    case 0: a.underline = .none
                    case 2: a.underline = .double
                    case 3: a.underline = .curly
                    case 4: a.underline = .dotted
                    case 5: a.underline = .dashed
                    default: a.underline = .single
                    }
                } else {
                    a.underline = .single
                }
            case 5, 6: a.flags.insert(.blink)
            case 7: a.flags.insert(.inverse)
            case 8: a.flags.insert(.invisible)
            case 9: a.flags.insert(.strikethrough)
            case 21: a.underline = .double
            case 22: a.flags.remove([.bold, .faint])
            case 23: a.flags.remove(.italic)
            case 24: a.underline = .none
            case 25: a.flags.remove(.blink)
            case 27: a.flags.remove(.inverse)
            case 28: a.flags.remove(.invisible)
            case 29: a.flags.remove(.strikethrough)
            case 30...37: a.fg = .indexed(UInt8(code - 30))
            case 39: a.fg = .default
            case 40...47: a.bg = .indexed(UInt8(code - 40))
            case 49: a.bg = .default
            case 53: a.flags.insert(.overline)
            case 55: a.flags.remove(.overline)
            case 59: a.underlineColor = .default
            case 90...97: a.fg = .indexed(UInt8(code - 90 + 8))
            case 100...107: a.bg = .indexed(UInt8(code - 100 + 8))
            case 38, 48, 58:
                let (color, consumed) = extendedColor(p, at: k)
                if let color {
                    switch code {
                    case 38: a.fg = color
                    case 48: a.bg = color
                    default: a.underlineColor = color
                    }
                }
                k += consumed
                cursor.attrs = a
                continue
            default: break
            }
            cursor.attrs = a
            k += 1
        }
    }

    private func extendedColor(_ p: CSIParams, at k: Int) -> (Color?, Int) {
        let group = Array(p.group(k))
        if group.count > 1 {
            switch group[1] {
            case 5:
                guard group.count >= 3 else { return (nil, 1) }
                return (.indexed(clamp(group[2])), 1)
            case 2:
                let rgb = group.count >= 6 ? Array(group[3...5]) : Array(group.dropFirst(2))
                guard rgb.count == 3 else { return (nil, 1) }
                return (.rgb(clamp(rgb[0]), clamp(rgb[1]), clamp(rgb[2])), 1)
            default:
                return (nil, 1)
            }
        }
        switch p.raw(k + 1, -1) {
        case 5:
            guard k + 2 < p.count else { return (nil, p.count - k) }
            return (.indexed(clamp(p.raw(k + 2, 0))), 3)
        case 2:
            guard k + 4 < p.count else { return (nil, p.count - k) }
            return (.rgb(clamp(p.raw(k + 2, 0)), clamp(p.raw(k + 3, 0)), clamp(p.raw(k + 4, 0))), 5)
        default:
            return (nil, 1)
        }
    }

    private func clamp(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 255)) }
}
