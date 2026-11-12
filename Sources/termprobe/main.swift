import Darwin
import Dispatch
import Foundation
import TermCore
import TermPTY

struct Options {
    var columns = 100
    var rows = 30
    var inputs: [(Double, [UInt8])] = []
    var timeout = 5.0
    var trace = false
    var raw: String?
    var scrollback = false
    var showCursor = false
    var command: [String] = []
}

func unescape(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = Array(s.utf8).makeIterator()
    while let b = it.next() {
        guard b == UInt8(ascii: "\\"), let n = it.next() else { out.append(b); continue }
        switch n {
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "e"): out.append(0x1B)
        case UInt8(ascii: "x"):
            if let a = it.next(), let c = it.next(), let v = UInt8(String(bytes: [a, c], encoding: .ascii) ?? "", radix: 16) {
                out.append(v)
            }
        default: out.append(n)
        }
    }
    return out
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--":
            o.command = args
            args = []
        case "--size":
            let parts = (args.isEmpty ? "" : args.removeFirst()).split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { o.columns = parts[0]; o.rows = parts[1] }
        case "--input":
            let v = args.isEmpty ? "" : args.removeFirst()
            if let colon = v.firstIndex(of: ":"), let d = Double(v[..<colon]) {
                o.inputs.append((d, unescape(String(v[v.index(after: colon)...]))))
            }
        case "--timeout": o.timeout = Double(args.isEmpty ? "" : args.removeFirst()) ?? o.timeout
        case "--trace": o.trace = true
        case "--raw": o.raw = args.isEmpty ? nil : args.removeFirst()
        case "--scrollback": o.scrollback = true
        case "--cursor": o.showCursor = true
        default:
            o.command = [a] + args
            args = []
        }
    }
    return o
}

final class Tracer: ParserHandler {
    var counts: [String: Int] = [:]
    func bump(_ k: String) { counts[k, default: 0] += 1 }

    func print(_ scalar: Unicode.Scalar) {
        if scalar.value >= 0x80 { bump(CharWidth.of(scalar) == 2 ? "text: wide character" : "text: non-ASCII") }
    }
    func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {}
    func execute(_ byte: UInt8) {
        let names: [UInt8: String] = [7: "BEL", 8: "BS", 9: "HT", 10: "LF", 13: "CR", 14: "SO", 15: "SI"]
        bump("C0 " + (names[byte] ?? String(format: "0x%02X", byte)))
    }
    func csiDispatch(_ p: CSIParams, _ i: Intermediates, final: UInt8) {
        let prefix = i.prefix == 0 ? "" : String(UnicodeScalar(i.prefix)) + " "
        let inter = i.count > 0 ? String(UnicodeScalar(i[0])) : ""
        let f = String(UnicodeScalar(final))
        switch f {
        case "m" where prefix.isEmpty && inter.isEmpty:
            var kinds: [String] = []
            var k = 0
            while k < max(p.count, 1) {
                let g = p.group(k)
                let code = max(g.first ?? 0, 0)
                if (code == 38 || code == 48 || code == 58) {
                    let sub = g.count > 1 ? g[g.startIndex + 1] : p.raw(k + 1, -1)
                    kinds.append("\(code):\(sub == 2 ? "rgb" : sub == 5 ? "256" : "?")\(g.count > 1 ? " (colon)" : "")")
                    k += g.count > 1 ? 1 : (sub == 2 ? 5 : 3)
                    continue
                }
                if code == 4 && g.count > 1 { kinds.append("4:\(g[g.startIndex + 1]) (underline style)") }
                else { kinds.append(String(code)) }
                k += 1
            }
            for kind in Set(kinds) { bump("SGR \(kind)") }
        case "h", "l" where !prefix.isEmpty:
            for k in 0..<p.count { bump("CSI \(prefix)\(p.raw(k, 0)) \(f)") }
        case "h", "l":
            for k in 0..<p.count { bump("CSI \(p.raw(k, 0)) \(f)") }
        default:
            let first = p.count > 0 && ["n", "c", "t", "q", "u", "p"].contains(f) ? "\(p.raw(0, 0)) " : ""
            bump("CSI \(prefix)\(first)\(inter)\(f)")
        }
    }
    func escDispatch(_ i: Intermediates, final: UInt8) {
        let inter = i.count > 0 ? String(UnicodeScalar(i[0])) : ""
        bump("ESC \(inter)\(String(UnicodeScalar(final)))")
    }
    func oscDispatch(_ data: [UInt8]) {
        let s = String(decoding: data, as: UTF8.self)
        let code = s.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "?"
        bump("OSC \(code)\(s.hasSuffix(";?") ? " (query)" : "")")
    }
    func dcsHook(_ p: CSIParams, _ i: Intermediates, final: UInt8) {
        let inter = i.count > 0 ? String(UnicodeScalar(i[0])) : ""
        bump("DCS \(inter)\(String(UnicodeScalar(final)))")
    }
    func dcsPut(_ byte: UInt8) {}
    func dcsUnhook() {}
}

