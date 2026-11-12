import AppKit
import TermCore
import TermPTY

@MainActor
final class TerminalSession {
    let terminal: Terminal
    private(set) var process: PTYProcess?
    var onUpdate: (() -> Void)?
    var onExit: ((Int32) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    private let events = SessionEvents()

    var currentDirectory: String? {
        guard let s = terminal.workingDirectory, let url = URL(string: s), url.isFileURL else { return nil }
        return url.path
    }

    init(columns: Int, rows: Int) {
        terminal = Terminal(columns: columns, rows: rows, scrollback: 10_000)
        terminal.softwareName = "terminal"
        events.session = self
        terminal.delegate = events
    }

    func start(workingDirectory: String?, cellWidth: Int, cellHeight: Int) {
        let shell = PTYProcess.userShell
        let name = "-" + (shell.split(separator: "/").last.map(String.init) ?? "zsh")
        let cwd = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        do {
            let p = try PTYProcess(executable: shell, argv0: name, workingDirectory: cwd,
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
        terminal.feed(bytes)
        onUpdate?()
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        process?.write(bytes)
    }

    func resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        terminal.cellPixelWidth = cellWidth
        terminal.cellPixelHeight = cellHeight
        guard columns != terminal.columns || rows != terminal.rows else { return }
        terminal.resize(columns: columns, rows: rows)
        process?.resize(columns: columns, rows: rows, pixelWidth: columns * cellWidth, pixelHeight: rows * cellHeight)
        onUpdate?()
    }

    func close() {
        process?.hangUp()
    }

    fileprivate func title(_ t: String) { onTitle?(t) }
    fileprivate func bell() { onBell?() }
}

private final class SessionEvents: TerminalDelegate, @unchecked Sendable {
    weak var session: TerminalSession?

    func terminalBell(_ t: Terminal) {
        MainActor.assumeIsolated { session?.bell() }
    }

    func terminal(_ t: Terminal, titleChanged title: String) {
        MainActor.assumeIsolated { session?.title(title) }
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
