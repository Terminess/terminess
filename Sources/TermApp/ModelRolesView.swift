import SwiftUI
import TermHost

struct ModelRolesSection: View {
    @State private var roles = ModelRoles.load()
    @State private var codexModels = AgentModels.codex()

    var body: some View {
        Section("Models: Claude Code") {
            row("Orchestration", "claude", "main", AgentModels.claude,
                help: "The session you talk to, which plans the work and directs it.")
            row("Building", "claude", "subagents", AgentModels.claude,
                help: "The agents Claude Code starts to do the work. An agent that names its own model keeps it.")
            Text("Orchestration and Building apply to Claude Code started in new tabs, on this Mac and from your iPhone. Your Claude Code settings are not changed.")
                .font(.caption).foregroundStyle(.secondary)
            row("Reviews for Codex", "claude", "review", AgentModels.claude,
                help: "When Codex asks Claude for a review.")
            row("Work for Codex", "claude", "work", AgentModels.claude,
                help: "When Codex hands Claude a task, or runs it in parallel.")
            row("Questions from Codex", "claude", "ask", AgentModels.claude,
                help: "When Codex asks Claude a question or for an opinion.")
        }
        Section("Models: Codex") {
            row("Reviews", "codex", "review", codexModels,
                help: "When Claude asks Codex for a review.")
            row("Work", "codex", "work", codexModels,
                help: "When Claude hands Codex a task, or runs it in parallel.")
            row("Questions", "codex", "ask", codexModels,
                help: "When Claude asks Codex a question or for an opinion.")
            Text("Used when one agent calls the other (\"have Codex review this\", \"hand this to Codex\"). The same choices are in the terminal: pair models.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            roles = ModelRoles.load()
            codexModels = AgentModels.codex()
        }
    }

    private func row(_ title: String, _ agent: String, _ role: String, _ models: [AgentModel], help: String) -> some View {
        let current = roles.model(agent, role)
        return Picker(title, selection: Binding(get: { current }, set: { picked in
            var fresh = ModelRoles.load()
            fresh.set(agent, role, picked)
            do { try fresh.save() } catch { AgentEvents.report(error) }
            roles = fresh
        })) {
            Text(agent == "claude" ? "Claude Code's default" : "Codex's default").tag("")
            Divider()
            ForEach(models) { m in Text(m.name).tag(m.id) }
            if !current.isEmpty, !models.contains(where: { $0.id == current }) { Text(current).tag(current) }
        }
        .help(help)
    }
}
