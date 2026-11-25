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

    let reader = ReaderModel()
    let composerState = ComposerState()
    var readerView: NSView?
    var composerView: NSView?
    var chatColumn: ChatColumnView?
    var statusShownAt = Date.distantPast

    init(columns: Int, rows: Int) {
        session = TerminalSession(columns: columns, rows: rows)
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.session = session
    }

    var currentDirectory: String? {
        session.process?.foregroundDirectory ?? session.currentDirectory
    }

    func runningConversation() -> (tool: String, id: String)? {
        guard session.machine == nil else { return nil }
        guard let process = session.process, let agent = Agent.detect(process.foregroundCommand) else { return nil }
        if agent.id == "claude" {
            let path = Transcript.claudeSession(pid: process.foregroundPID) ?? (transcript?.pid == process.foregroundPID ? transcript?.path : nil)
            guard let path else { return nil }
            return ("claude", ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
        if agent.id == "codex", let t = transcript, t.pid == process.foregroundPID {
            let name = ((t.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let id = String(name.suffix(36))
            guard UUID(uuidString: id) != nil else { return nil }
            return ("codex", id)
        }
        return nil
    }

    func resumeCommand() -> String? {
        guard let c = parked ?? runningConversation() else { return nil }
        return c.tool == "claude" ? "claude --resume \(shellQuote(c.id))" : "codex resume \(shellQuote(c.id))"
    }

    func readerSource() -> ReaderSource {
        if let machine = session.machine {
            guard let process = session.process, let id = process.hostSessionID else { return .none }
            let command = process.foregroundCommand
            if let agent = Agent.detect(command), ["claude", "codex", "ollama", "harness"].contains(agent.id) {
                return .remote(machine: machine, session: id, agent: agent.id)
            }
            if command == "ollama" || command == "harness" { return .remote(machine: machine, session: id, agent: command!) }
            return .none
        }
        guard let process = session.process else { return .none }
        if LocalChat.usesChatFile(process.foregroundCommand), let id = process.hostSessionID, let p = LocalChat.latest(for: id) {
            return .file(agent: process.foregroundCommand ?? "ollama", path: p, live: true)
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
    case remote(machine: RemoteMachine, session: String, agent: String)
}

indirect enum PaneLayout: Codable {
    case pane(directory: String, history: String?, host: String? = nil, resume: String? = nil, machine: String? = nil)
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
            if oldValue?.superview === self { oldValue?.removeFromSuperview() }
            if let composer { addSubview(composer) }
            needsLayout = true
        }
    }
    var composersInColumns = false { didSet { needsLayout = true } }
    var header: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let header { addSubview(header) }
            needsLayout = true
        }
    }
    private let pageGap = PageGapView()
    var overlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let overlay { addSubview(overlay) }
            needsLayout = true
        }
    }
    var approval: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let approval { addSubview(approval) }
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
            h = composerHeight(composer)
            composer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        }
        let stripShown = showStrip && !(strip.native && (composer != nil || composersInColumns))
        strip.isHidden = !stripShown
        if stripShown {
            let sh = strip.intrinsicContentSize.height
            strip.frame = NSRect(x: 0, y: h, width: bounds.width, height: sh)
            h += sh
        }
        if let approval {
            let ah = approval.fittingSize.height
            approval.frame = NSRect(x: 0, y: h, width: bounds.width, height: ah)
            h += ah
        }
        let top = header == nil ? 0 : chromeTopInset(window)
        header?.frame = NSRect(x: 0, y: bounds.height - chromeHeaderHeight, width: bounds.width, height: chromeHeaderHeight)
        split.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h - top))
        let paged = overlay != nil
        split.isHidden = paged
        composer?.isHidden = paged
        approval?.isHidden = paged
        if paged { strip.isHidden = true }
        var pageTop = top
        if paged, let window {
            let layoutHeight = window.contentLayoutRect.height
            let reserved = window.frame.height - layoutHeight
            if !window.styleMask.contains(.fullScreen), layoutHeight > 0, reserved > top, reserved <= top + 48 {
                pageTop = reserved
            }
        }
        pageGap.isHidden = !paged || pageTop <= top
        if paged {
            if pageGap.superview !== self { addSubview(pageGap, positioned: .below, relativeTo: header) }
            pageGap.frame = NSRect(x: 0, y: bounds.height - pageTop, width: bounds.width, height: pageTop - top)
        }
        overlay?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - pageTop))
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let container = ContentContainer()
    private let drops = WindowLink()
    var reader: ReaderModel { focused.reader }
    var composerState: ComposerState { focused.composerState }
    private var readerHost: ChatAreaView?
    private var clickMonitor: Any?
    private(set) var panes: [Pane] = []
    private(set) var focused: Pane!
    private let host = PaneHostView()
    private let split = SidebarSplitController()
    private let sidebarItem: NSSplitViewItem
    let gate: ViewGate
    private(set) var onScreen = true
    private var pendingStatus: StatusSummary?
    private var lastModelScan = Date.distantPast
    private var lastStripText: String?
    private var statusScheduled = false
    var onClose: (() -> Void)?
    var worktree: WorktreeInfo? { didSet { SidebarModel.shared.refreshTabs() } }
    var themeOverride: String? {
        didSet { (NSApp.delegate as? AppDelegate)?.applyAppearance() }
    }
    var customTitle: String? {
        didSet {
            refreshTitle()
            if customTitle != oldValue { sendName(locked: customTitle?.isEmpty == false) }
        }
    }
    private(set) var agent: Agent?
    private(set) var displayTitle = "shell"
    var switchingModel = false

    var paneHost: NSView { host }
    var contentContainer: NSView { container }

    var session: TerminalSession { focused.session }
    var terminalView: TerminalView { focused.view }

    static var sidebarWidth: CGFloat { SidebarSplitController.savedWidth }

    init(workingDirectory: String?, command: String? = nil, layout: PaneLayout? = nil,
         machine: RemoteMachine? = nil, agent: String? = nil) {
        let gate = ViewGate()
        self.gate = gate
        let sidebarHost = NSHostingView(rootView: SidebarView(model: SidebarModel.shared, gate: gate, drops: drops))
        sidebarHost.safeAreaRegions = []
        sidebarItem = NSSplitViewItem(viewController: SidebarPaneController(content: sidebarHost))
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !SidebarModel.shared.visible

        let content = NSViewController()
        content.view = container
        container.split.addSubview(host)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 300
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.dividerStyle = .thin

        let probe = TerminalView(frame: .zero)
        var size = probe.contentSize(columns: 100, rows: 30)
        if SidebarModel.shared.visible { size.width += TerminalWindowController.sidebarWidth }
        let window = TerminalWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "terminal"
        window.title = "Terminess"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.backgroundColor = probe.backgroundNSColor
        let root = RootViewController(split: split)
        window.contentViewController = root
        window.setContentSize(size)
        split.applySavedWidth()
        window.center()
        window.setFrameAutosaveName("TerminalWindow")
        super.init(window: window)
        window.delegate = self
        container.drops = drops
        drops.handler = { [weak self] pb in self?.acceptDrop(pb) ?? false }
        drops.owner = ObjectIdentifier(self)

        let toolbar = NSToolbar(identifier: "terminal")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        container.header = header
        header.sidebarHidden = sidebarItem.isCollapsed
        sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.header.sidebarHidden = collapsed } }
        }
        layoutObservation = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.container.needsLayout = true
                    self?.sidebarItem.viewController.view.needsLayout = true
                }
            }
        }
        refreshWhatsNew()
        NotificationCenter.default.addObserver(forName: WhatsNew.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWhatsNew() }
        }

        if let layout {
            host.root = build(layout)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyFractions(layout, to: self?.host.root) }
            }
        } else {
            let pane = makePane(directory: workingDirectory, command: command, machine: machine, agent: agent)
            host.root = pane.view
        }
        focusPane(panes[0])
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.chatClick(event) }
            return event
        }
        setMode(ViewMode(rawValue: UserDefaults.standard.integer(forKey: "viewMode")) ?? .terminal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }


    enum ViewMode: Int { case terminal = 0, split = 1, chat = 2 }
    private(set) var mode: ViewMode = .terminal
    private lazy var header = ContentHeaderView(controller: self)
    private var sidebarObservation: NSKeyValueObservation?
    private var layoutObservation: NSKeyValueObservation?
    private var revealedForQuestion = false
    private var screenMenu: ScreenMenu?
    private var waitingLines: [String]?
    private var waitingTimer: DispatchWorkItem?
    var debugMenuCard: String { screenMenu.map { "\($0.options)" } ?? "none" }
    private var questionTimer: DispatchWorkItem?

    func setMode(_ m: ViewMode) {
        mode = m
        header.setMode(m.rawValue)
        UserDefaults.standard.set(m.rawValue, forKey: "viewMode")
        revealedForQuestion = false
        switch m {
        case .terminal:
            showHost(true)
            setReader(visible: false)
            container.showStrip = false
        case .split:
            showHost(true)
            setReader(visible: true)
            container.showStrip = true
        case .chat:
            setReader(visible: true)
            showHost(false)
            container.showStrip = true
        }
        layoutChat(rebuild: true)
        updateInputHiding(report: true)
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

    func hideNativeTabBar() {
        guard let group = window?.tabGroup else { return }
        if observedGroup !== group {
            observedGroup = group
            tabBarObservation = group.observe(\.isTabBarVisible, options: [.initial, .new]) { [weak self] g, _ in
                guard g.isTabBarVisible else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.hideTabBarOnce() } }
            }
        }
        hideTabBarOnce()
    }

    private func hideTabBarOnce() {
        for w in window?.tabbedWindows ?? [window].compactMap({ $0 }) {
            guard let frame = w.contentView?.superview else { continue }
            func walk(_ v: NSView) {
                let name = String(describing: type(of: v))
                if name.hasPrefix("NSTitlebarAccessory") || name == "NSTabBar" {
                    let holder = v.superview.flatMap { String(describing: type(of: $0)) == "NSTitlebarView" ? nil : $0 }
                    let target = name == "NSTabBar" ? v : (holder ?? v)
                    if !target.isHidden { target.isHidden = true }
                    return
                }
                if String(describing: type(of: v)) == "NSToolbarView" {
                    if !v.isHidden { v.isHidden = true }
                    return
                }
                v.subviews.forEach(walk)
            }
            walk(frame)
        }
        (window?.tabbedWindows ?? []).compactMap { $0.windowController as? TerminalWindowController }
            .forEach { $0.relayoutChrome() }
    }

    func relayoutChrome() {
        container.needsLayout = true
        sidebarItem.viewController.view.needsLayout = true
    }
    private weak var observedGroup: NSWindowTabGroup?
    private var tabBarObservation: NSKeyValueObservation?


    func showSettingsPane() {
        if let p = container.overlay as? PageHostView, !p.shouldClose() { return }
        if !(container.overlay is SettingsHostView) {
            let page = SettingsHostView(rootView: SettingsPane { [weak self] in self?.closePage() })
            page.safeAreaRegions = []
            container.overlay = page
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func showRemindersPage() {
        if let p = container.overlay as? PageHostView, !p.shouldClose() { return }
        if !(container.overlay is RemindersHostView) {
            let page = RemindersHostView(rootView: RemindersPage { [weak self] in self?.closePage() })
            page.safeAreaRegions = []
            container.overlay = page
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func closeSettingsPane() { closePage() }

    func showPage<V: View>(_ id: String, shouldClose: @escaping () -> Bool = { true }, _ make: () -> V) {
        if let p = container.overlay as? PageHostView, p.pageID == id {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        if let p = container.overlay as? PageHostView, !p.shouldClose() { return }
        let host = PageHostView(rootView: AnyView(make()))
        host.safeAreaRegions = []
        host.pageID = id
        host.shouldClose = shouldClose
        container.overlay = host
        window?.makeKeyAndOrderFront(nil)
    }

    var pageID: String? { (container.overlay as? PageHostView)?.pageID }

    func closePage() {
        if let p = container.overlay as? PageHostView, !p.shouldClose() { return }
        container.overlay = nil
        focus()
    }


    func showPalette() {
        guard let root = window?.contentView as? RootView else { return }
        if root.overlay == nil {
            let palette = NSHostingView(rootView: CommandPalette(controller: self) { [weak self] in self?.closePalette() })
            palette.safeAreaRegions = []
            root.overlay = palette
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func closePalette() {
        (window?.contentView as? RootView)?.overlay = nil
        focus()
    }


    func refreshWhatsNew() {
        header.whatsNew.isHidden = !WhatsNew.hasUnseen
    }

    @objc func showWhatsNew(_ sender: Any?) {
        let anchor: NSView = header.whatsNew.isHidden ? header : header.whatsNew
        WhatsNew.show(relativeTo: anchor)
    }

    private func agentScreenChanged(inputVisible: Bool, status: [Row]) {
        guard onScreen else { return }
        let palette = session.terminal.palette
        let native = Settings.shared.statusStyle == "native"
        let text = status.map { $0.plainText() }.joined(separator: "\n")
        let stripChanged = text != lastStripText || native != container.strip.native
        if stripChanged {
            lastStripText = text
            container.strip.native = native
            container.strip.palette = palette
            container.strip.rows = status
            container.needsLayout = true
        }
        let summary = StatusSummary(rows: status, palette: palette)
        pendingStatus = summary
        if onScreen, !statusScheduled {
            statusScheduled = true
            let pane = focused
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak pane] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.statusScheduled = false
                    guard let pane else { return }
                    if let s = self.pendingStatus, s != pane.composerState.status { pane.composerState.status = s }
                    let shells = self.pendingStatus?.shells
                    if shells != pane.reader.shells { pane.reader.shells = shells }
                }
            }
        }
        updateComposerPlace()
        if Date().timeIntervalSince(lastModelScan) > 0.5 {
            lastModelScan = Date()
            refreshComposerModel()
        }
        let menu = mode != .terminal && Agent.detect(session.process?.foregroundCommand) != nil
            ? ScreenMenu.find(in: session.terminal) : nil
        if menu != screenMenu { screenMenu = menu; updateApproval() }
        refreshWaiting(inputVisible: inputVisible)
        guard mode == .chat, !switchingModel, Agent.detect(session.process?.foregroundCommand) != nil else { return }
        questionTimer?.cancel()
        if revealedForQuestion { revealedForQuestion = false; showHost(false) }
    }

    private func refreshWaiting(inputVisible: Bool) {
        lastInputVisible = inputVisible
        waitingTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.decideWaiting() }
        }
        waitingTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private var lastInputVisible = true

    private func decideWaiting() {
        let isAgent = Agent.detect(focused?.session.process?.foregroundCommand) != nil
        let waiting = mode != .terminal && isAgent && !composerState.busy && !lastInputVisible
        guard waiting, let t = focused?.session.terminal else {
            if waitingLines != nil { waitingLines = nil; updateApproval() }
            if mode != .terminal && isAgent && !lastInputVisible {
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.decideWaiting() } }
                waitingTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            }
            return
        }
        let rows = t.screen.rows.map { $0.plainText().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        let frame = "─━═│┃║╭╮╰╯┌┐└┘".unicodeScalars
        let lines = Array(rows.filter { r in
            let x = r.trimmingCharacters(in: .whitespaces)
            return !x.isEmpty && !x.unicodeScalars.allSatisfy { frame.contains($0) }
        }.suffix(10))
        if lines != waitingLines { waitingLines = lines; updateApproval() }
    }

    private func sendKey(_ key: Key) {
        guard let s = focused?.session else { return }
        s.send(InputEncoder.encode(key, modifiers: [], modes: s.terminal.modes))
    }

    func updateApproval() {
        if let pane = ([focused] + panes).compactMap({ $0 }).first(where: { $0.session.permission == nil && $0.session.question != nil }),
           !panes.contains(where: { $0.session.permission != nil }), let q = pane.session.question {
            let agent = Agent.detect(pane.session.process?.foregroundCommand, title: pane.session.terminal.title)?.name ?? "The agent"
            showCard(NSHostingView(rootView: QuestionBar(question: q, agent: agent) { [weak self, weak pane] text in
                pane?.session.answerQuestion(text)
                self?.updateApproval()
            }), for: pane)
            return
        }
        let pane = ([focused] + panes).compactMap { $0 }.first { $0.session.permission != nil }
        let fuller = pane.flatMap { p in p.session.permission.flatMap { r in
            !r.canAlways && p === focused && (screenMenu?.options.count ?? 0) > 2 ? screenMenu : nil } }
        guard let pane, let request = pane.session.permission, fuller == nil else {
            if let menu = fuller ?? screenMenu, let pane = focused {
                let agent = Agent.detect(pane.session.process?.foregroundCommand, title: pane.session.terminal.title)?.name ?? "The agent"
                showCard(NSHostingView(rootView: MenuBar(menu: menu, agent: agent) { [weak self, weak pane] index in
                    guard let pane else { return }
                    for (i, k) in menu.keys(toChoose: index).enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) { [weak pane] in
                            MainActor.assumeIsolated {
                                guard let s = pane?.session else { return }
                                s.send(InputEncoder.encode(k, modifiers: [], modes: s.terminal.modes))
                            }
                        }
                    }
                    self?.screenMenu = nil
                    self?.updateApproval()
                }), for: pane)
                return
            }
            if let lines = waitingLines, let pane = focused {
                let agent = Agent.detect(pane.session.process?.foregroundCommand, title: pane.session.terminal.title)?.name ?? "The agent"
                showCard(NSHostingView(rootView: WaitingBar(lines: lines, agent: agent, key: { [weak self] k in
                    self?.sendKey(k)
                }, type: { [weak self] text in
                    guard let s = self?.focused?.session else { return }
                    s.send(Array(text.utf8))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        MainActor.assumeIsolated { s.send(InputEncoder.encode(.enter, modifiers: [], modes: s.terminal.modes)) }
                    }
                }, showTerminal: { [weak self] in self?.setMode(.split) })), for: pane)
                return
            }
            if let p = ([focused] + panes).compactMap({ $0 }).first(where: { $0.session.notice != nil && !$0.session.noticeDismissed }),
               let text = p.session.notice {
                let machine = p.session.machine
                let open = p.session.noticeNewest.flatMap { id in
                    Self.newestOpener(id, on: machine)
                }
                showCard(NSHostingView(rootView: NoticeBar(text: text, openNewest: open) { [weak self, weak p] in
                    p?.session.noticeDismissed = true
                    self?.updateApproval()
                }), for: p)
            } else {
                showCard(nil, for: nil)
            }
            return
        }
        let agent = Agent.detect(pane.session.process?.foregroundCommand, title: pane.session.terminal.title)?.name ?? "The agent"
        let bar = NSHostingView(rootView: ApprovalBar(request: request, agent: agent) { [weak self, weak pane] answer in
            pane?.session.answerPermission(answer)
            self?.updateApproval()
        })
        showCard(bar, for: pane)
    }

    private func showCard(_ card: NSView?, for pane: Pane?) {
        let column = mode == .chat ? (pane?.chatColumn ?? focused?.chatColumn) : nil
        for p in panes where p.chatColumn !== column { p.chatColumn?.card = nil }
        if let column {
            container.approval = nil
            column.card = card
        } else {
            container.approval = card
        }
    }

    static func newestOpener(_ id: String, on machine: RemoteMachine?) -> (() -> Void)? {
        let model = SidebarModel.shared
        if let tab = model.tabs.first(where: { t in t.conversations.contains { $0.contains(id) } }) {
            return { SidebarModel.shared.actions?.focusTab(tab.id) }
        }
        if let machine {
            guard let r = model.remote.first(where: { $0.machine.id == machine.id }),
                  let h = r.history.first(where: { $0.id == id }) else { return nil }
            return { SidebarModel.shared.actions?.resumeRemote(r.machine, h) }
        }
        guard let item = model.sessions.first(where: { $0.id == id }) else { return nil }
        return { SidebarModel.shared.actions?.resume(item) }
    }

    var readerVisible: Bool { readerHost != nil }
    var composerVisible: Bool { container.composer != nil || container.composersInColumns }

    func setReader(visible: Bool) {
        guard visible != readerVisible else { return }
        if visible {
            let v = ChatAreaView()
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
            readerHost?.root = nil
            readerHost?.removeFromSuperview()
            readerHost = nil
        }
    }

    func layoutChat(rebuild: Bool) {
        guard focused != nil else { return }
        switch mode {
        case .terminal:
            container.composer = nil
            container.composersInColumns = false
        case .split:
            container.composersInColumns = false
            let view = readerView(for: focused)
            if readerHost?.root !== view { readerHost?.root = view }
            let composer = composerView(for: focused)
            if container.composer !== composer { container.composer = composer }
        case .chat:
            container.composer = nil
            container.composersInColumns = true
            if rebuild || readerHost?.root == nil {
                for p in panes { p.chatColumn?.removeFromSuperview(); p.chatColumn = nil }
                readerHost?.root = chatTree(host.root)
                readerHost?.layoutSubtreeIfNeeded()
                if let root = readerHost?.root { matchSizes(of: host.root, in: root) }
            }
        }
        for p in panes {
            let marked = mode == .chat && panes.count > 1 && p === focused
            if p.composerState.marked != marked { p.composerState.marked = marked }
        }
        for p in panes {
            let shown = mode == .chat || (mode == .split && p === focused)
            if p.reader.visible != (shown && onScreen) { p.reader.visible = shown && onScreen }
        }
        if mode == .chat, !chatHasFirstResponder(focused) { focusComposer(of: focused) }
        updateApproval()
    }

    private func chatTree(_ view: NSView?) -> NSView {
        if let sv = view as? NSSplitView {
            let split = NSSplitView(frame: sv.frame)
            split.isVertical = sv.isVertical
            split.dividerStyle = .thin
            split.autoresizingMask = [.width, .height]
            for child in sv.subviews { split.addSubview(chatTree(child)) }
            return split
        }
        let pane = panes.first { $0.view === view } ?? focused!
        let column = ChatColumnView(reader: readerView(for: pane), composer: composerView(for: pane))
        column.frame = view?.frame ?? .zero
        pane.chatColumn = column
        return column
    }

    private func matchSizes(of terminals: NSView?, in chat: NSView) {
        guard let sv = terminals as? NSSplitView, let cv = chat as? NSSplitView else { return }
        let sizes = sv.subviews.map { sv.isVertical ? $0.frame.width : $0.frame.height }
        let total = sizes.reduce(0, +)
        if total > 0, !sizes.contains(where: { $0 <= 0 }) {
            cv.adjustSubviews()
            let room = (cv.isVertical ? cv.bounds.width : cv.bounds.height) - cv.dividerThickness * CGFloat(sizes.count - 1)
            var pos: CGFloat = 0
            for i in 0..<(sizes.count - 1) {
                pos += room * sizes[i] / total
                cv.setPosition(pos + cv.dividerThickness * CGFloat(i), ofDividerAt: i)
            }
        } else {
            equalize(cv)
        }
        for (t, c) in zip(sv.subviews, cv.subviews) { matchSizes(of: t, in: c) }
    }

    private func readerView(for pane: Pane) -> NSView {
        if let v = pane.readerView { return v }
        let v = NSHostingView(rootView: ReaderView(model: pane.reader))
        v.safeAreaRegions = []
        pane.readerView = v
        return v
    }

    private func composerView(for pane: Pane) -> NSView {
        if let v = pane.composerView { return v }
        let v = ComposerHostingView(rootView: ComposerView(placeholder: "Message the agent in this tab",
            state: pane.composerState,
            onSend: { [weak self, weak pane] text in
                guard let self, let pane else { return }
                if pane !== self.focused { self.focusPane(pane) }
                self.sendFromComposer(text)
            },
            onStop: { [weak self, weak pane] in
                guard let self, let pane else { return }
                if pane !== self.focused { self.focusPane(pane) }
                self.interruptAgent()
            },
            onEscape: { [weak self] in self?.escapeFromComposer() }))
        let state = pane.composerState
        v.measuredHeight = { [weak state] in state?.contentHeight ?? 0 }
        state.onContentHeight = { [weak v] in v?.relayoutParent() }
        pane.composerView = v
        return v
    }

    private func escapeFromComposer() {
        if mode == .split { window?.makeFirstResponder(focused.view) }
    }

    private func chatClick(_ event: NSEvent) {
        guard mode == .chat, panes.count > 1, event.window === window else { return }
        for p in panes where p !== focused {
            guard let column = p.chatColumn, column.window != nil else { continue }
            if column.bounds.contains(column.convert(event.locationInWindow, from: nil)) {
                focusPane(p)
                return
            }
        }
    }

    private func chatHasFirstResponder(_ pane: Pane) -> Bool {
        guard let column = pane.chatColumn, let r = window?.firstResponder as? NSView else { return false }
        return r.isDescendant(of: column)
    }

    private func focusComposer(of pane: Pane) {
        guard let box = pane.composerView, box.window != nil,
              let text = Self.firstTextView(in: box) else { return }
        window?.makeFirstResponder(text)
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let t = view as? KeyTextView { return t }
        for v in view.subviews { if let t = firstTextView(in: v) { return t } }
        return nil
    }

    func updateInputHiding(report: Bool = false) {
        let on = mode != .terminal && Settings.shared.composerHidesAgentInput
        for p in panes {
            let agent = Agent.detect(p.session.process?.foregroundCommand)?.id
            let isAgent = agent == "claude" || agent == "codex"
            p.view.hideAgentInput = on && isAgent
            p.view.hideAgentStatus = on && isAgent
            let follows = p === focused || mode == .chat
            p.view.onQueued = follows ? { [weak p] queued in p?.reader.setQueued(queued) } : nil
            p.view.onAgentScreen = follows ? { [weak self, weak p] visible, status, busy in
                guard let self, let p else { return }
                if p.composerState.busy != busy { p.composerState.busy = busy }
                if p === self.focused {
                    self.agentScreenChanged(inputVisible: visible, status: status)
                } else {
                    self.columnStatusChanged(p, status: status)
                }
            } : nil
        }
        for p in panes where p === focused || (report && mode == .chat) {
            p.view.updateAgentScreen(force: report)
        }
    }

    private func columnStatusChanged(_ pane: Pane, status: [Row]) {
        guard onScreen, Date().timeIntervalSince(pane.statusShownAt) > 0.3 else { return }
        pane.statusShownAt = Date()
        let summary = StatusSummary(rows: status, palette: pane.session.terminal.palette)
        if summary != pane.composerState.status { pane.composerState.status = summary }
        if summary.shells != pane.reader.shells { pane.reader.shells = summary.shells }
        updateComposerPlace(pane)
        refreshComposerModel(pane)
    }

    func updateComposerPlace(_ pane: Pane? = nil) {
        guard let pane = pane ?? focused else { return }
        let state = pane.composerState
        let machineID = pane.session.process?.machineID
        let remote = machineID.flatMap { RemoteMachines.machine($0) }
        let name = remote?.name ?? "This Mac"
        let symbol = remote == nil ? "laptopcomputer" : "server.rack"
        if state.machine != name { state.machine = name }
        if state.machineSymbol != symbol { state.machineSymbol = symbol }
        let folder = remote == nil ? pane.currentDirectory : nil
        if state.folderPath != folder { state.folderPath = folder }
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
        nameFromFirstMessage(text)
        if pane.parked == nil, Self.isShell(pane.session.process?.foregroundCommand) {
            reader.addPending(text)
            let command = StartAgent.command(StartAgent.current, remote: pane.session.machine != nil, message: text)
            pane.session.send(Array("\(command)\r".utf8))
            return
        }
        reader.addPending(text)
        if pane.parked != nil { resume(pane) }
        if let model = composerState.pendingModel {
            Task { @MainActor in
                composerState.switching = true
                while composerState.busy { try? await Task.sleep(nanoseconds: 300_000_000) }
                let ok = await switchModel(model)
                composerState.switching = false
                composerState.pendingModel = nil
                guard ok else {
                    composerState.draft = text
                    reader.pending.removeAll { $0.text == text }
                    let alert = NSAlert()
                    alert.messageText = "Couldn't switch to \(model.name)"
                    alert.informativeText = "The agent didn't confirm the change, so your message wasn't sent. It's back in the message box."
                    if let w = window { alert.beginSheetModal(for: w, completionHandler: nil) }
                    return
                }
                composerState.model = model.name
                typeIntoAgent(text, pane: pane)
            }
            return
        }
        typeIntoAgent(text, pane: pane)
    }

    func refreshComposerModel(_ pane: Pane? = nil) {
        guard let pane = pane ?? focused else { return }
        let state = pane.composerState
        let id = Agent.detect(pane.session.process?.foregroundCommand)?.id
        let usable = id == "claude" || id == "codex" ? id : nil
        if state.agentID != usable {
            state.agentID = usable
            state.models = AgentModels.list(for: usable)
            state.model = nil
            state.pendingModel = nil
        }
        guard usable != nil, !(switchingModel && pane === focused),
              let seen = AgentModels.current(onScreen: pane.session.terminal.screenText(), agentID: usable) else { return }
        if state.model != seen { state.model = seen }
    }

    static func isShell(_ command: String?) -> Bool {
        guard let c = command else { return false }
        let name = (c as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh"].contains(name)
    }

    private func typeIntoAgent(_ text: String, pane: Pane) {
        let t = pane.session.terminal
        pane.session.send(InputEncoder.paste(text, modes: t.modes))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { pane.session.send([0x0D]) }
        }
    }

    @objc func toggleReader(_ sender: Any?) { setMode(mode == .terminal ? .split : .terminal) }


    private func makePane(directory: String?, command: String?, history: String? = nil, attach: String? = nil,
                          resumeIfGone: String? = nil, machine: RemoteMachine? = nil, agent: String? = nil) -> Pane {
        let pane = Pane(columns: 100, rows: 30)
        let view = pane.view, session = pane.session
        if attach == nil, let history, !history.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let body = history.replacingOccurrences(of: "\n", with: "\r\n")
            session.terminal.feed("\u{1B}[2m\(body)\r\n\u{1B}[0;2;3mRestored from the previous session\u{1B}[0m\r\n\r\n")
        }
        session.onUpdate = { [weak view] in view?.terminalDidUpdate() }
        view.hostWindowShowing = { [weak self] in self?.onScreen ?? false }
        session.onTitle = { [weak self, weak pane] t in
            pane?.programTitle = t
            PerfCounters.tick("title.osc")
        }
        session.onForeground = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.updateComposerPlace(pane)
            guard pane === self.focused else { return }
            self.refreshTitle()
            self.refreshWaiting(inputVisible: self.lastInputVisible)
        }
        session.onBell = { [weak self, weak pane] in
            guard let self, let pane else { return }
            AttentionCenter.shared.alert(controller: self, pane: pane, title: self.displayTitle, body: "Bell")
        }
        session.onNotice = { [weak self] _ in self?.updateApproval() }
        session.onPermission = { [weak self, weak pane] request in
            guard let self, let pane else { return }
            self.updateApproval()
            if let request, self.window?.isKeyWindow != true || NSApp.isActive == false {
                let agent = Agent.detect(pane.session.process?.foregroundCommand, title: pane.session.terminal.title)?.name ?? "The agent"
                AttentionCenter.shared.alert(controller: self, pane: pane, title: "\(agent) needs your approval",
                                             body: request.summary.isEmpty ? request.tool : request.summary, always: true)
            }
        }
        session.onQuestion = { [weak self, weak pane] q in
            guard let self, let pane else { return }
            self.updateApproval()
            if let q, self.window?.isKeyWindow != true || NSApp.isActive == false {
                let agent = Agent.detect(pane.session.process?.foregroundCommand, title: pane.session.terminal.title)?.name ?? "The agent"
                AttentionCenter.shared.alert(controller: self, pane: pane, title: "\(agent) asks", body: q.text, always: true)
            }
        }
        session.onAgentNote = { [weak self, weak pane] text in
            guard let self, let pane else { return }
            let agent = Agent.detect(pane.session.process?.foregroundCommand, title: pane.session.terminal.title)?.name ?? "The agent"
            AttentionCenter.shared.alert(controller: self, pane: pane, title: agent, body: text, always: true)
        }
        session.onAgentRequest = { [weak self] id, tool, args in
            guard let self, let app = NSApp.delegate as? AppDelegate else { return }
            app.agentRequest(id: id, tool: tool, args: args, from: self)
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
        setUpChat(pane, machine: machine)
        panes.append(pane)
        session.start(workingDirectory: directory,
                      cellWidth: Int(view.cellSize.width.rounded()), cellHeight: Int(view.cellSize.height.rounded()),
                      attach: attach, resumeIfGone: resumeIfGone, machine: machine, command: agent)
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

    private func setUpChat(_ pane: Pane, machine: RemoteMachine?) {
        let reader = pane.reader
        reader.drops = drops
        pane.composerState.drops = drops
        reader.folder = { [weak pane] in pane?.currentDirectory }
        reader.gate = gate
        reader.onUserMessages = { [weak self] messages in self?.nameFromMessages(messages) }
        reader.machineID = machine?.id ?? ""
        reader.showTerminal = { [weak self] in self?.setMode(.split) }
        reader.startHere = { [weak self, weak pane] path, command in
            guard let self, let pane else { return }
            let dir = path == "~" ? "~" : shellQuote(path)
            pane.session.send(Array("cd \(dir) && clear && \(command)\r".utf8))
            if pane !== self.focused { self.focusPane(pane) }
            self.focus()
        }
        reader.follow { [weak pane] in pane?.readerSource() }
        reader.activity = { [weak pane] in pane?.session.lastActivity }
        reader.menuWaiting = { [weak self, weak pane] in self?.focused === pane && self?.screenMenu != nil }
        reader.onFound = { [weak pane] pid, agent, path in pane?.transcript = (pid, agent, path) }
    }

    func focusPane(_ pane: Pane) {
        let changed = focused !== pane
        focused = pane
        if pane.parked != nil && window?.isKeyWindow == true { resume(pane) }
        for p in panes { p.view.dimmed = panes.count > 1 && p !== pane }
        if mode == .chat {
            if !chatHasFirstResponder(pane) { focusComposer(of: pane) }
        } else if window?.firstResponder !== pane.view {
            window?.makeFirstResponder(pane.view)
        }
        AttentionCenter.shared.clear(pane: pane)
        refreshTitle()
        if changed {
            screenMenu = nil
            waitingLines = nil
            layoutChat(rebuild: false)
        }
        if reader.visible { reader.refresh(force: true) }
        updateInputHiding(report: changed)
    }

    @objc func splitRight(_ sender: Any?) { splitFocused(vertical: true) }
    @objc func splitDown(_ sender: Any?) { splitFocused(vertical: false) }

    private func splitFocused(vertical: Bool) {
        let target = focused.view
        let pane = makePane(directory: focused.currentDirectory, command: nil, machine: focused.session.machine)
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
        if mode == .chat { layoutChat(rebuild: true) }
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
        pane.reader.visible = false
        pane.chatColumn?.removeFromSuperview()
        pane.chatColumn = nil
        pane.readerView?.removeFromSuperview()
        pane.composerView?.removeFromSuperview()
        if mode == .chat { layoutChat(rebuild: true) }
        focusPane(panes.last!)
    }

    @objc func focusLeft(_ sender: Any?) { moveFocus(dx: -1, dy: 0) }
    @objc func focusRight(_ sender: Any?) { moveFocus(dx: 1, dy: 0) }
    @objc func focusUp(_ sender: Any?) { moveFocus(dx: 0, dy: -1) }
    @objc func focusDown(_ sender: Any?) { moveFocus(dx: 0, dy: 1) }

    private func moveFocus(dx: CGFloat, dy: CGFloat) {
        guard panes.count > 1 else { return }
        func frame(_ p: Pane) -> NSRect {
            let v: NSView = mode == .chat ? (p.chatColumn ?? p.view) : p.view
            return v.convert(v.bounds, to: nil)
        }
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
        guard pane.parked == nil, pane.session.machine == nil, let process = pane.session.process,
              let conversation = pane.runningConversation() else { return false }
        guard process.terminateForeground() else { return false }
        pane.parked = (conversation.tool, conversation.id)
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
                     host: pane?.session.process?.hostSessionID, resume: pane?.resumeCommand(),
                     machine: pane?.session.machine?.id)
    }

    private func build(_ layout: PaneLayout) -> NSView {
        switch layout {
        case .pane(let dir, let history, let host, let resume, let machineID):
            if let machineID {
                guard let m = RemoteMachines.machine(machineID) else {
                    return makePane(directory: nil, command: nil, history: history).view
                }
                return makePane(directory: dir, command: nil, history: history, attach: host, resumeIfGone: resume, machine: m).view
            }
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
        let tint = terminalView.backgroundNSColor.withAlphaComponent(CGFloat(Settings.shared.backgroundOpacity))
        window?.backgroundColor = translucent ? .clear : terminalView.backgroundNSColor
        (window?.contentView as? RootView)?.fill = translucent ? tint : nil
        updateInputHiding()
        for p in panes { p.view.needsDisplay = true }
    }

    func setSidebar(visible: Bool, animated: Bool) {
        guard sidebarItem.isCollapsed == visible else { return }
        if animated { sidebarItem.animator().isCollapsed = !visible } else { sidebarItem.isCollapsed = !visible }
        header.sidebarHidden = !visible
    }

    func setResumeOf(_ id: String) {
        focused?.session.resumeOf = id
    }


    private(set) var decidedName: String?

    var editableName: String {
        if let name = customTitle ?? decidedName { return name }
        if let m = focused?.session.machine, displayTitle.hasSuffix(" \u{00B7} \(m.name)") {
            return String(displayTitle.dropLast(m.name.count + 3))
        }
        return displayTitle
    }

    private enum NameSource { case firstLine, written, conversation }
    private var nameSource: NameSource?
    private var namedFrom = 0
    private var writingName = false

    func nameFromFirstMessage(_ text: String) {
        guard customTitle?.isEmpty != false, decidedName == nil else { return }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return }
        decidedName = line.count > 48 ? String(line.prefix(47)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : line
        nameSource = .firstLine
        refreshTitle()
        sendName(locked: false)
    }

    func nameFromMessages(_ messages: [String]) {
        guard customTitle?.isEmpty != false, let first = messages.first else { return }
        if decidedName == nil { nameFromFirstMessage(first) }
        let n = min(messages.count, 3)
        guard nameSource == .firstLine || nameSource == .written, !writingName,
              namedFrom == 0 || (namedFrom < 3 && n == 3), OnDeviceModel.isAvailable else { return }
        writingName = true
        let asked = Array(messages.prefix(n))
        PerfCounters.tick("name.write")
        Task { [weak self] in
            let name = await TabNamer.name(for: asked)
            guard let self else { return }
            self.writingName = false
            guard self.nameSource == .firstLine || self.nameSource == .written else { return }
            self.namedFrom = n
            guard let name, self.customTitle?.isEmpty != false, name != self.decidedName else { return }
            self.decidedName = name
            self.nameSource = .written
            self.refreshTitle()
            self.sendName(locked: false)
        }
    }

    func nameFromConversation(_ title: String) {
        guard customTitle?.isEmpty != false else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        decidedName = t
        nameSource = .conversation
        refreshTitle()
        sendName(locked: false)
    }

    func nameFromTranscriptIfNeeded(retry: Bool = true) {
        let wantMore = decidedName == nil || (nameSource != .conversation && namedFrom < 3 && OnDeviceModel.isAvailable)
        guard customTitle?.isEmpty != false, wantMore, !readingNameFromTranscript,
              let pane = focused, pane.session.machine == nil, let process = pane.session.process,
              let agent = Agent.detect(process.foregroundCommand), agent.id == "claude" || agent.id == "codex",
              let dir = pane.currentDirectory else { return }
        readingNameFromTranscript = true
        let pid = process.foregroundPID
        let pinned = pane.transcript.flatMap { $0.pid == pid ? $0.path : nil }
        let started = Date(timeIntervalSince1970: process.foregroundStartTime ?? Date().timeIntervalSince1970)
        let args = process.foregroundArguments
        PerfCounters.tick("name.transcriptRead")
        Task.detached(priority: .utility) {
            let path = pinned
                ?? (agent.id == "claude" ? Transcript.claudeSession(pid: pid) : nil)
                ?? Transcript.locate(agent: agent.id, directory: dir, started: started, arguments: args, pid: pid)
            var first: [String] = []
            if let path, let handle = FileHandle(forReadingAtPath: path) {
                let data = handle.readData(ofLength: 256 * 1024)
                try? handle.close()
                for item in Transcript.parse(data: data, agent: agent.id).items {
                    if case .user(let text) = item.kind { first.append(text) }
                    if first.count == 3 { break }
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.readingNameFromTranscript = false
                if !first.isEmpty {
                    self.nameFromMessages(first)
                } else if retry {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                        MainActor.assumeIsolated { self?.nameFromTranscriptIfNeeded(retry: false) }
                    }
                }
            }
        }
    }
    private var readingNameFromTranscript = false

    private func sendName(locked: Bool) {
        guard let focused, let id = focused.session.process?.hostSessionID else {
            nameWaitingForSession = locked ? .locked : .decided
            return
        }
        nameWaitingForSession = nil
        var m = Message(op: "set-name", id: id, name: locked ? (customTitle ?? "") : (decidedName ?? ""))
        m.code = locked ? 1 : (customTitle == nil && lockSent ? 2 : 0)
        lockSent = locked
        if let machine = focused.session.machine {
            SidebarModel.shared.monitor(machine.id)?.send(m)
        } else {
            HostAttachment.send(m)
        }
    }
    private var lockSent = false
    private enum PendingName { case decided, locked }
    private var nameWaitingForSession: PendingName?

    func refreshTitle() {
        guard let focused else { return }
        let command = focused.session.process?.foregroundCommand ?? ""
        let dir = currentDirectory ?? ""
        let folder = dir.isEmpty ? "" : folderName(dir)
        let found = Agent.detect(command)
        var title: String
        if let custom = customTitle, !custom.isEmpty {
            title = custom
        } else if let decidedName {
            title = decidedName
        } else if found != nil || Agent.shells.contains(command) || command.isEmpty {
            title = folder.isEmpty ? (found?.name ?? "shell") : folder
        } else {
            title = folder.isEmpty ? command : "\(command) \u{00B7} \(folder)"
        }
        PerfCounters.tick("title.recompute")
        if found != agent {
            if found == nil, agent != nil, decidedName != nil {
                decidedName = nil
                nameSource = nil
                namedFrom = 0
                title = folder.isEmpty ? "shell" : folder
                sendName(locked: false)
            }
            agent = found
            updateTabBadge()
            if let id = found?.id { AgentEvents.started(id) }
            updateInputHiding()
            if found != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated { self?.nameFromTranscriptIfNeeded() }
                }
            }
        }
        if let pending = nameWaitingForSession, focused.session.process?.hostSessionID != nil {
            sendName(locked: pending == .locked)
        }
        if customTitle?.isEmpty != false, let m = focused.session.machine { title += " \u{00B7} \(m.name)" }
        guard title != displayTitle else { return }
        PerfCounters.tick("title.change")
        displayTitle = title
        if window?.title != title { window?.title = title }
        SidebarModel.shared.refreshTabs()
    }

    private(set) var busy = false

    func refreshBusy() {
        let now = panes.contains { Agent.detect($0.session.process?.foregroundCommand) != nil && $0.view.agentLooksBusy() }
        if now != busy {
            busy = now
            updateTabBadge()
            if !now { nameFromTranscriptIfNeeded() }
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
        guard let window else { return }
        if let group = window.tabGroup, group.selectedWindow !== window { group.selectedWindow = window }
        window.makeKeyAndOrderFront(nil)
        if mode == .chat, let pane = focused { focusComposer(of: pane) } else { window.makeFirstResponder(terminalView) }
    }


    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }


    func windowWillClose(_ notification: Notification) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        for p in panes { p.reader.visible = false; p.session.close(); AttentionCenter.shared.clear(pane: p) }
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        hideNativeTabBar()
        terminalView.focusChanged(true)
        if let focused, focused.parked != nil { resume(focused) }
        if let focused { AttentionCenter.shared.clear(pane: focused) }
        SidebarModel.shared.refreshTabs()
    }

    func windowDidResignKey(_ notification: Notification) { terminalView.focusChanged(false) }

    func windowDidResize(_ notification: Notification) { hideNativeTabBar() }
    func windowDidEnterFullScreen(_ notification: Notification) { hideNativeTabBar() }
    func windowDidExitFullScreen(_ notification: Notification) { hideNativeTabBar() }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        let shown = window.occlusionState.contains(.visible)
        guard shown != onScreen else { return }
        onScreen = shown
        gate.active = shown
        layoutChat(rebuild: false)
        if shown {
            for p in panes { p.view.cameOnScreen() }
            updateInputHiding(report: true)
        }
    }
}

