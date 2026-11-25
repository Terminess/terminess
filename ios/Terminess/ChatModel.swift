import Foundation
import TermHost
import TermTranscript

@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []
    @Published private(set) var loaded = false
    private var channel: Connection?
    private var following: (id: String, host: HostConnection)?

    func follow(session id: String, on host: HostConnection) async {
        stop()
        following = (id, host)
        await open()
    }

    private var opening = false

    private func open() async {
        guard let f = following, channel == nil, !opening else { return }
        let id = f.id
        opening = true
        let opened = try? await f.host.transcriptChannel(for: id)
        opening = false
        guard let conn = opened else { retry(id); return }
        guard following?.id == id, channel == nil else { conn.close(); return }
        channel = conn
        conn.onFrame = { [weak self] frame in
            MainActor.assumeIsolated {
                guard let self, let m = frame.message, m.op == "transcript", let incoming = m.items else { return }
                let from = min(max(0, m.code ?? 0), self.items.count)
                self.items = Array(self.items.prefix(from)) + incoming
                self.loaded = true
            }
        }
        conn.onClose = { [weak self, weak conn] in
            MainActor.assumeIsolated {
                guard let self, self.channel === conn else { return }
                self.channel = nil
                self.retry(id)
            }
        }
    }

    private func retry(_ id: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.following?.id == id else { return }
            await self.open()
        }
    }

    func stop() {
        following = nil
        let c = channel
        channel = nil
        c?.close()
    }
}
