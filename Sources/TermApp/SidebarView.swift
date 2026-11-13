import SwiftUI

enum SidebarID: Hashable {
    case tab(ObjectIdentifier)
    case job(String)
    case run(String)
    case session(String)
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    @State private var selection: SidebarID?
    @AppStorage("sidebar.openExpanded") private var openExpanded = true
    @AppStorage("sidebar.pairExpanded") private var pairExpanded = true
    @AppStorage("sidebar.sessionsExpanded") private var sessionsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.search)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            List(selection: $selection) {
                if model.search.isEmpty {
                    openSection
                    pairSection
                }
                sessionSections
                if let note = model.sessionsNote, model.search.isEmpty {
                    Text(note).font(.callout).foregroundStyle(.tertiary)
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: SidebarID.self) { ids in
                if let id = ids.first { menu(for: id) }
            } primaryAction: { ids in
                if let id = ids.first { open(id) }
            }
            .onChange(of: selection) { _, new in
                if case .tab(let tab)? = new { model.actions?.focusTab(tab) }
            }
        }
        .frame(minWidth: 220)
    }


    private var openSection: some View {
        Section("Open", isExpanded: $openExpanded) {
            ForEach(model.tabs) { tab in
                let agent = Agent.detect(tab.command)
                Row(symbol: agent != nil ? "sparkle" : "terminal",
                    tint: agent.map { Color(nsColor: $0.tint) } ?? .secondary,
                    title: tab.title, subtitle: tab.directory)
                    .tag(SidebarID.tab(tab.id))
            }
        }
    }

    private var pairSection: some View {
        Section(isExpanded: $pairExpanded) {
            if model.jobs.isEmpty && model.runs.isEmpty {
                Text("No pair runs today")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.jobs) { job in
                Row(symbol: jobSymbol(job.state), tint: jobTint(job.state),
                    title: job.brief, subtitle: agent(job.target) + " · parallel · " + job.state)
                    .tag(SidebarID.job(job.id))
            }
            ForEach(model.runs) { run in
                let ok = run.status == "ok"
                Row(symbol: ok ? "checkmark.circle" : "exclamationmark.circle", tint: ok ? .secondary : .red,
                    title: run.brief, subtitle: agent(run.to) + " · " + run.mode + " · " + run.repo)
                    .tag(SidebarID.run(run.id))
            }
        } header: {
            HStack {
                Text("Pair")
                Spacer()
                PairMenu(model: model)
            }
        }
    }

    private var sessionSections: some View {
        ForEach(groupedSessions, id: \.title) { group in
            Section(group.title, isExpanded: model.search.isEmpty ? $sessionsExpanded : .constant(true)) {
                ForEach(group.items) { s in
                    Row(symbol: "bubble.left", tint: toolTint(s.tool), title: s.title, subtitle: s.repo)
                        .tag(SidebarID.session(s.id))
                }
            }
        }
    }


    private struct Group { let title: String; let items: [SessionItem] }

    private var groupedSessions: [Group] {
        let items = model.filteredSessions.filter { $0.pair == nil && $0.title != "(no messages)" }.prefix(150)
        if !model.search.isEmpty { return [Group(title: "Sessions", items: Array(items))] }
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [SessionItem])] = [("Today", []), ("Yesterday", []), ("Previous 7 Days", []),
                                                    ("Previous 30 Days", []), ("Older", [])]
        for s in items {
            let d = Date(timeIntervalSince1970: s.mtime)
            let i: Int
            if cal.isDateInToday(d) { i = 0 }
            else if cal.isDateInYesterday(d) { i = 1 }
            else if now.timeIntervalSince(d) < 7 * 86_400 { i = 2 }
            else if now.timeIntervalSince(d) < 30 * 86_400 { i = 3 }
            else { i = 4 }
            buckets[i].1.append(s)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, items: $0.1) }
    }


    private func open(_ id: SidebarID) {
        switch id {
        case .tab(let t): model.actions?.focusTab(t)
        case .job(let j): if let job = model.jobs.first(where: { $0.id == j }) { model.actions?.jobAction(job, "wait") }
        case .run(let r): if let run = model.runs.first(where: { $0.id == r }) { model.actions?.showRun(run) }
        case .session(let s): if let item = model.sessions.first(where: { $0.id == s }) { model.actions?.resume(item) }
        }
    }

    @ViewBuilder
    private func menu(for id: SidebarID) -> some View {
        switch id {
        case .tab(let t):
            Button("Show Tab") { model.actions?.focusTab(t) }
            Button("Rename…") { model.actions?.renameTab(t) }
        case .job(let j):
            if let job = model.jobs.first(where: { $0.id == j }) {
                Button("Show Result") { model.actions?.jobAction(job, "wait") }
                Button("Show Diff") { model.actions?.jobAction(job, "diff") }
                Divider()
                Button("Apply Changes") { model.actions?.jobAction(job, "apply") }
                    .disabled(!(job.state == "done" || job.state == "failed"))
                Button("Discard") { model.actions?.jobAction(job, "discard") }
                    .disabled(job.state == "applied" || job.state == "discarded")
            }
        case .run(let r):
            if let run = model.runs.first(where: { $0.id == r }) {
                Button("Show Result") { model.actions?.showRun(run) }
            }
        case .session(let s):
            if let item = model.sessions.first(where: { $0.id == s }) {
                Button("Resume in New Tab") { model.actions?.resume(item) }
                Divider()
                Button("Copy Session ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.id, forType: .string)
                }
                Button("Show Folder in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.cwd)
                }
            }
        }
    }
}


private func agent(_ tool: String) -> String {
    tool == "claude" ? "Claude" : tool == "codex" ? "Codex" : tool
}

private func toolTint(_ tool: String) -> Color {
    switch tool {
    case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
    case "codex": return Color(red: 0.36, green: 0.62, blue: 0.95)
    default: return .secondary
    }
}

private func jobSymbol(_ state: String) -> String {
    switch state {
    case "running": return "circle.dotted"
    case "done": return "checkmark.circle"
    case "failed", "died": return "exclamationmark.circle"
    case "applied": return "checkmark.circle.fill"
    default: return "xmark.circle"
    }
}

private func jobTint(_ state: String) -> Color {
    switch state {
    case "running": return .orange
    case "done", "applied": return .green
    case "failed", "died": return .red
    default: return .secondary
    }
}

private struct Row: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .help(title)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
    }
}

private struct PairMenu: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        Menu {
            ForEach(["codex", "claude"], id: \.self) { tool in
                Section(agent(tool)) {
                    Button("Ask…") { model.actions?.startPair(mode: "ask", target: tool) }
                    Button("Review Changes…") { model.actions?.startPair(mode: "review", target: tool) }
                    Button("Hand Off…") { model.actions?.startPair(mode: "handoff", target: tool) }
                    Button("Run in Parallel…") { model.actions?.startPair(mode: "parallel", target: tool) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(SidebarModel.pairTool == nil)
        .help("Ask, review, hand off or run in parallel, in this tab's folder")
    }
}
