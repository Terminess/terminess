import AppKit
import SwiftUI
import TermTranscript

@MainActor
final class LibraryModel: ObservableObject {
    enum AgentFilter: String, CaseIterable { case all = "All Agents", claude = "Claude", codex = "Codex" }
    enum ScopeFilter: String, CaseIterable { case all = "All Scopes", user = "User", project = "Project" }

    @Published var items: [Library.Item] = []
    @Published var kind: Library.Kind = .skills
    @Published var agentFilter: AgentFilter = .all
    @Published var scopeFilter: ScopeFilter = .all
    @Published var search = ""
    @Published var busy = false
    @Published private(set) var currentDirectory: String?
    @Published private(set) var project: String?

    func setDirectory(_ dir: String?) {
        guard dir != currentDirectory else { return }
        currentDirectory = dir
        project = Library.projectRoot(dir)
        reload()
    }

    func reload() {
        let project = project, cwd = currentDirectory
        Task.detached(priority: .userInitiated) {
            let items = Library.scan(project: project, currentDirectory: cwd)
            await MainActor.run { self.items = items }
        }
    }

    var visible: [Library.Item] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            guard item.kind == kind else { return false }
            switch agentFilter {
            case .all: break
            case .claude: if item.agent != .claude { return false }
            case .codex: if item.agent != .codex { return false }
            }
            switch scopeFilter {
            case .all: break
            case .user: if item.scope != .user { return false }
            case .project: if item.scope == .user { return false }
            }
            return q.isEmpty || item.name.localizedCaseInsensitiveContains(q)
                || item.detail.localizedCaseInsensitiveContains(q) || item.file.localizedCaseInsensitiveContains(q)
        }
    }

    func count(_ kind: Library.Kind) -> Int { items.filter { $0.kind == kind }.count }


    func open(_ item: Library.Item) { Editor.open(item.file, line: nil, column: nil) }

    func reveal(_ item: Library.Item) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.location ?? item.file)])
    }

    func toggle(_ item: Library.Item) {
        do { try Library.setEnabled(item, !item.enabled, project: project) } catch { report(error) }
        reload()
    }

    func trash(_ item: Library.Item) {
        if item.kind == .mcp { removeMCP(item); return }
        guard let location = item.location else { return }
        let a = NSAlert()
        a.messageText = "Move \(item.name) to the Trash?"
        a.informativeText = "\(Library.abbreviate(location)) goes to the Trash, where you can get it back. \(item.agent.rawValue) stops loading it."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await Library.trash([location], project: project) } catch { report(error) }
            reload()
        }
    }

    func removeMCP(_ item: Library.Item) {
        let a = NSAlert()
        a.messageText = "Remove the \(item.name) MCP server from \(item.agent.rawValue)?"
        a.informativeText = item.agent == .claude
            ? "Terminess runs `claude mcp remove --scope \(item.scope.rawValue.lowercased()) \(item.name)`."
            : "Terminess removes its [mcp_servers.\(item.name)] table from \(Library.abbreviate(Library.codexConfig)) and keeps a copy of the table beside it. The rest of the file is left as it is."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run { [project] in try Library.removeMCP(item, project: project) }
    }

    func addMCP(agent: Library.Agent, scope: Library.Scope, name: String, commandLine: String) {
        run { [project] in try Library.addMCP(agent: agent, scope: scope, name: name, commandLine: commandLine, project: project) }
    }

    private func run(_ work: @escaping @Sendable () throws -> String) {
        busy = true
        Task.detached {
            let result = Result { try work() }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let text): if !text.isEmpty { self.inform("Done", text) }
                case .failure(let error): self.report(error)
                }
                self.reload()
            }
        }
    }

    func create(_ kind: Library.Kind, agent: Library.Agent, scope: Library.Scope, name: String) -> Bool {
        do {
            let file = try Library.create(kind, agent: agent, scope: scope, name: name, project: project)
            reload()
            Editor.open(file, line: nil, column: nil)
            return true
        } catch { report(error); return false }
    }

    func report(_ error: Error) { inform("Could not do that", error.localizedDescription) }

    func inform(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    var onClose: () -> Void = {}
    @State private var showNew = false
    @State private var showImport = false
    @State private var showAddMCP = false

    static func symbol(_ kind: Library.Kind) -> String {
        switch kind {
        case .skills: return "wand.and.stars"
        case .commands: return "command"
        case .agents: return "person.2"
        case .mcp: return "server.rack"
        }
    }

    var body: some View {
        PageShell(onClose: onClose) {
            ForEach(Library.Kind.allCases) { k in
                PageSideItem(symbol: Self.symbol(k), title: k.rawValue, count: model.count(k), selected: model.kind == k) {
                    model.kind = k
                }
            }
            PageSideHeading(title: "Guide")
            PageSideItem(symbol: "book.closed", title: "Operations guide", selected: false) { OpsGuideWindow.show() }
        } main: {
            PageTitle(title: "Library",
                      subtitle: "The skills, slash commands, subagents and MCP servers Claude Code and Codex load. "
                        + (model.project.map { "Project: " + Library.abbreviate($0) } ?? "Project items show when the front tab is in a project folder.")) {
                HStack(spacing: 8) {
                    if model.kind != .mcp {
                        Button { showImport = true } label: { Label("Import\u{2026}", systemImage: "square.and.arrow.down") }
                            .buttonStyle(.quiet)
                            .help("Import a skill, command or agent from GitHub")
                    }
                    Button { if model.kind == .mcp { showAddMCP = true } else { showNew = true } } label: {
                        Label(model.kind == .mcp ? "Add Server\u{2026}" : "New\u{2026}", systemImage: "plus")
                    }
                    .buttonStyle(.primary)
                }
            }
            filters
            list
        }
        .sheet(isPresented: $showNew) { NewItemSheet(model: model, kind: model.kind == .mcp ? .skills : model.kind) }
        .sheet(isPresented: $showImport) { ImportSheet(model: model) }
        .sheet(isPresented: $showAddMCP) { AddMCPSheet(model: model) }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.agentFilter) {
                ForEach(LibraryModel.AgentFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            Picker("", selection: $model.scopeFilter) {
                ForEach(LibraryModel.ScopeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search", text: $model.search).textFieldStyle(.plain).font(.system(size: 12.5))
            }
            .padding(.horizontal, 8).frame(width: 200, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Look again")
        }
    }

    @ViewBuilder private var list: some View {
        let items = model.visible
        if items.isEmpty {
            Text(emptyText).font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        } else {
            PageGroup {
                ForEach(items) { item in
                    LibraryRow(item: item, model: model)
                }
            }
        }
    }

    private var emptyText: String {
        if !model.search.isEmpty { return "Nothing matches \u{201C}\(model.search)\u{201D}." }
        return "No \(model.kind.rawValue.lowercased()) here yet."
    }
}

private struct LibraryRow: View {
    let item: Library.Item
    @ObservedObject var model: LibraryModel
    @State private var hovering = false

    var body: some View {
        PageRow(symbol: LibraryView.symbol(item.kind), tint: item.enabled ? .secondary : Color.secondary.opacity(0.5),
                title: item.name,
                status: item.enabled ? nil : ("Disabled", Color.secondary.opacity(0.5)),
                detail: item.detail,
                mono: "\(item.agent.rawValue) \u{00B7} \(item.scope.rawValue) \u{00B7} \(Library.abbreviate(item.location ?? item.file))",
                dimmed: !item.enabled) {
            if hovering {
                Button(item.kind == .mcp ? "Open Config" : "Open") { model.open(item) }.buttonStyle(.quiet)
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("More")
            }
        }
        .background(hovering ? Color.primary.opacity(0.03) : .clear)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(item) }
        .contextMenu { menu }
        .help(item.location ?? item.file)
    }

    @ViewBuilder private var menu: some View {
        Button(item.kind == .mcp ? "Open Config File" : "Open in Editor") { model.open(item) }
        Button("Reveal in Finder") { model.reveal(item) }
        Divider()
        if item.kind == .mcp {
            Button("Remove Server\u{2026}") { model.removeMCP(item) }
        } else {
            Button(item.enabled ? "Disable" : "Enable") { model.toggle(item) }
            Button("Move to Trash\u{2026}") { model.trash(item) }
        }
    }
}

private struct DestinationPicker: View {
    let kind: Library.Kind
    let project: String?
    @Binding var agent: Library.Agent
    @Binding var scope: Library.Scope

    var body: some View {
        if kind == .skills {
            Picker("Agent", selection: $agent) {
                ForEach(Library.Agent.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } else {
            LabeledContent("Agent", value: "Claude")
        }
        Picker("Scope", selection: $scope) {
            Text("User (all projects)").tag(Library.Scope.user)
            Text(project.map { "This project (\(($0 as NSString).lastPathComponent))" } ?? "This project").tag(Library.Scope.project)
                .disabled(project == nil)
        }
    }
}

private struct NewItemSheet: View {
    @ObservedObject var model: LibraryModel
    @State var kind: Library.Kind
    @State private var agent: Library.Agent = .claude
    @State private var scope: Library.Scope = .user
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New").font(.headline)
            Form {
                Picker("Kind", selection: $kind) {
                    Text("Skill").tag(Library.Kind.skills)
                    Text("Command").tag(Library.Kind.commands)
                    Text("Agent").tag(Library.Kind.agents)
                }
                TextField("Name", text: $name, prompt: Text("my-skill"))
                DestinationPicker(kind: kind, project: model.project, agent: $agent, scope: $scope)
            }
            Text("Creates a template and opens it in your editor.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    if model.create(kind, agent: kind == .skills ? agent : .claude, scope: scope, name: name) { dismiss() }
                }
                .keyboardShortcut(.defaultAction).disabled(!AgentLibrary.isValidName(name))
            }
        }
        .padding(20).frame(width: 420)
    }
}

