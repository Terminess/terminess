import AppKit

extension AppDelegate {

    @objc func newWorktreeTab(_ sender: Any?) {
        guard let dir = keyController?.currentDirectory, Git.root(of: dir) != nil else {
            alert("Not in a git repository", "Open a tab in a repository first, then create a worktree tab from it.")
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        field.stringValue = "agent/\(f.string(from: Date()))"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        picker.addItems(withTitles: ["Claude Code", "Codex", "Shell only"])
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        box.addSubview(field)
        box.addSubview(picker)
        let a = NSAlert()
        a.messageText = "New Worktree Tab"
        a.informativeText = "Creates a branch and its own working copy of this repository, so this tab's work stays separate until you merge it."
        a.accessoryView = box
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let branch = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return }
        let command = ["claude", "codex", nil][picker.indexOfSelectedItem]
        openWorktreeTab(repo: dir, branch: branch, command: command)
    }

    @discardableResult
    func openWorktreeTab(repo: String, branch: String, command: String?) -> TerminalWindowController? {
        switch Worktrees.create(repo: repo, branch: branch) {
        case .failure(let error):
            alert("Could not create the worktree", error.message)
            return nil
        case .success(let info):
            let c = open(tabbedWith: keyController?.window, directory: info.path, command: command)
            c.worktree = info
            return c
        }
    }

    func worktreeAction(_ id: ObjectIdentifier, _ action: String) {
        guard let c = controllers.first(where: { ObjectIdentifier($0) == id }), let w = c.worktree else { return }
        switch action {
        case "merge": merge(c, w)
        case "remove":
            if let error = Worktrees.remove(w, deleteBranch: false, force: false) {
                alert("Could not remove the worktree", error + "\n\nCommit or discard its changes first.")
            } else {
                c.worktree = nil
                c.window?.performClose(nil)
            }
        case "discard":
            guard confirm("Discard \(w.branch)?", "Deletes the worktree and its branch, including any uncommitted or unmerged work. This cannot be undone.", "Discard") else { return }
            c.window?.performClose(nil)
            if let error = Worktrees.remove(w, deleteBranch: true, force: true) { alert("Could not discard", error) }
        default: break
        }
    }

    private func merge(_ c: TerminalWindowController, _ w: WorktreeInfo) {
        if let onBranch = Git.currentBranch(w.repo), onBranch != w.base {
            alert("Switch your main checkout first", "\(w.repo) is on \(onBranch), but this worktree was made from \(w.base). Check out \(w.base) there, then merge.")
            return
        }
        Task {
            let message = await Git.draftCommitMessage(w.path, fallback: "Work from \(w.branch)")
            await MainActor.run {
                guard let text = self.editMessage(title: "Merge \(w.branch) into \(w.base)",
                                                  note: "Commits the worktree's changes with this message, then merges the branch into \(w.base).",
                                                  message: message, button: "Commit and Merge") else { return }
                Task.detached {
                    let msgFile = NSTemporaryDirectory() + "terminal-commit-\(UUID().uuidString).txt"
                    try? text.write(toFile: msgFile, atomically: true, encoding: .utf8)
                    Git.run(w.path, ["add", "-A"])
                    var log = ""
                    if Git.run(w.path, ["diff", "--cached", "--quiet"]).status != 0 {
                        log += Git.run(w.path, ["commit", "-F", msgFile]).output + "\n"
                    }
                    let m = Git.run(w.repo, ["merge", "--no-ff", "-m", "Merge branch '\(w.branch)'", w.branch])
                    try? FileManager.default.removeItem(atPath: msgFile)
                    await MainActor.run {
                        if m.status == 0 {
                            if self.confirm("Merged into \(w.base)", "Remove the worktree and its branch now?", "Remove") {
                                c.window?.performClose(nil)
                                if let e = Worktrees.remove(w, deleteBranch: true, force: false) { self.alert("Could not remove", e) }
                            }
                        } else {
                            self.alert("The merge stopped", log + m.output + "\n\nResolve it in \(w.repo); a tab is open there.")
                            self.open(tabbedWith: c.window, directory: w.repo, command: "git status")
                        }
                    }
                }
            }
        }
    }


