import Foundation
import TermHost
import TermTranscript

enum DemoMachine {
    enum Kind: String, CaseIterable, Sendable {
        case mac = "demo", pc = "demo-pc", server = "demo-server"
        var address: String { "\(rawValue).terminess.invalid" }
        var name: String {
            switch self {
            case .mac: return "Mac"
            case .pc: return "Linux PC"
            case .server: return "Server"
            }
        }
    }

    static func kind(_ host: SavedHost?) -> Kind? { Kind.allCases.first { $0.address == host?.address } }
    static func isDemo(_ host: SavedHost?) -> Bool { kind(host) != nil }

    static var hosts: [SavedHost] { Kind.allCases.map { SavedHost(name: $0.name, address: $0.address, port: 22, user: "demo") } }

    static func channel(_ kind: Kind) -> Int32? {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        DemoPeer.serve(fds[1], kind)
        return fds[0]
    }
}

final class DemoPeer: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "terminess.demo")
    private static var peers: [ObjectIdentifier: DemoPeer] = [:]
    private static let states = Dictionary(uniqueKeysWithValues: DemoMachine.Kind.allCases.map { ($0, DemoState($0)) })

    private let conn: Connection
    private let kind: DemoMachine.Kind
    private var state: DemoState { DemoPeer.states[kind]! }
    private var attached: String?
    private var line = ""
    private var followingTranscript: String?

    private init(fd: Int32, kind: DemoMachine.Kind) {
        conn = Connection(readFD: fd, queue: DemoPeer.queue)
        self.kind = kind
    }

    static func serve(_ fd: Int32, _ kind: DemoMachine.Kind) {
        queue.async {
            let p = DemoPeer(fd: fd, kind: kind)
            let key = ObjectIdentifier(p)
            peers[key] = p
            p.conn.onFrame = { [weak p] f in p?.handle(f) }
            p.conn.onClose = { peers[key] = nil }
            p.conn.start()
        }
    }

    private func handle(_ f: Wire.Frame) {
        let s = state
        switch f.kind {
        case .input:
            guard let id = attached else { return }
            typed(f.payload, in: id)
            return
        case .output, .response:
            return
        case .control:
            break
        }
        guard let m = f.message else { return }
        switch m.op {
        case "hello": conn.send(Message(op: "hello", version: Wire.version, host: kind.name))
        case "list": conn.send(Message(op: "sessions", sessions: s.infos))
        case "projects": conn.send(Message(op: "projects", projects: s.projects))
        case "history": conn.send(Message(op: "history", history: s.history))
        case "models": conn.send(Message(op: "models", args: s.models, code: s.models.isEmpty ? 0 : 1))
        case "register-push", "unregister-push", "resize", "detach": conn.send(Message(op: "ok"))
        case "create":
            let id = s.newShell(cwd: m.cwd)
            conn.send(Message(op: "created", id: id))
        case "attach":
            guard let id = m.id, let session = s.sessions[id] else { conn.send(Message(op: "error", message: "no session")); return }
            attached = id
            conn.send(Message(op: "attached", id: id, cols: 60, rows: 30))
            conn.send(Wire.Frame(.output, Array(session.screen.utf8)))
            conn.send(Message(op: "replayed", id: id))
            conn.send(Message(op: "info", id: id, foreground: ForegroundInfo(command: session.info.command, cwd: session.info.cwd,
                                                                              args: [session.info.command], started: session.info.created,
                                                                              pid: 1, shellPid: 1)))
            if let p = session.info.permission { conn.send(Message(op: "permission", id: id, permission: p)) }
            if let q = session.info.question { conn.send(Message(op: "question", id: id, question: q)) }
        case "transcript":
            guard let id = m.id, let session = s.sessions[id] else { return }
            followingTranscript = id
            conn.send(Message(op: "transcript", id: id, code: 0, items: session.items))
        case "decide":
            guard let id = m.id, let session = s.sessions[id], session.info.permission != nil else { conn.send(Message(op: "ok")); return }
            s.decide(id, m.message ?? "deny")
            conn.send(Message(op: "ok"))
            broadcast(id)
        case "answer":
            guard let id = m.id, s.sessions[id]?.info.question != nil else { conn.send(Message(op: "ok")); return }
            s.answer(id, m.message ?? "")
            conn.send(Message(op: "ok"))
            broadcast(id)
        case "kill":
            if let id = m.id { s.sessions[id] = nil }
            conn.send(Message(op: "ok", id: m.id))
        case "upload":
            conn.send(Message(op: m.code == 1 ? "uploaded" : "ok", message: "\(s.home)/Downloads/\(m.name ?? "file")"))
        default:
            conn.send(Message(op: "error", message: "The demo machine doesn't do that."))
        }
    }

    private func typed(_ bytes: [UInt8], in id: String) {
        guard let session = state.sessions[id] else { return }
        for b in bytes {
            switch b {
            case 13, 10:
                let text = line.trimmingCharacters(in: .whitespaces)
                line = ""
                conn.send(Wire.Frame(.output, Array("\r\n".utf8)))
                guard !text.isEmpty else { break }
                if session.info.command == "zsh" {
                    conn.send(Wire.Frame(.output, Array("This is the demo machine, so commands don't run here.\r\n\u{1B}[90m~/code\u{1B}[0m % ".utf8)))
                } else {
                    state.reply(id, to: text)
                    conn.send(Wire.Frame(.output, Array("\u{1B}[90mDemo reply added in Chat.\u{1B}[0m\r\n".utf8)))
                    broadcast(id)
                }
            case 127, 8:
                if !line.isEmpty { line.removeLast(); conn.send(Wire.Frame(.output, [8, 32, 8])) }
            case 0x1B:
                break
            default:
                if b >= 32 { line.append(Character(UnicodeScalar(b))); conn.send(Wire.Frame(.output, [b])) }
            }
        }
    }

    private func broadcast(_ id: String) {
        guard let session = state.sessions[id] else { return }
        for p in DemoPeer.peers.values where p.kind == kind {
            if p.followingTranscript == id { p.conn.send(Message(op: "transcript", id: id, code: 0, items: session.items)) }
            if p.attached == id {
                p.conn.send(Message(op: "permission", id: id, permission: session.info.permission))
                p.conn.send(Message(op: "question", id: id, question: session.info.question))
            }
        }
    }
}

