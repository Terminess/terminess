import AppKit
import Carbon.HIToolbox

@MainActor
final class QuickTerminal: NSObject, NSWindowDelegate {
    static let shared = QuickTerminal()

    private var panel: QuickPanel?
    private var pane: Pane?
    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false

    static let choices: [(String, String, UInt32, UInt32)] = [
        ("ctrl-grave", "Control-`", UInt32(kVK_ANSI_Grave), UInt32(controlKey)),
        ("opt-space", "Option-Space", UInt32(kVK_Space), UInt32(optionKey)),
        ("ctrl-opt-space", "Control-Option-Space", UInt32(kVK_Space), UInt32(controlKey | optionKey)),
        ("cmd-esc", "Command-Escape", UInt32(kVK_Escape), UInt32(cmdKey)),
    ]

    func configure() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let id = Settings.shared.quickTerminalKey
        guard id != "off", let choice = QuickTerminal.choices.first(where: { $0.0 == id }) else { return }
        installHandler()
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x54444556), id: 1)
        if RegisterEventHotKey(choice.2, choice.3, hkID, GetApplicationEventTarget(), 0, &ref) == noErr {
            hotKey = ref
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { QuickTerminal.shared.toggle() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    var debugState: String {
        guard let panel, let pane else { return "not built" }
        return "visible=\(panel.isVisible) frame=\(Int(panel.frame.width))x\(Int(panel.frame.height)) text=\(pane.session.terminal.screenText().split(separator: "\n").first ?? "")"
    }

    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    private var frameOnScreen: NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let height = (vf.height * 0.42).rounded()
        return NSRect(x: vf.minX, y: vf.maxY - height, width: vf.width, height: height)
    }

    private func show() {
        let target = frameOnScreen
        if panel == nil { build(frame: target) }
        guard let panel, let pane else { return }
        var start = target
        start.origin.y += target.height
        panel.setFrame(start, display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(pane.view)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().setFrame(target, display: true)
        }
    }

    private func hide() {
        guard let panel else { return }
        var end = panel.frame
        end.origin.y += end.height
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().setFrame(end, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                if !NSApp.windows.contains(where: { $0 !== panel && $0.isVisible && $0.windowController is TerminalWindowController }) {
                    NSApp.hide(nil)
                }
            }
        })
    }

    private func build(frame: NSRect) {
        let p = QuickPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                           backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovable = false
        p.hasShadow = true
        p.delegate = self
        let pane = makePane()
        pane.view.frame = NSRect(origin: .zero, size: frame.size)
        pane.view.autoresizingMask = [.width, .height]
        p.contentView = pane.view
        p.backgroundColor = pane.view.backgroundNSColor
        panel = p
        self.pane = pane
    }

    private func makePane() -> Pane {
        let pane = Pane(columns: 120, rows: 20)
        let view = pane.view, session = pane.session
        session.onUpdate = { [weak view] in view?.terminalDidUpdate() }
        session.onExit = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
                self?.panel = nil
                self?.pane = nil
            }
        }
        if let app = NSApp.delegate as? AppDelegate {
            let theme = app.activeTheme
            session.terminal.setColorScheme(theme.isDark ? .dark : .light, palette: theme.palette)
        }
        session.start(workingDirectory: Settings.shared.startDirectory,
                      cellWidth: Int(view.cellSize.width.rounded()), cellHeight: Int(view.cellSize.height.rounded()))
        return pane
    }

    func applyTheme(_ theme: Theme) {
        guard let pane else { return }
        pane.session.terminal.setColorScheme(theme.isDark ? .dark : .light, palette: theme.palette)
        panel?.backgroundColor = pane.view.backgroundNSColor
        pane.view.needsDisplay = true
    }

    func windowDidResignKey(_ notification: Notification) {
        if let panel, panel.isVisible, !NSApp.isActive { panel.orderOut(nil) }
    }
}

final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
