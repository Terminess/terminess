#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Dispatch
import Foundation
import TermHost
import TermPTY
import TermTranscript

final class HostSession {
    let id: String
    var name: String
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
    var busy = false
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
    private var toolWaiters: [String: Connection] = [:]
    private var nextNumber = 1
    public let socketPath: String
    public var log: (String) -> Void = { _ in }

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

    private func dropConnection(_ key: ObjectIdentifier) {
        clientKinds[key] = nil
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
            conn.send(Message(op: "hello", version: Wire.version, host: ProcessInfo.processInfo.hostName))
        case "list":
            conn.send(Message(op: "sessions", sessions: order.compactMap { sessions[$0]?.info }))
        case "create":
            do {
                let s = try createSession(m)
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
            conn.send(Message(op: "attached", id: s.id, cols: s.cols, rows: s.rows))
            if !s.replay.isEmpty { conn.send(Wire.Frame(.output, s.replay)) }
            conn.send(Message(op: "replayed", id: s.id))
            let fg = s.foreground
            s.lastForeground = fg
            conn.send(Message(op: "info", id: s.id, foreground: fg))
            if let p = s.permission { conn.send(Message(op: "permission", id: s.id, permission: p)) }
            if let q = s.question { conn.send(Message(op: "question", id: s.id, question: q)) }
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
            conn.send(Message(op: "projects", projects: Projects.recent()))
        case "models":
            LocalModels.installed { names in
                self.queue.async { conn.send(Message(op: "models", args: names ?? [], code: names == nil ? 0 : 1)) }
            }
        case "history":
            conn.send(Message(op: "history", history: History.recent()))
        case "upload":
            upload(m, from: conn)
        case "register-push":
            guard let token = m.token, !token.isEmpty else { conn.send(Message(op: "error", message: "no token")); return }
            push.register(token: token, environment: m.message ?? "production", host: m.name, credential: m.credential, key: m.key)
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
