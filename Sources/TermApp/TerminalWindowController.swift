import AppKit
import TermCore

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let session: TerminalSession
    let terminalView: TerminalView
    var onClose: (() -> Void)?

    init(workingDirectory: String?) {
        let view = TerminalView(frame: .zero)
        let cols = 100, rows = 30
        session = TerminalSession(columns: cols, rows: rows)
        terminalView = view
        let size = view.contentSize(columns: cols, rows: rows)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "terminal"
        window.title = "terminal"
        window.backgroundColor = view.backgroundNSColor
        window.contentView = view
        window.contentResizeIncrements = view.cellSize
        window.center()
        window.setFrameAutosaveName("TerminalWindow")
        super.init(window: window)
        window.delegate = self

        view.session = session
        session.onUpdate = { [weak view] in view?.terminalDidUpdate() }
        session.onTitle = { [weak window] t in window?.title = t.isEmpty ? "terminal" : t }
        session.onBell = { NSSound.beep() }
        session.onExit = { [weak window] _ in window?.close() }
        session.start(workingDirectory: workingDirectory,
                      cellWidth: Int(view.cellSize.width.rounded()), cellHeight: Int(view.cellSize.height.rounded()))
        window.makeFirstResponder(view)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        session.close()
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) { terminalView.focusChanged(true) }
    func windowDidResignKey(_ notification: Notification) { terminalView.focusChanged(false) }
}
