import XCTest
import TermHost
@testable import TermHostServer

private final class Client {
    let fd: Int32
    private var decoder = Wire.Decoder()
    private(set) var messages: [Message] = []
    private(set) var output: [UInt8] = []

    init?(_ socket: String) {
        guard let fd = UnixSocket.connect(socket) else { return nil }
        self.fd = fd
    }
    deinit { close(fd) }

    func send(_ m: Message) { _ = Connection.writeAll(fd, Wire.Frame.control(m).encoded()) }

    @discardableResult
    func wait(timeout: TimeInterval = 5, for match: (Message) -> Bool) -> Message? {
        let deadline = Date().addingTimeInterval(timeout)
        if let m = messages.first(where: match) { return m }
        var buf = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) >= 0 else { return nil }
            guard p.revents != 0 else { continue }
            let n = read(fd, &buf, buf.count)
            guard n > 0, let frames = try? decoder.feed(Array(buf[0..<n])) else { return nil }
            for f in frames {
                if f.kind == .output { output += f.payload }
                if let m = f.message {
                    messages.append(m)
                    if match(m) { return m }
                }
            }
        }
        return nil
    }

    func waitForOutput(containing text: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if String(decoding: output, as: UTF8.self).contains(text) { return true }
            _ = wait(timeout: 0.2) { _ in false }
        }
        return String(decoding: output, as: UTF8.self).contains(text)
    }
}

final class ReminderTests: XCTestCase {
    private var tmp: String!
    private var servers: [HostServer] = []

