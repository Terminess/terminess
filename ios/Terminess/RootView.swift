import SwiftUI
import TermHost

struct RootView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var store = HostStore.shared
    @Environment(\.scenePhase) private var phase
    @State private var drag: CGFloat = 0

    var body: some View {
        Group {
            if store.hosts.isEmpty {
                WelcomeView()
            } else {
                GeometryReader { geo in
                    let width = min(geo.size.width * 0.84, 360)
                    let offset = max(0, min(width, (app.drawerOpen ? width : 0) + drag))
                    ZStack(alignment: .leading) {
                        DrawerView().frame(width: width)
                        main
                            .frame(width: geo.size.width)
                            .background(Theme.background)
                            .overlay {
                                if offset > 0 {
                                    Theme.ink.opacity((Theme.appearance.isDark ? 0.11 : 0.06) * offset / width)
                                        .allowsHitTesting(false)
                                    Color.clear.contentShape(Rectangle())
                                        .onTapGesture { withAnimation(.easeOut(duration: 0.22)) { app.drawerOpen = false } }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: offset > 0 ? 28 : 0, style: .continuous))
                            .offset(x: offset)
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 18)
                                    .onChanged { v in
                                        if app.rowSwiping { drag = 0; return }
                                        let fromEdge = v.startLocation.x < 28
                                        if !app.drawerOpen && fromEdge && v.translation.width > 10 { hideKeyboard() }
                                        if app.drawerOpen && v.translation.width < 0 { drag = v.translation.width }
                                        else if !app.drawerOpen && fromEdge && v.translation.width > 0 { drag = v.translation.width }
                                    }
                                    .onEnded { v in
                                        if app.rowSwiping { drag = 0; return }
                                        withAnimation(.easeOut(duration: 0.22)) {
                                            if app.drawerOpen && v.translation.width < -60 { app.drawerOpen = false }
                                            else if !app.drawerOpen && v.startLocation.x < 28 && v.translation.width > 60 { app.drawerOpen = true }
                                            drag = 0
                                        }
                                    }
                            )
                    }
                }
                .background(Theme.background.ignoresSafeArea())
            }
        }
        .task { app.start() }
        .onChange(of: store.hosts.count) { _, _ in
            app.start()
            PushPermission.askIfUseful()
        }
        .onChange(of: phase) { _, p in if p == .active { app.resume() } }
        .onChange(of: app.drawerOpen) { _, open in if open { hideKeyboard() } }
    }

    @ViewBuilder private var main: some View {
        if let target = app.current {
            ConversationView(target: target).id(target.id)
        } else {
            NewChatView()
        }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct DrawerView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var store = HostStore.shared
    @State private var search = ""
    @State private var searching = false
    @State private var collapsed: Set<String> = []
    @State private var showAll: Set<String> = []

    private var multipleMachines: Bool { store.hosts.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Terminess").font(.system(size: 20, weight: .bold))
                Spacer()
                CircleButton(symbol: "magnifyingglass") { searching = true }
            }
            .padding(.leading, 20).padding(.trailing, 14).padding(.top, 4).padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let running = app.running.filter { matches(SessionText.title($0.session) + " " + $0.session.cwd) }
                    let recent = app.recent.filter { matches($0.item.title + " " + $0.item.cwd) }
                    let grouped = projectGroups(running: running, recent: recent)
                    let reminders = app.reminders.filter { search.isEmpty || matches($0.reminder.title) }
                    if !reminders.isEmpty {
                        header("Reminders")
                        ForEach(reminders, id: \.reminder.id) { entry in
                            ReminderRow(reminder: entry.reminder, machine: multipleMachines ? entry.host.name : nil,
                                        proceed: { Task { await app.proceed(entry.reminder, on: entry.host.id) } },
                                        dismiss: { app.dismiss(entry.reminder, on: entry.host.id) })
                        }
                    }
                    if !store.hosts.isEmpty && search.isEmpty {
                        header("Machines")
                        ForEach(store.hosts) { h in MachineListRow(host: h, connection: app.connection(h.id)) }
                        ForEach(connectedMacs, id: \.name) { mac in
                            DeviceListRow(symbol: "laptopcomputer", name: mac.name,
                                          detail: mac.viewing.count == 1 ? "viewing \(mac.viewing[0])" : "\(mac.viewing.count) sessions open")
                        }
                    }
                    ForEach(grouped.groups, id: \.key) { group in
                        GroupHeader(title: group.title, open: isOpen(group.key)) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if collapsed.contains(group.key) { collapsed.remove(group.key) } else { collapsed.insert(group.key) }
                            }
                        }
                        if isOpen(group.key) {
                            ForEach(group.live, id: \.session.id) { entry in liveRow(entry, showFolder: false) }
                            ForEach(group.visible, id: \.item.id) { entry in
                                Button { resume(entry.item, on: entry.host) } label: {
                                    HistoryRow(item: entry.item, machine: multipleMachines ? entry.host.name : nil)
                                }
                                .buttonStyle(.plain)
                            }
                            if group.more > 0 && search.isEmpty {
                                Button(showAll.contains(group.key) ? "Show less" : "Show \(group.more) more") {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        if showAll.contains(group.key) { showAll.remove(group.key) } else { showAll.insert(group.key) }
                                    }
                                }
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(.leading, 48).padding(.vertical, 6)
                            }
                        }
                    }
                    if !grouped.loose.isEmpty {
                        header("Other")
                        ForEach(grouped.loose, id: \.session.id) { entry in liveRow(entry, showFolder: true) }
                    }
                    ForEach(store.hosts) { h in
                        if case .failed(let message) = app.connection(h.id).state {
                            header(h.name)
                            Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                        }
                    }
                    if running.isEmpty && recent.isEmpty && search.isEmpty {
                        Text("Nothing yet. Start a new chat below.").foregroundStyle(.secondary).padding(20)
                    }
                }
                .padding(.bottom, 20)
            }
            .refreshable { await app.loadHistory() }

            HStack {
                Button { app.newChat() } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.onInk)
                        .padding(.horizontal, 20).padding(.vertical, 13)
                        .background(Capsule().fill(Theme.ink))
                }
                Spacer()
                CircleButton(symbol: "gearshape") { app.showSettings = true }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .task { await app.loadHistory() }
        .fullScreenCover(isPresented: $searching) { SearchView() }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
    }

    private typealias Live = (host: SavedHost, session: SessionInfo)
    private typealias Past = (host: SavedHost, item: HistoryItem)

    private struct ProjectGroup {
        let key: String
        let title: String
        let live: [Live]
        let visible: [Past]
        let more: Int
    }

    private func projectGroups(running: [Live], recent: [Past]) -> (loose: [Live], groups: [ProjectGroup]) {
        var known: [UUID: [String]] = [:]
        for h in store.hosts {
            let c = app.connection(h.id)
            known[h.id] = c.history.map(\.cwd) + c.projects.map(\.path)
        }
        func project(_ cwd: String, _ host: SavedHost) -> String? {
            ProjectGrouping.pathProject(cwd: cwd, knownFolders: known[host.id] ?? [])
        }
        var loose: [Live] = []
        var live: [String: [Live]] = [:]
        for e in running {
            if let p = project(e.session.cwd, e.host) { live[p, default: []].append(e) } else { loose.append(e) }
        }
        var past: [String: [Past]] = [:]
        for e in recent.sorted(by: { $0.item.used > $1.item.used }) {
            let p = project(e.item.cwd, e.host) ?? SessionText.folderName(e.item.cwd)
            past[p, default: []].append(e)
        }
        let keys = Set(live.keys).union(past.keys)
        let groups = keys.map { key -> ProjectGroup in
            let items = past[key] ?? []
            let shown = ProjectGrouping.limited(items, expanded: showAll.contains(key) || !search.isEmpty)
            return ProjectGroup(key: key, title: key, live: live[key] ?? [], visible: shown.visible, more: shown.more)
        }
        func lastActive(_ g: ProjectGroup) -> Double {
            max(g.live.compactMap { $0.session.active }.max() ?? 0, (past[g.key] ?? []).first?.item.used ?? 0)
        }
        let ordered = groups.sorted { a, b in
            if a.live.isEmpty != b.live.isEmpty { return !a.live.isEmpty }
            return lastActive(a) > lastActive(b)
        }
        return (loose.sorted { ($0.session.active ?? 0) > ($1.session.active ?? 0) }, ordered)
    }

    private func liveRow(_ entry: Live, showFolder: Bool) -> some View {
        let others = DevicePresence.others(entry.session, ownKind: "iphone", ownName: DeviceName.current,
                                           attachedHere: app.current?.session == entry.session.id)
        return SwipeToEnd(busy: entry.session.busy == true) { app.end(entry.session, on: entry.host) } content: {
            Button { app.open(SessionTarget(host: entry.host.id, session: entry.session.id, title: SessionText.title(entry.session))) } label: {
                RunningRow(session: entry.session, machine: entry.host.name,
                           role: MachineRole.clean(entry.host.role),
                           selected: app.current?.session == entry.session.id,
                           showFolder: showFolder, others: others,
                           machineSymbol: app.connection(entry.host.id).symbol,
                           machineConnected: app.connection(entry.host.id).state == .connected)
            }
            .buttonStyle(.plain)
        }
    }

    private var connectedMacs: [(name: String, viewing: [String])] {
        var byName: [String: [String]] = [:]
        for entry in app.running {
            let s = entry.session
            for d in s.clientDevices ?? (s.clientKinds ?? []).map({ ClientDevice(kind: $0) }) where d.kind == "mac" {
                byName[DevicePresence.displayName(d), default: []].append(SessionText.title(s))
            }
        }
        return byName.keys.sorted().map { ($0, byName[$0]!.sorted()) }
    }

    private func isOpen(_ key: String) -> Bool { !collapsed.contains(key) || !search.isEmpty }

    private func matches(_ s: String) -> Bool {
        search.isEmpty || s.localizedCaseInsensitiveContains(search)
    }

    private func resume(_ item: HistoryItem, on host: SavedHost) {
        let command = item.agent == "codex" ? "codex resume \(item.id)" : "claude --resume \(item.id)"
        app.open(SessionTarget(host: host.id, session: nil, title: item.title, cwd: item.cwd, input: command, resumeOf: item.id))
    }
}

