import SwiftUI
import TermHost

struct SearchView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var store = HostStore.shared
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search conversations", text: $query)
                        .focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Capsule().fill(Theme.surface))
                Button("Cancel") { dismiss() }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            List {
                let running = app.running.filter { matches(SessionText.title($0.session) + " " + $0.session.cwd) }
                if !running.isEmpty {
                    Section("Running") {
                        ForEach(running, id: \.session.id) { e in
                            Button {
                                app.open(SessionTarget(host: e.host.id, session: e.session.id, title: SessionText.title(e.session)))
                                dismiss()
                            } label: {
                                RunningRow(session: e.session, machine: store.hosts.count > 1 ? e.host.name : nil, selected: false)
                            }
                            .listRowInsets(EdgeInsets())
                        }
                    }
                }
                let recent = app.recent.filter { matches($0.item.title + " " + $0.item.cwd) }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent, id: \.item.id) { e in
                            Button {
                                let cmd = e.item.agent == "codex" ? "codex resume \(e.item.id)" : "claude --resume \(e.item.id)"
                                app.open(SessionTarget(host: e.host.id, session: nil, title: e.item.title, cwd: e.item.cwd, input: cmd))
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.item.title).foregroundStyle(.primary).lineLimit(2)
                                    Text("\(SessionText.folderName(e.item.cwd)) · \(SessionText.relative(e.item.used))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !query.isEmpty && running.isEmpty && recent.isEmpty {
                    Text("Nothing matches \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.background)
        .onAppear { focused = true }
    }

    private func matches(_ s: String) -> Bool { query.isEmpty || s.localizedCaseInsensitiveContains(query) }
}