final class DemoState {
    struct Session { var info: SessionInfo; var items: [TranscriptItem]; var screen: String }
    var sessions: [String: Session] = [:]
    private(set) var projects: [ProjectInfo] = []
    private(set) var history: [HistoryItem] = []
    private(set) var models: [String] = []
    let home: String
    private var shells = 0

    init(_ kind: DemoMachine.Kind) {
        home = kind == .mac ? "/Users/demo" : "/home/demo"
        let now = Date().timeIntervalSince1970
        switch kind {
        case .mac: mac(now)
        case .pc: pc(now)
        case .server: server(now)
        }
    }

    private func items(_ kinds: [TranscriptItem.Kind]) -> [TranscriptItem] { kinds.enumerated().map { TranscriptItem(id: $0.offset, kind: $0.element) } }

    private func mac(_ now: Double) {
        var claude = SessionInfo(id: "demo-claude", name: "1", command: "claude", cwd: "/Users/demo/code/brightcart",
                                 created: now - 1800, clients: 1)
        claude.title = "\u{2733} Checkout discount codes"
        claude.active = now - 40
        sessions[claude.id] = Session(info: claude, items: items([
            .user("Add discount codes to checkout. SAVE10 takes 10% off the subtotal before shipping, codes are case-insensitive, and an unknown code is rejected with a clear error. Add tests and run them."),
            .tool(name: "Read", summary: "src/cart.js", detail: "src/cart.js", result: "export function total(items) { ... }"),
            .tool(name: "Write", summary: "src/discounts.js", detail: "src/discounts.js", result: "Wrote 30 lines"),
            .tool(name: "Edit", summary: "src/cart.js", detail: "src/cart.js", result: "Added 6 lines, removed 2"),
            .tool(name: "Bash", summary: "npm test", detail: "npm test", result: "# pass 15\n# fail 0"),
            .assistant("""
                Discount codes now work at checkout. `npm test` runs all 15 tests and they pass: the 5 that were already there and 10 new ones.

                **What changed**
                - `src/discounts.js` (new) holds the codes (only `SAVE10` for now) and the lookup. Codes are case-insensitive.
                - `src/cart.js`: `total(items, code)` takes the discount off the subtotal, then adds shipping.
                - `test/discounts.test.js` (new) covers the maths, rounding, an empty basket and unknown codes.

                **One decision for you:** free shipping is judged on the discounted subtotal, so a £50 basket with SAVE10 now pays shipping. Say if you'd rather judge it before the discount.
                """),
        ]), screen: """
            \u{1B}]0;\u{2733} Checkout discount codes\u{07}\u{1B}[90m~/code/brightcart\u{1B}[0m % claude\r
            \r
            \u{1B}[1m> \u{1B}[0mAdd discount codes to checkout...\r
            \r
            \u{1B}[33m\u{25CF}\u{1B}[0m Write(src/discounts.js)\r
            \u{1B}[33m\u{25CF}\u{1B}[0m Update(src/cart.js)  \u{1B}[32m+6\u{1B}[0m \u{1B}[31m-2\u{1B}[0m\r
            \u{1B}[33m\u{25CF}\u{1B}[0m Bash(npm test)\r
            \u{1B}[90m  # pass 15   # fail 0\u{1B}[0m\r
            \r
            Discount codes now work at checkout. All 15 tests pass.\r
            \r
            \u{1B}[90m(This is the demo machine. Type a message to see how replies appear.)\u{1B}[0m\r
            \r
            """)

        var codex = SessionInfo(id: "demo-codex", name: "2", command: "codex", cwd: "/Users/demo/code/ledger-api",
                                created: now - 900, clients: 0)
        codex.title = "Add transaction CSV export"
        codex.active = now - 10
        codex.attention = true
        codex.asking = true
        codex.permission = PermissionInfo(id: "demo-perm", tool: "Bash", summary: "python3 -m unittest -v", canAlways: true)
        sessions[codex.id] = Session(info: codex, items: items([
            .user("Add a CSV export of all transactions, newest first, with a header row. Add tests and run them."),
            .assistant("I'll add `Ledger.export_csv()` next to `all()`, keep the newest-first order, and cover the header, ordering and escaping in tests."),
            .tool(name: "Edit", summary: "ledger/store.py, tests/test_store.py", detail: "", result: "Success"),
            .assistant("The export and four tests are written. I need your approval to run the test suite."),
        ]), screen: """
            \u{1B}]0;Add transaction CSV export\u{07}\u{1B}[90m~/code/ledger-api\u{1B}[0m % codex\r
            \r
            \u{1B}[1m\u{203A} \u{1B}[0mAdd a CSV export of all transactions...\r
            \r
            Edited ledger/store.py (+17) and tests/test_store.py (+39)\r
            \r
            \u{1B}[33mAllow command?\u{1B}[0m python3 -m unittest -v\r
            \r
            """)
        projects = [ProjectInfo(path: "/Users/demo/code/brightcart", used: now - 40), ProjectInfo(path: "/Users/demo/code/ledger-api", used: now - 10)]
        history = [
            HistoryItem(id: "h1", agent: "claude", cwd: "/Users/demo/code/brightcart", title: "Add a test that an empty basket costs nothing", used: now - 3600),
            HistoryItem(id: "h2", agent: "claude", cwd: "/Users/demo/code/brightcart", title: "How is shipping worked out in this repo?", used: now - 7200),
            HistoryItem(id: "h3", agent: "codex", cwd: "/Users/demo/code/ledger-api", title: "Add pagination to Ledger.all", used: now - 5400),
            HistoryItem(id: "h4", agent: "claude", cwd: "/Users/demo/code/ledger-api", title: "Add a monthly_totals method to Ledger", used: now - 86400),
        ]
    }

