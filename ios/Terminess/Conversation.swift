import PhotosUI
import SwiftUI
import TermCore
import TermHost
import UniformTypeIdentifiers

struct SessionTarget: Identifiable {
    let id = UUID()
    var host: UUID
    var session: String?
    var title: String
    var cwd: String?
    var input: String?
}

enum ViewMode: String, CaseIterable, Identifiable {
    case chat, split, terminal
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .chat: return "bubble.left"
        case .split: return "rectangle.split.1x2"
        case .terminal: return "apple.terminal"
        }
    }
}

struct ModeSwitch: View {
    @Binding var mode: ViewMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases) { m in
                Button { withAnimation(.easeOut(duration: 0.15)) { mode = m } } label: {
                    Image(systemName: m.symbol).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(mode == m ? Theme.onInk : Color.secondary)
                        .frame(width: 36, height: 32)
                        .background(Capsule().fill(mode == m ? Theme.ink : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.surface))
    }
}

struct TopBar<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            DrawerButton {
                withAnimation(.easeOut(duration: 0.22)) { AppState.shared.drawerOpen = true }
            }
            if !title.isEmpty || subtitle != nil {
                VStack(alignment: .leading, spacing: 1) {
                    if !title.isEmpty { Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1) }
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 6)
    }
}

struct ConversationView: View {
    let target: SessionTarget
    @ObservedObject private var app = AppState.shared
    @StateObject private var model = ScreenModel()
    @StateObject private var chat = ChatModel()
    @State private var mode: ViewMode?
    @State private var modeChosen = false
    @State private var draft = ""
    @State private var error: String?
    @State private var attaching = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var uploading: Double?
    @State private var models: [AgentModel] = []
    @State private var currentModel: String?
    @State private var pendingModel: AgentModel?
    @State private var switchingModel = false
    @FocusState private var composing: Bool
    @Environment(\.scenePhase) private var phase

    private var connection: HostConnection { app.connection(target.host) }
    private var host: SavedHost? { HostStore.shared.host(target.host) }
    private var agentName: String { SessionText.agentName(model.command) ?? "" }
    private var asking: Bool { connection.sessions.first(where: { $0.id == model.sessionID })?.asking == true }
    private var question: QuestionInfo? { connection.sessions.first(where: { $0.id == model.sessionID })?.question }
    private var permission: PermissionInfo? { connection.sessions.first(where: { $0.id == model.sessionID })?.permission }
    private var sessionFolder: String? { target.cwd ?? connection.sessions.first(where: { $0.id == model.sessionID })?.cwd }

    private var title: String {
        if model.isAgent { return model.topic.isEmpty || model.topic == agentName ? agentName : model.topic }
        return model.command.isEmpty ? target.title : (["zsh", "bash", "fish", "sh"].contains(model.command) ? "Shell" : model.command)
    }

