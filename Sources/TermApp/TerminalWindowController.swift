import AppKit
import SwiftUI
import TermCore
import TermTranscript
import TermHost

@MainActor
final class Pane {
    let session: TerminalSession
    let view: TerminalView
    var programTitle = ""
    var transcript: (pid: Int32, agent: String, path: String)?
    var parked: (tool: String, id: String)? {
        didSet { view.parkedNotice = parked.map { "Parked to free memory. It resumes \($0.tool == "claude" ? "Claude Code" : "Codex") when you come back." } }
    }

    init(columns: Int, rows: Int) {
        session = TerminalSession(columns: columns, rows: rows)
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.session = session
    }

    var currentDirectory: String? {
        session.process?.foregroundDirectory ?? session.currentDirectory
    }

    func resumeCommand() -> String? {
        if let p = parked { return p.tool == "claude" ? "claude --resume \(shellQuote(p.id))" : "codex resume \(shellQuote(p.id))" }
        guard let process = session.process, let agent = Agent.detect(process.foregroundCommand) else { return nil }
        if agent.id == "claude" {
            let path = Transcript.claudeSession(pid: process.foregroundPID) ?? (transcript?.pid == process.foregroundPID ? transcript?.path : nil)
            guard let path else { return nil }
            let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return "claude --resume \(shellQuote(id))"
        }
        if agent.id == "codex", let t = transcript, t.pid == process.foregroundPID {
            let name = ((t.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let id = String(name.suffix(36))
            guard UUID(uuidString: id) != nil else { return nil }
            return "codex resume \(id)"
        }
        return nil
    }

    func readerSource() -> ReaderSource {
        guard let process = session.process else { return .none }
        if process.foregroundCommand == "ollama", let id = process.hostSessionID, let p = LocalChat.latest(for: id) {
            return .file(agent: "ollama", path: p, live: true)
        }
        if let agent = Agent.detect(process.foregroundCommand), agent.id == "claude" || agent.id == "codex",
           let dir = currentDirectory {
            let pid = process.foregroundPID
            if agent.id == "claude", let p = Transcript.claudeSession(pid: pid) {
                transcript = (pid, "claude", p)
                return .file(agent: "claude", path: p, live: true)
            }
            if let t = transcript, t.pid == pid { return .file(agent: t.agent, path: t.path, live: true) }
            return .find(agent: agent.id, directory: dir, pid: pid,
                         started: Date(timeIntervalSince1970: process.foregroundStartTime ?? Date().timeIntervalSince1970),
                         arguments: process.foregroundArguments)
        }
        if let t = transcript { return .file(agent: t.agent, path: t.path, live: false) }
        return .none
    }
}

enum ReaderSource {
    case none
    case file(agent: String, path: String, live: Bool)
    case find(agent: String, directory: String, pid: Int32, started: Date, arguments: [String])
}

indirect enum PaneLayout: Codable {
    case pane(directory: String, history: String?, host: String? = nil, resume: String? = nil)
    case split(vertical: Bool, children: [PaneLayout], fractions: [Double])
}

final class PaneHostView: NSView {
    private var blur: NSVisualEffectView?

    var root: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let root {
                root.frame = bounds
                root.autoresizingMask = [.width, .height]
                addSubview(root)
            }
        }
    }

    var translucent = false {
        didSet {
            guard translucent != oldValue else { return }
            if translucent {
                let v = NSVisualEffectView(frame: bounds)
                v.autoresizingMask = [.width, .height]
                v.material = .underWindowBackground
                v.blendingMode = .behindWindow
                v.state = .active
                addSubview(v, positioned: .below, relativeTo: nil)
                blur = v
            } else {
                blur?.removeFromSuperview()
                blur = nil
            }
        }
    }
}

