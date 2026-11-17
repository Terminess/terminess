import SwiftUI

struct MachinesSection: View {
    @State private var machines = RemoteMachines.all
    @State private var name = ""
    @State private var host = ""
    @State private var path = "~/.local/bin/terminessd"
    @State private var link = ""
    @State private var note: String?
    private let aliases = SSHConfig.aliases()

    var body: some View {
        Section("Machines") {
            if machines.isEmpty {
                Text("No machines yet. Add a server or another computer running terminessd, and its sessions appear in the sidebar.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(machines) { m in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name)
                        Text(m.host + (m.port == 22 ? "" : ":\(m.port)") + "  " + m.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Remove") { save(machines.filter { $0.id != m.id }) }
                }
                TextField("Repositories there", text: Binding(
                    get: { m.repoRoot ?? "" },
                    set: { v in save(machines.map { x in var x = x; if x.id == m.id { x.repoRoot = v.isEmpty ? nil : v }; return x }) }),
                    prompt: Text("~/github"))
                    .font(.callout)
            }
            TextField("Repositories on this Mac", text: Binding(
                get: { HandoffCoordinator.localRoot == "~/github" ? "" : HandoffCoordinator.localRoot },
                set: { HandoffCoordinator.localRoot = $0 }), prompt: Text("~/github"))
            Text("Moving a conversation between this Mac and a machine (right-click an agent session) matches repositories by folder name in these folders.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Add a Machine") {
            TextField("Name", text: $name, prompt: Text("agents"))
            HStack {
                TextField("SSH host", text: $host, prompt: Text("An alias from ~/.ssh/config, or user@host"))
                if !aliases.isEmpty {
                    Menu("Aliases") {
                        ForEach(aliases, id: \.self) { a in
                            Button(a) { host = a; if name.isEmpty { name = a } }
                        }
                    }
                    .fixedSize()
                }
            }
            TextField("terminessd on the machine", text: $path)
            HStack {
                Spacer()
                Button("Add", action: add).disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Terminess connects with your own ssh and keys, so the host must log in without a password prompt. Install terminessd there with: terminessd service install")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Or Paste a Link") {
            HStack {
                TextField("Link", text: $link, prompt: Text("terminess://add?..."))
                Button("Add") { addLink() }.disabled(link.isEmpty)
            }
            Text("Run terminessd pair on the machine and paste the link it prints.")
                .font(.caption).foregroundStyle(.secondary)
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func add() {
        let h = host.trimmingCharacters(in: .whitespaces)
        var m = RemoteMachine(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? h : name, host: h)
        let p = path.trimmingCharacters(in: .whitespaces)
        m.path = p.isEmpty ? "~/.local/bin/terminessd" : p
        if let colon = h.lastIndex(of: ":"), let port = Int(h[h.index(after: colon)...]) {
            m.host = String(h[..<colon]); m.port = port
        }
        guard m.isValid else { note = "That host or path can't be used."; return }
        note = nil
        save(machines + [m])
        name = ""; host = ""; path = "~/.local/bin/terminessd"
    }

    private func addLink() {
        guard let m = RemoteMachine.fromLink(link) else { note = "That isn't a terminess://add link."; return }
        note = nil
        save(machines + [m])
        link = ""
    }

    private func save(_ list: [RemoteMachine]) {
        RemoteMachines.all = list
        machines = list
    }
}
