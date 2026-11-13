import SwiftUI
import TermCore
import TermHost
import UIKit

@MainActor
final class ScreenModel: ObservableObject {
    let terminal: Terminal
    private(set) var attachment: HostAttachment?
    @Published private(set) var text = AttributedString()
    @Published private(set) var status: String?
    @Published private(set) var ended = false
    @Published private(set) var sessionID: String?
    @Published private(set) var title = ""
    @Published private(set) var command = ""
    @Published private(set) var connected = false
    private let events = ScreenEvents()
    private var pendingInput: String?
    private var sizeAfterReplay: (Int, Int)?
    private var viewGrid: (cols: Int, rows: Int)?
    private var renderPending = false
    let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    init() {
        terminal = Terminal(columns: 50, rows: 30, scrollback: 2000)
        terminal.softwareName = "Terminess"
        terminal.setColorScheme(.dark)
        events.model = self
        terminal.delegate = events
    }

    var isAgent: Bool { command == "claude" || command == "codex" }
    var busy: Bool {
        guard let first = title.unicodeScalars.first else { return false }
        return (0x25D0...0x25D3).contains(first.value) || (0x2800...0x28FF).contains(first.value)
    }
    var topic: String {
        String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }

    fileprivate func titleChanged(_ t: String) { title = t }

    var background: SwiftUI.Color { SwiftUI.Color(rgb: terminal.palette.background) }

    func grid(for size: CGSize) -> (cols: Int, rows: Int) {
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        let h = font.lineHeight
        return (max(20, Int((size.width - 12) / w)), max(8, Int((size.height - 8) / h)))
    }

    func start(_ attachment: HostAttachment, cols: Int, rows: Int, input: String? = nil) {
        self.attachment = attachment
        pendingInput = input
        status = nil
        terminal.fullReset()
        terminal.setColorScheme(.dark)
        let size = viewGrid ?? (cols, rows)
        terminal.resize(columns: size.cols, rows: size.rows)
        attachment.resizesAfterReplay = true
        terminal.onResponse = { [weak attachment] bytes in attachment?.write(bytes) }
        attachment.onAttached = { [weak self] id, c, r in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sessionID = id
                self.connected = true
                guard c > 0, r > 0 else { return }
                if c != self.terminal.columns || r != self.terminal.rows {
                    self.sizeAfterReplay = (self.terminal.columns, self.terminal.rows)
                    self.terminal.resize(columns: c, rows: r)
                }
            }
        }
        attachment.onReplayed = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let s = self.sizeAfterReplay {
                    self.sizeAfterReplay = nil
                    self.terminal.resize(columns: s.0, rows: s.1)
                }
                self.attachment?.resize(cols: self.terminal.columns, rows: self.terminal.rows)
                self.scheduleRender()
                if let input = self.pendingInput {
                    self.pendingInput = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.send(Array((input + "\r").utf8)) }
                }
            }
        }
        attachment.onOutput = { [weak self] bytes in
            MainActor.assumeIsolated {
                self?.terminal.feed(bytes)
                self?.scheduleRender()
            }
        }
        attachment.onForeground = { [weak self] fg in MainActor.assumeIsolated { self?.command = fg.command } }
        attachment.onExit = { [weak self] _ in MainActor.assumeIsolated { self?.ended = true; self?.connected = false; self?.status = "Session ended" } }
        attachment.onDisconnect = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.connected = false
                self?.status = "Reconnecting…"
            }
        }
        attachment.start()
    }

    func resize(cols: Int, rows: Int) {
        viewGrid = (cols, rows)
        guard cols != terminal.columns || rows != terminal.rows else { return }
        if sizeAfterReplay != nil { sizeAfterReplay = (cols, rows); return }
        terminal.resize(columns: cols, rows: rows)
        attachment?.resize(cols: cols, rows: rows)
        scheduleRender()
    }

    func send(_ bytes: [UInt8]) { attachment?.write(bytes) }

    func sendLine(_ text: String) {
        if !text.isEmpty { send(InputEncoder.paste(text, modes: terminal.modes)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.send([0x0D]) }
    }

    func key(_ k: Key) { send(InputEncoder.encode(k, modifiers: [], modes: terminal.modes)) }

    func detach() {
        attachment?.detach()
        attachment = nil
        connected = false
    }

    private func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.renderPending = false
            self.render()
        }
    }

    private func render() {
        let t = terminal
        let palette = t.palette
        var out = AttributedString()
        let rows = t.screen.rows
        let cursor = t.cursor
        for (y, row) in rows.enumerated() {
            let count = row.cells.count
            func isCursor(_ x: Int) -> Bool { t.modes.cursorVisible && y == cursor.y && x == cursor.x }
            func glyph(_ x: Int) -> String {
                let c = row.cells[x]
                if c.isWideTail { return "" }
                if c.isEmpty { return " " }
                return row.clusters[x] ?? UnicodeScalar(c.scalar).map { String(Character($0)) } ?? " "
            }
            var x = 0
            while x < count {
                if isCursor(x) {
                    out += styled(glyph(x), row.cells[x].attrs, palette, cursor: true)
                    x += 1
                    continue
                }
                let a = row.cells[x].attrs
                var run = ""
                while x < count, row.cells[x].attrs == a, !isCursor(x) {
                    run += glyph(x)
                    x += 1
                }
                out += styled(run, a, palette, cursor: false)
            }
            if y < rows.count - 1 { out += AttributedString("\n") }
        }
        text = out
    }

    private func styled(_ s: String, _ a: Attributes, _ p: Palette, cursor: Bool) -> AttributedString {
        var fg = p.resolve(a.fg, isForeground: true)
        var bg = p.resolve(a.bg, isForeground: false)
        if a.flags.contains(.inverse) != cursor { swap(&fg, &bg) }
        var r = AttributedString(s)
        r.foregroundColor = SwiftUI.Color(rgb: fg)
        if bg != p.background || cursor || a.flags.contains(.inverse) { r.backgroundColor = SwiftUI.Color(rgb: bg) }
        if a.flags.contains(.bold) { r.font = .system(size: 12, weight: .bold, design: .monospaced) }
        if a.flags.contains(.faint) { r.foregroundColor = SwiftUI.Color(rgb: fg).opacity(0.6) }
        if a.underline != .none { r.underlineStyle = .single }
        return r
    }
}

private final class ScreenEvents: TerminalDelegate {
    weak var model: ScreenModel?
    func terminal(_ t: Terminal, titleChanged title: String) {
        MainActor.assumeIsolated { model?.titleChanged(title) }
    }
}

extension SwiftUI.Color {
    init(rgb: RGB) { self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255) }
}