final class ContentContainer: NSView {
    let split = NSSplitView()
    var drops: WindowLink?
    let strip = StatusStripView()
    var showStrip = false { didSet { strip.isHidden = !showStrip; needsLayout = true } }
    var composer: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let composer { addSubview(composer) }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        split.isVertical = true
        split.dividerStyle = .thin
        addSubview(split)
        strip.isHidden = true
        addSubview(strip)
        registerForDraggedTypes(Drops.pasteboardTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        drops?.drop(sender.draggingPasteboard) ?? false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        var h: CGFloat = 0
        if let composer {
            h = min(composer.fittingSize.height, 200)
            composer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        }
        if showStrip {
            let sh = strip.intrinsicContentSize.height
            strip.frame = NSRect(x: 0, y: h, width: bounds.width, height: sh)
            h += sh
        }
        split.frame = NSRect(x: 0, y: h, width: bounds.width, height: bounds.height - h)
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let container = ContentContainer()
    private let drops = WindowLink()
    let reader = ReaderModel()
    let composerState = ComposerState()
    private var readerHost: NSView?
    private(set) var panes: [Pane] = []
    private(set) var focused: Pane!
    private let host = PaneHostView()
    private let split = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    var onClose: (() -> Void)?
    var worktree: WorktreeInfo? { didSet { SidebarModel.shared.refreshTabs() } }
    var themeOverride: String? {
        didSet { (NSApp.delegate as? AppDelegate)?.applyAppearance() }
    }
    var customTitle: String? { didSet { refreshTitle() } }
    private(set) var agent: Agent?
    private(set) var displayTitle = "shell"

    var paneHost: NSView { host }
    var contentContainer: NSView { container }

    var session: TerminalSession { focused.session }
    var terminalView: TerminalView { focused.view }

    static let sidebarWidth: CGFloat = 260
    private static let toggleItem = NSToolbarItem.Identifier("toggleSidebar")
    private static let modeItem = NSToolbarItem.Identifier("viewMode")

    init(workingDirectory: String?, command: String? = nil, layout: PaneLayout? = nil) {
        let sidebarHost = NSHostingController(rootView: SidebarView(model: SidebarModel.shared, drops: drops))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !SidebarModel.shared.visible

        let content = NSViewController()
        content.view = container
        container.split.addSubview(host)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 300
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)

        let probe = TerminalView(frame: .zero)
        var size = probe.contentSize(columns: 100, rows: 30)
        if SidebarModel.shared.visible { size.width += TerminalWindowController.sidebarWidth }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "terminal"
        window.title = "Terminess"
        window.backgroundColor = probe.backgroundNSColor
        window.contentViewController = split
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName("TerminalWindow")
        super.init(window: window)
        window.delegate = self
        container.drops = drops
        reader.drops = drops
        composerState.drops = drops
        drops.handler = { [weak self] pb in self?.acceptDrop(pb) ?? false }
        drops.owner = ObjectIdentifier(self)

        let toolbar = NSToolbar(identifier: "terminal")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        if let layout {
            host.root = build(layout)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyFractions(layout, to: self?.host.root) }
            }
        } else {
            let pane = makePane(directory: workingDirectory, command: command)
            host.root = pane.view
        }
        focusPane(panes[0])
        reader.follow { [weak self] in self?.focused?.readerSource() }
        reader.activity = { [weak self] in self?.focused?.session.lastActivity }
        reader.onFound = { [weak self] pid, agent, path in
            self?.focused?.transcript = (pid, agent, path)
        }
        setMode(ViewMode(rawValue: UserDefaults.standard.integer(forKey: "viewMode")) ?? .terminal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }


    enum ViewMode: Int { case terminal = 0, split = 1, chat = 2 }
    private(set) var mode: ViewMode = .terminal
    private var modeControl: NSSegmentedControl?
    private var revealedForQuestion = false
    private var questionTimer: DispatchWorkItem?

    func setMode(_ m: ViewMode) {
        mode = m
        modeControl?.selectedSegment = m.rawValue
        UserDefaults.standard.set(m.rawValue, forKey: "viewMode")
        revealedForQuestion = false
        switch m {
        case .terminal:
            showHost(true)
            setReader(visible: false)
            setComposer(visible: false)
            container.showStrip = false
        case .split:
            showHost(true)
            setReader(visible: true)
            setComposer(visible: true)
            container.showStrip = true
        case .chat:
            setReader(visible: true)
            showHost(false)
            setComposer(visible: true)
            container.showStrip = true
        }
        updateInputHiding()
        container.needsLayout = true
        if m == .terminal { focus() }
    }

    private func showHost(_ show: Bool) {
        let split = container.split
        let inSplit = host.superview === split
        if show && !inSplit {
            split.addSubview(host, positioned: .below, relativeTo: split.subviews.first)
            split.adjustSubviews()
            if readerHost != nil {
                let total = split.bounds.width
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { split.setPosition(total * 0.5, ofDividerAt: 0) }
                }
            }
        } else if !show && inSplit {
            host.removeFromSuperview()
            split.adjustSubviews()
        }
    }

    @objc func showTerminalMode(_ sender: Any?) { setMode(.terminal) }
    @objc func showSplitMode(_ sender: Any?) { setMode(.split) }
    @objc func showChatMode(_ sender: Any?) { setMode(.chat) }
    @objc func modeChanged(_ sender: NSSegmentedControl) {
        setMode(ViewMode(rawValue: sender.selectedSegment) ?? .terminal)
    }

    private func agentScreenChanged(inputVisible: Bool, status: [Row]) {
        container.strip.palette = session.terminal.palette
        container.strip.native = Settings.shared.statusStyle == "native"
        container.strip.rows = status
        container.needsLayout = true
        guard mode == .chat, Agent.detect(session.process?.foregroundCommand) != nil else { return }
        questionTimer?.cancel()
        if !inputVisible && !revealedForQuestion {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.mode == .chat else { return }
                    self.revealedForQuestion = true
                    self.showHost(true)
                    self.focus()
                }
            }
            questionTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else if inputVisible && revealedForQuestion {
            revealedForQuestion = false
            showHost(false)
        }
    }

    var readerVisible: Bool { readerHost != nil }
    var composerVisible: Bool { container.composer != nil }

    func setReader(visible: Bool) {
        guard visible != readerVisible else { return }
        if visible {
            let v = NSHostingView(rootView: ReaderView(model: reader))
            let split = container.split
            let total = max(split.bounds.width, window?.contentLayoutRect.width ?? 1000)
            let readerWidth = min(520, max(320, total * 0.42))
            v.frame = NSRect(x: total - readerWidth, y: 0, width: readerWidth, height: split.bounds.height)
            host.frame.size.width = total - readerWidth - split.dividerThickness
            split.addSubview(v)
            readerHost = v
            split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
            split.setHoldingPriority(.init(260), forSubviewAt: 0)
            split.adjustSubviews()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { split.setPosition(total - readerWidth, ofDividerAt: 0) }
            }
        } else {
            readerHost?.removeFromSuperview()
            readerHost = nil
        }
        reader.visible = visible
    }

    func updateInputHiding() {
        let on = mode != .terminal && Settings.shared.composerHidesAgentInput
        for p in panes {
            let agent = Agent.detect(p.session.process?.foregroundCommand)?.id
            let isAgent = agent == "claude" || agent == "codex"
            p.view.hideAgentInput = on && isAgent
            p.view.hideAgentStatus = on && isAgent
            p.view.onAgentScreen = p === focused ? { [weak self] visible, status, busy in
                self?.composerState.busy = busy
                self?.agentScreenChanged(inputVisible: visible, status: status)
            } : nil
        }
        focused?.view.updateAgentScreen()
    }

    func setComposer(visible: Bool) {
        defer { updateInputHiding() }
        guard visible != composerVisible else { return }
        if visible {
            let view = NSHostingView(rootView: ComposerView(placeholder: "Message the agent in this tab",
                state: composerState,
                onSend: { [weak self] text in self?.sendFromComposer(text) },
                onStop: { [weak self] in self?.interruptAgent() },
                onEscape: { [weak self] in self?.focus() }))
            container.composer = view
        } else {
            container.composer = nil
            focus()
        }
    }

    func interruptAgent() {
        guard let pane = focused else { return }
        pane.session.send([0x1B])
    }

    func acceptDrop(_ pb: NSPasteboard) -> Bool {
        guard let text = Drops.text(from: pb), !text.isEmpty else { return false }
        if composerVisible {
            let draft = composerState.draft
            let gap = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
            composerState.draft = draft + gap + text + " "
            return true
        }
        guard let pane = focused else { return false }
        if pane.parked != nil { resume(pane) }
        pane.session.send(InputEncoder.paste(text + " ", modes: pane.session.terminal.modes))
        window?.makeFirstResponder(pane.view)
        return true
    }

    func sendFromComposer(_ text: String) {
        guard let pane = focused else { return }
        if pane.parked != nil { resume(pane) }
        let t = pane.session.terminal
        pane.session.send(InputEncoder.paste(text, modes: t.modes))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { pane.session.send([0x0D]) }
        }
    }

    @objc func toggleReader(_ sender: Any?) { setMode(mode == .terminal ? .split : .terminal) }


    private func makePane(directory: String?, command: String?, history: String? = nil, attach: String? = nil,
                          resumeIfGone: String? = nil) -> Pane {
        let pane = Pane(columns: 100, rows: 30)
        let view = pane.view, session = pane.session
        if attach == nil, let history, !history.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let body = history.replacingOccurrences(of: "\n", with: "\r\n")
            session.terminal.feed("\u{1B}[2m\(body)\r\n\u{1B}[0;2;3mRestored from the previous session\u{1B}[0m\r\n\r\n")
        }
        session.onUpdate = { [weak view] in view?.terminalDidUpdate() }
        session.onTitle = { [weak self, weak pane] t in
            pane?.programTitle = t
            if pane === self?.focused { self?.refreshTitle() }
        }
        session.onBell = { [weak self, weak pane] in
            guard let self, let pane else { return }
            AttentionCenter.shared.alert(controller: self, pane: pane, title: self.displayTitle, body: "Bell")
        }
        session.onNotify = { [weak self, weak pane] title, body in
            guard let self, let pane else { return }
            AttentionCenter.shared.alert(controller: self, pane: pane, title: title.isEmpty ? self.displayTitle : title,
                                         body: body, always: true)
        }
        session.onCommandFinished = { [weak self, weak pane] seconds, status in
            guard let self, let pane, seconds >= 10 else { return }
            let what = status == 0 ? "Finished" : "Failed (exit \(status))"
            AttentionCenter.shared.alert(controller: self, pane: pane, title: self.displayTitle,
                                         body: "\(what) after \(Int(seconds))s")
        }
        session.onExit = { [weak self, weak pane] _ in
            guard let self, let pane else { return }
            self.closePane(pane)
        }
        view.onFocus = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.focusPane(pane)
        }
        panes.append(pane)
        session.start(workingDirectory: directory,
                      cellWidth: Int(view.cellSize.width.rounded()), cellHeight: Int(view.cellSize.height.rounded()),
                      attach: attach, resumeIfGone: resumeIfGone)
        if let command {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak session] in
                MainActor.assumeIsolated { session?.send(Array((command + "\r").utf8)) }
            }
        }
        if let app = NSApp.delegate as? AppDelegate {
            let theme = app.theme(for: self)
            session.terminal.setColorScheme(theme.isDark ? .dark : .light, palette: theme.palette)
        }
        return pane
    }

    func focusPane(_ pane: Pane) {
        focused = pane
        if pane.parked != nil && window?.isKeyWindow == true { resume(pane) }
        for p in panes { p.view.dimmed = panes.count > 1 && p !== pane }
        if window?.firstResponder !== pane.view { window?.makeFirstResponder(pane.view) }
        AttentionCenter.shared.clear(pane: pane)
        refreshTitle()
        if reader.visible { reader.refresh(force: true) }
        updateInputHiding()
    }

    @objc func splitRight(_ sender: Any?) { splitFocused(vertical: true) }
    @objc func splitDown(_ sender: Any?) { splitFocused(vertical: false) }

    private func splitFocused(vertical: Bool) {
        let target = focused.view
        let pane = makePane(directory: focused.currentDirectory, command: nil)
        if let sv = target.superview as? NSSplitView, sv.isVertical == vertical {
            sv.addSubview(pane.view, positioned: .above, relativeTo: target)
            equalize(sv)
        } else {
            let sv = NSSplitView(frame: target.frame)
            sv.isVertical = vertical
            sv.dividerStyle = .thin
            sv.autoresizingMask = target.autoresizingMask
            if host.root === target {
                host.root = sv
            } else {
                target.superview?.replaceSubview(target, with: sv)
            }
            sv.addSubview(target)
            sv.addSubview(pane.view)
            equalize(sv)
        }
        focusPane(pane)
    }

    private func equalize(_ sv: NSSplitView) {
        sv.adjustSubviews()
        let n = sv.subviews.count
        guard n > 1 else { return }
        let total = (sv.isVertical ? sv.bounds.width : sv.bounds.height) - sv.dividerThickness * CGFloat(n - 1)
        for i in 0..<(n - 1) {
            sv.setPosition(total * CGFloat(i + 1) / CGFloat(n) + sv.dividerThickness * CGFloat(i), ofDividerAt: i)
        }
    }

    @objc func closePaneOrTab(_ sender: Any?) {
        if panes.count > 1 { closePane(focused) } else { window?.performClose(sender) }
    }

    func closePane(_ pane: Pane) {
        guard panes.count > 1 else { window?.close(); return }
        let view = pane.view
        pane.session.close()
        panes.removeAll { $0 === pane }
        AttentionCenter.shared.clear(pane: pane)
        if let sv = view.superview as? NSSplitView {
            view.removeFromSuperview()
            if sv.subviews.count == 1 {
                let only = sv.subviews[0]
                only.removeFromSuperview()
                if host.root === sv {
                    host.root = only
                } else {
                    only.frame = sv.frame
                    only.autoresizingMask = sv.autoresizingMask
                    sv.superview?.replaceSubview(sv, with: only)
                }
            } else {
                equalize(sv)
            }
        }
        focusPane(panes.last!)
    }

    @objc func focusLeft(_ sender: Any?) { moveFocus(dx: -1, dy: 0) }
    @objc func focusRight(_ sender: Any?) { moveFocus(dx: 1, dy: 0) }
    @objc func focusUp(_ sender: Any?) { moveFocus(dx: 0, dy: -1) }
    @objc func focusDown(_ sender: Any?) { moveFocus(dx: 0, dy: 1) }

    private func moveFocus(dx: CGFloat, dy: CGFloat) {
        guard panes.count > 1 else { return }
        func frame(_ p: Pane) -> NSRect { p.view.convert(p.view.bounds, to: nil) }
        let current = frame(focused)
        let centre = CGPoint(x: current.midX, y: current.midY)
        var best: (Pane, CGFloat)?
        for p in panes where p !== focused {
            let f = frame(p)
            let ok: Bool
            if dx < 0 { ok = f.maxX <= current.minX + 2 }
            else if dx > 0 { ok = f.minX >= current.maxX - 2 }
            else if dy < 0 { ok = f.maxY <= current.minY + 2 }
            else { ok = f.minY >= current.maxY - 2 }
            guard ok else { continue }
            let d = hypot(f.midX - centre.x, f.midY - centre.y)
            if best == nil || d < best!.1 { best = (p, d) }
        }
        if let (p, _) = best { focusPane(p) }
    }


    @discardableResult
    func park(_ pane: Pane, sessions: [SessionItem]) -> Bool {
        guard pane.parked == nil, let process = pane.session.process,
              let agent = Agent.detect(process.foregroundCommand), agent.id == "claude" || agent.id == "codex",
              let dir = pane.currentDirectory else { return false }
        guard let match = sessions.filter({ $0.tool == agent.id && $0.cwd == dir && $0.pair == nil })
                .max(by: { $0.mtime < $1.mtime }) else { return false }
        guard process.terminateForeground() else { return false }
        pane.parked = (agent.id, match.id)
        updateTabBadge()
        SidebarModel.shared.refreshTabs()
        return true
    }

    func resume(_ pane: Pane) {
        guard let p = pane.parked else { return }
        pane.parked = nil
        let cmd = p.tool == "claude" ? "claude --resume \(shellQuote(p.id))" : "codex resume \(shellQuote(p.id))"
        pane.session.send(Array((cmd + "\r").utf8))
        SidebarModel.shared.refreshTabs()
    }

    var hasParkedPane: Bool { panes.contains { $0.parked != nil } }


    func layout() -> PaneLayout { encode(host.root) }

    private static var resumed: Set<String> = []

    private func encode(_ view: NSView?) -> PaneLayout {
        if let sv = view as? NSSplitView {
            let sizes = sv.subviews.map { sv.isVertical ? $0.frame.width : $0.frame.height }
            let total = max(1, sizes.reduce(0, +))
            return .split(vertical: sv.isVertical, children: sv.subviews.map(encode), fractions: sizes.map { Double($0 / total) })
        }
        let pane = panes.first { $0.view === view }
        var history: String?
        if let t = pane?.session.terminal, !t.isAlternate {
            let lines = t.allText().split(separator: "\n", omittingEmptySubsequences: false).suffix(300)
            history = lines.joined(separator: "\n")
        }
        return .pane(directory: pane?.currentDirectory ?? Settings.shared.startDirectory, history: history,
                     host: pane?.session.process?.hostSessionID, resume: pane?.resumeCommand())
    }

    private func build(_ layout: PaneLayout) -> NSView {
        switch layout {
        case .pane(let dir, let history, let host, let resume):
            let exists = FileManager.default.fileExists(atPath: dir)
            var once: String?
            if exists, let resume, !Self.resumed.contains(resume) { Self.resumed.insert(resume); once = resume }
            return makePane(directory: exists ? dir : nil, command: nil, history: history, attach: host,
                            resumeIfGone: once).view
        case .split(let vertical, let children, _):
            let sv = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            sv.isVertical = vertical
            sv.dividerStyle = .thin
            for c in children { sv.addSubview(build(c)) }
            return sv
        }
    }

    private func applyFractions(_ layout: PaneLayout, to view: NSView?) {
        guard case .split(_, let children, let fractions) = layout, let sv = view as? NSSplitView else { return }
        sv.adjustSubviews()
        let total = (sv.isVertical ? sv.bounds.width : sv.bounds.height)
        var pos: CGFloat = 0
        for i in 0..<max(0, min(fractions.count, sv.subviews.count) - 1) {
            pos += total * CGFloat(fractions[i])
            sv.setPosition(pos, ofDividerAt: i)
        }
        for (i, c) in children.enumerated() where i < sv.subviews.count { applyFractions(c, to: sv.subviews[i]) }
    }


    func apply(scheme: TermCore.ColorScheme, palette: Palette, appearance: NSAppearance?) {
        window?.appearance = appearance
        container.strip.palette = palette
        container.strip.native = Settings.shared.statusStyle == "native"
        for p in panes {
            p.session.terminal.setColorScheme(scheme, palette: palette)
            p.view.needsDisplay = true
        }
        let translucent = Settings.shared.isModern && Settings.shared.backgroundOpacity < 1
        host.translucent = false
        window?.isOpaque = !translucent
        window?.backgroundColor = translucent
            ? terminalView.backgroundNSColor.withAlphaComponent(CGFloat(Settings.shared.backgroundOpacity))
            : terminalView.backgroundNSColor
        updateInputHiding()
        for p in panes { p.view.needsDisplay = true }
    }

    func setSidebar(visible: Bool, animated: Bool) {
        guard sidebarItem.isCollapsed == visible else { return }
        if animated { sidebarItem.animator().isCollapsed = !visible } else { sidebarItem.isCollapsed = !visible }
    }

    func refreshTitle() {
        guard let focused else { return }
        let command = focused.session.process?.foregroundCommand ?? ""
        let dir = currentDirectory ?? ""
        let folder = dir == SidebarModel.home ? "~" : (dir.split(separator: "/").last.map(String.init) ?? "")
        let found = Agent.detect(command)
        let title: String
        if let custom = customTitle, !custom.isEmpty {
            title = custom
        } else if let found {
            if let topic = Agent.topic(fromTitle: focused.programTitle, agentName: found.name) {
                title = topic
            } else {
                title = folder.isEmpty ? found.name : "\(found.name) · \(folder)"
            }
        } else if Agent.shells.contains(command) || command.isEmpty {
            title = folder.isEmpty ? "shell" : folder
        } else if !focused.programTitle.isEmpty {
            title = focused.programTitle
        } else {
            title = folder.isEmpty ? command : "\(command) · \(folder)"
        }
        if found != agent {
            agent = found
            updateTabBadge()
            if let id = found?.id { AgentEvents.started(id) }
        }
        updateInputHiding()
        displayTitle = title
        if window?.title != title { window?.title = title }
    }

    private(set) var busy = false

    func refreshBusy() {
        let now = panes.contains { Agent.detect($0.session.process?.foregroundCommand) != nil && $0.view.agentLooksBusy() }
        if now != busy {
            busy = now
            updateTabBadge()
        }
    }

    func updateTabBadge() {
        let attention = AttentionCenter.shared.needsAttention(self)
        if busy && !attention {
            let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            window?.tab.accessoryView = spinner
            return
        }
        let symbol = attention ? "circle.fill" : (agent != nil ? "sparkle" : nil)
        guard let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            window?.tab.accessoryView = nil
            return
        }
        let view = NSImageView(image: image)
        view.contentTintColor = attention ? .systemOrange : agent?.tint
        view.symbolConfiguration = .init(pointSize: attention ? 8 : 11, weight: .semibold)
        view.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        window?.tab.accessoryView = view
    }

    var currentDirectory: String? { focused?.currentDirectory }

    func focus() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(terminalView)
    }


    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TerminalWindowController.toggleItem, .flexibleSpace, TerminalWindowController.modeItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TerminalWindowController.toggleItem, .flexibleSpace, TerminalWindowController.modeItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == TerminalWindowController.modeItem {
            let images = ["terminal", "rectangle.split.2x1", "text.bubble"].map {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)!
            }
            let control = NSSegmentedControl(images: images, trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
            control.setToolTip("Terminal (Option-Command-1)", forSegment: 0)
            control.setToolTip("Terminal and Chat (Option-Command-2)", forSegment: 1)
            control.setToolTip("Chat (Option-Command-3)", forSegment: 2)
            control.selectedSegment = mode.rawValue
            modeControl = control
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = "View"
            return item
        }
        guard id == TerminalWindowController.toggleItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Sidebar"
        item.toolTip = "Show or hide the sidebar (Control-Command-S)"
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
        item.action = #selector(AppDelegate.toggleSidebar(_:))
        item.isBordered = true
        return item
    }


    func windowWillClose(_ notification: Notification) {
        for p in panes { p.session.close(); AttentionCenter.shared.clear(pane: p) }
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        terminalView.focusChanged(true)
        if let focused, focused.parked != nil { resume(focused) }
        if let focused { AttentionCenter.shared.clear(pane: focused) }
        SidebarModel.shared.refreshTabs()
    }

    func windowDidResignKey(_ notification: Notification) { terminalView.focusChanged(false) }
}
