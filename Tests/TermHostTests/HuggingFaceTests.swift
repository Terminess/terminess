import XCTest
@testable import TermHost

final class HuggingFaceTests: XCTestCase {
    func sse(_ chunks: [[String: Any]], done: Bool = true) -> Data {
        var s = chunks.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
        if done { s += "data: [DONE]\n\n" }
        return Data(s.utf8)
    }
    func delta(_ d: [String: Any], finish: String? = nil) -> [String: Any] {
        var c: [String: Any] = ["index": 0, "delta": d]
        if let finish { c["finish_reason"] = finish }
        return ["id": "x", "object": "chat.completion.chunk", "choices": [c]]
    }

    func testTextAndReasoning() {
        var p = OpenAIStream()
        let pieces = p.feed(sse([
            delta(["role": "assistant", "reasoning_content": "Think "]),
            delta(["reasoning": "more."]),
            delta(["content": "Hello"]),
            delta(["content": " there"], finish: "stop"),
        ]))
        XCTAssertEqual(pieces.map(\.0), ["Think ", "more.", "Hello", " there"])
        XCTAssertEqual(pieces.map(\.1), [true, true, false, false])
        let t = p.result()
        XCTAssertEqual(t.text, "Hello there")
        XCTAssertEqual(t.thinking, "Think more.")
        XCTAssertEqual(t.stopReason, "end_turn")
        XCTAssertTrue(t.calls.isEmpty)
        XCTAssertEqual(p.assistantMessage()["content"] as? String, "Hello there")
        XCTAssertNil(p.assistantMessage()["tool_calls"])
    }

    func testToolCallsInPiecesSplitAcrossReads() {
        var p = OpenAIStream()
        let data = sse([
            delta(["tool_calls": [["index": 0, "id": "call_a", "type": "function", "function": ["name": "read_file", "arguments": ""]]]]),
            delta(["tool_calls": [["index": 0, "function": ["arguments": "{\"path\": \"RE"]]]]),
            delta(["tool_calls": [["index": 0, "function": ["arguments": "ADME.md\"}"]]]]),
            delta(["tool_calls": [["index": 1, "type": "function", "function": ["name": "bash", "arguments": "{\"command\":\"ls\"}"]]]]),
            delta([:], finish: "tool_calls"),
        ])
        var i = 0
        while i < data.count { _ = p.feed(data.subdata(in: i..<min(i + 7, data.count))); i += 7 }
        let t = p.result()
        XCTAssertEqual(t.stopReason, "tool_use")
        XCTAssertEqual(t.calls.count, 2)
        XCTAssertEqual(t.calls[0].id, "call_a")
        XCTAssertEqual(t.calls[0].name, "read_file")
        XCTAssertEqual(t.calls[0].input["path"] as? String, "README.md")
        XCTAssertFalse(t.calls[0].invalid)
        XCTAssertEqual(t.calls[1].id, "call_2")
        XCTAssertEqual(t.calls[1].input["command"] as? String, "ls")
        let m = p.assistantMessage()
        XCTAssertTrue(m["content"] is NSNull)
        let calls = m["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(calls?.count, 2)
        XCTAssertEqual((calls?[0]["function"] as? [String: Any])?["arguments"] as? String, "{\"path\": \"README.md\"}")
    }

    func testCutOffArgumentsAreInvalid() {
        var p = OpenAIStream()
        _ = p.feed(sse([
            delta(["tool_calls": [["index": 0, "id": "c", "function": ["name": "write_file", "arguments": "{\"path\": \"a"]]]]),
            delta([:], finish: "length"),
        ]))
        let t = p.result()
        XCTAssertTrue(t.calls[0].invalid)
        XCTAssertEqual(t.stopReason, "max_tokens")
    }

    func testStreamEndingWithoutFinishRunsNothing() {
        var p = OpenAIStream()
        _ = p.feed(sse([delta(["tool_calls": [["index": 0, "id": "c", "function": ["name": "bash", "arguments": "{\"command\":\"ls\"}"]]]])],
                       done: false))
        let t = p.result()
        XCTAssertNotNil(t.error)
        XCTAssertTrue(t.calls.isEmpty)
    }

    func testReasoningKeptOnlyWhenAsked() {
        var p = OpenAIStream()
        _ = p.feed(sse([delta(["reasoning_content": "plan"]),
                        delta(["tool_calls": [["index": 0, "id": "c", "function": ["name": "bash", "arguments": "{}"]]]], finish: "tool_calls")]))
        XCTAssertNil(p.assistantMessage()["reasoning_content"])
        XCTAssertEqual(p.assistantMessage(withReasoning: true)["reasoning_content"] as? String, "plan")
    }

    func testErrorEventAndCRLF() {
        var p = OpenAIStream()
        _ = p.feed(Data("data: {\"error\":{\"message\":\"Model is overloaded\"}}\r\n\r\n".utf8))
        XCTAssertEqual(p.result().error, "Model is overloaded")
    }

    func testErrorMessages() {
        let body = Data(#"{"error":"You have exceeded your monthly included credits"}"#.utf8)
        XCTAssertTrue(HuggingFace.errorMessage(status: 402, body: body).contains("billing"))
        XCTAssertTrue(HuggingFace.errorMessage(status: 401, body: Data()).contains("settings/tokens"))
        XCTAssertEqual(HuggingFace.errorMessage(status: 404, body: Data(#"{"error":{"message":"Model not found"}}"#.utf8)),
                       "HTTP 404: Model not found")
    }

    func testNoticeFollowsTheLastRequest() throws {
        let home = NSTemporaryDirectory() + "hf-notice-\(UUID().uuidString)"
        let oldHome = ProcessInfo.processInfo.environment["HOME"], oldToken = ProcessInfo.processInfo.environment["HF_TOKEN"]
        setenv("HOME", home, 1); unsetenv("HF_TOKEN")
        defer {
            if let oldHome { setenv("HOME", oldHome, 1) }
            if let oldToken { setenv("HF_TOKEN", oldToken, 1) }
            try? FileManager.default.removeItem(atPath: home)
        }
        XCTAssertEqual(HuggingFace.notice(), .noToken)
        try HuggingFace.savePrivate("hf_test", to: HuggingFace.tokenPath)
        XCTAssertNil(HuggingFace.notice())
        HuggingFace.record(status: 402)
        XCTAssertEqual(HuggingFace.notice(), .noCredit)
        XCTAssertEqual(HuggingFace.notice()?.url, HuggingFace.billingPage)
        HuggingFace.record(status: 500)
        XCTAssertEqual(HuggingFace.notice(), .noCredit)
        HuggingFace.record(status: 200)
        XCTAssertNil(HuggingFace.notice())
        HuggingFace.record(status: 401)
        XCTAssertEqual(HuggingFace.notice(), .badToken)
        HuggingFace.clearNotice()
        XCTAssertNil(HuggingFace.notice())
    }

    func testModelNamesAndList() {
        XCTAssertEqual(HuggingFace.modelID("hf:moonshotai/Kimi-K3:groq"), "moonshotai/Kimi-K3:groq")
        XCTAssertNil(HuggingFace.modelID("ollama:gemma"))
        XCTAssertEqual(HuggingFace.parseModels("hf:a/b\n# note\n c/d , a/b\n\ne/f:cheapest"), ["a/b", "c/d", "e/f:cheapest"])
        XCTAssertEqual(LocalModels.chatCommand(terminessd: "terminessd", model: "hf:Qwen/Qwen3.8-2.4T-A95B:fastest"),
                       "'terminessd' chat hf:Qwen/Qwen3.8-2.4T-A95B:fastest")
    }
}
