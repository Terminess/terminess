#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#else
import Darwin
#endif
import Dispatch
import Foundation
import TermHost
import TermHostServer

setvbuf(stdout, nil, _IONBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "attach"
let rest = Array(arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("terminessd: \(message)\n".utf8))
    exit(1)
}


func serve() -> Never {
    setsid()
    signal(SIGHUP, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    if UnixSocket.connect(HostPaths.socket) != nil {
        FileHandle.standardError.write(Data("terminessd: already running on \(HostPaths.socket)\n".utf8))
        exit(ProcessInfo.processInfo.environment["INVOCATION_ID"] == nil ? 0 : 1)
    }
    let server = HostServer()
    let verbose = rest.contains("-v")
    server.log = { if verbose { print("terminessd: \($0)") } }
    do { try server.start() } catch { fail("\(error)") }
    dispatchMain()
}

func startViaSystemd() -> Bool {
    #if os(Linux)
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    guard FileManager.default.fileExists(atPath: home + "/.config/systemd/user/terminessd.service"),
          run(["systemctl", "--user", "is-enabled", "--quiet", "terminessd.service"], quiet: true) == 0 else { return false }
    return run(["systemctl", "--user", "start", "terminessd.service"], quiet: true) == 0
    #else
    return false
    #endif
}

func connectToService() -> Int32 {
    let path = HostPaths.socket
    guard UnixSocket.fits(path) else { fail("socket path is too long for the system: \(path)") }
    if let fd = UnixSocket.connect(path) { return fd }
    if startViaSystemd() {
        for _ in 0..<100 {
            if let fd = UnixSocket.connect(path) { return fd }
            usleep(50_000)
        }
        fail("terminessd.service did not start; see: journalctl --user -u terminessd")
    }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: me)
    p.arguments = ["serve"]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { fail("could not start the service: \(error)") }
    for _ in 0..<50 {
        usleep(50_000)
        if let fd = UnixSocket.connect(path) { return fd }
    }
    fail("the service did not start")
}

func request(_ m: Message) -> Message {
    let fd = connectToService()
    Connection.writeAll(fd, Wire.Frame.control(m).encoded())
    var decoder = Wire.Decoder()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { fail("the service closed the connection") }
        guard let frames = try? decoder.feed(Array(buf[0..<n])) else { fail("bad reply") }
        if let reply = frames.compactMap(\.message).first { close(fd); return reply }
    }
}


func terminalSize() -> (cols: Int, rows: Int) {
    var w = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 0 { return (Int(w.ws_col), Int(w.ws_row)) }
    return (100, 30)
}

var savedTermios = termios()
var rawMode = false

func enterRawMode() {
    guard isatty(STDIN_FILENO) != 0, tcgetattr(STDIN_FILENO, &savedTermios) == 0 else { return }
    var raw = savedTermios
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    rawMode = true
}

func leaveRawMode() {
    if rawMode { tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios); rawMode = false }
}


