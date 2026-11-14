import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var store = HostStore.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var push = PushTokens.shared
    @State private var editing: SavedHost?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.hosts) { h in
                        Button { editing = h } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.name).foregroundStyle(.primary)
                                    Text("\(h.user)@\(h.address)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                status(app.connection(h.id).state)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.hosts[$0].id }
                        ids.forEach { app.connection($0).disconnect() }
                        store.delete(ids)
                    }
                    Button { editing = SavedHost(name: "", address: "", user: "") } label: { Label("Add Manually", systemImage: "plus") }
                } header: {
                    Text("Machines")
                } footer: {
                    Text("Quickest: run terminessd pair on the machine and scan the code it shows with the iPhone camera.")
                }
                KeySection()
                Section("Notifications") {
                    Label(push.token == nil ? "Off. Allow them in iOS Settings, Terminess." : "On. You'll hear when an agent finishes or needs you.",
                          systemImage: push.token == nil ? "bell.slash" : "bell")
                        .font(.callout)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { HostEditor(host: $0) }
        }
    }

    @ViewBuilder private func status(_ s: HostConnection.State) -> some View {
        switch s {
        case .connected: Circle().fill(Color.green).frame(width: 8, height: 8)
        case .connecting: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.attention)
        case .idle: EmptyView()
        }
    }
}

struct KeySection: View {
    @State private var copied = false

    var body: some View {
        Section {
            Text(DeviceKey.authorizedKeyLine())
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(4)
            Button(copied ? "Copied" : "Copy Key") {
                UIPasteboard.general.string = DeviceKey.authorizedKeyLine()
                copied = true
            }
            ShareLink(item: DeviceKey.authorizedKeyLine()) { Text("Share Key") }
        } header: {
            Text("This iPhone's key")
        } footer: {
            Text(DeviceKey.usesSecureEnclave
                 ? "Made in the Secure Enclave; it never leaves this iPhone. Add it to ~/.ssh/authorized_keys on each machine."
                 : "Add it to ~/.ssh/authorized_keys on each machine.")
        }
    }
}

struct HostEditor: View {
    @State var host: SavedHost
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $host.name)
                TextField("Address", text: $host.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("User", text: $host.user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", value: $host.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                Section("terminessd on the machine") {
                    TextField("Path", text: $host.terminessd)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
                if host.hostKey != nil {
                    Section {
                        Button("Forget Host Key", role: .destructive) { host.hostKey = nil }
                    } footer: {
                        Text("Only after reinstalling the machine. Terminess trusts the key it sees on the next connection.")
                    }
                }
            }
            .navigationTitle(host.name.isEmpty ? "New Machine" : host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if host.name.isEmpty { host.name = host.address }
                        HostStore.shared.save(host)
                        AppState.shared.connection(host.id).disconnect()
                        Task { await AppState.shared.connection(host.id).connect() }
                        dismiss()
                    }
                    .disabled(host.address.isEmpty || host.user.isEmpty)
                }
            }
        }
    }
}

struct WelcomeView: View {
    @State private var adding: SavedHost?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "sparkle").font(.system(size: 40, weight: .light)).padding(.top, 50)
                Text("Your agents, on your phone").font(.system(size: 30, weight: .bold))
                Text("Terminess connects to the machines where Claude Code and Codex run, so you can follow and steer them from anywhere.")
                    .foregroundStyle(.secondary)
                step(1, "On your Mac or server, install terminessd and run:", code: "terminessd pair")
                step(2, "Scan the code it shows with this iPhone's camera.", code: nil)
                step(3, "Add this iPhone's key to the machine's ~/.ssh/authorized_keys:", code: nil)
                List { KeySection() }.frame(height: 260).scrollDisabled(true).listStyle(.insetGrouped)
                Button("Add a machine manually") { adding = SavedHost(name: "", address: "", user: "") }
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
        .background(Theme.background)
        .sheet(item: $adding) { HostEditor(host: $0) }
    }

    private func step(_ n: Int, _ text: String, code: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 15, weight: .bold)).frame(width: 26, height: 26).background(Circle().fill(Theme.surface))
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                if let code {
                    Text(code).font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                }
            }
        }
    }
}
