import AppKit

enum Git {
    struct Result { let status: Int32; let output: String }

    @discardableResult
    static func run(_ dir: String, _ args: [String]) -> Result {
        exec("/usr/bin/git", ["-C", dir] + args)
    }

    static func exec(_ tool: String, _ args: [String], cwd: String? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return Result(status: -1, output: "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func root(of dir: String) -> String? {
        let r = run(dir, ["rev-parse", "--show-toplevel"])
        return r.status == 0 ? r.output : nil
    }

    static func mainRoot(of dir: String) -> String? {
        let r = run(dir, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard r.status == 0 else { return nil }
        return URL(fileURLWithPath: r.output).deletingLastPathComponent().path
    }

    static func currentBranch(_ dir: String) -> String? {
        let r = run(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
        return r.status == 0 && r.output != "HEAD" ? r.output : nil
    }

    static var gh: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func githubRepo(_ dir: String) -> String? {
        let r = run(dir, ["remote", "get-url", "origin"])
        guard r.status == 0, r.output.contains("github.com") else { return nil }
        var s = r.output
        if let range = s.range(of: "github.com") { s = String(s[range.upperBound...]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s.isEmpty ? nil : s
    }

    static func draftCommitMessage(_ dir: String, fallback: String) async -> String {
        let stat = run(dir, ["diff", "HEAD", "--stat"]).output
        let untracked = run(dir, ["ls-files", "--others", "--exclude-standard"]).output
        var diff = run(dir, ["diff", "HEAD", "--unified=1", "--no-color"]).output
        if diff.count > 6_000 { diff = String(diff.prefix(6_000)) + "\n[diff truncated]" }
        let prompt = """
        Changes (stat):
        \(stat)
        New files:
        \(untracked.isEmpty ? "none" : untracked)

        Diff:
        \(diff)
        """
        let instructions = """
        You write git commit messages. Reply with only the message: a summary line in the imperative mood of at most 70 characters, then a blank line, then up to three short lines explaining what changed and why. British English. Do not use em dashes or en dashes. Do not mention AI or that the message was generated.
        """
        if let text = await OnDeviceModel.generate(prompt, instructions: instructions, maxTokens: 180) {
            return text.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: " to ")
        }
        return fallback
    }
}

struct GitError: Error { let message: String }

struct WorktreeInfo: Codable, Equatable {
    var repo: String
    var path: String
    var branch: String
    var base: String
}

@MainActor
enum Worktrees {
    static func create(repo: String, branch: String) -> Result<WorktreeInfo, GitError> {
        guard let root = Git.mainRoot(of: repo) ?? Git.root(of: repo) else { return .failure(GitError(message: "Not inside a git repository.")) }
        let base = Git.currentBranch(repo) ?? "HEAD"
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        let path = root + "/.worktrees/" + safe
        let exclude = Git.run(root, ["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"]).output
        if !exclude.isEmpty {
            var current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
            let lines = Set(current.split(separator: "\n").map(String.init))
            let wanted = [".worktrees/", "node_modules", ".venv", "venv"].filter { !lines.contains($0) }
            if !wanted.isEmpty {
                if !current.isEmpty && !current.hasSuffix("\n") { current += "\n" }
                current += wanted.joined(separator: "\n") + "\n"
                try? FileManager.default.createDirectory(atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try? current.write(toFile: exclude, atomically: true, encoding: .utf8)
            }
        }
        let r = Git.run(root, ["worktree", "add", "-b", branch, path, base])
        guard r.status == 0 else { return .failure(GitError(message: r.output)) }
        linkEssentials(from: root, to: path)
        return .success(WorktreeInfo(repo: root, path: path, branch: branch, base: base))
    }

    private static func linkEssentials(from root: String, to path: String) {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return }
        while let rel = e.nextObject() as? String {
            let depth = rel.split(separator: "/").count
            let name = (rel as NSString).lastPathComponent
            if rel.hasPrefix(".git") || rel.hasPrefix(".worktrees") { e.skipDescendants(); continue }
            if depth > 3 { e.skipDescendants(); continue }
            let src = root + "/" + rel, dst = path + "/" + rel
            var isDir: ObjCBool = false
            fm.fileExists(atPath: src, isDirectory: &isDir)
            if isDir.boolValue && ["node_modules", ".venv", "venv"].contains(name) {
                if fm.fileExists(atPath: (dst as NSString).deletingLastPathComponent) && !fm.fileExists(atPath: dst) {
                    try? fm.createSymbolicLink(atPath: dst, withDestinationPath: src)
                }
                e.skipDescendants()
            } else if !isDir.boolValue && name.hasPrefix(".env") && !fm.fileExists(atPath: dst) {
                if Git.run(root, ["check-ignore", "-q", rel]).status == 0 { try? fm.copyItem(atPath: src, toPath: dst) }
            }
        }
    }

    static func remove(_ w: WorktreeInfo, deleteBranch: Bool, force: Bool) -> String? {
        var args = ["worktree", "remove", w.path]
        if force { args.insert("--force", at: 2) }
        let r = Git.run(w.repo, args)
        guard r.status == 0 else { return r.output }
        if deleteBranch {
            let b = Git.run(w.repo, ["branch", force ? "-D" : "-d", w.branch])
            if b.status != 0 { return b.output }
        }
        return nil
    }
}
