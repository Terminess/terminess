import AppKit
import SwiftUI
import TermCore

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let session: TerminalSession
    let terminalView: TerminalView
    private let split = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    var onClose: (() -> Void)?

    static let sidebarWidth: CGFloat = 260
    private static let toggleItem = NSToolbarItem.Identifier("toggleSidebar")

    init(workingDirectory: String?, command: String? = nil) {
        let view = TerminalView(frame: .zero)
        let cols = 100, rows = 30
        session = TerminalSession(columns: cols, rows: rows)
        terminalView = view

        let sidebarHost = NSHostingController(rootView: SidebarView(model: SidebarModel.shared))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !SidebarModel.shared.visible

        let terminalController = NSViewController()
        terminalController.view = view
        let contentItem = NSSplitViewItem(viewController: terminalController)
        contentItem.minimumThickness = 300
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)

        var size = view.contentSize(columns: cols, rows: rows)
        if SidebarModel.shared.visible { size.width += TerminalWindowController.sidebarWidth }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "terminal"
        window.title = "terminal"
        window.backgroundColor = view.backgroundNSColor
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

        view.session = session
        session.onUpdate = { [weak view] in view?.terminalDidUpdate() }
        session.onTitle = { [weak window] t in window?.title = t.isEmpty ? "terminal" : t }
        session.onBell = { NSSound.beep() }
        session.onExit = { [weak window] _ in window?.close() }
        session.start(workingDirectory: workingDirectory,
                      cellWidth: Int(view.cellSize.width.rounded()), cellHeight: Int(view.cellSize.height.rounded()))
        if let command {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.session.send(Array((command + "\r").utf8)) }
            }
        }
        window.makeFirstResponder(view)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(scheme: TermCore.ColorScheme, appearance: NSAppearance?) {
        window?.appearance = appearance
        session.terminal.setColorScheme(scheme)
        window?.backgroundColor = terminalView.backgroundNSColor
        terminalView.needsDisplay = true
    }

    func setSidebar(visible: Bool, animated: Bool) {
        guard sidebarItem.isCollapsed == visible else { return }
        if animated { sidebarItem.animator().isCollapsed = !visible } else { sidebarItem.isCollapsed = !visible }
    }

    var currentDirectory: String? {
        session.process?.foregroundDirectory ?? session.currentDirectory
    }

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
        session.close()
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        terminalView.focusChanged(true)
        SidebarModel.shared.refreshTabs()
    }

    func windowDidResignKey(_ notification: Notification) { terminalView.focusChanged(false) }
}
