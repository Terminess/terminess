import AppKit
import SwiftUI
import TermTranscript
import UserNotifications

@MainActor
final class DoctorModel: ObservableObject {
    enum Status { case ok, warning, problem, info }

    struct Check: Identifiable {
        let id = UUID()
        let title: String
        let status: Status
        let detail: String
        var fix: (label: String, action: () -> Void)?
    }

    @Published var checks: [Check] = []
    @Published var running = false

    func run() {
        running = true
        Task.detached(priority: .userInitiated) {
            let tools = DoctorModel.probeTools()
            let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            await MainActor.run {
                let model = DoctorModel.sharedForWindow
                model.checks = DoctorModel.buildChecks(tools: tools, notifications: notifications)
                model.running = false
            }
        }
    }

    static let sharedForWindow = DoctorModel()


    struct ToolInfo: Sendable {
        var claude: String?
        var claudePaths: [String] = []
        var codex: String?
        var gh: String?
        var ghAuthed = false
        var swapUsedGB: Double = 0
        var swapTotalGB: Double = 0
        var claudeCleanupDays: Int?
        var formats: [(agent: String, version: String?, unknown: [String: Int])] = []
    }

    nonisolated static func surveyFormats() -> [(agent: String, version: String?, unknown: [String: Int])] {
        let fm = FileManager.default
        let home = Transcript.home
        func newest(_ paths: [String], _ n: Int) -> [String] {
            Array(paths.sorted { (Transcript.mtime($0) ?? .distantPast) > (Transcript.mtime($1) ?? .distantPast) }.prefix(n))
        }
        var claude: [String] = []
        let projects = home + "/.claude/projects"
        for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            for f in (try? fm.contentsOfDirectory(atPath: projects + "/" + dir)) ?? [] where f.hasSuffix(".jsonl") {
                claude.append(projects + "/" + dir + "/" + f)
            }
        }
        var codex: [String] = []
        if let e = fm.enumerator(atPath: home + "/.codex/sessions") {
            for case let f as String in e where f.hasSuffix(".jsonl") { codex.append(home + "/.codex/sessions/" + f) }
        }
        var out: [(agent: String, version: String?, unknown: [String: Int])] = []
        for (agent, files) in [("claude", newest(claude, 5)), ("codex", newest(codex, 3))] where !files.isEmpty {
            var version: String?
            var unknown: [String: Int] = [:]
            for f in files {
                let s = Transcript.survey(f, agent: agent)
                version = version ?? s.version
                unknown.merge(s.unknown, uniquingKeysWith: +)
            }
            out.append((agent, version, unknown))
        }
        return out
    }

    nonisolated static func shell(_ command: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", command + " 2>/dev/null"]
        var env = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID"] { env[key] = nil }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }

    nonisolated static func probeTools() -> ToolInfo {
        var t = ToolInfo()
        func lastLine(_ s: String?, containing word: String) -> String? {
            s?.split(separator: "\n").last { $0.localizedCaseInsensitiveContains(word) }.map(String.init)
        }
        t.claude = lastLine(shell("command claude --version"), containing: "claude")
        t.codex = lastLine(shell("command codex --version"), containing: "codex")
        t.gh = lastLine(shell("command gh --version"), containing: "gh version")
        t.claudePaths = (shell("which -a claude") ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
        var seen = Set<String>()
        t.claudePaths = t.claudePaths.filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
        if t.gh != nil { t.ghAuthed = shell("command gh auth status >/dev/null 2>&1 && echo yes") == "yes" }
        if let swap = shell("sysctl -n vm.swapusage") {
            func value(_ key: String) -> Double {
                guard let r = swap.range(of: "\(key) = ") else { return 0 }
                let rest = swap[r.upperBound...]
                let num = rest.prefix { "0123456789.".contains($0) }
                return (Double(num) ?? 0) / 1024
            }
            t.swapTotalGB = value("total")
            t.swapUsedGB = value("used")
        }
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: settings),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t.claudeCleanupDays = obj["cleanupPeriodDays"] as? Int
        }
        t.formats = surveyFormats()
        return t
    }


    static func buildChecks(tools t: ToolInfo, notifications: UNAuthorizationStatus) -> [Check] {
        var c: [Check] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        c.append(t.claude.map { Check(title: "Claude Code", status: .ok, detail: $0) }
                 ?? Check(title: "Claude Code", status: .warning, detail: "Not found on your PATH. Install it to use Claude in a tab.",
                          fix: ("Open install page", { NSWorkspace.shared.open(URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!) })))
        if t.claudePaths.count > 1 {
            c.append(Check(title: "Several Claude Code installs", status: .warning,
                           detail: "Found \(t.claudePaths.count): \(t.claudePaths.joined(separator: ", ")). The first one on your PATH runs; the others can be out of date and cause confusion. Remove the ones you do not use."))
        }
        c.append(t.codex.map { Check(title: "Codex", status: .ok, detail: $0) }
                 ?? Check(title: "Codex", status: .info, detail: "Not installed. Optional; pair handoffs to Codex need it."))

        let leaked = ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID"].filter { ProcessInfo.processInfo.environment[$0] != nil }
        if leaked.isEmpty {
            c.append(Check(title: "Agent session markers", status: .ok, detail: "None inherited."))
        } else {
            c.append(Check(title: "Agent session markers", status: .info,
                           detail: "This app was launched from inside a Claude session and inherited \(leaked.joined(separator: ", ")). New tabs strip them, so Claude still saves transcripts here. Other terminals started the same way may not."))
        }

        if let days = t.claudeCleanupDays, days >= 60 {
            c.append(Check(title: "Claude transcript history", status: .ok, detail: "Kept for \(days) days, so past sessions stay in the sidebar."))
        } else {
            c.append(Check(title: "Claude transcript history", status: .warning,
                           detail: "Claude Code deletes transcripts after \(t.claudeCleanupDays ?? 30) days, so older sessions disappear from the sidebar. Set cleanupPeriodDays in ~/.claude/settings.json to keep them longer."))
        }

        for (agent, installed) in [(AgentEvents.AgentKind.claude, t.claude != nil), (.codex, t.codex != nil)] where installed {
            let name = agent == .claude ? "Claude Code" : "Codex"
            let turnOn: () -> Void = { do { try AgentEvents.set(agent, true) } catch { AgentEvents.report(error) } }
            switch AgentEvents.state(agent) {
            case .on:
                c.append(Check(title: "\(name) status reports", status: .ok,
                               detail: agent == .claude ? "On: Claude Code tells Terminess when it starts, finishes or needs you."
                                                        : "On: Codex tells Terminess when a turn finishes."))
            case .outdated:
                c.append(Check(title: "\(name) status reports", status: .warning,
                               detail: "Set up for a different copy of Terminess, so reports aren't arriving.", fix: ("Refresh", turnOn)))
            case .taken:
                c.append(Check(title: "\(name) status reports", status: .info,
                               detail: "notify in ~/.codex/config.toml already runs another program, and Codex allows only one, so Terminess left it alone and estimates from the screen instead."))
            case .off:
                c.append(Check(title: "\(name) status reports", status: .info,
                               detail: "Off. Terminess estimates from the screen when \(name) is busy or done. Turning this on edits \(agent == .claude ? "~/.claude/settings.json" : "~/.codex/config.toml") with an entry that only acts inside Terminess.",
                               fix: ("Turn on", turnOn)))
            }
        }

        for f in t.formats {
            let name = f.agent == "claude" ? "Claude Code" : "Codex"
            let who = [name, f.version].compactMap { $0 }.joined(separator: " ")
            if f.unknown.isEmpty {
                c.append(Check(title: "\(name) transcripts", status: .ok, detail: "Everything \(who) writes is understood, so Chat shows the whole conversation."))
            } else {
                let kinds = f.unknown.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
                c.append(Check(title: "\(name) transcripts", status: .warning,
                               detail: "\(who) writes kinds of record this version of Terminess doesn't know: \(kinds). Messages with text in them still show in Chat; anything else is skipped until Terminess learns the new format."))
            }
        }

        if Privacy.hasFullDiskAccess {
            c.append(Check(title: "Full Disk Access", status: .ok, detail: "On: agents can read any file you drop in, including screenshot thumbnails."))
        } else {
            c.append(Check(title: "Full Disk Access", status: .warning,
                           detail: "Off. macOS asks before Terminess opens Desktop, Documents or Downloads, but some places (screenshot thumbnails, Mail, other apps' data) need Full Disk Access. It applies once Terminess and its session service (terminessd) restart; open tabs keep the old access until then.",
                           fix: ("Open Privacy Settings", { Privacy.openFullDiskAccessSettings() })))
        }

        let integration = Settings.shared.shellIntegration
        let installed = fm.fileExists(atPath: ShellIntegration.directory.appendingPathComponent(".zshenv").path)
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if !shellPath.hasSuffix("zsh") {
            c.append(Check(title: "Shell integration", status: .info, detail: "Your shell is \(shellPath); integration currently covers zsh only."))
        } else if integration && installed {
            c.append(Check(title: "Shell integration", status: .ok, detail: "On: prompt jumps, last output and long-command notifications work in new tabs."))
        } else {
            c.append(Check(title: "Shell integration", status: .warning, detail: "Off. Prompt jumps and long-command notifications need it.",
                           fix: ("Turn on", { Settings.shared.shellIntegration = true; ShellIntegration.install() })))
        }

        switch notifications {
        case .authorized, .provisional:
            c.append(Check(title: "Notifications", status: .ok, detail: "Allowed: you will hear when an agent needs you."))
        case .denied:
            c.append(Check(title: "Notifications", status: .warning, detail: "Turned off for this app, so agents finishing in the background will not alert you.",
                           fix: ("Open System Settings", { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) })))
        default:
            c.append(Check(title: "Notifications", status: .info, detail: Bundle.main.bundlePath.hasSuffix(".app")
                           ? "Not decided yet; macOS will ask the first time an agent needs you." : "Only available in the app bundle, not in development builds."))
        }

        if t.gh == nil {
            c.append(Check(title: "GitHub CLI", status: .info, detail: "Not installed. The Issues section needs gh (brew install gh)."))
        } else if !t.ghAuthed {
            c.append(Check(title: "GitHub CLI", status: .warning, detail: "\(t.gh!), but not signed in. Run gh auth login to list issues."))
        } else {
            c.append(Check(title: "GitHub CLI", status: .ok, detail: "\(t.gh!), signed in."))
        }

        let pairOK = fm.isExecutableFile(atPath: home + "/.local/bin/pair")
        let sessionsOK = fm.isExecutableFile(atPath: home + "/.local/bin/sessions")
        c.append(Check(title: "pair and sessions tools", status: pairOK && sessionsOK ? .ok : .info,
                       detail: pairOK && sessionsOK ? "Both installed in ~/.local/bin." : "Missing \(pairOK ? "" : "pair ")\(sessionsOK ? "" : "sessions"); the sidebar's Pair and Sessions sections need them."))

        if t.swapTotalGB > 0 {
            let ratio = t.swapUsedGB / t.swapTotalGB
            let detail = String(format: "%.1f of %.1f GB swap in use.", t.swapUsedGB, t.swapTotalGB)
            if ratio > 0.6 {
                c.append(Check(title: "Memory", status: .warning,
                               detail: detail + " The Mac is short of memory, which slows everything (builds included). Idle parking stops agent tabs you are not using.",
                               fix: Settings.shared.idleParking ? nil : ("Turn on idle parking", { Settings.shared.idleParking = true })))
            } else {
                c.append(Check(title: "Memory", status: .ok, detail: detail))
            }
        }

        c.append(OnDeviceModel.isAvailable
                 ? Check(title: "On-device model", status: .ok, detail: "Apple Intelligence is available for commit messages, at no cost.")
                 : Check(title: "On-device model", status: .info, detail: "Apple Intelligence is not available, so commit messages are written by a simple fallback."))
        return c
    }
}

struct DoctorView: View {
    @ObservedObject var model = DoctorModel.sharedForWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Doctor").font(.title2.weight(.semibold))
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("Check Again") { model.run() }.disabled(model.running)
            }
            .padding()
            Divider()
            List(model.checks) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(check.status))
                        .foregroundStyle(color(check.status))
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.title).fontWeight(.medium)
                        Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let fix = check.fix {
                            Button(fix.label) { fix.action(); model.run() }
                                .controlSize(.small)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 560, height: 560)
        .onAppear { model.run() }
    }

    private func symbol(_ s: DoctorModel.Status) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }

    private func color(_ s: DoctorModel.Status) -> Color {
        switch s {
        case .ok: return .green
        case .warning: return .orange
        case .problem: return .red
        case .info: return .secondary
        }
    }
}
