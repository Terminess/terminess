import AppKit
import SwiftUI
import TermTranscript

@MainActor
final class OpsGuideModel: ObservableObject {
    @Published private(set) var status: OperationsGuide.Status
    @Published var message: String?
    @Published var busy = false
    private let home = Transcript.home

    init() {
        status = OperationsGuide.locate(home: Transcript.home, configured: Settings.shared.guideFolder)
    }

    func reload() {
        status = OperationsGuide.locate(home: home, configured: Settings.shared.guideFolder)
    }

    var agent: String { Settings.shared.preferredAgent == "codex" ? "codex" : "claude" }
    var agentName: String { agent == "codex" ? "Codex" : "Claude Code" }
    var reviewerName: String { agent == "codex" ? "Claude Code" : "Codex" }

    private var operationsPath: String { OperationsGuide.tilde(status.operations.path, home: home) }
    private var orchestratePath: String { OperationsGuide.tilde(status.orchestrate.path, home: home) }

    private var projectRoots: [String] {
        ["github", "Projects", "projects", "code", "Code", "Developer", "src"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { OperationsGuide.tilde($0, home: home) }
    }

    private var machineHosts: [String] { RemoteMachines.all.filter(\.isValid).map(\.host) }


    func build() {
        start(OperationsGuide.buildPrompt(operations: operationsPath, orchestrate: orchestratePath, agent: agent,
                                          projectRoots: projectRoots, machines: machineHosts), name: "build")
    }

    func update() {
        start(OperationsGuide.updatePrompt(operations: operationsPath, orchestrate: orchestratePath, agent: agent,
                                           projectRoots: projectRoots, machines: machineHosts), name: "update")
    }

    private func start(_ prompt: String, name: String) {
        let file = SidebarModel.pairState + "/briefs/ops-guide-\(name)-\(Int(Date().timeIntervalSince1970)).md"
        do {
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try prompt.write(toFile: file, atomically: true, encoding: .utf8)
        } catch {
            message = "Couldn't write the brief: \(error.localizedDescription)"
            return
        }
        try? FileManager.default.createDirectory(atPath: status.folder, withIntermediateDirectories: true)
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let c = app.open(tabbedWith: app.keyController?.window, directory: status.folder,
                         command: "\(agent) \"$(cat \(shellQuote(file)))\"")
        c.customTitle = name == "build" ? "Operations guide" : "Update operations guide"
        c.window?.makeKeyAndOrderFront(nil)
    }

    func open(_ file: OperationsGuide.FileStatus) {
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
    }

    func reveal() {
        NSWorkspace.shared.selectFile(status.operations.exists ? status.operations.path : status.orchestrate.path,
                                      inFileViewerRootedAtPath: status.folder)
    }


    struct PointerTarget: Identifiable, Equatable {
        let path: String
        let agent: String
        let exists: Bool
        let folderExists: Bool
        let alreadyPoints: Bool
        var id: String { path }
    }

    var pointerLine: String { OperationsGuide.pointerLine(operations: operationsPath, orchestrate: orchestratePath) }

    var pointerTargets: [PointerTarget] {
        [(home + "/.claude/CLAUDE.md", "Claude Code"), (home + "/.codex/AGENTS.md", "Codex")].map { path, agent in
            let text = try? String(contentsOfFile: path, encoding: .utf8)
            return PointerTarget(path: path, agent: agent, exists: text != nil,
                                 folderExists: FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent),
                                 alreadyPoints: text.map(OperationsGuide.hasPointer) ?? false)
        }
    }

    func addPointers() {
        var done: [String] = []
        for t in pointerTargets where !t.alreadyPoints {
            let folder = (t.path as NSString).deletingLastPathComponent
            guard FileManager.default.fileExists(atPath: folder) else { continue }
            let current = (try? String(contentsOfFile: t.path, encoding: .utf8)) ?? ""
            guard let next = OperationsGuide.addingPointer(to: current, operations: operationsPath,
                                                           orchestrate: orchestratePath) else { continue }
            do {
                try next.write(toFile: t.path, atomically: true, encoding: .utf8)
                done.append(OperationsGuide.tilde(t.path, home: home))
            } catch {
                message = "Couldn't update \(OperationsGuide.tilde(t.path, home: home)): \(error.localizedDescription)"
                return
            }
        }
        message = done.isEmpty ? "Nothing to add: both already point at the guide." : "Added the pointer to " + done.joined(separator: " and ") + "."
    }


    var machines: [RemoteMachine] { RemoteMachines.all.filter(\.isValid) }

    func remotePath(_ local: String) -> String {
        local.hasPrefix(home + "/") ? String(local.dropFirst(home.count + 1)) : (local as NSString).lastPathComponent
    }

    func copyToMachines() {
        let files = [status.operations, status.orchestrate].filter(\.exists).map(\.path)
        guard !files.isEmpty, !machines.isEmpty else { return }
        busy = true
        let targets = machines
        let remote = files.map { (local: $0, remote: remotePath($0)) }
        Task.detached {
            var results: [String] = []
            for m in targets {
                let dirs = Set(remote.map { ($0.remote as NSString).deletingLastPathComponent }).filter { !$0.isEmpty }
                var ok = true
                if !dirs.isEmpty {
                    ok = Self.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-p", "\(m.port)", m.host, "--",
                                                   "mkdir -p " + dirs.map(shellQuote).joined(separator: " ")]) == 0
                }
                for f in remote where ok {
                    ok = Self.run("/usr/bin/scp", ["-q", "-o", "BatchMode=yes", "-P", "\(m.port)", f.local, "\(m.host):\(f.remote)"]) == 0
                }
                results.append("\(m.name): \(ok ? "copied" : "failed")")
            }
            await MainActor.run {
                self.busy = false
                self.message = results.joined(separator: ", ")
            }
        }
    }

    nonisolated private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

