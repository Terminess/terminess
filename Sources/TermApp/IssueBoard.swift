import AppKit
import SwiftUI

extension Git {
    static func ghProblem() -> String? {
        guard let gh else { return "The GitHub CLI is not installed. Install it with `brew install gh`, then run `gh auth login`." }
        if exec(gh, ["auth", "status"]).status != 0 { return "The GitHub CLI is not signed in. Run `gh auth login` in a tab, then try again." }
        return nil
    }

    static func ghRepo(_ dir: String) -> String? {
        if let gh {
            let r = exec(gh, ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], cwd: dir)
            if r.status == 0, !r.output.isEmpty, !r.output.contains(" ") { return r.output }
        }
        return githubRepo(dir)
    }

    static func ghLogin() -> String? {
        guard let gh else { return nil }
        let r = exec(gh, ["api", "user", "--jq", ".login"])
        return r.status == 0 && !r.output.isEmpty ? r.output : nil
    }
}

struct BoardIssue: Identifiable, Equatable, Decodable {
    struct Label: Equatable, Hashable, Decodable { let name: String; let color: String? }
    struct User: Equatable, Decodable { let login: String }
    struct Comment: Equatable, Decodable {}
    let number: Int
    let title: String
    let labels: [Label]
    let assignees: [User]
    let state: String
    let comments: [Comment]
    let updatedAt: String?
    let closedAt: String?
    let url: String
    var subIssues: (total: Int, done: Int)?
    var id: Int { number }
    var isOpen: Bool { state.uppercased() == "OPEN" }

    enum CodingKeys: String, CodingKey { case number, title, labels, assignees, state, comments, updatedAt, closedAt, url }

    static func == (a: BoardIssue, b: BoardIssue) -> Bool {
        a.number == b.number && a.title == b.title && a.labels == b.labels && a.assignees == b.assignees
            && a.state == b.state && a.comments.count == b.comments.count && a.updatedAt == b.updatedAt
            && a.subIssues?.total == b.subIssues?.total && a.subIssues?.done == b.subIssues?.done
    }
}

@MainActor
final class IssueBoardModel: ObservableObject {
    static let progressLabels: Set<String> = ["in progress", "in-progress", "in_progress", "doing", "wip", "started"]

    let directory: String
    @Published var repo: String?
    @Published var me: String?
    @Published var open: [BoardIssue] = []
    @Published var closed: [BoardIssue] = []
    @Published var note: String?
    @Published var loading = false
    @Published var search = ""
    @Published var label = ""
    @Published var assignee = ""
    @Published var subIssuesNote: String?

    init(directory: String) {
        self.directory = directory
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let dir = directory
        Task.detached(priority: .userInitiated) {
            if let problem = Git.ghProblem() {
                await MainActor.run { self.finish(note: problem) }
                return
            }
            guard let gh = Git.gh, let repo = Git.ghRepo(dir) else {
                await MainActor.run { self.finish(note: "\(dir) has no GitHub remote.") }
                return
            }
            let me = Git.ghLogin()
            let fields = "number,title,labels,assignees,state,comments,updatedAt,closedAt,url"
            let o = Git.exec(gh, ["issue", "list", "-R", repo, "--json", fields, "--limit", "100"])
            let c = Git.exec(gh, ["issue", "list", "-R", repo, "--state", "closed", "--json", fields, "--limit", "40"])
            let decoder = JSONDecoder()
            var open = (try? decoder.decode([BoardIssue].self, from: Data(o.output.utf8))) ?? []
            var closed = (try? decoder.decode([BoardIssue].self, from: Data(c.output.utf8))) ?? []
            closed.sort { ($0.closedAt ?? "") > ($1.closedAt ?? "") }
            closed = Array(closed.prefix(30))
            let subs = IssueBoardModel.subIssueCounts(gh: gh, repo: repo)
            if let subs {
                for i in open.indices { open[i].subIssues = subs[open[i].number] }
                for i in closed.indices { closed[i].subIssues = subs[closed[i].number] }
            }
            let failed = o.status != 0 ? o.output : nil
            await MainActor.run {
                self.repo = repo
                self.me = me
                self.open = open
                self.closed = closed
                self.subIssuesNote = subs == nil ? "Sub-issue progress is not available for this repository." : nil
                self.finish(note: failed.map { "Could not load issues: \($0)" })
            }
        }
    }

