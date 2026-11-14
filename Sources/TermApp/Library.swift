import AppKit
import TermTranscript

enum Library {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case skills = "Skills", commands = "Commands", agents = "Agents", mcp = "MCP Servers"
        var id: String { rawValue }
        var singular: String {
            switch self { case .skills: "skill"; case .commands: "command"; case .agents: "agent"; case .mcp: "MCP server" }
        }
    }

    enum Agent: String, CaseIterable, Sendable { case claude = "Claude", codex = "Codex" }

    enum Scope: String, Sendable { case user = "User", project = "Project", local = "Local" }

    struct Item: Identifiable, Hashable, Sendable {
        var kind: Kind
        var agent: Agent
        var scope: Scope
        var name: String
        var detail: String
        var file: String
        var location: String?
        var root: String
        var relative: String
        var enabled: Bool
        var id: String { [kind.rawValue, agent.rawValue, scope.rawValue, location ?? file, name].joined(separator: "|") }
    }

    struct Root: Sendable {
        var kind: Kind
        var agent: Agent
        var scope: Scope
        var path: String
        var recursive: Bool
    }

    static let disabledFolder = ".disabled"
    static let disabledSuffix = ".disabled"

    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var claudeDir: String { env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? Transcript.home + "/.claude" }
    static var claudeJSON: String {
        env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 + "/.claude.json" } ?? Transcript.home + "/.claude.json"
    }
    static var codexDir: String { env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? Transcript.home + "/.codex" }
    static var codexConfig: String { codexDir + "/config.toml" }

    static func projectRoot(_ dir: String?) -> String? {
        guard let dir, !dir.isEmpty else { return nil }
        let fm = FileManager.default
        var d = (dir as NSString).standardizingPath
        let start = d
        while d != "/" && d != Transcript.home {
            if fm.fileExists(atPath: d + "/.git") { return d }
            d = (d as NSString).deletingLastPathComponent
        }
        return start == Transcript.home || start == "/" ? nil : start
    }

    static func roots(project: String?) -> [Root] {
        var out = [
            Root(kind: .skills, agent: .claude, scope: .user, path: claudeDir + "/skills", recursive: false),
            Root(kind: .commands, agent: .claude, scope: .user, path: claudeDir + "/commands", recursive: true),
            Root(kind: .agents, agent: .claude, scope: .user, path: claudeDir + "/agents", recursive: true),
            Root(kind: .skills, agent: .codex, scope: .user, path: codexDir + "/skills", recursive: true),
            Root(kind: .skills, agent: .codex, scope: .user, path: Transcript.home + "/.agents/skills", recursive: true),
        ]
        if let p = project {
            out += [
                Root(kind: .skills, agent: .claude, scope: .project, path: p + "/.claude/skills", recursive: false),
                Root(kind: .commands, agent: .claude, scope: .project, path: p + "/.claude/commands", recursive: true),
                Root(kind: .agents, agent: .claude, scope: .project, path: p + "/.claude/agents", recursive: true),
                Root(kind: .skills, agent: .codex, scope: .project, path: p + "/.codex/skills", recursive: true),
                Root(kind: .skills, agent: .codex, scope: .project, path: p + "/.agents/skills", recursive: true),
            ]
        }
        return out
    }

    static func installRoot(_ kind: Kind, agent: Agent, scope: Scope, project: String?) -> String? {
        if scope == .project && project == nil { return nil }
        let base = scope == .user ? (agent == .claude ? claudeDir : codexDir) : project! + (agent == .claude ? "/.claude" : "/.agents")
        switch (kind, agent) {
        case (.skills, _): return base + "/skills"
        case (.commands, .claude): return base + "/commands"
        case (.agents, .claude): return base + "/agents"
        default: return nil
        }
    }


    static func scan(project: String?, currentDirectory: String?) -> [Item] {
        var items: [Item] = []
        for root in roots(project: project) {
            items += root.kind == .skills ? skills(in: root) : markdownFiles(in: root)
        }
        items += mcpServers(project: project, currentDirectory: currentDirectory)
        return items
    }

    private static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    private static func children(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private static func read(_ path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path), data.count < 1_000_000 else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func describe(_ text: String, _ front: [String: String]) -> String {
        var d = front["description"] ?? ""
        if d.isEmpty {
            var body = Substring(text)
            if text.hasPrefix("---"), let r = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
                body = text[r.upperBound...]
            }
            d = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("---") }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? ""
        }
        return d.count > 300 ? String(d.prefix(299)) + "…" : d
    }

    private static func skills(in root: Root) -> [Item] {
        var out: [Item] = []
        func walk(_ dir: String, relative: String, depth: Int, enabled: Bool, recursive: Bool) {
            for name in children(dir) {
                let path = dir + "/" + name
                let rel = relative.isEmpty ? name : relative + "/" + name
                guard isDirectory(path) else { continue }
                let skill = path + "/SKILL.md"
                if FileManager.default.fileExists(atPath: skill) {
                    let text = read(skill)
                    let front = AgentLibrary.frontmatter(text)
                    out.append(Item(kind: .skills, agent: root.agent, scope: root.scope,
                                    name: front["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name,
                                    detail: describe(text, front), file: skill, location: path,
                                    root: root.path, relative: rel, enabled: enabled))
                } else if recursive && depth < 4 {
                    walk(path, relative: rel, depth: depth + 1, enabled: enabled, recursive: recursive)
                }
            }
        }
        walk(root.path, relative: "", depth: 0, enabled: true, recursive: root.recursive)
        walk(root.path + "/" + disabledFolder, relative: "", depth: 0, enabled: false, recursive: true)
        return out
    }

    private static func markdownFiles(in root: Root) -> [Item] {
        var out: [Item] = []
        func walk(_ dir: String, relative: String, depth: Int, enabled: Bool) {
            for name in children(dir) {
                let path = dir + "/" + name
                let rel = relative.isEmpty ? name : relative + "/" + name
                if isDirectory(path) {
                    if depth < 4 { walk(path, relative: rel, depth: depth + 1, enabled: enabled) }
                    continue
                }
                let ending = enabled ? ".md" : ".md" + disabledSuffix
                guard name.hasSuffix(ending) else { continue }
                let enabledRel = enabled ? rel : String(rel.dropLast(disabledSuffix.count))
                let text = read(path)
                let front = AgentLibrary.frontmatter(text)
                let fileName = String(enabledRel.dropLast(3))
                let name = root.kind == .agents ? (front["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fileName) : fileName
                out.append(Item(kind: root.kind, agent: root.agent, scope: root.scope, name: name,
                                detail: describe(text, front), file: path, location: path,
                                root: root.path, relative: enabledRel, enabled: enabled))
            }
        }
        walk(root.path, relative: "", depth: 0, enabled: true)
        walk(root.path + "/" + disabledFolder, relative: "", depth: 0, enabled: false)
        return out
    }

    private static func mcpServers(project: String?, currentDirectory: String?) -> [Item] {
        var out: [Item] = []
        func add(_ servers: [AgentLibrary.MCPServer], _ agent: Agent, _ scope: Scope, _ file: String) {
            for s in servers where !out.contains(where: { $0.name == s.name && $0.agent == agent && $0.scope == scope }) {
                out.append(Item(kind: .mcp, agent: agent, scope: scope, name: s.name, detail: s.summary,
                                file: file, location: nil, root: (file as NSString).deletingLastPathComponent,
                                relative: s.name, enabled: true))
            }
        }
        if let data = FileManager.default.contents(atPath: claudeJSON),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            add(AgentLibrary.mcpServers(inJSON: obj), .claude, .user, claudeJSON)
            if let projects = obj["projects"] as? [String: Any] {
                for dir in [project, currentDirectory].compactMap({ $0 }) {
                    add(AgentLibrary.mcpServers(inJSON: projects[dir]), .claude, .local, claudeJSON)
                }
            }
        }
        if let p = project, let data = FileManager.default.contents(atPath: p + "/.mcp.json") {
            add(AgentLibrary.mcpServers(inJSON: try? JSONSerialization.jsonObject(with: data)), .claude, .project, p + "/.mcp.json")
        }
        add(AgentLibrary.codexMCPServers(read(codexConfig)), .codex, .user, codexConfig)
        return out
    }


    struct Failure: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func isManaged(_ path: String, project: String?) -> Bool {
        guard !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return false }
        return roots(project: project).contains { path.hasPrefix($0.path + "/") }
    }

    static func disabledPath(_ item: Item) -> String {
        item.root + "/" + disabledFolder + "/" + item.relative + (item.kind == .skills ? "" : disabledSuffix)
    }

    static func setEnabled(_ item: Item, _ enabled: Bool, project: String?) throws {
        guard let from = item.location, item.enabled != enabled else { return }
        let to = enabled ? item.root + "/" + item.relative : disabledPath(item)
        guard isManaged(from, project: project), isManaged(to, project: project) else {
            throw Failure("That item is outside the folders the Library looks after.")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: to) {
            throw Failure("Something is already at \(abbreviate(to)). Move it away first.")
        }
        try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.moveItem(atPath: from, toPath: to)
        let disabledRoot = item.root + "/" + disabledFolder
        var dir = (from as NSString).deletingLastPathComponent
        while enabled && dir.hasPrefix(disabledRoot) {
            guard (try? fm.contentsOfDirectory(atPath: dir))?.isEmpty == true else { break }
            try? fm.removeItem(atPath: dir)
            if dir == disabledRoot { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    @MainActor
    static func trash(_ paths: [String], project: String?) async throws {
        guard paths.allSatisfy({ isManaged($0, project: project) }) else {
            throw Failure("That item is outside the folders the Library looks after.")
        }
        _ = try await NSWorkspace.shared.recycle(paths.map { URL(fileURLWithPath: $0) })
    }

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(Transcript.home + "/") ? "~" + path.dropFirst(Transcript.home.count) : path
    }


    static func template(_ kind: Kind, name: String) -> String {
        switch kind {
        case .skills:
            return """
            ---
            name: \(name)
            description: What this skill does and when to use it. The agent reads this line to decide when to load the skill.
            ---

            # \(name)

            Instructions for the agent go here. Other files in this folder (scripts, references) can be mentioned by relative path.

            """
        case .commands:
            return """
            ---
            description: What this command does.
            argument-hint: [anything typed after the command]
            ---

            The prompt this command sends. $ARGUMENTS stands for anything typed after /\(name).

            """
        case .agents:
            return """
            ---
            name: \(name)
            description: When Claude should hand work to this agent.
            tools: Read, Grep, Glob, Bash
            ---

            You are a focused assistant for one kind of task. Describe the task, how to approach it and what to report back.

            """
        case .mcp:
            return ""
        }
    }

    static func create(_ kind: Kind, agent: Agent, scope: Scope, name: String, project: String?) throws -> String {
        guard AgentLibrary.isValidName(name) else {
            throw Failure("Use letters, digits, hyphens and underscores for the name.")
        }
        guard let root = installRoot(kind, agent: agent, scope: scope, project: project) else {
            throw Failure(scope == .project && project == nil ? "There is no project folder for the key window." : "\(agent.rawValue) has no \(kind.rawValue.lowercased()) folder.")
        }
        let fm = FileManager.default
        let target = kind == .skills ? root + "/" + name : root + "/" + name + ".md"
        let file = kind == .skills ? target + "/SKILL.md" : target
        if fm.fileExists(atPath: target) || fm.fileExists(atPath: disabledTarget(root: root, name: name, kind: kind)) {
            throw Failure("A \(kind.singular) called \(name) already exists in \(abbreviate(root)).")
        }
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try template(kind, name: name).write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    static func disabledTarget(root: String, name: String, kind: Kind) -> String {
        root + "/" + disabledFolder + "/" + name + (kind == .skills ? "" : ".md" + disabledSuffix)
    }


    nonisolated static func shell(_ command: String, in dir: String? = nil) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", command]
        var e = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT"] { e[key] = nil }
        p.environment = e
        if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data(), error.localizedDescription) }
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, outData, String(decoding: errData, as: UTF8.self))
    }

    nonisolated static func readCodexConfig() throws -> String {
        guard FileManager.default.fileExists(atPath: codexConfig) else { return "" }
        guard let data = FileManager.default.contents(atPath: codexConfig),
              let text = String(data: data, encoding: .utf8) else {
            throw Failure("Could not read \(abbreviate(codexConfig)) as text, so it was left alone.")
        }
        return text
    }

    static func backUpCodexConfig() throws {
        let backup = codexConfig + ".before-terminess"
        let fm = FileManager.default
        if fm.fileExists(atPath: codexConfig) && !fm.fileExists(atPath: backup) {
            try fm.copyItem(atPath: codexConfig, toPath: backup)
        }
    }

    nonisolated static func removeMCP(_ item: Item, project: String?) throws -> String {
        switch item.agent {
        case .claude:
            let scope = item.scope.rawValue.lowercased()
            let r = shell("claude mcp remove --scope \(scope) \(shellQuote(item.name))", in: project ?? Transcript.home)
            let text = (String(decoding: r.out, as: UTF8.self) + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            if r.status != 0 { throw Failure(text.isEmpty ? "claude mcp remove failed." : text) }
            return text
        case .codex:
            let text = try readCodexConfig()
            guard let result = AgentLibrary.removingCodexMCPServer(item.name, from: text) else {
                throw Failure("No [mcp_servers.\(item.name)] table in \(abbreviate(codexConfig)).")
            }
            try backUpCodexConfig()
            let removedLog = codexConfig + ".removed-by-terminess"
            let stamp = "# Removed by Terminess on \(Date().formatted(.iso8601))\n"
            let previous = read(removedLog)
            try (previous + (previous.isEmpty ? "" : "\n") + stamp + result.removed).write(toFile: removedLog, atomically: true, encoding: .utf8)
            try result.toml.write(toFile: codexConfig, atomically: false, encoding: .utf8)
            return "Removed [mcp_servers.\(item.name)] from \(abbreviate(codexConfig)). The table was saved to \(abbreviate(removedLog))."
        }
    }

    nonisolated static func addMCP(agent: Agent, scope: Scope, name: String, commandLine: String, project: String?) throws -> String {
        guard AgentLibrary.isValidName(name) else { throw Failure("Use letters, digits, hyphens and underscores for the name.") }
        let words = AgentLibrary.splitArgs(commandLine)
        guard let command = words.first, !command.isEmpty else { throw Failure("Enter the command that starts the server.") }
        switch agent {
        case .claude:
            if scope != .user && project == nil { throw Failure("There is no project folder for the key window.") }
            let args = words.map(shellQuote).joined(separator: " ")
            let r = shell("claude mcp add --scope \(scope.rawValue.lowercased()) \(shellQuote(name)) -- \(args)", in: project ?? Transcript.home)
            let text = (String(decoding: r.out, as: UTF8.self) + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            if r.status != 0 { throw Failure(text.isEmpty ? "claude mcp add failed." : text) }
            return text
        case .codex:
            let text = try readCodexConfig()
            if AgentLibrary.codexMCPServers(text).contains(where: { $0.name == name }) {
                throw Failure("Codex already has a server called \(name).")
            }
            try backUpCodexConfig()
            try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
            let updated = AgentLibrary.appendingCodexMCPServer(name: name, command: command, args: Array(words.dropFirst()), to: text)
            try updated.write(toFile: codexConfig, atomically: false, encoding: .utf8)
            return "Added [mcp_servers.\(name)] to \(abbreviate(codexConfig))."
        }
    }
}
