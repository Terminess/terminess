import AppKit
import TermTranscript
import TermCore
import TermPTY
import TermHost

@MainActor
final class TerminalSession {
    let terminal: Terminal
    private(set) var process: SessionBackend?
    static var appIsQuitting = false
    private var sizeAfterReplay: (columns: Int, rows: Int)?
    var onUpdate: (() -> Void)?
    var onExit: ((Int32) -> Void)?
    var onTitle: ((String) -> Void)?
    var onForeground: (() -> Void)?
    var onBell: (() -> Void)?
    var onNotify: ((String, String) -> Void)?
    var onCommandFinished: ((Double, Int) -> Void)?
    private var commandStarted: Date?
    private(set) var lastActivity = Date()
    private let events = SessionEvents()
    private var resumeIfGone: String?

    private func typeResume() {
        guard let command = resumeIfGone else { return }
        resumeIfGone = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.send(Array((command + "\r").utf8)) }
        }
    }

    var currentDirectory: String? {
        guard let s = terminal.workingDirectory else { return nil }
        if let url = URL(string: s), url.isFileURL { return url.path }
        guard s.hasPrefix("file://") else { return nil }
        let rest = s.dropFirst(7)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return String(rest[slash...]).removingPercentEncoding
    }

    init(columns: Int, rows: Int) {
        terminal = Terminal(columns: columns, rows: rows, scrollback: Settings.shared.scrollback)
        terminal.softwareName = "Terminess"
        terminal.supportsKittyKeyboard = true
        events.session = self
        terminal.delegate = events
    }

    func start(workingDirectory: String?, cellWidth: Int, cellHeight: Int, attach: String? = nil, persistent: Bool = true,
               resumeIfGone: String? = nil, machine: RemoteMachine? = nil, command: String? = nil) {
        self.resumeIfGone = resumeIfGone
        if let machine {
            startRemote(machine, attach: attach, cwd: workingDirectory, command: command)
            return
        }
        let cwd = workingDirectory ?? Transcript.home
        let hosted = persistent && Settings.shared.keepSessions && HostService.ensureRunning()
        if hosted {
            startHost(attach.map { .attach(id: $0) } ?? createTarget(cwd: cwd), cwd: cwd, cellWidth: cellWidth, cellHeight: cellHeight)
        } else {
            startLocal(cwd: cwd, cellWidth: cellWidth, cellHeight: cellHeight)
        }
        if !hosted || attach == nil { typeResume() }
    }

    private func createTarget(cwd: String) -> HostAttachment.Target {
        let shell = PTYProcess.userShell
        let env = ShellIntegration.environment(for: shell, base: PTYProcess.defaultEnvironment(program: "Terminess").merging(ModelRoles.load().environment()) { _, role in role })
        return .create(cwd: cwd, command: nil, args: [], env: env, name: nil)
    }

    private(set) var machine: RemoteMachine?

    private func startRemote(_ m: RemoteMachine, attach: String?, cwd: String?, command: String?) {
        machine = m
        let create = HostAttachment.Target.create(cwd: cwd, command: command.map { _ in "bash" },
                                                  args: command.map { ["-ic", "\($0); exec bash -i"] } ?? [],
                                                  env: nil, name: nil)
        startHost(attach.map { .attach(id: $0) } ?? create, cwd: cwd ?? "", cellWidth: 0, cellHeight: 0, remote: m)
    }

    private func startHost(_ target: HostAttachment.Target, cwd: String, cellWidth: Int, cellHeight: Int,
                           remote: RemoteMachine? = nil) {
        var link: SSHLink?
        let made: HostAttachment?
        if let remote {
            link = SSHLink.open(remote)
            made = link.map { HostAttachment(readFD: $0.fd, writeFD: $0.fd, target: target, cols: terminal.columns, rows: terminal.rows) }
        } else {
            made = HostAttachment(target: target, cols: terminal.columns, rows: terminal.rows)
        }
        guard let a = made else {
            if let remote {
                terminal.feed("\r\n\u{1B}[2m[Could not run ssh for \(remote.host)]\u{1B}[0m\r\n")
                onUpdate?()
                return
            }
            startLocal(cwd: cwd, cellWidth: cellWidth, cellHeight: cellHeight)
            return
        }
        a.resizesAfterReplay = true
        a.clientKind = "mac"
        a.deviceName = DeviceIdentity.name
        let backend = HostBackend(attachment: a, link: link, machineID: remote?.id)
        process = backend
        var attached = false
        terminal.onResponse = { [weak self] bytes in self?.process?.respond(bytes) }
        let ref = WeakRef(self)
        a.onAttached = { _, cols, rows in
            MainActor.assumeIsolated {
                attached = true
                ref.value?.resumeIfGone = nil
                guard let session = ref.value, cols > 0, rows > 0 else { return }
                let t = session.terminal
                if cols != t.columns || rows != t.rows {
                    session.sizeAfterReplay = (t.columns, t.rows)
                    t.resize(columns: cols, rows: rows)
                }
            }
        }
        a.onReplayed = {
            MainActor.assumeIsolated {
                guard let session = ref.value else { return }
                let t = session.terminal
                if let size = session.sizeAfterReplay {
                    session.sizeAfterReplay = nil
                    t.resize(columns: size.columns, rows: size.rows)
                    session.onUpdate?()
                }
                session.process?.resize(columns: t.columns, rows: t.rows,
                                        pixelWidth: t.columns * t.cellPixelWidth, pixelHeight: t.rows * t.cellPixelHeight)
                if let remote, case .create(_, nil, _, _, _) = target {
                    t.feed("\u{1B}[2mThis tab runs on \(remote.name). \u{21E7}\u{2318}M opens a terminal on this Mac.\u{1B}[0m\r\n")
                    session.onUpdate?()
                }
            }
        }
        a.onOutput = { bytes in MainActor.assumeIsolated { ref.value?.receive(bytes) } }
        a.onPermission = { p in MainActor.assumeIsolated { ref.value?.permissionChanged(p) } }
        a.onQuestion = { q in MainActor.assumeIsolated { ref.value?.questionChanged(q) } }
        a.onNote = { text in MainActor.assumeIsolated { ref.value?.onAgentNote?(text) } }
        a.onNotice = { text in MainActor.assumeIsolated { ref.value?.noticeChanged(text) } }
        a.resumeOf = resumeOf
        a.onAgentRequest = { id, tool, args in MainActor.assumeIsolated { ref.value?.onAgentRequest?(id, tool, args) } }
        a.onSize = { cols, rows in
            MainActor.assumeIsolated {
                guard let session = ref.value, session.sizeAfterReplay == nil else { return }
                let t = session.terminal
                guard cols != t.columns || rows != t.rows else { return }
                t.resize(columns: cols, rows: rows)
                session.onUpdate?()
            }
        }
        a.onForeground = { [weak backend] fg in
            MainActor.assumeIsolated {
                backend?.update(fg)
                ref.value?.onForeground?()
            }
        }
        a.onExit = { code in MainActor.assumeIsolated { ref.value?.onExit?(Int32(code)) } }
        a.onDisconnect = { message in
            MainActor.assumeIsolated {
                guard let session = ref.value else { return }
                if attached {
                    session.terminal.feed("\r\n\u{1B}[2m[\(message)]\u{1B}[0m\r\n")
                    session.onUpdate?()
                    return
                }
                if let remote {
                    let why = link?.lastError ?? ""
                    if case .attach = target, why.isEmpty, message.hasPrefix("no session") {
                        session.startHost(.create(cwd: cwd.isEmpty ? nil : cwd, command: nil, args: [], env: nil, name: nil),
                                          cwd: cwd, cellWidth: 0, cellHeight: 0, remote: remote)
                        session.typeResume()
                        return
                    }
                    session.terminal.feed("\r\n\u{1B}[2m[Could not reach \(remote.name): \(why.isEmpty ? message : why)]\u{1B}[0m\r\n")
                    session.onUpdate?()
                    return
                }
                if case .attach = target {
                    session.startHost(session.createTarget(cwd: cwd), cwd: cwd, cellWidth: cellWidth, cellHeight: cellHeight)
                    session.typeResume()
                } else {
                    session.startLocal(cwd: cwd, cellWidth: cellWidth, cellHeight: cellHeight)
                }
            }
        }
        a.start()
    }

    private func startLocal(cwd: String, cellWidth: Int, cellHeight: Int) {
        let shell = PTYProcess.userShell
        let name = "-" + (shell.split(separator: "/").last.map(String.init) ?? "zsh")
        do {
            let env = ShellIntegration.environment(for: shell, base: PTYProcess.defaultEnvironment(program: "Terminess").merging(ModelRoles.load().environment()) { _, role in role })
            let p = try PTYProcess(executable: shell, argv0: name, environment: env, workingDirectory: cwd,
                                   columns: terminal.columns, rows: terminal.rows,
                                   pixelWidth: terminal.columns * cellWidth, pixelHeight: terminal.rows * cellHeight)
            process = p
            terminal.onResponse = { [weak p] bytes in p?.write(bytes) }
            let ref = WeakRef(self)
            p.start(queue: .main, onData: { bytes in
                MainActor.assumeIsolated { ref.value?.receive(bytes) }
            }, onExit: { code in
                MainActor.assumeIsolated { ref.value?.onExit?(code) }
            })
        } catch {
            terminal.feed("\r\nCould not start \(shell): \(error)\r\n")
            onUpdate?()
        }
    }

    private func receive(_ bytes: [UInt8]) {
        lastActivity = Date()
        terminal.feed(bytes)
        onUpdate?()
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lastActivity = Date()
        process?.write(bytes)
    }

    func resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        terminal.cellPixelWidth = cellWidth
        terminal.cellPixelHeight = cellHeight
        if sizeAfterReplay != nil {
            sizeAfterReplay = (columns, rows)
            return
        }
        guard columns != terminal.columns || rows != terminal.rows else { return }
        terminal.resize(columns: columns, rows: rows)
        process?.resize(columns: columns, rows: rows, pixelWidth: columns * cellWidth, pixelHeight: rows * cellHeight)
        onUpdate?()
    }

    func close() {
        if TerminalSession.appIsQuitting { process?.detach() } else { process?.hangUp() }
    }

    fileprivate func title(_ t: String) { onTitle?(t) }
    fileprivate func bell() { onBell?() }
    fileprivate func notify(_ title: String, _ body: String) { onNotify?(title, body) }

    private(set) var permission: PermissionInfo?
    var onPermission: ((PermissionInfo?) -> Void)?
    fileprivate func permissionChanged(_ p: PermissionInfo?) { permission = p; onPermission?(p) }

    var resumeOf: String? {
        didSet { (process as? HostBackend)?.attachment.resumeOf = resumeOf }
    }
    private(set) var notice: String?
    var noticeDismissed = false
    var onNotice: ((String?) -> Void)?
    fileprivate func noticeChanged(_ text: String?) {
        if text != notice { noticeDismissed = false }
        notice = text
        onNotice?(text)
    }

    private(set) var question: QuestionInfo?
    var onQuestion: ((QuestionInfo?) -> Void)?
    var onAgentNote: ((String) -> Void)?
    var onAgentRequest: ((String, String, String) -> Void)?
    fileprivate func questionChanged(_ q: QuestionInfo?) { question = q; onQuestion?(q) }

    func answerQuestion(_ text: String) {
        guard let q = question, let id = process?.hostSessionID else { return }
        questionChanged(nil)
        control(Message(op: "answer", id: id, name: q.id, message: text))
    }

    func answerPermission(_ answer: String) {
        guard let p = permission, let id = process?.hostSessionID else { return }
        permissionChanged(nil)
        control(Message(op: "decide", id: id, name: p.id, message: answer))
    }

    private func control(_ m: Message) {
        if machine != nil, let hb = process as? HostBackend { hb.attachment.sendControl(m) } else { HostAttachment.send(m) }
    }

    fileprivate func mark(_ kind: Character, _ params: [String]) {
        switch kind {
        case "C": commandStarted = Date()
        case "D":
            if let start = commandStarted {
                commandStarted = nil
                onCommandFinished?(Date().timeIntervalSince(start), params.first.flatMap { Int($0) } ?? 0)
            }
        default: break
        }
    }
}

private final class SessionEvents: TerminalDelegate, @unchecked Sendable {
    weak var session: TerminalSession?

    func terminalBell(_ t: Terminal) {
        MainActor.assumeIsolated { session?.bell() }
    }

    func terminal(_ t: Terminal, titleChanged title: String) {
        MainActor.assumeIsolated { session?.title(title) }
    }

    func terminal(_ t: Terminal, notify title: String, body: String) {
        MainActor.assumeIsolated { session?.notify(title, body) }
    }

    func terminal(_ t: Terminal, semanticMark kind: Character, params: [String]) {
        MainActor.assumeIsolated { session?.mark(kind, params) }
    }

    func terminal(_ t: Terminal, setClipboard data: [UInt8]) {
        let text = String(decoding: data, as: UTF8.self)
        MainActor.assumeIsolated {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
