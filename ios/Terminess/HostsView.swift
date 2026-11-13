import SwiftUI
import UIKit

struct HostsView: View {
    @ObservedObject var store = HostStore.shared
    @State private var editing: SavedHost?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.hosts) { host in
                        NavigationLink(value: host.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name).font(.headline)
                                Text("\(host.user)@\(host.address)\(host.port == 22 ? "" : ":\(host.port)")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Edit") { editing = host }.tint(.gray)
                        }
                    }
                    .onDelete { offsets in store.delete(offsets.map { store.hosts[$0].id }) }
                } header: {
                    Text("Machines")
                } footer: {
                    if store.hosts.isEmpty {
                        Text("On the machine, run: terminessd pair. Then scan the code it shows with this iPhone's camera.")
                    }
                }

                Section {
                    Text(DeviceKey.authorizedKeyLine())
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                    Button(copied ? "Copied" : "Copy Key") {
                        UIPasteboard.general.string = DeviceKey.authorizedKeyLine()
                        copied = true
                    }
                    ShareLink(item: DeviceKey.authorizedKeyLine()) { Text("Share Key") }
                } header: {
                    Text("This iPhone's key")
                } footer: {
                    Text(DeviceKey.usesSecureEnclave
                         ? "Kept in the Secure Enclave; it never leaves this iPhone. Add this line to ~/.ssh/authorized_keys on each machine."
                         : "Add this line to ~/.ssh/authorized_keys on each machine.")
                }
            }
            .navigationTitle("Terminess")
            .navigationDestination(for: UUID.self) { id in SessionsView(hostID: id) }
            .toolbar {
                Button { editing = SavedHost(name: "", address: "", user: "") } label: { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { host in HostEditor(host: host) }
            .alert("Added \(store.justAdded ?? "")", isPresented: Binding(get: { store.justAdded != nil },
                                                                     set: { if !$0 { store.justAdded = nil } })) {
                Button("OK") { store.justAdded = nil }
            } message: {
                Text("Tap it to see what's running there.")
            }
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
                TextField("Port", value: $host.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                Section("terminessd on the host") {
                    TextField("Path", text: $host.terminessd)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
                if host.hostKey != nil {
                    Section {
                        Button("Forget Host Key", role: .destructive) { host.hostKey = nil }
                    } footer: {
                        Text("Only after reinstalling the server. Terminess trusts the key it sees on the next connection.")
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
                        dismiss()
                    }
                    .disabled(host.address.isEmpty || host.user.isEmpty)
                }
            }
        }
    }
}
