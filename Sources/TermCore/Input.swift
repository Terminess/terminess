import Foundation

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift   = KeyModifiers(rawValue: 1)
    public static let option  = KeyModifiers(rawValue: 2)
    public static let control = KeyModifiers(rawValue: 4)

    var xtermParameter: Int { 1 + Int(rawValue & 7) }
}

public enum Key: Sendable, Equatable {
    case character(String)
    case enter, tab, backspace, escape, space
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, delete
    case function(Int)
}

public enum InputEncoder {
    public static func encode(_ key: Key, modifiers m: KeyModifiers, modes: TerminalModes,
                              optionAsMeta: Bool = true) -> [UInt8] {
        let esc: [UInt8] = [0x1B]
        let meta = m.contains(.option) && optionAsMeta
        let hasMods = m.rawValue & 7 != 0

        func csi(_ s: String) -> [UInt8] { esc + Array("[\(s)".utf8) }

        func cursorKey(_ final: String) -> [UInt8] {
            if hasMods { return csi("1;\(m.xtermParameter)\(final)") }
            return esc + Array((modes.applicationCursorKeys ? "O" : "[").utf8) + Array(final.utf8)
        }

        func tildeKey(_ n: Int) -> [UInt8] {
            hasMods ? csi("\(n);\(m.xtermParameter)~") : csi("\(n)~")
        }

        switch key {
        case .up: return cursorKey("A")
        case .down: return cursorKey("B")
        case .right: return cursorKey("C")
        case .left: return cursorKey("D")
        case .home: return cursorKey("H")
        case .end: return cursorKey("F")
        case .insert: return tildeKey(2)
        case .delete: return tildeKey(3)
        case .pageUp: return tildeKey(5)
        case .pageDown: return tildeKey(6)

        case .function(let n):
            switch n {
            case 1...4:
                let final = ["P", "Q", "R", "S"][n - 1]
                return hasMods ? csi("1;\(m.xtermParameter)\(final)") : esc + Array("O\(final)".utf8)
            case 5: return tildeKey(15)
            case 6: return tildeKey(17)
            case 7: return tildeKey(18)
            case 8: return tildeKey(19)
            case 9: return tildeKey(20)
            case 10: return tildeKey(21)
            case 11: return tildeKey(23)
            case 12: return tildeKey(24)
            case 13...20: return tildeKey([25, 26, 28, 29, 31, 32, 33, 34][n - 13])
            default: return []
            }

        case .enter:
            if m.contains(.shift) || meta { return esc + [0x0D] }
            return modes.newline ? [0x0D, 0x0A] : [0x0D]
        case .tab:
            return m.contains(.shift) ? csi("Z") : (meta ? esc + [0x09] : [0x09])
        case .backspace:
            if m.contains(.control) { return [0x08] }
            return meta ? esc + [0x7F] : [0x7F]
        case .escape:
            return esc
        case .space:
            if m.contains(.control) { return meta ? esc + [0x00] : [0x00] }
            return meta ? esc + [0x20] : [0x20]

        case .character(let text):
            var bytes = Array(text.utf8)
            if m.contains(.control), let c = controlByte(text) { bytes = [c] }
            return meta ? esc + bytes : bytes
        }
    }

    static func controlByte(_ text: String) -> UInt8? {
        guard text.utf8.count == 1, let b = text.utf8.first else { return nil }
        switch b {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return b - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return b - UInt8(ascii: "A") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "), UInt8(ascii: "2"): return 0
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1B
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1C
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1D
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "7"): return 0x1F
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7F
        default: return nil
        }
    }

    public static func paste(_ text: String, modes: TerminalModes) -> [UInt8] {
        var t = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if modes.bracketedPaste {
            t = t.replacingOccurrences(of: "\u{1B}[201~", with: "")
            return Array("\u{1B}[200~\(t)\u{1B}[201~".utf8)
        }
        return Array(t.utf8)
    }

    public static func focus(_ focused: Bool, modes: TerminalModes) -> [UInt8] {
        guard modes.focusEvents else { return [] }
        return Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8)
    }

    public enum MouseButton: Sendable { case left, middle, right, none, wheelUp, wheelDown, wheelLeft, wheelRight }
    public enum MouseAction: Sendable { case press, release, drag, move }

    public static func mouse(_ button: MouseButton, _ action: MouseAction, x: Int, y: Int,
                             modifiers m: KeyModifiers, modes: TerminalModes) -> [UInt8] {
        switch modes.mouseTracking {
        case .off: return []
        case .x10: if action != .press { return [] }
        case .normal: if action == .drag || action == .move { return [] }
        case .button: if action == .move { return [] }
        case .any: break
        }
        var code: Int
        switch button {
        case .left: code = 0
        case .middle: code = 1
        case .right: code = 2
        case .none: code = 3
        case .wheelUp: code = 64
        case .wheelDown: code = 65
        case .wheelLeft: code = 66
        case .wheelRight: code = 67
        }
        if action == .drag || action == .move { code += 32 }
        if modes.mouseTracking != .x10 {
            if m.contains(.shift) { code += 4 }
            if m.contains(.option) { code += 8 }
            if m.contains(.control) { code += 16 }
        }
        let cx = x + 1, cy = y + 1
        switch modes.mouseEncoding {
        case .sgr, .sgrPixels:
            let final = action == .release ? "m" : "M"
            return Array("\u{1B}[<\(code);\(cx);\(cy)\(final)".utf8)
        case .urxvt:
            let c = action == .release ? 3 : code
            return Array("\u{1B}[\(c + 32);\(cx);\(cy)M".utf8)
        case .legacy, .utf8:
            let c = action == .release ? 3 + (code & ~3 & ~64) : code
            guard cx < 223, cy < 223 else { return [] }
            return [0x1B, UInt8(ascii: "["), UInt8(ascii: "M"), UInt8(32 + c), UInt8(32 + cx), UInt8(32 + cy)]
        }
    }
}
