import AppKit
import TermCore

struct Theme: Codable, Equatable, Identifiable {
    var name: String
    var background: String
    var foreground: String
    var cursor: String
    var selection: String
    var ansi: [String]
    var builtIn = false

    var id: String { name }

    var isDark: Bool {
        let c = Theme.rgb(background)
        return (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255 < 0.5
    }

    var palette: Palette {
        var p = Palette()
        p.background = Theme.rgb(background)
        p.foreground = Theme.rgb(foreground)
        p.cursor = Theme.rgb(cursor)
        p.selection = Theme.rgb(selection)
        for i in 0..<min(16, ansi.count) { p.colors[i] = Theme.rgb(ansi[i]) }
        return p
    }

    static func rgb(_ hex: String) -> RGB {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(h, radix: 16) ?? 0
        return RGB(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02x%02x%02x", Int((s.redComponent * 255).rounded()),
                      Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
    }

    static func color(_ hex: String) -> NSColor {
        let c = rgb(hex)
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    private static func make(_ name: String, bg: String, fg: String, cursor: String? = nil, sel: String,
                             _ ansi: [String]) -> Theme {
        Theme(name: name, background: bg, foreground: fg, cursor: cursor ?? fg, selection: sel, ansi: ansi, builtIn: true)
    }

    static let builtIns: [Theme] = [
        make("Default Dark", bg: "#161618", fg: "#e6e6e6", sel: "#3a5f8f", [
            "#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#cccccc",
            "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#f2f2f2"]),
        make("Default Light", bg: "#fbfbfa", fg: "#1e1e22", sel: "#b3d4fc", [
            "#1e1e22", "#c4252b", "#1f8a3b", "#9a6a00", "#1f5fcc", "#a02fb3", "#10808f", "#8a8a90",
            "#5e5e66", "#e0353b", "#2ea44f", "#b58500", "#2f7ae5", "#bf46d1", "#1a9bad", "#b0b0b6"]),
        make("Solarized Dark", bg: "#002b36", fg: "#839496", cursor: "#93a1a1", sel: "#073642", [
            "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        make("Solarized Light", bg: "#fdf6e3", fg: "#657b83", cursor: "#586e75", sel: "#eee8d5", [
            "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        make("Dracula", bg: "#282a36", fg: "#f8f8f2", sel: "#44475a", [
            "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
            "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
        make("Nord", bg: "#2e3440", fg: "#d8dee9", sel: "#434c5e", [
            "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
            "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
        make("Gruvbox Dark", bg: "#282828", fg: "#ebdbb2", sel: "#504945", [
            "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
            "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        make("One Dark", bg: "#282c34", fg: "#abb2bf", cursor: "#528bff", sel: "#3e4451", [
            "#1e2127", "#e06c75", "#98c379", "#d19a66", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
            "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"]),
        make("Tokyo Night", bg: "#1a1b26", fg: "#c0caf5", sel: "#33467c", [
            "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
            "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"]),
        make("Catppuccin Mocha", bg: "#1e1e2e", fg: "#cdd6f4", cursor: "#f5e0dc", sel: "#45475a", [
            "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
            "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"]),
        make("Catppuccin Latte", bg: "#eff1f5", fg: "#4c4f69", cursor: "#dc8a78", sel: "#ccd0da", [
            "#5c5f77", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#acb0be",
            "#6c6f85", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#bcc0cc"]),
    ]

    static func importITerm(_ url: URL) -> Theme? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func hex(_ key: String) -> String? {
            guard let d = plist[key] as? [String: Any],
                  let r = d["Red Component"] as? Double, let g = d["Green Component"] as? Double,
                  let b = d["Blue Component"] as? Double else { return nil }
            return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
        var ansi: [String] = []
        for i in 0..<16 { guard let c = hex("Ansi \(i) Color") else { return nil }; ansi.append(c) }
        guard let bg = hex("Background Color"), let fg = hex("Foreground Color") else { return nil }
        return Theme(name: url.deletingPathExtension().lastPathComponent, background: bg, foreground: fg,
                     cursor: hex("Cursor Color") ?? fg, selection: hex("Selection Color") ?? "#3a5f8f", ansi: ansi)
    }
}
