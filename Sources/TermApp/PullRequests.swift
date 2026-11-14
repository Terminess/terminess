import AppKit

enum PullRequests {
    struct Plan: Sendable {
        let root: String
        let repo: String
        let branch: String
        let base: String
        let baseRef: String
        let subjects: [String]
        let dirty: Bool
        let existingURL: String?
    }

    static func plan(dir: String, worktreeBase: String?) -> Result<Plan, GitError> {
        if let problem = Git.ghProblem() { return .failure(GitError(message: problem)) }
        guard let gh = Git.gh, let root = Git.root(of: dir) else { return .failure(GitError(message: "\(dir) is not in a git repository.")) }
        guard let branch = Git.currentBranch(root) else {
            return .failure(GitError(message: "This tab is not on a branch (detached HEAD). Check out a branch first."))
        }
        guard let repo = Git.ghRepo(root) else { return .failure(GitError(message: "\(root) has no GitHub remote.")) }
        let defaultBranch = defaultBranch(gh: gh, repo: repo, root: root)
        if branch == defaultBranch {
            return .failure(GitError(message: "This tab is on \(branch), the default branch. Pull requests are opened from another branch, such as a worktree tab's."))
        }
        var existing: String?
        let v = Git.exec(gh, ["pr", "view", branch, "-R", repo, "--json", "url,state"], cwd: root)
        if v.status == 0, let obj = try? JSONSerialization.jsonObject(with: Data(v.output.utf8)) as? [String: Any],
           (obj["state"] as? String)?.uppercased() == "OPEN" {
            existing = obj["url"] as? String
        }
        var base = defaultBranch
        if let b = worktreeBase, b != "HEAD", b != branch,
           Git.run(root, ["ls-remote", "--exit-code", "--heads", "origin", b]).status == 0 {
            base = b
        }
        Git.run(root, ["fetch", "--quiet", "origin", base])
        let remoteRef = "origin/\(base)"
        let baseRef = Git.run(root, ["rev-parse", "--verify", "--quiet", remoteRef]).status == 0 ? remoteRef : base
        let log = Git.run(root, ["log", "--no-merges", "--format=%s", "\(baseRef)..HEAD"])
        let subjects = log.status == 0 ? log.output.split(separator: "\n").map(String.init) : []
        if subjects.isEmpty && existing == nil {
            return .failure(GitError(message: "\(branch) has no commits that are not already on \(base). Commit your work first."))
        }
        let dirty = !Git.run(root, ["status", "--porcelain"]).output.isEmpty
        return .success(Plan(root: root, repo: repo, branch: branch, base: base, baseRef: baseRef,
                             subjects: subjects, dirty: dirty, existingURL: existing))
    }

