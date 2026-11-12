import Testing
@testable import TermCore

@Suite struct KittyKeyboardTests {
    let modes = TerminalModes()
    func k(_ key: Key, _ m: KittyModifiers = [], _ e: KeyEventType = .press, text: String? = nil,
           shifted: String? = nil, flags: Int = 1) -> String? {
        InputEncoder.kitty(key, modifiers: m, event: e, text: text, shiftedKey: shifted, flags: flags, modes: modes)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func disambiguateKeepsPlainTextAndLegacyKeys() {
        #expect(k(.character("a"), text: "a") == "a")
        #expect(k(.character("a"), [.shift], text: "A") == "A")
        #expect(k(.enter) == "\r")
        #expect(k(.tab) == "\t")
        #expect(k(.backspace) == "\u{7F}")
        #expect(k(.up) == "\u{1B}[A")
    }

    @Test func modifiedKeysBecomeUnambiguous() {
        #expect(k(.enter, [.shift]) == "\u{1B}[13;2u")
        #expect(k(.tab, [.control]) == "\u{1B}[9;5u")
        #expect(k(.character("i"), [.control]) == "\u{1B}[105;5u")
        #expect(k(.character("a"), [.alt]) == "\u{1B}[97;3u")
        #expect(k(.escape) == "\u{1B}[27u")
        #expect(k(.backspace, [.alt]) == "\u{1B}[127;3u")
        #expect(k(.character("A"), [.control, .shift]) == "\u{1B}[97;6u")
    }

    @Test func functionalKeysKeepLegacyFinals() {
        #expect(k(.up, [.control]) == "\u{1B}[1;5A")
        #expect(k(.delete) == "\u{1B}[3~")
        #expect(k(.pageDown, [.shift]) == "\u{1B}[6;2~")
        #expect(k(.function(1)) == "\u{1B}[P")
        #expect(k(.function(3)) == "\u{1B}[13~")
        #expect(k(.function(5), [.alt]) == "\u{1B}[15;3~")
    }

    @Test func eventTypes() {
        #expect(k(.escape, [], .release, flags: 3) == "\u{1B}[27;1:3u")
        #expect(k(.character("a"), [.control], .repeat, flags: 3) == "\u{1B}[97;5:2u")
        #expect(k(.character("a"), [], .release, text: "a", flags: 3) == nil)
        #expect(k(.enter, [], .release, flags: 3) == nil)
        #expect(k(.up, [], .release, flags: 3) == "\u{1B}[1;1:3A")
        #expect(k(.escape, [], .release) == nil)
        #expect(k(.escape, [], .repeat) == "\u{1B}[27u")
    }

    @Test func alternateKeys() {
        #expect(k(.character("2"), [.control, .shift], text: "@", shifted: "@", flags: 5) == "\u{1B}[50:64;6u")
    }

    @Test func allKeysAsCodesWithText() {
        #expect(k(.character("a"), text: "a", flags: 8) == "\u{1B}[97u")
        #expect(k(.enter, flags: 8) == "\u{1B}[13u")
        #expect(k(.character("a"), [.shift], text: "A", flags: 8 | 16) == "\u{1B}[97;2;65u")
    }
}
