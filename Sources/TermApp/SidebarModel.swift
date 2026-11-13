import AppKit
import Combine

struct OpenTab: Identifiable, Equatable {
    let id: ObjectIdentifier
    let title: String
    let command: String
    let directory: String
    let isKey: Bool
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
    let status: String
    let brief: String
    let resultFile: String
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
    func resume(_ session: SessionItem)
    func startPair(mode: String, target: String)
    func jobAction(_ job: PairJob, _ action: String)
    func showRun(_ run: PairRun)
}

@MainActor
final class SidebarModel: ObservableObject {
    static let shared = SidebarModel()

    @Published var tabs: [OpenTab] = []
    @Published var jobs: [PairJob] = []
    @Published var runs: [PairRun] = []
    @Published var sessions: [SessionItem] = []
    @Published var sessionsNote: String?
    @Published var search = ""
    @Published var visible: Bool = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(visible, forKey: "sidebarVisible") }
    }

    weak var actions: SidebarActions?
    var tabProvider: (() -> [OpenTab])?
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var loadingSessions = false

    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let pairState = home + "/.local/state/pair"
    static var sessionsTool: String? {
        let p = home + "/.local/bin/sessions"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
    static var pairTool: String? {
        let p = home + "/.local/bin/pair"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
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
            }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { SidebarModel.shared.refreshSessions() }
        }
    }

    func refreshTabs() {
        let new = tabProvider?() ?? []
        if new != tabs { tabs = new }
    }

    func refreshPair() {
        let (jobs, runs) = SidebarModel.readPair()
        if jobs != self.jobs { self.jobs = jobs }
        if runs != self.runs { self.runs = runs }
    }

    func refreshSessions() {
        guard !loadingSessions else { return }
        guard let tool = SidebarModel.sessionsTool else {
            sessionsNote = "Install ~/.local/bin/sessions to list past sessions."
            return
        }
        loadingSessions = true
        Task.detached(priority: .utility) {
            let data = SidebarModel.run(tool, ["json"])
            let items = (try? JSONDecoder().decode([SessionItem].self, from: data)) ?? []
            await MainActor.run {
                let model = SidebarModel.shared
                model.loadingSessions = false
                if items != model.sessions { model.sessions = items }
                model.sessionsNote = items.isEmpty ? "No sessions found." : nil
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

        var runs: [PairRun] = []
        if let ledger = try? String(contentsOfFile: pairState + "/log.jsonl", encoding: .utf8) {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            for line in ledger.split(separator: "\n").suffix(40).reversed() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let mode = obj["mode"] as? String, mode != "parallel",
                      let ts = obj["ts"] as? String else { continue }
                if let date = SidebarModel.ledgerDate(ts), date < cutoff { continue }
                runs.append(PairRun(id: ts + (obj["to"] as? String ?? ""), from: obj["from"] as? String ?? "?",
                                    to: obj["to"] as? String ?? "?", mode: mode,
                                    repo: (obj["repo"] as? String ?? "").split(separator: "/").last.map(String.init) ?? "",
                                    status: obj["status"] as? String ?? "", brief: obj["brief_head"] as? String ?? "",
                                    resultFile: obj["result_file"] as? String ?? ""))
                if runs.count >= 6 { break }
            }
        }
        return (jobs, runs)
    }

    static func ledgerDate(_ ts: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: ts)
    }
}
