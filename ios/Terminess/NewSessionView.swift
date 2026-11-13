import SwiftUI
import TermHost

struct NewSessionView: View {
    @ObservedObject var connection: HostConnection
    let onStart: (SessionTarget) -> Void
    @State private var agent = "claude"
    @State private var folder = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Start", selection: $agent) {
                        Text("Claude Code").tag("claude")
                        Text("Codex").tag("codex")
                        Text("Shell").tag("shell")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Recent projects") {
                    if connection.projects.isEmpty {
                        HStack { ProgressView(); Text("Looking for projects…").foregroundStyle(.secondary) }
                    }
                    ForEach(connection.projects, id: \.path) { p in
                        Button { start(in: p.path) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.path.split(separator: "/").last.map(String.init) ?? p.path).foregroundStyle(.primary)
                                Text(p.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                }
                Section("Another folder") {
                    TextField("~/path/to/project", text: $folder)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { start(in: folder) }
                    Button("Start in Home Folder") { start(in: nil) }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await connection.loadProjects() }
        }
    }

    private func start(in path: String?) {
        let cwd = path.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let name = agent == "claude" ? "Claude Code" : (agent == "codex" ? "Codex" : "Shell")
        onStart(SessionTarget(session: nil, title: name, cwd: cwd, input: agent == "shell" ? nil : agent))
    }
}
