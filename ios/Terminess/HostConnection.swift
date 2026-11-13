import Foundation
import TermHost

@MainActor
final class HostConnection: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    let hostID: UUID
    @Published var state: State = .idle
    @Published var sessions: [SessionInfo] = []
    private var ssh: SSHConnection?

    init(hostID: UUID) { self.hostID = hostID }

    var host: SavedHost? { HostStore.shared.host(hostID) }
    private var stdioCommand: String { "\(host?.terminessd ?? "~/.local/bin/terminessd") stdio" }

    func connect() async {
        guard let host, state != .connecting else { return }
        if ssh != nil { await refresh(); return }
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
        } catch {
            ssh = nil
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        ssh?.disconnect()
        ssh = nil
        state = .idle
    }

    func refresh() async {
        guard let reply = await request(Message(op: "list")) else {
            if ssh != nil {
                state = .failed("Connected, but couldn't run terminessd at \(host?.terminessd ?? "~/.local/bin/terminessd"). Install it on the server with: terminessd service install")
            }
            return
        }
        if reply.op == "sessions" { sessions = reply.sessions ?? [] }
        else if reply.op == "error" { state = .failed(reply.message ?? "terminessd error") }
    }

    func kill(_ id: String) async {
        _ = await request(Message(op: "kill", id: id))
        sessions.removeAll { $0.id == id }
    }

    func attachment(to target: HostAttachment.Target, cols: Int, rows: Int) async throws -> HostAttachment {
        guard let ssh else { throw SSHError.channel("not connected") }
        let fd = try await ssh.exec(stdioCommand)
        return HostAttachment(readFD: fd, writeFD: fd, target: target, cols: cols, rows: rows, queue: .main)
    }

    private func request(_ m: Message) async -> Message? {
        guard let ssh else { return nil }
        do {
            let fd = try await ssh.exec(stdioCommand)
            return await withCheckedContinuation { (cont: CheckedContinuation<Message?, Never>) in
                let conn = Connection(readFD: fd, queue: .main)
                var done = false
                func finish(_ reply: Message?) {
                    guard !done else { return }
                    done = true
                    cont.resume(returning: reply)
                    conn.close()
                }
                conn.onFrame = { frame in if let reply = frame.message { finish(reply) } }
                conn.onClose = {
                    finish(nil)
                }
                conn.start()
                conn.send(m)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
            }
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }
}
