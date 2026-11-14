#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Dispatch
import Foundation

public final class HostAttachment: @unchecked Sendable {
    public enum Target {
        case create(cwd: String?, command: String?, args: [String], env: [String: String]?, name: String?)
        case attach(id: String)
    }

    private let connection: Connection
    private var target: Target
    private var cols: Int
    private var rows: Int
    public private(set) var sessionID: String?
    public private(set) var foreground: ForegroundInfo?
    private var ended = false
    public var resizesAfterReplay = false

    public var onAttached: ((String, Int, Int) -> Void)?
    public var onSize: ((Int, Int) -> Void)?
    public var onReplayed: (() -> Void)?
    public var onOutput: (([UInt8]) -> Void)?
    public var onForeground: ((ForegroundInfo) -> Void)?
    public var onExit: ((Int) -> Void)?
    public var onDisconnect: ((String) -> Void)?

    public convenience init?(socketPath: String = HostPaths.socket, target: Target, cols: Int, rows: Int,
                             queue: DispatchQueue = .main) {
        guard let fd = UnixSocket.connect(socketPath) else { return nil }
        self.init(readFD: fd, writeFD: fd, target: target, cols: cols, rows: rows, queue: queue)
    }

    public init(readFD: Int32, writeFD: Int32, target: Target, cols: Int, rows: Int, queue: DispatchQueue = .main) {
        connection = Connection(readFD: readFD, writeFD: writeFD, queue: queue)
        self.target = target
        self.cols = cols
        self.rows = rows
        connection.onFrame = { [weak self] frame in self?.handle(frame) }
        connection.onClose = { [weak self] in
            guard let self, !self.ended else { return }
            self.ended = true
            self.onDisconnect?("lost the connection to terminessd")
        }
    }

    public func start() {
        connection.start()
        connection.send(Message(op: "hello", version: Wire.version))
    }

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        connection.send(Wire.Frame(.input, bytes))
    }

    public func respond(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        connection.send(Wire.Frame(.response, bytes))
    }

    public func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        if sessionID != nil { connection.send(Message(op: "resize", cols: cols, rows: rows)) }
    }

    public func releaseSize() {
        if sessionID != nil { connection.send(Message(op: "resize")) }
    }

    public func kill() {
        guard let id = sessionID else { connection.close(); return }
        connection.send(Message(op: "kill", id: id))
    }

    public func signal(_ name: String) {
        guard let id = sessionID else { return }
        connection.send(Message(op: "signal", id: id, signal: name))
    }

    public func detach() {
        ended = true
        if sessionID != nil { connection.send(Message(op: "detach")) }
        connection.close()
    }

    private func handle(_ frame: Wire.Frame) {
        switch frame.kind {
        case .output:
            onOutput?(frame.payload)
        case .input, .response:
            break
        case .control:
            guard let m = frame.message else { return }
            switch m.op {
            case "hello":
                guard (m.version ?? 0) >= 2 else {
                    fail("terminessd is too old (protocol \(m.version ?? 0)); restart it")
                    return
                }
                switch target {
                case .create(let cwd, let command, let args, let env, let name):
                    connection.send(Message(op: "create", name: name, cwd: cwd, command: command, args: args,
                                            cols: cols, rows: rows, env: env))
                case .attach(let id):
                    sendAttach(id)
                }
            case "created":
                guard let id = m.id else { return }
                target = .attach(id: id)
                sendAttach(id)
            case "attached":
                sessionID = m.id
                if let id = m.id { onAttached?(id, m.cols ?? 0, m.rows ?? 0) }
            case "replayed":
                onReplayed?()
            case "size":
                if let c = m.cols, let r = m.rows, c > 0, r > 0 { onSize?(c, r) }
            case "info":
                if let fg = m.foreground {
                    foreground = fg
                    onForeground?(fg)
                }
            case "exited":
                ended = true
                onExit?(m.code ?? 0)
                connection.close()
            case "error":
                fail(m.message ?? "terminessd error")
            default:
                break
            }
        }
    }

    private func sendAttach(_ id: String) {
        if resizesAfterReplay {
            connection.send(Message(op: "attach", id: id))
        } else {
            connection.send(Message(op: "attach", id: id, cols: cols, rows: rows))
        }
    }

    private func fail(_ message: String) {
        guard !ended else { return }
        ended = true
        connection.close()
        onDisconnect?(message)
    }

    @discardableResult
    public static func send(_ m: Message, socketPath: String = HostPaths.socket) -> Bool {
        guard let fd = UnixSocket.connect(socketPath) else { return false }
        defer { Darwin_close(fd) }
        return Connection.writeAll(fd, Wire.Frame.control(m).encoded())
    }

    public static func list(socketPath: String = HostPaths.socket, timeout: Double = 2) -> [SessionInfo]? {
        guard let fd = UnixSocket.connect(socketPath) else { return nil }
        defer { Darwin_close(fd) }
        guard Connection.writeAll(fd, Wire.Frame.control(Message(op: "list")).encoded()) else { return nil }
        var decoder = Wire.Decoder()
        var buf = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 200) >= 0 else { return nil }
            if p.revents == 0 { continue }
            let n = read(fd, &buf, buf.count)
            guard n > 0, let frames = try? decoder.feed(Array(buf[0..<n])) else { return nil }
            if let m = frames.compactMap(\.message).first(where: { $0.op == "sessions" }) { return m.sessions ?? [] }
        }
        return nil
    }
}
