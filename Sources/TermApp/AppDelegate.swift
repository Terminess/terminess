import AppKit

import SwiftUI
import TermCore
import TermHost
import TermTranscript

enum AppearanceSetting: Int {
    case system = 0, light = 1, dark = 2
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate, SidebarActions {
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
        set { Settings.shared.appearance = newValue.rawValue }
    }

    var colorScheme: TermCore.ColorScheme {
        switch appearanceSetting {
        case .light: return .light
        case .dark: return .dark
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    var activeTheme: Theme {
        let settings = Settings.shared
        let darkAppearance: Bool
        switch appearanceSetting {
        case .light: darkAppearance = false
        case .dark: darkAppearance = true
        case .system: darkAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return darkAppearance ? settings.theme(named: settings.darkTheme, fallbackDark: true)
                              : settings.theme(named: settings.lightTheme, fallbackDark: false)
    }

    private var forcedAppearance: NSAppearance? {
        switch appearanceSetting {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    func theme(for c: TerminalWindowController) -> Theme {
        if let name = c.themeOverride, let t = Settings.shared.allThemes.first(where: { $0.name == name }) { return t }
        return activeTheme
    }

    func applyAppearance() {
        let theme = activeTheme
        for c in controllers {
            let t = self.theme(for: c)
            c.apply(scheme: t.isDark ? .dark : .light, palette: t.palette, appearance: forcedAppearance)
        }
        QuickTerminal.shared.applyTheme(theme)
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        Settings.shared.appearance = sender.tag
    }

    private var doctorWindow: NSWindow?
    private var pairWindow: NSWindow?

    @objc func showPairPhone(_ sender: Any?) {
        if pairWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PairPhoneView()))
            w.title = "Pair iPhone"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            pairWindow = w
        }
        pairWindow?.makeKeyAndOrderFront(nil)
        PairModel.shared.start()
    }

    @objc func showDoctor(_ sender: Any?) {
        if doctorWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: DoctorView()))
            w.title = "Doctor"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            doctorWindow = w
        } else {
            DoctorModel.sharedForWindow.run()
        }
        doctorWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAgentsDashboard(_ sender: Any?) { AgentsDashboardWindow.show() }

    @objc func newAgentTab(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String, let exe = HostService.executable else { return }
        if AgentKey.read() == nil {
            alert("Add your Anthropic API key", "Terminess agent tabs use your own API key, billed to your Anthropic account. Add it in Settings, Agents, then try again.")
            return
        }
        let c = open(tabbedWith: keyController?.window, directory: keyController?.currentDirectory,
                     command: "\(shellQuote(exe)) agent --model \(model)")
        c.customTitle = "Terminess Agent"
    }

    @objc func showOpsGuide(_ sender: Any?) {
        OpsGuideWindow.show()
    }

    @objc func showLibrary(_ sender: Any?) {
        LibraryWindow.show(directory: keyController?.currentDirectory)
    }

    func showSettings(page: String) {
        UserDefaults.standard.set(page, forKey: "settingsPage")
        showSettings(nil)
    }

    @objc func showModels(_ sender: Any?) { showSettings(page: "models") }