    private func pc(_ now: Double) {
        var claude = SessionInfo(id: "demo-pc-claude", name: "1", command: "claude", cwd: "/home/demo/code/photo-sorter",
                                 created: now - 2400, clients: 0)
        claude.title = "\u{2733} Sort the photo inbox"
        claude.active = now - 25
        claude.attention = true
        claude.asking = true
        claude.question = QuestionInfo(id: "demo-q", text: "63 photos are exact copies of ones already sorted. What should I do with them?",
                                       choices: ["Move them to a duplicates folder", "Delete them", "Keep both copies"])
        sessions[claude.id] = Session(info: claude, items: items([
            .user("Sort ~/Pictures/inbox into year and month folders by the date each photo was taken, and deal with duplicates."),
            .tool(name: "Bash", summary: "exiftool -json -DateTimeOriginal ~/Pictures/inbox", detail: "", result: "1,284 files"),
            .tool(name: "Write", summary: "sort_photos.py", detail: "sort_photos.py", result: "Wrote 74 lines"),
            .tool(name: "Bash", summary: "python3 sort_photos.py --dry-run", detail: "", result: "1,284 photos, 41 folders, 63 duplicates"),
            .assistant("""
                The sorter is written and a dry run looks right: **1,284 photos** go into **41 month folders**, from 2014 to 2026. Photos without a date go into `undated/`.

                Nothing has moved yet. Before I run it for real, one question about duplicates.
                """),
        ]), screen: """
            \u{1B}]0;\u{2733} Sort the photo inbox\u{07}\u{1B}[90m~/code/photo-sorter\u{1B}[0m $ claude\r
            \r
            \u{1B}[1m> \u{1B}[0mSort ~/Pictures/inbox into year and month folders...\r
            \r
            \u{1B}[33m\u{25CF}\u{1B}[0m Write(sort_photos.py)\r
            \u{1B}[33m\u{25CF}\u{1B}[0m Bash(python3 sort_photos.py --dry-run)\r
            \u{1B}[90m  1,284 photos, 41 folders, 63 duplicates\u{1B}[0m\r
            \r
            \u{1B}[33mWhat should I do with the 63 duplicates?\u{1B}[0m\r
            \r
            """)
        projects = [ProjectInfo(path: "/home/demo/code/photo-sorter", used: now - 25), ProjectInfo(path: "/home/demo/dotfiles", used: now - 90000)]
        history = [
            HistoryItem(id: "p1", agent: "codex", cwd: "/home/demo/code/photo-sorter", title: "Add a --dry-run flag to the sorter", used: now - 9000),
            HistoryItem(id: "p2", agent: "claude", cwd: "/home/demo/dotfiles", title: "Set up the new keyboard layout in sway", used: now - 172800),
        ]
        models = ["qwen3-coder:30b", "gpt-oss:20b", "llama3.2:3b"]
    }

