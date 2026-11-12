public enum KeyEventType: Int, Sendable {
    case press = 1, `repeat` = 2, release = 3
}

public struct KittyFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let disambiguate   = KittyFlags(rawValue: 1)
    public static let eventTypes     = KittyFlags(rawValue: 2)
    public static let alternateKeys  = KittyFlags(rawValue: 4)
    public static let allKeysAsCodes = KittyFlags(rawValue: 8)
    public static let associatedText = KittyFlags(rawValue: 16)
}

public struct KittyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift    = KittyModifiers(rawValue: 1)
    public static let alt      = KittyModifiers(rawValue: 2)
    public static let control  = KittyModifiers(rawValue: 4)
    public static let `super`  = KittyModifiers(rawValue: 8)
    public static let capsLock = KittyModifiers(rawValue: 64)
    public static let numLock  = KittyModifiers(rawValue: 128)
}

extension InputEncoder {
    public static func kitty(_ key: Key, modifiers m: KittyModifiers, event: KeyEventType = .press,
                             text: String? = nil, shiftedKey: String? = nil, flags rawFlags: Int,
                             modes: TerminalModes) -> [UInt8]? {
        let flags = KittyFlags(rawValue: rawFlags)
        let allKeys = flags.contains(.allKeysAsCodes)
        let reportEvents = flags.contains(.eventTypes)
        if event != .press && !reportEvents { return event == .repeat ? kitty(key, modifiers: m, event: .press, text: text, shiftedKey: shiftedKey, flags: rawFlags, modes: modes) : nil }

        let significant = KittyModifiers(rawValue: m.rawValue & ~(KittyModifiers.capsLock.rawValue | KittyModifiers.numLock.rawValue))
        let modValue = m.rawValue + 1
        let eventSuffix = reportEvents && event != .press ? ":\(event.rawValue)" : ""

        func csi(_ body: String) -> [UInt8] { Array("\u{1B}[\(body)".utf8) }

        func uForm(_ code: Int, alternate: String = "", textCodes: String = "") -> [UInt8] {
            var s = "\(code)\(alternate)"
            let needMods = modValue != 1 || !eventSuffix.isEmpty || !textCodes.isEmpty
            if needMods { s += ";\(modValue)\(eventSuffix)" }
            if !textCodes.isEmpty { s += ";\(textCodes)" }
            return csi(s + "u")
        }

        func legacyForm(_ number: Int, _ final: String) -> [UInt8] {
            if modValue == 1 && eventSuffix.isEmpty {
                if final == "~" { return csi("\(number)~") }
                return InputEncoder.encode(key, modifiers: [], modes: modes)
            }
            return csi("\(number);\(modValue)\(eventSuffix)\(final)")
        }

        switch key {
        case .up: return legacyForm(1, "A")
        case .down: return legacyForm(1, "B")
        case .right: return legacyForm(1, "C")
        case .left: return legacyForm(1, "D")
        case .home: return legacyForm(1, "H")
        case .end: return legacyForm(1, "F")
        case .insert: return legacyForm(2, "~")
        case .delete: return legacyForm(3, "~")
        case .pageUp: return legacyForm(5, "~")
        case .pageDown: return legacyForm(6, "~")
        case .function(let n):
            switch n {
            case 1: return modValue == 1 && eventSuffix.isEmpty ? csi("P") : csi("1;\(modValue)\(eventSuffix)P")
            case 2: return modValue == 1 && eventSuffix.isEmpty ? csi("Q") : csi("1;\(modValue)\(eventSuffix)Q")
            case 3: return legacyForm(13, "~")
            case 4: return modValue == 1 && eventSuffix.isEmpty ? csi("S") : csi("1;\(modValue)\(eventSuffix)S")
            case 5: return legacyForm(15, "~")
            case 6: return legacyForm(17, "~")
            case 7: return legacyForm(18, "~")
            case 8: return legacyForm(19, "~")
            case 9: return legacyForm(20, "~")
            case 10: return legacyForm(21, "~")
            case 11: return legacyForm(23, "~")
            case 12: return legacyForm(24, "~")
            case 13...35: return uForm(57376 + n - 13)
            default: return nil
            }

        case .escape:
            return uForm(27)

        case .enter, .tab, .backspace:
            let code = key == .enter ? 13 : key == .tab ? 9 : 127
            if significant.isEmpty && !allKeys {
                if event == .release { return nil }
                return key == .enter ? [0x0D] : key == .tab ? [0x09] : [0x7F]
            }
            return uForm(code)

        case .space, .character:
            let base: String
            if case .character(let c) = key { base = c } else { base = " " }
            guard let scalar = base.unicodeScalars.first else { return nil }
            var code = Int(scalar.value)
            if let lower = base.lowercased().unicodeScalars.first, base.unicodeScalars.count == 1 { code = Int(lower.value) }

            let produced = text ?? (key == .space ? " " : base)
            let onlyShift = significant.subtracting(.shift).isEmpty
            if !allKeys && onlyShift {
                if event == .release { return nil }
                return Array(produced.utf8)
            }
            var alternate = ""
            if flags.contains(.alternateKeys), m.contains(.shift), let shifted = shiftedKey?.unicodeScalars.first,
               Int(shifted.value) != code {
                alternate = ":\(shifted.value)"
            }
            var textCodes = ""
            if flags.contains(.associatedText), allKeys, event != .release,
               significant.subtracting(.shift).isEmpty, !produced.isEmpty {
                textCodes = produced.unicodeScalars.map { String($0.value) }.joined(separator: ":")
            }
            return uForm(code, alternate: alternate, textCodes: textCodes)
        }
    }
}
