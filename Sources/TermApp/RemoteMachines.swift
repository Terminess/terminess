import AppKit
import TermHost

struct RemoteMachine: Codable, Identifiable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var host: String
    var port: Int = 22
    var path: String = "~/.local/bin/terminessd"
    var repoRoot: String?
    var role: String?

    var isValid: Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        return !h.isEmpty && !h.hasPrefix("-") && !h.contains(where: \.isWhitespace)
            && (1...65535).contains(port) && RemotePath.isSafe(path)
    }

    static func fromLink(_ text: String) -> RemoteMachine? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "terminess", c.host == "add" else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value }
        guard let address = q["address"], !address.isEmpty else { return nil }
        let name = q["name"].flatMap { $0.isEmpty ? nil : $0 } ?? address
        let user = q["user"].flatMap { $0.isEmpty ? nil : $0 }
        var m = RemoteMachine(name: name, host: user.map { "\($0)@\(address)" } ?? address)
        if let p = q["port"].flatMap(Int.init) { m.port = p }
        if let path = q["path"], RemotePath.isSafe(path) { m.path = path }
        if SSHConfig.aliases().contains(name) { m.host = name; m.port = 22 }
        return m.isValid ? m : nil
    }
}

@MainActor
enum RemoteMachines {
    private static let key = "remoteMachines"
    static let changed = Notification.Name("remoteMachinesChanged")

    static var all: [RemoteMachine] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([RemoteMachine].self, from: data) else { return [] }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func machine(_ id: String) -> RemoteMachine? { all.first { $0.id == id } }
}

enum SSHConfig {
    static func aliases() -> [String] {
        let path = NSHomeDirectory() + "/.ssh/config"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for p in parts.dropFirst() where !p.contains("*") && !p.contains("?") && !p.hasPrefix("!") { out.append(String(p)) }
        }
        return out
    }
}

final class SSHLink: @unchecked Sendable {
    let fd: Int32
    private let process: Process
    private let errors = Pipe()
    private var errorText = ""
    private let lock = NSLock()

    var lastError: String {
        lock.lock(); defer { lock.unlock() }
        return errorText.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private init(fd: Int32, process: Process) {
        self.fd = fd
        self.process = process
    }

    static func open(_ m: RemoteMachine) -> SSHLink? {
        guard m.isValid else { return nil }
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        let ours = pair[0], theirs = pair[1]
        _ = fcntl(ours, F_SETFD, FD_CLOEXEC)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
        if m.port != 22 { args += ["-p", String(m.port)] }
        args += ["--", m.host, RemotePath.shellQuoted(m.path) + " stdio"]
        p.arguments = args
        let handle = FileHandle(fileDescriptor: theirs, closeOnDealloc: false)
        p.standardInput = handle
        p.standardOutput = handle
        let link = SSHLink(fd: ours, process: p)
        p.standardError = link.errors
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDE") || k == "TERMINESS_SESSION" { env[k] = nil }
        p.environment = env
        link.errors.fileHandleForReading.readabilityHandler = { [weak link] h in
            let data = h.availableData
            guard let link, !data.isEmpty else { h.readabilityHandler = nil; return }
            link.lock.lock()
            link.errorText = String((link.errorText + String(decoding: data, as: UTF8.self)).suffix(2000))
            link.lock.unlock()
        }
        do { try p.run() } catch {
            close(ours); close(theirs)
            return nil
        }
        close(theirs)
        return link
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    deinit { terminate() }
}

@MainActor
final class RemoteMonitor {
    let machine: RemoteMachine
    private var link: SSHLink?
    private var connection: Connection?
    private var timer: Timer?
    private var retry: DispatchWorkItem?
    private var backoff: TimeInterval = 2
    private var stopped = false
    private(set) var connected = false
    var onUpdate: ((_ sessions: [SessionInfo]?, _ note: String?) -> Void)?
    var onProjects: (([ProjectInfo], [String]) -> Void)?
    var onPlatform: ((String?) -> Void)?
    var onHistory: (([HistoryItem]) -> Void)?
    var onReminders: (([ReminderInfo]) -> Void)?
    var onReminderActed: ((String) -> Void)?
    private var ticks = 0

    init(machine: RemoteMachine) { self.machine = machine }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        retry?.cancel()
        timer?.invalidate()
        timer = nil
        connection?.close()
        link?.terminate()
        connection = nil
        link = nil
    }

    func refresh() {
        if connected { connection?.send(Message(op: "list")) } else if connection == nil && !stopped { retry?.cancel(); connect() }
    }

    func send(_ m: Message) { connection?.send(m) }

    private func connect() {
        guard !stopped, connection == nil else { return }
        onUpdate?(nil, "Connecting…")
        guard let link = SSHLink.open(machine) else {
            onUpdate?(nil, "Can't run ssh for \(machine.host)")
            scheduleRetry()
            return
        }
        self.link = link
        let c = Connection(readFD: link.fd, queue: .main)
        connection = c
        c.onFrame = { [weak self] frame in MainActor.assumeIsolated { self?.handle(frame) } }
        c.onClose = { [weak self, weak link] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let why = link?.lastError ?? ""
                self.connection = nil
                self.link?.terminate()
                self.link = nil
                self.connected = false
                self.timer?.invalidate()
                self.timer = nil
                guard !self.stopped else { return }
                self.onUpdate?(nil, why.isEmpty ? "Can't reach \(self.machine.name)" : why)
                self.scheduleRetry()
            }
        }
        c.start()
        c.send(Message(op: "hello", version: Wire.version))
    }

