import SwiftUI
import UIKit
import TermHost

struct SettingsView: View {
    @ObservedObject private var store = HostStore.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var push = PushTokens.shared
    @State private var editing: SavedHost?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.dark.rawValue
    @AppStorage(DeviceName.key) private var deviceName = ""
    #if DEBUG
    @State private var demoModels = ProcessInfo.processInfo.environment["TERMINESS_DEMO_MODELS"] != nil
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { a in
                            HStack(spacing: 12) {
                                Swatch(look: a)
                                Text(a.name)
                            }
                            .tag(a.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Appearance")
                }
                .listRowBackground(Theme.surface)
                Section {
                    ForEach(store.hosts) { h in
                        Button { editing = h } label: {
                            HStack {
                                Image(systemName: app.connection(h.id).symbol)
                                    .foregroundStyle(app.connection(h.id).state == .connected ? Color.connected : Color.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.name).foregroundStyle(.primary)
                                    Text([MachineRole.clean(h.role), "\(h.user)@\(h.address)"].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
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
                .listRowBackground(Theme.surface)
                Section {
                    TextField(DeviceName.model, text: $deviceName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("This iPhone's Name")
                } footer: {
                    Text("How this iPhone appears on your other devices, for example \"Alex's iPhone 13 Pro\". It goes only to your own machines, over your own SSH.")
                }
                .listRowBackground(Theme.surface)
                Section {
                    ForEach(store.hosts) { h in
                        NavigationLink { MachineModelsView(host: h) } label: {
                            Label(store.hosts.count > 1 ? h.name : "Models on \(h.name)", systemImage: "cpu")
                        }
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("Which model each agent uses for orchestration, building, reviews and handed-off work. For the model of one chat, use the menu under its message box.")
                }
                .listRowBackground(Theme.surface)
                KeySection().listRowBackground(Theme.surface)
                LockSection().listRowBackground(Theme.surface)
                NotificationsSection(push: push).listRowBackground(Theme.surface)
                DemoSection().listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { HostEditor(host: $0) }
            #if DEBUG
            .navigationDestination(isPresented: $demoModels) {
                if let h = store.hosts.first { MachineModelsView(host: h) }
            }
            #endif
        }
        .id(appearance)
        .tint(Theme.ink)
        .preferredColorScheme(appearance == Appearance.system.rawValue ? nil : (Theme.appearance.isDark ? .dark : .light))
    }

    @ViewBuilder private func status(_ s: HostConnection.State) -> some View {
        switch s {
        case .connected: Text("connected").font(.caption).foregroundStyle(Color.connected)
        case .connecting: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.attention)
        case .idle: EmptyView()
        }
    }
}

private struct Swatch: View {
    let look: Appearance

    var body: some View {
        let saved = Theme.appearance
        Theme.appearance = look == .system ? .dark : look
        let bg = Theme.background, ink = Theme.ink, bubble = Theme.userBubble
        Theme.appearance = saved
        return RoundedRectangle(cornerRadius: 6)
            .fill(bg)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(ink).frame(width: 14, height: 2.5)
                    Capsule().fill(bubble).frame(width: 10, height: 4)
                }
                .padding(.leading, 6)
            }
            .overlay {
                if look == .system {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white)
                        .mask(HStack(spacing: 0) { Color.clear; Color.black })
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
            .frame(width: 34, height: 24)
    }
}

struct KeySection: View {
    @State private var copied = false
    @State private var shown = false

    private var fingerprint: String {
        let blob = DeviceKey.authorizedKeyLine().split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return blob.isEmpty ? "" : "\u{2026}" + blob.suffix(12)
    }

    var body: some View {
        Section {
            HStack {
                Label("Public key", systemImage: "key")
                Spacer()
                Text(fingerprint).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            if shown {
                Text(DeviceKey.authorizedKeyLine())
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(4)
            }
            Button(shown ? "Hide Key" : "Show Key") { withAnimation { shown.toggle() } }
            Button(copied ? "Copied" : "Copy Key") {
                UIPasteboard.general.string = DeviceKey.authorizedKeyLine()
                copied = true
            }
            ShareLink(item: DeviceKey.authorizedKeyLine()) { Text("Share Key") }
        } header: {
            Text("This iPhone's key")
        } footer: {
            Text(DeviceKey.usesSecureEnclave
                 ? "This is the public half, safe to share: add it to ~/.ssh/authorized_keys on each machine (pairing with a Mac does it for you). The private half was made in the Secure Enclave and never leaves this iPhone."
                 : "This is the public half, safe to share: add it to ~/.ssh/authorized_keys on each machine (pairing with a Mac does it for you).")
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
                Section {
                    Picker("Role", selection: Binding(
                        get: { MachineRole.presets.contains(host.role ?? "") ? (host.role ?? "") : (host.role == nil ? "" : "custom") },
                        set: { v in host.role = v == "custom" ? (host.role ?? "") : (v.isEmpty ? nil : v) })) {
                        Text("None").tag("")
                        ForEach(MachineRole.presets, id: \.self) { Text($0).tag($0) }
                        Text("Custom").tag("custom")
                    }
                    if let role = host.role, !MachineRole.presets.contains(role) {
                        TextField("Custom role", text: Binding(get: { role }, set: { host.role = $0 }))
                    }
                } footer: {
                    Text("Shown beside the machine's name, so you can tell production, staging and agent machines apart.")
                }
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
                        host.role = MachineRole.clean(host.role)
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

private struct LockSection: View {
    @ObservedObject var lock = AppLock.shared

    var body: some View {
        Section {
            Toggle("Require \(lock.biometryName)", isOn: Binding(get: { lock.enabled }, set: { lock.setEnabled($0) }))
                .disabled(!AppLock.available)
            if lock.enabled && AppLock.available {
                Picker("Ask again", selection: $lock.delay) {
                    ForEach(AppLock.Delay.allCases) { Text($0.label).tag($0) }
                }
            }
        } header: { Text("Lock") } footer: {
            Text(AppLock.available
                 ? "Terminess can type into shells on your machines, so it asks before opening. Locking disconnects; your sessions keep running."
                 : "Set a passcode on this iPhone to lock Terminess.")
        }
    }
}


private struct DemoSection: View {
    @ObservedObject var store = HostStore.shared

    var body: some View {
        Section {
            Toggle("Demo machine", isOn: Binding(
                get: { store.hosts.contains { DemoMachine.isDemo($0) } },
                set: { on in
                    if on { DemoMachine.hosts.forEach(store.save); AppState.shared.start() }
                    else { store.delete(store.hosts.filter { DemoMachine.isDemo($0) }.map(\.id)) }
                }))
        } footer: {
            Text("Adds three pretend machines (a Mac, a Linux PC and a server) with sample sessions, so you can try Terminess without a machine of your own. Nothing runs on them.")
        }
    }
}

private struct NotificationsSection: View {
    @ObservedObject var push: PushTokens
    @AppStorage("notificationsMode") private var mode = PushTokens.Mode.terminess.rawValue
    @AppStorage("customRelay") private var customRelay = ""

    private var current: PushTokens.Mode { PushTokens.Mode(rawValue: mode) ?? .terminess }

    var body: some View {
        Section {
            Picker("Deliver through", selection: $mode) {
                ForEach(PushTokens.Mode.allCases) { Text($0.name).tag($0.rawValue) }
            }
            if current == .custom {
                TextField("https://push.example.com/v1", text: $customRelay)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { push.modeChanged() }
                if PushTokens.relayBase == nil {
                    Text("Enter the https address of your relay.").font(.caption).foregroundStyle(Theme.attention)
                }
            }
            Label(statusText, systemImage: current == .off || push.token == nil ? "bell.slash" : "bell").font(.callout)
        } header: { Text("Notifications") } footer: {
            Text(footer)
        }
        .onChange(of: mode) { _, _ in push.modeChanged() }
    }

    private var statusText: String {
        if current == .off { return "Off. Nothing is sent to any relay; you'll see updates while Terminess is open." }
        if push.token == nil { return "Not allowed yet. Turn them on in iOS Settings, Terminess." }
        return "On. You'll hear when an agent finishes, needs you or a reminder is due."
    }

    private var footer: String {
        switch current {
        case .off:
            return "Your machines never contact a relay for this iPhone."
        case .terminess:
            return "Each notification passes through the Terminess relay and Apple, and only says a session finished or needs you. What's in your sessions stays between this iPhone and your machines."
        case .custom:
            return "For a Terminess you build with your own Apple developer team. Run relay/relay.py from the Terminess source with your own push key, then enter its address here."
        }
    }
}
