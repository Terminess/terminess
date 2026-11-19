import AppKit
import SwiftUI
import TermHost

@MainActor
enum AgentEvents {
    enum State { case off, on, outdated, taken }
    enum AgentKind: String { case claude, codex }

    private static var offeredThisLaunch: Set<String> = []

    static func state(_ a: AgentKind) -> State {
        guard let exe = HostService.executable else { return .off }
        switch a {
        case .claude:
            switch ClaudeHooks.status(executable: exe) { case .off: return .off; case .on: return .on; case .outdated: return .outdated }
        case .codex:
            let hooks = CodexHooks.status(executable: exe)
            switch CodexNotify.status(executable: exe) {
            case .off: return hooks == .off ? .off : .outdated
            case .on: return hooks == .on ? .on : .outdated
            case .outdated: return .outdated
            case .taken: return .taken
            }
        }
    }

    private static func key(_ a: AgentKind, _ what: String) -> String {
        a == .claude ? "claudeHooks\(what)" : "codexNotify\(what)"
    }

    static func refreshIfConsented() {
        for a in [AgentKind.claude, .codex] where UserDefaults.standard.bool(forKey: key(a, "Consented")) && state(a) == .outdated {
            try? set(a, true)
        }
        for a in [AgentKind.claude, .codex] where UserDefaults.standard.bool(forKey: key(a, "Consented")) {
            giveTools(a)
        }
    }

    static func giveTools(_ a: AgentKind) {
        let flag = key(a, "ToolsDefaulted")
        guard !UserDefaults.standard.bool(forKey: flag), let t = AgentTools.Agent(rawValue: a.rawValue) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        if !AgentTools.isOn(t) { try? AgentTools.set(t, true) }
    }

    static func started(_ agentID: String) {
        guard let a = AgentKind(rawValue: agentID), !offeredThisLaunch.contains(agentID),
              Settings.shared.keepSessions, HostService.executable != nil else { return }
        offeredThisLaunch.insert(agentID)
        switch state(a) {
        case .on, .taken: return
        case .outdated: refreshIfConsented()
        case .off:
            guard !UserDefaults.standard.bool(forKey: key(a, "Answered")) else { return }
            UserDefaults.standard.set(true, forKey: key(a, "Answered"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { ask(a) } }
        }
    }

    private static func ask(_ a: AgentKind) {
        let alert = NSAlert()
        if a == .claude {
            alert.messageText = "Let Claude Code tell Terminess what it's doing?"
            alert.informativeText = """
                Terminess then knows exactly when Claude is working, has finished, or is waiting for you, so Chat, the busy \
                indicators and iPhone notifications are accurate instead of estimated, and you can approve or deny what \
                Claude asks permission for from Terminess or your iPhone.

                This adds a small entry to Claude Code's settings (~/.claude/settings.json), and the Terminess tools (open tabs, \
                notify you, ask you, set reminders, borrow your Mac from a server), all only acting inside Terminess. \
                Your other settings stay as they are, and you can turn them off in Settings, Agents.
                """
        } else {
            alert.messageText = "Let Codex tell Terminess when it finishes or needs approval?"
            alert.informativeText = """
                Terminess then knows the moment a Codex turn ends, and you can approve or deny Codex's commands from \
                Terminess or your iPhone.

                This sets notify in Codex's settings (~/.codex/config.toml) and adds a hook (~/.codex/hooks.json), both \
                Terminess commands that only act inside Terminess, plus the Terminess tools (tabs, notify, ask, reminders, \
                borrow your Mac). Codex asks you once to trust the hook: type /hooks in Codex. Your other settings stay as \
                they are, and you can turn them off in Settings, Agents.
                """
        }
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try set(a, true) } catch { report(error) }
    }

    static func set(_ a: AgentKind, _ on: Bool) throws {
        UserDefaults.standard.set(true, forKey: key(a, "Answered"))
        UserDefaults.standard.set(on, forKey: key(a, "Consented"))
        guard let exe = HostService.executable else { return }
        switch (a, on) {
        case (.claude, true):
            try ClaudeHooks.install(executable: exe)
            giveTools(.claude)
        case (.claude, false): try ClaudeHooks.uninstall()
        case (.codex, true):
            try CodexNotify.install(executable: exe)
            try CodexHooks.install(executable: exe)
            giveTools(.codex)
        case (.codex, false):
            try CodexNotify.uninstall()
            try CodexHooks.uninstall()
        }
    }

    static func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't change the agent's settings"
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}

struct AgentEventsToggle: View {
    let agent: AgentEvents.AgentKind
    @State private var on = false
    @State private var taken = false

    var body: some View {
        Toggle(agent == .claude ? "Let Claude Code report when it's working, finished or needs you"
                                : "Let Codex report when it finishes or needs approval" + (taken ? " (notify is set to another program)" : ""),
               isOn: Binding(get: { on }, set: { value in
                   do { try AgentEvents.set(agent, value); on = value } catch { AgentEvents.report(error) }
               }))
            .disabled(taken)
            .help(agent == .claude ? "Adds hooks to ~/.claude/settings.json that only act inside Terminess sessions."
                                   : "Sets notify in ~/.codex/config.toml to a command that only acts inside Terminess sessions.")
            .onAppear {
                let s = AgentEvents.state(agent)
                on = s == .on
                taken = s == .taken
            }
    }
}
