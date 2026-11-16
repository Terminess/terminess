import TermTranscript
import TermHost
import AppKit
import SwiftUI

@MainActor
final class ReaderModel: ObservableObject {
    @Published var items: [TranscriptItem] = []
    @Published var agentName = ""
    @Published var agentID = ""
    @Published var live = false
    var drops: WindowLink?
    @Published var working = false
    var activity: (() -> Date?)?
    private var watcher: DispatchSourceFileSystemObject?
    private var path: String?
    private var lastMTime: Date?
    private var timer: Timer?
    private var source: (() -> ReaderSource?)?
    var folder: (() -> String?)?
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
        let busy = live && (activity?().map { Date().timeIntervalSince($0) < 2.5 } ?? false)
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
        items = []
        path = nil
        lastMTime = nil
        agentID = agent ?? ""
        agentName = agent == "claude" ? "Claude Code" : agent == "codex" ? "Codex" : agent == "ollama" ? "Local model" : agent == "harness" ? "Terminess Agent" : ""
        live = false
    }

    private func show(agent: String, path: String, live: Bool, force: Bool) {
        agentID = agent
        agentName = agent == "claude" ? "Claude Code" : agent == "ollama" ? "Local model" : agent == "harness" ? "Terminess Agent" : "Codex"
        self.live = live
        let mtime = Transcript.mtime(path)
        guard force || path != self.path || mtime != lastMTime else { return }
        if path != self.path { watch(path, agent: agent) }
        self.path = path
        lastMTime = mtime
        Task.detached(priority: .utility) {
            let parsed = Transcript.parse(path, agent: agent)
            await MainActor.run { [weak self] in
                guard self?.path == path else { return }
                self?.items = Array(parsed.suffix(400))
            }
        }
    }
}

struct ReaderView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        VStack(spacing: 0) {
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
            if model.items.isEmpty {
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
            VStack(alignment: .leading, spacing: 4) {
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
            .modifier(RememberMenu(text: text, folder: folder))

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
        VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1)
                }
                ComposerTextView(text: $state.draft, height: $height, onSend: send, onEscape: escape)
                    .frame(height: min(max(height, 22), 140))
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
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(text.isEmpty)
                .help("Send (Return)")
            }
        }
            if state.agentID != nil, !state.models.isEmpty { modelPicker }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 0.5)))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
        .onDrop(of: Drops.utTypes, isTargeted: nil) { _ in state.drops?.dropFromSwiftUI() ?? false }
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
            HStack(spacing: 4) {
                Image(systemName: state.switching ? "arrow.triangle.2.circlepath" : "sparkle").font(.system(size: 10))
                Text(state.switching ? "Switching to \(shown)…" : shown).font(.system(size: 11, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(state.pendingModel != nil ? Color.accentColor : Color.secondary)
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
            if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                let h = lm.usedRect(for: tc).height + 6
                DispatchQueue.main.async { height = h }
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
