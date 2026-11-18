#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Dispatch
import Foundation
import TermHandoff
import TermHost
import TermPTY
import TermTranscript

final class HostSession {
    let id: String
    var name: String
    var nameLocked = false
    let created: Double
    let process: PTYProcess
    let initialCommand: String
    var clients: [ObjectIdentifier: Connection] = [:]
    private(set) var replay: [UInt8] = []
    static let replayLimit = 2 * 1024 * 1024
    var cols: Int
    var rows: Int
    var lastForeground: ForegroundInfo?
    var scanner = OutputScanner()
    var title = ""
    var origin: String?
    var originName: String?
    var notice: String?
    var onTurnEnd: (() -> Void)?
    var busy = false {
        didSet { if oldValue && !busy { onTurnEnd?() } }
    }
    var attention = false
    var asking = false
    var permission: PermissionInfo?
    var permissionWaiter: Connection?
    var queuedPermissions: [(info: PermissionInfo, waiter: Connection)] = []
    var question: QuestionInfo?
    var questionWaiter: Connection?
    var active = Date().timeIntervalSince1970
    var lastPush = 0.0
    var transcript: (agent: String, path: String, pid: Int32)?
    var hookPid: Int32?
    var hookAgent = "claude"
    var hooked: Bool { hookPid != nil && hookPid == process.foregroundPID }

    init(id: String, name: String, process: PTYProcess, command: String, cols: Int, rows: Int) {
        self.id = id
        self.name = name
        self.process = process
        self.initialCommand = command
        self.cols = cols
        self.rows = rows
        created = Date().timeIntervalSince1970
    }

    func record(_ bytes: [UInt8]) {
        replay.append(contentsOf: bytes)
        if replay.count > HostSession.replayLimit + 256 * 1024 {
            replay.removeFirst(replay.count - HostSession.replayLimit)
        }
    }

    var command: String {
        let c = process.foregroundCommand ?? initialCommand
        if c == "terminessd" && LocalChat.isAgent(command: c, args: process.foregroundArguments) { return "harness" }
        return c == "terminessd" && LocalChat.isChat(command: c, args: process.foregroundArguments) ? "ollama" : c
    }

    var foreground: ForegroundInfo {
        let fgPid = process.foregroundPID
        return ForegroundInfo(command: command,
                              cwd: process.foregroundDirectory ?? "",
                              args: fgPid == process.pid ? [] : process.foregroundArguments,
                              started: process.foregroundStartTime ?? 0, pid: fgPid, shellPid: process.pid)
    }

    var info: SessionInfo {
        var i = SessionInfo(id: id, name: name, command: command,
                            cwd: process.foregroundDirectory ?? "", created: created, clients: clients.count)
        i.title = title.isEmpty ? nil : title
        i.busy = busy
        i.attention = attention
        i.asking = asking
        i.permission = permission
        i.question = question
        i.active = active
        i.origin = origin
        i.originName = origin == nil ? nil : originName
        i.nameLocked = nameLocked ? true : nil
        return i
    }

    var readableTitle: String {
        let command = process.foregroundCommand ?? initialCommand
        let topic = TitleState.clean(title)
        let agent = command == "claude" ? "Claude Code" : (command == "codex" ? "Codex" : nil)
        if let agent { return topic.isEmpty || topic.lowercased() == agent.lowercased() ? agent : topic }
        return topic.isEmpty ? command : topic
    }
}

