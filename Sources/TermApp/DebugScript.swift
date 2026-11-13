import AppKit

@MainActor
enum DebugScript {
    static func run(on controller: TerminalWindowController) {
        let env = ProcessInfo.processInfo.environment
        var last = 0.0
        if let script = env["TERMAPP_SCRIPT"] {
            for step in script.split(separator: "|") {
                guard let colon = step.firstIndex(of: ":"), let delay = Double(step[..<colon]) else { continue }
                let text = String(step[step.index(after: colon)...])
                    .replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\e", with: "\u{1B}").replacingOccurrences(of: "\\t", with: "\t")
                last = max(last, delay)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in
                    MainActor.assumeIsolated { controller?.session.send(Array(text.utf8)) }
                }
            }
        }
        if let extra = env["TERMAPP_EXTRA_TAB"], let delegate = NSApp.delegate as? AppDelegate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak controller] in
                MainActor.assumeIsolated {
                    delegate.open(tabbedWith: controller?.window, command: extra)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        MainActor.assumeIsolated { controller?.focus() }
                    }
                }
            }
        }
        if let splits = env["TERMAPP_SPLITS"] {
            for (i, ch) in splits.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(i) * 0.5) { [weak controller] in
                    MainActor.assumeIsolated {
                        if ch == "r" { controller?.splitRight(nil) } else { controller?.splitDown(nil) }
                        controller?.session.send(Array("clear; echo pane \(i + 2)\r".utf8))
                    }
                }
            }
        }
        if env["TERMAPP_QUICK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated { QuickTerminal.shared.toggle() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated { print("quick terminal: \(QuickTerminal.shared.debugState)"); fflush(stdout) }
            }
        }
        if let query = env["TERMAPP_FIND"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + last + 0.6) { [weak controller] in
                MainActor.assumeIsolated {
                    guard let view = controller?.terminalView else { return }
                    view.showFind(nil)
                    view.debugSetFindQuery(query)
                }
            }
        }
        if let path = env["TERMAPP_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + last + 1.0) {
                MainActor.assumeIsolated {
                    let c = (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? controller
                    let view = env["TERMAPP_SPLITS"] != nil ? c.paneHost : c.terminalView
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    let m = SidebarModel.shared
                    m.refreshTabs()
                    print("sidebar visible=\(m.visible)")
                    for t in m.tabs { print("  open: \(t.isKey ? "*" : " ") \(t.title) | \(t.command) | \(t.directory)") }
                    for j in m.jobs { print("  job: \(j.id) \(j.state) \(j.target) \(j.brief)") }
                    for r in m.runs { print("  run: \(r.mode) \(r.from)->\(r.to) \(r.status) \(r.brief)") }
                    print("  sessions: \(m.sessions.count)  note: \(m.sessionsNote ?? "-")")
                    let t = c.session.terminal
                    print("integration: prompts=\(t.promptLines().count) cwd=\(c.session.currentDirectory ?? "-")")
                    print("last output: \(t.lastCommandOutput()?.replacingOccurrences(of: "\n", with: " / ") ?? "-")")
                    for s in m.sessions.prefix(4) { print("    \(s.tool) \(s.repo) \(s.title)") }
                    fflush(stdout)
                }
            }
        }
        if let quit = env["TERMAPP_QUIT_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + quit) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
    }
}