    static func defaultBranch(gh: String, repo: String, root: String) -> String {
        let r = Git.exec(gh, ["repo", "view", repo, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"], cwd: root)
        if r.status == 0, !r.output.isEmpty, !r.output.contains(" ") { return r.output }
        let s = Git.run(root, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        if s.status == 0, s.output.hasPrefix("origin/") { return String(s.output.dropFirst(7)) }
        return "main"
    }

    static func draft(_ plan: Plan) async -> (title: String, body: String) {
        let stat = Git.run(plan.root, ["diff", "--stat", "\(plan.baseRef)...HEAD"]).output
        let fallback = fallbackDraft(plan, stat: stat)
        var diff = Git.run(plan.root, ["diff", "--unified=1", "--no-color", "\(plan.baseRef)...HEAD"]).output
        if diff.count > 6_000 { diff = String(diff.prefix(6_000)) + "\n[diff truncated]" }
        let prompt = """
        Branch: \(plan.branch)
        Commits:
        \(plan.subjects.prefix(40).map { "- " + $0 }.joined(separator: "\n"))

        Changes (stat):
        \(stat)

        Diff:
        \(diff)
        """
        let instructions = """
        You write GitHub pull request descriptions. Reply with only the title on the first line (at most 70 characters, imperative mood, no prefix), then a blank line, then the body in Markdown: one short paragraph saying what the change does and why, then a bulleted list of the main changes. British English. Do not use em dashes or en dashes. Do not mention AI, assistants, or that the text was generated.
        """
        guard let text = await OnDeviceModel.generate(prompt, instructions: instructions, maxTokens: 400) else { return fallback }
        var lines = clean(text).components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard let first = lines.first else { return fallback }
        var title = first.trimmingCharacters(in: CharacterSet(charactersIn: "#* ").union(.whitespaces))
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? fallback.title : title, body.isEmpty ? fallback.body : body)
    }

    static func fallbackDraft(_ plan: Plan, stat: String) -> (title: String, body: String) {
        let title: String
        if plan.subjects.count == 1 {
            title = plan.subjects[0]
        } else {
            let words = plan.branch.split(separator: "/").last.map(String.init) ?? plan.branch
            let spaced = words.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            title = spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
        var body = "## Changes\n\n" + plan.subjects.reversed().map { "- " + $0 }.joined(separator: "\n")
        if let summary = stat.split(separator: "\n").last { body += "\n\n" + summary.trimmingCharacters(in: .whitespaces) }
        return (title, clean(body))
    }

    static func clean(_ text: String) -> String {
        let attribution = ["co-authored-by", "generated with", "generated by", "written by ai", "ai-generated", "ai generated"]
        return text.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: " to ")
            .components(separatedBy: "\n")
            .filter { line in let l = line.lowercased(); return !attribution.contains { l.contains($0) } }
            .joined(separator: "\n")
    }

    static func create(_ plan: Plan, title: String, body: String, draft: Bool) -> Result<String, GitError> {
        guard let gh = Git.gh else { return .failure(GitError(message: "The GitHub CLI is not installed.")) }
        guard Git.currentBranch(plan.root) == plan.branch, plan.branch != plan.base,
              plan.branch != defaultBranch(gh: gh, repo: plan.repo, root: plan.root) else {
            return .failure(GitError(message: "The tab's branch changed, or is the default branch. Nothing was pushed."))
        }
        let push = Git.run(plan.root, ["push", "-u", "origin", "HEAD"])
        guard push.status == 0 else { return .failure(GitError(message: "Could not push \(plan.branch):\n\n" + push.output)) }
        let file = NSTemporaryDirectory() + "terminal-pr-\(UUID().uuidString).md"
        try? clean(body).write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        var args = ["pr", "create", "-R", plan.repo, "--base", plan.base, "--head", plan.branch,
                    "--title", clean(title), "--body-file", file]
        if draft { args.append("--draft") }
        let r = Git.exec(gh, args, cwd: plan.root)
        let url = r.output.split(separator: "\n").map(String.init).last { $0.hasPrefix("https://") }
        guard r.status == 0, let url else { return .failure(GitError(message: "Pushed, but could not create the pull request:\n\n" + r.output)) }
        return .success(url)
    }
}

extension AppDelegate {
    @objc func openPullRequest(_ sender: Any?) {
        guard let c = keyController else { return }
        openPullRequest(for: c)
    }

    func openPullRequest(for c: TerminalWindowController) {
        guard let dir = c.worktree?.path ?? c.currentDirectory else { return }
        let worktreeBase = c.worktree?.base
        Task.detached {
            let result = PullRequests.plan(dir: dir, worktreeBase: worktreeBase)
            await MainActor.run {
                switch result {
                case .failure(let e): self.alert("Cannot open a pull request", e.message)
                case .success(let plan): self.continuePullRequest(plan, in: c)
                }
            }
        }
    }

    private func continuePullRequest(_ plan: PullRequests.Plan, in c: TerminalWindowController) {
        if let url = plan.existingURL {
            if confirm("\(plan.branch) already has a pull request", url, "Open Pull Request"), let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
            return
        }
        if plan.dirty && !confirm("Uncommitted changes", "\(plan.root) has changes that are not committed, so they will not be in the pull request. Use Commit Changes first to include them.", "Continue Without Them") {
            return
        }
        Task {
            let drafted = await PullRequests.draft(plan)
            await MainActor.run { self.editPullRequest(plan, drafted, in: c) }
        }
    }

    private func editPullRequest(_ plan: PullRequests.Plan, _ drafted: (title: String, body: String), in c: TerminalWindowController) {
        let width: CGFloat = 520
        let titleField = NSTextField(frame: NSRect(x: 0, y: 254, width: width, height: 24))
        titleField.stringValue = drafted.title
        titleField.placeholderString = "Title"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 26, width: width, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.string = drafted.body
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.autoresizingMask = [.width]
        scroll.documentView = text
        let draftBox = NSButton(checkboxWithTitle: "Open as a draft", target: nil, action: nil)
        draftBox.frame = NSRect(x: 0, y: 0, width: width, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 280))
        box.addSubview(titleField)
        box.addSubview(scroll)
        box.addSubview(draftBox)
        let a = NSAlert()
        a.messageText = "Open Pull Request"
        a.informativeText = "Pushes \(plan.branch) to origin, then proposes it for \(plan.base) in \(plan.repo)."
        a.accessoryView = box
        a.addButton(withTitle: "Push and Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = titleField
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { self.alert("A title is needed", "Nothing was pushed."); return }
            let body = text.string
            let draft = draftBox.state == .on
            Task.detached {
                let r = PullRequests.create(plan, title: title, body: body, draft: draft)
                await MainActor.run {
                    switch r {
                    case .failure(let e): self.alert("Pull request not created", e.message)
                    case .success(let url): self.showPullRequestCreated(url)
                    }
                }
            }
        }
        if let window = c.window { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
    }

    private func showPullRequestCreated(_ url: String) {
        let a = NSAlert()
        a.messageText = "Pull request created"
        a.informativeText = url
        a.addButton(withTitle: "Open")
        a.addButton(withTitle: "Copy Link")
        a.addButton(withTitle: "Close")
        switch a.runModal() {
        case .alertFirstButtonReturn: if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        default: break
        }
    }
}
