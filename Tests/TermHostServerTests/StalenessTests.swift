import XCTest
import TermHost
@testable import TermHostServer

private final class FakeGit: @unchecked Sendable {
    var head = "aaa"
    var count = "4"
    var calls: [[String]] = []
    let lock = NSLock()
    func run(_ folder: String, _ args: [String]) -> String? {
        lock.lock(); defer { lock.unlock() }
        calls.append(args)
        if args.first == "rev-parse" { return head }
        if args.first == "rev-list" { return count }
        return nil
    }
    var revLists: Int { lock.lock(); defer { lock.unlock() }; return calls.filter { $0.first == "rev-list" }.count }
}

final class StalenessTests: XCTestCase {
    private let old = HistoryItem(id: "old", agent: "claude", cwd: "/r", title: "Old", used: 1_000)
    private let new = HistoryItem(id: "new", agent: "claude", cwd: "/r", title: "New", used: 2_000)
    private let other = HistoryItem(id: "solo", agent: "codex", cwd: "/s", title: "Solo", used: 500)

    func testMarkNewestPerFolder() {
        let marked = CommitCounter.markNewest([old, new, other])
        XCTAssertEqual(marked.map(\.newest), [false, true, true])
    }

    func testCountIsCachedUntilHeadMoves() {
        let git = FakeGit()
        let c = CommitCounter(git: git.run)
        XCTAssertEqual(c.count(folder: "/r", since: 1_000), 4)
        XCTAssertEqual(c.count(folder: "/r", since: 1_000), 4)
        XCTAssertEqual(git.revLists, 1, "same HEAD: counted once")
        git.head = "bbb"; git.count = "6"
        XCTAssertEqual(c.count(folder: "/r", since: 1_000), 6)
        XCTAssertEqual(git.revLists, 2, "HEAD moved: counted again")
    }

    func testAnnotateServesCacheAndFillsItInTheBackground() {
        let git = FakeGit()
        let c = CommitCounter(git: git.run)
        let first = c.annotate([new, old])
        XCTAssertNil(first.first { $0.id == "old" }?.commitsSince, "nothing cached yet, and no git on the hot path")
        XCTAssertNil(first.first { $0.id == "new" }?.commitsSince, "the newest never gets a count")
        c.settle()
        let second = c.annotate([new, old])
        XCTAssertEqual(second.first { $0.id == "old" }?.commitsSince, 4)
        XCTAssertEqual(second.first { $0.id == "new" }?.newest, true)
    }

    func testNoticeText() {
        var o = old; o.newest = false
        var n = new; n.newest = true
        XCTAssertNil(CommitCounter.notice(for: n, commits: 3))
        XCTAssertEqual(CommitCounter.notice(for: o, commits: 1), "Older conversation: 1 commit has landed since. Check the repo state before carrying on.")
        XCTAssertEqual(CommitCounter.notice(for: o, commits: 12), "Older conversation: 12 commits have landed since. Check the repo state before carrying on.")
        XCTAssertEqual(CommitCounter.notice(for: o, commits: 0), "Older conversation: a newer one exists in this folder. Check the repo state before carrying on.")
    }

    func testNoticeGoesToAttachedClients() throws {
        let socket = NSTemporaryDirectory() + "tsn-\(getpid()).sock"
        unlink(socket)
        let server = HostServer(socketPath: socket)
        let items = [old, new]
        server.historyProvider = { items }
        let git = FakeGit()
        server.commits = CommitCounter(git: git.run)
        try server.start()
        defer { unlink(socket) }

        let queue = DispatchQueue(label: "test")
        let gotFirst = expectation(description: "creator gets the notice")
        guard let fd = UnixSocket.connect(socket) else { return XCTFail("no socket") }
        let a = HostAttachment(readFD: fd, writeFD: fd, target: .create(cwd: "/tmp", command: "/bin/sleep", args: ["20"], env: nil, name: "t"),
                               cols: 80, rows: 24, queue: queue)
        a.resumeOf = "old"
        var sessionID: String?
        a.onAttached = { id, _, _ in sessionID = id }
        a.onNotice = { text in
            if text?.contains("4 commits have landed since") == true { gotFirst.fulfill() }
        }
        a.start()
        wait(for: [gotFirst], timeout: 10)

        let gotSecond = expectation(description: "a later client gets it on attach")
        guard let id = queue.sync(execute: { sessionID }), let fd2 = UnixSocket.connect(socket) else { return XCTFail("no session") }
        let b = HostAttachment(readFD: fd2, writeFD: fd2, target: .attach(id: id), cols: 80, rows: 24, queue: queue)
        b.onNotice = { text in if text?.hasPrefix("Older conversation") == true { gotSecond.fulfill() } }
        b.start()
        wait(for: [gotSecond], timeout: 10)
        a.kill()
    }

    func testNoNoticeForTheNewest() throws {
        let socket = NSTemporaryDirectory() + "tsm-\(getpid()).sock"
        unlink(socket)
        let server = HostServer(socketPath: socket)
        let items = [old, new]
        server.historyProvider = { items }
        server.commits = CommitCounter(git: FakeGit().run)
        try server.start()
        defer { unlink(socket) }
        let queue = DispatchQueue(label: "test2")
        let attached = expectation(description: "attached")
        let noNotice = expectation(description: "no notice"); noNotice.isInverted = true
        guard let fd = UnixSocket.connect(socket) else { return XCTFail("no socket") }
        let a = HostAttachment(readFD: fd, writeFD: fd, target: .create(cwd: "/tmp", command: "/bin/sleep", args: ["20"], env: nil, name: "t2"),
                               cols: 80, rows: 24, queue: queue)
        a.resumeOf = "new"
        a.onAttached = { _, _, _ in attached.fulfill() }
        a.onNotice = { _ in noNotice.fulfill() }
        a.start()
        wait(for: [attached], timeout: 10)
        wait(for: [noNotice], timeout: 2)
        a.kill()
    }
}