    private var subtitle: String? {
        if let e = error ?? model.status { return e }
        var parts: [String] = []
        if let cwd = target.cwd ?? connection.sessions.first(where: { $0.id == model.sessionID })?.cwd {
            parts.append(SessionText.folderName(cwd))
        }
        if HostStore.shared.hosts.count > 1, let host { parts.append(host.name) }
        if model.busy { parts.append("working") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: title, subtitle: subtitle) {
                ModeSwitch(mode: Binding(get: { mode ?? .terminal }, set: { mode = $0; modeChosen = true }))
            }
            content
            if (mode ?? .terminal) != .chat { keyRow }
            if let uploading {
                ProgressView(value: uploading) { Text("Sending to \(host?.name ?? "the machine")…").font(.caption) }
                    .padding(.horizontal, 20).padding(.bottom, 4)
            }
            Composer(text: $draft, placeholder: model.isAgent ? "Message \(agentName)" : "Type a command",
                     busy: model.busy, disabled: model.ended || switchingModel, focus: $composing,
                     onSend: send, onStop: { model.key(.escape) },
                     onPhoto: { showPhotos = true }, onFile: { showFiles = true }) {
                if !models.isEmpty { modelMenu }
                ForEach(statusChips) { c in Chip(text: c.text, symbol: c.symbol, percent: c.percent) }
            }
        }
        .background(Theme.background)
        .task {
            await attach()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if mode == nil { mode = .terminal }
        }
        .onChange(of: model.sessionID) { _, id in
            if let id { Task { await chat.follow(session: id, on: connection) } }
        }
        .task(id: model.command) { await loadModels() }
        .onReceive(model.$text) { _ in refreshCurrentModel() }
        .onAppear {
            if mode == nil, let input = target.input, input.hasPrefix("claude") || input.hasPrefix("codex") || input.contains(" chat ") || input.contains(" agent ") { mode = .chat }
        }
        .onChange(of: model.command) { _, _ in
            guard !modeChosen, !model.command.isEmpty else { return }
            if model.isAgent { mode = .chat } else if mode == nil { mode = .terminal }
        }
        .onChange(of: model.connected) { _, connected in
            if !connected, !model.ended, phase == .active {
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await attach()
                }
            }
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await attach() } }
            if p == .background { keepAliveBriefly() }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await sendPhoto(item) }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DemoScript.modeChange)) { n in
            if let m = n.object as? ViewMode { mode = m; modeChosen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: DemoScript.pickModel)) { n in
            if let i = n.object as? Int, i < models.count { pendingModel = models[i] }
        }
        .onReceive(NotificationCenter.default.publisher(for: DemoScript.sendText)) { n in
            if let t = n.object as? String { draft = t; send() }
        }
        #endif
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await sendFile(url) } }
        }
        .onDisappear {
            model.detach()
            chat.stop()
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case nil:
            Color.clear.frame(maxHeight: .infinity)
        case .terminal:
            TerminalScreen(model: model)
        case .chat:
            ChatView(chat: chat, agentName: agentName, working: model.busy && !asking, folder: sessionFolder)
                .safeAreaInset(edge: .bottom) {
                    if let q = question {
                        QuestionCard(question: q, agent: agentName.isEmpty ? "The agent" : agentName) { text in
                            guard let id = model.sessionID else { return }
                            Task { await connection.answer(session: id, questionID: q.id, text: text) }
                        }
                    } else if let p = permission {
                        ApprovalCard(request: p, agent: agentName.isEmpty ? "The agent" : agentName) { answer in
                            guard let id = model.sessionID else { return }
                            Task { await connection.decide(session: id, requestID: p.id, answer: answer) }
                        }
                    } else if asking {
                        HStack(spacing: 10) {
                            Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
                            Text("\(agentName.isEmpty ? "The agent" : agentName) is asking you something.")
                                .font(.callout)
                            Spacer(minLength: 8)
                            Button { mode = .split; modeChosen = true } label: {
                                Text("Answer").font(.callout.weight(.semibold)).foregroundStyle(Theme.onInk)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(Theme.ink))
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
                        .padding(.horizontal, 12).padding(.bottom, 6)
                    }
                }
        case .split:
            VStack(spacing: 0) {
                TerminalScreen(model: model).frame(maxHeight: .infinity)
                Divider()
                ChatView(chat: chat, agentName: agentName, working: model.busy, folder: sessionFolder).frame(maxHeight: .infinity)
            }
        }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { model.key(.escape) }
                key("tab") { model.key(.tab) }
                key("^C") { model.send([0x03]) }
                key("↑") { model.key(.up) }
                key("↓") { model.key(.down) }
                key("←") { model.key(.left) }
                key("→") { model.key(.right) }
                key("⏎") { model.send([0x0D]) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private func key(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Capsule().fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .disabled(model.ended)
    }

    private var modelMenu: some View {
        Menu {
            Section("Model for this session") {
                ForEach(models) { m in
                    Button { pendingModel = (m.name == currentModel) ? nil : m } label: {
                        if m.name == (pendingModel?.name ?? currentModel) { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                    }
                }
            }
        } label: {
            Chip(text: switchingModel ? "Switching…" : (pendingModel?.name ?? currentModel ?? "Model"), symbol: "cpu", menu: true)
        }
        .disabled(switchingModel || model.ended)
    }

    private var statusChips: [StatusChip] {
        guard !models.isEmpty, let current = currentModel else { return model.statusChips }
        return model.statusChips.filter { !$0.text.localizedCaseInsensitiveContains(current) }
    }

    private func loadModels() async {
        let agent = model.command
        guard agent == "claude" || agent == "codex" else {
            models = []; currentModel = nil; pendingModel = nil
            return
        }
        var list = await connection.agentModels(agent)
        if list.isEmpty, agent == "claude" { list = AgentModels.claude }
        guard agent == model.command else { return }
        models = list
        pendingModel = nil
        refreshCurrentModel()
    }

    private func refreshCurrentModel() {
        guard !models.isEmpty, !switchingModel,
              let seen = AgentModels.current(onScreen: model.terminal.screenText(), models: models) else { return }
        if currentModel != seen { currentModel = seen }
    }

    private func send() {
        let text = draft
        draft = ""
        guard let wanted = pendingModel else { model.sendLine(text); return }
        let agent = model.command
        Task {
            switchingModel = true
            while model.busy { try? await Task.sleep(nanoseconds: 300_000_000) }
            let ok = await AgentModels.switchModel(wanted, agentID: agent,
                                                   screen: { model.terminal.screenText() },
                                                   send: { model.send($0) })
            switchingModel = false
            pendingModel = nil
            guard ok else {
                draft = text
                let problem = "Couldn't switch to \(wanted.name), so your message wasn't sent."
                error = problem
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if error == problem { error = nil }
                return
            }
            currentModel = wanted.name
            model.sendLine(text)
        }
    }

    private func attach() async {
        guard !model.connected, !model.ended, !attaching else { return }
        attaching = true
        defer { attaching = false }
        await connection.connect()
        guard connection.isConnected else {
            if case .failed(let m) = connection.state { error = m }
            return
        }
        error = nil
        let screen = UIScreen.main.bounds.size
        let g = model.grid(for: CGSize(width: screen.width, height: screen.height * 0.55))
        let existing = model.sessionID ?? target.session
        let t: HostAttachment.Target = existing.map { .attach(id: $0) }
            ?? .create(cwd: target.cwd, command: nil, args: [], env: nil, name: nil)
        do {
            let a = try await connection.attachment(to: t, cols: g.cols, rows: g.rows)
            model.start(a, cols: g.cols, rows: g.rows, input: existing == nil ? target.input : nil)
            if let id = existing { await chat.follow(session: id, on: connection) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func keepAliveBriefly() {
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { UIApplication.shared.endBackgroundTask(task) }
    }

    private func sendPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { error = "Couldn't read that photo."; return }
        let jpeg = ImageShrinker.jpeg(data) ?? data
        await upload(jpeg, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
    }

    private func sendFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { error = "Couldn't read that file."; return }
        await upload(data, name: url.lastPathComponent)
    }

    private func upload(_ data: Data, name: String) async {
        uploading = 0
        defer { uploading = nil }
        do {
            let path = try await connection.upload(data, name: name) { p in uploading = p }
            draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + path.replacingOccurrences(of: " ", with: "\\ ") + " "
            composing = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct NewChatView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var store = HostStore.shared
    @State private var draft = ""
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading: Double?
    @State private var problem: String?
    @FocusState private var composing: Bool

    private var hostID: UUID? { app.newHost ?? store.hosts.first?.id }
    private var connection: HostConnection? { hostID.map { app.connection($0) } }
    private var agentName: String { SessionText.agentName(app.newAgent) ?? "Shell" }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "", subtitle: nil) { EmptyView() }
            Spacer()
            VStack(spacing: 14) {
                LogoMark(size: 64).foregroundStyle(Theme.ink.opacity(0.14))
                if let m = problem ?? store.pairing ?? connectionProblem {
                    Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                }
            }
            Spacer()
            if let uploading {
                ProgressView(value: uploading) { Text("Sending to \(store.host(hostID ?? UUID())?.name ?? "the machine")…").font(.caption) }
                    .padding(.horizontal, 20).padding(.bottom, 4)
            }
            Composer(text: $draft, placeholder: app.newAgent == "shell" ? "Type a command" : "Message \(agentName)",
                     disabled: connection?.isConnected != true, focus: $composing, onSend: start,
                     onPhoto: { showPhotos = true }, onFile: { showFiles = true }) {
                if store.hosts.count > 1 {
                    Menu {
                        ForEach(store.hosts) { h in Button(h.name) { app.newHost = h.id; app.newProject = nil } }
                    } label: { Chip(text: store.host(hostID ?? UUID())?.name ?? "Machine", symbol: "desktopcomputer", menu: true) }
                }
                Menu {
                    Button("Home folder") { app.newProject = nil }
                    ForEach(connection?.projects ?? [], id: \.path) { p in
                        Button(SessionText.folderName(p.path)) { app.newProject = p.path }
                    }
                } label: { Chip(text: app.newProject.map(SessionText.folderName) ?? "Home folder", symbol: "folder", menu: true) }
                Menu {
                    Button("Claude Code") { app.newAgent = "claude" }
                    Button("Codex") { app.newAgent = "codex" }
                    Button("Terminess Agent (your API key)") { app.newAgent = "harness" }
                    Button("Shell") { app.newAgent = "shell" }
                    Section("Local model") {
                        if let models = connection?.models, !models.isEmpty {
                            ForEach(models, id: \.self) { m in Button(m) { app.newAgent = "ollama:" + m } }
                        } else {
                            Text(connection?.models == nil ? "Ollama isn't running on this machine" : "No models installed in Ollama")
                        }
                    }
                } label: {
                    Chip(text: agentName, symbol: app.newAgent == "shell" ? "apple.terminal"
                         : app.newAgent.hasPrefix("ollama:") ? "cpu" : "sparkle", menu: true)
                }
            }
        }
        .background(Theme.background)
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await attachFile(url) } }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { problem = "Couldn't read that photo."; return }
                await attach(ImageShrinker.jpeg(data) ?? data, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
            }
        }
        .task(id: hostID) {
            if let c = connection {
                await c.connect()
                await c.loadProjects()
                await c.loadModels()
                if app.newProject == nil || !c.projects.contains(where: { $0.path == app.newProject }) {
                    app.newProject = c.projects.first?.path
                }
            }
        }
    }

    private var connectionProblem: String? {
        if let state = connection?.state, case .failed(let m) = state { return m }
        return nil
    }

    private func attachFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { problem = "Couldn't read that file."; return }
        await attach(data, name: url.lastPathComponent)
    }

    private func attach(_ data: Data, name: String) async {
        guard let connection else { return }
        uploading = 0
        defer { uploading = nil }
        do {
            let path = try await connection.upload(data, name: name) { p in uploading = p }
            draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + path.replacingOccurrences(of: " ", with: "\\ ") + " "
            problem = nil
            composing = true
        } catch {
            problem = error.localizedDescription
        }
    }

    private func start() {
        guard let hostID else { return }
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let quoted = "'" + message.replacingOccurrences(of: "'", with: "'\\''") + "'"
        draft = ""
        if app.newAgent.hasPrefix("ollama:") {
            let model = String(app.newAgent.dropFirst(7))
            let exe = store.host(hostID)?.terminessd ?? "~/.local/bin/terminessd"
            app.open(SessionTarget(host: hostID, session: nil, title: model, cwd: app.newProject,
                                   input: LocalModels.chatCommand(terminessd: exe, model: model, message: message)))
            return
        }
        if app.newAgent == "harness" {
            let exe = store.host(hostID)?.terminessd ?? "~/.local/bin/terminessd"
            app.open(SessionTarget(host: hostID, session: nil, title: "Terminess Agent", cwd: app.newProject,
                                   input: "\(exe) agent \(quoted)"))
            return
        }
        let input = app.newAgent == "shell" ? message : "\(app.newAgent) \(quoted)"
        app.open(SessionTarget(host: hostID, session: nil, title: agentName, cwd: app.newProject, input: input))
    }
}


