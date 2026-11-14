import Testing
@testable import TermTranscript

@Suite struct InstructionsTests {
    @Test func notesHeadingCreatedWhenMissing() {
        #expect(Instructions.addingNote("Use tabs", to: "") == "## Notes\n\n- Use tabs\n")
        #expect(Instructions.addingNote("Use tabs", to: "# Title\nBody") == "# Title\nBody\n\n## Notes\n\n- Use tabs\n")
        #expect(Instructions.addingNote("Use tabs", to: "# Title\n\n") == "# Title\n\n## Notes\n\n- Use tabs\n")
    }

    @Test func noteGoesAtTheEndOfTheNotesSection() {
        let text = "# T\n\n## Notes\n\n- one\n\n## Later\n\nmore\n"
        #expect(Instructions.addingNote("two", to: text) == "# T\n\n## Notes\n\n- one\n- two\n\n## Later\n\nmore\n")
        let empty = "## Notes\n## Later\n"
        #expect(Instructions.addingNote("two", to: empty) == "## Notes\n\n- two\n\n## Later\n")
        let sub = "## Notes\n- a\n### Sub\n- b\n"
        #expect(Instructions.addingNote("c", to: sub) == "## Notes\n- a\n### Sub\n- b\n- c\n")
    }

    @Test func multiLineNotesAndLineEndings() {
        #expect(Instructions.addingNote("first\nsecond", to: "## Notes\n") == "## Notes\n\n- first\n  second\n")
        #expect(Instructions.addingNote("x", to: "# T\r\nBody\r\n") == "# T\r\nBody\r\n\r\n## Notes\r\n\r\n- x\r\n")
        #expect(Instructions.addingNote("  ", to: "keep") == "keep")
    }

    @Test func headingsInsideCodeBlocksAreIgnored() {
        let text = "```\n## Notes\n```\n"
        #expect(Instructions.addingNote("x", to: text) == "```\n## Notes\n```\n\n## Notes\n\n- x\n")
    }

    @Test func sharing() {
        #expect(Instructions.importsAgents("@AGENTS.md\n"))
        #expect(Instructions.importsAgents("# Hi\r\n  @./AGENTS.md\r\n"))
        #expect(!Instructions.importsAgents("See @AGENTS.md for more"))
        #expect(Instructions.sharedClaude() == "@AGENTS.md\n")
        #expect(Instructions.sharedClaude(keeping: "# Extra\n\nkeep\n") == "@AGENTS.md\n\n# Extra\n\nkeep\n")
        #expect(Instructions.sharedClaude(keeping: "a", ending: "\r\n") == "@AGENTS.md\r\n\r\na\r\n")
    }

    @Test func claudeProjectName() {
        #expect(Instructions.claudeProjectName("/Users/me/my.app") == "-Users-me-my-app")
    }
}
