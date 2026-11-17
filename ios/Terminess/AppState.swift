import SwiftUI
import TermHost

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var connections: [UUID: HostConnection] = [:]
    @Published var current: SessionTarget?
    @Published var drawerOpen = false
    var rowSwiping = false
    @Published var showSettings = false
    @Published var newHost: UUID?
    @Published var newProject: String?
    @Published var newAgent = "claude"
    private var poller: Task<Void, Never>?
    private var lastHistory = Date.distantPast

    func connection(_ id: UUID) -> HostConnection {
        if let c = connections[id] { return c }
        let c = HostConnection(hostID: id)
        connections[id] = c
        return c
    }

    var hosts: [SavedHost] { HostStore.shared.hosts }

    var running: [(host: SavedHost, session: SessionInfo)] {
        hosts.flatMap { h in (connections[h.id]?.sessions ?? []).map { (h, $0) } }
            .sorted { ($0.session.active ?? 0) > ($1.session.active ?? 0) }
    }

    var reminders: [(host: SavedHost, reminder: ReminderInfo)] {
        hosts.flatMap { h in (connections[h.id]?.reminders ?? []).map { (h, $0) } }
            .sorted { $0.reminder.due < $1.reminder.due }
    }

    func proceed(_ r: ReminderInfo, on hostID: UUID) async {
        let c = connection(hostID)
        if !c.isConnected { await c.connect() }
        guard let session = await c.actOnReminder(r.id) else { return }
        await c.refresh()
        open(SessionTarget(host: hostID, session: session, title: r.title))
    }

    func dismiss(_ r: ReminderInfo, on hostID: UUID) {
        Task { await connection(hostID).dismissReminder(r.id) }
    }

    var recent: [(host: SavedHost, item: HistoryItem)] {
        hosts.flatMap { h in (connections[h.id]?.history ?? []).map { (h, $0) } }
            .sorted { $0.item.used > $1.item.used }
    }

    func start() {
        for h in hosts { Task { await connection(h.id).connect() } }
        if newHost == nil { newHost = hosts.first?.id }
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                for h in self.hosts {
                    let c = self.connection(h.id)
                    if c.isConnected { await c.refresh() } else if case .idle = c.state { await c.connect() }
                }
                if Date().timeIntervalSince(self.lastHistory) > 60 { await self.loadHistory() }
            }
        }
    }

    func resume() {
        for h in hosts { Task { await connection(h.id).connect() } }
    }

    func loadHistory() async {
        lastHistory = Date()
        for h in hosts where connection(h.id).isConnected { await connection(h.id).loadHistory() }
    }

    func open(_ target: SessionTarget) {
        current = target
        withAnimation(.easeOut(duration: 0.22)) { drawerOpen = false }
    }

    func end(_ session: SessionInfo, on host: SavedHost) {
        if current?.session == session.id { current = nil }
        Task { await connection(host.id).kill(session.id) }
    }

    func newChat() {
        current = nil
        if newHost == nil || connections[newHost!] == nil { newHost = hosts.first?.id }
        withAnimation(.easeOut(duration: 0.22)) { drawerOpen = false }
    }
}
