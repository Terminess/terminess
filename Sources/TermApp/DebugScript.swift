import Combine
import AppKit
import TermHost
import TermCore

@MainActor
enum DebugScript {
    static func run(on controller: TerminalWindowController) {
        let env = ProcessInfo.processInfo.environment
        var last = 0.0
        if env["TERMAPP_BACKGROUND"] != nil {
            for delay in [0.2, 1.5, 4.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        for w in NSApp.windows where w.isVisible && (w.tabGroup?.selectedWindow ?? w) === w { w.orderFrontRegardless() }
                    }
                }
            }
        }
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
        if let file = env["TERMAPP_PAIR_MATCH"], let command = try? String(contentsOfFile: file, encoding: .utf8) {
            print("pair match: \(PairRuns.run(forCommand: command).map { "\($0.id) \($0.state) \($0.brief)" } ?? "none")")
            fflush(stdout)
        }
        if let at = env["TERMAPP_PAIR_OPEN_AT"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                MainActor.assumeIsolated {
                    if let run = PairRuns.recent().first { PairRunWindows.show(run) }
                    else { print("pair open: no run yet"); fflush(stdout) }
                }
            }
        }
        if let png = env["TERMAPP_PAIR_SNAPSHOT"], let run = PairRuns.recent().first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    PairRunWindows.show(run)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        MainActor.assumeIsolated {
                            guard let w = NSApp.windows.first(where: { $0.title.hasPrefix("Codex") || $0.title.hasPrefix("Claude") }),
                                  let view = w.contentView else { return }
                            view.layoutSubtreeIfNeeded()
                            view.display()
                            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                            view.cacheDisplay(in: view.bounds, to: rep)
                            let out = rep.copy() as! NSBitmapImageRep
                            NSGraphicsContext.saveGraphicsState()
                            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
                            w.backgroundColor.withAlphaComponent(1).setFill()
                            NSRect(origin: .zero, size: out.size).fill()
                            rep.draw(in: NSRect(origin: .zero, size: out.size), from: .zero, operation: .sourceOver, fraction: 1,
                                     respectFlipped: false, hints: nil)
                            NSGraphicsContext.restoreGraphicsState()
                            try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: png))
                        }
                    }
                }
            }
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
        if let size = env["TERMAPP_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak controller] in
                MainActor.assumeIsolated {
                    guard let w = controller?.window, let screen = w.screen ?? NSScreen.main else { return }
                    let f = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - size[1] - 40, width: size[0], height: size[1])
                    w.setFrame(f, display: true)
                }
            }
        }
        if let modes = env["TERMAPP_MODE_AT"] {
            for step in modes.split(separator: "|") {
                let parts = step.split(separator: ":")
                guard parts.count == 2, let delay = Double(parts[0]), let raw = Int(parts[1]),
                      let mode = TerminalWindowController.ViewMode(rawValue: raw) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in
                    MainActor.assumeIsolated {
                        let c = (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? controller
                        c?.setMode(mode)
                    }
                }
            }
        }
        if let spec = env["TERMAPP_OPEN_AT"], let app = NSApp.delegate as? AppDelegate {
            for step in spec.split(separator: "|") {
                let parts = step.split(separator: ":")
                guard parts.count == 2, let delay = Double(parts[0]) else { continue }
                let what = String(parts[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        switch what {
                        case "library": app.showLibrary(nil)
                        case "opsguide": app.showOpsGuide(nil)
                        case "instructions": app.showProjectInstructions(nil)
                        case "issues": app.showIssueBoard(nil)
                        case "settings": app.showSettings(nil)
                        case "models": app.showModels(nil)
                        case "pair": app.showPairPhone(nil)
                        case "reminders": app.showReminders(nil)
                        case "search": app.showSearch(nil)
                        case "hidesidebar": app.toggleSidebar(nil)
                        case "newtab": app.open(tabbedWith: NSApp.keyWindow ?? app.keyController?.window)
                        case "agenttab":
                            let cmd = env["TERMAPP_AGENT_CMD"] ?? "claude"
                            app.open(tabbedWith: app.keyController?.window, directory: env["TERMAPP_AGENT_DIR"], command: cmd)
                        case "agents": AgentsDashboardWindow.show()
                        case "tab1": app.controllers.first?.focus()
                        case "newreminder":
                            RemindersPageState.shared.draft = ReminderDraft(title: "Check the SPRING20 rollout",
                                                                            prompt: "Look at checkout errors since SPRING20 went live and summarise anything odd.")
                            app.showReminders(nil)
                        case "reminderdetail":
                            if let e = SidebarModel.shared.allReminders.first {
                                RemindersPageState.shared.detail = "\(e.machine?.id ?? "")/\(e.reminder.id)"
                            }
                            app.showReminders(nil)
                        case "demoreminders":
                            let now = Date().timeIntervalSince1970
                            let demo: [(String, Double, String)] = [
                                ("Check the SPRING20 rollout", 2 * 3600, "Look at checkout errors since SPRING20 went live and summarise anything odd."),
                                ("Ship check before release", 5 * 3600, "Run the full test suite and review the diff since the last release."),
                                ("Weekly dependency audit", 3 * 86400, "Check dependencies for outdated or vulnerable packages."),
                            ]
                            Task.detached {
                                for (title, after, prompt) in demo {
                                    var m = Message(op: "remind-add")
                                    m.reminder = ReminderInfo(id: "", title: title, due: now + after, actionPrompt: prompt, created: now)
                                    _ = HostAttachment.request(m, expecting: ["reminder-added", "error"], timeout: 3)
                                }
                                await MainActor.run { SidebarModel.shared.refreshBackground() }
                            }
                        default: break
                        }
                    }
                }
            }
        }
        if let spec = env["TERMAPP_CLICK_AT"] {
            for step in spec.split(separator: "|") {
                let parts = step.split(separator: ":")
                guard parts.count == 2, let delay = Double(parts[0]) else { continue }
                let xy = parts[1].split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { DebugClick.click(x: xy[0], y: xy[1]) }
                }
            }
        }
        if env["TERMAPP_PERF"] != nil { PerfCounters.start() }
        for (key, isModel) in [("TERMAPP_MODEL_AT", true), ("TERMAPP_COMPOSE_AT", false)] {
            guard let spec = env[key], let colon = spec.firstIndex(of: ":"), let delay = Double(spec[..<colon]) else { continue }
            let value = String(spec[spec.index(after: colon)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in
                MainActor.assumeIsolated {
                    guard let c = controller else { return }
                    if isModel {
                        c.refreshComposerModel()
                        let m = c.composerState.models.first { $0.name == value }
                        c.composerState.pendingModel = m
                        print("model: picked \(m?.name ?? "nothing") from \(c.composerState.models.map(\.name)) (showing \(c.composerState.model ?? "none"))")
                    } else {
                        print("compose: \(value)"); c.sendFromComposer(value)
                    }
                    fflush(stdout)
                }
            }
        }
        if let at = env["TERMAPP_AGENTS_AT"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { AgentsDashboardWindow.show() } }
        }
        for step in (env["TERMAPP_SCREEN_AT"] ?? "").split(separator: "|") {
            guard let delay = Double(step) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in
                MainActor.assumeIsolated {
                    guard let c = controller else { return }
                    let t = c.session.terminal
                    print("screen@\(delay): fg=\(c.session.process?.foregroundCommand ?? "-") menu=\(String(describing: ScreenMenu.find(in: t))) card=\(c.debugMenuCard)")
                    print(t.screenText())
                    fflush(stdout)
                }
            }
        }
        for step in (env["TERMAPP_ANSWER_AT"] ?? "").split(separator: "|") {
            guard let colon = step.firstIndex(of: ":"), let delay = Double(step[..<colon]) else { continue }
            let answer = String(step[step.index(after: colon)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in
                MainActor.assumeIsolated {
                    if let c = controller, let qp = c.panes.first(where: { $0.session.question != nil }) {
                        print("answer: \(answer) to question \(qp.session.question!.text)"); fflush(stdout)
                        qp.session.answerQuestion(answer)
                        c.updateApproval()
                        return
                    }
                    guard let c = controller, let pane = c.panes.first(where: { $0.session.permission != nil }) else {
                        print("answer: nothing waiting"); fflush(stdout); return
                    }
                    print("answer: \(answer) to \(pane.session.permission!.tool) \(pane.session.permission!.summary)"); fflush(stdout)
                    pane.session.answerPermission(answer)
                    c.updateApproval()
                }
            }
        }
        if let host = env["TERMAPP_REMOTE"] {
            var m = RemoteMachine(id: "test", name: host, host: host)
            if let path = env["TERMAPP_REMOTE_PATH"] { m.path = path }
            if let root = env["TERMAPP_REMOTE_ROOT"] { m.repoRoot = root }
            RemoteMachines.all = [m]
        }
        if let spec = env["TERMAPP_MACHINES"] {
            RemoteMachines.all = spec.split(separator: ";").enumerated().map { i, entry in
                let f = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                var m = RemoteMachine(id: "test\(i)", name: f[0], host: f.count > 1 ? f[1] : f[0])
                if f.count > 2, !f[2].isEmpty { m.path = f[2] }
                if f.count > 3 { m.role = MachineRole.clean(f[3]) }
                return m
            }
        }
        for step in (env["TERMAPP_REMOTE_AT"] ?? "").split(separator: "|") {
            let parts = step.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let delay = Double(parts[0]), let app = NSApp.delegate as? AppDelegate else { continue }
            let arg = parts.count > 2 ? parts[2] : ""
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    let model = SidebarModel.shared
                    model.refreshTabs()
                    let key = NSApp.keyWindow?.windowController as? TerminalWindowController
                    switch parts[1] {
                    case "move-here":
                        guard let r = model.remote.first, let s = r.sessions.first(where: { $0.name == arg }) else {
                            print("move-here: no remote session \(arg)"); fflush(stdout); return
                        }
                        HandoffCoordinator.moveToMac(r.machine, sessionID: s.id)
                    case "move-there":
                        let tab = arg.isEmpty ? key : NSApp.windows.lazy.compactMap { $0.windowController as? TerminalWindowController }
                            .first { $0.displayTitle.contains(arg) || ($0.currentDirectory ?? "").hasSuffix(arg) }
                        guard let r = model.remote.first, let tab else { print("move-there: no tab or machine"); fflush(stdout); return }
                        HandoffCoordinator.moveTab(tab, to: r.machine)
                    case "openlocal":
                        guard let s = model.background.first(where: { $0.name == arg || $0.command == arg }) else {
                            print("local: no background session \(arg)"); break
                        }
                        app.attachHost(s)
                        print("local: opened \(s.id) (\(arg))")
                    case "open":
                        guard let r = model.remote.first, let s = r.sessions.first(where: { $0.name == arg }) else {
                            print("remote: no session named \(arg)"); break
                        }
                        app.attachRemote(r.machine, s)
                        print("remote: opened \(s.id) (\(arg))")
                    case "new":
                        if let r = model.remote.first { app.newRemote(r.machine, agent: arg == "shell" ? nil : arg, directory: nil) }
                        print("remote: new \(arg)")
                    case "type":
                        let text = arg.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1B}")
                        key?.session.send(Array(text.utf8))
                    case "close":
                        key?.window?.performClose(nil)
                        print("remote: closed key tab")
                    case "kill":
                        guard let r = model.remote.first, let s = r.sessions.first(where: { $0.name == arg || $0.id == arg }) else {
                            print("remote: no session \(arg) to end"); break
                        }
                        app.killRemote(r.machine, s.id)
                        print("remote: ended \(s.id)")
                    case "resumepast":
                        guard let r = model.remote.first, let h = r.history.first(where: { $0.title.contains(arg) }) else {
                            print("remote: no past conversation matching \(arg)"); break
                        }
                        app.resumeRemote(r.machine, h)
                        print("remote: resumed \(h.id) in \(h.cwd)")
                    case "resumelocal":
                        let inFolder = model.sessions.filter { $0.cwd == arg && $0.pair == nil }.sorted { $0.mtime > $1.mtime }
                        guard inFolder.count > 1 else { print("local: no older conversation in \(arg)"); break }
                        app.resume(inFolder[1])
                        print("local: resumed older \(inFolder[1].id) (\(inFolder[1].title.prefix(40)))")
                    case "reminders":
                        if model.allReminders.isEmpty { print("reminders: none") }
                        for e in model.allReminders {
                            print("reminder: \(e.reminder.id) \(e.machine?.name ?? "local") fired=\(e.reminder.fired == true) \(e.reminder.title) session=\(e.reminder.sessionId ?? "-")")
                        }
                    case "proceed":
                        guard let e = model.allReminders.first(where: { $0.reminder.fired == true }) else { print("proceed: nothing due"); break }
                        ReminderCenter.shared.proceed(e.reminder.id, machine: e.machine)
                        print("proceed: \(e.reminder.id)")
                    case "notice":
                        print("notice: \(key?.focused?.session.notice ?? "none")")
                    case "groups":
                        let layout = SidebarView.layout(model, showAll: [])
                        for g in layout.groups.prefix(Int(arg) ?? 8) {
                            print("group: \(g.title) [\(g.key)] more=\(g.more)")
                            for l in g.live {
                                switch l {
                                case .tab(let t): print("  live tab: \(t.title) path=\(t.path) machine=\(t.machineID ?? "-")")
                                case .background(let s): print("  live background: \(s.name) \(s.cwd) origin=\(s.origin ?? "-")")
                                case .remote(let r, let s): print("  live \(r.machine.name): \(s.name) \(s.cwd) origin=\(s.origin ?? "-")")
                                }
                            }
                            for p in g.past {
                                switch p {
                                case .local(let s):
                                    let n = model.commitsSince[SidebarModel.commitKey(s)]
                                    print("  past: \(s.title.prefix(40)) newest=\(s.id == g.newest) commitsSince=\(n.map(String.init) ?? "-")")
                                case .remote(let r, let h): print("  past \(r.machine.name): \(h.title.prefix(40)) \(h.cwd)")
                                }
                            }
                        }
                        for r in model.remote {
                            let free = model.remoteFree(r).filter { !layout.placedRemote.contains("\(r.id)/\($0.id)") }
                            print("machine \(r.machine.name): note=\(r.note ?? "none") unplaced=\(free.map(\.name)) history=\(r.history.count)")
                        }
                        print("background unplaced=\(model.background.filter { !layout.placedHosts.contains($0.id) }.map(\.name))")
                        for l in layout.other {
                            switch l {
                            case .tab(let t): print("other tab: \(t.title)")
                            case .background(let s): print("other This Mac: \(s.name) \(s.cwd) devices=\(s.clientDevices?.map { "\($0.kind):\($0.name ?? "-")" } ?? [])")
                            case .remote(let r, let s): print("other \(r.displayName): \(s.name) \(s.cwd)")
                            }
                        }
                        print("phones: \(model.connectedPhones.map { "\($0.name) viewing \($0.viewing)" })")
                    default:
                        for r in model.remote {
                            print("remote: machine \(r.machine.name) note=\(r.note ?? "none") sessions=\(r.sessions.map { "\($0.name)[\(SessionNames.title($0))]" }) free=\(model.remoteFree(r).map(\.name)) projects=\(r.projects.count)")
                        }
                        for t in model.tabs { print("remote: tab \"\(t.title)\" remote=\(t.remoteIDs) host=\(t.hostIDs)") }
                    }
                    fflush(stdout)
                }
            }
        }
        if let shots = env["TERMAPP_WINDOW_SHOTS"] {
            for step in shots.split(separator: "|") {
                guard let colon = step.firstIndex(of: ":"), let delay = Double(step[..<colon]) else { continue }
                let path = String(step[step.index(after: colon)...])
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        guard let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible && ($0.tabGroup?.selectedWindow ?? $0) === $0 }),
                              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                                  [.boundsIgnoreFraming, .bestResolution]) else {
                            print("window shot failed: \(path)"); fflush(stdout); return
                        }
                        let rep = NSBitmapImageRep(cgImage: image)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        print("window shot: \(path) \(image.width)x\(image.height) [\(window.title)] modal=\(NSApp.modalWindow?.title ?? "none")"); fflush(stdout)
                    }
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
                    for r in m.runs { print("  run: \(r.mode) \(r.from)->\(r.to) \(r.state) \(r.brief)") }
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
        if let file = env["TERMAPP_CONTROL_FILE"] {
            Control.start(file)
        }
    }

    @MainActor
    enum Control {
        static var done = 0
        static var timer: Timer?
        static var recorder: Timer?
        static var frame = 0

        static func start(_ file: String) {
            FileManager.default.createFile(atPath: file, contents: nil)
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                    while done < lines.count {
                        let line = lines[done]
                        done += 1
                        perform(line)
                    }
                }
            }
        }

        static func perform(_ line: String) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            let action = parts[0], arg = parts.count > 1 ? parts[1] : ""
            let model = SidebarModel.shared
            model.refreshTabs()
            let key = (NSApp.keyWindow?.windowController as? TerminalWindowController)
                ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? TerminalWindowController }.first
            print("control: \(action)"); fflush(stdout)
            switch action {
            case "openlocal":
                guard let app = NSApp.delegate as? AppDelegate,
                      let s = model.background.first(where: { $0.name == arg || $0.command == arg }) else {
                    print("control: no background session \(arg)"); fflush(stdout); return
                }
                app.attachHost(s)
            case "type":
                let text = arg.replacingOccurrences(of: "\\r", with: "\r")
                key?.session.send(Array(text.utf8))
            case "typeto", "modeto":
                let f = arg.split(separator: ":", maxSplits: 1).map(String.init)
                guard f.count == 2 else { return }
                let tab = NSApp.windows.lazy.compactMap { $0.windowController as? TerminalWindowController }
                    .first { c in c.panes.contains { $0.session.process?.hostSessionID == f[0] } }
                guard let tab else { print("control: no tab for session \(f[0])"); fflush(stdout); return }
                if action == "typeto" {
                    let pane = tab.panes.first { $0.session.process?.hostSessionID == f[0] }
                    let submit = f[1].hasSuffix("\\r")
                    let body = submit ? String(f[1].dropLast(2)) : f[1]
                    pane?.session.send(Array(body.utf8))
                    if submit {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            MainActor.assumeIsolated { pane?.session.send([13]) }
                        }
                    }
                } else if let n = Int(f[1]), let mode = TerminalWindowController.ViewMode(rawValue: n) {
                    if let w = tab.window, let group = w.tabGroup, group.selectedWindow !== w { group.selectedWindow = w }
                    tab.setMode(mode)
                }
            case "pairopen":
                guard let run = PairRuns.recent().first else { return }
                PairRunWindows.show(run)
                if let main = mainWindow, let w = NSApp.windows.first(where: { $0.isVisible && $0 !== main && !($0.windowController is TerminalWindowController) && $0.title.contains(run.brief) }) {
                    let m = main.frame, size = w.frame.size
                    w.setFrameOrigin(NSPoint(x: m.midX - size.width / 2, y: m.midY - size.height / 2))
                }
            case "pairclose":
                for w in NSApp.windows where w.isVisible && !(w.windowController is TerminalWindowController) && w.title.hasPrefix("Codex") { w.close() }
            case "applyfix":
                guard let run = PairRuns.recent().first,
                      let data = FileManager.default.contents(atPath: run.dir + "/findings.json"),
                      let found = try? JSONDecoder().decode(ReviewFindings.self, from: data) else {
                    print("control: no findings"); fflush(stdout); return
                }
                let n = Int(arg) ?? 0
                guard found.findings.indices.contains(n) else { return }
                FindingsView.apply(found.findings[n], run: run, tabbedWith: mainWindow)?.setMode(.terminal)
            case "main":
                NSApp.windows.first { $0.windowController is TerminalWindowController }?.makeKeyAndOrderFront(nil)
            case "record":
                let f = arg.split(separator: ":").map(String.init)
                guard let dir = f.first else { return }
                let every = f.count > 1 ? Double(f[1]) ?? 0.33 : 0.33
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                recorder?.invalidate()
                recorder = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
                    MainActor.assumeIsolated { shot(dir) }
                }
            case "recordstop":
                recorder?.invalidate(); recorder = nil
                print("control: recorded \(frame) frames"); fflush(stdout)
            default:
                print("control: unknown \(line)"); fflush(stdout)
            }
        }

        static var mainWindow: NSWindow? {
            NSApp.orderedWindows.first { $0.isVisible && $0.windowController is TerminalWindowController }
        }

        static func shot(_ dir: String) {
            guard let main = mainWindow else { return }
            let above = NSApp.orderedWindows.filter { $0.isVisible }.prefix { $0 !== main }
            let ids = (Array(above) + [main]).map { CGWindowID($0.windowNumber) }
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            let f = main.frame
            let rect = CGRect(x: f.minX, y: screenH - f.maxY, width: f.width, height: f.height)
            var raw = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
            guard let array = CFArrayCreate(nil, &raw, raw.count, nil) else { return }
            let options: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
            guard let image = ids.count == 1
                    ? CGWindowListCreateImage(.null, .optionIncludingWindow, ids[0], options)
                    : CGImage(windowListFromArrayScreenBounds: rect, windowArray: array, imageOption: options)
            else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
            let ms = Int(Date().timeIntervalSince1970 * 1000)
            try? data.write(to: URL(fileURLWithPath: "\(dir)/\(ms).jpg"))
            frame += 1
        }
    }
}

