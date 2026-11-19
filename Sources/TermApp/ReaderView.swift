import TermTranscript
import TermHost
import AppKit
import SwiftUI

@MainActor
final class ReaderModel: ObservableObject {
    @Published var items: [TranscriptItem] = [] { didSet { settlePending() } }
    @Published var pending: [PendingMessage] = []

    struct PendingMessage: Identifiable {
        let id = UUID()
        let text: String
        let sent = Date()
        let seenBefore: Int
    }

    @Published private(set) var queued: [String] = []

    func setQueued(_ texts: [String]) {
        let sent = Set(pending.map { Self.norm($0.text) })
        let list = texts.filter { !sent.contains(Self.norm($0)) }
        if list != queued { queued = list }
    }

    func addPending(_ text: String) {
        pending.append(PendingMessage(text: text, seenBefore: userCount(text)))
    }

    private func userCount(_ text: String) -> Int {
        let t = Self.norm(text)
        return items.reduce(0) { n, item in
            if case .user(let u) = item.kind, Self.norm(u) == t { return n + 1 }
            return n
        }
    }

    private static func norm(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func settlePending() {
        guard !pending.isEmpty else { return }
        let now = Date()
        let left = pending.filter { p in userCount(p.text) <= p.seenBefore && now.timeIntervalSince(p.sent) < 600 }
        if left.count != pending.count { pending = left }
    }
    @Published var agentName = ""
    @Published var agentID = ""
    @Published var live = false
    var drops: WindowLink?
    @Published var working = false
    var activity: (() -> Date?)?
    var menuWaiting: (() -> Bool)?
    private var watcher: DispatchSourceFileSystemObject?
    private var path: String?
    private var lastMTime: Date?
    private var timer: Timer?
    private var source: (() -> ReaderSource?)?
    var folder: (() -> String?)?
    var startHere: ((_ path: String, _ command: String) -> Void)?
    var machineID = ""
    var gate = ViewGate()
    var onUserMessage: ((String) -> Void)?
    var onFound: ((Int32, String, String) -> Void)?
    var visible = false { didSet { visible ? start() : stop() } }

    func follow(_ source: @escaping () -> ReaderSource?) {
        self.source = source
        if visible { refresh(force: true) }
    }

    private func start() {
        refresh(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(force: Bool = false) {
        let busy = live && !(menuWaiting?() ?? false) && (activity?().map { Date().timeIntervalSince($0) < 2.5 } ?? false)
        if busy != working { working = busy }
        switch source?() ?? .none {
        case .none:
            clear()
        case .file(let agent, let path, let live):
            show(agent: agent, path: path, live: live, force: force)
        case .find(let agent, let dir, let pid, let started, let args):
            Task.detached(priority: .utility) {
                let path = Transcript.locate(agent: agent, directory: dir, started: started, arguments: args, pid: pid)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let path {
                        self.onFound?(pid, agent, path)
                        self.show(agent: agent, path: path, live: true, force: true)
                    } else {
                        self.clear(agent: agent)
                    }
                }
            }
        }
    }

    private func watch(_ path: String, agent: String) {
        watcher?.cancel()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.path == path else { return }
                self.show(agent: agent, path: path, live: self.live, force: false)
            }
        }
        src.setCancelHandler { close(fd) }
        watcher = src
        src.resume()
    }

    private func clear(agent: String? = nil) {
        watcher?.cancel()
        watcher = nil
        if !items.isEmpty { items = [] }
        path = nil
        lastMTime = nil
        let id = agent ?? ""
        let name = agent == "claude" ? "Claude Code" : agent == "codex" ? "Codex" : agent == "ollama" ? "Local model" : agent == "harness" ? "Terminess Agent" : ""
        if agentID != id { agentID = id }
        if agentName != name { agentName = name }
        if live { live = false }
    }

    private func show(agent: String, path: String, live: Bool, force: Bool) {
        let name = agent == "claude" ? "Claude Code" : agent == "ollama" ? "Local model" : agent == "harness" ? "Terminess Agent" : "Codex"
        if agentID != agent { agentID = agent }
        if agentName != name { agentName = name }
        if self.live != live { self.live = live }
        let mtime = Transcript.mtime(path)
        guard force || path != self.path || mtime != lastMTime else { return }
        if path != self.path { watch(path, agent: agent) }
        self.path = path
        lastMTime = mtime
        Task.detached(priority: .utility) {
            let parsed = Transcript.parse(path, agent: agent)
            await MainActor.run { [weak self] in
                guard let self, self.path == path else { return }
                let latest = Array(parsed.suffix(400))
                if latest != self.items { self.items = latest }
                for item in parsed {
                    if case .user(let text) = item.kind { self.onUserMessage?(text); break }
                }
            }
        }
    }
}