struct ApprovalCard: View {
    let request: PermissionInfo
    let agent: String
    let answer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(agent) needs your approval").font(.callout.weight(.semibold))
            }
            Text(request.summary.isEmpty ? request.tool : "\(request.tool): \(request.summary)")
                .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4)
            HStack(spacing: 10) {
                Button { answer("deny") } label: {
                    Text("Deny").frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Capsule().strokeBorder(Theme.ink.opacity(0.3)))
                }
                if request.canAlways {
                    Button { answer("always") } label: {
                        Text("Always").frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Capsule().strokeBorder(Theme.ink.opacity(0.3)))
                    }
                }
                Button { answer("allow") } label: {
                    Text("Allow").font(.callout.weight(.semibold)).foregroundStyle(Theme.onInk)
                        .frame(maxWidth: .infinity).padding(.vertical, 8).background(Capsule().fill(Theme.ink))
                }
            }
            .font(.callout).foregroundStyle(Theme.ink)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raised))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}


struct QuestionCard: View {
    let question: QuestionInfo
    let agent: String
    let answer: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue)
                Text("\(agent) asks").font(.callout.weight(.semibold))
            }
            Text(question.text).font(.callout)
            ForEach(question.choices, id: \.self) { c in
                Button { answer(c) } label: {
                    Text(c).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Capsule().strokeBorder(Theme.ink.opacity(0.3)))
                }
                .foregroundStyle(Theme.ink)
            }
            HStack {
                TextField(question.choices.isEmpty ? "Your answer" : "Or write an answer", text: $text)
                    .textFieldStyle(.roundedBorder).onSubmit { if !text.isEmpty { answer(text) } }
                Button("Send") { answer(text) }.disabled(text.isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raised))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}