    private func server(_ now: Double) {
        var claude = SessionInfo(id: "demo-srv-claude", name: "1", command: "claude", cwd: "/home/demo/srv/payments-api",
                                 created: now - 3000, clients: 0)
        claude.title = "\u{2733} Retry failed card payments"
        claude.active = now - 300
        sessions[claude.id] = Session(info: claude, items: items([
            .user("Retry failed card payments with backoff, then have Codex review it before we commit."),
            .tool(name: "Write", summary: "src/retry.ts", detail: "src/retry.ts", result: "Wrote 52 lines"),
            .tool(name: "Bash", summary: "npm test", detail: "npm test", result: "22 passing"),
            .tool(name: "Bash", summary: "pair review --from claude", detail: "pair review --from claude", result: "Codex: 2 findings"),
            .tool(name: "Edit", summary: "src/retry.ts", detail: "src/retry.ts", result: "Added 9 lines, removed 3"),
            .assistant("""
                Retries are in: a failed card payment is tried up to three more times, waiting longer each time. All 22 tests pass.

                **Codex reviewed it** and found two things, both fixed now:
                - **Declined cards were retried.** A decline like `do_not_honor` won't succeed on a second try, so `src/retry.ts` now retries only timeouts and network errors.
                - **No jitter.** After an outage every payment would retry at the same moment; each wait now has a random spread.

                Ready to commit when you are.
                """),
        ]), screen: """
            \u{1B}]0;\u{2733} Retry failed card payments\u{07}\u{1B}[90m~/srv/payments-api\u{1B}[0m $ claude\r
            \r
            \u{1B}[1m> \u{1B}[0mRetry failed card payments with backoff...\r
            \r
            \u{1B}[33m\u{25CF}\u{1B}[0m Write(src/retry.ts)\r
            \u{1B}[33m\u{25CF}\u{1B}[0m Bash(pair review --from claude)\r
            \u{1B}[90m  Codex: 2 findings\u{1B}[0m\r
            \u{1B}[33m\u{25CF}\u{1B}[0m Update(src/retry.ts)  \u{1B}[32m+9\u{1B}[0m \u{1B}[31m-3\u{1B}[0m\r
            \r
            Retries are in and Codex's two findings are fixed.\r
            \r
            """)

        var codex = SessionInfo(id: "demo-srv-codex", name: "2", command: "codex", cwd: "/home/demo/srv/web",
                                created: now - 600, clients: 0)
        codex.title = "Upgrade to Node 24"
        codex.active = now - 5
        codex.busy = true
        sessions[codex.id] = Session(info: codex, items: items([
            .user("Upgrade the web app to Node 24 and fix whatever breaks."),
            .tool(name: "Edit", summary: "package.json, .nvmrc", detail: "", result: "Success"),
            .tool(name: "Shell", summary: "npm ci && npm run build", detail: "", result: "Running"),
        ]), screen: """
            \u{1B}]0;Upgrade to Node 24\u{07}\u{1B}[90m~/srv/web\u{1B}[0m $ codex\r
            \r
            \u{1B}[1m\u{203A} \u{1B}[0mUpgrade the web app to Node 24...\r
            \r
            Running npm ci && npm run build\r
            \r
            """)
        projects = [ProjectInfo(path: "/home/demo/srv/payments-api", used: now - 300), ProjectInfo(path: "/home/demo/srv/web", used: now - 5)]
        history = [
            HistoryItem(id: "s1", agent: "claude", cwd: "/home/demo/srv/payments-api", title: "Why did last night's deploy roll back?", used: now - 20000),
            HistoryItem(id: "s2", agent: "codex", cwd: "/home/demo/srv/payments-api", title: "Rotate the webhook signing secret", used: now - 100000),
        ]
    }

