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
                                    Color.white.opacity(0.11 * offset / width)
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
                                        let fromEdge = v.startLocation.x < 28
                                        if app.drawerOpen && v.translation.width < 0 { drag = v.translation.width }
                                        else if !app.drawerOpen && fromEdge && v.translation.width > 0 { drag = v.translation.width }
                                    }
                                    .onEnded { v in
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
        .sheet(isPresented: $app.showSettings) { SettingsView() }
        .task { app.start() }
        .onChange(of: store.hosts.count) { _, _ in app.start() }
        .onChange(of: phase) { _, p in if p == .active { app.resume() } }
    }

    @ViewBuilder private var main: some View {
        if let target = app.current {
            ConversationView(target: target).id(target.id)
        } else {
            NewChatView()
        }
    }
}

struct DrawerView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var store = HostStore.shared
    @State private var search = ""
    @State private var searching = false

    private var multipleMachines: Bool { store.hosts.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Terminess").font(.system(size: 28, weight: .bold))
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
                            Button { app.open(SessionTarget(host: entry.host.id, session: entry.session.id, title: SessionText.title(entry.session))) } label: {
                                RunningRow(session: entry.session, machine: multipleMachines ? entry.host.name : nil,
                                           selected: app.current?.session == entry.session.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    let recent = app.recent.filter { matches($0.item.title + " " + $0.item.cwd) }
                    if !recent.isEmpty {
                        header("Recent")
                        ForEach(recent, id: \.item.id) { entry in
                            Button { resume(entry.item, on: entry.host) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.item.title).font(.system(size: 17)).lineLimit(1)
                                    Text([SessionText.folderName(entry.item.cwd), multipleMachines ? entry.host.name : nil,
                                          SessionText.relative(entry.item.used)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 13)
                        .background(Capsule().fill(.white))
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