struct OpsGuideView: View {
    @ObservedObject var model: OpsGuideModel
    @ObservedObject var settings = Settings.shared
    var onClose: () -> Void = {}
    @State private var confirmPointer = false
    @State private var confirmCopy = false

    var body: some View {
        PageShell(onClose: onClose) {
            PageTitle(title: "Operations guide",
                      subtitle: "Two files every agent reads first: how your setup is built, and how agents should work here. \(model.agentName) builds them with you; \(model.reviewerName) reviews.") {
                Button(model.status.exists ? "Update My Guide" : "Build My Guide") {
                    if model.status.exists { model.update() } else { model.build() }
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
            PageSection(title: "Files") {
                PageGroup {
                    fileRow(model.status.operations, "The facts: accounts, machines, domains, deploys, where secrets live, gotchas.")
                    fileRow(model.status.orchestrate, "The rules: who leads, pairing, where work runs, what needs your go-ahead.")
                }
            }
            PageSection(title: "Build") {
                PageGroup {
                    PageRow(symbol: "sparkles", title: "Agent that builds it", detail: "\(model.reviewerName) reviews what it writes.") {
                        Picker("Agent", selection: $settings.preferredAgent) {
                            Text("Claude Code").tag("claude")
                            Text("Codex").tag("codex")
                        }
                        .labelsHidden().fixedSize()
                    }
                    if model.status.exists {
                        PageRow(symbol: "arrow.clockwise", title: "Start over", detail: "Rebuild both files from a fresh scan of your setup.") {
                            Button("Rebuild My Guide") { model.build() }.buttonStyle(.quiet)
                        }
                    }
                }
            }
            if model.status.exists {
                PageSection(title: "Make sure every agent finds it") {
                    PageGroup {
                        PageRow(symbol: "link", title: "Point CLAUDE.md and AGENTS.md at it",
                                detail: "Adds one line under an \u{201C}Operations guide\u{201D} heading.") {
                            Button("Add Pointer\u{2026}") { confirmPointer = true }.buttonStyle(.quiet)
                        }
                        PageRow(symbol: "server.rack", title: "Copy to your machines",
                                detail: model.machines.isEmpty ? "No machines added yet." : model.machines.map(\.name).joined(separator: ", ")) {
                            if model.busy { ProgressView().controlSize(.small) }
                            Button("Copy\u{2026}") { confirmCopy = true }.buttonStyle(.quiet)
                                .disabled(model.machines.isEmpty || model.busy)
                        }
                    }
                }
            }
            if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.secondary)
            }
            PageSection(title: "Where it lives") {
                PageGroup {
                    PageRow(symbol: "folder", title: "Folder", detail: "Found automatically unless you set one.") {
                        TextField("Found automatically", text: $settings.guideFolder,
                                  prompt: Text(OperationsGuide.tilde(model.status.folder, home: Transcript.home)))
                            .frame(width: 200)
                            .onSubmit { model.reload() }
                        Button("Reveal") { model.reveal() }.buttonStyle(.quiet).disabled(!model.status.exists)
                    }
                }
            }
            Text("Update My Guide re-scans and proposes changes for you to approve. Automatic upkeep, collecting changes from every session and proposing a daily update, is planned.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.reload() }
        .onChange(of: settings.guideFolder) { _, _ in model.reload() }
        .sheet(isPresented: $confirmPointer) { pointerSheet }
        .alert("Copy the guide to your machines?", isPresented: $confirmCopy) {
            Button("Copy") { model.copyToMachines() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies \(OperationsGuide.operationsName) and \(OperationsGuide.orchestrateName) to the same place under home on " + model.machines.map(\.name).joined(separator: ", ") + ", with your own ssh. Existing copies there are replaced.")
        }
    }

    private func fileRow(_ f: OperationsGuide.FileStatus, _ detail: String) -> some View {
        PageRow(symbol: f.exists ? "doc.text" : "doc.badge.plus", title: (f.path as NSString).lastPathComponent,
                detail: detail,
                mono: f.exists ? "\(OperationsGuide.tilde(f.path, home: Transcript.home)) \u{00B7} \(f.lines) lines \u{00B7} updated \(Self.relative(f.modified))"
                               : "Not built yet") {
            if f.exists { Button("Open") { model.open(f) }.buttonStyle(.quiet) }
        }
    }

    private var pointerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a pointer to the guide").font(.headline)
            Text("This line goes at the end of each file below, under the heading \"Operations guide\":")
                .foregroundStyle(.secondary)
            Text(model.pointerLine)
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            ForEach(model.pointerTargets) { t in
                HStack(spacing: 6) {
                    Image(systemName: t.alreadyPoints ? "checkmark" : "plus").foregroundStyle(.secondary).frame(width: 14)
                    Text(OperationsGuide.tilde(t.path, home: Transcript.home)).font(.system(.callout, design: .monospaced))
                    Text(t.alreadyPoints ? "already points at the guide" : (t.exists ? "will be added" : (t.folderExists ? "will be created" : "skipped: \(t.agent) isn't set up")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { confirmPointer = false }.keyboardShortcut(.cancelAction)
                Button("Add") { model.addPointers(); confirmPointer = false }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pointerTargets.allSatisfy { $0.alreadyPoints || !$0.folderExists })
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "unknown" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}

@MainActor
enum OpsGuideWindow {
    private static let model = OpsGuideModel()

    static func show() {
        model.reload()
        (NSApp.delegate as? AppDelegate)?.showPage("opsguide") { c in
            OpsGuideView(model: model, onClose: { [weak c] in c?.closePage() })
        }
    }
}
