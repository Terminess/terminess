import AppKit
import SwiftUI
import TermHost

@MainActor
final class DashboardChanges: ObservableObject {
    static let shared = DashboardChanges()
    @Published private(set) var stats: [String: String] = [:]
    @Published private(set) var schedules: [AgentSchedule] = []

    func removeSchedule(_ id: String) {
        AgentSchedules.save(AgentSchedules.load().filter { $0.id != id })
        schedules = AgentSchedules.load()
    }
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { DashboardChanges.shared.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func folders() -> [String] {
        let model = SidebarModel.shared
        let tabs = model.tabs.filter { $0.branch != nil }.map(\.directory)
        let jobs = model.jobs.compactMap { DashboardChanges.jobWorktree($0.id) }
        return Array(Set(tabs + jobs))
    }

    nonisolated static func jobWorktree(_ id: String) -> String? {
        let meta = (try? String(contentsOfFile: SidebarModel.pairState + "/parallel/\(id)/meta", encoding: .utf8)) ?? ""
        let wt = meta.split(separator: "\n").first { $0.hasPrefix("wt=") }.map { String($0.dropFirst(3)) }
        return wt.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    func refresh() {
        let list = AgentSchedules.load()
        if list != schedules { schedules = list }
        let dirs = folders()
        Task.detached(priority: .utility) {
            var out: [String: String] = [:]
            for d in dirs { out[d] = DashboardChanges.shortstat(d) }
            await MainActor.run { if out != DashboardChanges.shared.stats { DashboardChanges.shared.stats = out } }
        }
    }

    nonisolated static func shortstat(_ dir: String) -> String {
        func git(_ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = git(["merge-base", "HEAD", "@{upstream}"]).isEmpty ? "HEAD" : git(["merge-base", "HEAD", "@{upstream}"])
        let stat = git(["diff", "--shortstat", base])
        let untracked = git(["ls-files", "--others", "--exclude-standard"]).split(separator: "\n").count
        var parts: [String] = []
        if !stat.isEmpty {
            let files = stat.firstMatch(of: /(\d+) files? changed/).map { "\($0.1) file\($0.1 == "1" ? "" : "s")" }
            let plus = stat.firstMatch(of: /(\d+) insertions?/).map { "+\($0.1)" }
            let minus = stat.firstMatch(of: /(\d+) deletions?/).map { "\u{2212}\($0.1)" }
            parts = [files, plus, minus].compactMap { $0 }
        }
        if untracked > 0 { parts.append("\(untracked) new") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " ")
    }
}

struct AgentsDashboard: View {
    var onClose: () -> Void = {}
    @ObservedObject var model = SidebarModel.shared
    @ObservedObject var changes = DashboardChanges.shared
    @AppStorage("agents.tabsOpen") private var tabsOpen = true
    @AppStorage("agents.backgroundOpen") private var backgroundOpen = true
    @AppStorage("agents.jobsOpen") private var jobsOpen = true
    @AppStorage("agents.runsOpen") private var runsOpen = true
    @AppStorage("agents.schedulesOpen") private var schedulesOpen = true

    private var agentTabs: [OpenTab] { model.tabs.filter { ["claude", "codex", "ollama", "harness"].contains($0.command) || $0.branch != nil } }
    private var inTabs: Set<String> { Set(model.tabs.flatMap(\.hostIDs)) }
    private var background: [SessionInfo] { model.background.filter { !inTabs.contains($0.id) } }
    private var liveJobs: [PairJob] { model.jobs.filter { !["applied", "discarded"].contains($0.state) } }

    var body: some View {
        PageShell(onClose: onClose) {
            PageTitle(title: "Agents", subtitle: summary) {
                Button { NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil) } label: {
                    Label("New session", systemImage: "plus")
                }
                .buttonStyle(.primary)
            }
            if agentTabs.isEmpty && background.isEmpty && liveJobs.isEmpty && model.runs.isEmpty && changes.schedules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("No agents at work").font(.system(size: 15, weight: .medium))
                    Text("Start Claude Code or Codex in a tab, a worktree tab or with pair, and they show here with what they've changed.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            if !agentTabs.isEmpty {
                PageSection(title: "In tabs", count: agentTabs.count, expanded: $tabsOpen) {
                    PageGroup {
                        ForEach(agentTabs) { tab in
                            PageRow(symbol: icon(tab.command), tint: tint(tab.command), title: tab.title,
                                    status: tab.attention ? ("Needs you", .orange) : tab.busy ? ("Working", .connected) : ("Idle", Color.secondary.opacity(0.6)),
                                    detail: SidebarModel.tilde(tab.directory),
                                    mono: tab.branch.map { b in "\(b) \u{00B7} \(changes.stats[tab.directory] ?? "\u{2026}")" }) {
                                Button("Show") { model.actions?.focusTab(tab.id) }.buttonStyle(.quiet)
                                if tab.branch != nil {
                                    Button("Merge\u{2026}") { model.actions?.worktreeAction(tab.id, "merge") }.buttonStyle(.quiet)
                                    Button("Discard\u{2026}") { model.actions?.worktreeAction(tab.id, "discard") }.buttonStyle(.quiet)
                                }
                            }
                        }
                    }
                }
            }
            if !background.isEmpty {
                PageSection(title: "Background", count: background.count, expanded: $backgroundOpen) {
                    PageGroup {
                        ForEach(background, id: \.id) { s in
                            PageRow(symbol: icon(s.command), tint: tint(s.command), title: Self.title(s),
                                    status: s.attention == true ? ("Needs you", .orange) : s.busy == true ? ("Working", .connected) : ("Idle", Color.secondary.opacity(0.6)),
                                    detail: [SidebarModel.tilde(s.cwd), DeviceBadge.presence(s)?.label].compactMap { $0 }.joined(separator: " \u{00B7} ")) {
                                Button("Open in a Tab") { model.actions?.attachHost(s) }.buttonStyle(.quiet)
                                Button("End") { model.actions?.killHost(s.id) }.buttonStyle(.quiet)
                            }
                        }
                    }
                }
            }
            if !liveJobs.isEmpty {
                PageSection(title: "Parallel jobs", count: liveJobs.count, expanded: $jobsOpen) {
                    PageGroup {
                        ForEach(liveJobs) { job in
                            PageRow(symbol: icon(job.target), tint: tint(job.target), title: job.brief,
                                    status: job.state == "running" ? ("Working", .connected) : job.state == "done" ? ("Ready to apply", .blue)
                                        : (job.state.capitalized, Color.secondary.opacity(0.6)),
                                    detail: "\(job.target.capitalized) \u{00B7} \(job.repo)",
                                    mono: DashboardChanges.jobWorktree(job.id).flatMap { changes.stats[$0] }) {
                                Button("Result") { model.actions?.jobAction(job, "wait") }.buttonStyle(.quiet)
                                Button("Diff") { model.actions?.jobAction(job, "diff") }.buttonStyle(.quiet)
                                Button("Apply") { model.actions?.jobAction(job, "apply") }.buttonStyle(.quiet).disabled(job.state == "running")
                                Button("Discard") { model.actions?.jobAction(job, "discard") }.buttonStyle(.quiet)
                            }
                        }
                    }
                }
            }
            if !model.runs.isEmpty {
                PageSection(title: "Pair runs today", count: model.runs.count, expanded: $runsOpen) {
                    PageGroup {
                        ForEach(model.runs) { run in
                            PageRow(symbol: icon(run.to), tint: tint(run.to), title: run.brief,
                                    status: run.state == "running" ? ("Working", .connected) : run.state == "failed" ? ("Failed", .red) : (run.state.capitalized, Color.secondary.opacity(0.6)),
                                    detail: "\(run.to.capitalized) \u{00B7} \(run.mode) \u{00B7} \((run.repo as NSString).lastPathComponent)") {
                                Button(run.state == "running" ? "Watch" : "Show") { model.actions?.showRun(run) }.buttonStyle(.quiet)
                            }
                        }
                    }
                }
            }
            if !changes.schedules.isEmpty {
                PageSection(title: "Scheduled", count: changes.schedules.count, expanded: $schedulesOpen) {
                    PageGroup {
                        ForEach(changes.schedules, id: \.id) { s in
                            PageRow(symbol: "clock", title: s.task,
                                    status: ("Next \(Date(timeIntervalSince1970: s.next).formatted(date: .abbreviated, time: .shortened))", Color.secondary.opacity(0.6)),
                                    detail: "\(s.model) \u{00B7} \(SidebarModel.tilde(s.cwd))",
                                    mono: "Every \(s.everyMinutes >= 1440 ? "\(s.everyMinutes / 1440) day(s)" : s.everyMinutes >= 60 ? "\(s.everyMinutes / 60) hour(s)" : "\(s.everyMinutes) min")\(s.at.map { " at \($0)" } ?? "")") {
                                Button("Remove") { changes.removeSchedule(s.id) }.buttonStyle(.quiet)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { DashboardChanges.shared.start() }
        .onDisappear { DashboardChanges.shared.stop() }
    }

    private var summary: String {
        let busyTabs: Int = model.tabs.filter { $0.busy && !$0.attention }.count
        let busyBackground: Int = background.filter { $0.busy == true && $0.attention != true }.count
        let busyJobs: Int = liveJobs.filter { $0.state == "running" }.count
        let busyRuns: Int = model.runs.filter { $0.state == "running" }.count
        let working = busyTabs + busyBackground + busyJobs + busyRuns
        let waitingTabs: Int = model.tabs.filter { $0.attention }.count
        let waiting = waitingTabs + background.filter { $0.attention == true }.count
        let parts = (working > 0 || waiting == 0 ? ["\(working) working"] : []) + (waiting > 0 ? ["\(waiting) waiting for you"] : [])
        return parts.joined(separator: ", ")
    }

    private func tint(_ command: String) -> Color {
        switch command {
        case "claude": return Color(nsColor: Agent.claude.tint)
        case "codex": return Color(nsColor: Agent.codex.tint)
        default: return .secondary
        }
    }

    private func icon(_ command: String) -> String {
        switch command {
        case "claude": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "ollama": return "cpu"
        default: return "terminal"
        }
    }

    static func title(_ s: SessionInfo) -> String {
        let agent = Agent.detect(s.command)
        if let t = s.title, let topic = Agent.topic(fromTitle: t, agentName: agent?.name ?? ""),
           topic.contains(where: \.isLetter) { return topic }
        return agent?.name ?? SessionNames.given(s) ?? s.command
    }

}

@MainActor
enum AgentsDashboardWindow {
    static func show() {
        (NSApp.delegate as? AppDelegate)?.showPage("agents") { c in
            AgentsDashboard(onClose: { [weak c] in c?.closePage() })
        }
    }
}
