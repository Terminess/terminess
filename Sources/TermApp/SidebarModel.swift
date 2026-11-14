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
    private var loadingBackground = false
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
                SidebarModel.shared.refreshSessions()
                SidebarModel.shared.refreshIssues()
            }
        }
    }

    func refreshIssues(force: Bool = false) {
        guard let dir = currentDirectory?(), let gh = Git.gh else { issues = []; issuesRepo = nil; return }
        Task.detached(priority: .utility) {
            let repo = Git.githubRepo(dir)
            await MainActor.run {
                let m = SidebarModel.shared
                guard let repo else { m.issues = []; m.issuesRepo = nil; return }
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
            await MainActor.run {
                let model = SidebarModel.shared
                model.loadingBackground = false
                let shown = Set(model.tabs.flatMap(\.hostIDs))
                let free = all.filter { !shown.contains($0.id) }
                if free != model.background { model.background = free }
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