    @objc func showSettings(_ sender: Any?) {
        if let c = keyController ?? controllers.last { c.showSettingsPane() } else { SettingsWindowController.shared.show() }
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
        NotificationCenter.default.addObserver(forName: .terminalSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyAppearance()
                if Settings.shared.quickTerminalKey != self?.lastQuickKey {
                    self?.lastQuickKey = Settings.shared.quickTerminalKey
                    QuickTerminal.shared.configure()
                }
            }
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyAppearance() } }
        }
        installTabDoubleClick()
        AttentionCenter.shared.setUp()
        ShellIntegration.install()
        QuickTerminal.shared.configure()
        let sidebar = SidebarModel.shared
        sidebar.actions = self
        sidebar.tabProvider = { [weak self] in self?.openTabs() ?? [] }
        sidebar.currentDirectory = { [weak self] in self?.keyController?.currentDirectory }
        sidebar.start()
        AgentEvents.refreshIfConsented()
        let env = ProcessInfo.processInfo.environment
        let testing = env["TERMAPP_SCRIPT"] != nil && env["TERMAPP_ALLOW_RESTORE"] == nil
        if testing || !restoreSession() { newWindow(nil) }
        if let first = controllers.first { DebugScript.run(on: first) }
        parkingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.parkIdleAgents() }
        }
        if !testing {
            sessionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.saveSession() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private var sessionTimer: Timer?
    var lastChoiceWasSecond = false
    private var parkingTimer: Timer?

    func parkIdleAgents(force: Bool = false) {
        let settings = Settings.shared
        guard settings.idleParking || force else { return }
        let limit = force ? 0 : TimeInterval(settings.idleParkingMinutes * 60)
        let sessions = SidebarModel.shared.sessions
        for c in controllers {
            for pane in c.panes {
                let inView = NSApp.isActive && c.window?.isKeyWindow == true && c.focused === pane
                if !inView, Date().timeIntervalSince(pane.session.lastActivity) >= limit {
                    c.park(pane, sessions: sessions)
                }
            }
        }
    }
    private var lastQuickKey = Settings.shared.quickTerminalKey

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let env = ProcessInfo.processInfo.environment
        if env["TERMAPP_SCRIPT"] == nil || env["TERMAPP_ALLOW_RESTORE"] != nil { saveSession() }
        TerminalSession.appIsQuitting = true
        return .terminateNow
    }

    func saveSession() { SessionStore.save(controllers) }

    private func restoreSession() -> Bool {
        let windows = SessionStore.load()
        guard !windows.isEmpty else { return false }
        for saved in windows {
            var host: NSWindow?
            var opened: [TerminalWindowController] = []
            for tab in saved.tabs {
                let c = open(tabbedWith: host, layout: tab.layout)
                c.customTitle = tab.title
                c.themeOverride = tab.theme
                if let w = tab.worktree, FileManager.default.fileExists(atPath: w.path) { c.worktree = w }
                if host == nil, saved.frame.count == 4 {
                    c.window?.setFrame(NSRect(x: saved.frame[0], y: saved.frame[1], width: saved.frame[2], height: saved.frame[3]),
                                       display: true)
                }
                host = c.window ?? host
                opened.append(c)
            }
            if saved.selected < opened.count { opened[saved.selected].focus() }
        }
        return !controllers.isEmpty
    }

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
    func open(tabbedWith host: NSWindow?, directory: String? = nil, command: String? = nil,
              layout: PaneLayout? = nil, machine: RemoteMachine? = nil, agent: String? = nil) -> TerminalWindowController {
        let inherit = Settings.shared.newTabsInCurrentFolder
        let current = (host?.windowController as? TerminalWindowController)
        let local = current?.session.machine == nil ? current?.currentDirectory : nil
        let cwd = machine != nil ? directory : directory ?? (inherit ? local : nil) ?? Settings.shared.startDirectory
        let controller = TerminalWindowController(workingDirectory: cwd, command: command, layout: layout,
                                                  machine: machine, agent: agent)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
            SidebarModel.shared.refreshTabs()
        }
        controllers.append(controller)
        let theme = self.theme(for: controller)
        controller.apply(scheme: theme.isDark ? .dark : .light, palette: theme.palette, appearance: forcedAppearance)
        if let host, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
        }
        controller.hideNativeTabBar()
        controller.focus()
        SidebarModel.shared.refreshTabs()
        return controller
    }


    @objc func toggleQuickTerminal(_ sender: Any?) { QuickTerminal.shared.toggle() }


    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Tab Theme" else { return }
        menu.removeAllItems()
        let current = keyController?.themeOverride
        let follow = NSMenuItem(title: "Same as App", action: #selector(setTabTheme(_:)), keyEquivalent: "")
        follow.target = self
        follow.state = current == nil ? .on : .off
        menu.addItem(follow)
        menu.addItem(.separator())
        for t in Settings.shared.allThemes {
            let item = NSMenuItem(title: t.name, action: #selector(setTabTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t.name
            item.state = current == t.name ? .on : .off
            menu.addItem(item)
        }
    }

    @objc func setTabTheme(_ sender: NSMenuItem) {
        keyController?.themeOverride = sender.representedObject as? String
    }

    func setTheme(_ name: String?, forTab id: ObjectIdentifier) {
        controllers.first { ObjectIdentifier($0) == id }?.themeOverride = name
    }

    @objc func toggleSidebar(_ sender: Any?) {
        let model = SidebarModel.shared
        model.visible.toggle()
        for c in controllers { c.setSidebar(visible: model.visible, animated: c.window?.isKeyWindow == true) }
    }

    private var tabOrder: [TerminalWindowController] {
        var seen = Set<ObjectIdentifier>(), out: [TerminalWindowController] = []
        for c in controllers where !seen.contains(ObjectIdentifier(c)) {
            let group = (c.window?.tabbedWindows ?? []).compactMap { $0.windowController as? TerminalWindowController }
            for t in group.isEmpty ? [c] : group where !seen.contains(ObjectIdentifier(t)) {
                seen.insert(ObjectIdentifier(t)); out.append(t)
            }
        }
        return out
    }

    private func openTabs() -> [OpenTab] {
        let home = SidebarModel.home
        return tabOrder.map { c in
            c.refreshTitle()
            c.refreshBusy()
            let dir = c.currentDirectory ?? ""
            let shown = c.session.machine.map { "\($0.name): " + remoteTilde(dir) } ?? SidebarModel.tilde(dir)
            return OpenTab(id: ObjectIdentifier(c), title: c.customTitle ?? c.displayTitle,
                           command: c.session.process?.foregroundCommand ?? "",
                           directory: shown, isKey: c.window?.isKeyWindow == true,
                           attention: AttentionCenter.shared.needsAttention(c),
                           panes: c.panes.count, parked: c.hasParkedPane, branch: c.worktree?.branch,
                           busy: c.busy,
                           hostIDs: c.panes.filter { $0.session.machine == nil }.compactMap { $0.session.process?.hostSessionID },
                           remoteIDs: c.panes.compactMap { p in
                               guard let m = p.session.machine, let id = p.session.process?.hostSessionID else { return nil }
                               return "\(m.id)/\(id)"
                           },
                           path: dir, machineID: c.session.machine?.id,
                           group: c.window?.tabGroup.map { ObjectIdentifier($0) })
        }
    }

    private func installTabDoubleClick() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard event.clickCount == 2, let window = event.window,
                  let frame = window.contentView?.superview else { return event }
            var view = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
            while let v = view {
                let name = NSStringFromClass(type(of: v))
                if name.contains("TabButton") || name.contains("TabBarItem") {
                    MainActor.assumeIsolated { self?.renameCurrentTab(nil) }
                    return nil
                }
                view = v.superview
            }
            return event
        }
    }

    @objc func renameCurrentTab(_ sender: Any?) {
        if let c = keyController { rename(c) }
    }

    func renameTab(_ id: ObjectIdentifier) {
        if let c = controllers.first(where: { ObjectIdentifier($0) == id }) { rename(c) }
    }

    private func rename(_ c: TerminalWindowController) {
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to go back to the automatic name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = c.customTitle ?? c.displayTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.customTitle = name.isEmpty ? nil : name
        SidebarModel.shared.refreshTabs()
    }

    func closeTab(_ id: ObjectIdentifier) {
        controllers.first { ObjectIdentifier($0) == id }?.window?.performClose(nil)
    }

    func focusTab(_ id: ObjectIdentifier) {
        controllers.first { ObjectIdentifier($0) == id }?.focus()
    }

    func reorderTab(_ id: ObjectIdentifier, before target: ObjectIdentifier) {
        guard let moving = controllers.first(where: { ObjectIdentifier($0) == id })?.window,
              let anchor = controllers.first(where: { ObjectIdentifier($0) == target })?.window,
              let group = anchor.tabGroup, moving !== anchor else { return }
        if moving.tabGroup === group { group.removeWindow(moving) }
        let index = group.windows.firstIndex(of: anchor) ?? group.windows.count
        group.insertWindow(moving, at: index)
        (moving.windowController as? TerminalWindowController)?.focus()
        SidebarModel.shared.refreshTabs()
    }

    @objc func selectTabNumber(_ sender: NSMenuItem) {
        guard let window = keyController?.window else { return }
        let tabs = window.tabbedWindows ?? [window]
        guard !tabs.isEmpty else { return }
        let n = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        guard n >= 0, n < tabs.count, let c = tabs[n].windowController as? TerminalWindowController else { return }
        c.focus()
    }

    @objc func showSearch(_ sender: Any?) { keyController?.showPalette() }

    @objc func showReminders(_ sender: Any?) { keyController?.showRemindersPage() }

    func attachHost(_ session: SessionInfo) {
        let dir = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : SidebarModel.home
        open(tabbedWith: keyController?.window, layout: .pane(directory: dir, history: nil, host: session.id))
        SidebarModel.shared.background.removeAll { $0.id == session.id }
    }

    func killHost(_ id: String) {
        HostAttachment.send(Message(op: "kill", id: id))
        SidebarModel.shared.background.removeAll { $0.id == id }
    }

    func attachRemote(_ machine: RemoteMachine, _ session: SessionInfo) {
        let key = "\(machine.id)/\(session.id)"
        if let tab = SidebarModel.shared.tabs.first(where: { $0.remoteIDs.contains(key) }) { focusTab(tab.id); return }
        open(tabbedWith: keyController?.window,
             layout: .pane(directory: session.cwd, history: nil, host: session.id, machine: machine.id))
    }

    func killRemote(_ machine: RemoteMachine, _ id: String) {
        SidebarModel.shared.monitor(machine.id)?.send(Message(op: "kill", id: id))
        SidebarModel.shared.monitor(machine.id)?.refresh()
    }

    func newRemote(_ machine: RemoteMachine, agent: String?, directory: String?) {
        open(tabbedWith: keyController?.window, directory: directory, machine: machine, agent: agent)
    }

    func resume(_ session: SessionItem) {
        var cmd = session.tool == "claude" ? "claude --resume \(shellQuote(session.id))" : "codex resume \(shellQuote(session.id))"
        if session.tool == "gemini" {
            guard let g = SidebarModel.shared.gemini[session.id], g.resumable else {
                if let g = SidebarModel.shared.gemini[session.id] { GeminiReader.show(g) }
                return
            }
            cmd = "gemini --resume \(shellQuote(session.id))"
        }
        let dir = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : SidebarModel.home
        let c = open(tabbedWith: keyController?.window, directory: dir, command: cmd)
        c.setResumeOf(session.id)
    }

    func openMoved(directory: String, command: String, conversation: String) {
        let c = open(tabbedWith: keyController?.window, directory: directory, command: command)
        c.setResumeOf(conversation)
    }

    func moveToMac(_ machine: RemoteMachine, sessionID: String) {
        HandoffCoordinator.moveToMac(machine, sessionID: sessionID)
    }

    func moveTab(_ id: ObjectIdentifier, to machine: RemoteMachine) {
        guard let c = controllers.first(where: { ObjectIdentifier($0) == id }) else { return }
        HandoffCoordinator.moveTab(c, to: machine)
    }

    func resumeRemote(_ machine: RemoteMachine, _ item: HistoryItem) {
        let cmd = item.agent == "claude" ? "claude --resume \(shellQuote(item.id))" : "codex resume \(shellQuote(item.id))"
        let c = open(tabbedWith: keyController?.window, directory: item.cwd, machine: machine, agent: cmd)
        c.setResumeOf(item.id)
    }


    func agentRequest(id: String, tool: String, args json: String, from controller: TerminalWindowController) {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        if ProcessInfo.processInfo.environment["TERMAPP_SCRIPT"] != nil { print("agent request: \(tool) \(json)"); fflush(stdout) }
        func reply(_ text: String, failed: Bool = false) {
            HostAttachment.send(Message(op: "agent-reply", id: id, code: failed ? 1 : 0, message: text))
        }
        let here = controller.currentDirectory ?? SidebarModel.home
        switch tool {
        case "open_tab":
            var dir = (args["directory"] as? String).map { ($0 as NSString).expandingTildeInPath } ?? here
            if !dir.hasPrefix("/") { dir = (here as NSString).appendingPathComponent(dir) }
            guard FileManager.default.fileExists(atPath: dir) else { reply("No folder at \(dir).", failed: true); return }
            let command = (args["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let c = open(tabbedWith: controller.window, directory: dir, command: command)
            if let title = args["title"] as? String, !title.isEmpty { c.customTitle = title }
            controller.focus()
            reply("Opened a tab in \(dir)" + (command.map { " running \($0)" } ?? "") + ".")
        case "start_worktree":
            guard let branch = (args["branch"] as? String)?.trimmingCharacters(in: .whitespaces), !branch.isEmpty else {
                reply("Give a branch name.", failed: true); return
            }
            guard Git.root(of: here) != nil else { reply("\(here) isn't a git repository.", failed: true); return }
            let task = (args["task"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let command: String?
            switch args["agent"] as? String ?? "claude" {
            case "shell": command = nil
            case "codex": command = "codex" + (task.map { " " + shellQuote($0) } ?? "")
            default: command = "claude" + (task.map { " " + shellQuote($0) } ?? "")
            }
            switch Worktrees.create(repo: here, branch: branch) {
            case .failure(let error): reply("Couldn't create the worktree: \(error.message)", failed: true)
            case .success(let info):
                let c = open(tabbedWith: controller.window, directory: info.path, command: command)
                c.worktree = info
                reply("Started a worktree tab on branch \(info.branch) at \(info.path)" + (command.map { ", running \($0.split(separator: " ").first ?? "")" } ?? "") + ".")
            }
        default:
            reply("Unknown request \(tool).", failed: true)
        }
    }


    func fork(_ session: SessionItem, inWorktree: Bool) {
        let cmd = session.tool == "claude" ? "claude --resume \(shellQuote(session.id)) --fork-session"
                                           : "codex fork \(shellQuote(session.id))"
        let dir = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : SidebarModel.home
        guard inWorktree else {
            let c = open(tabbedWith: keyController?.window, directory: dir, command: cmd)
            c.customTitle = "Fork: " + session.title
            return
        }
        guard Git.root(of: dir) != nil else {
            alert("Not in a git repository", "\(dir) isn't a git repository, so the fork can't have its own worktree. Fork it in a new tab instead.")
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        switch Worktrees.create(repo: dir, branch: "fork/\(f.string(from: Date()))") {
        case .failure(let error):
            alert("Could not create the worktree", error.message)
        case .success(let info):
            if session.tool == "claude" { Self.copyClaudeSession(session.id, from: session.cwd, to: info.path) }
            let c = open(tabbedWith: keyController?.window, directory: info.path, command: cmd)
            c.worktree = info
            c.customTitle = "Fork: " + session.title
        }
    }

    func forkTab(_ id: ObjectIdentifier, inWorktree: Bool) {
        guard let c = controllers.first(where: { ObjectIdentifier($0) == id }),
              case .file(let agent, let path, _) = c.focused?.readerSource() ?? .none, agent == "claude" else {
            alert("No conversation to fork", "Fork works on a Claude Code conversation running in the tab.")
            return
        }
        let sid = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        let cwd = c.currentDirectory ?? SidebarModel.home
        fork(SessionItem(tool: "claude", id: sid, cwd: cwd, repo: (cwd as NSString).lastPathComponent,
                         title: c.customTitle ?? c.displayTitle, mtime: 0, linked: [], pair: nil), inWorktree: inWorktree)
    }

    static func copyClaudeSession(_ id: String, from: String, to: String) {
        func folder(_ dir: String) -> String {
            (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? Transcript.home + "/.claude") + "/projects/"
                + String(dir.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        }
        let src = folder(from) + "/" + id + ".jsonl"
        let dstDir = folder(to)
        try? FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: src, toPath: dstDir + "/" + id + ".jsonl")
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
        PairRunWindows.show(run)
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
        appMenu.addItem(withTitle: "About Terminess", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "What\u{2019}s New", action: #selector(TerminalWindowController.showWhatsNew(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Pair iPhone…", action: #selector(showPairPhone(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Make Terminess the Default Terminal…", action: #selector(makeDefaultTerminal(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let shellItem = NSMenuItem()
        let shell = NSMenu(title: "Shell")
        shell.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        shell.addItem(withTitle: "New Tab", action: #selector(newWindowForTab(_:)), keyEquivalent: "t")
        let worktreeTab = NSMenuItem(title: "New Worktree Tab…", action: #selector(newWorktreeTab(_:)), keyEquivalent: "t")
        worktreeTab.keyEquivalentModifierMask = [.command, .option]
        shell.addItem(worktreeTab)
        let commit = NSMenuItem(title: "Commit Changes…", action: #selector(commitChanges(_:)), keyEquivalent: "c")
        commit.keyEquivalentModifierMask = [.command, .option]
        shell.addItem(commit)
        let pr = NSMenuItem(title: "Open Pull Request…", action: #selector(openPullRequest(_:)), keyEquivalent: "p")
        pr.keyEquivalentModifierMask = [.command, .option]
        shell.addItem(pr)
        let board = NSMenuItem(title: "Issues Board", action: #selector(showIssueBoard(_:)), keyEquivalent: "i")
        board.keyEquivalentModifierMask = [.command, .option]
        shell.addItem(board)
        let agentItem = NSMenuItem(title: "New Agent Tab", action: nil, keyEquivalent: "")
        let agentMenu = NSMenu(title: "New Agent Tab")
        for (title, model) in [("Claude Opus 5.5", "claude-opus-5-5"), ("Claude Sonnet 5.5", "claude-sonnet-5-5"), ("Claude Haiku 5.5", "claude-haiku-5-5")] {
            let item = agentMenu.addItem(withTitle: title, action: #selector(newAgentTab(_:)), keyEquivalent: "")
            item.representedObject = model
        }
        agentMenu.addItem(.separator())
        agentMenu.addItem(withTitle: "Uses your Anthropic API key (Settings). Type /model ollama:NAME for a local model.", action: nil, keyEquivalent: "")
        agentItem.submenu = agentMenu
        shell.addItem(agentItem)
        let localModel = NSMenuItem(title: "Local Model", action: nil, keyEquivalent: "")
        let localModelMenu = NSMenu(title: "Local Model")
        LocalModelMenu.shared.attach(to: localModelMenu)
        localModel.submenu = localModelMenu
        shell.addItem(localModel)
        shell.addItem(withTitle: "Show Quick Terminal", action: #selector(toggleQuickTerminal(_:)), keyEquivalent: "")
        shell.addItem(.separator())
        let tabTheme = NSMenuItem(title: "Tab Theme", action: nil, keyEquivalent: "")
        let tabThemeMenu = NSMenu(title: "Tab Theme")
        tabThemeMenu.delegate = self
        tabTheme.submenu = tabThemeMenu
        shell.addItem(tabTheme)
        let rename = NSMenuItem(title: "Rename Tab…", action: #selector(renameCurrentTab(_:)), keyEquivalent: "r")
        rename.keyEquivalentModifierMask = [.command, .shift]
        shell.addItem(rename)
        shell.addItem(.separator())
        shell.addItem(withTitle: "Split Right", action: #selector(TerminalWindowController.splitRight(_:)), keyEquivalent: "d")
        let splitDown = NSMenuItem(title: "Split Down", action: #selector(TerminalWindowController.splitDown(_:)), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        shell.addItem(splitDown)
        let arrows: [(String, Selector, Int)] = [
            ("Select Pane Left", #selector(TerminalWindowController.focusLeft(_:)), NSLeftArrowFunctionKey),
            ("Select Pane Right", #selector(TerminalWindowController.focusRight(_:)), NSRightArrowFunctionKey),
            ("Select Pane Above", #selector(TerminalWindowController.focusUp(_:)), NSUpArrowFunctionKey),
            ("Select Pane Below", #selector(TerminalWindowController.focusDown(_:)), NSDownArrowFunctionKey),
        ]
        for (title, sel, key) in arrows {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: String(Character(UnicodeScalar(key)!)))
            item.keyEquivalentModifierMask = [.command, .option]
            shell.addItem(item)
        }
        shell.addItem(.separator())
        shell.addItem(withTitle: "Close", action: #selector(TerminalWindowController.closePaneOrTab(_:)), keyEquivalent: "w")
        shellItem.submenu = shell
        main.addItem(shellItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(TerminalView.showFind(_:)), keyEquivalent: "f")
        edit.addItem(withTitle: "Find Next", action: #selector(TerminalView.findNext(_:)), keyEquivalent: "g")
        let findPrev = NSMenuItem(title: "Find Previous", action: #selector(TerminalView.findPrevious(_:)), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(findPrev)
        let copyOutput = NSMenuItem(title: "Copy Last Command's Output", action: #selector(TerminalView.copyLastOutput(_:)), keyEquivalent: "c")
        copyOutput.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(copyOutput)
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
        view.addItem(withTitle: "Previous Prompt", action: #selector(TerminalView.previousPrompt(_:)),
                     keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        view.addItem(withTitle: "Next Prompt", action: #selector(TerminalView.nextPrompt(_:)),
                     keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        view.addItem(.separator())
        for (title, sel, key) in [("Terminal", #selector(TerminalWindowController.showTerminalMode(_:)), "1"),
                                  ("Terminal and Chat", #selector(TerminalWindowController.showSplitMode(_:)), "2"),
                                  ("Chat", #selector(TerminalWindowController.showChatMode(_:)), "3")] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .option]
            view.addItem(item)
        }
        view.addItem(.separator())
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.control, .command]
        view.addItem(sidebarItem)
        let instructionsItem = NSMenuItem(title: "Project Instructions…", action: #selector(showProjectInstructions(_:)), keyEquivalent: "i")
        instructionsItem.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(instructionsItem)
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

        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Doctor…", action: #selector(showDoctor(_:)), keyEquivalent: "")
        helpItem.submenu = help

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{")
        window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}")
        for n in 1...9 {
            let item = window.addItem(withTitle: n == 9 ? "Show Last Tab" : "Show Tab \(n)",
                                      action: #selector(selectTabNumber(_:)), keyEquivalent: "\(n)")
            item.tag = n
        }
        window.addItem(.separator())
        window.addItem(withTitle: "Search…", action: #selector(showSearch(_:)), keyEquivalent: "k")
        window.addItem(withTitle: "Reminders", action: #selector(showReminders(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Library…", action: #selector(showLibrary(_:)), keyEquivalent: "L")
        window.addItem(withTitle: "Operations Guide…", action: #selector(showOpsGuide(_:)), keyEquivalent: "")
        let agents = window.addItem(withTitle: "Agents", action: #selector(showAgentsDashboard(_:)), keyEquivalent: "a")
        agents.keyEquivalentModifierMask = [.command, .option]
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        main.addItem(helpItem)
        NSApp.helpMenu = help

        return main
    }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
