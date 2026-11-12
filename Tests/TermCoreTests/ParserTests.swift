import Testing
@testable import TermCore

final class Recorder: ParserHandler {
    var log: [String] = []
    var text = ""

    func flushText() {
        if !text.isEmpty { log.append("print(\(text))"); text = "" }
    }
    func print(_ scalar: Unicode.Scalar) { text.unicodeScalars.append(scalar) }
    func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) { text += String(decoding: bytes, as: UTF8.self) }
    func execute(_ byte: UInt8) { flushText(); log.append("exec(\(byte))") }
    func csiDispatch(_ p: CSIParams, _ i: Intermediates, final: UInt8) {
        flushText()
        let groups = (0..<p.count).map { k in p.group(k).map(String.init).joined(separator: ":") }.joined(separator: ";")
        let prefix = i.prefix == 0 ? "" : String(UnicodeScalar(i.prefix))
        let inter = (0..<i.count).map { String(UnicodeScalar(i[$0])) }.joined()
        log.append("csi(\(prefix)\(groups)\(inter)\(Character(UnicodeScalar(final))))")
    }
    func escDispatch(_ i: Intermediates, final: UInt8) {
        flushText()
        let inter = (0..<i.count).map { String(UnicodeScalar(i[$0])) }.joined()
        log.append("esc(\(inter)\(Character(UnicodeScalar(final))))")
    }
    func oscDispatch(_ data: [UInt8]) { flushText(); log.append("osc(\(String(decoding: data, as: UTF8.self)))") }
    func dcsHook(_ p: CSIParams, _ i: Intermediates, final: UInt8) {
        flushText()
        let inter = (0..<i.count).map { String(UnicodeScalar(i[$0])) }.joined()
        log.append("dcs(\(inter)\(Character(UnicodeScalar(final))))")
    }
    func dcsPut(_ byte: UInt8) { text.unicodeScalars.append(UnicodeScalar(byte)) }
    func dcsUnhook() { log.append("dcsdata(\(text))"); text = ""; log.append("unhook") }

    static func parse(_ chunks: [String]) -> [String] {
        let r = Recorder()
        let p = Parser()
        for c in chunks { p.feed(c, to: r) }
        r.flushText()
        return r.log
    }

    static func parse(_ s: String) -> [String] { parse([s]) }
}

@Suite struct ParserTests {
    @Test func plainTextAndControls() {
        #expect(Recorder.parse("ab\r\ncd") == ["print(ab)", "exec(13)", "exec(10)", "print(cd)"])
    }

    @Test func csiParams() {
        #expect(Recorder.parse("\u{1B}[1;2H") == ["csi(1;2H)"])
        #expect(Recorder.parse("\u{1B}[H") == ["csi(H)"])
        #expect(Recorder.parse("\u{1B}[;5H") == ["csi(-1;5H)"])
        #expect(Recorder.parse("\u{1B}[?1049h") == ["csi(?1049h)"])
        #expect(Recorder.parse("\u{1B}[2 q") == ["csi(2 q)"])
        #expect(Recorder.parse("\u{1B}[?2026$p") == ["csi(?2026$p)"])
    }

    @Test func colonSubParameters() {
        #expect(Recorder.parse("\u{1B}[4:3m") == ["csi(4:3m)"])
        #expect(Recorder.parse("\u{1B}[38:2::10:20:30m") == ["csi(38:2:-1:10:20:30m)"])
        #expect(Recorder.parse("\u{1B}[1;38:5:200m") == ["csi(1;38:5:200m)"])
    }

    @Test func paramAccessors() {
        let p = CSIParams([[5], [-1], [0], [38, 2, -1, 1, 2, 3]])
        #expect(p.get(0, 1) == 5)
        #expect(p.get(1, 1) == 1)
        #expect(p.get(2, 1) == 1)
        #expect(p.raw(2) == 0)
        #expect(Array(p.group(3)) == [38, 2, -1, 1, 2, 3])
        #expect(p.get(9, 7) == 7)
    }

    @Test func controlsInsideCSIStillExecute() {
        #expect(Recorder.parse("\u{1B}[1\n;2H") == ["exec(10)", "csi(1;2H)"])
    }

    @Test func oscTerminators() {
        #expect(Recorder.parse("\u{1B}]0;title\u{07}x") == ["osc(0;title)", "print(x)"])
        #expect(Recorder.parse("\u{1B}]2;t\u{1B}\\x") == ["osc(2;t)", "esc(\\)", "print(x)"])
        #expect(Recorder.parse("\u{1B}]0;caf\u{E9}\u{07}") == ["osc(0;caf\u{E9})"])
    }

    @Test func escSequences() {
        #expect(Recorder.parse("\u{1B}7\u{1B}(0\u{1B}#8") == ["esc(7)", "esc((0)", "esc(#8)"])
    }

    @Test func dcs() {
        #expect(Recorder.parse("\u{1B}P$qm\u{1B}\\") == ["dcs($q)", "dcsdata(m)", "unhook", "esc(\\)"])
    }

    @Test func cancelAbortsSequence() {
        #expect(Recorder.parse("\u{1B}[12\u{18}x") == ["print(x)"])
    }

    @Test func utf8AcrossChunks() {
        let bytes = Array("é日👍".utf8)
        let r = Recorder()
        let p = Parser()
        for b in bytes { p.feed([b], to: r) }
        r.flushText()
        #expect(r.log == ["print(é日👍)"])
    }

    @Test func invalidUTF8BecomesReplacement() {
        let r = Recorder()
        let p = Parser()
        p.feed([0x61, 0xFF, 0x62, 0xE2, 0x82, 0x63], to: r)
        r.flushText()
        #expect(r.log == ["print(a\u{FFFD}b\u{FFFD}c)"])
    }

    @Test func escInterruptsUTF8() {
        let r = Recorder()
        let p = Parser()
        p.feed([0xE2, 0x82, 0x1B, 0x5B, 0x41], to: r)
        r.flushText()
        #expect(r.log == ["print(\u{FFFD})", "csi(A)"])
    }

    @Test func sequenceSplitAcrossChunks() {
        #expect(Recorder.parse(["\u{1B}[3", "8;5;1", "2m"]) == ["csi(38;5;12m)"])
    }
}
