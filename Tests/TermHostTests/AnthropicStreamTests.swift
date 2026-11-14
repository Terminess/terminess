import XCTest
@testable import TermHost

final class AnthropicStreamTests: XCTestCase {
    func sse(_ events: [[String: Any]]) -> Data {
        Data(events.map { e in
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: e), as: UTF8.self)
            return "event: \(e["type"]!)\ndata: \(json)\n\n"
        }.joined().utf8)
    }

    let events: [[String: Any]] = [
        ["type": "message_start", "message": ["id": "msg_1", "type": "message", "role": "assistant", "content": []]],
        ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
        ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Check the file "]],
        ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "first."]],
        ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sig123"]],
        ["type": "content_block_stop", "index": 0],
        ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
        ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "Reading it."]],
        ["type": "content_block_stop", "index": 1],
        ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "toolu_1", "name": "read_file", "input": [:]]],
        ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"path\": \"RE"]],
        ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "ADME.md\"}"]],
        ["type": "content_block_stop", "index": 2],
        ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 40]],
        ["type": "message_stop"],
    ]

    func testTurnAndMessageToSendBack() {
        var s = AnthropicStream()
        let data = sse(events)
        let shown = s.feed(data.prefix(100)) + s.feed(data.dropFirst(100))
        XCTAssertEqual(shown.filter { !$0.1 }.map(\.0).joined(), "Reading it.")
        XCTAssertEqual(shown.filter { $0.1 }.map(\.0).joined(), "Check the file first.")
        let t = s.result()
        XCTAssertEqual(t.stopReason, "tool_use")
        XCTAssertEqual(t.calls.count, 1)
        XCTAssertEqual(t.calls[0].id, "toolu_1")
        XCTAssertEqual(t.calls[0].input["path"] as? String, "README.md")
        XCTAssertFalse(t.calls[0].invalid)
        let content = s.content
        XCTAssertEqual(content.map { $0["type"] as? String }, ["thinking", "text", "tool_use"])
        XCTAssertEqual(content[0]["signature"] as? String, "sig123")
        XCTAssertEqual(content[0]["thinking"] as? String, "Check the file first.")
        XCTAssertNil(content[2]["_invalid"])
    }

    func testCutOffToolInputIsFlagged() {
        var s = AnthropicStream()
        _ = s.feed(sse([
            ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "t", "name": "bash", "input": [:]]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "{\"command\": \"ls"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "message_delta", "delta": ["stop_reason": "max_tokens"]],
        ]))
        let t = s.result()
        XCTAssertEqual(t.stopReason, "max_tokens")
        XCTAssertTrue(t.calls[0].invalid)
    }

    func testUnknownBlocksAreKeptForTheRoundTrip() {
        var s = AnthropicStream()
        _ = s.feed(sse([
            ["type": "content_block_start", "index": 0, "content_block": ["type": "fallback", "from": ["model": "a"], "to": ["model": "b"]]],
            ["type": "content_block_stop", "index": 0],
            ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]],
        ]))
        XCTAssertEqual(s.content.first?["type"] as? String, "fallback")
        XCTAssertEqual(s.result().error, "Overloaded")
    }
}