    override func setUp() {
        tmp = NSTemporaryDirectory() + "rem-\(getpid())-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: tmp) }


    func testParseTimes() throws {
        let zone = TimeZone(identifier: "Europe/London")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12, minute: 0))!
        let tonight = try XCTUnwrap(ReminderTime.parse("22:00", now: now, zone: zone))
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: tonight), DateComponents(day: 17, hour: 22, minute: 0))
        let tomorrow = try XCTUnwrap(ReminderTime.parse("9:30", now: now, zone: zone))
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: tomorrow), DateComponents(day: 18, hour: 9, minute: 30), "a time that has passed means tomorrow")
        XCTAssertEqual(ReminderTime.parse("+2h", now: now), now.addingTimeInterval(7200))
        XCTAssertEqual(ReminderTime.parse("+1h30m", now: now), now.addingTimeInterval(5400))
        XCTAssertEqual(ReminderTime.parse("+90m", now: now), now.addingTimeInterval(5400))
        XCTAssertEqual(ReminderTime.parse("+1d", now: now), now.addingTimeInterval(86400))
        let local = try XCTUnwrap(ReminderTime.parse("2026-11-17T22:00", now: now, zone: zone))
        XCTAssertEqual(local, tonight)
        XCTAssertEqual(ReminderTime.parse("2026-11-17 22:00", now: now, zone: zone), tonight)
        XCTAssertEqual(ReminderTime.parse("2026-11-17T22:00:00Z", now: now, zone: zone), tonight, "London is on GMT in November")
        XCTAssertEqual(ReminderTime.parse("2026-11-17T23:00+01:00", now: now, zone: zone), tonight)
        for bad in ["", "tonight", "25:00", "+", "+2x", "+h", "22:7", "2026-13-01T10:00"] {
            XCTAssertNil(ReminderTime.parse(bad, now: now, zone: zone), bad)
        }
    }


    func testStorePersistsFiresAndRemoves() {
        let path = tmp + "/reminders.json"
        let store = ReminderStore(path: path)
        let soon = store.add(ReminderInfo(id: "", title: "Soon", due: 1_000, created: 0), now: Date(timeIntervalSince1970: 900))
        let later = store.add(ReminderInfo(id: "", title: "Later", due: 5_000, actionPrompt: "go", created: 0))
        XCTAssertEqual(soon.id.count, 8)
        XCTAssertEqual(soon.created, 900)
        XCTAssertNotEqual(soon.id, later.id)

        let reloaded = ReminderStore(path: path)
        XCTAssertEqual(reloaded.items.map(\.title), ["Soon", "Later"], "kept across restarts, earliest first")

        XCTAssertEqual(reloaded.fireDue(now: Date(timeIntervalSince1970: 2_000)).map(\.id), [soon.id])
        XCTAssertTrue(reloaded.fireDue(now: Date(timeIntervalSince1970: 2_001)).isEmpty, "goes off once")
        XCTAssertEqual(reloaded.pending.map(\.id), [soon.id])
        XCTAssertEqual(ReminderStore(path: path).pending.map(\.id), [soon.id], "still pending after a restart")

        XCTAssertNotNil(reloaded.remove(soon.id))
        XCTAssertNil(reloaded.remove(soon.id))
        XCTAssertEqual(ReminderStore(path: path).items.map(\.id), [later.id])
    }

    func testResumeCommand() {
        var r = ReminderInfo(id: "x", title: "t", due: 0, actionPrompt: "It's 10pm, go ahead", created: 0)
        XCTAssertNil(ReminderStore.resumeShellCommand(r), "nothing to resume without a conversation")
        r.agent = "claude"; r.conversation = "791af30f-c950"
        XCTAssertEqual(ReminderStore.resumeShellCommand(r), "claude --resume 791af30f-c950 'It'\\''s 10pm, go ahead'")
        r.agent = "codex"; r.actionPrompt = nil
        XCTAssertEqual(ReminderStore.resumeShellCommand(r), "codex resume 791af30f-c950")
    }

    func testClaudeConversationFromPerProcessRecord() throws {
        try FileManager.default.createDirectory(atPath: tmp + "/.claude/sessions", withIntermediateDirectories: true)
        try #"{"pid":4242,"sessionId":"abc-123","cwd":"/r"}"#.write(toFile: tmp + "/.claude/sessions/4242.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(ReminderStore.claudeConversation(pid: 4242, home: tmp), "abc-123")
        XCTAssertNil(ReminderStore.claudeConversation(pid: 4243, home: tmp))
    }


    private func startServer(_ name: String) throws -> (HostServer, String) {
        let socket = NSTemporaryDirectory() + "\(name)-\(getpid()).sock"
        unlink(socket)
        let server = HostServer(socketPath: socket)
        server.reminders = ReminderStore(path: tmp + "/reminders.json")
        server.promptReturnDelay = 0
        try server.start()
        servers.append(server)
        addTeardownBlock { unlink(socket) }
        return (server, socket)
    }

    func testReminderGoesOffForWatchersAndLaterClients() throws {
        let (_, socket) = try startServer("trf")
        guard let a = Client(socket), let quiet = Client(socket) else { return XCTFail("no socket") }
        a.send(Message(op: "watch-reminders"))
        a.wait { $0.op == "watching" }
        quiet.send(Message(op: "hello", version: Wire.version))
        quiet.wait { $0.op == "hello" }
        var add = Message(op: "remind-add")
        add.reminder = ReminderInfo(id: "", title: "Switch on the firewall", due: Date().timeIntervalSince1970 + 1, created: 0)
        a.send(add)
        let added = try XCTUnwrap(a.wait { $0.op == "reminder-added" }?.reminder)
        let fired = try XCTUnwrap(a.wait(timeout: 6) { $0.op == "reminder" }, "a watcher hears it go off")
        XCTAssertEqual(fired.reminder?.id, added.id)
        XCTAssertEqual(fired.reminder?.fired, true)
        XCTAssertNil(quiet.wait(timeout: 1) { $0.op != "hello" }, "a request-and-reply client is never sent anything it didn't ask for")

        quiet.send(Message(op: "reminders"))
        XCTAssertEqual(quiet.wait { $0.op == "reminders" }?.reminders?.first?.fired, true, "polling clients see it as due")

        guard let b = Client(socket) else { return XCTFail("no socket") }
        b.send(Message(op: "watch-reminders"))
        XCTAssertNotNil(b.wait { $0.op == "reminder" && $0.reminder?.id == added.id }, "a watcher joining later gets the pending one")

        b.send(Message(op: "reminder-dismiss", id: added.id))
        XCTAssertNotNil(a.wait { $0.op == "reminder-done" && $0.id == added.id }, "every watcher puts it away")
        quiet.send(Message(op: "reminders"))
        XCTAssertEqual(quiet.wait { $0.op == "reminders" && $0.reminders?.isEmpty == true }?.reminders?.count, 0)
    }

    func testRefusesPastAndUntitledAndUnknownSession() throws {
        let (_, socket) = try startServer("trr")
        guard let a = Client(socket) else { return XCTFail("no socket") }
        for r in [ReminderInfo(id: "", title: "Old", due: Date().timeIntervalSince1970 - 3600, created: 0),
                  ReminderInfo(id: "", title: " ", due: Date().timeIntervalSince1970 + 60, created: 0),
                  ReminderInfo(id: "", title: "x", due: Date().timeIntervalSince1970 + 60, sessionId: "nope", created: 0)] {
            var m = Message(op: "remind-add"); m.reminder = r
            a.send(m)
            XCTAssertNotNil(a.wait { $0.op == "error" }, r.title)
            a.wait(timeout: 0.1) { _ in false }
        }
    }


    func testHelloSaysPlatformAndListSaysWhichClientsAreAttached() throws {
        let (_, socket) = try startServer("tdk")
        guard let ctl = Client(socket) else { return XCTFail("no socket") }
        ctl.send(Message(op: "hello", version: Wire.version))
        let hello = try XCTUnwrap(ctl.wait { $0.op == "hello" })
        #if os(macOS)
        XCTAssertEqual(hello.platform, "macos")
        #else
        XCTAssertEqual(hello.platform, "linux")
        #endif

        ctl.send(Message(op: "create", name: "cat", cwd: tmp, command: "/bin/cat", args: [], cols: 80, rows: 24))
        let session = try XCTUnwrap(ctl.wait { $0.op == "created" }?.id)

        func kinds() throws -> [String]? {
            guard let c = Client(socket) else { XCTFail("no socket"); return nil }
            c.send(Message(op: "list"))
            let list = try XCTUnwrap(c.wait { $0.op == "sessions" })
            return list.sessions?.first { $0.id == session }?.clientKinds
        }
        XCTAssertNil(try kinds(), "nobody attached yet")

        guard let phone = Client(socket), let mac = Client(socket), let cli = Client(socket) else { return XCTFail("no socket") }
        phone.send(Message(op: "attach", host: "iphone", id: session, cols: 80, rows: 24))
        phone.wait { $0.op == "replayed" }
        XCTAssertEqual(try kinds(), ["iphone"])

        mac.send(Message(op: "attach", host: "mac", id: session, cols: 80, rows: 24))
        mac.wait { $0.op == "replayed" }
        cli.send(Message(op: "attach", id: session, cols: 80, rows: 24))
        cli.wait { $0.op == "replayed" }
        XCTAssertEqual(try kinds(), ["iphone", "mac", "other"], "unknown clients count as other")
    }

    func testListNamesEachAttachedDeviceAndTheOneThatStartedIt() throws {
        let (_, socket) = try startServer("tdn")
        guard let phone = Client(socket) else { return XCTFail("no socket") }
        var create = Message(op: "create", host: "iphone", name: "cat", cwd: tmp, command: "/bin/cat", args: [], cols: 80, rows: 24)
        create.deviceName = "Alex's iPhone 13 Pro\u{0007}"
        phone.send(create)
        let session = try XCTUnwrap(phone.wait { $0.op == "created" }?.id)

        func info() throws -> SessionInfo? {
            guard let c = Client(socket) else { XCTFail("no socket"); return nil }
            c.send(Message(op: "list"))
            return try XCTUnwrap(c.wait { $0.op == "sessions" }).sessions?.first { $0.id == session }
        }
        XCTAssertEqual(try info()?.originName, "Alex's iPhone 13 Pro")

        var attach = Message(op: "attach", host: "iphone", id: session, cols: 80, rows: 24)
        attach.deviceName = "Alex's iPhone 13 Pro"
        phone.send(attach)
        phone.wait { $0.op == "replayed" }
        guard let mac = Client(socket) else { return XCTFail("no socket") }
        var macAttach = Message(op: "attach", host: "mac", id: session, cols: 80, rows: 24)
        macAttach.deviceName = "Alex's MacBook Pro"
        mac.send(macAttach)
        mac.wait { $0.op == "replayed" }
        let s = try XCTUnwrap(try info())
        XCTAssertEqual(s.clientDevices, [ClientDevice(kind: "iphone", name: "Alex's iPhone 13 Pro"),
                                         ClientDevice(kind: "mac", name: "Alex's MacBook Pro")])
        XCTAssertNil(s.originName, "picked up on a Mac: no longer shown as from the phone")
    }

    func testActTypesPromptIntoLiveSession() throws {
        let (_, socket) = try startServer("tra")
        guard let c = Client(socket) else { return XCTFail("no socket") }
        c.send(Message(op: "create", name: "cat", cwd: tmp, command: "/bin/cat", args: [], cols: 80, rows: 24))
        let session = try XCTUnwrap(c.wait { $0.op == "created" }?.id)
        c.send(Message(op: "attach", id: session, cols: 80, rows: 24))
        c.wait { $0.op == "replayed" }

        guard let ctl = Client(socket) else { return XCTFail("no socket") }
        var add = Message(op: "remind-add")
        add.reminder = ReminderInfo(id: "", title: "Pick up", due: Date().timeIntervalSince1970 + 3600,
                                    actionPrompt: "proceed-now-7731", sessionId: session, created: 0)
        ctl.send(add)
        let r = try XCTUnwrap(ctl.wait { $0.op == "reminder-added" }?.reminder)
        XCTAssertEqual(r.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: tmp).resolvingSymlinksInPath().path, "the session's folder is kept for later")
        ctl.send(Message(op: "reminder-act", id: r.id))
        XCTAssertEqual(ctl.wait { $0.op == "reminder-acted" }?.id, session, "the client opens the same session")
        XCTAssertTrue(c.waitForOutput(containing: "proceed-now-7731"), "the prompt was typed into the session")
        c.send(Message(op: "kill", id: session))
    }

    func testActOnEndedSessionStartsANewOne() throws {
        let (_, socket) = try startServer("tre")
        guard let ctl = Client(socket) else { return XCTFail("no socket") }
        var add = Message(op: "remind-add")
        add.reminder = ReminderInfo(id: "", title: "Resume it", due: Date().timeIntervalSince1970 + 3600,
                                    actionPrompt: "carry on", cwd: tmp, created: 0)
        ctl.send(add)
        let r = try XCTUnwrap(ctl.wait { $0.op == "reminder-added" }?.reminder)
        XCTAssertNil(r.sessionId)
        ctl.send(Message(op: "reminder-act", id: r.id))
        let started = try XCTUnwrap(ctl.wait { $0.op == "reminder-acted" }?.id)
        ctl.send(Message(op: "list"))
        let list = try XCTUnwrap(ctl.wait { $0.op == "sessions" }?.sessions)
        let s = try XCTUnwrap(list.first { $0.id == started }, "a new session exists")
        XCTAssertEqual(s.name, "Resume it")
        ctl.send(Message(op: "reminder-act", id: r.id))
        XCTAssertNotNil(ctl.wait { $0.op == "error" }, "acting twice does nothing")
        ctl.send(Message(op: "kill", id: started))
    }
}