func attach(_ target: String?) -> Never {
    var id = target
    if id == nil {
        guard let newest = request(Message(op: "list")).sessions?.last else { fail("no sessions; start one with: terminessd new") }
        id = newest.id
    }
    let fd = connectToService()
    let queue = DispatchQueue(label: "attach")
    let conn = Connection(readFD: fd, queue: queue)
    let size = terminalSize()
    var detachArmed = false

    func finish(_ note: String?) -> Never {
        leaveRawMode()
        FileHandle.standardOutput.write(Data("\u{1B}[?1049l\u{1B}[?25h\u{1B}[0m\r\n".utf8))
        if let note { print(note) }
        exit(0)
    }

    conn.onFrame = { frame in
        switch frame.kind {
        case .output:
            Connection.writeAll(STDOUT_FILENO, frame.payload)
        case .control:
            guard let m = frame.message else { return }
            switch m.op {
            case "error": leaveRawMode(); fail(m.message ?? "error")
            case "exited": finish("[session \(m.id ?? "") ended]")
            default: break
            }
        case .input, .response:
            break
        }
    }
    conn.onClose = { finish("[lost the service]") }
    conn.start()
    conn.send(Message(op: "attach", id: id, cols: size.cols, rows: size.rows))
    enterRawMode()

    let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
    signal(SIGWINCH, SIG_IGN)
    winch.setEventHandler {
        let s = terminalSize()
        conn.send(Message(op: "resize", cols: s.cols, rows: s.rows))
    }
    winch.resume()

    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
    var buf = [UInt8](repeating: 0, count: 4096)
    input.setEventHandler {
        let n = read(STDIN_FILENO, &buf, buf.count)
        guard n > 0 else { finish(nil) }
        var out: [UInt8] = []
        for b in buf[0..<n] {
            if b == 0x1C {
                if detachArmed { out.append(b); detachArmed = false } else { detachArmed = true }
                continue
            }
            if detachArmed {
                detachArmed = false
                conn.send(Message(op: "detach"))
                finish("[detached from \(id!); reattach with: terminessd attach \(id!)]")
            }
            out.append(b)
        }
        if detachArmed {
            queue.asyncAfter(deadline: .now() + .milliseconds(350)) {
                if detachArmed {
                    conn.send(Message(op: "detach"))
                    finish("[detached from \(id!); reattach with: terminessd attach \(id!)]")
                }
            }
        }
        if !out.isEmpty { conn.send(Wire.Frame(.input, out)) }
    }
    input.resume()
    dispatchMain()
}


func stdioBridge() -> Never {
    signal(SIGPIPE, SIG_IGN)
    let fd = connectToService()
    let queue = DispatchQueue(label: "stdio")
    func pump(from: Int32, to: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: from, queue: queue)
        var buf = [UInt8](repeating: 0, count: 65536)
        src.setEventHandler {
            let n = read(from, &buf, buf.count)
            guard n > 0, Connection.writeAll(to, Array(buf[0..<n])) else { exit(0) }
        }
        src.resume()
        sources.append(src)
    }
    pump(from: STDIN_FILENO, to: fd)
    pump(from: fd, to: STDOUT_FILENO)
    dispatchMain()
}
nonisolated(unsafe) var sources: [DispatchSourceRead] = []


@discardableResult
func run(_ args: [String], quiet: Bool = false) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    if quiet { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice }
    do { try p.run() } catch { return 127 }
    p.waitUntilExit()
    return p.terminationStatus
}

