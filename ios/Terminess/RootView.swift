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
                    if !running.isEmpty {
                        header("Running")
                        ForEach(running, id: \.session.id) { entry in
                            SwipeToEnd(busy: entry.session.busy == true) { app.end(entry.session, on: entry.host) } content: {
                                Button { app.open(SessionTarget(host: entry.host.id, session: entry.session.id, title: SessionText.title(entry.session))) } label: {
                                    RunningRow(session: entry.session, machine: multipleMachines ? entry.host.name : nil,
                                               selected: app.current?.session == entry.session.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    let recent = app.recent.filter { matches($0.item.title + " " + $0.item.cwd) }
                    ForEach(groups(recent), id: \.key) { group in
                        GroupHeader(title: group.title, open: isOpen(group.key)) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if collapsed.contains(group.key) { collapsed.remove(group.key) } else { collapsed.insert(group.key) }
                            }
                        }
                        if isOpen(group.key) {
                            ForEach(group.visible, id: \.item.id) { entry in
                                Button { resume(entry.item, on: entry.host) } label: {
                                    HistoryRow(item: entry.item)
                                }
                                .buttonStyle(.plain)
                            }
                            if group.hidden > 0 || showAll.contains(group.key) {
                                Button(showAll.contains(group.key) ? "Show less" : "Show \(group.hidden) more") {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        if showAll.contains(group.key) { showAll.remove(group.key) } else { showAll.insert(group.key) }
                                    }
                                }
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(.leading, 48).padding(.vertical, 6)
                            }
                        }
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

    private struct HistoryGroup {
        let key: String
        let title: String
        let visible: [(host: SavedHost, item: HistoryItem)]
        let hidden: Int
    }

    private func groups(_ entries: [(host: SavedHost, item: HistoryItem)]) -> [HistoryGroup] {
        var order: [String] = []
        var byKey: [String: [(host: SavedHost, item: HistoryItem)]] = [:]
        for e in entries.sorted(by: { $0.item.used > $1.item.used }) {
            let key = e.host.id.uuidString + ":" + e.item.cwd
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(e)
        }
        let cutoff = Date().timeIntervalSince1970 - 6 * 3600
        return order.map { key in
            let all = byKey[key] ?? []
            let folder = SessionText.folderName(all.first?.item.cwd ?? "")
            let title = multipleMachines ? "\(folder) · \(all.first?.host.name ?? "")" : folder
            if !search.isEmpty || showAll.contains(key) { return HistoryGroup(key: key, title: title, visible: all, hidden: 0) }
            let shown = all.enumerated().filter { $0.offset < 5 || $0.element.item.used > cutoff }.map(\.element)
            return HistoryGroup(key: key, title: title, visible: shown, hidden: all.count - shown.count)
        }
    }

    private func isOpen(_ key: String) -> Bool { !collapsed.contains(key) || !search.isEmpty }

    private func matches(_ s: String) -> Bool {
        search.isEmpty || s.localizedCaseInsensitiveContains(search)
    }

    private func resume(_ item: HistoryItem, on host: SavedHost) {
        let command = item.agent == "codex" ? "codex resume \(item.id)" : "claude --resume \(item.id)"
        app.open(SessionTarget(host: host.id, session: nil, title: item.title, cwd: item.cwd, input: command))
    }
}

struct RunningRow: View {
    let session: SessionInfo
    let machine: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionText.title(session)).font(.system(size: 17)).lineLimit(1)
                Text(([SessionText.folderName(session.cwd), machine] + [SessionText.state(session)]).compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left").font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.agent == "codex" ? Color(red: 0.36, green: 0.62, blue: 0.95) : Color(red: 0.85, green: 0.47, blue: 0.34))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 16)).lineLimit(1)
                Text(SessionText.relative(item.used)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
        .opacity(Date().timeIntervalSince1970 - item.used < 86_400 ? 1 : 0.58)
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
