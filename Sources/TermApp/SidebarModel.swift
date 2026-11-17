import TermHost
import TermTranscript
import AppKit
import Combine

struct OpenTab: Identifiable, Equatable {
    let id: ObjectIdentifier
    let title: String
    let command: String
    let directory: String
    let isKey: Bool
    var attention = false
    var panes = 1
    var parked = false
    var branch: String?
    var busy = false
    var hostIDs: [String] = []
    var remoteIDs: [String] = []
    var path = ""
    var machineID: String?
}

struct PairJob: Identifiable, Equatable {
    let id: String
    let target: String
    let from: String
    let repo: String
    let repoPath: String
    let brief: String
    let state: String
}

struct PairRun: Identifiable, Equatable {
    let id: String
    let from: String
    let to: String
    let mode: String
    let repo: String
    let brief: String
    let dir: String
    let state: String
    let started: Date
    let transcript: String?
}

struct IssueItem: Identifiable, Equatable, Decodable {
    struct Label: Equatable, Decodable { let name: String }
    let number: Int
    let title: String
    let labels: [Label]
    var id: Int { number }
}

struct SessionItem: Identifiable, Equatable, Decodable {
    struct PairInfo: Equatable, Decodable {
        let from: String
        let mode: String
        let brief: String
    }
    let tool: String
    let id: String
    let cwd: String
    let repo: String
    let title: String
    let mtime: Double
    let linked: [String]
    let pair: PairInfo?
}

@MainActor
protocol SidebarActions: AnyObject {
    func focusTab(_ id: ObjectIdentifier)
    func renameTab(_ id: ObjectIdentifier)
    func setTheme(_ name: String?, forTab id: ObjectIdentifier)
    func closeTab(_ id: ObjectIdentifier)
    func worktreeAction(_ id: ObjectIdentifier, _ action: String)
    func startIssue(_ issue: IssueItem, agent: String)
    func resume(_ session: SessionItem)
    func fork(_ session: SessionItem, inWorktree: Bool)
    func forkTab(_ id: ObjectIdentifier, inWorktree: Bool)
    func startPair(mode: String, target: String)
    func jobAction(_ job: PairJob, _ action: String)
    func showRun(_ run: PairRun)
    func attachHost(_ session: SessionInfo)
    func killHost(_ id: String)
    func attachRemote(_ machine: RemoteMachine, _ session: SessionInfo)
    func killRemote(_ machine: RemoteMachine, _ id: String)
    func newRemote(_ machine: RemoteMachine, agent: String?, directory: String?)
    func resumeRemote(_ machine: RemoteMachine, _ item: HistoryItem)
    func moveToMac(_ machine: RemoteMachine, sessionID: String)
    func moveTab(_ id: ObjectIdentifier, to machine: RemoteMachine)
}

@MainActor
final class SidebarModel: ObservableObject {
    static let shared = SidebarModel()

    @Published var tabs: [OpenTab] = []
    @Published var jobs: [PairJob] = []
    @Published var runs: [PairRun] = []
    @Published var sessions: [SessionItem] = []
    @Published var sessionsNote: String?
    @Published var background: [SessionInfo] = []
    @Published var localClientKinds: [String: [String]] = [:]

    func iPhoneOnTab(_ tab: OpenTab) -> Bool {
        if tab.hostIDs.contains(where: { localClientKinds[$0]?.contains("iphone") == true }) { return true }
        return remote.contains { r in r.sessions.contains { tab.remoteIDs.contains("\(r.id)/\($0.id)") && $0.clientKinds?.contains("iphone") == true } }
    }
    @Published var localReminders: [ReminderInfo] = []

