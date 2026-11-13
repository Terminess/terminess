import CPTY
import Darwin
import Dispatch

public struct PTYError: Error, CustomStringConvertible {
    public let message: String
    public let code: Int32
    public var description: String { "\(message): \(String(cString: strerror(code)))" }
}

public final class PTYProcess: @unchecked Sendable {
    public let pid: pid_t
    public let fd: Int32

    private let lock = PThreadLock()
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var exited = false

    public static let agentSessionVariables: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_EXECPATH",
        "CODEX_THREAD_ID", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED",
    ]

    public static func defaultEnvironment(program: String = "terminal", version: String = "0.1") -> [String: String] {
        var env = ProcessEnv.current
        for key in agentSessionVariables { env[key] = nil }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = program
        env["TERM_PROGRAM_VERSION"] = version
        if env["LANG"] == nil { env["LANG"] = "en_GB.UTF-8" }
        return env
    }

    public static var userShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { return String(cString: sh) }
        return ProcessEnv.current["SHELL"] ?? "/bin/zsh"
    }

    public init(executable: String, arguments: [String] = [], argv0: String? = nil,
                environment: [String: String]? = nil, workingDirectory: String? = nil,
                columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) throws {
        let env = environment ?? PTYProcess.defaultEnvironment()
        let path = try PTYProcess.resolve(executable, path: env["PATH"])
        let name = argv0 ?? executable.lastPathComponent
        var argv: [UnsafeMutablePointer<CChar>?] = ([name] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var master: Int32 = -1
        var child: pid_t = 0
        let rc = path.withCString { cpath in
            if let wd = workingDirectory {
                return wd.withCString { cwd in
                    cpty_spawn(cpath, argv, envp, cwd, UInt16(clamping: rows), UInt16(clamping: columns),
                               UInt16(clamping: pixelWidth), UInt16(clamping: pixelHeight), &master, &child)
                }
            }
            return cpty_spawn(cpath, argv, envp, nil, UInt16(clamping: rows), UInt16(clamping: columns),
                              UInt16(clamping: pixelWidth), UInt16(clamping: pixelHeight), &master, &child)
        }
        guard rc == 0 else { throw PTYError(message: "could not start \(executable)", code: errno) }
        fd = master
        pid = child
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    deinit {
        readSource?.cancel()
        exitSource?.cancel()
    }

    public func start(queue: DispatchQueue, onData: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) {
        let fd = self.fd
        let pid = self.pid
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        src.setEventHandler { [weak self] in
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    onData(Array(buffer[0..<n]))
                    if n < buffer.count { break }
                } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    break
                } else {
                    src.cancel()
                    self?.reap(onExit)
                    break
                }
            }
        }
        src.setCancelHandler { close(fd) }
        readSource = src
        src.resume()

        let ex = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        ex.setEventHandler { [weak self] in
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
                self?.readSource?.cancel()
                self?.reap(onExit)
            }
        }
        exitSource = ex
        ex.resume()
    }

    private func reap(_ onExit: @Sendable (Int32) -> Void) {
        lock.lock()
        if exited { lock.unlock(); return }
        exited = true
        lock.unlock()
        exitSource?.cancel()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        onExit(code)
    }

    public func write(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 { offset += n; continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 100)
                continue
            }
            return
        }
    }

    public func write(_ text: String) { write(Array(text.utf8)) }

    public func resize(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        _ = cpty_resize(fd, UInt16(clamping: rows), UInt16(clamping: columns),
                        UInt16(clamping: pixelWidth), UInt16(clamping: pixelHeight))
    }

    public func hangUp() {
        kill(-pid, SIGHUP)
    }

    public var foregroundDirectory: String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pid = cpty_foreground_pid(fd, self.pid)
        guard cpty_process_cwd(pid, &buf, Int32(buf.count)) == 0 else { return nil }
        return String(cString: buf)
    }

    public var foregroundCommand: String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pid = cpty_foreground_pid(fd, self.pid)
        guard cpty_process_path(pid, &buf, Int32(buf.count)) == 0 else { return nil }
        let path = String(cString: buf)
        if path.contains("/claude/versions/") { return "claude" }
        return path.lastPathComponent
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !exited
    }

    static func resolve(_ name: String, path: String?) throws -> String {
        if name.contains("/") { return name }
        for dir in (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        throw PTYError(message: "\(name) not found on PATH", code: ENOENT)
    }
}

enum ProcessEnv {
    static var current: [String: String] {
        var out: [String: String] = [:]
        var p = environ
        while let entry = p.pointee {
            let s = String(cString: entry)
            if let eq = s.firstIndex(of: "=") {
                out[String(s[..<eq])] = String(s[s.index(after: eq)...])
            }
            p += 1
        }
        return out
    }
}

extension String {
    var lastPathComponent: String {
        split(separator: "/").last.map(String.init) ?? self
    }
}

final class PThreadLock: @unchecked Sendable {
    private var m = pthread_mutex_t()
    init() { pthread_mutex_init(&m, nil) }
    deinit { pthread_mutex_destroy(&m) }
    func lock() { pthread_mutex_lock(&m) }
    func unlock() { pthread_mutex_unlock(&m) }
}
