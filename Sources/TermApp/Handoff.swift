import AppKit
import SwiftUI
import TermHost
import TermHandoff

@MainActor
enum HandoffCoordinator {
    static var localRoot: String {
        get { UserDefaults.standard.string(forKey: "handoffLocalRoot").flatMap { $0.isEmpty ? nil : $0 } ?? "~/github" }
        set { UserDefaults.standard.set(newValue, forKey: "handoffLocalRoot") }
    }

    private static var busy = false

    static func moveToMac(_ machine: RemoteMachine, sessionID: String) {
        guard !busy else { return }
        busy = true
        let root = localRoot, remoteRoot = machine.repoRoot ?? "~/github"
        DispatchQueue.global().async {
            guard let peer = HandoffPeer.ssh(host: machine.host, port: machine.port, path: machine.path) else {
                return finish(error: "Can't reach terminessd on \(machine.name).")
            }
            switch HandoffTransfer.info(peer, session: sessionID) {
            case .failure(let e): finish(error: e.description)
            case .success(let info):
                onMain {
                    guard confirm(info, from: machine.name, to: "this Mac") else { busy = false; return }
                    DispatchQueue.global().async {
                        let result = HandoffTransfer.export(peer, session: sessionID)
                            .flatMap { Handoff.importBundle($0, sourceRoot: remoteRoot, targetRoot: root) }
                        peer.close()
                        onMain {
                            busy = false
                            switch result {
                            case .failure(let e): fail(e.description)
                            case .success(let r):
                                (NSApp.delegate as? AppDelegate)?.openMoved(directory: r.cwd, command: r.resumeCommand, conversation: info.conversation)
                                SidebarModel.shared.monitor(machine.id)?.refresh()
                                report(r, to: "this Mac")
                            }
                        }
                    }
                }
            }
        }
    }

    static func moveTab(_ controller: TerminalWindowController, to machine: RemoteMachine) {
        guard !busy, let process = controller.focused?.session.process else { return }
        let agent = Agent.detect(process.foregroundCommand)?.id ?? ""
        let pid = process.foregroundPID
        switch Handoff.info(pid: pid, agent: agent) {
        case .failure(let e): fail(e.description); return
        case .success(let info):
            guard confirm(info, from: "this Mac", to: machine.name) else { return }
            busy = true
            let root = localRoot, remoteRoot = machine.repoRoot ?? "~/github"
            DispatchQueue.global().async {
                guard let peer = HandoffPeer.ssh(host: machine.host, port: machine.port, path: machine.path) else {
                    return finish(error: "Can't reach terminessd on \(machine.name), so nothing was stopped.")
                }
                guard Handoff.stop(pid: pid) else { return finish(error: "The agent didn't stop within 15 seconds, so nothing was moved.") }
                let fresh = Handoff.describe(agent: info.agent, conversation: info.conversation, cwd: info.cwd, transcript: info.transcriptPath)
                let result = Handoff.bundle(fresh)
                    .flatMap { HandoffTransfer.importRemote(peer, bundle: $0, sourceRoot: root, targetRoot: remoteRoot) }
                peer.close()
                onMain {
                    busy = false
                    switch result {
                    case .failure(let e):
                        fail(e.description + "\n\nThe agent here has stopped; resume it with: \(info.resumeCommand)")
                    case .success(let r):
                        let item = HistoryItem(id: info.conversation, agent: info.agent, cwd: r.cwd, title: "", used: Date().timeIntervalSince1970)
                        (NSApp.delegate as? AppDelegate)?.resumeRemote(machine, item)
                        SidebarModel.shared.monitor(machine.id)?.refresh()
                        report(r, to: machine.name)
                    }
                }
            }
        }
    }


    private nonisolated static func finish(error: String) {
        onMain { busy = false; fail(error) }
    }

    nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    private static var auto: Bool { ProcessInfo.processInfo.environment["TERMAPP_HANDOFF_AUTO"] != nil }

