import Foundation
import TermHost

@MainActor
final class HostConnection: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    let hostID: UUID
    @Published var state: State = .idle
    @Published var sessions: [SessionInfo] = []
    @Published var projects: [ProjectInfo] = []
    private(set) var ssh: SSHConnection?
    private var control: ControlChannel?
    private var poller: Task<Void, Never>?

    init(hostID: UUID) { self.hostID = hostID }

    var host: SavedHost? { HostStore.shared.host(hostID) }
    var stdioCommand: String { "\(host?.terminessd ?? "~/.local/bin/terminessd") stdio" }
    var isConnected: Bool { state == .connected && ssh != nil }

    func connect() async {
        guard let host else { return }
        if ssh != nil, control?.isOpen == true { await refresh(); return }
        if state == .connecting { return }
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
            state = .connected
            await refresh()
            await registerPush()
        } catch {
            ssh = nil
            state = .failed(error.localizedDescription)
        }
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
    }

    func loadProjects() async {
        if let reply = await request(Message(op: "projects")), let p = reply.projects { projects = p }
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
            guard let reply = await request(m) else { throw SSHError.channel("The upload stopped; check the connection.") }
            if reply.op == "error" { throw SSHError.channel(reply.message ?? "upload failed") }
            offset = end
            progress(Double(offset) / Double(max(1, data.count)))
            if last, reply.op == "uploaded", let path = reply.message { return path }
        } while offset < data.count
        throw SSHError.channel("The machine didn't confirm the upload.")
    }

    func registerPush() async {
        guard let token = PushTokens.shared.token else { return }
        _ = await request(Message(op: "register-push", name: hostID.uuidString, message: PushTokens.environment, token: token))
    }

    func attachment(to target: HostAttachment.Target, cols: Int, rows: Int) async throws -> HostAttachment {
        guard let ssh else { throw SSHError.channel("not connected") }
        let fd = try await ssh.exec(stdioCommand)
        return HostAttachment(readFD: fd, writeFD: fd, target: target, cols: cols, rows: rows, queue: .main)
    }

    func transcriptChannel(for id: String) async throws -> Connection {
        guard let ssh else { throw SSHError.channel("not connected") }
        let fd = try await ssh.exec(stdioCommand)
        let conn = Connection(readFD: fd, queue: .main)
        conn.start()
        conn.send(Message(op: "transcript", id: id))
        return conn
    }

    private func request(_ m: Message) async -> Message? {
        guard let ssh else { return nil }
        if control?.isOpen != true {
            guard let fd = try? await ssh.exec(stdioCommand) else {
                state = .failed("Lost the connection to \(host?.name ?? "the machine").")
                self.ssh = nil
                return nil
            }
            control = ControlChannel(fd: fd)
        }
        return await control?.request(m)
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

    func request(_ m: Message) async -> Message? {
        guard isOpen else { return nil }
        return await withCheckedContinuation { cont in
            waiting.append(cont)
            connection.send(m)
        }
    }

    func close() {
        connection.close()
    }
}
