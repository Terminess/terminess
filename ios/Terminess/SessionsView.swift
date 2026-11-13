import SwiftUI
import TermHost

struct SessionsView: View {
    let hostID: UUID
    @StateObject private var connection: HostConnection
    @ObservedObject private var router = Router.shared
    @ObservedObject private var push = PushTokens.shared
    @State private var opened: SessionTarget?
    @State private var starting = false
    @Environment(\.scenePhase) private var phase

    init(hostID: UUID) {
        self.hostID = hostID
        _connection = StateObject(wrappedValue: HostConnection(hostID: hostID))
    }

    private var groups: [(folder: String, sessions: [SessionInfo])] {
        let byFolder = Dictionary(grouping: connection.sessions) { $0.cwd }
        return byFolder.map { ($0.key, $0.value.sorted { ($0.active ?? 0) > ($1.active ?? 0) }) }
            .sorted { ($0.sessions.first?.active ?? 0) > ($1.sessions.first?.active ?? 0) }
    }

    var body: some View {
        List {
            switch connection.state {
            case .idle, .connecting where connection.sessions.isEmpty:
                HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }
            case .failed(let message):
                Section {
                    Text(message).foregroundStyle(.secondary)
                    Button("Try Again") { Task { connection.disconnect(); await connection.connect() } }
                }
            default:
                if connection.sessions.isEmpty {
                    Section {
                        Text("Nothing running. Start Claude Code, Codex or a shell with the + button.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groups, id: \.folder) { group in
                    Section(header: Text(SessionText.folderName(group.folder))) {
                        ForEach(group.sessions, id: \.id) { s in
                            Button { opened = SessionTarget(session: s.id, title: SessionText.title(s)) } label: { SessionRow(session: s) }
                                .swipeActions {
                                    Button("End", role: .destructive) { Task { await connection.kill(s.id) } }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle(connection.host?.name ?? "Machine")
        .refreshable { await connection.connect() }
        .toolbar {
            Button { starting = true } label: { Image(systemName: "plus") }
                .disabled(!connection.isConnected)
        }
        .task {
            await connection.connect()
            connection.startPolling()
            openPending()
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await connection.connect() } }
        }
        .onChange(of: push.token) { _, _ in Task { await connection.registerPush() } }
        .onChange(of: router.pendingSession?.session) { _, _ in openPending() }
        .sheet(isPresented: $starting) {
            NewSessionView(connection: connection) { target in
                starting = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { opened = target }
            }
        }
        .fullScreenCover(item: $opened, onDismiss: { Task { await connection.refresh() } }) { target in
            SessionView(connection: connection, target: target)
        }
        .onDisappear {
            connection.stopPolling()
        }
    }

    private func openPending() {
        guard let p = router.pendingSession, p.host == hostID else { return }
        router.pendingSession = nil
        let s = connection.sessions.first { $0.id == p.session }
        opened = SessionTarget(session: p.session, title: s.map(SessionText.title) ?? "Session")
    }
}

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if session.busy == true {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: SessionText.isAgent(session) ? "sparkle" : "terminal")
                        .foregroundStyle(SessionText.tint(session))
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionText.title(session)).foregroundStyle(.primary).lineLimit(1)
                Text(SessionText.subtitle(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if session.attention == true {
                Circle().fill(Color.orange).frame(width: 9, height: 9)
            }
        }
    }
}

enum SessionText {
    static func isAgent(_ s: SessionInfo) -> Bool { s.command == "claude" || s.command == "codex" }

    static func agentName(_ s: SessionInfo) -> String? {
        s.command == "claude" ? "Claude Code" : (s.command == "codex" ? "Codex" : nil)
    }

    static func topic(_ s: SessionInfo) -> String {
        String((s.title ?? "").drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }

    static func title(_ s: SessionInfo) -> String {
        let t = topic(s)
        if let agent = agentName(s) { return t.isEmpty || t.lowercased() == agent.lowercased() ? agent : t }
        if ["zsh", "bash", "fish", "sh"].contains(s.command) { return "Shell" }
        return t.isEmpty ? s.command : t
    }

    static func subtitle(_ s: SessionInfo) -> String {
        var parts: [String] = []
        if let agent = agentName(s), title(s) != agent { parts.append(agent) }
        if s.busy == true { parts.append("working") }
        else if s.attention == true { parts.append("needs you") }
        else if let active = s.active { parts.append(relative(active)) }
        if s.clients > 0 { parts.append("open on \(s.clients) device\(s.clients == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    static func tint(_ s: SessionInfo) -> Color {
        s.command == "claude" ? .orange : (s.command == "codex" ? .blue : .secondary)
    }

    static func folderName(_ path: String) -> String {
        guard !path.isEmpty else { return "Unknown folder" }
        let home = HostHome.guess(path)
        if path == home { return "Home" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    static func relative(_ t: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }
}

enum HostHome {
    static func guess(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "home" || parts[0] == "Users" else { return "" }
        return "/" + parts[0] + "/" + parts[1]
    }
}