struct ReaderView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        let _ = PerfCounters.tick("body.reader")
        content.noTopScrollEdge()
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !model.agentName.isEmpty || !model.items.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .foregroundStyle(model.agentID == "codex" ? Color(nsColor: Agent.codex.tint) : Color(nsColor: Agent.claude.tint))
                Text(model.agentName.isEmpty ? "Chat" : model.agentName).font(.headline)
                Spacer()
                if model.live {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("Live").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            }
            if model.items.isEmpty && model.agentName.isEmpty {
                NewSessionView(gate: model.gate, tabMachine: model.machineID, startHere: { model.startHere?($0, $1) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty && model.pending.isEmpty && model.queued.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(model.agentName.isEmpty ? "No agent in this tab" : "No messages yet").font(.headline).foregroundStyle(.secondary)
                    Text(model.agentName.isEmpty
                         ? "Start Claude Code or Codex here and this tab's conversation appears, formatted for reading."
                         : "Send a message and the conversation appears here.")
                        .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 260)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(model.items) { item in
                                ItemView(item: item, folder: model.folder?()).id(item.id)
                            }
                            ForEach(Array(model.queued.enumerated()), id: \.offset) { _, text in
                                UserBubble(text: text, pending: true)
                            }
                            ForEach(model.pending) { p in
                                UserBubble(text: p.text, pending: true)
                            }
                            if model.working {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("\(model.agentName) is working…").font(.callout).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                .transition(.opacity)
                            }
                            Color.clear.frame(height: 4).id("end")
                        }
                        .padding(16)
                    }
                    .onChange(of: model.working) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onChange(of: model.items.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onChange(of: model.pending.count + model.queued.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 300)
        .onDrop(of: Drops.utTypes, isTargeted: nil) { _ in model.drops?.dropFromSwiftUI() ?? false }
    }
}

struct ItemView: View {
    let item: TranscriptItem
    var folder: String? = nil
    @State private var expanded = false

