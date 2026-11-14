import TermHost
import SwiftUI

enum SidebarID: Hashable {
    case tab(ObjectIdentifier)
    case job(String)
    case run(String)
    case session(String)
    case issue(Int)
    case host(String)
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    var drops: WindowLink?
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
                    if !model.background.isEmpty { runningSection }
                    pairSection
                    if model.issuesRepo != nil { issuesSection }
                }
                sessionSections
                if !model.search.isEmpty && listedSessions.isEmpty {
                    Text("No matches for \u{201C}\(model.search)\u{201D}")
                        .font(.callout).foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
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
        .onDrop(of: Drops.utTypes, isTargeted: nil) { _ in drops?.dropFromSwiftUI() ?? false }
    }


    private var openSection: some View {
        Section("Open", isExpanded: $openExpanded) {
            ForEach(model.tabs) { tab in
                let agent = Agent.detect(tab.command)
                Row(symbol: tab.attention ? "circle.fill" : (tab.parked ? "moon.zzz" : (agent != nil ? "sparkle" : "terminal")),
                    tint: tab.attention ? .orange : (agent.map { Color(nsColor: $0.tint) } ?? .secondary),
                    title: tab.title,
                    subtitle: [tab.busy ? "working" : nil, tab.branch.map { "⎇ \($0)" }, tab.directory,
                               tab.panes > 1 ? "\(tab.panes) panes" : nil,
                               tab.parked ? "parked" : nil].compactMap { $0 }.joined(separator: " · "),
                    busy: tab.busy && !tab.attention,
                    current: tab.id == drops?.owner,
                    actions: [
                        RowAction(symbol: "pencil", help: "Rename") { model.actions?.renameTab(tab.id) },
                        RowAction(symbol: "xmark", help: "Close tab") { model.actions?.closeTab(tab.id) },
                    ])
                    .tag(SidebarID.tab(tab.id))
            }
        }
    }

    private var runningSection: some View {
        Section("Running") {
            ForEach(model.background, id: \.id) { s in
                let agent = Agent.detect(s.command)
                Row(symbol: agent != nil ? "sparkle" : "terminal",
                    tint: agent.map { Color(nsColor: $0.tint) } ?? .secondary,
                    title: agent?.name ?? s.command,
                    subtitle: [shortPath(s.cwd), s.clients > 0 ? "open elsewhere" : "no tab"].filter { !$0.isEmpty }.joined(separator: " · "),
                    actions: [
                        RowAction(symbol: "arrow.up.forward.app", help: "Open in a tab") { model.actions?.attachHost(s) },
                        RowAction(symbol: "xmark", help: "End this session") { model.actions?.killHost(s.id) },
                    ])
                    .tag(SidebarID.host(s.id))
            }
        }
    }

    private func shortPath(_ p: String) -> String {
        let home = SidebarModel.home
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
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
                Row(symbol: run.state == "done" ? "checkmark.circle" : run.state == "failed" ? "exclamationmark.circle" : "stop.circle",
                    tint: run.state == "failed" ? .red : .secondary,
                    title: run.brief,
                    subtitle: agent(run.to) + " · " + run.mode + " · " + (run.state == "running" ? "working" : run.repo),
                    busy: run.state == "running")
                    .tag(SidebarID.run(run.id))
                    .help("Open to see what \(agent(run.to)) is doing: the brief, every command and its output, and its answer.")
            }
        } header: {
            HStack {
                Text("Pair")
                Spacer()
                PairMenu(model: model)
            }
        }
    }

    @AppStorage("sidebar.issuesExpanded") private var issuesExpanded = true

    private var issuesSection: some View {
        Section(isExpanded: $issuesExpanded) {
            if let note = model.issuesNote {
                Text(note).font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(model.issues) { issue in
                Row(symbol: "smallcircle.filled.circle", tint: .green, title: issue.title,
                    subtitle: (["#\(issue.number)"] + issue.labels.map(\.name)).joined(separator: " · "),
                    actions: [
                        RowAction(symbol: "play", help: "Start with Claude Code in a new worktree") { model.actions?.startIssue(issue, agent: "claude") },
                    ])
                    .tag(SidebarID.issue(issue.number))
            }
        } header: {
            Text("Issues · \(model.issuesRepo?.split(separator: "/").last.map(String.init) ?? "")")
        }
    }

    private var sessionSections: some View {
        Group {
            if !pinnedSessions.isEmpty && model.search.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedSessions) { s in sessionRow(s, showRepo: true) }
                }
            }
            ForEach(projectGroups, id: \.key) { group in
                Section(isExpanded: expandedBinding(group.key)) {
                    ForEach(group.visible) { s in sessionRow(s, showRepo: false) }
                    if group.hidden > 0 {
                        Button(showAll.contains(group.key) ? "Show less" : "Show \(group.hidden) more") {
                            if showAll.contains(group.key) { showAll.remove(group.key) } else { showAll.insert(group.key) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
    }

    private func sessionRow(_ s: SessionItem, showRepo: Bool) -> some View {
        let recent = Date().timeIntervalSince1970 - s.mtime < 86_400
        let pinned = model.pinned.contains(s.id)
        return Row(symbol: "bubble.left", tint: toolTint(s.tool), title: s.title,
                   subtitle: showRepo ? "\(s.repo) · \(relative(s.mtime))" : relative(s.mtime),
                   dimmed: !recent && !pinned,
                   actions: [
                       RowAction(symbol: "arrow.uturn.forward", help: "Resume in new tab") { model.actions?.resume(s) },
                       RowAction(symbol: pinned ? "pin.slash" : "pin", help: pinned ? "Unpin" : "Pin") { model.togglePin(s.id) },
                   ])
            .tag(SidebarID.session(s.id))
    }


    @State private var showAll: Set<String> = []
    @State private var collapsed: Set<String> = []

    private func expandedBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(key) || !model.search.isEmpty },
                set: { if $0 { collapsed.remove(key) } else { collapsed.insert(key) } })
    }

    private var listedSessions: [SessionItem] {
        model.filteredSessions.filter { $0.pair == nil && $0.title != "(no messages)" }
    }

    private var pinnedSessions: [SessionItem] {
        listedSessions.filter { model.pinned.contains($0.id) }
    }

    private struct ProjectGroup {
        let key: String
        let title: String
        let visible: [SessionItem]
        let hidden: Int
    }

    private var projectGroups: [ProjectGroup] {
        let items = listedSessions.filter { model.search.isEmpty ? !model.pinned.contains($0.id) : true }
        var order: [String] = []
        var byKey: [String: [SessionItem]] = [:]
        for s in items {
            if byKey[s.cwd] == nil { order.append(s.cwd) }
            byKey[s.cwd, default: []].append(s)
        }
        let cutoff = Date().timeIntervalSince1970 - 6 * 3600
        return order.map { key in
            let all = byKey[key] ?? []
            let title = all.first?.repo ?? key
            if !model.search.isEmpty || showAll.contains(key) {
                return ProjectGroup(key: key, title: title, visible: all, hidden: showAll.contains(key) ? max(0, all.count - 5) : 0)
            }
            let shown = all.enumerated().filter { $0.offset < 5 || $0.element.mtime > cutoff }.map(\.element)
            return ProjectGroup(key: key, title: title, visible: shown, hidden: all.count - shown.count)
        }
    }


    private func open(_ id: SidebarID) {
        switch id {
        case .tab(let t): model.actions?.renameTab(t)
        case .job(let j): if let job = model.jobs.first(where: { $0.id == j }) { model.actions?.jobAction(job, "wait") }
        case .run(let r): if let run = model.runs.first(where: { $0.id == r }) { model.actions?.showRun(run) }
        case .session(let s): if let item = model.sessions.first(where: { $0.id == s }) { model.actions?.resume(item) }
        case .issue(let n): if let issue = model.issues.first(where: { $0.number == n }) { model.actions?.startIssue(issue, agent: "claude") }
        case .host(let h): if let s = model.background.first(where: { $0.id == h }) { model.actions?.attachHost(s) }
        }
    }

    @ViewBuilder
    private func menu(for id: SidebarID) -> some View {
        switch id {
        case .tab(let t):
            Button("Show Tab") { model.actions?.focusTab(t) }
            Button("Rename…") { model.actions?.renameTab(t) }
            if let tab = model.tabs.first(where: { $0.id == t }), let branch = tab.branch {
                Divider()
                Button("Commit and Merge \(branch)…") { model.actions?.worktreeAction(t, "merge") }
                Button("Remove Worktree, Keep Branch") { model.actions?.worktreeAction(t, "remove") }
                Button("Discard Worktree…") { model.actions?.worktreeAction(t, "discard") }
                Divider()
            }
            Menu("Theme") {
                Button("Same as App") { model.actions?.setTheme(nil, forTab: t) }
                Divider()
                ForEach(Settings.shared.allThemes) { theme in
                    Button(theme.name) { model.actions?.setTheme(theme.name, forTab: t) }
                }
            }
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
                Button("Show What It Did") { model.actions?.showRun(run) }
            }
        case .host(let h):
            if let s = model.background.first(where: { $0.id == h }) {
                Button("Open in a Tab") { model.actions?.attachHost(s) }
                Divider()
                Button("End Session") { model.actions?.killHost(h) }
            }
        case .issue(let n):
            if let issue = model.issues.first(where: { $0.number == n }) {
                Button("Start with Claude Code") { model.actions?.startIssue(issue, agent: "claude") }
                Button("Start with Codex") { model.actions?.startIssue(issue, agent: "codex") }
                Divider()
                Button("Open on GitHub") {
                    if let repo = model.issuesRepo, let url = URL(string: "https://github.com/\(repo)/issues/\(issue.number)") {
                        NSWorkspace.shared.open(url)
                    }
                }
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

struct RowAction {
    let symbol: String
    let help: String
    let perform: () -> Void
}

private struct Row: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var dimmed = false
    var busy = false
    var current = false
    var actions: [RowAction] = []
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini).tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(current ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovering && !actions.isEmpty {
                HStack(spacing: 2) {
                    ForEach(actions.indices, id: \.self) { i in
                        Button(action: actions[i].perform) {
                            Image(systemName: actions[i].symbol)
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(actions[i].help)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(current
            ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 8)
            : nil)
        .opacity(dimmed && !hovering ? 0.58 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
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
                .onExitCommand { text = "" }
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

private func relative(_ t: Double) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
}
