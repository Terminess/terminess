import AppKit
import Combine
import TermCore

extension Notification.Name {
    static let terminalSettingsChanged = Notification.Name("terminalSettingsChanged")
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var fontName: String { didSet { save("fontName", fontName) } }
    @Published var fontSize: Double { didSet { save("fontSize", fontSize) } }
    @Published var lineSpacing: Double { didSet { save("lineSpacing", lineSpacing) } }
    @Published var cursorShape: String { didSet { save("cursorShape", cursorShape) } }
    @Published var cursorBlink: Bool { didSet { save("cursorBlink", cursorBlink) } }
    @Published var optionKey: String { didSet { save("optionKey", optionKey) } }
    @Published var scrollback: Int { didSet { save("scrollback", scrollback) } }
    @Published var newTabsInCurrentFolder: Bool { didSet { save("newTabsInCurrentFolder", newTabsInCurrentFolder) } }
    @Published var appearance: Int { didSet { save("appearance", appearance) } }
    @Published var lightTheme: String { didSet { save("lightTheme", lightTheme) } }
    @Published var darkTheme: String { didSet { save("darkTheme", darkTheme) } }
    @Published var customThemes: [Theme] { didSet { saveThemes() } }
    @Published var thinStrokes: Bool { didSet { save("thinStrokes", thinStrokes) } }
    @Published var startFolder: String { didSet { save("startFolder", startFolder) } }

    private init() {
        if d.object(forKey: "fontName") == nil {
            let imported = Settings.iTermFont()
            d.set(imported?.name ?? "", forKey: "fontName")
            d.set(imported?.size ?? 12, forKey: "fontSize")
        }
        fontName = d.string(forKey: "fontName") ?? ""
        fontSize = d.object(forKey: "fontSize") as? Double ?? 12
        lineSpacing = d.object(forKey: "lineSpacing") as? Double ?? 1.0
        cursorShape = d.string(forKey: "cursorShape") ?? "block"
        cursorBlink = d.object(forKey: "cursorBlink") as? Bool ?? false
        optionKey = d.string(forKey: "optionKey") ?? "left"
        scrollback = d.object(forKey: "scrollback") as? Int ?? 10_000
        newTabsInCurrentFolder = d.object(forKey: "newTabsInCurrentFolder") as? Bool ?? true
        appearance = d.integer(forKey: "appearance")
        lightTheme = d.string(forKey: "lightTheme") ?? "Default Light"
        darkTheme = d.string(forKey: "darkTheme") ?? "Default Dark"
        thinStrokes = d.object(forKey: "thinStrokes") as? Bool ?? true
        startFolder = d.string(forKey: "startFolder") ?? ""
        if let data = d.data(forKey: "customThemes"), let themes = try? JSONDecoder().decode([Theme].self, from: data) {
            customThemes = themes
        } else {
            customThemes = []
        }
    }

    private func saveThemes() {
        if let data = try? JSONEncoder().encode(customThemes) { d.set(data, forKey: "customThemes") }
        NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
    }

    var allThemes: [Theme] { Theme.builtIns + customThemes }

    func theme(named name: String, fallbackDark: Bool) -> Theme {
        allThemes.first { $0.name == name } ?? Theme.builtIns[fallbackDark ? 0 : 1]
    }

    func saveCustom(_ theme: Theme) {
        var t = theme
        t.builtIn = false
        if let i = customThemes.firstIndex(where: { $0.name == t.name }) { customThemes[i] = t } else { customThemes.append(t) }
    }

    func deleteCustom(_ name: String) {
        customThemes.removeAll { $0.name == name }
        if lightTheme == name { lightTheme = "Default Light" }
        if darkTheme == name { darkTheme = "Default Dark" }
    }

    var startDirectory: String {
        if !startFolder.isEmpty, FileManager.default.fileExists(atPath: startFolder) { return startFolder }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func save(_ key: String, _ value: Any) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
    }

    var engineCursorShape: CursorShape {
        switch cursorShape {
        case "bar": return .bar
        case "underline": return .underline
        default: return .block
        }
    }

    func font(size: CGFloat) -> NSFont {
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func iTermFont() -> (name: String, size: Double)? {
        guard let profiles = CFPreferencesCopyAppValue("New Bookmarks" as CFString, "com.googlecode.iterm2" as CFString) as? [[String: Any]],
              !profiles.isEmpty else { return nil }
        let defaultID = CFPreferencesCopyAppValue("Default Bookmark Guid" as CFString, "com.googlecode.iterm2" as CFString) as? String
        let profile = profiles.first { ($0["Guid"] as? String) == defaultID } ?? profiles[0]
        guard let spec = profile["Normal Font"] as? String, let space = spec.lastIndex(of: " "),
              let size = Double(spec[spec.index(after: space)...]) else { return nil }
        let name = String(spec[..<space])
        return NSFont(name: name, size: CGFloat(size)) != nil ? (name, size) : nil
    }

    static func monospacedFonts() -> [(String, String)] {
        let fm = NSFontManager.shared
        var out: [(String, String)] = []
        for family in fm.availableFontFamilies.sorted() {
            guard let members = fm.availableMembers(ofFontFamily: family), let first = members.first,
                  let ps = first.first as? String, let font = NSFont(name: ps, size: 12), font.isFixedPitch else { continue }
            let regular = members.first { ($0[1] as? String)?.lowercased() == "regular" }?.first as? String
            out.append((family, regular ?? ps))
        }
        return out
    }
}
