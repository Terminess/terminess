import Foundation
import TermHost
import TermTranscript

@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []
    @Published private(set) var loaded = false
    private var channel: Connection?

    func follow(session id: String, on host: HostConnection) async {
        stop()
        guard let conn = try? await host.transcriptChannel(for: id) else { return }
        channel = conn
        conn.onFrame = { [weak self] frame in
            MainActor.assumeIsolated {
                guard let self, let m = frame.message, m.op == "transcript", let incoming = m.items else { return }
                let from = min(max(0, m.code ?? 0), self.items.count)
                self.items = Array(self.items.prefix(from)) + incoming
                self.loaded = true
            }
        }
        conn.onClose = { [weak self] in MainActor.assumeIsolated { self?.channel = nil } }
    }

    func stop() {
        channel?.close()
        channel = nil
    }
}
