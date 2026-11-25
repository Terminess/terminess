import Foundation
import Testing
@testable import TermTranscript

@Suite struct TranscriptTests {
    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: "jsonl"))
        return try Data(contentsOf: url)
    }

    @Test func claudeConversation() throws {
        let (items, survey) = Transcript.parse(data: try fixture("claude"), agent: "claude")
        #expect(items.map(\.kind.line) == [
            "user: Fix the build",
            "thinking: Check the compiler output first.",
            "assistant: Looking at the build.",
            "tool: Bash | swift build | Build complete",
            "user: Also check the tests",
            "user: [Image #1] this one",
            "tool: WebSearch | swift testing | 3 results",
            "user: Spoken message",
            "assistant: Cited answer",
        ])
        #expect(survey.version == "2.1.325")
    }

    @Test func claudePastedMessageIsYours() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"\n\n<pasted_content id=\"8a0e\">\nThe sidebar keeps shrinking\n</pasted_content id=\"8a0e\">"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"[Image: original 2080x1286, displayed at 2000x1237. Multiply coordinates by 1.04 to map to original image.]"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
        ]
        let items = Transcript.parse(data: Data(lines.joined(separator: "\n").utf8), agent: "claude").items
        #expect(items.map(\.kind.line) == ["user: The sidebar keeps shrinking", "assistant: Looking."])
    }

    @Test func claudeCompactSummaryIsAStepNotYourMessage() throws {
        let lines = [
            #"{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation.\nSummary: ..."}}"#,
            #"{"type":"user","message":{"role":"user","content":"installed, looks fine"}}"#,
        ]
        let items = Transcript.parse(data: Data(lines.joined(separator: "\n").utf8), agent: "claude").items
        #expect(items.count == 2)
        guard case .tool(let name, _, _, let result) = items[0].kind else { Issue.record("not a step"); return }
        #expect(name == TranscriptItem.compactedTool)
        #expect(result?.hasPrefix("This session is being continued") == true)
        #expect(items[1].kind.line == "user: installed, looks fine")
    }

    @Test func claudeUnknownKindsAreCountedNotLost() throws {
        let survey = Transcript.parse(data: try fixture("claude"), agent: "claude").survey
        #expect(survey.unknown == [
            "record:future-thing": 1,
            "attachment:future_attachment": 1,
            "attachment:voice_note": 1,
            "part:citation_text": 1,
            "part:audio": 1,
        ])
    }

    @Test func codexConversation() throws {
        let (items, survey) = Transcript.parse(data: try fixture("codex"), agent: "codex")
        #expect(items.map(\.kind.line) == [
            "user: List the files",
            "tool: shell | ls -la | file.txt",
            "tool: exec | echo hi | hi",
            "assistant: Done",
        ])
        #expect(survey.version == "0.169.0")
        #expect(survey.unknown == ["record:event_msg/future_event": 1, "record:future_record": 1])
    }

    @Test func codexItems() throws {
        let (items, survey) = Transcript.parse(data: try fixture("codex-items"), agent: "codex")
        #expect(items.map(\.kind.line) == [
            "user: Add paging",
            "assistant: Checking the store.",
            "tool: Shell | ls | store.py",
            "tool: Edit | /tmp/demo/store.py | Success",
            "assistant: Paging added.",
        ])
        #expect(survey.unknown == ["item:FutureItem": 1])
    }

    @Test func localModelChat() throws {
        let (items, survey) = Transcript.parse(data: try fixture("localchat"), agent: "ollama")
        #expect(items.map(\.kind.line) == [
            "user: Call me Robin.",
            "thinking: A greeting.",
            "assistant: Hello Robin.",
            "user: What name?",
            "assistant: Robin",
            "user: Stop that.",
        ])
        #expect(survey.version == "gemma4:e4b" && survey.unknown.isEmpty)
    }

    @Test func claudeSessionFromProcessRecord() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-tests-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/.claude/projects/-tmp-a", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/.claude/projects/-tmp-b", withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: home + "/.claude/projects/-tmp-a/s1.jsonl"))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: home + "/.claude/projects/-tmp-b/s2.jsonl"))
        func record(_ pid: Int, _ id: String, _ cwd: String) throws {
            try Data(#"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"\#(cwd)"}"#.utf8)
                .write(to: URL(fileURLWithPath: home + "/.claude/sessions/\(pid).json"))
        }
        try record(100, "s1", "/tmp/a")
        try record(200, "s2", "/tmp/elsewhere")
        try record(300, "missing", "/tmp/a")
        #expect(Transcript.claudeSession(pid: 100, home: home) == home + "/.claude/projects/-tmp-a/s1.jsonl")
        #expect(Transcript.claudeSession(pid: 200, home: home) == home + "/.claude/projects/-tmp-b/s2.jsonl")
        #expect(Transcript.claudeSession(pid: 300, home: home) == nil)
        #expect(Transcript.claudeSession(pid: 400, home: home) == nil)
    }

    @Test func newClaudeNeverTakesAnotherTabsTranscript() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-tests-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/.claude/projects/-tmp-a", withIntermediateDirectories: true)
        let started = Date()
        try Data("{}".utf8).write(to: URL(fileURLWithPath: home + "/.claude/projects/-tmp-a/busy.jsonl"))
        try Data(#"{"pid":500,"sessionId":"mine","cwd":"/tmp/a"}"#.utf8)
            .write(to: URL(fileURLWithPath: home + "/.claude/sessions/500.json"))
        #expect(Transcript.locate(agent: "claude", directory: "/tmp/a", started: started, arguments: [], pid: 500, home: home) == nil)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: home + "/.claude/projects/-tmp-a/mine.jsonl"))
        #expect(Transcript.locate(agent: "claude", directory: "/tmp/a", started: started, arguments: [], pid: 500, home: home)
                == home + "/.claude/projects/-tmp-a/mine.jsonl")
    }

    @Test func rolloutStartComesFromTheName() {
        let d = Transcript.rolloutStart("/x/rollout-2026-11-20T13-05-28-01a1f408-cb9f-7061-96db-ab80f8edb91c.jsonl")
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d ?? .distantPast)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 11, 20, 13, 5, 28])
        #expect(Transcript.rolloutStart("/x/abc.jsonl") == nil)
    }
}

extension TranscriptItem.Kind {
    var line: String {
        switch self {
        case .user(let s): return "user: " + s
        case .assistant(let s): return "assistant: " + s
        case .thinking(let s): return "thinking: " + s
        case .tool(let name, let summary, _, let result): return "tool: \(name) | \(summary) | \(result ?? "(running)")"
        }
    }
}