func service(_ action: String?) -> Never {
    #if os(Linux)
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let unitDir = home + "/.config/systemd/user"
    let unit = unitDir + "/terminessd.service"
    let installed = home + "/.local/bin/terminessd"
    switch action {
    case "install":
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let fm = FileManager.default
        try? fm.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        if me != installed {
            let tmp = installed + ".new"
            try? fm.removeItem(atPath: tmp)
            do { try fm.copyItem(atPath: me, toPath: tmp) } catch { fail("could not copy to \(installed): \(error)") }
            chmod(tmp, 0o755)
            guard rename(tmp, installed) == 0 else { fail("could not install \(installed)") }
        }
        let path = ([home + "/.local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":").map(String.init).filter { $0 != home + "/.local/bin" }).joined(separator: ":")
        let text = """
        [Unit]
        Description=Terminess sessions (terminessd)
        After=network.target

        [Service]
        ExecStart=\(installed) serve
        Environment=PATH=\(path)
        Restart=on-failure
        RestartSec=2

        [Install]
        WantedBy=default.target

        """
        try? fm.createDirectory(atPath: unitDir, withIntermediateDirectories: true)
        do { try text.write(toFile: unit, atomically: true, encoding: .utf8) } catch { fail("could not write \(unit): \(error)") }
        run(["systemctl", "--user", "daemon-reload"])
        guard run(["systemctl", "--user", "enable", "terminessd.service"]) == 0,
              run(["systemctl", "--user", "restart", "terminessd.service"]) == 0 else { fail("systemctl could not start the service") }
        print("Installed \(installed) and started terminessd.service.")
        let user = ProcessInfo.processInfo.environment["USER"] ?? ""
        let linger = Process()
        linger.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        linger.arguments = ["loginctl", "show-user", user, "-p", "Linger", "--value"]
        let pipe = Pipe(); linger.standardOutput = pipe; linger.standardError = FileHandle.nullDevice
        try? linger.run(); linger.waitUntilExit()
        let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if value != "yes" {
            print("To keep it running after you log out and across reboots, run once: sudo loginctl enable-linger \(user)")
        }
        print("Clients connect with: ssh <host> \(installed) stdio")
        exit(0)
    case "uninstall":
        run(["systemctl", "--user", "disable", "--now", "terminessd.service"], quiet: true)
        try? FileManager.default.removeItem(atPath: unit)
        run(["systemctl", "--user", "daemon-reload"])
        print("Stopped and removed terminessd.service (left \(installed) in place).")
        exit(0)
    case "status", nil:
        exit(run(["systemctl", "--user", "status", "--no-pager", "terminessd.service"]))
    default:
        fail("usage: terminessd service install|uninstall|status")
    }
    #else
    print("On a Mac, Terminess starts terminessd itself; there is nothing to install.")
    exit(0)
    #endif
}


func pair() -> Never {
    let env = ProcessInfo.processInfo.environment
    let user = env["USER"] ?? NSUserName()
    var address = value(after: "--address", in: rest)
    if address == nil {
        if let conn = env["SSH_CONNECTION"]?.split(separator: " "), conn.count >= 3 { address = String(conn[2]) }
    }
    let host = ProcessInfo.processInfo.hostName
    guard let addr = address else { fail("pass --address with this machine's public address or name") }
    let name = value(after: "--name", in: rest) ?? host.split(separator: ".").first.map(String.init) ?? addr
    let port = env["SSH_CONNECTION"]?.split(separator: " ").last.map(String.init) ?? "22"
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let home = env["HOME"] ?? NSHomeDirectory()
    let path = me.hasPrefix(home + "/") ? "~" + me.dropFirst(home.count) : me
    let hostKey = (try? String(contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8))?
        .split(separator: " ").prefix(2).joined(separator: " ")
    var c = URLComponents()
    c.scheme = "terminess"
    c.host = "add"
    c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "address", value: addr),
                    URLQueryItem(name: "user", value: user), URLQueryItem(name: "port", value: port),
                    URLQueryItem(name: "path", value: path)]
        + (hostKey.map { [URLQueryItem(name: "hostkey", value: $0)] } ?? [])
    let link = c.url!.absoluteString.replacingOccurrences(of: "+", with: "%2B")
    print("""
    Open this link on your iPhone (or scan it as a QR code) to add \(name) to Terminess:

    \(link)

    Then add the iPhone's key (Terminess shows it under "This iPhone's key") to ~/.ssh/authorized_keys here.
    """)
    exit(0)
}


func selfPath() -> String {
    #if os(Linux)
    if let p = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") { return p }
    #endif
    return Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
}

