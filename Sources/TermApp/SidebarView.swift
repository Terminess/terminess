import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search sessions", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            List {
                Section("Open") {
                    ForEach(model.tabs) { tab in
                        TabRow(tab: tab)
                            .contentShape(Rectangle())
                            .onTapGesture { model.actions?.focusTab(tab.id) }
                    }
                }
                Section {
                    if model.jobs.isEmpty && model.runs.isEmpty {
                        Text(SidebarModel.pairTool == nil ? "Install ~/.local/bin/pair to pair agents." : "Nothing yet. Use + to start.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.actions?.jobAction(job, "wait") }
                            .contextMenu {
                                Button("Show Result") { model.actions?.jobAction(job, "wait") }
                                Button("Show Diff") { model.actions?.jobAction(job, "diff") }
                                Divider()
                                Button("Apply Changes") { model.actions?.jobAction(job, "apply") }
                                    .disabled(!(job.state == "done" || job.state == "failed"))
                                Button("Discard") { model.actions?.jobAction(job, "discard") }
                                    .disabled(job.state == "applied" || job.state == "discarded")
                            }
                    }
                    ForEach(model.runs) { run in
                        RunRow(run: run)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.actions?.showRun(run) }
                            .contextMenu { Button("Show Result") { model.actions?.showRun(run) } }
                    }
                } header: {
                    HStack {
                        Text("Pair")
                        Spacer()
                        Menu {
                            ForEach(["codex", "claude"], id: \.self) { agent in
                                Section(agent == "codex" ? "Codex" : "Claude") {
                                    Button("Ask…") { model.actions?.startPair(mode: "ask", target: agent) }
                                    Button("Review Changes…") { model.actions?.startPair(mode: "review", target: agent) }
                                    Button("Hand Off…") { model.actions?.startPair(mode: "handoff", target: agent) }
                                    Button("Parallel Job…") { model.actions?.startPair(mode: "parallel", target: agent) }
                                }
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(SidebarModel.pairTool == nil)
                        .help("Start a pair run in the current tab's folder")
                    }
                }
                Section("Sessions") {
                    if let note = model.sessionsNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.filteredSessions.prefix(150)) { s in
                        SessionRow(session: s)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.actions?.resume(s) }
                            .contextMenu {
                                Button("Resume in New Tab") { model.actions?.resume(s) }
                                Button("Copy Session ID") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(s.id, forType: .string)
                                }
                                Button("Show Folder in Finder") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd)
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 220)
    }
}

private func toolColor(_ tool: String) -> Color {
    switch tool {
    case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
    case "codex": return Color(red: 0.36, green: 0.62, blue: 0.95)
    default: return .secondary
    }
}

private func relative(_ t: Double) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
}

private struct ToolBadge: View {
    let tool: String
    var body: some View {
        Text(tool)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(toolColor(tool))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(toolColor(tool).opacity(0.5), lineWidth: 0.5))
    }
}

private struct TabRow: View {
    let tab: OpenTab
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.command == "claude" || tab.command == "codex" ? "sparkles" : "terminal")
                .foregroundStyle(toolColor(tab.command))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title).lineLimit(1).fontWeight(tab.isKey ? .semibold : .regular)
                Text(tab.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        }
    }
}

private struct JobRow: View {
    let job: PairJob
    var color: Color {
        switch job.state {
        case "running": return .orange
        case "done": return .green
        case "failed", "died": return .red
        default: return .secondary
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    ToolBadge(tool: job.target)
                    Text("parallel · \(job.state)").font(.caption).foregroundStyle(.secondary)
                }
                Text(job.brief).lineLimit(2).font(.callout)
                Text(job.repo).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RunRow: View {
    let run: PairRun
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: run.status == "ok" ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(run.status == "ok" ? Color.secondary : Color.red)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    ToolBadge(tool: run.to)
                    Text("\(run.mode) from \(run.from)").font(.caption).foregroundStyle(.secondary)
                }
                Text(run.brief).lineLimit(2).font(.callout)
                Text(run.repo).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionItem
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ToolBadge(tool: session.tool)
                Text(session.repo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(relative(session.mtime)).font(.caption2).foregroundStyle(.tertiary)
            }
            if let p = session.pair {
                Text("↳ \(p.mode) from \(p.from): \(p.brief)").lineLimit(2).font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text(session.title).lineLimit(2).font(.callout)
                    if !session.linked.isEmpty {
                        Text("⇄ " + session.linked.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }
}