    private func finish(note: String?) {
        self.note = note
        loading = false
    }

    nonisolated static func subIssueCounts(gh: String, repo: String) -> [Int: (total: Int, done: Int)]? {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let query = """
        query($o:String!,$n:String!){repository(owner:$o,name:$n){issues(first:100,states:[OPEN,CLOSED],orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number subIssuesSummary{total completed}}}}}
        """
        let r = Git.exec(gh, ["api", "graphql", "-f", "query=\(query)", "-F", "o=\(parts[0])", "-F", "n=\(parts[1])"])
        guard r.status == 0,
              let obj = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
              let data = obj["data"] as? [String: Any],
              let repository = data["repository"] as? [String: Any],
              let issues = repository["issues"] as? [String: Any],
              let nodes = issues["nodes"] as? [[String: Any]] else { return nil }
        var out: [Int: (total: Int, done: Int)] = [:]
        for node in nodes {
            guard let n = node["number"] as? Int, let s = node["subIssuesSummary"] as? [String: Any],
                  let total = s["total"] as? Int, total > 0 else { continue }
            out[n] = (total, s["completed"] as? Int ?? 0)
        }
        return out
    }

    func inProgress(_ i: BoardIssue) -> Bool {
        if let me, i.assignees.contains(where: { $0.login == me }) { return true }
        return i.labels.contains { IssueBoardModel.progressLabels.contains($0.name.lowercased()) }
    }

    private func matches(_ i: BoardIssue) -> Bool {
        if !label.isEmpty && !i.labels.contains(where: { $0.name == label }) { return false }
        switch assignee {
        case "": break
        case "@me": if !i.assignees.contains(where: { $0.login == me }) { return false }
        case "@none": if !i.assignees.isEmpty { return false }
        default: if !i.assignees.contains(where: { $0.login == assignee }) { return false }
        }
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let hay = "#\(i.number) \(i.title) \(i.labels.map(\.name).joined(separator: " "))".lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    var openColumn: [BoardIssue] { open.filter { !inProgress($0) && matches($0) } }
    var progressColumn: [BoardIssue] { open.filter { inProgress($0) && matches($0) } }
    var closedColumn: [BoardIssue] { closed.filter(matches) }

    var allLabels: [String] { Array(Set((open + closed).flatMap { $0.labels.map(\.name) })).sorted() }
    var allAssignees: [String] { Array(Set((open + closed).flatMap { $0.assignees.map(\.login) })).sorted() }


    func assignToMe(_ i: BoardIssue) { edit(["issue", "edit", "\(i.number)", "--add-assignee", "@me"]) }
    func close(_ i: BoardIssue) { edit(["issue", "close", "\(i.number)"]) }
    func reopen(_ i: BoardIssue) { edit(["issue", "reopen", "\(i.number)"]) }

    func openOnGitHub(_ i: BoardIssue) {
        if let url = URL(string: i.url) { NSWorkspace.shared.open(url) }
    }

    func start(_ i: BoardIssue, agent: String) {
        guard let repo, let app = NSApp.delegate as? AppDelegate else { return }
        app.startIssue(IssueItem(number: i.number, title: i.title, labels: []), agent: agent, repo: repo, directory: directory)
    }

    private func edit(_ args: [String]) {
        guard let gh = Git.gh, let repo else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let r = Git.exec(gh, args + ["-R", repo])
            await MainActor.run {
                self.loading = false
                if r.status != 0 { self.note = r.output } else { self.refresh() }
                SidebarModel.shared.refreshIssues(force: true)
            }
        }
    }
}