    var allReminders: [(machine: RemoteMachine?, reminder: ReminderInfo)] {
        (localReminders.map { (nil as RemoteMachine?, $0) } + remote.flatMap { r in r.reminders.map { (r.machine as RemoteMachine?, $0) } })
            .sorted { $0.reminder.due < $1.reminder.due }
    }
    private var loadingBackground = false
    @Published var remote: [RemoteMachineState] = []
    private var monitors: [String: RemoteMonitor] = [:]
    private var machinesObserver: NSObjectProtocol?
    @Published var search = ""
    @Published var issues: [IssueItem] = []
    @Published var issuesRepo: String?
    @Published var issuesNote: String?
    private var issuesLoadedAt = Date.distantPast
    private var issuesFor: String?
    var currentDirectory: (() -> String?)?
    @Published var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? []) {
        didSet { UserDefaults.standard.set(Array(pinned), forKey: "pinnedSessions") }
    }

    func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
    }
    @Published var visible: Bool = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(visible, forKey: "sidebarVisible") }
    }

    weak var actions: SidebarActions?
    var tabProvider: (() -> [OpenTab])?
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var loadingSessions = false

    nonisolated static let home = Transcript.home

    nonisolated static func tilde(_ p: String) -> String {
        for h in Set([home, NSHomeDirectory()]) where p == h || p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        return p
    }
    nonisolated static let pairState = home + "/.local/state/pair"
    static var pairTool: String? {
        let candidates: [String?] = [Bundle.main.resourceURL?.appendingPathComponent("bin/pair").path, home + "/.local/bin/pair"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var filteredSessions: [SessionItem] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return sessions }
        return sessions.filter { s in
            let hay = "\(s.title) \(s.repo) \(s.tool) \(s.pair?.brief ?? "")".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    func start() {
        guard fastTimer == nil else { return }
        reloadMachines()
        machinesObserver = NotificationCenter.default.addObserver(forName: RemoteMachines.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SidebarModel.shared.reloadMachines() }
        }
        refreshTabs()
        refreshPair()
        refreshSessions()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                SidebarModel.shared.refreshTabs()
                SidebarModel.shared.refreshPair()
                SidebarModel.shared.refreshBackground()
            }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated {
                SidebarModel.shared.repoCache = [:]
                SidebarModel.shared.refreshSessions()
                SidebarModel.shared.refreshIssues()
            }
        }
    }

    func refreshIssues(force: Bool = false) {
        guard let dir = currentDirectory?(), let gh = Git.gh else { issues = []; issuesRepo = nil; return }
        let wanted = visible && (UserDefaults.standard.object(forKey: "sidebar.issuesExpanded") as? Bool ?? false)
        Task.detached(priority: .utility) {
            let repo = Git.githubRepo(dir)
            await MainActor.run {
                let m = SidebarModel.shared
                guard let repo else { m.issues = []; m.issuesRepo = nil; return }
                m.issuesRepo = repo
                guard wanted else { return }
                let stale = Date().timeIntervalSince(m.issuesLoadedAt) > 120
                guard force || repo != m.issuesFor || stale else { return }
                m.issuesFor = repo
                m.issuesLoadedAt = Date()
                Task.detached(priority: .utility) {
                    let r = Git.exec(gh, ["issue", "list", "-R", repo, "--json", "number,title,labels", "--limit", "25"])
                    let items = (try? JSONDecoder().decode([IssueItem].self, from: Data(r.output.utf8))) ?? []
                    await MainActor.run {
                        let m = SidebarModel.shared
                        m.issuesRepo = repo
                        m.issues = items
                        m.issuesNote = r.status != 0 ? (r.output.contains("auth") || r.output.contains("login")
                            ? "Run gh auth login to see issues." : "Could not load issues.") : (items.isEmpty ? "No open issues." : nil)
                    }
                }
            }
        }
    }

    func refreshTabs() {
        let new = tabProvider?() ?? []
        if new != tabs { tabs = new }
    }

    func refreshBackground() {
        guard !loadingBackground, Settings.shared.keepSessions else {
            if !Settings.shared.keepSessions, !background.isEmpty { background = [] }
            return
        }
        loadingBackground = true
        Task.detached(priority: .utility) {
            let all = HostAttachment.list(timeout: 1) ?? []
            let reminders = HostAttachment.request(Message(op: "reminders"), expecting: ["reminders"], timeout: 1)?.reminders
            await MainActor.run {
                let model = SidebarModel.shared
                model.loadingBackground = false
                let shown = Set(model.tabs.flatMap(\.hostIDs))
                let free = all.filter { !shown.contains($0.id) }
                if free != model.background { model.background = free }
                let kinds = Dictionary(all.map { ($0.id, $0.clientKinds ?? []) }, uniquingKeysWith: { a, _ in a })
                if kinds != model.localClientKinds { model.localClientKinds = kinds }
                if let reminders {
                    if reminders != model.localReminders { model.localReminders = reminders }
                    ReminderCenter.shared.saw(reminders, machine: nil)
                }
            }
        }
    }

    func reloadMachines() {
        let machines = RemoteMachines.all
        for (id, mon) in monitors where machines.first(where: { $0.id == id }) != mon.machine {
            mon.stop()
            monitors[id] = nil
        }
        for m in machines where monitors[m.id] == nil {
            let mon = RemoteMonitor(machine: m)
            mon.onUpdate = { sessions, note in SidebarModel.shared.remoteUpdate(m.id, sessions: sessions, note: note) }
            mon.onPlatform = { platform in
                let model = SidebarModel.shared
                if let i = model.remote.firstIndex(where: { $0.id == m.id }), model.remote[i].platform != platform { model.remote[i].platform = platform }
            }
            mon.onProjects = { projects in
                let model = SidebarModel.shared
                if let i = model.remote.firstIndex(where: { $0.id == m.id }), model.remote[i].projects != projects { model.remote[i].projects = projects }
            }
            mon.onHistory = { history in
                let model = SidebarModel.shared
                if let i = model.remote.firstIndex(where: { $0.id == m.id }), model.remote[i].history != history { model.remote[i].history = history }
            }
            mon.onReminders = { reminders in
                let model = SidebarModel.shared
                if let i = model.remote.firstIndex(where: { $0.id == m.id }), model.remote[i].reminders != reminders { model.remote[i].reminders = reminders }
                ReminderCenter.shared.saw(reminders, machine: m)
            }
            mon.onReminderActed = { session in ReminderCenter.shared.acted(session: session, machine: m) }
            monitors[m.id] = mon
            mon.start()
        }
        remote = machines.map { m in
            if var r = remote.first(where: { $0.id == m.id }) { r.machine = m; return r }
            return RemoteMachineState(machine: m, note: "Connecting…")
        }
    }

    private func remoteUpdate(_ id: String, sessions: [SessionInfo]?, note: String?) {
        guard let i = remote.firstIndex(where: { $0.id == id }) else { return }
        var r = remote[i]
        if let sessions { r.sessions = sessions }
        if sessions == nil, let note, note != "Connecting…" { r.sessions = [] }
        r.note = note
        if r != remote[i] { remote[i] = r }
    }

    func remoteFree(_ r: RemoteMachineState) -> [SessionInfo] {
        let shown = Set(tabs.flatMap(\.remoteIDs))
        return r.sessions.filter { !shown.contains("\(r.id)/\($0.id)") }
    }

    func monitor(_ id: String) -> RemoteMonitor? { monitors[id] }


    private var repoCache: [String: Bool] = [:]

    func isRepo(_ path: String) -> Bool {
        if let known = repoCache[path] { return known }
        let found = FileManager.default.fileExists(atPath: path + "/.git")
        repoCache[path] = found
        return found
    }

    func repoRoot(_ path: String) -> String? {
        ProjectGrouping.repoRoot(of: path, home: Self.home, isRepo: isRepo)
    }

    @Published var commitsSince: [String: Int] = [:]
    private var headSeen: [String: String] = [:]
    private var countingCommits = false

    nonisolated static func commitKey(_ s: SessionItem) -> String { "\(s.cwd)|\(Int(s.mtime))" }

    func refreshCommitCounts() {
        guard !countingCommits else { return }
        countingCommits = true
        let items = Array(sessions.filter { $0.pair == nil }.prefix(200))
        let known = commitsSince, heads = headSeen
        Task.detached(priority: .background) {
            var counts = known, seen = heads
            for (cwd, group) in Dictionary(grouping: items, by: \.cwd) {
                guard FileManager.default.fileExists(atPath: cwd) else { continue }
                let head = Git.run(cwd, ["rev-parse", "HEAD"])
                guard head.status == 0 else { continue }
                if seen[cwd] != head.output {
                    seen[cwd] = head.output
                    for k in counts.keys where k.hasPrefix(cwd + "|") { counts[k] = nil }
                }
                for s in group where counts[SidebarModel.commitKey(s)] == nil {
                    let r = Git.run(cwd, ProjectGrouping.commitsSinceArguments(s.mtime))
                    if r.status == 0, let n = ProjectGrouping.commitCount(r.output) { counts[SidebarModel.commitKey(s)] = n }
                }
            }
            await MainActor.run {
                let model = SidebarModel.shared
                model.countingCommits = false
                model.headSeen = seen
                if counts != model.commitsSince { model.commitsSince = counts }
            }
        }
    }

    func refreshPair() {
        let (jobs, runs) = SidebarModel.readPair()
        if jobs != self.jobs { self.jobs = jobs }
        if runs != self.runs { self.runs = runs }
    }

    func refreshSessions() {
        guard !loadingSessions else { return }
        loadingSessions = true
        Task.detached(priority: .utility) {
            _ = await MainActor.run { HostService.ensureRunning() }
            let reply = HostRequest.send(Message(op: "history"))
            let items = (reply?.history ?? []).map { h in
                SessionItem(tool: h.agent, id: h.id, cwd: h.cwd, repo: (h.cwd as NSString).lastPathComponent,
                            title: h.title, mtime: h.used, linked: [], pair: nil)
            }
            await MainActor.run {
                let model = SidebarModel.shared
                model.loadingSessions = false
                if items != model.sessions { model.sessions = items }
                model.refreshCommitCounts()
                model.sessionsNote = reply == nil ? "Couldn't reach the Terminess service." : (items.isEmpty ? "No sessions yet." : nil)
            }
        }
    }

    nonisolated static func run(_ tool: String, _ args: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }


    static func readPair() -> ([PairJob], [PairRun]) {
        let fm = FileManager.default
        var jobs: [PairJob] = []
        let parallel = pairState + "/parallel"
        for id in ((try? fm.contentsOfDirectory(atPath: parallel)) ?? []).sorted().reversed() {
            let dir = parallel + "/" + id
            guard let metaText = try? String(contentsOfFile: dir + "/meta", encoding: .utf8) else { continue }
            var meta: [String: String] = [:]
            for line in metaText.split(separator: "\n") {
                if let eq = line.firstIndex(of: "=") { meta[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
            }
            let state: String
            if let s = try? String(contentsOfFile: dir + "/state", encoding: .utf8) {
                state = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let e = try? String(contentsOfFile: dir + "/exit", encoding: .utf8) {
                state = e.trimmingCharacters(in: .whitespacesAndNewlines) == "0" ? "done" : "failed"
            } else if let p = try? String(contentsOfFile: dir + "/pid", encoding: .utf8),
                      let pid = Int32(p.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
                state = "running"
            } else {
                state = "died"
            }
            if (state == "applied" || state == "discarded") && jobs.filter({ $0.state == "applied" || $0.state == "discarded" }).count >= 3 {
                continue
            }
            jobs.append(PairJob(id: id, target: meta["target"] ?? "?", from: meta["from"] ?? "?",
                                repo: (meta["repo"] ?? "").split(separator: "/").last.map(String.init) ?? "",
                                repoPath: meta["repo"] ?? "", brief: meta["brief_head"] ?? "", state: state))
            if jobs.count >= 12 { break }
        }

        let runs = PairRuns.recent().filter { $0.mode != "parallel" }
        return (jobs, runs)
    }

    nonisolated static func ledgerDate(_ ts: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: ts)
    }
}