@MainActor
enum DebugClick {
    static func click(x: Double, y: Double) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.windowController is TerminalWindowController }), let frame = window.contentView?.superview else {
            print("click: no window"); fflush(stdout); return
        }
        let point = NSPoint(x: x, y: window.frame.height - y)
        let hit = frame.hitTest(point)
        let before = window.title
        var chain: [String] = []
        var v = hit
        while let view = v, chain.count < 8 { chain.append("\(type(of: view))\(view.frame)"); v = view.superview }
        print("click: chain " + chain.joined(separator: " < "))
        print("click: at \(x),\(y) hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing"); showing \(before)")
        fflush(stdout)
        let t = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ dt: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: t + dt,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        if let up = event(.leftMouseUp, 0.05) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, 0) { NSApp.sendEvent(down) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                let now = NSApp.keyWindow?.title ?? "none"
                print("click: after, showing \(now) (\(now == before ? "unchanged" : "changed")); sidebar \(SidebarModel.shared.visible ? "shown" : "hidden")")
                fflush(stdout)
            }
        }
    }
}

@MainActor
enum PerfCounters {
    private static var counts: [String: Int] = [:]
    private static var cancellables: [AnyCancellable] = []
    static let enabled = ProcessInfo.processInfo.environment["TERMAPP_PERF"] != nil

    static func tick(_ name: String) {
        guard enabled else { return }
        counts[name, default: 0] += 1
    }

    static func watch<O: ObservableObject>(_ object: O, _ name: String) {
        guard enabled else { return }
        cancellables.append(object.objectWillChange.sink { _ in MainActor.assumeIsolated { tick(name) } })
    }

    static func start() {
        watch(SidebarModel.shared, "publish.sidebarModel")
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let line = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                print("perf(5s): \(line)")
                fflush(stdout)
                counts = [:]
            }
        }
    }
}