@MainActor
final class SidebarSplitController: NSSplitViewController {
    static let widthKey = "sidebarWidth"
    static let defaultWidth: CGFloat = 282
    static let range: ClosedRange<CGFloat> = 220...420

    static var savedWidth: CGFloat {
        let w = CGFloat(UserDefaults.standard.double(forKey: widthKey))
        return w > 0 ? min(max(w, range.lowerBound), range.upperBound) : defaultWidth
    }

    func applySavedWidth() {
        guard let item = splitViewItems.first, !item.isCollapsed else { return }
        splitView.setPosition(Self.savedWidth, ofDividerAt: 0)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applySavedWidth()
    }

    override func toggleSidebar(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.toggleSidebar(sender)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard let item = splitViewItems.first, !item.isCollapsed else { return }
        if let type = NSApp.currentEvent?.type, type == .leftMouseDragged || type == .leftMouseUp,
           notification.userInfo?["NSSplitViewDividerIndex"] != nil, view.window?.inLiveResize != true {
            let w = item.viewController.view.frame.width
            if Self.range.contains(w) { UserDefaults.standard.set(Double(w), forKey: Self.widthKey) }
            return
        }
        scheduleRestore()
    }

    private var restore: DispatchWorkItem?
    private func scheduleRestore() {
        restore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restoreWidth() }
        }
        restore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func restoreWidth() {
        guard let item = splitViewItems.first, !item.isCollapsed, splitViewItems.count > 1 else { return }
        if view.window?.inLiveResize == true { scheduleRestore(); return }
        let total = splitView.bounds.width - splitView.dividerThickness
        let room = total - splitViewItems[1].minimumThickness
        let wanted = min(Self.savedWidth, max(room, Self.range.lowerBound))
        let now = item.viewController.view.frame.width
        guard abs(now - wanted) > 0.5 else { return }
        splitView.setPosition(wanted, ofDividerAt: 0)
    }
}