    private func handle(_ frame: Wire.Frame) {
        guard let m = frame.message else { return }
        switch m.op {
        case "hello":
            connected = true
            backoff = 2
            onPlatform?(m.platform)
            connection?.send(Message(op: "list"))
            connection?.send(Message(op: "projects"))
            connection?.send(Message(op: "history"))
            connection?.send(Message(op: "reminders"))
            connection?.send(Message(op: "watch-borrow"))
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.connected else { return }
                    self.ticks += 1
                    if self.ticks % 10 == 0 {
                        self.connection?.send(Message(op: "history"))
                        self.connection?.send(Message(op: "projects"))
                    }
                    if SidebarModel.shared.visible || Int(Date().timeIntervalSince1970) % 15 < 3 {
                        self.connection?.send(Message(op: "list"))
                    }
                    self.connection?.send(Message(op: "reminders"))
                }
            }
        case "sessions":
            onUpdate?(m.sessions ?? [], nil)
        case "projects":
            onProjects?(m.projects ?? [], m.folders ?? [])
        case "history":
            onHistory?(m.history ?? [])
        case "reminders":
            onReminders?(m.reminders ?? [])
        case "borrow-request":
            guard let id = m.id, let task = m.message else { break }
            let machine = self.machine
            let r = BorrowCenter.Request(id: id, machine: machine, from: m.name ?? machine.name, task: task)
            BorrowCenter.shared.request(r) { code, text in
                HandoffCoordinator.onMain {
                    SidebarModel.shared.monitor(machine.id)?.send(Message(op: "borrow-reply", id: id, code: code, message: text))
                }
            }
        case "reminder-acted":
            if let session = m.id { onReminderActed?(session) }
            connection?.send(Message(op: "list"))
            connection?.send(Message(op: "reminders"))
        default:
            break
        }
    }

    private func scheduleRetry() {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
        backoff = min(backoff * 2, 60)
    }
}

struct RemoteMachineState: Identifiable, Equatable {
    var machine: RemoteMachine
    var sessions: [SessionInfo] = []
    var projects: [ProjectInfo] = []
    var folders: [String] = []
    var history: [HistoryItem] = []
    var reminders: [ReminderInfo] = []
    var note: String?
    var platform: String?
    var id: String { machine.id }
    var symbol: String {
        switch platform {
        case "macos": return "laptopcomputer"
        case "linux", "windows": return "server.rack"
        default: return "desktopcomputer"
        }
    }
    var displayName: String { machine.name.isEmpty ? machine.host : machine.name }
    var role: String? { MachineRole.clean(machine.role) }
}

extension RemoteMachineState {
    var folderTree: [(path: String, children: [String])] {
        let set = Set(folders)
        var children: [String: [String]] = [:]
        var tops: [String] = []
        for f in folders {
            let parent = (f as NSString).deletingLastPathComponent
            if set.contains(parent) { children[parent, default: []].append(f) } else { tops.append(f) }
        }
        return tops.map { ($0, children[$0] ?? []) }
    }
}

func remoteTilde(_ p: String) -> String {
    let parts = p.split(separator: "/", omittingEmptySubsequences: true)
    if parts.count >= 2, parts[0] == "home" || parts[0] == "Users" {
        return "~" + (parts.count > 2 ? "/" + parts.dropFirst(2).joined(separator: "/") : "")
    }
    if p == "/root" || p.hasPrefix("/root/") { return "~" + p.dropFirst(5) }
    return p
}

enum SessionNames {
    static func given(_ s: SessionInfo) -> String? {
        let n = s.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n.allSatisfy(\.isNumber) ? nil : n
    }

    static func title(_ s: SessionInfo) -> String {
        if let n = given(s) { return n }
        let agent = Agent.detect(s.command)
        if let agent, let t = s.title, let topic = Agent.topic(fromTitle: t, agentName: agent.name),
           topic.contains(where: \.isLetter) { return topic }
        if let agent { return agent.name }
        if let n = given(s) { return n }
        return s.command
    }
}