    var infos: [SessionInfo] { sessions.values.map(\.info).sorted { ($0.active ?? 0) > ($1.active ?? 0) } }

    func newShell(cwd: String?) -> String {
        shells += 1
        let id = "demo-shell-\(shells)"
        var info = SessionInfo(id: id, name: "\(sessions.count + 1)", command: "zsh", cwd: cwd ?? home + "/code",
                               created: Date().timeIntervalSince1970, clients: 1)
        info.active = Date().timeIntervalSince1970
        sessions[id] = Session(info: info, items: [], screen: "\u{1B}[90mThe demo machine: try typing, but commands don't run here.\u{1B}[0m\r\n\u{1B}[90m~/code\u{1B}[0m % ")
        return id
    }

    func answer(_ id: String, _ text: String) {
        guard var s = sessions[id] else { return }
        s.info.question = nil
        s.info.asking = false
        s.info.attention = false
        s.items.append(TranscriptItem(id: s.items.count, kind: .user(text)))
        s.items.append(TranscriptItem(id: s.items.count, kind: .assistant(
            "Got it. This is the demo machine, so nothing moves here; on your own machine the agent would carry on with that answer.")))
        s.info.active = Date().timeIntervalSince1970
        sessions[id] = s
    }

    func reply(_ id: String, to text: String) {
        guard var s = sessions[id] else { return }
        s.items.append(TranscriptItem(id: s.items.count, kind: .user(text)))
        s.items.append(TranscriptItem(id: s.items.count, kind: .assistant(
            "This is the demo machine, so nothing runs here. On your own Mac or server, \(s.info.command == "codex" ? "Codex" : "Claude Code") would now work on that, and you'd follow it here as it goes.")))
        s.info.active = Date().timeIntervalSince1970
        sessions[id] = s
    }

    func decide(_ id: String, _ answer: String) {
        guard var s = sessions[id] else { return }
        s.info.permission = nil
        s.info.asking = false
        s.info.attention = false
        if answer == "deny" {
            s.items.append(TranscriptItem(id: s.items.count, kind: .assistant("Understood, I won't run the tests. The export is written; run `python3 -m unittest -v` when you're ready.")))
        } else {
            s.items.append(TranscriptItem(id: s.items.count, kind: .tool(name: "Shell", summary: "python3 -m unittest -v", detail: "", result: "Ran 14 tests in 0.001s\n\nOK")))
            s.items.append(TranscriptItem(id: s.items.count, kind: .assistant("All 14 tests pass. `Ledger.export_csv()` returns every transaction newest first, with a header row and proper CSV escaping.")))
        }
        sessions[id] = s
    }
}
