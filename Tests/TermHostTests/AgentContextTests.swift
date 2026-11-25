import XCTest
@testable import TermHost

final class AgentContextTests: XCTestCase {
    func user(_ t: String) -> [String: Any] { ["role": "user", "content": t] }
    func call(_ id: String) -> [String: Any] {
        ["role": "assistant", "content": NSNull(), "tool_calls": [["id": id, "type": "function", "function": ["name": "bash", "arguments": "{}"]]]]
    }
    func result(_ id: String, _ size: Int) -> [String: Any] { ["role": "tool", "tool_call_id": id, "content": String(repeating: "x", count: size)] }

    func testCutKeepsTaskAndNeverStartsOnAToolResult() {
        var msgs: [[String: Any]] = [user("the task")]
        for n in 0..<20 { msgs.append(call("c\(n)")); msgs.append(result("c\(n)", 2000)) }
        let ctx = AgentContext(window: 6000, reply: 1000)
        guard let cut = ctx.cut(msgs) else { return XCTFail("expected a cut") }
        XCTAssertEqual(cut.lowerBound, 1)
        XCTAssertEqual(msgs[cut.upperBound]["role"] as? String, "assistant")
        XCTAssertLessThan(cut.upperBound, msgs.count)
        let kept = msgs[cut.upperBound...].map { AgentContext.size($0) }.reduce(0, +)
        XCTAssertLessThanOrEqual(kept, Int(Double(2000) * 3.2))
    }

    func testHugeLastTurnStillCuts() {
        let msgs: [[String: Any]] = [user("task"), call("a"), result("a", 10), call("b"), result("b", 100_000)]
        let cut = AgentContext(window: 4000, reply: 500).cut(msgs)
        XCTAssertEqual(cut, 1..<3)
    }

    func testShrinkKeepsIdsAndFitsBudget() {
        var msgs: [[String: Any]] = [user("task"), call("a"), result("a", 100_000)]
        let ctx = AgentContext(window: 4000, reply: 500)
        let over = msgs.map { AgentContext.size($0) }.reduce(0, +) - ctx.requestBudget
        AgentContext.shrinkToolResults(&msgs, by: over)
        XCTAssertEqual(msgs[2]["tool_call_id"] as? String, "a")
        XCTAssertLessThanOrEqual(msgs.map { AgentContext.size($0) }.reduce(0, +), ctx.requestBudget + 200)
        XCTAssertTrue((msgs[2]["content"] as? String ?? "").contains("left out to fit"))
    }

    func testThresholdAndLearning() {
        var ctx = AgentContext(window: 10_000, reply: 2000)
        XCTAssertFalse(ctx.needsCompacting(bytes: 3_200 * 6))
        XCTAssertTrue(ctx.needsCompacting(bytes: 3_200 * 7))
        ctx.learn(bytes: 40_000, promptTokens: 10_000)
        XCTAssertEqual(ctx.bytesPerToken, 4)
        XCTAssertFalse(AgentContext(window: 0, reply: 0, compactAt: 0).needsCompacting(bytes: 10_000_000))
        XCTAssertNil(ctx.cut([user("a"), user("b")]))
    }

    func testSummarisesEarlyWhateverTheWindow() {
        let big = AgentContext(window: 1_048_576, reply: 16_384)
        XCTAssertEqual(big.limit, 64_000)
        XCTAssertFalse(big.needsCompacting(bytes: Int(60_000 * 3.2)))
        XCTAssertTrue(big.needsCompacting(bytes: Int(70_000 * 3.2)))
        XCTAssertEqual(AgentContext(window: 1_048_576, reply: 16_384, compactAt: 0).limit, 1_048_576 * 85 / 100 - 16_384)
        XCTAssertEqual(AgentContext(window: 0, reply: 8192).limit, 64_000)
        XCTAssertEqual(AgentContext(window: 32_000, reply: 4000).limit, 23_200)
    }

    func testTranscriptNamesCallsAndTrims() {
        let msgs: [[String: Any]] = [call("a"), result("a", 9000), user("next")]
        let t = AgentContext.transcript(msgs[...], limit: 100_000)
        XCTAssertTrue(t.contains("[called bash {}]"))
        XCTAssertTrue(t.contains("TOOL: "))
        XCTAssertLessThan(t.count, 5000)
        XCTAssertEqual(AgentContext.transcript(msgs[...], limit: 50).utf8.count <= 54, true)
    }

    func testUsageIsRead() {
        var p = OpenAIStream()
        _ = p.feed(Data("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":1234,\"completion_tokens\":56}}\n\ndata: [DONE]\n\n".utf8))
        XCTAssertEqual(p.promptTokens, 1234)
        XCTAssertEqual(p.completionTokens, 56)
    }
}
