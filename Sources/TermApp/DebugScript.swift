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
        if env["TERMAPP_PARK_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + last + 0.8) { [weak controller] in
                MainActor.assumeIsolated {
                    guard let c = controller, let pane = c.panes.first else { return }
                    let dir = pane.currentDirectory ?? ""
                    let fake = SessionItem(tool: "claude", id: "test-session", cwd: dir, repo: "x", title: "t",
                                           mtime: Date().timeIntervalSince1970, linked: [], pair: nil)
                    print("park: before=\(pane.session.process?.foregroundCommand ?? "-") parked=\(c.park(pane, sessions: [fake]))")
                    fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        MainActor.assumeIsolated {
                            print("park: after stop=\(pane.session.process?.foregroundCommand ?? "-") state=\(pane.parked.map { "\($0.tool) \($0.id)" } ?? "none")")
                            c.resume(pane)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                MainActor.assumeIsolated {
                                    let lastLine = pane.session.terminal.screenText().split(separator: "\n").last ?? ""
                                    print("park: after resume=\(pane.session.process?.foregroundCommand ?? "-") line=\(lastLine)")
                                    fflush(stdout)
                                }
                            }
                        }
                    }
                }
            }
        }
        if let repo = env["TERMAPP_WORKTREE_TEST"] {
            switch Worktrees.create(repo: repo, branch: "agent/test-\(Int(Date().timeIntervalSince1970))") {
            case .failure(let e): print("worktree: failed \(e.message)")
            case .success(let w):
                print("worktree: created \(w.path) branch=\(w.branch) base=\(w.base)")
                print("worktree: env copied=\(FileManager.default.fileExists(atPath: w.path + "/.env")) node_modules linked=\((try? FileManager.default.destinationOfSymbolicLink(atPath: w.path + "/node_modules")) != nil)")
                print("worktree: main status clean=\(Git.run(w.repo, ["status", "--porcelain"]).output.isEmpty)")
                try? "def greet(name):\n    return f'Hello, {name}!'\n".write(toFile: w.path + "/greet.py", atomically: true, encoding: .utf8)
                Task {
                    let msg = await Git.draftCommitMessage(w.path, fallback: "FALLBACK")
                    print("worktree: drafted message (on-device available=\(OnDeviceModel.isAvailable)):\n\(msg)")
                    fflush(stdout)
                }
            }
            fflush(stdout)
        }
        if env["TERMAPP_READER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak controller] in
                MainActor.assumeIsolated {
                    if let m = env["TERMAPP_MODE"], let mode = TerminalWindowController.ViewMode(rawValue: Int(m) ?? 1) {
                        controller?.setMode(mode)
                    } else {
                        controller?.toggleReader(nil)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + last + 0.9) { [weak controller] in
                MainActor.assumeIsolated {
                    let m = controller?.reader
                    print("composer shown=\(controller?.composerVisible ?? false) height=\(Int((controller?.contentContainer.subviews.last?.frame.height) ?? 0))")
                    let proc = controller?.focused?.session.process
                    print("foreground: \(proc?.foregroundCommand ?? "-") args=\(proc?.foregroundArguments.prefix(4).joined(separator: " ") ?? "-")")
                    print("reader: agent=\(m?.agentName ?? "-") items=\(m?.items.count ?? 0) terminalWidth=\(Int(controller?.paneHost.frame.width ?? 0))")
                    fflush(stdout)
                }
            }
        }
        if let msg = env["TERMAPP_COMPOSE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak controller] in
                MainActor.assumeIsolated { controller?.sendFromComposer(msg) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak controller] in
                MainActor.assumeIsolated {
                    let lines = controller?.session.terminal.screenText().split(separator: "\n").suffix(3) ?? []
                    print("compose: " + lines.joined(separator: " | "))
                    fflush(stdout)
                }
            }
        }
        if env["TERMAPP_DOCTOR"] != nil {
            Task.detached {
                let tools = DoctorModel.probeTools()
                await MainActor.run {
                    for c in DoctorModel.buildChecks(tools: tools, notifications: .notDetermined) {
                        print("doctor: [\(c.status)] \(c.title): \(c.detail)\(c.fix.map { "  (fix: \($0.label))" } ?? "")")
                    }
                    fflush(stdout)
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
                    let view = env["TERMAPP_READER"] != nil ? c.contentContainer : (env["TERMAPP_SPLITS"] != nil ? c.paneHost : c.terminalView)
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let out = rep.copy() as! NSBitmapImageRep
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
                        let r = NSRect(origin: .zero, size: out.size)
                        (c.window?.backgroundColor ?? .black).withAlphaComponent(1).setFill()
                        r.fill()
                        rep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                        NSGraphicsContext.restoreGraphicsState()
                        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
