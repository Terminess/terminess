import AppKit

@MainActor
enum SessionStore {
    struct SavedTab: Codable {
        var layout: PaneLayout
        var title: String?
        var theme: String?
        var worktree: WorktreeInfo?
    }
    struct SavedWindow: Codable {
        var frame: [Double]
        var tabs: [SavedTab]
        var selected: Int
    }

    static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = Bundle.main.bundleIdentifier ?? "TermApp-debug"
        return base.appendingPathComponent("terminal-dev/\(name)-session.json")
    }

    static func save(_ controllers: [TerminalWindowController]) {
        guard Settings.shared.restoreSession else { try? FileManager.default.removeItem(at: file); return }
        var seen = Set<ObjectIdentifier>()
        var windows: [SavedWindow] = []
        for c in controllers {
            guard let w = c.window, !seen.contains(ObjectIdentifier(w)) else { continue }
            let group = w.tabbedWindows ?? [w]
            group.forEach { seen.insert(ObjectIdentifier($0)) }
            let tabs = group.compactMap { $0.windowController as? TerminalWindowController }
            let saved = tabs.map { SavedTab(layout: $0.layout(), title: $0.customTitle, theme: $0.themeOverride, worktree: $0.worktree) }
            let f = w.frame
            windows.append(SavedWindow(frame: [f.minX, f.minY, f.width, f.height], tabs: saved,
                                       selected: group.firstIndex { $0.isKeyWindow || $0 == w.tabGroup?.selectedWindow } ?? 0))
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(windows) { try? data.write(to: file, options: .atomic) }
    }

    static func load() -> [SavedWindow] {
        guard Settings.shared.restoreSession, let data = try? Data(contentsOf: file),
              let windows = try? JSONDecoder().decode([SavedWindow].self, from: data) else { return [] }
        return windows
    }
}
