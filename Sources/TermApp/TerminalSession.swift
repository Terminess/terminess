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
               resumeIfGone: String? = nil) {
        self.resumeIfGone = resumeIfGone
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
        let env = ShellIntegration.environment(for: shell, base: PTYProcess.defaultEnvironment(program: "Terminess"))
        return .create(cwd: cwd, command: nil, args: [], env: env, name: nil)
    }

    private func startHost(_ target: HostAttachment.Target, cwd: String, cellWidth: Int, cellHeight: Int) {
        guard let a = HostAttachment(target: target, cols: terminal.columns, rows: terminal.rows) else {
            startLocal(cwd: cwd, cellWidth: cellWidth, cellHeight: cellHeight)
            return
        }
        a.resizesAfterReplay = true
        a.clientKind = "mac"
        let backend = HostBackend(attachment: a)
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
            }
        }
        a.onOutput = { bytes in MainActor.assumeIsolated { ref.value?.receive(bytes) } }
        a.onPermission = { p in MainActor.assumeIsolated { ref.value?.permissionChanged(p) } }
        a.onQuestion = { q in MainActor.assumeIsolated { ref.value?.questionChanged(q) } }
        a.onNote = { text in MainActor.assumeIsolated { ref.value?.onAgentNote?(text) } }
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
        a.onForeground = { [weak backend] fg in MainActor.assumeIsolated { backend?.update(fg) } }
        a.onExit = { code in MainActor.assumeIsolated { ref.value?.onExit?(Int32(code)) } }
        a.onDisconnect = { message in
            MainActor.assumeIsolated {
                guard let session = ref.value else { return }
                if attached {
                    session.terminal.feed("\r\n\u{1B}[2m[\(message)]\u{1B}[0m\r\n")
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
            let env = ShellIntegration.environment(for: shell, base: PTYProcess.defaultEnvironment(program: "Terminess"))
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

    private(set) var question: QuestionInfo?
    var onQuestion: ((QuestionInfo?) -> Void)?
    var onAgentNote: ((String) -> Void)?
    var onAgentRequest: ((String, String, String) -> Void)?
    fileprivate func questionChanged(_ q: QuestionInfo?) { question = q; onQuestion?(q) }

    func answerQuestion(_ text: String) {
        guard let q = question, let id = process?.hostSessionID else { return }
        questionChanged(nil)
        HostAttachment.send(Message(op: "answer", id: id, name: q.id, message: text))
    }

    func answerPermission(_ answer: String) {
        guard let p = permission, let id = process?.hostSessionID else { return }
        permissionChanged(nil)
        HostAttachment.send(Message(op: "decide", id: id, name: p.id, message: answer))
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
