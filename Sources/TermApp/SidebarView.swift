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
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    var drops: WindowLink?
    @State private var selection: SidebarID?
    @State private var openReminder: String?
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
                let layout = projectLayout
                if model.search.isEmpty {
                    shortcutsSection
                    if !model.allReminders.isEmpty { remindersSection }
                    openSection
                    ForEach(model.remote) { r in machineSection(r, layout) }
                    if model.background.contains(where: { !layout.placedHosts.contains($0.id) }) { runningSection(layout) }
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
        }
        .frame(minWidth: 220)
        .onDrop(of: Drops.utTypes, isTargeted: nil) { _ in drops?.dropFromSwiftUI() ?? false }
    }


    private var remindersSection: some View {
        Section("Reminders") {
            ForEach(model.allReminders, id: \.reminder.id) { entry in
                let r = entry.reminder, m = entry.machine
                let due = r.fired == true
                Row(symbol: due ? "bell.badge.fill" : "clock",
                    tint: due ? .orange : .secondary,
                    title: r.title,
                    subtitle: [due ? "due" : Self.reminderTime(r.due), m?.name, r.body].compactMap { $0 }.joined(separator: " · "),
                    dimmed: !due,
                    actions: due
                        ? [RowAction(symbol: "play.fill", help: r.label) { ReminderCenter.shared.proceed(r.id, machine: m) },
                           RowAction(symbol: "xmark", help: "Dismiss") { ReminderCenter.shared.dismiss(r.id, machine: m) }]
                        : [RowAction(symbol: "xmark", help: "Cancel reminder") { ReminderCenter.shared.dismiss(r.id, machine: m) }])
                    .tag(SidebarID.reminder("\(m?.id ?? "")/\(r.id)"))
            }
        }
    }

    static func reminderTime(_ due: Double) -> String {
        let d = Date(timeIntervalSince1970: due)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE d MMM HH:mm"
        return f.string(from: d)
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

    private func runningSection(_ layout: Layout) -> some View {
        Section("Background") {
            ForEach(model.background.filter { !layout.placedHosts.contains($0.id) }, id: \.id) { s in
                let agent = Agent.detect(s.command)
                Row(symbol: agent != nil ? "sparkle" : "terminal",
                    tint: agent.map { Color(nsColor: $0.tint) } ?? .secondary,
                    title: SessionNames.title(s),
                    subtitle: [shortPath(s.cwd), DeviceBadge.openElsewhere(s) ? "open elsewhere" : (DeviceBadge.phone(s)?.connected == true ? nil : "no tab")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    badge: DeviceBadge.phone(s),
                    actions: [
                        RowAction(symbol: "arrow.up.forward.app", help: "Open in a tab") { model.actions?.attachHost(s) },
                        RowAction(symbol: "xmark", help: "End this session") { model.actions?.killHost(s.id) },
                    ])
                    .tag(SidebarID.host(s.id))
            }
        }
    }

    private func machineSection(_ r: RemoteMachineState, _ layout: Layout) -> some View {
        Section {
            if let note = r.note {
                Text(note).font(.callout).foregroundStyle(.tertiary).lineLimit(2)
            } else {
                let free = model.remoteFree(r).filter { !layout.placedRemote.contains("\(r.id)/\($0.id)") }
                if free.isEmpty {
                    Text(r.sessions.isEmpty ? "Nothing running" : "Running under projects or in tabs").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(free, id: \.id) { s in
                    let agent = Agent.detect(s.command)
                    Row(symbol: s.attention == true ? "circle.fill" : (agent != nil ? "sparkle" : "terminal"),
                        tint: s.attention == true ? .orange : (agent.map { Color(nsColor: $0.tint) } ?? .secondary),
                        title: SessionNames.title(s),
                        subtitle: [s.busy == true ? "working" : (s.attention == true ? "needs you" : nil),
                                   remotePath(s.cwd), DeviceBadge.openElsewhere(s) ? "open elsewhere" : nil]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                        busy: s.busy == true && s.attention != true,
                        badge: DeviceBadge.phone(s),
                        actions: [
                            RowAction(symbol: "arrow.up.forward.app", help: "Open in a tab") { model.actions?.attachRemote(r.machine, s) },
                            RowAction(symbol: "xmark", help: "End this session") { model.actions?.killRemote(r.machine, s.id) },
                        ])
                        .tag(SidebarID.remote("\(r.id)/\(s.id)"))
                }
            }
        } header: {
            HStack(spacing: 4) {
                Image(systemName: r.symbol)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(r.note == nil ? Color.connected : Color.secondary)
                Text(model.remote.count > 1 ? "Remote \u{00B7} \(r.machine.name)" : "Remote")
                if r.note == nil {
                    Text("connected").font(.caption2).fontWeight(.regular).foregroundStyle(Color.connected).textCase(nil)
                }
                Spacer()
                Menu {
                    newRemoteItems(r, directory: nil, label: "Home")
                    let recent = r.projects.sorted { $0.used > $1.used }.prefix(8)
                    if !recent.isEmpty { Divider() }
                    ForEach(Array(recent), id: \.path) { p in
                        Menu(p.path.split(separator: "/").last.map(String.init) ?? p.path) {
                            newRemoteItems(r, directory: p.path, label: nil)
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New session on \(r.machine.name)")
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

    @AppStorage("sidebar.shortcutsExpanded") private var shortcutsExpanded = true

    private var shortcutsSection: some View {
        Section("Shortcuts", isExpanded: $shortcutsExpanded) {
            shortcut("Library", "books.vertical", #selector(AppDelegate.showLibrary(_:)),
                     help: "The skills, slash commands, subagents and MCP servers Claude Code and Codex load, in one place.")
            shortcut("Models", "cpu", #selector(AppDelegate.showModels(_:)),
                     help: "Which model each agent uses for orchestration, building, reviews and handed-off work.")
            shortcut("Pair iPhone", "iphone", #selector(AppDelegate.showPairPhone(_:)),
                     help: "Follow and steer what's running here from Terminess for iPhone.")
        }
    }

    private func shortcut(_ title: String, _ symbol: String, _ action: Selector, help: String) -> some View {
        Button { NSApp.sendAction(action, to: nil, from: nil) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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

    private func sessionSections(_ layout: Layout) -> some View {
        Group {
            if !pinnedSessions.isEmpty && model.search.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedSessions) { s in sessionRow(s, showRepo: true, stale: nil) }
                }
            }
            ForEach(layout.groups, id: \.key) { group in
                Section(isExpanded: expandedBinding(group.key)) {
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
                } header: {
                    Text(group.title)
                }
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
                badge: model.iPhoneOnTab(tab)
                    ? DeviceBadge(symbol: "iphone", label: "iPhone connected", connected: true)
                    : remoteMachine.map { DeviceBadge.machine($0) },
                actions: [RowAction(symbol: "xmark", help: "Close tab") { model.actions?.closeTab(tab.id) }])
                .tag(SidebarID.projectTab(tab.id))
        case .background(let s):
            let agent = Agent.detect(s.command)
            Row(symbol: s.attention == true ? "circle.fill" : (agent != nil ? "sparkle" : "terminal"),
                tint: s.attention == true ? .orange : (agent.map { Color(nsColor: $0.tint) } ?? .secondary),
                title: SessionNames.title(s),
                subtitle: [s.busy == true ? "working" : (s.attention == true ? "needs you" : nil), "background",
                           DeviceBadge.openElsewhere(s) ? "open elsewhere" : nil].compactMap { $0 }.joined(separator: " · "),
                busy: s.busy == true && s.attention != true,
                badge: DeviceBadge.phone(s),
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
                subtitle: [s.busy == true ? "working" : (s.attention == true ? "needs you" : nil),
                           DeviceBadge.openElsewhere(s) ? "open elsewhere" : nil].compactMap { $0 }.joined(separator: " · "),
                busy: s.busy == true && s.attention != true,
                badge: DeviceBadge.phone(s) ?? DeviceBadge.machine(r),
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
                subtitle: [r.machine.name, relative(h.used),
                           h.commitsSince.flatMap { $0 > 0 ? "\($0) commit\($0 == 1 ? "" : "s") since" : nil }]
                    .compactMap { $0 }.joined(separator: " · "),
                dimmed: true,
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
                   subtitle: [when, stale.map { "\($0) commit\($0 == 1 ? "" : "s") since" }].compactMap { $0 }.joined(separator: " · "),
                   dimmed: !pinned,
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
                    if let k = key(tab.path) { live[k, default: []].append(.tab(tab)) }
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

struct DeviceBadge: Equatable {
    let symbol: String
    let label: String
    let connected: Bool

    var view: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 9, weight: .regular))
            Text(label).fontWeight(.regular).lineLimit(1)
        }
        .foregroundStyle(connected ? Color.connected : Color.secondary)
        .fixedSize()
    }

    static func phone(_ s: SessionInfo) -> DeviceBadge? {
        if s.clientKinds?.contains("iphone") == true { return DeviceBadge(symbol: "iphone", label: "iPhone connected", connected: true) }
        if s.origin == "iphone" { return DeviceBadge(symbol: "iphone", label: "from iPhone", connected: false) }
        return nil
    }

    static func machine(_ r: RemoteMachineState, label: String? = nil) -> DeviceBadge {
        DeviceBadge(symbol: r.symbol, label: label ?? r.machine.name, connected: r.note == nil)
    }

    static func openElsewhere(_ s: SessionInfo) -> Bool {
        if let kinds = s.clientKinds { return kinds.contains { $0 != "iphone" } }
        return s.clients > 0
    }
}

private struct Row: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var dimmed = false
    var busy = false
    var current = false
    var badge: DeviceBadge? = nil
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
                HStack(spacing: 4) {
                    if let badge {
                        badge.view
                        if !subtitle.isEmpty { Text("\u{00B7}").foregroundStyle(.secondary) }
                    }
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(badge == nil ? .middle : .tail)
                }
                .font(.caption)
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
