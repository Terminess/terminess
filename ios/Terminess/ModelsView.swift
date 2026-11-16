import SwiftUI
import TermHost

struct MachineModelsView: View {
    let host: SavedHost
    @ObservedObject private var app = AppState.shared
    @State private var roles: ModelRoles?
    @State private var claude: [AgentModel] = AgentModels.claude
    @State private var codex: [AgentModel] = []
    @State private var problem: String?
    @State private var loading = true

    private var connection: HostConnection { app.connection(host.id) }

    var body: some View {
        List {
            if let roles {
                Section {
                    row("Orchestration", "claude", "main", roles)
                    row("Building", "claude", "subagents", roles)
                } header: { Text("Claude Code") } footer: {
                    Text("Orchestration is the session you talk to. Building is the agents it starts to do the work. Both apply to Claude Code started in new sessions.")
                }
                .listRowBackground(Theme.surface)
                Section {
                    row("Reviews", "claude", "review", roles)
                    row("Work", "claude", "work", roles)
                    row("Questions", "claude", "ask", roles)
                } header: { Text("Claude Code, when Codex asks it") }
                .listRowBackground(Theme.surface)
                Section {
                    row("Reviews", "codex", "review", roles)
                    row("Work", "codex", "work", roles)
                    row("Questions", "codex", "ask", roles)
                } header: { Text("Codex, when Claude asks it") } footer: {
                    Text("Used when one agent calls the other, such as \"have Codex review this\" or \"hand this to Codex\".")
                }
                .listRowBackground(Theme.surface)
            } else if loading {
                HStack(spacing: 10) { ProgressView(); Text("Asking \(host.name)…").foregroundStyle(.secondary) }
                    .listRowBackground(Theme.surface)
            } else {
                Text(problem ?? "Couldn't reach \(host.name).").foregroundStyle(.secondary)
                    .listRowBackground(Theme.surface)
            }
            if roles != nil, let problem {
                Text(problem).font(.footnote).foregroundStyle(Theme.attention).listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func row(_ title: String, _ agent: String, _ role: String, _ roles: ModelRoles) -> some View {
        let models = agent == "claude" ? claude : codex
        let current = roles.model(agent, role)
        return Picker(title, selection: Binding(get: { current }, set: { picked in
            Task {
                if let saved = await connection.setModelRole(agent: agent, role: role, model: picked) {
                    self.roles = saved
                    problem = nil
                } else {
                    problem = "That wasn't saved: \(host.name) didn't answer."
                }
            }
        })) {
            Text(agent == "claude" ? "Claude Code's default" : "Codex's default").tag("")
            ForEach(models) { m in Text(m.name).tag(m.id) }
            if !current.isEmpty, !models.contains(where: { $0.id == current }) { Text(current).tag(current) }
        }
        .pickerStyle(.menu)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        await connection.connect()
        guard connection.isConnected else {
            problem = "Couldn't reach \(host.name). Check it's on and try again."
            return
        }
        guard let r = await connection.modelRoles() else {
            problem = "Update Terminess on \(host.name) to choose its models from here."
            return
        }
        let c = await connection.agentModels("claude")
        if !c.isEmpty { claude = c }
        codex = await connection.agentModels("codex")
        roles = r
    }
}
