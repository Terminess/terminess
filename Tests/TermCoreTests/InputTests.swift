import Testing
@testable import TermCore

@Suite struct InputTests {
    func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
    let plain = TerminalModes()

    @Test func cursorKeys() {
        #expect(s(InputEncoder.encode(.up, modifiers: [], modes: plain)) == "\u{1B}[A")
        var app = plain
        app.applicationCursorKeys = true
        #expect(s(InputEncoder.encode(.up, modifiers: [], modes: app)) == "\u{1B}OA")
        #expect(s(InputEncoder.encode(.left, modifiers: [.control], modes: plain)) == "\u{1B}[1;5D")
        #expect(s(InputEncoder.encode(.right, modifiers: [.shift, .option], modes: plain)) == "\u{1B}[1;4C")
    }

    @Test func editingAndFunctionKeys() {
        #expect(s(InputEncoder.encode(.delete, modifiers: [], modes: plain)) == "\u{1B}[3~")
        #expect(s(InputEncoder.encode(.pageUp, modifiers: [.shift], modes: plain)) == "\u{1B}[5;2~")
        #expect(s(InputEncoder.encode(.function(1), modifiers: [], modes: plain)) == "\u{1B}OP")
        #expect(s(InputEncoder.encode(.function(5), modifiers: [], modes: plain)) == "\u{1B}[15~")
        #expect(s(InputEncoder.encode(.function(12), modifiers: [], modes: plain)) == "\u{1B}[24~")
    }

    @Test func controlAndMeta() {
        #expect(InputEncoder.encode(.character("c"), modifiers: [.control], modes: plain) == [3])
        #expect(InputEncoder.encode(.character("["), modifiers: [.control], modes: plain) == [0x1B])
        #expect(InputEncoder.encode(.space, modifiers: [.control], modes: plain) == [0])
        #expect(s(InputEncoder.encode(.character("b"), modifiers: [.option], modes: plain)) == "\u{1B}b")
        #expect(InputEncoder.encode(.backspace, modifiers: [], modes: plain) == [0x7F])
        #expect(s(InputEncoder.encode(.tab, modifiers: [.shift], modes: plain)) == "\u{1B}[Z")
        #expect(s(InputEncoder.encode(.enter, modifiers: [.shift], modes: plain)) == "\u{1B}\r")
    }

    @Test func bracketedPaste() {
        var m = plain
        #expect(s(InputEncoder.paste("a\nb", modes: m)) == "a\rb")
        m.bracketedPaste = true
        #expect(s(InputEncoder.paste("x\u{1B}[201~y", modes: m)) == "\u{1B}[200~xy\u{1B}[201~")
    }

    @Test func mouseSGR() {
        var m = plain
        #expect(InputEncoder.mouse(.left, .press, x: 0, y: 0, modifiers: [], modes: m).isEmpty)
        m.mouseTracking = .normal
        m.mouseEncoding = .sgr
        #expect(s(InputEncoder.mouse(.left, .press, x: 4, y: 2, modifiers: [], modes: m)) == "\u{1B}[<0;5;3M")
        #expect(s(InputEncoder.mouse(.left, .release, x: 4, y: 2, modifiers: [], modes: m)) == "\u{1B}[<0;5;3m")
        #expect(InputEncoder.mouse(.left, .drag, x: 4, y: 2, modifiers: [], modes: m).isEmpty)
        m.mouseTracking = .any
        #expect(s(InputEncoder.mouse(.none, .move, x: 1, y: 1, modifiers: [], modes: m)) == "\u{1B}[<35;2;2M")
        #expect(s(InputEncoder.mouse(.wheelUp, .press, x: 0, y: 0, modifiers: [.control], modes: m)) == "\u{1B}[<80;1;1M")
    }

    @Test func mouseLegacy() {
        var m = plain
        m.mouseTracking = .normal
        #expect(InputEncoder.mouse(.left, .press, x: 0, y: 0, modifiers: [], modes: m) == [0x1B, 0x5B, 0x4D, 32, 33, 33])
        #expect(InputEncoder.mouse(.left, .release, x: 0, y: 0, modifiers: [], modes: m) == [0x1B, 0x5B, 0x4D, 35, 33, 33])
    }

    @Test func focusEvents() {
        var m = plain
        #expect(InputEncoder.focus(true, modes: m).isEmpty)
        m.focusEvents = true
        #expect(s(InputEncoder.focus(false, modes: m)) == "\u{1B}[O")
    }
}