final class ComposerHostingView<Content: View>: NSHostingView<Content> {
    var measuredHeight: () -> CGFloat = { 0 }

    var wantedHeight: CGFloat {
        let measured = measuredHeight()
        return min(measured > 0 ? measured : fittingSize.height, 280)
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        relayoutParent()
    }

    func relayoutParent() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, abs(self.wantedHeight - self.frame.height) > 0.5 else { return }
                self.superview?.needsLayout = true
            }
        }
    }
}

@MainActor func composerHeight(_ view: NSView) -> CGFloat {
    if let v = view as? ComposerHostingView<ComposerView> { return v.wantedHeight }
    return min(view.fittingSize.height, 280)
}

final class ChatAreaView: NSView {
    var root: NSView? {
        didSet {
            if let old = oldValue, old !== root, old.superview === self { old.removeFromSuperview() }
            if let root {
                root.frame = bounds
                root.autoresizingMask = [.width, .height]
                if root.superview !== self { addSubview(root) }
            }
        }
    }
}

final class ChatColumnView: NSView {
    let reader: NSView
    let composer: NSView
    var card: NSView? {
        didSet {
            guard card !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let card { addSubview(card) }
            needsLayout = true
        }
    }

    init(reader: NSView, composer: NSView) {
        self.reader = reader
        self.composer = composer
        super.init(frame: .zero)
        addSubview(reader)
        addSubview(composer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let h = composerHeight(composer)
        composer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        var y = h
        if let card {
            let ch = card.fittingSize.height
            card.frame = NSRect(x: 0, y: y, width: bounds.width, height: ch)
            y += ch
        }
        reader.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
    }
}
