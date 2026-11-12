import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        NSWindow.allowsAutomaticWindowTabbing = true
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

    private func open(tabbedWith host: NSWindow?) {
        let cwd = (host?.windowController as? TerminalWindowController)?.session.currentDirectory
        let controller = TerminalWindowController(workingDirectory: cwd)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        if let host, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
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
