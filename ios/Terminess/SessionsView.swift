import SwiftUI
import TermHost

struct SessionsView: View {
    let hostID: UUID
    @StateObject private var connection: HostConnection
    @State private var opened: SessionTarget?

    init(hostID: UUID) {
        self.hostID = hostID
        _connection = StateObject(wrappedValue: HostConnection(hostID: hostID))
    }

    var body: some View {
        List {
            switch connection.state {
            case .idle, .connecting:
                HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }
            case .failed(let message):
                Section {
                    Text(message).foregroundStyle(.secondary)
                    Button("Try Again") { Task { connection.disconnect(); await connection.connect() } }
                }
            case .connected:
                Section {
                    if connection.sessions.isEmpty {
                        Text("Nothing running. Start a shell, or open Terminess on this machine.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(connection.sessions, id: \.id) { s in
                        Button { opened = SessionTarget(id: s.id, title: title(s)) } label: { row(s) }
                            .swipeActions {
                                Button("End", role: .destructive) { Task { await connection.kill(s.id) } }
                            }
                    }
                } header: {
                    Text("Running")
                }
            }
        }
        .navigationTitle(connection.host?.name ?? "Machine")
        .refreshable { await connection.connect() }
        .toolbar {
            Button { opened = SessionTarget(id: nil, title: "New shell") } label: { Image(systemName: "plus") }
                .disabled(connection.state != .connected)
        }
        .task { await connection.connect() }
        .fullScreenCover(item: $opened, onDismiss: { Task { await connection.refresh() } }) { target in
            SessionView(connection: connection, target: target)
        }
        .onDisappear { connection.disconnect() }
    }

    private func title(_ s: SessionInfo) -> String {
        switch s.command {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return s.command
        }
    }

    private func row(_ s: SessionInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ["claude", "codex"].contains(s.command) ? "sparkle" : "terminal")
                .foregroundStyle(s.command == "claude" ? Color.orange : (s.command == "codex" ? Color.blue : Color.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(s)).foregroundStyle(.primary)
                Text([shortPath(s.cwd), s.clients > 0 ? "open on \(s.clients) device\(s.clients == 1 ? "" : "s")" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func shortPath(_ p: String) -> String? {
        guard !p.isEmpty else { return nil }
        let parts = p.split(separator: "/")
        return parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : p
    }
}

struct SessionTarget: Identifiable {
    let id: String?
    let title: String
    var identity: String { id ?? "new" }
}