if let i = CommandLine.arguments.firstIndex(of: "--bench"), i + 1 < CommandLine.arguments.count {
    let data = FileManager.default.contents(atPath: CommandLine.arguments[i + 1]) ?? Data()
    let bytes = [UInt8](data)
    let t = Terminal(columns: 120, rows: 40, scrollback: 10_000)
    let start = DispatchTime.now()
    var offset = 0
    while offset < bytes.count {
        let end = min(offset + 65_536, bytes.count)
        bytes[offset..<end].withUnsafeBufferPointer { t.feed($0) }
        offset = end
    }
    let secs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    let mb = Double(bytes.count) / 1_048_576
    Swift.print(String(format: "%.1f MB in %.3f s = %.0f MB/s", mb, secs, mb / secs))
    exit(0)
}

let opts = parseOptions()
guard !opts.command.isEmpty else {
    FileHandle.standardError.write("usage: termprobe [options] -- program [args...]\n".data(using: .utf8)!)
    exit(2)
}

final class ProbeState: @unchecked Sendable {
    let terminal: Terminal
    let tracer = Tracer()
    let traceParser = Parser()
    var rawBytes: [UInt8] = []
    var exitCode: Int32?
    init(_ t: Terminal) { terminal = t }
}

let state = ProbeState(Terminal(columns: opts.columns, rows: opts.rows))
let queue = DispatchQueue(label: "termprobe")
let done = DispatchSemaphore(value: 0)
let trace = opts.trace
let keepRaw = opts.raw != nil

let process: PTYProcess
do {
    process = try PTYProcess(executable: opts.command[0], arguments: Array(opts.command.dropFirst()),
                             columns: opts.columns, rows: opts.rows)
} catch {
    FileHandle.standardError.write("termprobe: \(error)\n".data(using: .utf8)!)
    exit(1)
}

state.terminal.onResponse = { bytes in process.write(bytes) }
process.start(queue: queue, onData: { bytes in
    state.terminal.feed(bytes)
    if trace { state.traceParser.feed(bytes, to: state.tracer) }
    if keepRaw { state.rawBytes.append(contentsOf: bytes) }
}, onExit: { code in
    state.exitCode = code
    done.signal()
})

for (delay, bytes) in opts.inputs {
    queue.asyncAfter(deadline: .now() + delay) { process.write(bytes) }
}

let timedOut = done.wait(timeout: .now() + opts.timeout) == .timedOut

queue.sync {
    let terminal = state.terminal
    if let raw = opts.raw { FileManager.default.createFile(atPath: raw, contents: Data(state.rawBytes)) }
    let rule = String(repeating: "-", count: opts.columns)
    Swift.print(rule)
    Swift.print(opts.scrollback ? terminal.allText() : terminal.screenText())
    Swift.print(rule)
    Swift.print("exit: \(timedOut ? "still running at timeout (hung up)" : state.exitCode.map(String.init) ?? "?")  size: \(terminal.columns)x\(terminal.rows)  alternate screen: \(terminal.isAlternate)")
    if opts.showCursor {
        let m = terminal.modes
        Swift.print("cursor: row \(terminal.cursor.y + 1) col \(terminal.cursor.x + 1) visible=\(m.cursorVisible)  bracketedPaste=\(m.bracketedPaste) mouse=\(m.mouseTracking) appCursor=\(m.applicationCursorKeys)")
    }
    if opts.trace {
        Swift.print("\nescape sequences sent (count, kind):")
        for (k, v) in state.tracer.counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            Swift.print(String(format: "%7d  %@", v, k))
        }
    }
}

if timedOut {
    process.hangUp()
    _ = done.wait(timeout: .now() + 1)
}