struct RunningRow: View {
    let session: SessionInfo
    let machine: String?
    let selected: Bool
    var showFolder = true
    var others: [ClientDevice] = []
    var machineSymbol = "server.rack"

    var machineConnected = false

    init(session: SessionInfo, machine: String?, role: String? = nil, selected: Bool, showFolder: Bool = true,
         others: [ClientDevice] = [], machineSymbol: String = "server.rack", machineConnected: Bool = false) {
        self.session = session; self.machine = machine; self.role = role; self.selected = selected
        self.showFolder = showFolder; self.others = others; self.machineSymbol = machineSymbol
        self.machineConnected = machineConnected
    }
    let role: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionText.title(session)).font(.system(size: 17)).lineLimit(1)
                HStack(spacing: 5) {
                    if let machine {
                        HStack(spacing: 2) {
                            Image(systemName: machineSymbol).font(.system(size: 10, weight: .regular))
                            Text(role.map { "\(machine) · \($0)" } ?? machine)
                        }
                        .foregroundStyle(machineConnected ? Color.connected : Color.secondary)
                        .layoutPriority(2)
                    }
                    if let label = DevicePresence.connectedLabel(others) {
                        DeviceBadge(symbol: DevicePresence.symbol(others), label: label, connected: true)
                            .layoutPriority(1)
                    }
                    Text([showFolder ? SessionText.folderName(session.cwd) : nil, SessionText.state(session)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                .font(.footnote).lineLimit(1)
            }
            Spacer(minLength: 4)
            if session.busy == true { ProgressView().controlSize(.small) }
            else if session.attention == true { Circle().fill(Theme.attention).frame(width: 9, height: 9) }
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(selected ? Theme.surface : Color.clear)
        .contentShape(Rectangle())
    }
}

