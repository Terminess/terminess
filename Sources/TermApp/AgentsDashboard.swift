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
    @ObservedObject var model = SidebarModel.shared
    @ObservedObject var changes = DashboardChanges.shared

    private var agentTabs: [OpenTab] { model.tabs.filter { ["claude", "codex", "ollama", "harness"].contains($0.command) || $0.branch != nil } }
    private var inTabs: Set<String> { Set(model.tabs.flatMap(\.hostIDs)) }
    private var background: [SessionInfo] { model.background.filter { !inTabs.contains($0.id) } }
    private var liveJobs: [PairJob] { model.jobs.filter { !["applied", "discarded"].contains($0.state) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Agents").font(.title2.bold())
                    Spacer()
                    Text(summary).foregroundStyle(.secondary)
                }
                if agentTabs.isEmpty && background.isEmpty && liveJobs.isEmpty && model.runs.isEmpty {
                    Text("No agents running. Start Claude Code or Codex in a tab, a worktree tab or with pair, and they show here.")
                        .foregroundStyle(.secondary)
                }
                tabsSection
                backgroundSection
                jobsSection
                runsSection
                schedulesSection
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 440)
        .onAppear { DashboardChanges.shared.start() }
        .onDisappear { DashboardChanges.shared.stop() }
    }

    @ViewBuilder private var tabsSection: some View {
section("In tabs", agentTabs.isEmpty) {
            ForEach(agentTabs) { tab in
                card(icon: icon(tab.command), title: tab.title, detail: SidebarModel.tilde(tab.directory),
                     status: tab.attention ? ("Needs you", .orange) : tab.busy ? ("Working", .green) : ("Idle", .secondary),
                     changes: tab.branch.map { b in "\(b) \u{00B7} \(changes.stats[tab.directory] ?? "\u{2026}")" }) {
                    Button("Show") { model.actions?.focusTab(tab.id) }
                    if tab.branch != nil {
                        Button("Merge\u{2026}") { model.actions?.worktreeAction(tab.id, "merge") }
                        Button("Discard\u{2026}") { model.actions?.worktreeAction(tab.id, "discard") }
                    }
                }
            }
        }
        
    }

    @ViewBuilder private var backgroundSection: some View {
section("In the background", background.isEmpty) {
            ForEach(background, id: \.id) { s in
                card(icon: icon(s.command), title: Self.title(s), detail: SidebarModel.tilde(s.cwd),
                     status: s.attention == true ? ("Needs you", .orange) : s.busy == true ? ("Working", .green) : ("Idle", .secondary),
                     changes: nil) {
                    Button("Open in a Tab") { model.actions?.attachHost(s) }
                    Button("End") { model.actions?.killHost(s.id) }
                }
            }
        }
        
    }

    @ViewBuilder private var jobsSection: some View {
section("Parallel jobs", liveJobs.isEmpty) {
            ForEach(liveJobs) { job in
                card(icon: icon(job.target), title: job.brief, detail: "\(job.target.capitalized) \u{00B7} \(job.repo)",
                     status: job.state == "running" ? ("Working", .green) : job.state == "done" ? ("Ready to apply", .blue)
                        : (job.state.capitalized, .secondary),
                     changes: DashboardChanges.jobWorktree(job.id).flatMap { changes.stats[$0] }) {
                    Button("Result") { model.actions?.jobAction(job, "wait") }
                    Button("Diff") { model.actions?.jobAction(job, "diff") }
                    Button("Apply") { model.actions?.jobAction(job, "apply") }.disabled(job.state == "running")
                    Button("Discard") { model.actions?.jobAction(job, "discard") }
                }
            }
        }
        
    }

    @ViewBuilder private var runsSection: some View {
section("Pair runs today", model.runs.isEmpty) {
            ForEach(model.runs) { run in
                card(icon: icon(run.to), title: run.brief, detail: "\(run.to.capitalized) \u{00B7} \(run.mode) \u{00B7} \((run.repo as NSString).lastPathComponent)",
                     status: run.state == "running" ? ("Working", .green) : run.state == "failed" ? ("Failed", .red) : (run.state.capitalized, .secondary),
                     changes: nil) {
                    Button(run.state == "running" ? "Watch" : "Show") { model.actions?.showRun(run) }
                }
            }
        }
    }

    @ViewBuilder private var schedulesSection: some View {
        section("Scheduled", changes.schedules.isEmpty) {
            ForEach(changes.schedules, id: \.id) { s in
                card(icon: "clock", title: s.task, detail: "\(s.model) \u{00B7} \(SidebarModel.tilde(s.cwd))",
                     status: ("Next \(Date(timeIntervalSince1970: s.next).formatted(date: .abbreviated, time: .shortened))", .secondary),
                     changes: "Every \(s.everyMinutes >= 1440 ? "\(s.everyMinutes / 1440) day(s)" : s.everyMinutes >= 60 ? "\(s.everyMinutes / 60) hour(s)" : "\(s.everyMinutes) min")\(s.at.map { " at \($0)" } ?? "")") {
                    Button("Remove") { changes.removeSchedule(s.id) }
                }
            }
        }
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
        return agent?.name ?? s.name
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, _ empty: Bool, @ViewBuilder content: () -> Content) -> some View {
        if !empty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(.secondary)
                content()
            }
        }
    }

    private func card<Actions: View>(icon: String, title: String, detail: String, status: (String, Color), changes: String?,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let changes {
                    Text(changes).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(status.1).frame(width: 7, height: 7)
                    Text(status.0).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) { actions() }.controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.25)))
    }
}

@MainActor
enum AgentsDashboardWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: AgentsDashboard()))
        w.title = "Agents"
        w.setContentSize(NSSize(width: 720, height: 560))
        w.isReleasedWhenClosed = false
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
