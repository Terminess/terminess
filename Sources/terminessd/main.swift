#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Dispatch
import Foundation
import TermHost

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
        exit(0)
    }
    let server = HostServer()
    let verbose = rest.contains("-v")
    server.log = { if verbose { print("terminessd: \($0)") } }
    do { try server.start() } catch { fail("\(error)") }
    dispatchMain()
}

func connectToService() -> Int32 {
    let path = HostPaths.socket
    guard UnixSocket.fits(path) else { fail("socket path is too long for the system: \(path)") }
    if let fd = UnixSocket.connect(path) { return fd }
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
        case .input:
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
    let reply = request(Message(op: "create", name: value(after: "--name", in: opts),
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

case "-h", "--help", "help":
    print("""
    terminessd: keeps shells and agents alive for Terminess clients.

      terminessd serve                 run the service in the foreground (-v logs)
      terminessd list [--json]         list sessions
      terminessd new [-d] [--name N] [--cwd DIR] [-- command args...]
      terminessd attach [ID|NAME]      attach (newest by default); Ctrl-\\ detaches
      terminessd kill ID|NAME          end a session
      terminessd stdio                 bridge stdin/stdout to the service (for ssh)
      terminessd service install       run it as a systemd user service (Linux)
      terminessd service uninstall|status
    """)

default:
    fail("unknown command \(command); try terminessd help")
}
