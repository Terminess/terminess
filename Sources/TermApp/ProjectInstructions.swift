import AppKit
import SwiftUI
import TermTranscript

enum InstructionFiles {
    static var claudeHome: String { ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? Transcript.home + "/.claude" }
    static var codexHome: String { ProcessInfo.processInfo.environment["CODEX_HOME"] ?? Transcript.home + "/.codex" }

    static func projectRoot(_ folder: String) -> String { Git.root(of: folder) ?? folder }

    static func memoryFolder(for folder: String) -> String? {
        var candidates = [Git.mainRoot(of: folder), Git.root(of: folder), folder].compactMap { $0 }
        candidates = candidates.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        for dir in candidates {
            let path = claudeHome + "/projects/" + Instructions.claudeProjectName(dir) + "/memory"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return path }
        }
        return nil
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    static func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    static func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try Data(text.utf8).write(to: url, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    static func isLinked(root: String) -> Bool {
        let claude = URL(fileURLWithPath: root + "/CLAUDE.md")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: claude.path)) != nil else { return false }
        return claude.resolvingSymlinksInPath().path == URL(fileURLWithPath: root + "/AGENTS.md").resolvingSymlinksInPath().path
    }

    static func isShared(root: String) -> Bool {
        isLinked(root: root) || read(root + "/CLAUDE.md").map(Instructions.importsAgents) == true
    }
}

extension Notification.Name {
    static let instructionsChanged = Notification.Name("TerminessInstructionsChanged")
}

@MainActor
final class InstructionDocument: ObservableObject {
    let title: String
    let path: String
    let template: String
    let reader: String
    @Published var text = ""
    @Published private(set) var saved = ""
    @Published private(set) var exists = false
    @Published private(set) var unreadable = false
    @Published var error: String?
    private var ending = "\n"

    var dirty: Bool { text != saved }

    init(title: String, path: String, template: String, reader: String) {
        self.title = title
        self.path = path
        self.template = template
        self.reader = reader
        load()
    }

    func load() {
        exists = InstructionFiles.exists(path)
        if let t = InstructionFiles.read(path) {
            ending = Instructions.lineEnding(t)
            saved = t.replacingOccurrences(of: "\r\n", with: "\n")
            unreadable = false
        } else {
            ending = "\n"
            saved = ""
            unreadable = exists
        }
        text = saved
        error = nil
    }

    func reloadIfClean() { if !dirty { load() } }

