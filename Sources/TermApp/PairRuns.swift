import AppKit
import SwiftUI
import TermTranscript

enum PairRuns {
    static var directory: String { SidebarModel.pairState + "/runs" }

    nonisolated static func recent(limit: Int = 8) -> [PairRun] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted().reversed()
        var out: [PairRun] = []
        for name in names {
            guard let run = read(directory + "/" + name) else { continue }
            if run.started < cutoff { break }
            out.append(run)
            if out.count >= limit { break }
        }
        return out
    }

    nonisolated static func read(_ dir: String) -> PairRun? {
        let name = (dir as NSString).lastPathComponent
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count >= 4, let started = SidebarModel.ledgerDate(parts[0]) else { return nil }
        let prompt = (try? String(contentsOfFile: dir + "/prompt.md", encoding: .utf8)) ?? ""
        func after(_ marker: String) -> String? {
            guard let r = prompt.range(of: marker) else { return nil }
            return String(prompt[r.upperBound...].prefix { $0 != "\n" }).trimmingCharacters(in: .whitespaces)
        }
        let repo = after("- Repo: ").map { String($0.prefix { $0 != " " }).trimmingCharacters(in: CharacterSet(charactersIn: ".")) } ?? ""
        let transcript = after("transcript is at ").map { String($0.prefix { $0 != " " }).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let task = taskText(prompt)
        let focus = task.range(of: "Focus from the main session:").map { String(task[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        let firstLine = (focus ?? task).split(separator: "\n").first.map(String.init) ?? ""
        var brief = firstLine.hasPrefix("Goal:") ? String(firstLine.dropFirst(5)).trimmingCharacters(in: .whitespaces) : firstLine
        if brief.count > 90 { brief = String(brief.prefix(89)) + "…" }
        return PairRun(id: name, from: parts[1], to: parts[2], mode: parts[3],
                       repo: (repo as NSString).lastPathComponent, brief: brief.isEmpty ? parts[3] : brief,
                       dir: dir, state: state(dir), started: started, transcript: transcript)
    }

    nonisolated static func taskText(_ prompt: String) -> String {
        guard let r = prompt.range(of: "--- TASK ---") else { return prompt }
        return String(prompt[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func state(_ dir: String) -> String {
        let events = dir + "/events.jsonl"
        if let h = FileHandle(forReadingAtPath: events) {
            defer { try? h.close() }
            let size = h.seekToEndOfFile()
            h.seek(toFileOffset: size > 8192 ? size - 8192 : 0)
            let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            if tail.contains("\"type\":\"turn.completed\"") { return "done" }
            if tail.contains("\"type\":\"turn.failed\"") { return "failed" }
            if tail.contains("\"type\":\"result\"") { return tail.contains("\"is_error\":true") ? "failed" : "done" }
        }
        if FileManager.default.fileExists(atPath: dir + "/result.md") { return "done" }
        if let m = Transcript.mtime(events), Date().timeIntervalSince(m) < 600 { return "running" }
        return "stopped"
    }

    nonisolated static func run(forCommand command: String) -> PairRun? {
        let lines = command.components(separatedBy: "\n")
        var needle: String?
        if let i = lines.firstIndex(where: { $0.contains("<<'") || $0.contains("<<\"") || $0.contains("<<BRIEF") || $0.contains("<<EOF") }) {
            needle = lines.dropFirst(i + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else if let m = command.firstMatch(of: #/pair\s+(?:ask|review|handoff|parallel)[^"']*["']([^"']{8,})/#) {
            needle = String(m.1)
        }
        guard let needle = needle?.trimmingCharacters(in: .whitespaces), needle.count >= 8 else { return nil }
        let probe = String(needle.prefix(80))
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted().reversed().prefix(60)
        for name in names {
            let dir = directory + "/" + name
            if let prompt = try? String(contentsOfFile: dir + "/prompt.md", encoding: .utf8), taskText(prompt).contains(probe) {
                return read(dir)
            }
        }
        return nil
    }
}

@MainActor
final class PairRunModel: ObservableObject {
    @Published var run: PairRun
    @Published var items: [TranscriptItem] = []
    @Published var brief = ""
    @Published var findings: ReviewFindings?
    private var timer: Timer?
    private var lastSize: UInt64 = 0

    init(run: PairRun) {
        self.run = run
        brief = PairRuns.taskText((try? String(contentsOfFile: run.dir + "/prompt.md", encoding: .utf8)) ?? "")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let path = run.dir + "/events.jsonl"
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        if size != lastSize, let data = FileManager.default.contents(atPath: path) {
            lastSize = size
            items = Array(Transcript.parse(data: data, agent: run.to == "claude" ? "claude" : "codex-exec").items.suffix(400))
        }
        if findings == nil, let data = FileManager.default.contents(atPath: run.dir + "/findings.json") {
            findings = try? JSONDecoder().decode(ReviewFindings.self, from: data)
        }
        let state = PairRuns.state(run.dir)
        if state != run.state, let updated = PairRuns.read(run.dir) { run = updated }
        if state != "running" { stop() }
    }
}

struct PairRunView: View {
    @ObservedObject var model: PairRunModel
    @State private var showBrief = false

    private var who: String { model.run.to == "codex" ? "Codex" : model.run.to == "claude" ? "Claude" : model.run.to }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "person.2").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.run.brief).font(.headline).lineLimit(1)
                    Text("\(who) · \(model.run.mode) · \(model.run.repo) · \(model.run.started.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch model.run.state {
                case "running":
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working").font(.caption).foregroundStyle(.secondary) }
                case "done": Label("Done", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                case "failed": Label("Failed", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                default: Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        DisclosureGroup(isExpanded: $showBrief) {
                            Text(model.brief).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                        } label: {
                            Label("Brief from \(model.run.from == "claude" ? "Claude" : model.run.from)", systemImage: "doc.text")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
                        if let f = model.findings { FindingsView(findings: f, run: model.run, who: who) }
                        if model.items.isEmpty {
                            Text(model.run.state == "running" ? "\(who) is starting…" : "Nothing recorded.").foregroundStyle(.secondary)
                        }
                        ForEach(model.items) { ItemView(item: $0, folder: model.run.repo).id($0.id) }
                        if model.run.state == "running" && !model.items.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("\(who) is working…").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 4).id("end")
                    }
                    .padding(16)
                }
                .onChange(of: model.items.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { if model.findings == nil { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

@MainActor
enum PairRunWindows {
    private static var open: [String: NSWindow] = [:]

    static func show(_ run: PairRun) {
        if let w = open[run.dir] { w.makeKeyAndOrderFront(nil); return }
        let model = PairRunModel(run: run)
        let w = NSWindow(contentViewController: NSHostingController(rootView: PairRunView(model: model)))
        w.title = "\(run.to == "codex" ? "Codex" : run.to.capitalized): \(run.brief)"
        w.setContentSize(NSSize(width: 680, height: 620))
        w.isReleasedWhenClosed = false
        open[run.dir] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.stop()
                open[run.dir] = nil
            }
        }
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}


struct ReviewFindings: Decodable, Equatable {
    struct Finding: Decodable, Equatable, Identifiable {
        var id: String { file + ":\(line):" + title }
        let severity: String
        let file: String
        let line: Int
        let title: String
        let detail: String
        let fix: String
    }
    let summary: String
    let findings: [Finding]
}

struct FindingsView: View {
    let findings: ReviewFindings
    let run: PairRun
    let who: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(findings.findings.isEmpty ? "No findings" : "\(findings.findings.count) finding\(findings.findings.count == 1 ? "" : "s")",
                  systemImage: findings.findings.isEmpty ? "checkmark.seal" : "list.bullet.clipboard")
                .font(.headline)
            Text(findings.summary).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(findings.findings) { f in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(f.severity.uppercased()).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(color(f.severity).opacity(0.18)))
                            .foregroundStyle(color(f.severity))
                        Text(f.title).font(.callout.weight(.semibold))
                    }
                    Text(f.file + (f.line > 0 ? ":\(f.line)" : "")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Text(f.detail).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("Fix: " + f.fix).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Apply Fix") { apply(f) }
                            .help("\(who) makes this change in a new tab, where you can watch it.")
                        Button("Open File") { open(f) }
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
            }
        }
    }

    private func color(_ severity: String) -> Color {
        severity == "high" ? .red : severity == "medium" ? .orange : .secondary
    }

    private var repoPath: String {
        run.repo.hasPrefix("/") ? run.repo : (Git.root(of: FileManager.default.currentDirectoryPath) ?? run.repo)
    }

    private func open(_ f: ReviewFindings.Finding) {
        NSWorkspace.shared.open(URL(fileURLWithPath: (repoPath as NSString).appendingPathComponent(f.file)))
    }

    private func apply(_ f: ReviewFindings.Finding) {
        guard let pair = SidebarModel.pairTool, let app = NSApp.delegate as? AppDelegate else { return }
        let brief = """
            Goal: apply one fix from a code review of this repo.
            File: \(f.file)\(f.line > 0 ? " (around line \(f.line))" : "")
            Problem: \(f.title). \(f.detail)
            Fix: \(f.fix)
            Done when: the fix is made, nothing unrelated is changed, and the relevant tests pass.
            """
        let file = NSTemporaryDirectory() + "terminess-fix-\(UUID().uuidString.prefix(8)).md"
        guard (try? brief.write(toFile: file, atomically: true, encoding: .utf8)) != nil else { return }
        let target = run.to == "claude" ? "claude" : "codex"
        let c = app.open(tabbedWith: NSApp.keyWindow, directory: repoPath,
                         command: "\(shellQuote(pair)) handoff \(target) --from user --brief-file \(shellQuote(file))")
        c.customTitle = "Fix: " + f.title
    }
}
