#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Dispatch
import Foundation
import TermPTY

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

    var foreground: ForegroundInfo {
        let fgPid = process.foregroundPID
        return ForegroundInfo(command: process.foregroundCommand ?? initialCommand,
                              cwd: process.foregroundDirectory ?? "",
                              args: fgPid == process.pid ? [] : process.foregroundArguments,
                              started: process.foregroundStartTime ?? 0, pid: fgPid, shellPid: process.pid)
    }

    var info: SessionInfo {
        SessionInfo(id: id, name: name, command: process.foregroundCommand ?? initialCommand,
                    cwd: process.foregroundDirectory ?? "", created: created, clients: clients.count)
    }
}

public final class HostServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "terminessd")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var infoTimer: DispatchSourceTimer?
    private var sessions: [String: HostSession] = [:]
    private var order: [String] = []
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var bindings: [ObjectIdentifier: String] = [:]
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
        t.setEventHandler { [weak self] in self?.pushForeground() }
        infoTimer = t
        t.resume()
        log("listening on \(socketPath)")
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let conn = Connection(readFD: fd, queue: queue)
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.onFrame = { [weak self, weak conn] frame in
            guard let self, let conn else { return }
            self.handle(frame, from: conn)
        }
        conn.onClose = { [weak self] in self?.dropConnection(key) }
        conn.start()
    }

    private func dropConnection(_ key: ObjectIdentifier) {
        if let id = bindings.removeValue(forKey: key) { sessions[id]?.clients[key] = nil }
        connections[key] = nil
    }

    private func handle(_ frame: Wire.Frame, from conn: Connection) {
        let key = ObjectIdentifier(conn)
        switch frame.kind {
        case .input:
            if let id = bindings[key], let s = sessions[id] { s.process.write(frame.payload) }
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
            conn.send(Message(op: "attached", id: s.id, cols: s.cols, rows: s.rows))
            if !s.replay.isEmpty { conn.send(Wire.Frame(.output, s.replay)) }
            conn.send(Message(op: "replayed", id: s.id))
            let fg = s.foreground
            s.lastForeground = fg
            conn.send(Message(op: "info", id: s.id, foreground: fg))
            if m.cols != nil || m.rows != nil { resize(s, cols: m.cols, rows: m.rows, nudge: true) }
        case "resize":
            if let id = bindings[key], let s = sessions[id] { resize(s, cols: m.cols, rows: m.rows, nudge: false) }
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
        case "detach":
            if let id = bindings.removeValue(forKey: key) { sessions[id]?.clients[key] = nil }
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
        let frame = Wire.Frame(.output, bytes)
        for c in s.clients.values { c.send(frame) }
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

    private func resize(_ s: HostSession, cols: Int?, rows: Int?, nudge: Bool) {
        let c = max(20, cols ?? s.cols), r = max(5, rows ?? s.rows)
        if nudge {
            s.process.resize(columns: c, rows: max(5, r - 1))
            queue.asyncAfter(deadline: .now() + .milliseconds(60)) { s.process.resize(columns: c, rows: r) }
        } else {
            s.process.resize(columns: c, rows: r)
        }
        s.cols = c
        s.rows = r
    }
}
