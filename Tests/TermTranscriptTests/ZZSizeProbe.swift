import XCTest
import TermTranscript
import TermHost
final class ZZSizeProbe: XCTestCase {
    func testSize() throws {
        let p = NSHomeDirectory() + "/.claude/projects/-Users-user-github-terminal/a15589fc-2b10-4fc7-a791-7a81ccfa3eb5.jsonl"
        let items = Transcript.parse(p, agent: "claude").map { item -> TranscriptItem in
            guard case .tool(let name, let summary, let detail, let result) = item.kind else { return item }
            func cut(_ s: String) -> String { s.count > 1500 ? String(s.prefix(1500)) + "\n…" : s }
            return TranscriptItem(id: item.id, kind: .tool(name: name, summary: summary, detail: cut(detail), result: result.map(cut)))
        }
        let bytes = Wire.Frame.control(Message(op: "transcript", id: "x", code: 0, items: items)).encoded().count
        print("PROBE items=\(items.count) bytes=\(bytes)")
    }
}
