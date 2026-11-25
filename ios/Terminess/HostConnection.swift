import Foundation
import TermHost

@MainActor
final class HostConnection: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    let hostID: UUID
    @Published var state: State = .idle
    @Published var sessions: [SessionInfo] = []
    @Published var platform: String?
    var symbol: String {
        switch platform {
        case "macos": return "laptopcomputer"
        case "linux", "windows": return "server.rack"
        default: return "desktopcomputer"
        }
    }
    @Published var projects: [ProjectInfo] = []
    @Published var models: [String]?
    @Published var history: [HistoryItem] = []
    @Published var reminders: [ReminderInfo] = []
    private(set) var ssh: SSHConnection?
    private var control: ControlChannel?
    private var poller: Task<Void, Never>?

    init(hostID: UUID) { self.hostID = hostID }

    var host: SavedHost? { HostStore.shared.host(hostID) }
    var stdioCommand: String { RemotePath.shellQuoted(host?.terminessd ?? "~/.local/bin/terminessd") + " stdio" }
    var isConnected: Bool { state == .connected && (ssh != nil || Self.demoSocket != nil || isDemo) }
    var isDemo: Bool { DemoMachine.isDemo(host) }

    static var demoSocket: String? {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["TERMINESS_DEMO_SOCKET"]
        #else
        return nil
        #endif
    }

    private func channel() async throws -> Int32 {
        if let kind = DemoMachine.kind(host) {
            guard let fd = DemoMachine.channel(kind) else { throw SSHError.channel("demo machine unavailable") }
            return fd
        }
        if let path = Self.demoSocket {
            guard let fd = UnixSocket.connect(path) else { throw SSHError.channel("no demo socket at \(path)") }
            return fd
        }
        guard let ssh else { throw SSHError.channel("not connected") }
        return try await ssh.exec(stdioCommand)
    }

    private var connecting: Task<Void, Never>?
    var suspect = false

    func connect() async {
        if let pending = connecting { await pending.value; return }
        let task = Task { await establish() }
        connecting = task
        await task.value
        connecting = nil
    }

    private func establish() async {
        guard let host, !AppLock.shared.locked else { return }
        if ssh != nil, control?.isOpen == true, suspect {
            suspect = false
            if await request(Message(op: "list"), timeout: 4) == nil { disconnect() }
        }
        if ssh != nil, control?.isOpen == true { await refresh(); return }
        if Self.demoSocket != nil || isDemo {
            state = .connected
            await refresh()
            await loadPlatform()
            return
        }
        ssh?.disconnect()
        ssh = nil
        control = nil
        state = .connecting
        do {
            let key = try DeviceKey.load()
            let id = hostID
            ssh = try await SSHConnection.connect(host: host.address, port: host.port, user: host.user, key: key,
                                                  knownHostKey: host.hostKey) { seen in
                Task { @MainActor in
                    if var h = HostStore.shared.host(id) { h.hostKey = seen; HostStore.shared.save(h) }
                }
            }
            if AppLock.shared.locked { disconnect(); state = .idle; return }
            state = .connected
            await refresh()
            await loadPlatform()
            await registerPush()
        } catch {
            ssh = nil
            state = .failed(error.localizedDescription)
        }
    }

    func loadPlatform() async {
        guard let reply = await request(Message(op: "hello", version: Wire.version)), reply.op == "hello" else { return }
        if platform != reply.platform { platform = reply.platform }
    }

    func disconnect() {
        poller?.cancel()
        poller = nil
        control?.close()
        control = nil
        ssh?.disconnect()
        ssh = nil
        state = .idle
    }

    func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.isConnected { await self.refresh() }
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    func refresh() async {
        guard let reply = await request(Message(op: "list")) else {
            if ssh != nil, state == .connected {
                state = .failed("Connected, but couldn't run terminessd at \(host?.terminessd ?? "~/.local/bin/terminessd"). Install it on the machine with: terminessd service install")
            }
            return
        }
        if reply.op == "sessions" { sessions = reply.sessions ?? [] }
        if let r = await request(Message(op: "reminders")), r.op == "reminders" { reminders = r.reminders ?? [] }
    }

    func actOnReminder(_ id: String) async -> String? {
        guard let reply = await request(Message(op: "reminder-act", id: id)) else { return nil }
        reminders.removeAll { $0.id == id }
        return reply.op == "reminder-acted" ? reply.id : nil
    }

    func dismissReminder(_ id: String) async {
        _ = await request(Message(op: "reminder-dismiss", id: id))
        reminders.removeAll { $0.id == id }
    }

    func loadProjects() async {
        if let reply = await request(Message(op: "projects")), let p = reply.projects { projects = p }
    }

    func loadModels() async {
        guard let reply = await request(Message(op: "models")), reply.op == "models" else { models = nil; return }
        models = reply.code == 1 ? (reply.args ?? []) : nil
    }

    func agentModels(_ agent: String) async -> [AgentModel] {
        guard let reply = await request(Message(op: "agent-models", name: agent)), reply.op == "agent-models" else { return [] }
        return reply.agentModels ?? []
    }

    func modelRoles() async -> ModelRoles? {
        guard let reply = await request(Message(op: "model-roles")), reply.op == "model-roles" else { return nil }
        return reply.roles
    }

    func setModelRole(agent: String, role: String, model: String) async -> ModelRoles? {
        guard let reply = await request(Message(op: "set-model-role", id: role, name: agent, message: model)),
              reply.op == "model-roles" else { return nil }
        return reply.roles
    }

    func loadHistory() async {
        if let reply = await request(Message(op: "history")), let h = reply.history { history = h }
    }

    func kill(_ id: String) async {
        _ = await request(Message(op: "kill", id: id))
        sessions.removeAll { $0.id == id }
    }

    func upload(_ data: Data, name: String, progress: @escaping (Double) -> Void) async throws -> String {
        let chunk = 192 * 1024
        var offset = 0
        repeat {
            let end = min(offset + chunk, data.count)
            let last = end >= data.count
            let m = Message(op: "upload", name: name, code: last ? 1 : 0, data: data[offset..<end].base64EncodedString())
            guard let reply = await request(m, timeout: 90) else { throw SSHError.channel("The upload stopped; check the connection.") }
            if reply.op == "error" { throw SSHError.channel(reply.message ?? "upload failed") }
            offset = end
            progress(Double(offset) / Double(max(1, data.count)))
            if last, reply.op == "uploaded", let path = reply.message { return path }
        } while offset < data.count
        throw SSHError.channel("The machine didn't confirm the upload.")
    }

    func registerPush() async {
        guard let token = PushTokens.shared.token else { return }
        guard let base = PushTokens.relayBase else { await unregisterPush(); return }
        var m = Message(op: "register-push", name: hostID.uuidString, message: PushTokens.environment, token: token,
                        credential: PushTokens.shared.credential,
                        key: DeviceKey.authorizedKeyLine().split(separator: " ").dropFirst().first.map(String.init))
        if base != PushTokens.terminessRelay { m.relay = base }
        _ = await request(m)
    }

    func decide(session: String, requestID: String, answer: String) async {
        _ = await request(Message(op: "decide", id: session, name: requestID, message: answer))
        await refresh()
    }

    func answer(session: String, questionID: String, text: String) async {
        _ = await request(Message(op: "answer", id: session, name: questionID, message: text))
        await refresh()
    }

    func unregisterPush() async {
        guard isConnected, let token = PushTokens.shared.token else { return }
        _ = await request(Message(op: "unregister-push", token: token))
    }

    func attachment(to target: HostAttachment.Target, cols: Int, rows: Int) async throws -> HostAttachment {
        let fd = try await channel()
        let a = HostAttachment(readFD: fd, writeFD: fd, target: target, cols: cols, rows: rows, queue: .main)
        a.clientKind = "iphone"
        a.deviceName = DeviceName.current
        return a
    }

    func transcriptChannel(for id: String) async throws -> Connection {
        let fd = try await channel()
        let conn = Connection(readFD: fd, queue: .main)
        conn.start()
        conn.send(Message(op: "transcript", id: id))
        return conn
    }

    private func request(_ m: Message, timeout: Double = 15) async -> Message? {
        guard ssh != nil || Self.demoSocket != nil || isDemo else { return nil }
        if control?.isOpen != true {
            guard let fd = try? await channel() else {
                state = .failed("Lost the connection to \(host?.name ?? "the machine").")
                self.ssh = nil
                return nil
            }
            control = ControlChannel(fd: fd)
        }
        return await control?.request(m, timeout: timeout)
    }
}

@MainActor
final class ControlChannel {
    private let connection: Connection
    private var waiting: [CheckedContinuation<Message?, Never>] = []
    private(set) var isOpen = true

    init(fd: Int32) {
        connection = Connection(readFD: fd, queue: .main)
        connection.onFrame = { [weak self] frame in
            MainActor.assumeIsolated {
                guard let self, let m = frame.message, !self.waiting.isEmpty else { return }
                self.answeredCount += 1
                self.waiting.removeFirst().resume(returning: m)
            }
        }
        connection.onClose = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isOpen = false
                let all = self.waiting
                self.waiting.removeAll()
                all.forEach { $0.resume(returning: nil) }
            }
        }
        connection.start()
    }

    func request(_ m: Message, timeout: Double = 15) async -> Message? {
        guard isOpen else { return nil }
        let sent = sentCount + 1
        sentCount = sent
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, self.answeredCount < sent else { return }
                self.connection.close()
            }
        }
        return await withCheckedContinuation { cont in
            waiting.append(cont)
            connection.send(m)
        }
    }
    private var sentCount = 0
    private var answeredCount = 0

    func close() {
        connection.close()
    }
}