public final class HostServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "terminessd")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var infoTimer: DispatchSourceTimer?
    private lazy var push = PushRegistry(queue: queue)
    private var transcriptSubs: [ObjectIdentifier: (session: String, sent: [TranscriptItem], mtime: Date?)] = [:]
    private var clientSizes: [ObjectIdentifier: (cols: Int, rows: Int, at: Double)] = [:]
    private var owners: [String: ObjectIdentifier] = [:]
    private var uploads: [ObjectIdentifier: (path: String, handle: FileHandle)] = [:]
    private var sessions: [String: HostSession] = [:]
    private var order: [String] = []
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var bindings: [ObjectIdentifier: String] = [:]
    private var clientKinds: [ObjectIdentifier: String] = [:]
    private var deviceNames: [ObjectIdentifier: String] = [:]

    static var platform: String {
        #if os(macOS)
        return "macos"
        #elseif os(Windows)
        return "windows"
        #else
        return "linux"
        #endif
    }

    static func cleanDeviceName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let kept = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let name = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(80))
    }

    func sessionInfo(_ s: HostSession) -> SessionInfo {
        var i = s.info
        let kinds = s.clients.keys.map { k -> String in
            switch clientKinds[k] {
            case "mac", "iphone": return clientKinds[k]!
            default: return "other"
            }
        }
        i.clientKinds = kinds.isEmpty ? nil : Array(Set(kinds)).sorted()
        let devices = s.clients.keys.map { k -> ClientDevice in
            let kind = clientKinds[k]
            return ClientDevice(kind: kind == "mac" || kind == "iphone" ? kind! : "other", name: deviceNames[k])
        }
        i.clientDevices = devices.isEmpty ? nil
            : Array(Set(devices)).sorted { ($0.kind, $0.name ?? "") < ($1.kind, $1.name ?? "") }
        return i
    }
    private var toolWaiters: [String: Connection] = [:]
    private var handoffOut: [String: Data] = [:]
    private var handoffIn: [String: Data] = [:]
    private var borrowWatchers: [ObjectIdentifier] = []
    static let borrowTimeout: TimeInterval = 15 * 60
    private var nextNumber = 1
    public let socketPath: String
    public var log: (String) -> Void = { _ in }
    public var historyProvider: () -> [HistoryItem] = { History.recent() }
    public var commits = CommitCounter()
    public lazy var reminders = ReminderStore()
    public var claudeHome = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    public var promptReturnDelay: TimeInterval = 0.3

    public init(socketPath: String = HostPaths.socket) {
        self.socketPath = socketPath
    }

    public func start() throws {
        listenFD = try UnixSocket.listen(socketPath)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptClient() }
        acceptSource = src
        src.resume()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            self?.pushForeground()
            self?.pushTranscripts()
            self?.runDueSchedules()
            self?.fireDueReminders()
        }
        infoTimer = t
        t.resume()
        log("listening on \(socketPath)")
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let conn = Connection(readFD: fd, queue: queue, buffered: true)
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.onFrame = { [weak self, weak conn] frame in
            guard let self, let conn else { return }
            self.handle(frame, from: conn)
        }
        conn.onClose = { [weak self] in self?.dropConnection(key) }
        conn.start()
    }

    private func clearQuestion(_ s: HostSession) {
        s.question = nil
        s.questionWaiter = nil
        s.asking = false
        for (_, c) in s.clients { c.send(Message(op: "question", id: s.id)) }
    }

    private func answerPermission(_ s: HostSession, _ answer: String) {
        s.permissionWaiter?.send(Message(op: "decision", message: answer))
        s.permissionWaiter = nil
        s.permission = nil
        showNextPermission(s)
    }

    private func releasePermissions(_ s: HostSession) {
        for q in s.queuedPermissions { q.waiter.send(Message(op: "decision", message: "")) }
        s.queuedPermissions = []
        if s.permission != nil { answerPermission(s, "") }
    }

    private func showNextPermission(_ s: HostSession) {
        if s.queuedPermissions.isEmpty {
            s.asking = false
            for (_, c) in s.clients { c.send(Message(op: "permission", id: s.id)) }
            return
        }
        let next = s.queuedPermissions.removeFirst()
        s.permission = next.info
        s.permissionWaiter = next.waiter
        for (_, c) in s.clients { c.send(Message(op: "permission", id: s.id, permission: next.info)) }
    }

    static func permissionSummary(_ tool: String, _ input: [String: Any], cwd: String?) -> String {
        func rel(_ p: String) -> String {
            if let c = cwd, p.hasPrefix(c + "/") { return String(p.dropFirst(c.count + 1)) }
            return p
        }
        let command = (input["command"] as? String) ?? (input["command"] as? [String])?.joined(separator: " ")
        let text: String
        if let command { text = Transcript.shellCommand(command) }
        else if let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? (input["path"] as? String) { text = rel(path) }
        else if let url = input["url"] as? String { text = url }
        else if let q = input["query"] as? String { text = q }
        else if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) { text = String(decoding: data, as: UTF8.self) }
        else { text = "" }
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 300 ? String(line.prefix(299)) + "…" : line
    }


    private func handoffInfo(_ s: HostSession) -> Result<HandoffInfo, HandoffError> {
        let agent = s.info.command
        guard agent == "claude" || agent == "codex" else { return .failure(.noAgent) }
        return Handoff.info(pid: s.process.foregroundPID, agent: agent)
    }

    static func json<T: Encodable>(_ v: T) -> String? {
        (try? JSONEncoder().encode(v)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func borrow(_ m: Message, from conn: Connection) {
        let args = (m.message.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
        let task = String(((args["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !task.isEmpty else { conn.send(Message(op: "agent-result", code: 1, message: "Give a task.")); return }
        guard let key = borrowWatchers.last(where: { connections[$0] != nil }), let mac = connections[key] else {
            conn.send(Message(op: "agent-result", code: 1, message: "The Terminess app on the Mac isn't connected to this machine right now, so the task can't be handed to it. Ask the person to open Terminess on their Mac."))
            return
        }
        let req = String(UUID().uuidString.prefix(8)).lowercased()
        toolWaiters[req] = conn
        let host = ProcessInfo.processInfo.hostName
        let from = m.id.flatMap { sessions[$0] }.map { "\(host): \($0.info.cwd)" } ?? host
        mac.send(Message(op: "borrow-request", host: host, id: req, name: from, message: task))
        log("borrow \(req): sent to the Mac")
        queue.asyncAfter(deadline: .now() + Self.borrowTimeout) { [weak self] in
            guard let w = self?.toolWaiters.removeValue(forKey: req) else { return }
            w.send(Message(op: "agent-result", code: 1, message: "No answer from the Mac within \(Int(Self.borrowTimeout / 60)) minutes."))
        }
    }

    private func dropConnection(_ key: ObjectIdentifier) {
        clientKinds[key] = nil
        deviceNames[key] = nil
        reminderWatchers.remove(key)
        borrowWatchers.removeAll { $0 == key }
        for (req, w) in toolWaiters where ObjectIdentifier(w) == key { toolWaiters[req] = nil }
        for s in sessions.values where s.questionWaiter.map(ObjectIdentifier.init) == key { clearQuestion(s) }
        for s in sessions.values {
            s.queuedPermissions.removeAll { ObjectIdentifier($0.waiter) == key }
            if s.permissionWaiter.map(ObjectIdentifier.init) == key {
                s.permissionWaiter = nil
                s.permission = nil
                showNextPermission(s)
            }
        }
        if let id = bindings.removeValue(forKey: key), let s = sessions[id] {
            s.clients[key] = nil
            clientSizes[key] = nil
            restoreSize(s)
        }
        clientSizes[key] = nil
        transcriptSubs[key] = nil
        if let u = uploads.removeValue(forKey: key) { try? u.handle.close(); unlink(u.path) }
        connections[key] = nil
    }

    private func handle(_ frame: Wire.Frame, from conn: Connection) {
        let key = ObjectIdentifier(conn)
        switch frame.kind {
        case .input:
            if let id = bindings[key], let s = sessions[id] {
                owners[id] = key
                if let size = clientSizes[key], size.cols != s.cols || size.rows != s.rows {
                    clientSizes[key]?.at = Date().timeIntervalSince1970
                    resize(s, cols: size.cols, rows: size.rows, nudge: false)
                }
                s.process.write(frame.payload)
                releasePermissions(s)
                s.attention = false
                s.asking = false
                s.active = Date().timeIntervalSince1970
            }
        case .response:
            if let id = bindings[key], let s = sessions[id], owners[id] == nil || owners[id] == key || s.clients.count == 1 {
                s.process.write(frame.payload)
            }
        case .output:
            break
        case .control:
            guard let m = frame.message else { conn.send(Message(op: "error", message: "bad control message")); return }
            control(m, from: conn)
        }
    }

    private func control(_ m: Message, from conn: Connection) {
        let key = ObjectIdentifier(conn)
        switch m.op {
        case "hello":
            var hello = Message(op: "hello", version: Wire.version, host: ProcessInfo.processInfo.hostName)
            hello.platform = Self.platform
            conn.send(hello)
        case "watch-reminders":
            reminderWatchers.insert(key)
            conn.send(Message(op: "watching"))
            for r in reminders.pending { conn.send(reminderMessage(r)) }
        case "reminders":
            var reply = Message(op: "reminders")
            reply.reminders = reminders.items
            conn.send(reply)
        case "remind-add":
            guard let r = m.reminder else { conn.send(Message(op: "error", message: "no reminder")); return }
            switch addReminder(r) {
            case .success(let saved):
                var reply = Message(op: "reminder-added", id: saved.id)
                reply.reminder = saved
                conn.send(reply)
            case .failure(let e):
                conn.send(Message(op: "error", message: e.text))
            }
        case "remind-cancel", "reminder-dismiss":
            guard let id = m.id, reminders.remove(id) != nil else { conn.send(Message(op: "error", message: "no reminder \(m.id ?? "")")); return }
            broadcastReminderDone(id)
            conn.send(Message(op: "ok", id: id))
        case "reminder-act":
            guard let id = m.id, let r = reminders.remove(id) else { conn.send(Message(op: "error", message: "no reminder \(m.id ?? "")")); return }
            broadcastReminderDone(id)
            do {
                let session = try actOn(r)
                conn.send(Message(op: "reminder-acted", id: session, name: r.id))
            } catch {
                conn.send(Message(op: "error", message: "\(error)"))
            }
        case "handoff-info":
            guard let id = m.id, let s = sessions[id] ?? sessions.values.first(where: { $0.name == id }) else {
                conn.send(Message(op: "error", message: "no session \(m.id ?? "")")); return
            }
            switch handoffInfo(s) {
            case .success(let info): conn.send(Message(op: "handoff-info", id: s.id, message: Self.json(info)))
            case .failure(let e): conn.send(Message(op: "error", message: e.description))
            }
        case "handoff-export":
            guard let id = m.id, let s = sessions[id] ?? sessions.values.first(where: { $0.name == id }) else {
                conn.send(Message(op: "error", message: "no session \(m.id ?? "")")); return
            }
            let info: HandoffInfo
            switch handoffInfo(s) {
            case .success(let i): info = i
            case .failure(let e): conn.send(Message(op: "error", message: e.description)); return
            }
            let pid = s.process.foregroundPID
            let sid = s.id
            DispatchQueue.global().async { [weak self] in
                let result: Result<Data, HandoffError>
                if !Handoff.stop(pid: pid) {
                    result = .failure(.io("The agent didn't stop within 15 seconds, so nothing was moved."))
                } else {
                    let fresh = Handoff.describe(agent: info.agent, conversation: info.conversation, cwd: info.cwd, transcript: info.transcriptPath)
                    switch Handoff.bundle(fresh) {
                    case .success(let b):
                        if let d = HandoffTransfer.encode(b) { result = .success(d) } else { result = .failure(.io("Couldn't encode the bundle.")) }
                    case .failure(let e):
                        result = .failure(e)
                    }
                }
                self?.queue.async {
                    guard let self else { return }
                    switch result {
                    case .success(let data):
                        let token = String(UUID().uuidString.prefix(12)).lowercased()
                        self.handoffOut[token] = data
                        self.log("handoff export: \(info.agent) \(info.conversation) from session \(sid), \(data.count) bytes")
                        conn.send(Message(op: "handoff-ready", name: token, code: data.count, message: Self.json(info)))
                    case .failure(let e):
                        conn.send(Message(op: "error", message: e.description))
                    }
                }
            }
        case "handoff-get":
            guard let token = m.name, let data = handoffOut[token], let offset = m.code, offset >= 0, offset < data.count else {
                conn.send(Message(op: "error", message: "no such handoff data")); return
            }
            var reply = Message(op: "handoff-data", code: offset)
            reply.data = data[offset..<min(offset + HandoffTransfer.chunk, data.count)].base64EncodedString()
            conn.send(reply)
        case "handoff-put":
            guard let token = m.name, let b64 = m.data, let part = Data(base64Encoded: b64) else {
                conn.send(Message(op: "error", message: "bad handoff chunk")); return
            }
            var have = handoffIn[token] ?? Data()
            guard (m.code ?? have.count) == have.count, have.count + part.count <= 512 * 1024 * 1024 else {
                conn.send(Message(op: "error", message: "handoff chunk out of order or too large")); return
            }
            have.append(part)
            handoffIn[token] = have
            conn.send(Message(op: "ok"))
        case "handoff-import":
            guard let token = m.name, let data = handoffIn.removeValue(forKey: token), let bundle = HandoffTransfer.decode(data) else {
                conn.send(Message(op: "error", message: "no complete handoff bundle")); return
            }
            let roots = (m.message.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: String]) ?? [:]
            let source = roots["sourceRoot"] ?? "~/github"
            let target = Handoff.expand(roots["targetRoot"] ?? "~/github")
            DispatchQueue.global().async { [weak self] in
                let result = Handoff.importBundle(bundle, sourceRoot: source, targetRoot: target)
                self?.queue.async {
                    switch result {
                    case .success(let r):
                        self?.log("handoff import: \(bundle.info.agent) \(bundle.info.conversation) into \(r.cwd)")
                        conn.send(Message(op: "handoff-imported", message: Self.json(r)))
                    case .failure(let e):
                        conn.send(Message(op: "error", message: e.description))
                    }
                }
            }
        case "handoff-drop":
            if let token = m.name { handoffOut[token] = nil; handoffIn[token] = nil }
            conn.send(Message(op: "ok"))
        case "watch-borrow":
            borrowWatchers.removeAll { $0 == key }
            borrowWatchers.append(key)
            conn.send(Message(op: "watching"))
        case "borrow-reply":
            if let req = m.id, let w = toolWaiters.removeValue(forKey: req) {
                w.send(Message(op: "agent-result", code: m.code ?? 0, message: m.message ?? ""))
            }
        case "list":
            conn.send(Message(op: "sessions", sessions: order.compactMap { sessions[$0].map(sessionInfo) }))
        case "create":
            do {
                let s = try createSession(m)
                if let resumed = m.resumeOf { warnIfOlder(s, resuming: resumed) }
                s.origin = m.host
                s.originName = Self.cleanDeviceName(m.deviceName)
                conn.send(Message(op: "created", id: s.id))
            } catch {
                conn.send(Message(op: "error", message: "\(error)"))
            }
        case "attach":
            guard let id = m.id, let s = sessions[id] ?? sessions.values.first(where: { $0.name == m.id }) else {
                conn.send(Message(op: "error", message: "no session \(m.id ?? "")"))
                return
            }
            if let old = bindings[key] { sessions[old]?.clients[key] = nil }
            bindings[key] = s.id
            s.clients[key] = conn
            if let kind = m.host { clientKinds[key] = kind }
            if let name = Self.cleanDeviceName(m.deviceName) { deviceNames[key] = name }
            if m.host == "mac" { s.origin = nil }
            conn.send(Message(op: "attached", id: s.id, cols: s.cols, rows: s.rows))
            if !s.replay.isEmpty { conn.send(Wire.Frame(.output, s.replay)) }
            conn.send(Message(op: "replayed", id: s.id))
            let fg = s.foreground
            s.lastForeground = fg
            conn.send(Message(op: "info", id: s.id, foreground: fg))
            if let p = s.permission { conn.send(Message(op: "permission", id: s.id, permission: p)) }
            if let q = s.question { conn.send(Message(op: "question", id: s.id, question: q)) }
            if let n = s.notice { conn.send(Message(op: "notice", id: s.id, message: n)) }
            if let c = m.cols, let r = m.rows {
                clientSizes[key] = (c, r, Date().timeIntervalSince1970)
                owners[s.id] = key
                resize(s, cols: c, rows: r, nudge: true)
            } else if owners[s.id] == nil || s.clients[owners[s.id]!] == nil {
                owners[s.id] = key
            }
        case "resize":
            guard let id = bindings[key], let s = sessions[id] else { break }
            if let c = m.cols, let r = m.rows {
                clientSizes[key] = (c, r, Date().timeIntervalSince1970)
                owners[id] = key
                resize(s, cols: c, rows: r, nudge: false)
            } else {
                clientSizes[key] = nil
                if owners[id] == key { restoreSize(s) }
            }
        case "signal":
            guard let id = m.id ?? bindings[key], let s = sessions[id] else {
                conn.send(Message(op: "error", message: "no session"))
                return
            }
            let sig: Int32
            switch m.signal ?? "TERM" {
            case "INT": sig = SIGINT
            case "HUP": sig = SIGHUP
            case "KILL": sig = SIGKILL
            default: sig = SIGTERM
            }
            let pg = s.process.foregroundProcessGroup
            let sent = pg > 0 && pg != s.process.pid && kill(-pg, sig) == 0
            conn.send(Message(op: "ok", id: s.id, code: sent ? 1 : 0))
        case "transcript":
            guard let id = m.id, sessions[id] != nil else { conn.send(Message(op: "error", message: "no session \(m.id ?? "")")); return }
            transcriptSubs[key] = (id, [], nil)
            pushTranscripts(only: key)
        case "untranscript":
            transcriptSubs[key] = nil
        case "projects":
            var reply = Message(op: "projects", projects: Projects.recent())
            reply.folders = Projects.folders()
            conn.send(reply)
        case "models":
            LocalModels.installed { names in
                self.queue.async { conn.send(Message(op: "models", args: names ?? [], code: names == nil ? 0 : 1)) }
            }
        case "set-name":
            guard let id = m.id, let s = sessions[id], let name = m.name?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                conn.send(Message(op: "error", message: "no session \(m.id ?? "")")); return
            }
            let lock = m.code == 1
            if !s.nameLocked || lock || m.code == 2 {
                s.name = name
                s.nameLocked = lock && !name.isEmpty
            }
            conn.send(Message(op: "ok", id: id))
        case "history":
            conn.send(Message(op: "history", history: commits.annotate(historyProvider())))
        case "model-roles", "set-model-role":
            var roles = ModelRoles.load()
            if m.op == "set-model-role" {
                guard let agent = m.name, let role = m.id, ModelRoles.roles[agent]?.contains(role) == true else {
                    conn.send(Message(op: "error", message: "no such role")); return
                }
                roles.set(agent, role, m.message ?? "")
                do { try roles.save() } catch { conn.send(Message(op: "error", message: "\(error)")); return }
            }
            var reply = Message(op: "model-roles")
            reply.roles = roles
            conn.send(reply)
        case "agent-models":
            var reply = Message(op: "agent-models", name: m.name)
            reply.agentModels = AgentModels.list(for: m.name)
            conn.send(reply)
        case "upload":
            upload(m, from: conn)
        case "register-push":
            guard let token = m.token, !token.isEmpty else { conn.send(Message(op: "error", message: "no token")); return }
            push.register(token: token, environment: m.message ?? "production", host: m.name, credential: m.credential, key: m.key,
                          relay: m.relay)
            conn.send(Message(op: "ok"))
        case "revoke-push":
            push.revoke(key: m.key ?? "")
            conn.send(Message(op: "ok"))
        case "unregister-push":
            push.unregister(token: m.token ?? "")
            conn.send(Message(op: "ok"))
        case "detach":
            if let id = bindings.removeValue(forKey: key), let s = sessions[id] {
                s.clients[key] = nil
                clientSizes[key] = nil
                restoreSize(s)
            }
        case "hook":
            guard let id = m.id, let s = sessions[id], let raw = m.message,
                  let event = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return }
            if m.name == "codex" { codexHook(event, in: s) } else { hook(event, in: s) }
        case "permission":
            guard let id = m.id, let s = sessions[id], let raw = m.message,
                  let e = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  let tool = e["tool_name"] as? String else {
                conn.send(Message(op: "decision", message: "")); return
            }
            guard !s.clients.isEmpty || !push.devices.isEmpty else { conn.send(Message(op: "decision", message: "")); return }
            let input = e["tool_input"] as? [String: Any] ?? [:]
            let req = PermissionInfo(id: String(UUID().uuidString.prefix(8)).lowercased(), tool: tool,
                                     summary: Self.permissionSummary(tool, input, cwd: e["cwd"] as? String),
                                     canAlways: !((e["permission_suggestions"] as? [Any]) ?? []).isEmpty)
            if s.permission != nil {
                s.queuedPermissions.append((req, conn))
                return
            }
            s.permission = req
            s.permissionWaiter = conn
            for (_, c) in s.clients { c.send(Message(op: "permission", id: s.id, permission: req)) }
            raiseAttention(s, .approval)
        case "agent-tool":
            func done(_ text: String, failed: Bool = false) { conn.send(Message(op: "agent-result", code: failed ? 1 : 0, message: text)) }
            if m.name == "borrow" { borrow(m, from: conn); return }
            guard let id = m.id, let s = sessions[id], let tool = m.name else { done("No such Terminess session.", failed: true); return }
            let args = (m.message.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
            switch tool {
            case "notify":
                let text = String(((args["message"] as? String) ?? "").prefix(500))
                guard !text.isEmpty else { done("Give a message.", failed: true); return }
                for (k, c) in s.clients where clientKinds[k] == "mac" { c.send(Message(op: "agent-note", id: s.id, message: text)) }
                raiseAttention(s, .needsYou)
                done("Sent to the person's Mac and phone.")
            case "ask_user":
                let text = String(((args["question"] as? String) ?? "").prefix(1000))
                guard !text.isEmpty else { done("Give a question.", failed: true); return }
                let choices = ((args["choices"] as? [String]) ?? []).prefix(5).map { String($0.prefix(80)) }
                if let w = s.questionWaiter { w.send(Message(op: "agent-result", code: 1, message: "Replaced by a newer question.")) }
                let q = QuestionInfo(id: String(UUID().uuidString.prefix(8)).lowercased(), text: text, choices: Array(choices))
                s.question = q
                s.questionWaiter = conn
                for (_, c) in s.clients { c.send(Message(op: "question", id: s.id, question: q)) }
                raiseAttention(s, .needsYou)
            case "remind":
                let at = (args["at"] as? String) ?? ""
                guard let due = ReminderTime.parse(at) else {
                    done("Give `at` as a time like 22:00, +2h or 2026-11-17T22:00 (this machine's time zone unless it has an offset).", failed: true); return
                }
                let title = ((args["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { done("Give a short title.", failed: true); return }
                let r = ReminderInfo(id: "", title: title, body: args["body"] as? String, due: due.timeIntervalSince1970,
                                     actionLabel: args["action_label"] as? String, actionPrompt: args["action_prompt"] as? String,
                                     sessionId: s.id, created: 0)
                switch addReminder(r) {
                case .success(let saved):
                    done("Reminder \(saved.id) set for \(Self.describe(Date(timeIntervalSince1970: saved.due))). At that time the person gets a notification on their Mac and phone with a \(saved.label) button" +
                         (saved.actionPrompt == nil ? "." : " that types your prompt into this session (or resumes this conversation if the session has ended)."))
                case .failure(let e):
                    done(e.text, failed: true)
                }
            case "open_tab", "start_worktree":
                guard let mac = s.clients.first(where: { clientKinds[$0.key] == "mac" })?.value else {
                    done("That needs the Terminess app on the Mac to be showing this session.", failed: true); return
                }
                let req = String(UUID().uuidString.prefix(8)).lowercased()
                toolWaiters[req] = conn
                mac.send(Message(op: "agent-request", id: req, name: tool, message: m.message))
            default:
                done("Unknown tool \(tool).", failed: true)
            }
        case "agent-reply":
            if let req = m.id, let w = toolWaiters.removeValue(forKey: req) {
                w.send(Message(op: "agent-result", code: m.code ?? 0, message: m.message ?? ""))
            }
        case "answer":
            guard let id = m.id, let s = sessions[id], let q = s.question, q.id == m.name else { conn.send(Message(op: "ok")); return }
            s.questionWaiter?.send(Message(op: "agent-result", code: 0, message: "The person answered: " + (m.message ?? "")))
            clearQuestion(s)
            conn.send(Message(op: "ok"))
        case "decide":
            guard let id = m.id, let s = sessions[id], let p = s.permission, p.id == m.name,
                  let answer = m.message, ["allow", "always", "deny"].contains(answer) else {
                conn.send(Message(op: "ok")); return
            }
            answerPermission(s, answer)
            conn.send(Message(op: "ok"))
        case "kill":
            guard let id = m.id, let s = sessions[id] ?? sessions.values.first(where: { $0.name == m.id }) else {
                conn.send(Message(op: "error", message: "no session \(m.id ?? "")"))
                return
            }
            s.process.hangUp()
            conn.send(Message(op: "ok", id: s.id))
        default:
            conn.send(Message(op: "error", message: "unknown op \(m.op)"))
        }
    }

    private var scheduleTick = 0

    private func runDueSchedules() {
        scheduleTick += 1
        guard scheduleTick % 60 == 0 else { return }
        var list = AgentSchedules.load()
        guard !list.isEmpty else { return }
        let now = Date()
        var changed = false
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        for i in list.indices where list[i].next <= now.timeIntervalSince1970 {
            let s = list[i]
            let title = "Scheduled: " + String(s.task.prefix(40))
            _ = try? createSession(Message(op: "create", name: title, cwd: s.cwd, command: exe,
                                           args: ["agent", "--once", "--model", s.model, "--auto", s.auto, s.task]))
            list[i].lastRun = now.timeIntervalSince1970
            list[i].next = AgentSchedules.next(after: now, every: s.everyMinutes, at: s.at).timeIntervalSince1970
            changed = true
            log("started scheduled run \(s.id)")
        }
        if changed { AgentSchedules.save(list) }
    }


    struct ReminderError: Error { let text: String }

    private func addReminder(_ r: ReminderInfo) -> Result<ReminderInfo, ReminderError> {
        var r = r
        guard !r.title.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(ReminderError(text: "A reminder needs a title.")) }
        guard r.due > Date().timeIntervalSince1970 - 60 else { return .failure(ReminderError(text: "That time has already passed.")) }
        guard r.due < Date().timeIntervalSince1970 + 366 * 86400 else { return .failure(ReminderError(text: "That is more than a year away.")) }
        if let sid = r.sessionId, !sid.isEmpty {
            guard let s = sessions[sid] else { return .failure(ReminderError(text: "No session \(sid) here.")) }
            let fg = s.foreground
            if r.cwd == nil, !fg.cwd.isEmpty { r.cwd = fg.cwd }
            switch fg.command {
            case "claude":
                r.agent = "claude"
                r.conversation = r.conversation ?? ReminderStore.claudeConversation(pid: fg.pid, home: claudeHome)
            case "codex":
                r.agent = "codex"
            default: break
            }
        } else {
            r.sessionId = nil
        }
        let saved = reminders.add(r)
        log("reminder \(saved.id) set for \(Self.describe(Date(timeIntervalSince1970: saved.due)))")
        return .success(saved)
    }

    private func reminderMessage(_ r: ReminderInfo) -> Message {
        var m = Message(op: "reminder", id: r.id)
        m.reminder = r
        return m
    }

    private var reminderWatchers: Set<ObjectIdentifier> = []

    private func fireDueReminders() {
        for r in reminders.fireDue() {
            log("reminder \(r.id) is due")
            let m = reminderMessage(r)
            for k in reminderWatchers { connections[k]?.send(m) }
            if let sid = r.sessionId, let s = sessions[sid] { s.attention = true }
            push.notify(.reminder, session: r.sessionId ?? "", reminder: r.id)
        }
    }

    private func broadcastReminderDone(_ id: String) {
        let m = Message(op: "reminder-done", id: id)
        for k in reminderWatchers { connections[k]?.send(m) }
    }

    private func actOn(_ r: ReminderInfo) throws -> String {
        if let sid = r.sessionId, let s = sessions[sid] {
            s.attention = false
            if let prompt = r.actionPrompt, !prompt.isEmpty {
                s.process.write(Array(prompt.utf8))
                queue.asyncAfter(deadline: .now() + promptReturnDelay) { [weak s] in s?.process.write([0x0D]) }
                s.active = Date().timeIntervalSince1970
            }
            return sid
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/"
        var cwd = r.cwd ?? home
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue { cwd = home }
        let title = String(r.title.prefix(40))
        if let command = ReminderStore.resumeShellCommand(r) {
            let shell = PTYProcess.userShell
            let s = try createSession(Message(op: "create", name: title, cwd: cwd, command: shell,
                                              args: ["-l", "-i", "-c", command + "; exec " + ReminderStore.shellQuote(shell) + " -l"]))
            return s.id
        }
        return try createSession(Message(op: "create", name: title, cwd: cwd)).id
    }

    static func describe(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM HH:mm zzz"
        return f.string(from: date)
    }

    private func createSession(_ m: Message) throws -> HostSession {
        let cols = max(20, m.cols ?? 100), rows = max(5, m.rows ?? 30)
        let shell = PTYProcess.userShell
        let executable: String
        let args: [String]
        let argv0: String?
        if let command = m.command, !command.isEmpty {
            executable = command
            args = m.args ?? []
            argv0 = nil
        } else {
            executable = shell
            args = []
            argv0 = "-" + shell.split(separator: "/").last.map(String.init)!
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/"
        let cwd = (m.cwd?.isEmpty == false ? m.cwd! : home).replacingOccurrences(of: "~", with: home, options: .anchored)
        var env = m.env ?? PTYProcess.defaultEnvironment(program: "Terminess")
        for k in PTYProcess.agentSessionVariables { env[k] = nil }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        env["TERMINESS_SESSION"] = id
        for (k, v) in ModelRoles.load().environment() { env[k] = v }
        if let bin = Self.bundledBin {
            let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            if !path.split(separator: ":").contains(Substring(bin)) { env["PATH"] = path + ":" + bin }
        }
        let process = try PTYProcess(executable: executable, arguments: args, argv0: argv0, environment: env,
                                     workingDirectory: cwd, columns: cols, rows: rows)
        let name = m.name?.isEmpty == false ? m.name! : "\(nextNumber)"
        nextNumber += 1
        let s = HostSession(id: id, name: name, process: process,
                            command: executable.split(separator: "/").last.map(String.init) ?? executable,
                            cols: cols, rows: rows)
        sessions[id] = s
        order.append(id)
        process.start(queue: queue, onData: { [weak self, weak s] bytes in
            guard let self, let s else { return }
            self.queue.async { self.output(bytes, from: s) }
        }, onExit: { [weak self] code in
            guard let self else { return }
            self.queue.async { self.ended(id, code: Int(code)) }
        })
        log("session \(id) (\(name)) started: \(executable) in \(cwd)")
        return s
    }

    private func warnIfOlder(_ s: HostSession, resuming id: String) {
        let items = CommitCounter.markNewest(historyProvider())
        guard let item = items.first(where: { $0.id == id }), item.newest == false else { return }
        let counter = commits
        DispatchQueue.global(qos: .utility).async { [weak self, weak s] in
            let n = counter.count(folder: item.cwd, since: item.used)
            guard let text = CommitCounter.notice(for: item, commits: n) else { return }
            self?.queue.async {
                guard let self, let s, self.sessions[s.id] != nil else { return }
                s.notice = text
                s.onTurnEnd = { [weak self, weak s] in
                    guard let self, let s, s.notice != nil else { return }
                    s.notice = nil
                    s.onTurnEnd = nil
                    for c in s.clients.values { c.send(Message(op: "notice", id: s.id)) }
                }
                for c in s.clients.values { c.send(Message(op: "notice", id: s.id, message: text)) }
            }
        }
    }

    private func pushForeground(only s: HostSession? = nil, force: Bool = false) {
        for session in s.map({ [$0] }) ?? Array(sessions.values) where !session.clients.isEmpty {
            let fg = session.foreground
            guard force || fg != session.lastForeground else { continue }
            session.lastForeground = fg
            let m = Message(op: "info", id: session.id, foreground: fg)
            for c in session.clients.values { c.send(m) }
        }
    }

    private func output(_ bytes: [UInt8], from s: HostSession) {
        s.record(bytes)
        s.active = Date().timeIntervalSince1970
        for event in s.scanner.scan(bytes) {
            switch event {
            case .title(let t):
                s.title = t
                if s.hooked && s.hookAgent == "claude" { continue }
                let wasBusy = s.busy
                s.busy = TitleState.busy(t)
                if wasBusy && !s.busy && !s.hooked { raiseAttention(s, .finished) }
            case .bell:
                raiseAttention(s, .needsYou)
            case .notify:
                raiseAttention(s, .needsYou)
            }
        }
        let frame = Wire.Frame(.output, bytes)
        for c in s.clients.values { c.send(frame) }
    }

    private func codexHook(_ e: [String: Any], in s: HostSession) {
        guard e["type"] as? String == "agent-turn-complete" else { return }
        s.hookPid = s.process.foregroundPID
        s.hookAgent = "codex"
        s.busy = false
        raiseAttention(s, .finished)
        pushTranscripts()
    }

    static func trustedTranscript(_ path: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let roots = [(env["CLAUDE_CONFIG_DIR"] ?? home + "/.claude") + "/projects/",
                     (env["CODEX_HOME"] ?? home + "/.codex") + "/sessions/",
                     LocalChat.directory + "/"]
        guard path.hasSuffix(".jsonl"), !path.split(separator: "/").contains(".."),
              roots.contains(where: { path.hasPrefix($0) }) else { return false }
        return UnixSocket.ownFile(path)?.type == .typeRegular
    }

    static let bundledBin: String? = {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bin = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/bin").path
        return FileManager.default.isExecutableFile(atPath: bin + "/pair") ? bin : nil
    }()

    private func hook(_ e: [String: Any], in s: HostSession) {
        let pid = s.process.foregroundPID
        s.hookAgent = "claude"
        if let path = e["transcript_path"] as? String, Self.trustedTranscript(path) {
            s.transcript = (LocalChat.usesChatFile(s.command) ? s.command : "claude", path, pid)
        }
        switch e["hook_event_name"] as? String {
        case "SessionStart":
            s.hookPid = pid
            s.busy = false
        case "UserPromptSubmit":
            releasePermissions(s)
            s.hookPid = pid
            s.busy = true
            s.attention = false
            s.asking = false
        case "Stop":
            releasePermissions(s)
            s.hookPid = pid
            s.busy = false
            raiseAttention(s, .finished)
        case "StopFailure":
            s.hookPid = pid
            s.busy = false
            raiseAttention(s, .failed)
        case "Notification":
            s.hookPid = pid
            let type = e["notification_type"] as? String ?? ""
            guard !["idle_prompt", "auth_success", "agent_completed"].contains(type) else { break }
            raiseAttention(s, .needsYou)
        case "SessionEnd":
            s.hookPid = nil
            s.busy = false
        default:
            break
        }
        pushTranscripts()
    }

    private func raiseAttention(_ s: HostSession, _ reason: PushRegistry.Reason) {
        s.attention = true
        s.asking = reason == .needsYou || reason == .approval
        let now = Date().timeIntervalSince1970
        guard now - s.lastPush > 20 else { return }
        s.lastPush = now
        push.notify(reason, session: s.id)
    }

    private func transcriptPath(_ s: HostSession) -> (agent: String, path: String)? {
        let fg = s.foreground
        if LocalChat.usesChatFile(fg.command), let path = LocalChat.latest(for: s.id) {
            s.transcript = (fg.command, path, fg.pid)
            return (fg.command, path)
        }
        if fg.command == "claude" || fg.command == "codex", !fg.cwd.isEmpty {
            if s.hooked, let t = s.transcript, t.pid == fg.pid { return (t.agent, t.path) }
            if fg.command == "claude", let path = Transcript.claudeSession(pid: fg.pid) {
                s.transcript = (fg.command, path, fg.pid)
                return (fg.command, path)
            }
            if let pinned = s.transcript, pinned.agent == fg.command, pinned.pid == fg.pid { return (pinned.agent, pinned.path) }
            if let path = Transcript.locate(agent: fg.command, directory: fg.cwd,
                                            started: Date(timeIntervalSince1970: fg.started > 0 ? fg.started : s.created),
                                            arguments: fg.args, pid: fg.pid) {
                s.transcript = (fg.command, path, fg.pid)
            }
        }
        return s.transcript.map { ($0.agent, $0.path) }
    }

    private func pushTranscripts(only: ObjectIdentifier? = nil) {
        for (key, sub) in transcriptSubs where only == nil || key == only {
            guard let conn = connections[key], let s = sessions[sub.session] else { continue }
            guard let t = transcriptPath(s) else {
                if only != nil { conn.send(Message(op: "transcript", id: s.id, code: 0, items: [])) }
                continue
            }
            let mtime = Transcript.mtime(t.path)
            if only == nil, mtime == sub.mtime { continue }
            let items = Transcript.parse(t.path, agent: t.agent).map(Self.trimmed)
            var from = 0
            while from < items.count, from < sub.sent.count, items[from] == sub.sent[from] { from += 1 }
            transcriptSubs[key] = (sub.session, items, mtime)
            if from == items.count && items.count == sub.sent.count && only == nil { continue }
            conn.send(Message(op: "transcript", id: s.id, code: from, items: Array(items[from...])))
        }
    }

    private static func trimmed(_ item: TranscriptItem) -> TranscriptItem {
        guard case .tool(let name, let summary, let detail, let result) = item.kind else { return item }
        func cut(_ s: String) -> String { s.count > 1500 ? String(s.prefix(1500)) + "\n…" : s }
        return TranscriptItem(id: item.id, kind: .tool(name: name, summary: summary, detail: cut(detail), result: result.map(cut)))
    }

    private func upload(_ m: Message, from conn: Connection) {
        let key = ObjectIdentifier(conn)
        if uploads[key] == nil {
            let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            let dir = HostPaths.stateDirectory + "/uploads/" + day
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard (try? UnixSocket.checkPrivate(directory: dir)) != nil else { conn.send(Message(op: "error", message: "the upload folder isn't private")); return }
            let raw = (m.name ?? "file").replacingOccurrences(of: "/", with: "-")
            let safe = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || ".-_ ".unicodeScalars.contains($0) })
            var name = safe.isEmpty ? "file" : safe
            if name.hasPrefix(".") { name = "file" + name }
            var path = dir + "/" + name
            var n = 2
            var fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            while fd < 0 && errno == EEXIST && n < 1000 {
                let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
                path = dir + "/" + (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                n += 1
            }
            guard fd >= 0 else { conn.send(Message(op: "error", message: "could not save the file")); return }
            uploads[key] = (path, FileHandle(fileDescriptor: fd, closeOnDealloc: true))
        }
        guard let u = uploads[key] else { return }
        if let chunk = m.data, let bytes = Data(base64Encoded: chunk) { u.handle.write(bytes) }
        if m.code == 1 {
            try? u.handle.close()
            uploads[key] = nil
            conn.send(Message(op: "uploaded", message: u.path))
        } else {
            conn.send(Message(op: "ok"))
        }
    }

    private func ended(_ id: String, code: Int) {
        guard let s = sessions.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        for (key, c) in s.clients {
            c.send(Message(op: "exited", id: id, code: code))
            bindings[key] = nil
        }
        log("session \(id) ended (\(code))")
    }

    private func restoreSize(_ s: HostSession) {
        let remaining = s.clients.keys.compactMap { k in clientSizes[k].map { (k, $0) } }
        guard let best = remaining.max(by: { $0.1.at < $1.1.at }) else {
            owners[s.id] = s.clients.keys.first
            return
        }
        owners[s.id] = best.0
        guard best.1.cols != s.cols || best.1.rows != s.rows else { return }
        resize(s, cols: best.1.cols, rows: best.1.rows, nudge: false)
    }

    private func resize(_ s: HostSession, cols: Int?, rows: Int?, nudge: Bool) {
        let c = max(20, cols ?? s.cols), r = max(5, rows ?? s.rows)
        if nudge {
            s.process.resize(columns: c, rows: max(5, r - 1))
            queue.asyncAfter(deadline: .now() + .milliseconds(60)) { s.process.resize(columns: c, rows: r) }
        } else {
            s.process.resize(columns: c, rows: r)
        }
        let changed = s.cols != c || s.rows != r
        s.cols = c
        s.rows = r
        if changed { for (_, conn) in s.clients { conn.send(Message(op: "size", id: s.id, cols: c, rows: r)) } }
    }
}
