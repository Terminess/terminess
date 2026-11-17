import XCTest
import TermHost
@testable import TermHostServer

private final class Peer {
    let fd: Int32
    private var decoder = Wire.Decoder()
    private(set) var messages: [Message] = []

    init?(_ socket: String) {
        guard let fd = UnixSocket.connect(socket) else { return nil }
        self.fd = fd
    }
    deinit { close(fd) }

    func send(_ m: Message) { _ = Connection.writeAll(fd, Wire.Frame.control(m).encoded()) }

    @discardableResult
    func wait(timeout: TimeInterval = 5, for match: (Message) -> Bool) -> Message? {
        let deadline = Date().addingTimeInterval(timeout)
        if let i = messages.firstIndex(where: match) { return messages.remove(at: i) }
        var buf = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) >= 0 else { return nil }
            guard p.revents != 0 else { continue }
            let n = read(fd, &buf, buf.count)
            guard n > 0, let frames = try? decoder.feed(Array(buf[0..<n])) else { return nil }
            for m in frames.compactMap(\.message) {
                if match(m) { return m }
                messages.append(m)
            }
        }
        return nil
    }
}

final class BorrowHandoffTests: XCTestCase {
    private var servers: [HostServer] = []

    private func startServer(_ name: String) throws -> String {
        let socket = NSTemporaryDirectory() + "\(name)-\(getpid()).sock"
        unlink(socket)
        let server = HostServer(socketPath: socket)
        server.reminders = ReminderStore(path: NSTemporaryDirectory() + "\(name)-\(getpid())-rem.json")
        try server.start()
        servers.append(server)
        addTeardownBlock { unlink(socket) }
        return socket
    }

    private func borrowCall(_ task: String) -> Message {
        Message(op: "agent-tool", id: "", name: "borrow", message: #"{"task":"\#(task)"}"#)
    }

    func testBorrowWithoutAMacSaysSo() throws {
        let socket = try startServer("borrow-none")
        let agent = try XCTUnwrap(Peer(socket))
        agent.send(borrowCall("report the date"))
        let r = try XCTUnwrap(agent.wait { $0.op == "agent-result" })
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.message?.contains("isn't connected") == true)
    }

    func testBorrowIsRelayedToTheWatchingMacAndTheAnswerComesBack() throws {
        let socket = try startServer("borrow-relay")
        let mac = try XCTUnwrap(Peer(socket))
        mac.send(Message(op: "watch-borrow"))
        XCTAssertNotNil(mac.wait { $0.op == "watching" })
        let agent = try XCTUnwrap(Peer(socket))
        agent.send(borrowCall("report the date"))
        let req = try XCTUnwrap(mac.wait { $0.op == "borrow-request" })
        XCTAssertEqual(req.message, "report the date")
        let id = try XCTUnwrap(req.id)
        mac.send(Message(op: "borrow-reply", id: id, code: 0, message: "It is Tuesday."))
        let r = try XCTUnwrap(agent.wait { $0.op == "agent-result" })
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.message, "It is Tuesday.")
    }

    func testBorrowGoesToTheMostRecentLiveMac() throws {
        let socket = try startServer("borrow-latest")
        var first: Peer? = try XCTUnwrap(Peer(socket))
        first!.send(Message(op: "watch-borrow"))
        XCTAssertNotNil(first!.wait { $0.op == "watching" })
        let second = try XCTUnwrap(Peer(socket))
        second.send(Message(op: "watch-borrow"))
        XCTAssertNotNil(second.wait { $0.op == "watching" })
        first = nil
        Thread.sleep(forTimeInterval: 0.2)
        let agent = try XCTUnwrap(Peer(socket))
        agent.send(borrowCall("x"))
        XCTAssertNotNil(second.wait { $0.op == "borrow-request" })
    }

    func testHandoffInfoRefusesASessionWithoutAnAgent() throws {
        let socket = try startServer("handoff-noagent")
        let c = try XCTUnwrap(Peer(socket))
        c.send(Message(op: "create", name: "plain", cwd: NSTemporaryDirectory(), command: "/bin/sh", cols: 80, rows: 24))
        let created = try XCTUnwrap(c.wait { $0.op == "created" })
        c.send(Message(op: "handoff-info", id: created.id))
        let r = try XCTUnwrap(c.wait { $0.op == "error" || $0.op == "handoff-info" })
        XCTAssertEqual(r.op, "error")
        XCTAssertTrue(r.message?.contains("No Claude Code or Codex agent") == true)
        c.send(Message(op: "handoff-export", id: created.id))
        XCTAssertEqual(c.wait { $0.op == "error" || $0.op == "handoff-ready" }?.op, "error")
        c.send(Message(op: "kill", id: created.id))
    }

    func testHandoffChunksMustArriveInOrder() throws {
        let socket = try startServer("handoff-chunks")
        let c = try XCTUnwrap(Peer(socket))
        var m = Message(op: "handoff-put", name: "tok", code: 0)
        m.data = Data("abc".utf8).base64EncodedString()
        c.send(m)
        XCTAssertEqual(c.wait { $0.op == "ok" || $0.op == "error" }?.op, "ok")
        var skip = Message(op: "handoff-put", name: "tok", code: 99)
        skip.data = Data("d".utf8).base64EncodedString()
        c.send(skip)
        XCTAssertEqual(c.wait { $0.op == "ok" || $0.op == "error" }?.op, "error")
        c.send(Message(op: "handoff-import", name: "tok", message: "{}"))
        XCTAssertEqual(c.wait { $0.op == "error" || $0.op == "handoff-imported" }?.op, "error", "an incomplete bundle doesn't decode")
    }
}
