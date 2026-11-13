import AppKit

struct KeyBinding: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String
    var modifiers: Int
    var text: String

    static let command = 1, option = 2, control = 4, shift = 8

    var label: String {
        var s = ""
        if modifiers & KeyBinding.control != 0 { s += "⌃" }
        if modifiers & KeyBinding.option != 0 { s += "⌥" }
        if modifiers & KeyBinding.shift != 0 { s += "⇧" }
        if modifiers & KeyBinding.command != 0 { s += "⌘" }
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "forwarddelete": "⌦",
                     "return": "↩", "tab": "⇥", "escape": "⎋", "space": "Space", "home": "↖", "end": "↘",
                     "pageup": "⇞", "pagedown": "⇟"]
        return s + (names[key] ?? key.uppercased())
    }

    var bytes: [UInt8] {
        var out: [UInt8] = []
        var it = Array(text.utf8).makeIterator()
        while let b = it.next() {
            guard b == UInt8(ascii: "\\"), let n = it.next() else { out.append(b); continue }
            switch n {
            case UInt8(ascii: "e"): out.append(0x1B)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "x"):
                if let a = it.next(), let c = it.next(), let v = UInt8(String(bytes: [a, c], encoding: .ascii) ?? "", radix: 16) {
                    out.append(v)
                }
            default: out.append(n)
            }
        }
        return out
    }

    static func describe(_ e: NSEvent) -> (key: String, modifiers: Int)? {
        var m = 0
        let f = e.modifierFlags
        if f.contains(.command) { m |= command }
        if f.contains(.option) { m |= option }
        if f.contains(.control) { m |= control }
        if f.contains(.shift) { m |= shift }
        let key: String
        if e.keyCode == 53 { key = "escape" }
        else if e.keyCode == 49 { key = "space" }
        else if let sk = e.specialKey {
            switch sk {
            case .leftArrow: key = "left"
            case .rightArrow: key = "right"
            case .upArrow: key = "up"
            case .downArrow: key = "down"
            case .delete, .backspace: key = "delete"
            case .deleteForward: key = "forwarddelete"
            case .carriageReturn, .enter, .newline: key = "return"
            case .tab, .backTab: key = "tab"
            case .home: key = "home"
            case .end: key = "end"
            case .pageUp: key = "pageup"
            case .pageDown: key = "pagedown"
            default:
                let f: [NSEvent.SpecialKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
                guard let i = f.firstIndex(of: sk) else { return nil }
                key = "f\(i + 1)"
            }
        } else {
            guard let c = e.charactersIgnoringModifiers?.lowercased(), !c.isEmpty else { return nil }
            key = c
        }
        return (key, m)
    }

    static let naturalEditing: [KeyBinding] = [
        KeyBinding(key: "left", modifiers: option, text: "\\eb"),
        KeyBinding(key: "right", modifiers: option, text: "\\ef"),
        KeyBinding(key: "left", modifiers: command, text: "\\x01"),
        KeyBinding(key: "right", modifiers: command, text: "\\x05"),
        KeyBinding(key: "delete", modifiers: option, text: "\\x17"),
        KeyBinding(key: "delete", modifiers: command, text: "\\x15"),
    ]

    @MainActor
    static func match(_ e: NSEvent) -> KeyBinding? {
        guard let (key, m) = describe(e) else { return nil }
        let settings = Settings.shared
        if let b = settings.keyBindings.first(where: { $0.key == key && $0.modifiers == m }) { return b }
        if settings.naturalTextEditing {
            return naturalEditing.first { $0.key == key && $0.modifiers == m }
        }
        return nil
    }
}
