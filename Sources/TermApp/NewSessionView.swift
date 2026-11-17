import AppKit
import SwiftUI

struct NewSessionView: View {
    @ObservedObject var sidebar = SidebarModel.shared
    let startHere: (String) -> Void
    @State private var environment = ""

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
        .onAppear { if sidebar.historyCounts.isEmpty { sidebar.refreshSessions() } }
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
        } label: {
            HStack(spacing: 10) {
                Image(systemName: remote?.symbol ?? "laptopcomputer")
                    .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Choose environment").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text(remote?.displayName ?? "This Mac").font(.system(size: 13.5, weight: .medium))
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
                          help: "Opens this tab in the folder you pick.") { chooseFolder() }
            } else if let r = remote {
                Menu {
                    Button("Home") { open(r, nil) }
                    let recent = r.projects.sorted { $0.used > $1.used }.prefix(10)
                    if !recent.isEmpty { Divider() }
                    ForEach(Array(recent), id: \.path) { p in
                        Button((p.path as NSString).lastPathComponent) { open(r, p.path) }
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
        if panel.runModal() == .OK, let url = panel.url { startHere(url.path) }
    }

    private func open(_ r: RemoteMachineState, _ directory: String?) {
        (NSApp.delegate as? AppDelegate)?.newRemote(r.machine, agent: nil, directory: directory)
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