    func save() {
        guard !unreadable else { return }
        do {
            try InstructionFiles.write(Instructions.normalised(text, to: ending), to: path)
            saved = text
            exists = true
            error = nil
            NotificationCenter.default.post(name: .instructionsChanged, object: path)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func revert() { load() }
}

@MainActor
final class ProjectInstructionsModel: ObservableObject {
    enum Scope: String { case project, user }
    enum Tab: String { case agents, claude, memory }

    let root: String
    let folder: String
    @Published var scope = Scope.project
    @Published var tab = Tab.agents
    @Published private(set) var shared = false
    @Published private(set) var linked = false
    @Published private(set) var memoryFolder: String?
    @Published private(set) var memoryFiles: [String] = []
    @Published var memorySelection: String?
    @Published var rememberTarget: String {
        didSet { Remember.setTarget(rememberTarget, root: root) }
    }

    let projectAgents: InstructionDocument
    let projectClaude: InstructionDocument
    let userAgents: InstructionDocument
    let userClaude: InstructionDocument
    var documents: [InstructionDocument] { [projectAgents, projectClaude, userAgents, userClaude] }

    init(folder: String) {
        self.folder = folder
        root = InstructionFiles.projectRoot(folder)
        projectAgents = InstructionDocument(title: "AGENTS.md", path: root + "/AGENTS.md",
                                            template: Instructions.agentsTemplate, reader: "Codex reads this in this project.")
        projectClaude = InstructionDocument(title: "CLAUDE.md", path: root + "/CLAUDE.md",
                                            template: Instructions.claudeTemplate, reader: "Claude Code reads this in this project.")
        userAgents = InstructionDocument(title: "AGENTS.md", path: InstructionFiles.codexHome + "/AGENTS.md",
                                         template: "# Instructions for every project\n\n- \n", reader: "Codex reads this in every project.")
        userClaude = InstructionDocument(title: "CLAUDE.md", path: InstructionFiles.claudeHome + "/CLAUDE.md",
                                         template: "# Instructions for every project\n\n- \n", reader: "Claude Code reads this in every project.")
        rememberTarget = Remember.target(root: root) ?? "ask"
        refresh()
    }

    var current: InstructionDocument? {
        switch (scope, tab) {
        case (.project, .agents): return projectAgents
        case (.project, .claude): return projectClaude
        case (.user, .agents): return userAgents
        case (.user, .claude): return userClaude
        default: return nil
        }
    }

    func refresh() {
        documents.forEach { $0.reloadIfClean() }
        shared = InstructionFiles.isShared(root: root)
        linked = InstructionFiles.isLinked(root: root)
        memoryFolder = InstructionFiles.memoryFolder(for: folder)
        if let dir = memoryFolder {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            memoryFiles = names.filter { !$0.hasPrefix(".") }.sorted { a, b in
                a == "MEMORY.md" ? true : b == "MEMORY.md" ? false : a.localizedStandardCompare(b) == .orderedAscending
            }
        } else {
            memoryFiles = []
        }
        if memorySelection.map({ !memoryFiles.contains($0) }) ?? true { memorySelection = memoryFiles.first }
    }

    func share(window: NSWindow?) {
        guard !shared else { return }
        guard !projectAgents.dirty && !projectClaude.dirty else {
            alert("Save or revert your changes first.", "AGENTS.md or CLAUDE.md has unsaved edits.", window: window)
            return
        }
        let agentsPath = root + "/AGENTS.md", claudePath = root + "/CLAUDE.md"
        let agents = InstructionFiles.read(agentsPath)
        let claude = InstructionFiles.read(claudePath)
        if (InstructionFiles.exists(agentsPath) && agents == nil) || (InstructionFiles.exists(claudePath) && claude == nil) {
            alert("These files can't be read as text.", "Terminess left them alone.", window: window)
            return
        }
        let claudeEnding = claude.map(Instructions.lineEnding) ?? "\n"
        let extra = (claude ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let agentsBody = (agents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var newAgents: String?
        var newClaude = Instructions.sharedClaude(ending: claudeEnding)
        if extra.isEmpty || extra.replacingOccurrences(of: "\r\n", with: "\n") == agentsBody.replacingOccurrences(of: "\r\n", with: "\n") {
            if agents == nil { newAgents = Instructions.agentsTemplate }
        } else if agentsBody.isEmpty {
            let a = NSAlert()
            a.messageText = "Move CLAUDE.md's instructions into AGENTS.md?"
            a.informativeText = "AGENTS.md becomes the one set of instructions and CLAUDE.md a single line that imports it, so Claude Code and Codex both read it."
            a.addButton(withTitle: "Move to AGENTS.md")
            a.addButton(withTitle: "Keep in CLAUDE.md")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: newAgents = claude
            case .alertSecondButtonReturn:
                newAgents = Instructions.agentsTemplate
                newClaude = Instructions.sharedClaude(keeping: claude, ending: claudeEnding)
            default: return
            }
        } else {
            let a = NSAlert()
            a.messageText = "CLAUDE.md has instructions of its own."
            a.informativeText = "Keep them below the import, where only Claude Code reads them, or add them to the end of AGENTS.md so both agents do."
            a.addButton(withTitle: "Keep Below the Import")
            a.addButton(withTitle: "Add to AGENTS.md")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: newClaude = Instructions.sharedClaude(keeping: claude, ending: claudeEnding)
            case .alertSecondButtonReturn:
                let a = agents ?? ""
                let e = Instructions.lineEnding(a)
                var joined = a
                if !joined.hasSuffix(e) { joined += e }
                joined += e + Instructions.normalised(extra, to: e) + e
                newAgents = joined
            default: return
            }
        }
        do {
            if let newAgents { try InstructionFiles.write(newAgents, to: agentsPath) }
            try InstructionFiles.write(newClaude, to: claudePath)
        } catch {
            alert("Couldn't write the instructions.", error.localizedDescription, window: window)
        }
        projectAgents.load()
        projectClaude.load()
        refresh()
        NotificationCenter.default.post(name: .instructionsChanged, object: nil)
        if shared { Toast.show("Claude Code and Codex now share AGENTS.md", in: window) }
    }

    private func alert(_ message: String, _ info: String, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }
}

struct ProjectInstructionsView: View {
    @ObservedObject var model: ProjectInstructionsModel
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $model.scope) {
                    Text("This Project").tag(ProjectInstructionsModel.Scope.project)
                    Text("All Projects").tag(ProjectInstructionsModel.Scope.user)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Picker("", selection: $model.tab) {
                    Text("AGENTS.md").tag(ProjectInstructionsModel.Tab.agents)
                    Text("CLAUDE.md").tag(ProjectInstructionsModel.Tab.claude)
                    if model.scope == .project { Text("Memory").tag(ProjectInstructionsModel.Tab.memory) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if model.scope == .project { shareBanner }
            Divider()
            if let doc = model.current {
                DocumentEditor(doc: doc, shared: model.scope == .project && model.shared, window: window)
                    .id(doc.path)
            } else {
                MemoryView(model: model)
            }
            if model.scope == .project {
                Divider()
                rememberFooter
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(WindowFinder(window: $window))
        .onChange(of: model.scope) { _, scope in
            if scope == .user && model.tab == .memory { model.tab = .agents }
        }
    }

    private var shareBanner: some View {
        HStack(spacing: 8) {
            if model.shared {
                Image(systemName: "link").foregroundStyle(.green)
                Text(model.linked
                     ? "Shared: CLAUDE.md is a link to AGENTS.md, so Claude Code and Codex read the same instructions."
                     : "Shared: CLAUDE.md imports AGENTS.md, so Claude Code and Codex read the same instructions.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary)
                Text("Claude Code reads CLAUDE.md and Codex reads AGENTS.md.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Share One Set of Instructions") { model.share(window: window) }
                    .help("Make AGENTS.md the instructions and CLAUDE.md a one-line import of it, so both agents read the same file.")
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .help(model.root)
    }

    private var rememberFooter: some View {
        HStack(spacing: 8) {
            Text("Remember This in Chat adds notes to").font(.caption).foregroundStyle(.secondary)
            if model.shared {
                Text("AGENTS.md (shared)").font(.caption.weight(.medium))
            } else {
                Picker("", selection: $model.rememberTarget) {
                    Text("Ask Me").tag("ask")
                    Text("AGENTS.md").tag("agents")
                    Text("CLAUDE.md").tag("claude")
                    Text("Both").tag("both")
                }
                .labelsHidden().fixedSize().controlSize(.small)
            }
            Spacer()
            Text(abbreviated(model.root)).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

private func abbreviated(_ path: String) -> String { SidebarModel.tilde(path) }

private struct DocumentEditor: View {
    @ObservedObject var doc: InstructionDocument
    let shared: Bool
    let window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(abbreviated(doc.path)).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        status
                    }
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !doc.exists && doc.text.isEmpty {
                    Button("Start from Template") { doc.text = doc.template }
                }
                Button("Open in Editor") { Editor.open(doc.path, line: nil, column: nil) }
                    .disabled(!doc.exists)
                Button("Revert") { doc.revert() }.disabled(!doc.dirty)
                Button(doc.exists ? "Save" : "Create") { doc.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!doc.dirty || doc.unreadable)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if let error = doc.error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }
            PlainTextEditor(text: $doc.text, editable: !doc.unreadable)
        }
    }

    private var caption: String {
        if doc.unreadable { return "This file isn't UTF-8 text, so it is shown read-only. Open it in your editor instead." }
        if !doc.exists { return doc.reader + " It doesn't exist yet; write it here or start from a template, then Create." }
        if shared && doc.title == "CLAUDE.md" { return "Imports AGENTS.md, so edit the shared instructions there. Lines below the import are for Claude Code only." }
        if shared && doc.title == "AGENTS.md" { return "Codex and Claude Code both read this in this project." }
        return doc.reader
    }

    @ViewBuilder private var status: some View {
        if !doc.exists {
            Text("Not created").font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
        } else if doc.dirty {
            Text("Edited").font(.caption2.weight(.medium)).foregroundStyle(.orange)
        }
    }
}

private struct MemoryView: View {
    @ObservedObject var model: ProjectInstructionsModel

    var body: some View {
        if let dir = model.memoryFolder, !model.memoryFiles.isEmpty {
            HSplitView {
                List(model.memoryFiles, id: \.self, selection: $model.memorySelection) { name in
                    Label(name, systemImage: "doc.text").lineLimit(1)
                }
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)
                VStack(spacing: 0) {
                    if let name = model.memorySelection {
                        let path = dir + "/" + name
                        HStack {
                            Text("Claude Code writes these itself; edit them in your editor if you need to.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            Button("Open in Editor") { Editor.open(path, line: nil, column: nil) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        PlainTextEditor(text: .constant(InstructionFiles.read(path) ?? ""), editable: false)
                            .id(path)
                    } else {
                        Spacer()
                    }
                }
                .frame(minWidth: 300)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "brain").font(.largeTitle).foregroundStyle(.tertiary)
                Text("No memories yet").font(.headline).foregroundStyle(.secondary)
                Text("Claude Code hasn't saved any notes of its own for this project.")
                    .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.importsGraphics = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.string = text
        tv.isEditable = editable
        tv.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        tv.isEditable = editable
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ p: PlainTextEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

private struct WindowFinder: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { window = v.window }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if window !== v.window { DispatchQueue.main.async { window = v.window } }
    }
}

@MainActor
enum ProjectInstructionsWindows {
    private static var open: [String: (NSWindow, CloseGuard)] = [:]

    static func show(folder: String) {
        if let (w, _) = open[InstructionFiles.projectRoot(folder)] { w.makeKeyAndOrderFront(nil); return }
        let model = ProjectInstructionsModel(folder: folder)
        let w = NSWindow(contentViewController: NSHostingController(rootView: ProjectInstructionsView(model: model)))
        w.title = "Instructions: " + (model.root as NSString).lastPathComponent
        w.setContentSize(NSSize(width: 760, height: 620))
        w.isReleasedWhenClosed = false
        let guardian = CloseGuard(model: model)
        w.delegate = guardian
        open[model.root] = (w, guardian)
        let root = model.root
        guardian.tokens = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { model.refresh() }
            },
            NotificationCenter.default.addObserver(forName: .instructionsChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { model.refresh() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    open[root]?.1.tokens.forEach(NotificationCenter.default.removeObserver)
                    open[root] = nil
                }
            },
        ]
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    final class CloseGuard: NSObject, NSWindowDelegate {
        let model: ProjectInstructionsModel
        var tokens: [NSObjectProtocol] = []
        init(model: ProjectInstructionsModel) { self.model = model }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            MainActor.assumeIsolated {
                let dirty = model.documents.filter(\.dirty)
                guard !dirty.isEmpty else { return true }
                let a = NSAlert()
                a.messageText = "Save your changes?"
                a.informativeText = dirty.map { abbreviated($0.path) }.joined(separator: "\n")
                a.addButton(withTitle: "Save")
                a.addButton(withTitle: "Don't Save")
                a.addButton(withTitle: "Cancel")
                switch a.runModal() {
                case .alertFirstButtonReturn:
                    dirty.forEach { $0.save() }
                    return dirty.allSatisfy { !$0.dirty }
                case .alertSecondButtonReturn: return true
                default: return false
                }
            }
        }
    }
}

extension AppDelegate {
    @objc func showProjectInstructions(_ sender: Any?) {
        ProjectInstructionsWindows.show(folder: keyController?.currentDirectory ?? Settings.shared.startDirectory)
    }
}

@MainActor
enum Remember {
    private static func key(_ root: String) -> String { "RememberTarget:" + root }

    static func target(root: String) -> String? {
        let v = UserDefaults.standard.string(forKey: key(root))
        return v == "ask" ? nil : v
    }

    static func setTarget(_ value: String, root: String) {
        if value == "ask" { UserDefaults.standard.removeObject(forKey: key(root)) }
        else { UserDefaults.standard.set(value, forKey: key(root)) }
    }

    static func note(_ text: String, folder: String) {
        let window = NSApp.keyWindow
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        let root = InstructionFiles.projectRoot(folder)
        let agents = root + "/AGENTS.md", claude = root + "/CLAUDE.md"
        let choice: String
        if InstructionFiles.isShared(root: root) {
            choice = "agents"
        } else if let saved = target(root: root) {
            choice = saved
        } else {
            let a = NSAlert()
            a.messageText = "Where should notes for \((root as NSString).lastPathComponent) go?"
            a.informativeText = "Remember This adds them under ## Notes. Codex reads AGENTS.md and Claude Code reads CLAUDE.md. Terminess keeps this choice for the project; change it in View > Project Instructions."
            a.addButton(withTitle: "AGENTS.md")
            a.addButton(withTitle: "CLAUDE.md")
            a.addButton(withTitle: "Both")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: choice = "agents"
            case .alertSecondButtonReturn: choice = "claude"
            case .alertThirdButtonReturn: choice = "both"
            default: return
            }
            setTarget(choice, root: root)
        }
        var paths = choice == "agents" ? [agents] : choice == "claude" ? [claude] : [agents, claude]
        if paths.count == 2 && InstructionFiles.isLinked(root: root) { paths = [agents] }
        var written: [String] = []
        for path in paths {
            let current = InstructionFiles.read(path)
            if current == nil && InstructionFiles.exists(path) { continue }
            do {
                try InstructionFiles.write(Instructions.addingNote(note, to: current ?? ""), to: path)
                written.append((path as NSString).lastPathComponent)
            } catch {}
        }
        NotificationCenter.default.post(name: .instructionsChanged, object: nil)
        if written.isEmpty {
            NSSound.beep()
            Toast.show("Couldn't add the note", in: window)
        } else {
            Toast.show("Remembered in " + written.joined(separator: " and "), in: window)
        }
    }
}

struct RememberMenu: ViewModifier {
    let text: String
    let folder: String?

    func body(content: Content) -> some View {
        if let folder, folder.hasPrefix("/") {
            content.contextMenu {
                Button("Remember This") { Remember.note(text, folder: folder) }
                Button("Copy Message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        } else {
            content
        }
    }
}

@MainActor
enum Toast {
    static func show(_ message: String, in window: NSWindow?) {
        guard let content = window?.contentView else { return }
        let label = Text(message).font(.callout.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(8)
        let host = NSHostingView(rootView: label)
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -56),
        ])
        host.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; host.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; host.animator().alphaValue = 0 },
                                                 completionHandler: { MainActor.assumeIsolated { host.removeFromSuperview() } })
        }
    }
}
