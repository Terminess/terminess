import XCTest
@testable import TermHost

final class AgentModelsTests: XCTestCase {
    func testFindsCursorAndTargetInClaudePicker() {
        let picker = """
         Select model
         Switch between Claude models. Applies to this session and future sessions.

           1. Default (recommended)  Fable 5.2 · For your toughest challenges
         ❯ 2. Fable 5.2              For your toughest challenges
           3. Opus 5.5               For complex work and everyday tasks
           4. Sonnet 5.5             Most efficient for simpler tasks
           5. Haiku 5.5              Fastest for quick answers
        """
        let rows = AgentModels.pickerRows(picker, wanted: "Haiku 5.5")
        XCTAssertEqual(rows?.cursor, 2)
        XCTAssertEqual(rows?.target, 5)
        XCTAssertEqual(AgentModels.pickerRows(picker, wanted: "Fable 5.2")?.target, 2)
        XCTAssertNil(AgentModels.pickerRows(picker, wanted: "Mythos 5.2"))
    }

    func testWrappedDescriptionIsNotARow() {
        let picker = """
        ❯ 1. Default (recommended)
             Opus
          5.5 and newer models
          2. Opus 5.5
        """
        let rows = AgentModels.pickerRows(picker, wanted: "Opus 5.5")
        XCTAssertEqual(rows?.cursor, 1)
        XCTAssertEqual(rows?.target, 2)
    }

    func testFlatJoinsWrappedText() {
        XCTAssertTrue(AgentModels.flat("Set model to Haiku 5.5 for this\n   session only").contains("for this session only"))
    }

    func testCurrentModelIsTheLowestMention() {
        let screen = "Welcome\nOpus 5.5 with high effort\n> hello\n  ~/code  Haiku 5.5  12%"
        XCTAssertEqual(AgentModels.current(onScreen: screen, models: AgentModels.claude), "Haiku 5.5")
        XCTAssertNil(AgentModels.current(onScreen: "nothing here", models: AgentModels.claude))
        let codex = [AgentModel(id: "gpt-6-luna", name: "GPT-6-Luna", detail: "")]
        XCTAssertEqual(AgentModels.current(onScreen: "gpt-6-luna high · ~/code", models: codex), "GPT-6-Luna")
    }

    @MainActor
    func testSwitchDrivesClaudePickerForThisSessionOnly() async {
        final class Fake { var screen = "> "; var typed: [UInt8] = []; var row = 1; var open = false }
        let fake = Fake()
        let names = ["Default (recommended)"] + AgentModels.claude.map(\.name)
        func draw() {
            fake.screen = "Select model\n" + names.enumerated().map { i, n in "\(i + 1 == fake.row ? "❯" : " ") \(i + 1). \(n)" }.joined(separator: "\n")
        }
        let ok = await AgentModels.switchModel(AgentModels.claude[3], agentID: "claude", screen: { fake.screen }, send: { bytes in
            fake.typed += bytes
            if !fake.open {
                if bytes == [0x0D], String(decoding: fake.typed, as: UTF8.self).hasPrefix("/model") { fake.open = true; draw() }
            } else if bytes == [0x1B, 0x5B, 0x42] { fake.row += 1; draw() }
            else if bytes == [0x1B, 0x5B, 0x41] { fake.row -= 1; draw() }
            else if bytes == Array("s".utf8) { fake.screen = "Set model to \(names[fake.row - 1]) for this\nsession only" }
        })
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.screen, "Set model to Haiku 5.5 for this\nsession only")
    }

    @MainActor
    func testSwitchFailsWhenTheAgentSaysNothing() async {
        let ok = await AgentModels.switchModel(AgentModel(id: "x", name: "X", detail: ""), agentID: "shell", screen: { "" }, send: { _ in })
        XCTAssertFalse(ok)
    }

    func testRolesRoundTripAndEnvironment() throws {
        let path = NSTemporaryDirectory() + "roles-\(UUID().uuidString)/models.json"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        XCTAssertEqual(ModelRoles.load(from: path), ModelRoles())

        var roles = ModelRoles()
        roles.set("claude", "main", "claude-fable-5-2")
        roles.set("claude", "subagents", "claude-opus-5-5")
        roles.set("codex", "review", "gpt-6-astra")
        roles.set("codex", "work", "gpt-6-luna")
        roles.set("codex", "ask", "")
        try roles.save(to: path)

        let back = ModelRoles.load(from: path)
        XCTAssertEqual(back.model("codex", "review"), "gpt-6-astra")
        XCTAssertEqual(back.model("codex", "ask"), "")
        XCTAssertEqual(back.environment(), ["ANTHROPIC_MODEL": "claude-fable-5-2", "CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-5-5"])
        XCTAssertEqual(ModelRoles().environment(), [:])
        try #"{"codex":{"work":"gpt-6-luna"}}"#.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(ModelRoles.load(from: path).model("codex", "work"), "gpt-6-luna")
    }
}