struct DeviceBadge: View {
    let symbol: String
    let label: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10, weight: .regular))
            Text(label).fontWeight(.regular).lineLimit(1)
        }
        .foregroundStyle(connected ? Color.connected : Color.secondary)
        .fixedSize()
    }
}

struct MachineListRow: View {
    let host: SavedHost
    @ObservedObject var connection: HostConnection

    private var state: (text: String, color: Color) {
        switch connection.state {
        case .connected: return ("connected", Color.connected)
        case .connecting: return ("connecting", Color.secondary)
        case .failed: return ("offline", Theme.attention)
        case .idle: return ("not connected", Color.secondary)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: connection.symbol).font(.system(size: 15, weight: .regular))
                .foregroundStyle(connection.state == .connected ? Color.connected : Color.secondary)
                .frame(width: 22)
            Text(host.name).font(.system(size: 17)).lineLimit(1)
            if let role = MachineRole.clean(host.role) {
                Text(role).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5))
            }
            Spacer(minLength: 4)
            Text(state.text).font(.footnote).foregroundStyle(state.color)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }
}

struct DeviceListRow: View {
    let symbol: String
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular)).foregroundStyle(Color.connected).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 17)).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("connected").font(.footnote).foregroundStyle(Color.connected)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }
}

struct ReminderRow: View {
    let reminder: ReminderInfo
    let machine: String?
    let proceed: () -> Void
    let dismiss: () -> Void

