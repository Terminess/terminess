import XCTest
@testable import TermHostServer

final class HistoryFilterTests: XCTestCase {
    func testSkipsPrintRunsAndTerminessFolders() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "history-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: home) }
        let repo = home + "/github/app"
        let borrow = home + "/.local/state/terminess/borrow/abc"
        for d in [repo, borrow] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }

        func transcript(_ id: String, cwd: String, entrypoint: String, text: String) throws {
            let dir = home + "/.claude/projects/" + cwd.replacingOccurrences(of: "/", with: "-")
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let line: [String: Any] = ["type": "user", "cwd": cwd, "entrypoint": entrypoint, "sessionId": id,
                                       "message": ["role": "user", "content": text]]
            let data = try JSONSerialization.data(withJSONObject: line)
            try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: dir + "/" + id + ".jsonl"))
        }
        try transcript("kept", cwd: repo, entrypoint: "cli", text: "Fix the sidebar")
        try transcript("print", cwd: repo, entrypoint: "sdk-cli", text: "Run in zsh and report")
        try transcript("borrowed", cwd: borrow, entrypoint: "cli", text: "Open the dashboard")

        let got = History.recent(home: home)
        XCTAssertEqual(got.map(\.id), ["kept"])
        XCTAssertEqual(got.first?.title, "Fix the sidebar")
    }
}