struct IssueBoardView: View {
    @ObservedObject var model: IssueBoardModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Picker("Label", selection: $model.label) {
                    Text("Any label").tag("")
                    ForEach(model.allLabels, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 180)
                Picker("Assignee", selection: $model.assignee) {
                    Text("Anyone").tag("")
                    Text("Me").tag("@me")
                    Text("Unassigned").tag("@none")
                    if !model.allAssignees.isEmpty { Divider() }
                    ForEach(model.allAssignees, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 200)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh").disabled(model.loading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if let note = model.note {
                Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                column("Open", model.openColumn)
                column("In progress", model.progressColumn)
                column("Recently closed", model.closedColumn)
            }
            .padding(12)
            if let sub = model.subIssuesNote {
                Text(sub).font(.caption).foregroundStyle(.tertiary).padding(.bottom, 6)
            }
        }
        .frame(minWidth: 820, minHeight: 480)
    }

    private func column(_ title: String, _ issues: [BoardIssue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Text("\(issues.count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(issues) { IssueCard(issue: $0, model: model) }
                    if issues.isEmpty && !model.loading {
                        Text("Nothing here.").font(.callout).foregroundStyle(.tertiary).padding(.top, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }
}

struct IssueCard: View {
    let issue: BoardIssue
    @ObservedObject var model: IssueBoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(issue.number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Text(issue.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if !issue.labels.isEmpty {
                FlowChips(labels: issue.labels)
            }
            HStack(spacing: 10) {
                if let who = issue.assignees.first {
                    Label(who.login + (issue.assignees.count > 1 ? " +\(issue.assignees.count - 1)" : ""), systemImage: "person")
                }
                if !issue.comments.isEmpty {
                    Label("\(issue.comments.count)", systemImage: "bubble.left")
                }
                if let s = issue.subIssues {
                    HStack(spacing: 4) {
                        ProgressView(value: Double(s.done), total: Double(max(s.total, 1))).frame(width: 40)
                        Text("\(s.done)/\(s.total)")
                    }
                    .help("Sub-issues completed")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .contextMenu { actions }
        .onTapGesture(count: 2) { model.openOnGitHub(issue) }
    }

    @ViewBuilder
    private var actions: some View {
        if issue.isOpen {
            Button("Start with Claude") { model.start(issue, agent: "claude") }
            Button("Start with Codex") { model.start(issue, agent: "codex") }
            Divider()
        }
        Button("Open on GitHub") { model.openOnGitHub(issue) }
        if issue.isOpen {
            Button("Assign to Me") { model.assignToMe(issue) }
                .disabled(model.me != nil && issue.assignees.contains { $0.login == model.me })
            Divider()
            Button("Close Issue") { model.close(issue) }
        } else {
            Divider()
            Button("Reopen Issue") { model.reopen(issue) }
        }
    }
}

struct FlowChips: View {
    let labels: [BoardIssue.Label]

    var body: some View {
        Wrap(spacing: 4) {
            ForEach(labels, id: \.self) { l in
                let bg = Color(hex: l.color) ?? .gray
                Text(l.name).font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(Color.isLight(hex: l.color) ? Color.black : Color.white)
                    .background(Capsule().fill(bg))
            }
        }
    }
}

struct Wrap: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(bounds.width, subviews)
        for (i, p) in rows.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return (points, maxX, y + rowHeight)
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func isLight(hex: String?) -> Bool {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return false }
        let r = Double((v >> 16) & 0xff), g = Double((v >> 8) & 0xff), b = Double(v & 0xff)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 150
    }
}

@MainActor
enum IssueBoardWindows {
    private static var open: [String: NSWindow] = [:]

    static func show(directory: String) {
        let key = Git.mainRoot(of: directory) ?? directory
        if let w = open[key] { w.makeKeyAndOrderFront(nil); return }
        let model = IssueBoardModel(directory: directory)
        let w = NSWindow(contentViewController: NSHostingController(rootView: IssueBoardView(model: model)))
        w.title = "Issues: \((key as NSString).lastPathComponent)"
        w.setContentSize(NSSize(width: 1040, height: 680))
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        open[key] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { open[key] = nil }
        }
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate {
    @objc func showIssueBoard(_ sender: Any?) {
        guard let dir = keyController?.currentDirectory, Git.root(of: dir) != nil else {
            alert("Not in a git repository", "Open a tab in a GitHub repository first, then open its issue board.")
            return
        }
        IssueBoardWindows.show(directory: dir)
    }
}
