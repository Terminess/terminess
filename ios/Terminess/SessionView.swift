import PhotosUI
import SwiftUI
import TermCore
import TermHost
import UniformTypeIdentifiers

struct SessionTarget: Identifiable {
    let id = UUID()
    var session: String?
    var title: String
    var cwd: String?
    var input: String?
}

enum ViewMode: String, CaseIterable, Identifiable {
    case terminal = "Terminal", split = "Split", chat = "Chat"
    var id: String { rawValue }
}

struct SessionView: View {
    @ObservedObject var connection: HostConnection
    let target: SessionTarget
    @StateObject private var model = ScreenModel()
    @StateObject private var chat = ChatModel()
    @State private var mode: ViewMode?
    @State private var draft = ""
    @State private var error: String?
    @State private var attaching = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var uploading: Double?
    @FocusState private var composing: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    private var agentName: String {
        switch model.command {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return ""
        }
    }

    private var heading: String {
        if model.isAgent { return model.topic.isEmpty || model.topic == agentName ? agentName : model.topic }
        return target.title
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            if (mode ?? .terminal) != .chat { keyRow }
            composer
        }
        .task { await attach() }
        .onChange(of: model.sessionID) { _, id in
            if let id { Task { await chat.follow(session: id, on: connection) } }
        }
        .onChange(of: model.command) { _, _ in
            if mode == nil, !model.command.isEmpty { mode = model.isAgent ? .chat : .terminal }
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
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await sendFile(url) } }
        }
        .onDisappear {
            model.detach()
            chat.stop()
        }
    }


    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(heading).font(.headline).lineLimit(1)
                    if let status = error ?? model.status {
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if model.busy {
                        Text("Working…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            Picker("View", selection: Binding(get: { mode ?? .terminal }, set: { mode = $0 })) {
                ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        switch mode ?? .terminal {
        case .terminal:
            TerminalScreen(model: model)
        case .chat:
            ChatView(chat: chat, agentName: agentName, working: model.busy)
        case .split:
            VStack(spacing: 0) {
                TerminalScreen(model: model).frame(maxHeight: .infinity)
                Divider()
                ChatView(chat: chat, agentName: agentName, working: model.busy).frame(maxHeight: .infinity)
            }
        }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                key("esc") { model.key(.escape) }
                key("tab") { model.key(.tab) }
                key("^C") { model.send([0x03]) }
                key("↑") { model.key(.up) }
                key("↓") { model.key(.down) }
                key("←") { model.key(.left) }
                key("→") { model.key(.right) }
                key("⏎") { model.send([0x0D]) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    private func key(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
        }
        .buttonStyle(.plain)
        .disabled(model.ended)
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let uploading {
                ProgressView(value: uploading) { Text("Sending to \(connection.host?.name ?? "the machine")…").font(.caption) }
                    .padding(.horizontal, 14)
            }
            HStack(alignment: .center, spacing: 8) {
                Menu {
                    Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 26))
                }
                .disabled(model.ended || uploading != nil)
                TextField(model.isAgent ? "Message \(agentName)" : "Command", text: $draft)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .focused($composing)
                    .textInputAutocapitalization(model.isAgent ? .sentences : .never)
                    .autocorrectionDisabled(!model.isAgent)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                if model.busy && draft.isEmpty {
                    Button { model.key(.escape) } label: { Image(systemName: "stop.circle.fill").font(.system(size: 30)) }
                        .foregroundStyle(.primary)
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                        .disabled(model.ended)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 4)
        }
    }


    private func send() {
        model.sendLine(draft)
        draft = ""
        composing = true
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
        let stamp = Int(Date().timeIntervalSince1970)
        await upload(jpeg, name: "photo-\(stamp).jpg")
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
            let escaped = path.replacingOccurrences(of: " ", with: "\\ ")
            draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + escaped + " "
            composing = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TerminalScreen: View {
    @ObservedObject var model: ScreenModel

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.text)
                        .font(Font(model.font))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("screen")
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.text) { _, _ in proxy.scrollTo("screen", anchor: .bottom) }
            }
            .onAppear { fit(geo.size) }
            .onChange(of: geo.size) { _, size in fit(size) }
        }
        .background(model.background)
    }

    private func fit(_ size: CGSize) {
        guard size.width > 50, size.height > 50 else { return }
        let g = model.grid(for: size)
        model.resize(cols: g.cols, rows: g.rows)
    }
}

enum ImageShrinker {
    static func jpeg(_ data: Data, maxSide: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