    private func short(_ s: String) -> String {
        var out = s
        if let f = folder, !f.isEmpty, f != "/" { out = out.replacingOccurrences(of: f + "/", with: "") }
        for h in Set([Transcript.home, NSHomeDirectory()]) where h.count > 1 {
            out = out.replacingOccurrences(of: h + "/", with: "~/")
            out = out.replacingOccurrences(of: #"\#(NSRegularExpression.escapedPattern(for: h))(?![\w.-])"#, with: "~", options: .regularExpression)
        }
        return out
    }

    var body: some View {
        switch item.kind {
        case .user(let text):
            UserBubble(text: text).modifier(RememberMenu(text: text, folder: folder))

        case .assistant(let text):
            MarkdownView(text: text).padding(.horizontal, 12)
                .modifier(RememberMenu(text: text, folder: folder))

        case .thinking(let text):
            DisclosureGroup(isExpanded: $expanded) {
                Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            } label: {
                Label("Thinking", systemImage: "brain").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))

        case .tool(let name, let summary, let detail, let result):
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if !detail.isEmpty && detail != summary {
                        Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let result, !result.isEmpty {
                        Text(result).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).lineLimit(40).fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol(name)).foregroundStyle(.secondary).frame(width: 16)
                    Text(name).font(.callout.weight(.medium))
                    Text(short(summary)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    if result == nil { ProgressView().controlSize(.mini) }
                    if let command = pairCommand(name: name, detail: detail) {
                        Spacer(minLength: 8)
                        Button { ItemView.openPairRun(command) } label: {
                            Label(command.contains("--to claude") ? "Watch Claude" : "Watch Codex", systemImage: "eye")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .help("See what the other agent is doing: its commands, their output and its answer.")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
        }
    }

    private func pairCommand(name: String, detail: String) -> String? {
        guard ["Bash", "Shell", "shell", "exec_command"].contains(name), detail.contains("pair") else { return nil }
        let obj = (try? JSONSerialization.jsonObject(with: Data(detail.utf8))) as? [String: Any]
        let command = (obj?["command"] as? String) ?? detail
        guard command.firstMatch(of: #/(^|[\s;&|(])pair\s+(ask|review|handoff|parallel)\b/#) != nil else { return nil }
        return command
    }

    static func openPairRun(_ command: String) {
        Task.detached(priority: .userInitiated) {
            let run = PairRuns.run(forCommand: command)
            await MainActor.run {
                if let run { PairRunWindows.show(run) } else { NSSound.beep() }
            }
        }
    }

    private func symbol(_ tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "exec", "exec_command", "shell": return "terminal"
        case "read", "view": return "doc.text"
        case "edit", "write", "multiedit", "apply_patch": return "pencil"
        case "grep", "glob", "search": return "magnifyingglass"
        case "webfetch", "websearch": return "globe"
        case "task", "agent": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class ComposerState: ObservableObject {
    @Published var busy = false
    @Published var agentID: String?
    @Published var models: [AgentModels.Model] = []
    @Published var model: String?
    @Published var pendingModel: AgentModels.Model?
    @Published var switching = false
    @Published var draft = ""
    @Published var status = StatusSummary()
    @Published var machine = "This Mac"
    @Published var machineSymbol = "laptopcomputer"
    @Published var folderPath: String?
    var drops: WindowLink?
}

struct ComposerView: View {
    let placeholder: String
    @ObservedObject var state: ComposerState
    let onSend: (String) -> Void
    let onStop: () -> Void
    let onEscape: () -> Void
    private var text: String {
        get { state.draft }
        nonmutating set { state.draft = newValue }
    }
    @State private var height: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: attach) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .regular))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add files or images")
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(.system(size: 14)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 2)
                    }
                    ComposerTextView(text: $state.draft, height: $height, onSend: send, onEscape: escape)
                        .frame(height: min(max(height, 24), 160))
                }
                if state.busy && text.isEmpty {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop the agent (Esc or Cmd-.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(text.isEmpty ? Color.secondary.opacity(0.6) : Color.primary)
                    .disabled(text.isEmpty)
                    .help("Send (Return)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5)))

            controlRow
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .padding(.top, 6)
        .onDrop(of: Drops.utTypes, isTargeted: nil) { _ in state.drops?.dropFromSwiftUI() ?? false }
    }

    private var controlRow: some View {
        let st = state.status
        return HStack(spacing: 14) {
            ControlLabel(symbol: state.machineSymbol, text: state.machine)
                .help("Where this session runs")
            if let folder = st.folder ?? state.folderPath.map(SidebarModel.tilde) {
                Menu {
                    if let path = state.folderPath {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
                    } else {
                        Text(folder)
                    }
                } label: {
                    ControlLabel(symbol: "folder", text: (folder as NSString).lastPathComponent.isEmpty ? folder : (folder as NSString).lastPathComponent, chevron: true)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help(folder)
            }
            if let branch = st.branch {
                ControlLabel(symbol: "arrow.triangle.branch", text: branch).help("Branch")
            }
            Spacer(minLength: 8)
            if let shells = st.shells {
                Text(shells).help("Background shells")
            }
            if let mode = st.mode {
                Text(Self.shortMode(mode)).help(mode)
            }
            if state.agentID != nil, !state.models.isEmpty {
                modelPicker
            } else if let model = st.model {
                Text(model)
            }
            if let c = st.context {
                ContextRing(fraction: c).help(st.details.isEmpty ? "Context" : st.details)
            } else if !st.details.isEmpty {
                Image(systemName: "info.circle").help(st.details)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    static func shortMode(_ mode: String) -> String {
        let m = mode.lowercased()
        if m.hasPrefix("auto") { return "Auto" }
        if m.contains("plan") { return "Plan" }
        if m.contains("accept") { return "Accept edits" }
        return mode.prefix(1).uppercased() + mode.dropFirst()
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { $0.path.contains(" ") ? "'\($0.path)'" : $0.path }.joined(separator: " ")
        text = text.isEmpty ? paths + " " : text + (text.hasSuffix(" ") ? "" : " ") + paths + " "
    }

    private var modelPicker: some View {
        let shown = state.pendingModel?.name ?? state.model ?? "Model"
        return Menu {
            ForEach(state.models) { m in
                Button {
                    state.pendingModel = (m.name == state.model) ? nil : m
                } label: {
                    if m.name == (state.pendingModel?.name ?? state.model) { Label(m.name, systemImage: "checkmark") }
                    else { Text(m.name) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                if state.switching { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)) }
                Text(state.switching ? "Switching to \(shown)\u{2026}" : shown).font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(state.pendingModel != nil ? Color.primary : Color.secondary)
        .disabled(state.switching)
        .help("The model for your next message and the ones after it, in this session only. Your default for new sessions stays as it is.")
    }

    private func escape() {
        if state.busy { onStop() }
        else if !text.isEmpty { text = "" }
        else { onEscape() }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSend(t)
        text = ""
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let onSend: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = KeyTextView()
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.allowsUndo = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.delegate = context.coordinator
        tv.onSend = onSend
        tv.onEscape = onEscape
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? KeyTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            DispatchQueue.main.async { [weak tv] in
                guard let tv, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
                lm.ensureLayout(for: tc)
                height = lm.usedRect(for: tc).height + 6
            }
        }
        tv.onSend = onSend
        tv.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposerTextView
        init(_ p: ComposerTextView) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                parent.height = lm.usedRect(for: tc).height + 6
            }
        }
    }
}

final class KeyTextView: NSTextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) || hasMarkedText() { super.keyDown(with: event) } else { onSend?() }
            return
        }
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let isFileOrImage = pb.availableType(from: [.fileURL, .png, .tiff]) != nil
        if isFileOrImage, let text = Drops.text(from: pb) {
            insertText(text + " ", replacementRange: selectedRange())
            return true
        }
        return super.performDragOperation(sender)
    }
}


private struct ControlLabel: View {
    let symbol: String
    let text: String
    var chevron = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).truncationMode(.middle)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ContextRing: View {
    let fraction: Double
    var body: some View {
        let colour: Color = fraction >= 0.8 ? .red : fraction >= 0.5 ? .orange : .secondary
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.03, fraction)).stroke(colour, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}


struct UserBubble: View {
    let text: String
    var pending = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 0) {
                Spacer(minLength: 96)
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.16)))
            }
            if pending {
                Text("Sent \u{00B7} the agent will pick it up next").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .opacity(pending ? 0.75 : 1)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
