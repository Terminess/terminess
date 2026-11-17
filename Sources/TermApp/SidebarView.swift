import TermHost
import SwiftUI

enum SidebarID: Hashable {
    case tab(ObjectIdentifier)
    case job(String)
    case run(String)
    case session(String)
    case issue(Int)
    case host(String)
    case remote(String)
    case projectTab(ObjectIdentifier)
    case remotePast(String)
    case reminder(String)
    case machine(String)
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    var drops: WindowLink?
    @State private var selection: SidebarID?
    @State private var openReminder: String?
    @AppStorage("sidebar.openExpanded") private var openExpanded = true
    @AppStorage("sidebar.pairExpanded") private var pairExpanded = true
    @AppStorage("sidebar.sessionsExpanded") private var sessionsExpanded = true
    @AppStorage("sidebar.machinesExpanded") private var machinesExpanded = true
    @AppStorage("sidebar.otherExpanded") private var otherExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                SidebarAction(title: "New session", symbol: "plus", emphasised: true,
                              help: "A new tab in this window (Cmd-T)") {
                    NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
                }
                SidebarAction(title: "Search", symbol: "magnifyingglass", help: "Sessions, projects, machines, reminders and actions (Cmd-K)",
                              shortcut: "\u{2318}K") {
                    NSApp.sendAction(#selector(AppDelegate.showSearch(_:)), to: nil, from: nil)
                }
                let pending = model.allReminders
                SidebarAction(title: "Reminders", symbol: "clock",
                              help: "Reminders you and your agents set, here and on your other machines.",
                              detail: pending.first.map { e in
                                  let t = ReminderText.relative(e.reminder.due, fired: e.reminder.fired == true)
                                  return t == "due" ? "due now" : "next \(t)"
                              },
                              badge: pending.count) {
                    NSApp.sendAction(#selector(AppDelegate.showReminders(_:)), to: nil, from: nil)
                }
                SidebarAction(title: "Library", symbol: "books.vertical",
                              help: "The skills, slash commands, subagents and MCP servers Claude Code and Codex load, in one place.") {
                    NSApp.sendAction(#selector(AppDelegate.showLibrary(_:)), to: nil, from: nil)
                }
                SidebarAction(title: "Models", symbol: "cpu",
                              help: "Which model each agent uses for orchestration, building, reviews and handed-off work.") {
                    NSApp.sendAction(#selector(AppDelegate.showModels(_:)), to: nil, from: nil)
                }
                if !model.hasPairedPhone {
                    SidebarAction(title: "Pair iPhone", symbol: "iphone",
                                  help: "Follow and steer what's running here from Terminess for iPhone.") {
                        NSApp.sendAction(#selector(AppDelegate.showPairPhone(_:)), to: nil, from: nil)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            List(selection: $selection) {
                let layout = projectLayout
                if model.search.isEmpty {
                    machinesSection(layout)
                    openSection(layout)
                    pairSection
                    if model.issuesRepo != nil { issuesSection }
                }
                sessionSections(layout)
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
            .scrollContentBackground(.hidden)
            .onKeyPress(keys: ["f"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                NSApp.sendAction(#selector(AppDelegate.showSearch(_:)), to: nil, from: nil)
                return .handled
            }
            .sheet(isPresented: Binding(get: { openReminder != nil }, set: { if !$0 { openReminder = nil; selection = nil } })) {
                if let key = openReminder, let (m, r) = reminderEntry(key) {
                    ReminderDetailView(reminder: r, machine: m) { openReminder = nil; selection = nil }
                }
            }
            .contextMenu(forSelectionType: SidebarID.self) { ids in
                if let id = ids.first { menu(for: id) }
            } primaryAction: { ids in
                if let id = ids.first { open(id) }
            }
            .onChange(of: selection) { _, new in
                if case .tab(let tab)? = new { model.actions?.focusTab(tab) }
                if case .reminder(let key)? = new { openReminder = key }
                if case .projectTab(let tab)? = new { model.actions?.focusTab(tab) }
            }
            bottomBar
        }
        .frame(minWidth: 220)
        .noTopScrollEdge()
        .onDrop(of: Drops.utTypes, isTargeted: nil) { _ in drops?.dropFromSwiftUI() ?? false }
    }

    private var bottomBar: some View {
        let connected = model.remote.filter { $0.note == nil }.count
        let summary = [DeviceIdentity.name,
                       model.remote.isEmpty ? nil : "\(connected) of \(model.remote.count) machine\(model.remote.count == 1 ? "" : "s") connected"]
            .compactMap { $0 }.joined(separator: "\n")
        return HStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer").font(.system(size: 12))
                Text("This Mac").lineLimit(1)
            }
            .help(summary)
            Spacer(minLength: 4)
            Button { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) } label: {
                Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (Cmd-,)")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5) }
    }


    static func reminderTime(_ due: Double) -> String {
        let d = Date(timeIntervalSince1970: due)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE d MMM HH:mm"
        return f.string(from: d)
    }

    static let openListsEveryTab = false

    @ViewBuilder
    private func openSection(_ layout: Layout) -> some View {
        let tabs = Self.openListsEveryTab ? model.tabs : model.tabs.filter { !layout.placedTabs.contains($0.id) }
        if !tabs.isEmpty {
        Section {
            if openExpanded {
            ForEach(tabs) { tab in
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
        } header: { FoldHeader(title: "Open", expanded: $openExpanded) }
        }
    }

    private func machinesSection(_ layout: Layout) -> some View {
        Section {
            if machinesExpanded {
            MachineRow(symbol: "laptopcomputer", title: "This Mac", detail: DeviceIdentity.name,
                       role: nil, connected: true, state: nil, help: nil)
                .tag(SidebarID.machine(""))
            ForEach(model.remote) { r in
                MachineRow(symbol: r.symbol, title: r.displayName, detail: nil, role: r.role,
                           connected: r.note == nil, state: r.note == nil ? "connected" : "offline",
                           help: r.note ?? "Reachable over ssh") { newSessionMenu(r) }
                    .tag(SidebarID.machine(r.id))
            }
            ForEach(model.connectedPhones, id: \.name) { phone in
                MachineRow(symbol: "iphone", title: phone.name,
                           detail: phone.viewing.count == 1 ? "viewing \(phone.viewing[0])" : "\(phone.viewing.count) sessions open",
                           role: nil, connected: true, state: "connected", help: phone.viewing.joined(separator: "\n"))
                    .tag(SidebarID.machine("phone:" + phone.name))
            }
            }
        } header: { FoldHeader(title: "Machines", expanded: $machinesExpanded) }
    }

    @ViewBuilder
    private func newSessionMenu(_ r: RemoteMachineState) -> some View {
        newRemoteItems(r, directory: nil, label: "Home")
        let recent = r.projects.sorted { $0.used > $1.used }.prefix(8)
        if !recent.isEmpty { Divider() }
        ForEach(Array(recent), id: \.path) { p in
            Menu(p.path.split(separator: "/").last.map(String.init) ?? p.path) {
                newRemoteItems(r, directory: p.path, label: nil)
            }
        }
    }

    @ViewBuilder
    private func newRemoteItems(_ r: RemoteMachineState, directory: String?, label: String?) -> some View {
        let suffix = label.map { " in \($0)" } ?? ""
        Button("Claude Code" + suffix) { model.actions?.newRemote(r.machine, agent: "claude", directory: directory) }
        Button("Codex" + suffix) { model.actions?.newRemote(r.machine, agent: "codex", directory: directory) }
        Button("Shell" + suffix) { model.actions?.newRemote(r.machine, agent: nil, directory: directory) }
    }

    private func remotePath(_ p: String) -> String { remoteTilde(p) }

    private func remoteSession(_ key: String) -> (RemoteMachine, SessionInfo)? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let r = model.remote.first(where: { $0.id == parts[0] }),
              let s = r.sessions.first(where: { $0.id == parts[1] }) else { return nil }
        return (r.machine, s)
    }

    private func remotePast(_ key: String) -> (RemoteMachine, HistoryItem)? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let r = model.remote.first(where: { $0.id == parts[0] }),
              let h = r.history.first(where: { $0.id == parts[1] }) else { return nil }
        return (r.machine, h)
    }

    private func shortPath(_ p: String) -> String {
        SidebarModel.tilde(p)
    }

    private var pairSection: some View {
        Section {
            if pairExpanded {
            if model.jobs.isEmpty && model.runs.isEmpty {
                Text("No pair runs today")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.jobs) { job in
                Row(symbol: jobSymbol(job.state), tint: jobTint(job.state),
                    title: job.brief, subtitle: agent(job.target) + " · parallel · " + job.state, showSubtitle: true)
                    .tag(SidebarID.job(job.id))
            }
            ForEach(model.runs) { run in
                Row(symbol: run.state == "done" ? "checkmark.circle" : run.state == "failed" ? "exclamationmark.circle" : "stop.circle",
                    tint: run.state == "failed" ? .red : .secondary,
                    title: run.brief,
                    subtitle: agent(run.to) + " · " + run.mode + " · " + (run.state == "running" ? "working" : run.repo),
                    busy: run.state == "running",
                    showSubtitle: true)
                    .tag(SidebarID.run(run.id))
                    .help("Open to see what \(agent(run.to)) is doing: the brief, every command and its output, and its answer.")
            }
            }
        } header: {
            HStack {
                FoldHeader(title: "Pair", expanded: $pairExpanded)
                Spacer()
                PairMenu(model: model)
            }
        }
    }

    @AppStorage("sidebar.issuesExpanded") private var issuesExpanded = false

    private var issuesSection: some View {
        Section {
            if issuesExpanded {
            if let note = model.issuesNote {
                Text(note).font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(model.issues) { issue in
                Row(symbol: "smallcircle.filled.circle", tint: .green, title: issue.title,
                    subtitle: (["#\(issue.number)"] + issue.labels.map(\.name)).joined(separator: " · "),
                    showSubtitle: true,
                    actions: [
                        RowAction(symbol: "play", help: "Start with Claude Code in a new worktree") { model.actions?.startIssue(issue, agent: "claude") },
                    ])
                    .tag(SidebarID.issue(issue.number))
            }
            }
        } header: {
            FoldHeader(title: "Issues · \(model.issuesRepo?.split(separator: "/").last.map(String.init) ?? "")", expanded: $issuesExpanded)
        }
        .onChange(of: issuesExpanded) { _, open in
            if open { model.refreshIssues(force: true) }
        }
    }

    private func sessionSections(_ layout: Layout) -> some View {
        Group {
            if !pinnedSessions.isEmpty && model.search.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedSessions) { s in sessionRow(s, showRepo: true, stale: nil) }
                }
            }
            ForEach(layout.groups, id: \.key) { group in
                Section {
                    if expandedBinding(group.key).wrappedValue {
                    ForEach(group.live) { liveRow($0) }
                    ForEach(group.past) { pastRow($0, newest: group.newest) }
                    if group.more > 0 {
                        Button(showAll.contains(group.key) ? "Show less" : "Show \(group.more) more") {
                            if showAll.contains(group.key) { showAll.remove(group.key) } else { showAll.insert(group.key) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    }
                } header: {
                    FoldHeader(title: group.title, expanded: expandedBinding(group.key))
                }
            }
            if !layout.other.isEmpty {
                Section {
                    if otherExpanded { ForEach(layout.other) { liveRow($0) } }
                } header: { FoldHeader(title: "Other", expanded: $otherExpanded) }
            }
        }
    }

    @ViewBuilder
    private func liveRow(_ live: Live) -> some View {
        switch live {
        case .tab(let tab):
            let agent = Agent.detect(tab.command)
            let remoteMachine = tab.machineID.flatMap { id in model.remote.first { $0.id == id } }
            Row(symbol: tab.attention ? "circle.fill" : (tab.parked ? "moon.zzz" : (agent != nil ? "sparkle" : "terminal")),
                tint: tab.attention ? .orange : (agent.map { Color(nsColor: $0.tint) } ?? .secondary),
                title: tab.title,
                subtitle: [tab.busy ? "working" : nil, "open",
                           tab.branch.map { "⎇ \($0)" }, tab.parked ? "parked" : nil].compactMap { $0 }.joined(separator: " · "),
                busy: tab.busy && !tab.attention,
                current: tab.id == drops?.owner,
                machine: remoteMachine.map { DeviceBadge.machine($0) } ?? .thisMac,
                badge: DeviceBadge.connected(model.tabDevices(tab)),
                actions: [RowAction(symbol: "xmark", help: "Close tab") { model.actions?.closeTab(tab.id) }])
                .tag(SidebarID.projectTab(tab.id))
        case .background(let s):
            let agent = Agent.detect(s.command)
            Row(symbol: s.attention == true ? "circle.fill" : (agent != nil ? "sparkle" : "terminal"),
                tint: s.attention == true ? .orange : (agent.map { Color(nsColor: $0.tint) } ?? .secondary),
                title: SessionNames.title(s),
                subtitle: [s.busy == true ? "working" : (s.attention == true ? "needs you" : nil), "no tab", shortPath(s.cwd)]
                    .compactMap { $0 }.joined(separator: " · "),
                busy: s.busy == true && s.attention != true,
                machine: .thisMac,
                badge: DeviceBadge.presence(s),
                actions: [
                    RowAction(symbol: "arrow.up.forward.app", help: "Open in a tab") { model.actions?.attachHost(s) },
                    RowAction(symbol: "xmark", help: "End this session") { model.actions?.killHost(s.id) },
                ])
                .tag(SidebarID.host(s.id))
        case .remote(let r, let s):
            let agent = Agent.detect(s.command)
            Row(symbol: s.attention == true ? "circle.fill" : (agent != nil ? "sparkle" : "terminal"),
                tint: s.attention == true ? .orange : (agent.map { Color(nsColor: $0.tint) } ?? .secondary),
                title: SessionNames.title(s),
                subtitle: [s.busy == true ? "working" : (s.attention == true ? "needs you" : nil), remotePath(s.cwd)]
                    .compactMap { $0 }.joined(separator: " · "),
                busy: s.busy == true && s.attention != true,
                machine: DeviceBadge.machine(r),
                badge: DeviceBadge.presence(s),
                actions: [
                    RowAction(symbol: "arrow.up.forward.app", help: "Open in a tab") { model.actions?.attachRemote(r.machine, s) },
                    RowAction(symbol: "xmark", help: "End this session") { model.actions?.killRemote(r.machine, s.id) },
                ])
                .tag(SidebarID.remote("\(r.id)/\(s.id)"))
        }
    }

    @ViewBuilder
    private func pastRow(_ past: Past, newest: String?) -> some View {
        switch past {
        case .local(let s):
            sessionRow(s, showRepo: false, stale: s.id == newest ? nil : commitsSince(s))
        case .remote(let r, let h):
            Row(symbol: "bubble.left", tint: toolTint(h.agent), title: h.title,
                subtitle: [r.machine.name, relative(h.used)].joined(separator: " · "),
                dimmed: true,
                detail: h.commitsSince.flatMap { $0 > 0 ? "\($0) commit\($0 == 1 ? "" : "s") since" : nil },
                actions: [RowAction(symbol: "arrow.uturn.forward", help: "Resume on \(r.machine.name)") {
                    model.actions?.resumeRemote(r.machine, h)
                }])
                .tag(SidebarID.remotePast("\(r.id)/\(h.id)"))
        }
    }

    private func sessionRow(_ s: SessionItem, showRepo: Bool, stale: Int?) -> some View {
        let pinned = model.pinned.contains(s.id)
        let when = showRepo ? "\(s.repo) · \(relative(s.mtime))" : relative(s.mtime)
        return Row(symbol: "bubble.left", tint: toolTint(s.tool), title: s.title,
                   subtitle: when,
                   dimmed: !pinned,
                   detail: stale.map { "\($0) commit\($0 == 1 ? "" : "s") since" },
                   actions: [
                       RowAction(symbol: "arrow.uturn.forward", help: "Resume in new tab") { model.actions?.resume(s) },
                       RowAction(symbol: pinned ? "pin.slash" : "pin", help: pinned ? "Unpin" : "Pin") { model.togglePin(s.id) },
                   ])
            .tag(SidebarID.session(s.id))
    }

    private func commitsSince(_ s: SessionItem) -> Int? {
        model.commitsSince[SidebarModel.commitKey(s)].flatMap { $0 > 0 ? $0 : nil }
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

    enum Live: Identifiable {
        case tab(OpenTab)
        case background(SessionInfo)
        case remote(RemoteMachineState, SessionInfo)
        var id: String {
            switch self {
            case .tab(let t): return "tab-\(t.id.hashValue)"
            case .background(let s): return "host-\(s.id)"
            case .remote(let r, let s): return "remote-\(r.id)/\(s.id)"
            }
        }
    }

    enum Past: Identifiable {
        case local(SessionItem)
        case remote(RemoteMachineState, HistoryItem)
        var id: String {
            switch self {
            case .local(let s): return s.id
            case .remote(let r, let h): return "\(r.id)/\(h.id)"
            }
        }
        var time: Double {
            switch self {
            case .local(let s): return s.mtime
            case .remote(_, let h): return h.used
            }
        }
    }

    struct ProjectGroup {
        let key: String
        let title: String
        let live: [Live]
        let past: [Past]
        let more: Int
        let newest: String?
    }

    struct Layout {
        var groups: [ProjectGroup] = []
        var placedHosts: Set<String> = []
        var placedRemote: Set<String> = []
        var placedTabs: Set<ObjectIdentifier> = []
        var other: [Live] = []
    }

    private var projectLayout: Layout { Self.layout(model, showAll: showAll) }

    static func layout(_ model: SidebarModel, showAll: Set<String>) -> Layout {
        var layout = Layout()
        let searching = !model.search.isEmpty
        var order: [String] = []
        var titles: [String: String] = [:]
        var past: [String: [Past]] = [:]
        var live: [String: [Live]] = [:]
        func add(_ key: String, _ title: String) {
            if titles[key] == nil { order.append(key); titles[key] = title }
        }
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }

        let listed = model.filteredSessions.filter { $0.pair == nil && $0.title != "(no messages)" }
        for s in listed where searching || !model.pinned.contains(s.id) {
            add(s.cwd, s.repo)
            past[s.cwd, default: []].append(.local(s))
        }
        if !searching {
            for tab in model.tabs where tab.machineID == nil {
                guard let root = model.repoRoot(tab.path) else { continue }
                add(root, name(root))
                live[root, default: []].append(.tab(tab))
                layout.placedTabs.insert(tab.id)
            }
            for s in model.background {
                guard let root = model.repoRoot(s.cwd) else { continue }
                add(root, name(root))
                live[root, default: []].append(.background(s))
                layout.placedHosts.insert(s.id)
            }
        }
        var byName: [String: String] = [:]
        for key in order where model.isRepo(key) && byName[name(key)] == nil { byName[name(key)] = key }
        let names = Set(byName.keys)
        let words = model.search.lowercased().split(separator: " ").map(String.init)
        for r in model.remote {
            let projects = r.projects.map(\.path)
            func key(_ cwd: String) -> String? {
                guard let project = ProjectGrouping.remoteProject(cwd: cwd, localNames: names, remoteProjects: projects) else { return nil }
                let k = byName[project] ?? "remote:\(project)"
                add(k, project)
                return k
            }
            if !searching {
                for tab in model.tabs where tab.machineID == r.id {
                    if let k = key(tab.path) { live[k, default: []].append(.tab(tab)); layout.placedTabs.insert(tab.id) }
                }
                for s in model.remoteFree(r) {
                    guard let k = key(s.cwd) else { continue }
                    live[k, default: []].append(.remote(r, s))
                    layout.placedRemote.insert("\(r.id)/\(s.id)")
                }
            }
            for h in r.history where h.title != "(no messages)" {
                let hay = "\(h.title) \(name(h.cwd)) \(h.agent)".lowercased()
                guard words.allSatisfy({ hay.contains($0) }), let k = key(h.cwd) else { continue }
                past[k, default: []].append(.remote(r, h))
            }
        }
        let groups: [ProjectGroup] = order.compactMap { key in
            let running = live[key] ?? []
            let all = (past[key] ?? []).sorted { $0.time > $1.time }
            guard !running.isEmpty || !all.isEmpty else { return nil }
            let shown = ProjectGrouping.limited(all, expanded: searching || showAll.contains(key))
            return ProjectGroup(key: key, title: titles[key] ?? key, live: running, past: shown.visible,
                                more: searching ? 0 : shown.more, newest: all.first?.id)
        }
        layout.groups = groups.filter { !$0.live.isEmpty } + groups.filter { $0.live.isEmpty }
        if !searching {
            layout.other = model.background.filter { !layout.placedHosts.contains($0.id) }.map { .background($0) }
            for r in model.remote where r.note == nil {
                layout.other += model.remoteFree(r).filter { !layout.placedRemote.contains("\(r.id)/\($0.id)") }.map { .remote(r, $0) }
            }
        }
        return layout
    }


    private func open(_ id: SidebarID) {
        switch id {
        case .tab(let t): model.actions?.renameTab(t)
        case .job(let j): if let job = model.jobs.first(where: { $0.id == j }) { model.actions?.jobAction(job, "wait") }
        case .run(let r): if let run = model.runs.first(where: { $0.id == r }) { model.actions?.showRun(run) }
        case .session(let s): if let item = model.sessions.first(where: { $0.id == s }) { model.actions?.resume(item) }
        case .projectTab(let t): model.actions?.renameTab(t)
        case .remotePast(let key): if let (m, h) = remotePast(key) { model.actions?.resumeRemote(m, h) }
        case .issue(let n): if let issue = model.issues.first(where: { $0.number == n }) { model.actions?.startIssue(issue, agent: "claude") }
        case .host(let h): if let s = model.background.first(where: { $0.id == h }) { model.actions?.attachHost(s) }
        case .remote(let key): if let (m, s) = remoteSession(key) { model.actions?.attachRemote(m, s) }
        case .reminder(let key):
            openReminder = key
        case .machine(let id):
            if model.remote.contains(where: { $0.id == id }) {
                NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
            }
        }
    }

    private func reminderEntry(_ key: String) -> (RemoteMachine?, ReminderInfo)? {
        model.allReminders.first { "\($0.machine?.id ?? "")/\($0.reminder.id)" == key }.map { ($0.machine, $0.reminder) }
    }

    @ViewBuilder
    private func menu(for id: SidebarID) -> some View {
        switch id {
        case .tab(let t), .projectTab(let t):
            Button("Show Tab") { model.actions?.focusTab(t) }
            Button("Rename…") { model.actions?.renameTab(t) }
            if let tab = model.tabs.first(where: { $0.id == t }), Agent.detect(tab.command) != nil {
                if let key = tab.remoteIDs.first, let (m, s) = remoteSession(key) {
                    Button("Move to This Mac") { model.actions?.moveToMac(m, sessionID: s.id) }
                } else if tab.machineID == nil {
                    ForEach(model.remote.filter { $0.note == nil }) { r in
                        Button("Move to \(r.machine.name)") { model.actions?.moveTab(t, to: r.machine) }
                    }
                }
            }
            if model.tabs.first(where: { $0.id == t })?.command == "claude" {
                Button("Fork Conversation in New Tab") { model.actions?.forkTab(t, inWorktree: false) }
                Button("Fork Conversation in a Worktree Tab") { model.actions?.forkTab(t, inWorktree: true) }
            }
            if let tab = model.tabs.first(where: { $0.id == t }), let branch = tab.branch {
                Divider()
                Button("Commit and Merge \(branch)…") { model.actions?.worktreeAction(t, "merge") }
                Button("Open Pull Request…") { model.actions?.worktreeAction(t, "pr") }
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
        case .remote(let key):
            if let (m, s) = remoteSession(key) {
                Button("Open in a Tab") { model.actions?.attachRemote(m, s) }
                if Agent.detect(s.command) != nil {
                    Button("Move to This Mac") { model.actions?.moveToMac(m, sessionID: s.id) }
                }
                Divider()
                Button("End Session on \(m.name)") { model.actions?.killRemote(m, s.id) }
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
                Button("Open Issues Board") { NSApp.sendAction(#selector(AppDelegate.showIssueBoard(_:)), to: nil, from: nil) }
            }
        case .reminder(let key):
            if let (m, r) = reminderEntry(key) {
                if r.fired == true { Button(r.label) { ReminderCenter.shared.proceed(r.id, machine: m) } }
                Button(r.fired == true ? "Dismiss" : "Cancel Reminder") { ReminderCenter.shared.dismiss(r.id, machine: m) }
            }
        case .machine(let id):
            if let r = model.remote.first(where: { $0.id == id }) {
                newSessionMenu(r)
                Divider()
                Button("Machine Settings…") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
            } else if id.isEmpty {
                Button("New Tab") { NSApp.sendAction(#selector(AppDelegate.newWindow(_:)), to: nil, from: nil) }
            }
        case .remotePast(let key):
            if let (m, h) = remotePast(key) {
                Button("Resume on \(m.name)") { model.actions?.resumeRemote(m, h) }
                Button("Copy Session ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(h.id, forType: .string)
                }
            }
        case .session(let s):
            if let item = model.sessions.first(where: { $0.id == s }) {
                Button("Resume in New Tab") { model.actions?.resume(item) }
                Button("Fork in New Tab") { model.actions?.fork(item, inWorktree: false) }
                Button("Fork in a Worktree Tab") { model.actions?.fork(item, inWorktree: true) }
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
    tool == "claude" ? "Claude" : tool == "codex" ? "Codex" : tool == "gemini" ? "Gemini" : tool
}

func toolTint(_ tool: String) -> Color {
    switch tool {
    case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
    case "codex": return Color(red: 0.36, green: 0.62, blue: 0.95)
    case "gemini": return Color(red: 0.26, green: 0.72, blue: 0.62)
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

struct DeviceBadge: Equatable {
    let symbol: String
    let label: String
    let connected: Bool
    var help: String? = nil

    var view: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 9, weight: .regular))
            Text(label).fontWeight(.regular).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(connected ? Color.connected : Color.secondary)
        .help(help ?? label)
    }

    static func presence(_ s: SessionInfo, attachedHere: Bool = false) -> DeviceBadge? {
        let others = DevicePresence.others(s, ownKind: "mac", ownName: DeviceIdentity.name, attachedHere: attachedHere)
        if let b = connected(others) { return b }
        if let from = DevicePresence.originLabel(s) { return DeviceBadge(symbol: s.origin == "mac" ? "laptopcomputer" : "iphone", label: from, connected: false) }
        return nil
    }

    static func connected(_ devices: [ClientDevice]) -> DeviceBadge? {
        guard let label = DevicePresence.connectedLabel(devices) else { return nil }
        return DeviceBadge(symbol: DevicePresence.symbol(devices), label: label, connected: true,
                           help: devices.count > 2 ? DevicePresence.allNames(devices) : nil)
    }

    static let thisMac = DeviceBadge(symbol: "laptopcomputer", label: "This Mac", connected: true)

    static func machine(_ r: RemoteMachineState, label: String? = nil) -> DeviceBadge {
        DeviceBadge(symbol: r.symbol, label: label ?? r.displayName, connected: r.note == nil)
    }
}

struct MachineRow<MenuContent: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    let role: String?
    let connected: Bool
    let state: String?
    let help: String?
    let menu: MenuContent?
    @State private var hovering = false

    init(symbol: String, title: String, detail: String?, role: String?, connected: Bool, state: String?, help: String?,
         @ViewBuilder menu: () -> MenuContent) {
        self.symbol = symbol; self.title = title; self.detail = detail; self.role = role
        self.connected = connected; self.state = state; self.help = help; self.menu = menu()
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(connected ? Color.connected : Color.secondary)
                .frame(width: 16)
            Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).layoutPriority(2)
            if let role {
                Text(role)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if let menu, hovering {
                Menu { menu } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New session on \(title)")
            }
            if connected {
                Circle().fill(Color.connected).frame(width: 6, height: 6)
            } else if state != nil {
                Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help([title, detail, state, role, help].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

extension MachineRow where MenuContent == EmptyView {
    init(symbol: String, title: String, detail: String?, role: String?, connected: Bool, state: String?, help: String?) {
        self.symbol = symbol; self.title = title; self.detail = detail; self.role = role
        self.connected = connected; self.state = state; self.help = help; self.menu = nil
    }
}

enum DeviceIdentity {
    static let name: String = {
        let n = ProcessInfo.processInfo.environment["TERMAPP_DEVICE_NAME"] ?? Host.current().localizedName ?? ""
        return n.isEmpty ? "Mac" : n
    }()
}

private struct Row: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var dimmed = false
    var busy = false
    var current = false
    var machine: DeviceBadge? = nil
    var badge: DeviceBadge? = nil
    var showSubtitle = false
    var detail: String? = nil
    var actions: [RowAction] = []
    @State private var hovering = false

    private var tooltip: String {
        [title, machine.map { $0.connected && $0.label != "This Mac" ? "\($0.label), connected" : $0.label },
         badge.map { $0.help ?? $0.label }, subtitle.isEmpty ? nil : subtitle, detail]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var devices: some View {
        HStack(spacing: 5) {
            if let badge {
                Image(systemName: badge.symbol)
                    .foregroundStyle(badge.connected ? Color.connected : Color.secondary)
            }
            if let machine, machine.label != "This Mac" || badge != nil {
                Image(systemName: machine.symbol)
                    .foregroundStyle(machine.connected ? Color.connected : Color.secondary)
            }
        }
        .font(.system(size: 10.5))
        .fixedSize()
    }

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini).tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13))
                        .fontWeight(current ? .medium : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !(hovering && !actions.isEmpty) { devices }
                }
                if let second = showSubtitle && !subtitle.isEmpty ? subtitle : detail {
                    Text(second)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
        .padding(.vertical, 4)
        .listRowBackground(current
            ? RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)).padding(.horizontal, 8)
            : nil)
        .opacity(dimmed && !hovering ? 0.58 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(tooltip)
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13.5))
                .frame(width: 18)
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(focused ? 0.08 : hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }
}

private struct SidebarAction: View {
    let title: String
    let symbol: String
    var emphasised = false
    let help: String
    var detail: String? = nil
    var badge: Int? = nil
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13.5)).frame(width: 18)
                Text(title).font(.system(size: 13.5))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let shortcut, hovering {
                    Text(shortcut).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                if let badge, badge > 0 {
                    Text("\(badge)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 17)
                        .background(Capsule().fill(Color.primary.opacity(0.10)))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(emphasised ? (hovering ? 0.11 : 0.075) : (hovering ? 0.05 : 0))))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
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

struct FoldHeader: View {
    let title: String
    @Binding var expanded: Bool
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse" : "Expand")
    }
}
