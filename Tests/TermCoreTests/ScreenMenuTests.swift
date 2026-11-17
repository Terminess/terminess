import Testing
@testable import TermCore

@Suite struct ScreenMenuTests {
    let trust = [
        "",
        "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
        " Accessing workspace:",
        "",
        " /home/ubuntu",
        "",
        " Quick safety check: Is this a project you created or one you trust? (Like your",
        " own code, a well-known open source project, or work from your team).",
        "",
        " Claude Code'll be able to read, edit, and execute files here.",
        "",
        " Security guide",
        "",
        " \u{276F} No, exit",
        "   Yes, I trust this folder",
        "",
        " Enter to confirm \u{00B7} Esc to cancel",
        "",
    ]

    @Test func trustCheck() throws {
        let m = try #require(ScreenMenu.find(lines: trust))
        #expect(m.options == ["No, exit", "Yes, I trust this folder"])
        #expect(m.selected == 0)
        #expect(m.text.first == "Accessing workspace:")
        #expect(m.text.contains { $0.hasPrefix("Quick safety check: Is this a project you created or one you trust? (Like your own code") })
        #expect(m.keys(toChoose: 1) == [.down, .enter])
        #expect(m.keys(toChoose: 0) == [.enter])
    }

    @Test func numberedMenuInABoxWithDescriptions() throws {
        let lines = [
            "\u{256D}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256E}",
            "\u{2502} Bash command                                \u{2502}",
            "\u{2502}   rm -rf build                              \u{2502}",
            "\u{2502} Do you want to proceed?                     \u{2502}",
            "\u{2502}   1. Yes                                    \u{2502}",
            "\u{2502}      Runs it once                           \u{2502}",
            "\u{2502} \u{276F} 2. Yes, and don't ask again              \u{2502}",
            "\u{2502}   3. No                                     \u{2502}",
            "\u{2570}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256F}",
            "  Enter to select \u{00B7} Esc to cancel",
        ]
        let m = try #require(ScreenMenu.find(lines: lines))
        #expect(m.options == ["Yes", "Yes, and don't ask again", "No"])
        #expect(m.selected == 1)
        #expect(m.text == ["Bash command rm -rf build Do you want to proceed?"])
        #expect(m.keys(toChoose: 0) == [.up, .enter])
    }

    @Test func nothingWithoutAFooterOrACursor() {
        #expect(ScreenMenu.find(lines: Array(trust.dropLast(2))) == nil)
        #expect(ScreenMenu.find(lines: trust.map { $0.replacingOccurrences(of: "\u{276F}", with: " ") }) == nil)
        #expect(ScreenMenu.find(lines: ["\u{276F} hello", "Enter to confirm"]) == nil)
    }

    @Test func readsTheTerminalScreen() throws {
        let t = Terminal(columns: 60, rows: 12, scrollback: 10)
        t.feed("Quick safety check: trust this folder?\r\n\r\n\u{276F} No, exit\r\n  Yes, I trust this folder\r\n\r\nEnter to confirm \u{00B7} Esc to cancel")
        let m = try #require(ScreenMenu.find(in: t))
        #expect(m.options == ["No, exit", "Yes, I trust this folder"])
        #expect(m.text == ["Quick safety check: trust this folder?"])
    }

    @Test func joinsAWordWrappedAtTheEdge() throws {
        let t = Terminal(columns: 20, rows: 12, scrollback: 10)
        t.feed("Claude can read and executable files here.\r\n\r\n\u{276F} No, exit\r\n  Yes, I trust it\r\n\r\nEnter to confirm")
        let m = try #require(ScreenMenu.find(in: t))
        #expect(m.text == ["Claude can read and executable files here."])
    }

    @Test func keepsTheSpaceBetweenShortLines() throws {
        let m = try #require(ScreenMenu.find(lines: ["Line one", "line two", "", "\u{276F} A", "  B", "", "Enter to confirm"], width: 40))
        #expect(m.text == ["Line one line two"])
    }
}