    private static func confirm(_ info: HandoffInfo, from: String, to: String) -> Bool {
        if auto { print("handoff confirm: \(info.agent) \(info.conversation) \(from) -> \(to)"); fflush(stdout); return true }
        let alert = NSAlert()
        alert.messageText = "Move this \(info.agent == "codex" ? "Codex" : "Claude Code") conversation to \(to)?"
        var lines = ["The agent on \(from) stops, and the conversation carries on \(to == "this Mac" ? "here" : "on " + to) in a new tab."]
        if let repo = info.repoName {
            lines.append("Repository: \(repo) on \(info.branch ?? "?") at \(String((info.head ?? "?").prefix(8))). Both copies must be on that commit.")
        }
        lines.append(info.changedFiles == 0 ? "No uncommitted changes."
                     : "\(info.changedFiles) uncommitted file\(info.changedFiles == 1 ? "" : "s") travel with it, uncommitted. Different changes already on \(to) are stashed first, never lost.")
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func report(_ r: HandoffResult, to: String) {
        if auto { print("handoff done: \(r.cwd) | \(r.resumeCommand) | \(r.notes.joined(separator: " ")) | backups \(r.backups.count)"); fflush(stdout); return }
        guard !r.notes.isEmpty || !r.backups.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Moved to \(to)"
        alert.informativeText = (r.notes + r.backups.map { "Backup: \($0)" }).joined(separator: "\n\n")
        alert.runModal()
    }

    private static func fail(_ text: String) {
        if auto { print("handoff failed: \(text)"); fflush(stdout); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't move the conversation"
        alert.informativeText = text
        alert.runModal()
    }
}


@MainActor
final class BorrowCenter {
    static let shared = BorrowCenter()

    struct Request: Identifiable, Sendable {
        let id: String
        let machine: RemoteMachine
        let from: String
        let task: String
        var agent: String? = nil
        var state: String = "asking"
    }

    nonisolated static let runners = ["claude", "codex", "gemini"]
    nonisolated static func runnerName(_ a: String) -> String {
        a == "claude" ? "Claude Code" : a == "codex" ? "Codex" : a == "gemini" ? "Gemini CLI" : a
    }

    nonisolated static func installed(_ tool: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(tool) >/dev/null 2>&1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func runner(for r: Request) -> (agent: String, fallback: Bool, wanted: String)? {
        let setting = Settings.shared.borrowAgent
        let wanted = setting == "match" ? (r.agent.flatMap { runners.contains($0) ? $0 : nil } ?? "claude") : setting
        if installed(wanted) { return (wanted, false, wanted) }
        if let other = runners.first(where: { $0 != wanted && installed($0) }) { return (other, true, wanted) }
        return nil
    }

    private var panels: [String: NSPanel] = [:]
    private var running: [String: Process] = [:]

    func request(_ r: Request, reply: @escaping @Sendable (Int, String) -> Void) {
        if ProcessInfo.processInfo.environment["TERMAPP_BORROW_AUTO"] == "allow" {
            if let c = BorrowCenter.runner(for: r) { allow(r, runner: c.agent, reply: reply) } else { reply(1, "No agent is installed on the Mac.") }
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                            styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Borrow this Mac"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        guard let choice = BorrowCenter.runner(for: r) else {
            reply(1, "No agent is installed on the Mac to do this (Claude Code, Codex or Gemini CLI).")
            return
        }
        panel.contentView = NSHostingView(rootView: BorrowRequestView(request: r, runner: choice.agent, fallback: choice.fallback, wanted: choice.wanted, decide: { [weak self] ok in
            self?.close(r.id)
            if ok { self?.allow(r, runner: choice.agent, reply: reply) } else { reply(1, "The person declined to lend their Mac for this task.") }
        }))
        panel.center()
        panel.orderFrontRegardless()
        panels[r.id] = panel
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func close(_ id: String) { panels.removeValue(forKey: id)?.close() }

    func cancel(_ id: String) {
        close(id)
        if let p = running.removeValue(forKey: id), p.isRunning { p.terminate() }
    }

    private func allow(_ r: Request, runner: String, reply: @escaping @Sendable (Int, String) -> Void) {
        let dir = NSHomeDirectory() + "/.local/state/terminess/borrow/\(r.id)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let system = "You are doing one task for an agent on another machine (\(r.from)), which can't use this Mac's browser or apps. "
            + "Do exactly the task, then reply with a concise final answer only: what you found or did. Don't change files outside this folder."
        let command: String
        switch runner {
        case "codex":
            let devtools = ["-c", "'mcp_servers.chrome-devtools.command=\"npx\"'",
                            "-c", "'mcp_servers.chrome-devtools.args=[\"-y\",\"chrome-devtools-mcp@latest\"]'",
                            "-c", "'mcp_servers.chrome-devtools.startup_timeout_sec=90'",
                            "-c", "'mcp_servers.chrome-devtools.default_tools_approval_mode=\"approve\"'"].joined(separator: " ")
            command = "codex exec --skip-git-repo-check -c 'approval_policy=\"never\"' -s workspace-write " + devtools + " -o " + shq(dir + "/answer.txt") + " "
                + shq(system + " Use the browser tools for anything on the web.\n\nTask: " + r.task) + " >/dev/null"
        case "gemini":
            command = "gemini --yolo -p " + shq(system + "\n\nTask: " + r.task)
        default:
            command = "claude -p --chrome --output-format text --permission-mode acceptEdits "
                + "--allowedTools mcp__claude-in-chrome WebFetch WebSearch Read "
                + "--append-system-prompt " + shq(system) + " " + shq(r.task)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDE") || k == "TERMINESS_SESSION" { env[k] = nil }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        let id = r.id
        p.terminationHandler = { proc in
            var text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if runner == "codex", let answer = try? String(contentsOfFile: dir + "/answer.txt", encoding: .utf8) {
                text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            HandoffCoordinator.onMain {
                BorrowCenter.shared.running[id] = nil
                let who = "Done on the Mac by \(BorrowCenter.runnerName(runner)).\n\n"
                reply(proc.terminationStatus == 0 ? 0 : 1, text.isEmpty ? "The Mac's agent (\(BorrowCenter.runnerName(runner))) finished without an answer." : who + String(text.suffix(20000)))
            }
        }
        if ProcessInfo.processInfo.environment["TERMAPP_SCRIPT"] != nil { print("borrow: running \(r.id) with \(runner): \(r.task)"); fflush(stdout) }
        do { try p.run(); running[id] = p } catch { reply(1, "Couldn't start Claude Code on the Mac: \(error)") }
    }

    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct BorrowRequestView: View {
    let request: BorrowCenter.Request
    let runner: String
    let fallback: Bool
    let wanted: String
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(.orange)
                Text("\(request.machine.name) wants to borrow this Mac").font(.headline)
            }
            Text("An agent there (\(request.from)) asks for this to be done here and the answer sent back. "
                 + "\(BorrowCenter.runnerName(runner)) will do it" + (runner == "claude" ? ", with your Chrome" : "")
                 + (fallback ? " (\(BorrowCenter.runnerName(wanted)) isn't installed on this Mac)." : ":"))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(request.task).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            HStack {
                Spacer()
                Button("Deny") { decide(false) }.keyboardShortcut(.cancelAction)
                Button("Allow") { decide(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