    @objc func commitChanges(_ sender: Any?) {
        guard let dir = keyController?.currentDirectory, let root = Git.root(of: dir) else {
            alert("Not in a git repository", "Open a tab in a repository first.")
            return
        }
        let stat = Git.run(root, ["status", "--short"]).output
        guard !stat.isEmpty else { alert("Nothing to commit", "\(root) has no changes."); return }
        Task {
            let message = await Git.draftCommitMessage(root, fallback: "Update")
            await MainActor.run {
                let lines = stat.split(separator: "\n")
                let summary = lines.prefix(8).joined(separator: "\n") + (lines.count > 8 ? "\n…and \(lines.count - 8) more" : "")
                guard let text = self.editMessage(title: "Commit all changes", note: summary, message: message,
                                                  button: "Commit", secondButton: "Commit and Push") else { return }
                let push = self.lastChoiceWasSecond
                Task.detached {
                    let msgFile = NSTemporaryDirectory() + "terminal-commit-\(UUID().uuidString).txt"
                    try? text.write(toFile: msgFile, atomically: true, encoding: .utf8)
                    Git.run(root, ["add", "-A"])
                    let r = Git.run(root, ["commit", "-F", msgFile])
                    try? FileManager.default.removeItem(atPath: msgFile)
                    var out = r.output
                    if r.status == 0 && push { out += "\n" + Git.run(root, ["push"]).output }
                    await MainActor.run {
                        self.alert(r.status == 0 ? (push ? "Committed and pushed" : "Committed") : "Commit failed", out)
                    }
                }
            }
        }
    }


    func startIssue(_ issue: IssueItem, agent: String) {
        guard let gh = Git.gh, let repo = SidebarModel.shared.issuesRepo, let dir = keyController?.currentDirectory else { return }
        Task.detached {
            let r = Git.exec(gh, ["issue", "view", "\(issue.number)", "-R", repo, "--json", "title,body,comments,url"])
            var prompt = "Work on GitHub issue #\(issue.number): \(issue.title)\n"
            if let obj = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any] {
                if let url = obj["url"] as? String { prompt += url + "\n" }
                if let body = obj["body"] as? String, !body.isEmpty { prompt += "\n" + body + "\n" }
                if let comments = obj["comments"] as? [[String: Any]], !comments.isEmpty {
                    prompt += "\nComments:\n"
                    for c in comments.suffix(10) {
                        let who = (c["author"] as? [String: Any])?["login"] as? String ?? "someone"
                        prompt += "- \(who): \(c["body"] as? String ?? "")\n"
                    }
                }
            }
            prompt += "\nStart by reading the relevant code and proposing a plan."
            let slug = issue.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
                .reduce(into: "") { s, ch in if !(ch == "-" && s.hasSuffix("-")) { s.append(ch) } }
                .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32)
            let file = SidebarModel.pairState + "/briefs/issue-\(issue.number)-\(Int(Date().timeIntervalSince1970)).md"
            try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? prompt.write(toFile: file, atomically: true, encoding: .utf8)
            await MainActor.run {
                self.openWorktreeTab(repo: dir, branch: "issue-\(issue.number)-\(slug)",
                                     command: "\(agent) \"$(cat \(shellQuote(file)))\"")
            }
        }
    }


    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = String(text.prefix(2_000))
        a.runModal()
    }

    func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func editMessage(title: String, note: String, message: String, button: String, secondButton: String? = nil) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = note
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 130))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.string = message
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.autoresizingMask = [.width]
        scroll.documentView = text
        a.accessoryView = scroll
        a.addButton(withTitle: button)
        if let secondButton { a.addButton(withTitle: secondButton) }
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        lastChoiceWasSecond = secondButton != nil && r == .alertSecondButtonReturn
        if r == .alertFirstButtonReturn || lastChoiceWasSecond {
            let t = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }
}