    private var due: Bool { reminder.fired == true }

    private var when: String {
        let d = Date(timeIntervalSince1970: reminder.due)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: due ? "bell.badge.fill" : "clock")
                .foregroundStyle(due ? Theme.attention : Color.secondary)
                .frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title).font(.system(size: 17)).lineLimit(2)
                Text([due ? "due" : when, reminder.body, machine].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                if due {
                    HStack(spacing: 10) {
                        Button(reminder.label, action: proceed)
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.onInk)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.ink))
                        Button("Dismiss", action: dismiss)
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            if !due {
                Button(action: dismiss) { Image(systemName: "xmark").font(.footnote) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel reminder")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
    }
}

struct GroupHeader: View {
    let title: String
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    var machine: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left").font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.agent == "codex" ? Color(red: 0.36, green: 0.62, blue: 0.95) : Color(red: 0.85, green: 0.47, blue: 0.34))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 16)).lineLimit(1)
                Text([SessionText.relative(item.used), machine,
                      (item.commitsSince ?? 0) > 0 ? "\(item.commitsSince!) commits since" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
        .opacity(0.58)
        .contentShape(Rectangle())
    }
}

struct SwipeToEnd<Content: View>: View {
    let busy: Bool
    let onEnd: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var confirming = false
    private let width: CGFloat = 84

    var body: some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                Button { request() } label: {
                    Text("End").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: max(width, -offset)).frame(maxHeight: .infinity)
                        .background(Color.red)
                }
                .buttonStyle(.plain)
            }
            content()
                .background(Theme.background)
                .overlay {
                    if offset < 0 {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { offset = 0 } }
                    }
                }
                .offset(x: offset)
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    AppState.shared.rowSwiping = true
                    let start: CGFloat = offset < 0 && v.translation.width > -width ? -width : 0
                    offset = min(0, max(-width * 3, start + v.translation.width))
                }
                .onEnded { v in
                    let full = offset < -width * 2.2
                    withAnimation(.easeOut(duration: 0.2)) { offset = full ? -width : (offset < -width / 2 ? -width : 0) }
                    if full { request() }
                    DispatchQueue.main.async { AppState.shared.rowSwiping = false }
                }
        )
        .contextMenu {
            Button(role: .destructive) { request() } label: { Label("End Session", systemImage: "xmark.circle") }
        }
        .confirmationDialog("End this session?", isPresented: $confirming, titleVisibility: .visible) {
            Button("End Session", role: .destructive) { end() }
            Button("Cancel", role: .cancel) { withAnimation(.easeOut(duration: 0.2)) { offset = 0 } }
        } message: {
            Text("The agent is still working. Ending the session stops it.")
        }
    }

    private func request() {
        if busy { confirming = true } else { end() }
    }

    private func end() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        onEnd()
    }
}


extension Color {
    static let connected = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.68, blue: 0.40, alpha: 1)
            : UIColor(red: 0.13, green: 0.50, blue: 0.24, alpha: 1)
    })
}