private struct AddMCPSheet: View {
    @ObservedObject var model: LibraryModel
    @State private var agent: Library.Agent = .claude
    @State private var scope: Library.Scope = .user
    @State private var name = ""
    @State private var command = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add MCP Server").font(.headline)
            Form {
                Picker("Agent", selection: $agent) {
                    ForEach(Library.Agent.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if agent == .claude {
                    Picker("Scope", selection: $scope) {
                        Text("User (all projects)").tag(Library.Scope.user)
                        Text("Project (.mcp.json, shared)").tag(Library.Scope.project).disabled(model.project == nil)
                        Text("Local (this project, just you)").tag(Library.Scope.local).disabled(model.project == nil)
                    }
                } else {
                    LabeledContent("Scope", value: "User (~/.codex/config.toml)")
                }
                TextField("Name", text: $name, prompt: Text("filesystem"))
                TextField("Command", text: $command, prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents"))
            }
            Text(agent == .claude ? "Runs `claude mcp add`, which keeps Claude Code's own files in order." : "Adds an [mcp_servers] table at the end of config.toml; the rest of the file is left as it is. The first change backs it up to config.toml.before-terminess.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    model.addMCP(agent: agent, scope: agent == .codex ? .user : scope, name: name, commandLine: command)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!AgentLibrary.isValidName(name) || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }
}

private struct ImportSheet: View {
    @ObservedObject var model: LibraryModel
    @State private var url = ""
    @State private var fetching = false
    @State private var fetched: LibraryImport.Fetched?
    @State private var error: String?
    @State private var name = ""
    @State private var kind: Library.Kind = .skills
    @State private var target = "claude"
    @State private var scope: Library.Scope = .user
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from GitHub").font(.headline)
            HStack {
                TextField("Link", text: $url, prompt: Text("https://github.com/owner/repo/tree/main/skills/name"))
                    .onSubmit(fetch)
                Button("Fetch", action: fetch).disabled(url.isEmpty || fetching)
                if fetching { ProgressView().controlSize(.small) }
            }
            Text("A folder holding a SKILL.md, a link to the SKILL.md itself, or a single .md command or agent file.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let f = fetched {
                Text(f.isSkill ? "SKILL.md, plus \(f.files.count - 1) other file\(f.files.count == 2 ? "" : "s"). Read it before installing:" : "\(f.files.first?.path ?? ""). Read it before installing:")
                    .font(.callout)
                ScrollView {
                    Text(f.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(minHeight: 200, maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
                if f.isSkill && f.files.count > 1 {
                    Text("Files: " + f.files.map(\.path).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Form {
                    TextField("Name", text: $name)
                    if f.isSkill {
                        Picker("Agent", selection: $target) {
                            Text("Claude").tag("claude"); Text("Codex").tag("codex"); Text("Both").tag("both")
                        }
                    } else {
                        Picker("Install as", selection: $kind) {
                            Text("Command").tag(Library.Kind.commands); Text("Agent").tag(Library.Kind.agents)
                        }
                        LabeledContent("Agent", value: "Claude")
                    }
                    Picker("Scope", selection: $scope) {
                        Text("User (all projects)").tag(Library.Scope.user)
                        Text(model.project.map { "This project (\(($0 as NSString).lastPathComponent))" } ?? "This project")
                            .tag(Library.Scope.project).disabled(model.project == nil)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install", action: install).keyboardShortcut(.defaultAction)
                    .disabled(fetched == nil || !AgentLibrary.isValidName(name))
            }
        }
        .padding(20).frame(width: 600)
    }

    private func fetch() {
        fetching = true; error = nil; fetched = nil
        let link = url
        Task {
            do {
                let f = try await LibraryImport.fetch(link)
                fetched = f
                name = f.name
                kind = f.location.path.contains("agents/") ? .agents : .commands
            } catch {
                self.error = error.localizedDescription
            }
            fetching = false
        }
    }

    private func install() {
        guard let f = fetched else { return }
        let agents: [Library.Agent] = !f.isSkill ? [.claude] : target == "both" ? [.claude, .codex] : target == "codex" ? [.codex] : [.claude]
        let k: Library.Kind = f.isSkill ? .skills : kind
        Task {
            do {
                let files = try await LibraryImport.install(f, name: name, kind: k, agents: agents, scope: scope, project: model.project) { existing in
                    let a = NSAlert()
                    a.messageText = "\(Library.abbreviate(existing)) already exists."
                    a.informativeText = "Replace it? The one there now goes to the Trash."
                    a.addButton(withTitle: "Replace")
                    a.addButton(withTitle: "Keep It")
                    return a.runModal() == .alertFirstButtonReturn
                }
                model.reload()
                if files.isEmpty { return }
                dismiss()
                model.inform("Installed", files.map(Library.abbreviate).joined(separator: "\n"))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

@MainActor
enum LibraryWindow {
    private static let model = LibraryModel()

    static func show(directory: String?) {
        model.setDirectory(directory)
        model.reload()
        (NSApp.delegate as? AppDelegate)?.showPage("library") { c in
            LibraryView(model: model, onClose: { [weak c] in c?.closePage() })
        }
    }
}
