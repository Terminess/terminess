import AppKit

import TermCore

enum AppearanceSetting: Int {
    case system = 0, light = 1, dark = 2
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, SidebarActions {
    private(set) var controllers: [TerminalWindowController] = []
    private var appearanceObservation: NSKeyValueObservation?

    var appearanceSetting: AppearanceSetting {
        get {
            switch ProcessInfo.processInfo.environment["TERMAPP_APPEARANCE"] {
            case "light": return .light
            case "dark": return .dark
            default: return AppearanceSetting(rawValue: UserDefaults.standard.integer(forKey: "appearance")) ?? .system
            }
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appearance"); applyAppearance() }
    }

    var colorScheme: TermCore.ColorScheme {
        switch appearanceSetting {
        case .light: return .light
        case .dark: return .dark
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    func applyAppearance() {
        let scheme = colorScheme
        let forced: NSAppearance? = switch appearanceSetting {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        for c in controllers { c.apply(scheme: scheme, appearance: forced) }
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        appearanceSetting = AppearanceSetting(rawValue: sender.tag) ?? .system
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setAppearance(_:)) {
            item.state = item.tag == appearanceSetting.rawValue ? .on : .off
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        NSWindow.allowsAutomaticWindowTabbing = true
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyAppearance() } }
        }
        let sidebar = SidebarModel.shared
        sidebar.actions = self
        sidebar.tabProvider = { [weak self] in self?.openTabs() ?? [] }
        sidebar.start()
        newWindow(nil)
        if let first = controllers.first { DebugScript.run(on: first) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        open(tabbedWith: nil)
    }

    @objc func newWindowForTab(_ sender: Any?) {
        open(tabbedWith: NSApp.keyWindow)
    }

    var keyController: TerminalWindowController? {
        controllers.first { $0.window?.isKeyWindow == true } ?? controllers.last
    }

    @discardableResult
    func open(tabbedWith host: NSWindow?, directory: String? = nil, command: String? = nil) -> TerminalWindowController {
        let cwd = directory ?? (host?.windowController as? TerminalWindowController)?.currentDirectory
        let controller = TerminalWindowController(workingDirectory: cwd, command: command)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
            SidebarModel.shared.refreshTabs()
        }
        controllers.append(controller)
        controller.apply(scheme: colorScheme, appearance: appearanceSetting == .system ? nil
                         : NSAppearance(named: appearanceSetting == .light ? .aqua : .darkAqua))
        if let host, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
        SidebarModel.shared.refreshTabs()
        return controller
    }


    @objc func toggleSidebar(_ sender: Any?) {
        let model = SidebarModel.shared
        model.visible.toggle()
        for c in controllers { c.setSidebar(visible: model.visible, animated: c.window?.isKeyWindow == true) }
    }

    private func openTabs() -> [OpenTab] {
        let home = SidebarModel.home
        return controllers.map { c in
            let dir = c.currentDirectory ?? ""
            let shown = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
            let command = c.session.process?.foregroundCommand ?? ""
            let title = c.window?.title ?? ""
            return OpenTab(id: ObjectIdentifier(c),
                           title: title.isEmpty || title == "terminal" ? (command.isEmpty ? "shell" : command) : title,
                           command: command, directory: shown, isKey: c.window?.isKeyWindow == true)
        }
    }

    func focusTab(_ id: ObjectIdentifier) {
        controllers.first { ObjectIdentifier($0) == id }?.focus()
    }

    func resume(_ session: SessionItem) {
        let cmd = session.tool == "claude" ? "claude --resume \(shellQuote(session.id))" : "codex resume \(shellQuote(session.id))"
        let dir = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : SidebarModel.home
        open(tabbedWith: keyController?.window, directory: dir, command: cmd)
    }

    func startPair(mode: String, target: String) {
        guard let pair = SidebarModel.pairTool else { return }
        let host = keyController
        let dir = host?.currentDirectory ?? SidebarModel.home
        let agent = target == "codex" ? "Codex" : "Claude"
        let titles = ["ask": "Ask \(agent)", "review": "\(agent): Review Changes",
                      "handoff": "Hand Off to \(agent)", "parallel": "Parallel Job for \(agent)"]
        let notes = ["ask": "\(agent) reads the repo and answers. It cannot change files.",
                     "review": "\(agent) reviews the uncommitted changes. Add a focus, or leave this empty.",
                     "handoff": "\(agent) does the task in this folder and may edit files.",
                     "parallel": "\(agent) works in a separate copy of the repo in the background. Apply or discard the result from the sidebar."]
        guard let brief = promptForText(title: titles[mode] ?? "Pair", note: (notes[mode] ?? "") + "\nFolder: \(dir)",
                                        required: mode != "review") else { return }
        var cmd = "\(shellQuote(pair)) \(mode) \(target) --from user"
        if !brief.isEmpty, let file = writeBrief(brief) { cmd += " --brief-file \(shellQuote(file))" }
        open(tabbedWith: host?.window, directory: dir, command: cmd)
    }

    func jobAction(_ job: PairJob, _ action: String) {
        guard let pair = SidebarModel.pairTool else { return }
        var cmd = "\(shellQuote(pair)) \(action) \(shellQuote(job.id))"
        if action == "diff" { cmd += " | less -R" }
        let dir = FileManager.default.fileExists(atPath: job.repoPath) ? job.repoPath : SidebarModel.home
        open(tabbedWith: keyController?.window, directory: dir, command: cmd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { SidebarModel.shared.refreshPair() } }
    }

    func showRun(_ run: PairRun) {
        guard FileManager.default.fileExists(atPath: run.resultFile) else { return }
        open(tabbedWith: keyController?.window, command: "less -R \(shellQuote(run.resultFile))")
    }

    private func promptForText(title: String, note: String, required: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = note
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.font = NSFont.systemFont(ofSize: 13)
        text.autoresizingMask = [.width]
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if required && value.isEmpty { return nil }
        return value
    }

    private func writeBrief(_ text: String) -> String? {
        let dir = SidebarModel.pairState + "/briefs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let path = dir + "/" + f.string(from: Date()) + ".md"
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch { return nil }
        return path
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let shellItem = NSMenuItem()
        let shell = NSMenu(title: "Shell")
        shell.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        shell.addItem(withTitle: "New Tab", action: #selector(newWindowForTab(_:)), keyEquivalent: "t")
        shell.addItem(.separator())
        shell.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        shellItem.submenu = shell
        main.addItem(shellItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Clear Scrollback", action: #selector(TerminalView.clearScrollback(_:)), keyEquivalent: "k")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(TerminalView.increaseFontSize(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller", action: #selector(TerminalView.decreaseFontSize(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(TerminalView.resetFontSize(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.control, .command]
        view.addItem(sidebarItem)
        view.addItem(.separator())
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        for (title, tag) in [("Follow System", 0), ("Light", 1), ("Dark", 2)] {
            let item = NSMenuItem(title: title, action: #selector(setAppearance(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
            appearanceMenu.addItem(item)
        }
        appearanceItem.submenu = appearanceMenu
        view.addItem(appearanceItem)
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{")
        window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        return main
    }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
