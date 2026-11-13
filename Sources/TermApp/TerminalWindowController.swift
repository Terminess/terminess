import AppKit
import SwiftUI
import TermCore

@MainActor
final class Pane {
    let session: TerminalSession
    let view: TerminalView
    var programTitle = ""

    init(columns: Int, rows: Int) {
        session = TerminalSession(columns: columns, rows: rows)
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.session = session
    }

    var currentDirectory: String? {
        session.process?.foregroundDirectory ?? session.currentDirectory
    }
}

indirect enum PaneLayout: Codable {
    case pane(directory: String, history: String?)
    case split(vertical: Bool, children: [PaneLayout], fractions: [Double])
}

final class PaneHostView: NSView {
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
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private(set) var panes: [Pane] = []
    private(set) var focused: Pane!
    private let host = PaneHostView()
    private let split = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    var onClose: (() -> Void)?
    var themeOverride: String? {
        didSet { (NSApp.delegate as? AppDelegate)?.applyAppearance() }
    }
    var customTitle: String? { didSet { refreshTitle() } }
    private(set) var agent: Agent?
    private(set) var displayTitle = "shell"

    var paneHost: NSView { host }

    var session: TerminalSession { focused.session }
    var terminalView: TerminalView { focused.view }

    static let sidebarWidth: CGFloat = 260
    private static let toggleItem = NSToolbarItem.Identifier("toggleSidebar")

    init(workingDirectory: String?, command: String? = nil, layout: PaneLayout? = nil) {
        let sidebarHost = NSHostingController(rootView: SidebarView(model: SidebarModel.shared))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !SidebarModel.shared.visible

        let content = NSViewController()
        content.view = host
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
        window.title = "terminal"
        window.backgroundColor = probe.backgroundNSColor
        window.contentViewController = split
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName("TerminalWindow")
        super.init(window: window)
        window.delegate = self

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
    }

    required init?(coder: NSCoder) { fatalError("not used") }


    private func makePane(directory: String?, command: String?, history: String? = nil) -> Pane {
        let pane = Pane(columns: 100, rows: 30)
        let view = pane.view, session = pane.session
        if let history, !history.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                      cellWidth: Int(view.cellSize.width.rounded()), cellHeight: Int(view.cellSize.height.rounded()))
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
        for p in panes { p.view.dimmed = panes.count > 1 && p !== pane }
        if window?.firstResponder !== pane.view { window?.makeFirstResponder(pane.view) }
        AttentionCenter.shared.clear(pane: pane)
        refreshTitle()
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


    func layout() -> PaneLayout { encode(host.root) }

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
        return .pane(directory: pane?.currentDirectory ?? Settings.shared.startDirectory, history: history)
    }

    private func build(_ layout: PaneLayout) -> NSView {
        switch layout {
        case .pane(let dir, let history):
            let exists = FileManager.default.fileExists(atPath: dir)
            return makePane(directory: exists ? dir : nil, command: nil, history: history).view
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
        for p in panes {
            p.session.terminal.setColorScheme(scheme, palette: palette)
            p.view.needsDisplay = true
        }
        window?.backgroundColor = terminalView.backgroundNSColor
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
            title = folder.isEmpty ? found.name : "\(found.name) · \(folder)"
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
        }
        displayTitle = title
        if window?.title != title { window?.title = title }
    }

    func updateTabBadge() {
        let attention = AttentionCenter.shared.needsAttention(self)
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
        [TerminalWindowController.toggleItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TerminalWindowController.toggleItem, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
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
        if let focused { AttentionCenter.shared.clear(pane: focused) }
        SidebarModel.shared.refreshTabs()
    }

    func windowDidResignKey(_ notification: Notification) { terminalView.focusChanged(false) }
}
