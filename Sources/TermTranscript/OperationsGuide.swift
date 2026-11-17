import Foundation

public enum OperationsGuide {
    public static let operationsName = "OPERATIONS.md"
    public static let orchestrateName = "ORCHESTRATE.md"

    public struct FileStatus: Equatable, Sendable {
        public let path: String
        public let exists: Bool
        public let modified: Date?
        public let lines: Int
        public init(path: String, exists: Bool, modified: Date?, lines: Int) {
            self.path = path; self.exists = exists; self.modified = modified; self.lines = lines
        }
    }

    public struct Status: Equatable, Sendable {
        public let folder: String
        public let operations: FileStatus
        public let orchestrate: FileStatus
        public var exists: Bool { operations.exists || orchestrate.exists }
        public var complete: Bool { operations.exists && orchestrate.exists }
    }

    public static func candidateFolders(home: String, configured: String?) -> [String] {
        var out: [String] = []
        if let c = configured, !c.isEmpty { out.append(expand(c, home: home)) }
        for sub in ["", "github", "Projects", "projects", "code", "Code", "Developer", "src", "dev"] {
            out.append(sub.isEmpty ? home : home + "/" + sub)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public static func locate(home: String, configured: String?,
                              fileManager: FileManager = .default) -> Status {
        let folders = candidateFolders(home: home, configured: configured)
        let found = folders.first { f in
            fileManager.fileExists(atPath: f + "/" + operationsName) || fileManager.fileExists(atPath: f + "/" + orchestrateName)
        }
        let folder = found ?? folders.first ?? home
        return Status(folder: folder,
                      operations: status(folder + "/" + operationsName, fileManager),
                      orchestrate: status(folder + "/" + orchestrateName, fileManager))
    }

    static func status(_ path: String, _ fm: FileManager) -> FileStatus {
        guard fm.fileExists(atPath: path) else { return FileStatus(path: path, exists: false, modified: nil, lines: 0) }
        let attrs = try? fm.attributesOfItem(atPath: path)
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return FileStatus(path: path, exists: true, modified: attrs?[.modificationDate] as? Date, lines: lines)
    }

    public static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    public static func tilde(_ path: String, home: String) -> String {
        path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }


    public static let operationsSections: [(title: String, covers: String)] = [
        ("Hard rules: where they live", "a pointer to the global CLAUDE.md and AGENTS.md, which hold the rules every agent must follow; do not copy the rules here"),
        ("Identity, accounts, git", "names and emails used for commits, Git hosting accounts and organisations, which account owns what, SSH keys by purpose (never key material)"),
        ("Local machine and toolchain", "operating system, shells, package managers, language runtimes and versions, editors, anything unusual about this machine"),
        ("Agent configuration", "Claude Code and Codex settings, hooks, status lines, permission defaults, where their config lives"),
        ("MCP servers and skills", "which MCP servers and skills are configured, for which agent, and what each is for"),
        ("Machines and servers", "every server or always-on machine: what it is, how to reach it (ssh alias), what runs on it, who may change it, how it is protected"),
        ("Domains and DNS", "domains owned, where DNS is hosted, which services sit behind which names, certificate setup"),
        ("Deploy playbooks and CI", "for each app: the exact command that deploys it, what it does, how to check it worked, how to roll back; what CI runs"),
        ("Mirrors and publishing rules", "public mirrors of private repos and the rules for syncing them, anything that must never be published"),
        ("Scheduled automation", "cron, launchd and systemd timers on each machine: what runs when, where logs go, how to pause it"),
        ("Secrets and where they live", "for each secret: which file or manager holds it and who may read it. NEVER the value itself"),
        ("Gotchas that have bitten before", "hard-won lessons: the symptom, the cause, the fix, so no agent repeats them"),
        ("Repo map", "each repository: what it is, where it lives locally and remotely, its main branch, whether it is local only"),
        ("Project context", "per project: the essentials an agent needs before touching it, the current state, open decisions"),
    ]

    public static let orchestrateSections: [(title: String, covers: String)] = [
        ("Who leads", "which agent is the main session, which is the worker, and when to swap"),
        ("Repo ownership", "repositories one agent owns (the other only reviews), and the default for everything else"),
        ("Pairing", "how agents hand work to each other (pair ask, handoff, review, parallel) and when to use each"),
        ("Where work runs", "local machine versus headless server: which work needs the local machine (browser, desktop apps, device builds) and which belongs on the server"),
        ("Review loops", "build, then the other agent reviews, then fix; what counts as done"),
        ("Background agents", "worktrees, one heavy build at a time, never killing processes by name, report format, commit rules"),
        ("Standing process rules", "what needs the person's go-ahead every time (production changes, publishing, deleting, spending), what agents may do freely, writing style rules"),
        ("Picking work up later", "when the person says \"later\", set a Terminess reminder (terminessd remind add, or the remind tool) instead of relying on the chat staying open"),
    ]

    public static let maintainingSection = """
        ## Maintaining this file

        - Update this file in the same session as the change it describes. Facts about \
        the setup go in OPERATIONS.md; rules about how agents behave go in ORCHESTRATE.md.
        - Correct wrong entries instead of appending contradictions.
        - Verify before writing. Mark anything you could not check "(unverified YYYY-MM-DD)".
        - Record where secrets live, never their values.
        """

    static func outline(_ sections: [(title: String, covers: String)]) -> String {
        sections.enumerated().map { "\($0.offset + 1). \($0.element.title): \($0.element.covers)." }.joined(separator: "\n")
    }


    public static func reviewer(for agent: String) -> String { agent == "codex" ? "claude" : "codex" }

    public static func buildPrompt(operations: String, orchestrate: String, agent: String,
                                   projectRoots: [String], machines: [String]) -> String {
        let roots = projectRoots.isEmpty ? "~ (look for git repositories one or two levels down)" : projectRoots.joined(separator: ", ")
        let hosts = machines.isEmpty ? "none configured in Terminess" : machines.joined(separator: ", ")
        return """
            Build my operations guide: two Markdown files that tell any AI agent how my setup \
            is built and how agents should work here.

            - \(operations): the facts about my setup.
            - \(orchestrate): how agents behave and divide the work.

            If either file already exists, read it first and keep everything that is still \
            true; this is an improvement, not a replacement.

            ## 1. Scan what you can, before asking me anything

            Look, read-only, at:
            - Git repositories under \(roots): their remotes, default branches, whether they \
            have a remote at all (a missing remote may be deliberate: ask, don't assume).
            - ~/.ssh/config: hosts and aliases (names and purposes only, never key material).
            - The global CLAUDE.md (~/.claude/CLAUDE.md) and AGENTS.md (~/.codex/AGENTS.md), \
            and any project CLAUDE.md or AGENTS.md files.
            - MCP server configuration for Claude Code and Codex.
            - Deploy scripts (deploy.sh, Makefile targets, package.json scripts, CI workflows).
            - Scheduled jobs: crontab -l, ~/Library/LaunchAgents, systemd user units.
            - Package managers and runtimes in use (brew, npm, pip, uv, cargo and so on).
            - Remote machines Terminess knows about: \(hosts). You may run read-only commands \
            on them over ssh (hostname, uptime, systemctl list-units, crontab -l); change nothing.

            ## 2. Interview me for the rest

            Ask short, grouped questions, a few at a time, for what the scan cannot tell you: \
            which accounts own what, which repositories are private or local only, deploy \
            rules, what needs my go-ahead every time, how I like the agents to split work.

            ## 3. Write the two files, section by section

            \(operations), sections (skip any that don't apply, add any I need):
            \(outline(operationsSections))

            \(orchestrate), sections:
            \(outline(orchestrateSections))

            End each file with a "Maintaining this file" section like this:

            \(maintainingSection)

            ## Rules

            - NEVER write a secret value (passwords, tokens, API keys, private keys, recovery \
            codes) into either file. Record only where each secret lives and who may read it. \
            If you see a value while scanning, do not repeat it anywhere.
            - Be specific and practical: exact commands, paths and names, so another agent can act \
            on it without asking. Prefer distilled facts over narrative.
            - Mark anything you could not verify "(unverified \(today()))".
            - Show me each file's outline before writing it in full, and the finished files before \
            you finish.

            ## 4. Review

            When both files are written, run `pair review \(reviewer(for: agent)) "Review \(operations) \
            and \(orchestrate) for gaps, mistakes, contradictions and any secret values"` and fix \
            what it finds. Then tell me it's done, and offer to add a pointer to the guide in the \
            global CLAUDE.md and AGENTS.md if it isn't there yet.
            """
    }

    public static func updatePrompt(operations: String, orchestrate: String, agent: String,
                                    projectRoots: [String], machines: [String]) -> String {
        let roots = projectRoots.isEmpty ? "~" : projectRoots.joined(separator: ", ")
        let hosts = machines.isEmpty ? "none configured in Terminess" : machines.joined(separator: ", ")
        return """
            Update my operations guide: \(operations) (facts about my setup) and \(orchestrate) \
            (how agents behave and divide the work).

            1. Read both files.
            2. Re-scan, read-only, what they describe: git repositories under \(roots) and their \
            remotes, ~/.ssh/config hosts, the global CLAUDE.md and AGENTS.md, MCP configuration, \
            deploy scripts, scheduled jobs, toolchain versions, and the remote machines Terminess \
            knows about (\(hosts)) with read-only commands only.
            3. Also look through recent Claude Code and Codex conversations (~/.claude/projects, \
            ~/.codex/sessions) for decisions, new rules I gave, and things that changed.
            4. Show me a proposed diff for each file, grouped by section, with a one-line reason \
            per change. Do not edit anything until I agree.
            5. After I agree, apply it, keeping each file's "Maintaining this file" section.

            Never write a secret value into either file; record only where it lives. Mark anything \
            you could not verify "(unverified \(today()))".
            """
    }

    static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }


    public static func pointerLine(operations: String, orchestrate: String) -> String {
        "Read \(operations) before infrastructure work; \(orchestrate) for dividing work."
    }

    public static func hasPointer(_ text: String) -> Bool {
        text.contains(operationsName) || text.contains(orchestrateName)
    }

    public static func addingPointer(to text: String, operations: String, orchestrate: String) -> String? {
        guard !hasPointer(text) else { return nil }
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        out += "## Operations guide\n\n" + pointerLine(operations: operations, orchestrate: orchestrate) + "\n"
        return out
    }
}
