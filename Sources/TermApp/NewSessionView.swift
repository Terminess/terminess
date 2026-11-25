import AppKit
import SwiftUI
import TermHost

struct NewSessionView: View {
    private var sidebar: SidebarModel { SidebarModel.shared }
    @ObservedObject var gate: ViewGate
    let tabMachine: String
    let startHere: (_ path: String, _ command: String) -> Void
    @State private var environment = ""
    @State private var chosen = false
    @AppStorage("startAgent") private var agent = "claude"
    @ObservedObject private var localModels = LocalModelMenu.shared
    @ObservedObject private var settings = Settings.shared

    private var remote: RemoteMachineState? { sidebar.remote.first { $0.id == environment } }

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: 14) {
                Text("✦_")
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
                Text("Where shall we start?")
                    .font(.system(size: 20, weight: .regular))
                    .padding(.bottom, 8)
                environmentCard
                agentCard
                actionsCard
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, minHeight: geo.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .noTopScrollEdge()
        }
        .onAppear {
            if sidebar.historyCounts.isEmpty { sidebar.refreshSessions() }
            if !chosen {
                environment = tabMachine.isEmpty ? (AppDelegate.defaultRemoteMachine?.id ?? "") : tabMachine
                chosen = true
            }
            LocalModelMenu.shared.refresh()
        }
    }


    private var environmentCard: some View {
        Menu {
            Button { environment = "" } label: {
                Label("This Mac (\(DeviceIdentity.name))", systemImage: "laptopcomputer")
            }
            if !sidebar.remote.isEmpty { Divider() }
            ForEach(sidebar.remote) { r in
                Button { environment = r.id } label: {
                    Label(r.displayName + (r.note == nil ? "" : " (offline)"), systemImage: r.symbol)
                }
                .disabled(r.note != nil)
            }
            if environment != settings.defaultMachine {
                Divider()
                Button("Start New Sessions on \(remote?.displayName ?? "This Mac")") { settings.defaultMachine = environment }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: remote?.symbol ?? "laptopcomputer")
                    .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Choose environment").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(remote?.displayName ?? "This Mac").font(.system(size: 13.5, weight: .medium))
                        if environment == settings.defaultMachine {
                            Text("Default").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
                        }
                    }
                }
                Spacer()
                stateDot(connected: remote?.note == nil)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .card()
    }


    private var agentCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
            Text("Agent").font(.system(size: 13.5))
            Spacer()
            HStack(spacing: 4) {
                agentChoice("claude", "Claude Code")
                agentChoice("codex", "Codex")
                localChoice
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .card()
    }

    private func agentChoice(_ id: String, _ name: String) -> some View {
        let on = agent == id
        return Button { agent = id } label: { chip(tint: toolTint(id), name: name, on: on) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var models: [String] { remote.map(\.models) ?? (localModels.models ?? []) }

    private var localChoice: some View {
        let picked = StartAgent.localModel(agent)
        return Menu {
            if models.isEmpty {
                Text(remote == nil ? localModels.note : "No Ollama models on \(remote!.displayName)")
            } else {
                Section("On \(remote?.displayName ?? localModels.placeName)") {
                    ForEach(models, id: \.self) { m in
                        Button { agent = "local:" + m } label: {
                            if m == picked { Label(m, systemImage: "checkmark") } else { Text(m) }
                        }
                    }
                }
            }
            Section("Hugging Face") {
                if let notice = localModels.hfNotice {
                    Button { LocalModelMenu.open(notice) } label: {
                        Label(notice.message, systemImage: "exclamationmark.triangle.fill")
                    }
                }
                ForEach(localModels.hfModels, id: \.self) { id in
                    let m = HuggingFace.prefix + id
                    Button { agent = "local:" + m } label: {
                        if m == picked { Label(id, systemImage: "checkmark") } else { Text(id) }
                    }
                }
            }
        } label: {
            chip(tint: Color(nsColor: Agent.detect("ollama")?.tint ?? .systemGray),
                 name: picked.map { HuggingFace.modelID($0) ?? $0 } ?? "Local model", on: picked != nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Chat with an Ollama model on \(remote?.displayName ?? localModels.placeName)")
    }

    private func chip(tint: Color, name: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(name).font(.system(size: 12.5, weight: on ? .medium : .regular)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(on ? Color.primary.opacity(0.10) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(Color.primary.opacity(on ? 0.18 : 0.08), lineWidth: 0.5))
        .contentShape(Rectangle())
    }

    private func stateDot(connected: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(connected ? Color.connected : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
            Text(connected ? "connected" : "offline").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }


    private var importable: [(agent: String, count: Int)] {
        HistoryImport.agents.compactMap { a in
            guard let n = sidebar.historyCounts[a], n > 0, !sidebar.importedAgents.contains(a) else { return nil }
            return (a, n)
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            if environment.isEmpty {
                ForEach(Array(importable.enumerated()), id: \.element.agent) { _, item in
                    ActionRow(symbol: "square.and.arrow.down", tint: toolTint(item.agent),
                              title: "Import \(item.count) \(HistoryImport.name(item.agent)) session\(item.count == 1 ? "" : "s")",
                              help: help(item.agent)) {
                        sidebar.importHistory(item.agent)
                    }
                    Divider().padding(.leading, 44)
                }
                ActionRow(symbol: "folder", tint: .secondary, title: "Choose a folder to work in",
                          help: "Starts the agent in this tab, in the folder you pick.") { chooseFolder() }
            } else if let r = remote {
                Menu {
                    Button("Home") { open(r, nil) }
                    let recent = r.projects.sorted { $0.used > $1.used }.prefix(10)
                    if !recent.isEmpty { Divider() }
                    ForEach(Array(recent), id: \.path) { p in
                        Button((p.path as NSString).lastPathComponent) { open(r, p.path) }
                    }
                    let tree = r.folderTree
                    if !tree.isEmpty {
                        Divider()
                        Section("All folders") {
                            ForEach(tree, id: \.path) { node in
                                let name = (node.path as NSString).lastPathComponent
                                if node.children.isEmpty {
                                    Button(name) { open(r, node.path) }
                                } else {
                                    Menu(name) {
                                        Button("Work in \(name)") { open(r, node.path) }
                                        Divider()
                                        ForEach(node.children, id: \.self) { c in
                                            Button((c as NSString).lastPathComponent) { open(r, c) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    ActionLabel(symbol: "folder", tint: .secondary, title: "Choose a folder on \(r.displayName)")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }
        }
        .card()
    }

    private func help(_ agent: String) -> String {
        switch agent {
        case "gemini": return "Lists Gemini CLI conversations in the sidebar. Ones saved whole resume with gemini --resume; older ones, where Gemini CLI kept only your prompts, open read-only."
        default: return "Lists your past \(HistoryImport.name(agent)) conversations in the sidebar, by project, ready to read and resume."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Work Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if tabMachine.isEmpty {
            startHere(url.path, StartAgent.command(agent, remote: false))
        } else {
            (NSApp.delegate as? AppDelegate)?.open(tabbedWith: NSApp.keyWindow, directory: url.path,
                                                     command: StartAgent.command(agent, remote: false))
        }
    }

    private func open(_ r: RemoteMachineState, _ directory: String?) {
        let command = StartAgent.command(agent, remote: true)
        if r.id == tabMachine {
            startHere(directory ?? "~", command)
        } else {
            (NSApp.delegate as? AppDelegate)?.open(tabbedWith: NSApp.keyWindow, directory: directory, command: command, machine: r.machine)
        }
    }
}

private struct ActionLabel: View {
    let symbol: String
    let tint: Color
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint).frame(width: 20)
            Text(title).font(.system(size: 13.5))
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

private struct ActionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) { ActionLabel(symbol: symbol, tint: tint, title: title) }
            .buttonStyle(.plain)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .onHover { hovering = $0 }
            .help(help)
    }
}

private extension View {
    func card() -> some View {
        self
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