func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch command {
case "serve":
    serve()

case "list", "ls":
    let sessions = request(Message(op: "list")).sessions ?? []
    if rest.contains("--json") {
        let data = (try? JSONEncoder().encode(sessions)) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else if sessions.isEmpty {
        print("No sessions.")
    } else {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        for s in sessions {
            let cwd = s.cwd.hasPrefix(home) ? "~" + s.cwd.dropFirst(home.count) : s.cwd
            let attached = s.clients > 0 ? "  (\(s.clients) attached)" : ""
            print("\(s.id)  \(s.name.padding(toLength: 10, withPad: " ", startingAt: 0))  \(s.command.padding(toLength: 8, withPad: " ", startingAt: 0))  \(cwd)\(attached)")
        }
    }

case "new":
    let dash = rest.firstIndex(of: "--")
    let opts = dash.map { Array(rest[..<$0]) } ?? rest
    let program = dash.map { Array(rest[($0 + 1)...]) } ?? []
    let size = terminalSize()
    let reply = request(Message(op: "create", host: "cli", name: value(after: "--name", in: opts),
                                cwd: value(after: "--cwd", in: opts) ?? FileManager.default.currentDirectoryPath,
                                command: program.first, args: Array(program.dropFirst()),
                                cols: size.cols, rows: size.rows))
    guard reply.op == "created", let id = reply.id else { fail(reply.message ?? "could not create the session") }
    if opts.contains("-d") { print(id) } else { attach(id) }

case "attach", "a":
    attach(rest.first)

case "kill":
    guard let target = rest.first else { fail("usage: terminessd kill ID|NAME") }
    let reply = request(Message(op: "kill", id: target))
    if reply.op == "error" { fail(reply.message ?? "error") }

case "stdio":
    stdioBridge()

case "service":
    service(rest.first)

case "pair":
    pair()

case "chat":
    chat(rest)

case "remind", "reminder", "reminders":
    let a = Array(rest)
    func value(_ flag: String) -> String? {
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    func show(_ r: ReminderInfo) -> String {
        let when = DateFormatter()
        when.locale = Locale(identifier: "en_GB"); when.dateFormat = "EEE d MMM HH:mm zzz"
        var line = "\(r.id)  \(when.string(from: Date(timeIntervalSince1970: r.due)))  \(r.fired == true ? "DUE  " : "")\(r.title)"
        if let p = r.actionPrompt { line += "\n        \(r.label): \(p)" }
        if let s = r.sessionId { line += "\n        session \(s)\(r.conversation.map { ", \(r.agent ?? "agent") conversation \($0)" } ?? "")" }
        return line
    }
    switch command == "reminders" ? "list" : (a.first ?? "list") {
    case "add":
        guard let at = value("--at"), let title = value("--title") else {
            fail("usage: terminessd remind add --at 22:00|+2h|2026-11-17T22:00 --title T [--body B] [--session ID] [--action-label L] [--action-prompt TEXT]")
        }
        guard let due = ReminderTime.parse(at) else { fail("can't read the time \"\(at)\"; use 22:00, +2h or 2026-11-17T22:00") }
        let session = value("--session") ?? ProcessInfo.processInfo.environment["TERMINESS_SESSION"]
        var m = Message(op: "remind-add")
        m.reminder = ReminderInfo(id: "", title: title, body: value("--body"), due: due.timeIntervalSince1970,
                                  actionLabel: value("--action-label"), actionPrompt: value("--action-prompt"),
                                  sessionId: session?.isEmpty == false ? session : nil, created: 0)
        let reply = request(m)
        guard reply.op == "reminder-added", let r = reply.reminder else { fail(reply.message ?? "couldn't set the reminder") }
        print("Reminder set:\n" + show(r))
    case "list":
        var m = Message(op: "reminders")
        m = request(m)
        let list = m.reminders ?? []
        if list.isEmpty { print("No reminders. Add one with: terminessd remind add --at 22:00 --title \"...\"") }
        list.forEach { print(show($0)) }
    case "cancel", "remove", "dismiss":
        guard a.count > 1 else { fail("usage: terminessd remind cancel ID") }
        let reply = request(Message(op: "remind-cancel", id: a[1]))
        if reply.op == "error" { fail(reply.message ?? "error") }
        print("Cancelled.")
    case "act", "proceed":
        guard a.count > 1 else { fail("usage: terminessd remind act ID") }
        let reply = request(Message(op: "reminder-act", id: a[1]))
        if reply.op == "error" { fail(reply.message ?? "error") }
        print("Done; session \(reply.id ?? "?").")
    default:
        fail("usage: terminessd remind add|list|cancel|act")
    }

case "handoff":
    handoffCommand(rest)

case "borrow":
    borrowCommand(rest)
case "copy-from-mac":
    copyFromMacCommand(rest)

case "schedule":
    var list = AgentSchedules.load()
    switch rest.first {
    case "add":
        var every = "1d", at: String?, cwd = FileManager.default.currentDirectoryPath, model = "claude-opus-5-5", auto = "edits"
        var task: [String] = []
        var j = 1, afterDashes = false
        let a = Array(rest)
        while j < a.count {
            if afterDashes { task.append(a[j]) }
            else {
                switch a[j] {
                case "--every": j += 1; if j < a.count { every = a[j] }
                case "--at": j += 1; if j < a.count { at = a[j] }
                case "--cwd": j += 1; if j < a.count { cwd = (a[j] as NSString).expandingTildeInPath }
                case "--model": j += 1; if j < a.count { model = a[j] }
                case "--auto": j += 1; if j < a.count { auto = a[j] }
                case "--": afterDashes = true
                default: task.append(a[j])
                }
            }
            j += 1
        }
        guard let minutes = AgentSchedules.minutes(every), !task.isEmpty, ["edits", "all"].contains(auto) else {
            fail("usage: terminessd schedule add [--every 30m|2h|1d|1w] [--at HH:MM] [--cwd DIR] [--model M] [--auto edits|all] -- TASK")
        }
        let id = String(UUID().uuidString.prefix(6)).lowercased()
        let next = AgentSchedules.next(after: Date(), every: minutes, at: at)
        list.append(AgentSchedule(id: id, task: task.joined(separator: " "), cwd: cwd, model: model, auto: auto,
                                  everyMinutes: minutes, at: at, next: next.timeIntervalSince1970))
        AgentSchedules.save(list)
        print("Scheduled \(id): every \(every)\(at.map { " at \($0)" } ?? ""), next \(next.formatted(date: .abbreviated, time: .shortened)).")
    case "remove":
        guard rest.count > 1 else { fail("usage: terminessd schedule remove ID") }
        let before = list.count
        list.removeAll { $0.id == rest[rest.index(after: rest.startIndex)] }
        AgentSchedules.save(list)
        print(list.count < before ? "Removed." : "No schedule with that id.")
    case "list", nil:
        if list.isEmpty { print("No schedules. Add one with: terminessd schedule add --every 1d --at 09:00 -- \"task\"") }
        for s in list {
            print("\(s.id)  every \(s.everyMinutes)m\(s.at.map { " at \($0)" } ?? "")  next \(Date(timeIntervalSince1970: s.next).formatted(date: .abbreviated, time: .shortened))  \(s.model)  \(s.cwd)\n        \(s.task)")
        }
    default:
        fail("usage: terminessd schedule add|list|remove")
    }

case "agent":
    agent(rest)

case "models":
    let reply = request(Message(op: "models"))
    if reply.code != 1 { print("Ollama isn't running here.") }
    else if (reply.args ?? []).isEmpty { print("No models installed in Ollama.") }
    else { (reply.args ?? []).forEach { print($0) } }

case "hook":
    let env = ProcessInfo.processInfo.environment
    guard let session = env["TERMINESS_SESSION"], !session.isEmpty,
          let fd = UnixSocket.connect(HostPaths.socket) else { exit(0) }
    let agent = rest.first ?? "claude"
    let input = rest.count > 1 ? rest.last!
        : String(decoding: FileHandle.standardInput.readDataToEndOfFile().prefix(256 * 1024), as: UTF8.self)
    let event = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
    guard event["hook_event_name"] as? String == "PermissionRequest" else {
        let m = Message(op: "hook", id: session, name: agent, message: input)
        _ = Connection.writeAll(fd, Wire.Frame.control(m).encoded())
        close(fd)
        exit(0)
    }
    _ = Connection.writeAll(fd, Wire.Frame.control(Message(op: "permission", id: session, name: agent, message: input)).encoded())
    var decoder = Wire.Decoder()
    var buf = [UInt8](repeating: 0, count: 16384)
    let deadline = Date().addingTimeInterval(570)
    var answer = ""
    wait: while Date() < deadline {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 1000) >= 0 else { break }
        guard p.revents != 0 else { continue }
        let n = read(fd, &buf, buf.count)
        guard n > 0, let frames = try? decoder.feed(Array(buf[0..<n])) else { break }
        for f in frames where f.message?.op == "decision" { answer = f.message?.message ?? ""; break wait }
    }
    close(fd)
    var decision: [String: Any]
    switch answer {
    case "allow": decision = ["behavior": "allow"]
    case "always":
        decision = ["behavior": "allow"]
        if let rules = event["permission_suggestions"] as? [Any], !rules.isEmpty { decision["updatedPermissions"] = rules }
    case "deny": decision = ["behavior": "deny", "message": "The user declined this in Terminess."]
    default: exit(0)
    }
    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    if let data = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(data) }
    exit(0)

case "mcp":
    MCPServer.run()

case "tools":
    toolsCommand(rest)

case "hooks":
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    var exe = selfPath()
    #if os(Linux)
    if FileManager.default.isExecutableFile(atPath: home + "/.local/bin/terminessd") { exe = home + "/.local/bin/terminessd" }
    #endif
    func describe(_ name: String, _ on: Bool, _ outdated: Bool, _ taken: Bool) -> String {
        "\(name): " + (on ? "on" : outdated ? "outdated (terminessd hooks install to refresh)"
            : taken ? "off (notify is already set to another program; left alone)" : "off (terminessd hooks install to turn on)")
    }
    switch rest.first {
    case "install":
        do { try ClaudeHooks.install(executable: exe) } catch { fail("\(error)") }
        print("Claude Code hooks installed in \(ClaudeHooks.settingsPath).")
        do {
            try CodexNotify.install(executable: exe)
            print("Codex notify set in \(CodexNotify.configPath).")
            try CodexHooks.install(executable: exe)
            print("Codex approval hook added to \(CodexHooks.hooksPath); trust it once with /hooks in Codex.")
        } catch { print("Codex: \(error)") }
        print("They only act inside Terminess sessions.")
    case "uninstall":
        do { try ClaudeHooks.uninstall(); try CodexNotify.uninstall(); try CodexHooks.uninstall() } catch { fail("\(error)") }
        print("Removed from \(ClaudeHooks.settingsPath) and \(CodexNotify.configPath).")
    case "status", nil:
        let c = ClaudeHooks.status(executable: exe), x = CodexNotify.status(executable: exe)
        print(describe("Claude Code", c == .on, c == .outdated, false))
        print(describe("Codex", x == .on, x == .outdated, x == .taken))
    default:
        fail("usage: terminessd hooks install|uninstall|status")
    }

case "-h", "--help", "help":
    print("""
    terminessd: keeps shells and agents alive for Terminess clients.

      terminessd serve                 run the service in the foreground (-v logs)
      terminessd list [--json]         list sessions
      terminessd new [-d] [--name N] [--cwd DIR] [-- command args...]
      terminessd attach [ID|NAME]      attach (newest by default); Ctrl-\\ detaches
      terminessd kill ID|NAME          end a session
      terminessd stdio                 bridge stdin/stdout to the service (for ssh)
      terminessd pair [--address A]    print a link that adds this machine to Terminess on iPhone
      terminessd service install       run it as a systemd user service (Linux)
      terminessd service uninstall|status
      terminessd models                list the Ollama models the iPhone can start a chat with
      terminessd chat MODEL [message]  chat with a local model (Ollama), saved for Chat view
      terminessd hooks install         let Claude Code and Codex tell Terminess what they're doing
      terminessd hooks uninstall|status
      terminessd agent [--model M] [task]  harness mode: Terminess runs the agent on your API key or a local model
      terminessd schedule add|list|remove  agent runs on a schedule (your API key)
      terminessd remind add --at 22:00 --title T [--action-prompt TEXT]
                                       a reminder: at that time a notification with a Proceed button
                                       that types TEXT into this session (or resumes its conversation)
      terminessd remind list|cancel ID|act ID
      terminessd handoff pull HOST SESSION | push SESSION HOST
                                       move a running agent conversation between machines (see handoff help)
      terminessd borrow "task"         hand a task to the Mac (its Chrome, its apps) and print the answer
      terminessd copy-from-mac PATH [TO]
                                       copy a file from the Mac to here (TO: a file or folder)
      terminessd mcp                   an MCP server giving agents Terminess tools (tabs, worktrees, notify, ask, remind, borrow)
      terminessd tools install|status  give Claude Code and Codex here the Terminess tools (the Mac app does this for you)
    """)

default:
    fail("unknown command \(command); try terminessd help")
}
