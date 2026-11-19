import Foundation

enum AgentToolsSetup {
    static let name = "terminess"

    static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    static var claudeJSON: String {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] { return dir + "/.claude.json" }
        return home + "/.claude.json"
    }
    static var codexConfig: String {
        (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex") + "/config.toml"
    }

    static var executable: String {
        var exe = selfPath()
        #if os(Linux)
        if FileManager.default.isExecutableFile(atPath: home + "/.local/bin/terminessd") { exe = home + "/.local/bin/terminessd" }
        #endif
        return exe
    }

    static func claudeHas() -> Bool {
        guard let data = FileManager.default.contents(atPath: claudeJSON),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return false }
        return servers[name] != nil
    }

    static func codexHas() -> Bool {
        ((try? String(contentsOfFile: codexConfig, encoding: .utf8)) ?? "").contains("[mcp_servers.\(name)]")
    }

    static let approvedTools = ["borrow", "notify", "ask_user", "remind", "open_tab"]
    static var codexApprovals: String {
        approvedTools.map { "\n[mcp_servers.\(name).tools.\($0)]\napproval_mode = \"approve\"\n" }.joined()
    }

    static func codexOutdated() -> Bool {
        let text = (try? String(contentsOfFile: codexConfig, encoding: .utf8)) ?? ""
        guard let r = text.range(of: "[mcp_servers.\(name)]") else { return false }
        let rest = text[r.upperBound...]
        let table = rest.range(of: "\n[").map { rest[..<$0.lowerBound] } ?? rest
        return !table.contains("env_vars") || !text.contains("[mcp_servers.\(name).tools.notify]")
    }

    static func withoutTable(_ original: String) -> String {
        var kept: [Substring] = []
        var skipping = false
        for line in original.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { skipping = t == "[mcp_servers.\(name)]" || t.hasPrefix("[mcp_servers.\(name).") }
            if !skipping { kept.append(line) }
        }
        var text = kept.joined(separator: "\n")
        while text.hasSuffix("\n\n") { text.removeLast() }
        return text
    }

    @discardableResult
    static func shell(_ command: String) -> (status: Int32, output: String) {
        let p = Process()
        let sh = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/sh"
        p.executableURL = URL(fileURLWithPath: sh)
        p.arguments = ["-lc", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func find(_ tool: String) -> String? {
        let r = shell("command -v \(tool) 2>/dev/null")
        let found = r.output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if r.status == 0, found.hasPrefix("/") { return found }
        let dirs = [home + "/.npm-global/bin", home + "/.local/bin", home + "/.bun/bin", home + "/.volta/bin",
                    home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return dirs.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func install() -> [String] {
        var lines: [String] = []
        let exe = executable
        if let claude = find("claude") {
            if claudeHas() {
                lines.append("Claude Code: already has the Terminess tools.")
            } else {
                let dir = (claude as NSString).deletingLastPathComponent
                let r = shell("PATH=\(q(dir)):$PATH \(q(claude)) mcp add --scope user \(name) -- \(q(exe)) mcp")
                lines.append(r.status == 0 ? "Claude Code: Terminess tools added." : "Claude Code: couldn't add the tools: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } else {
            lines.append("Claude Code: not installed here, skipped.")
        }
        if find("codex") == nil {
            lines.append("Codex: not installed here, skipped.")
        } else if codexHas() && !codexOutdated() {
            lines.append("Codex: already has the Terminess tools.")
        } else {
            do {
                let path = codexConfig
                let original = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                let backup = path + ".before-terminess"
                if !original.isEmpty, !FileManager.default.fileExists(atPath: backup) {
                    try original.write(toFile: backup, atomically: true, encoding: .utf8)
                }
                let table = "\n[mcp_servers.\(name)]\ncommand = \"\(exe.replacingOccurrences(of: "\"", with: "\\\""))\"\nargs = [\"mcp\"]\n"
                    + "env_vars = [\"TERMINESS_SESSION\", \"TERMINESSD_SOCKET\"]\ntool_timeout_sec = 960\n"
                    + AgentToolsSetup.codexApprovals
                let base = withoutTable(original)
                let text = base + (base.isEmpty || base.hasSuffix("\n") ? "" : "\n") + table
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try text.write(toFile: path, atomically: true, encoding: .utf8)
                lines.append("Codex: Terminess tools added to \(path).")
            } catch {
                lines.append("Codex: couldn't add the tools: \(error)")
            }
        }
        return lines
    }
}

extension AgentToolsSetup {
    static func check() -> [String] {
        var lines: [String] = []
        func has(_ tool: String, _ helpArgs: String, _ flag: String) -> Bool {
            guard let exe = find(tool) else { return false }
            let dir = (exe as NSString).deletingLastPathComponent
            return shell("PATH=\(q(dir)):$PATH \(q(exe)) \(helpArgs) 2>&1").output.contains(flag)
        }
        if let claude = find("claude") {
            let dir = (claude as NSString).deletingLastPathComponent
            let list = shell("PATH=\(q(dir)):$PATH \(q(claude)) mcp list 2>&1").output
            let line = list.split(separator: "\n").first { $0.hasPrefix("\(name):") }.map(String.init) ?? ""
            if line.isEmpty { lines.append("problem: Claude Code doesn't list the Terminess tools (terminessd tools install adds them).") }
            else if line.contains("Connected") || line.contains("✔") { lines.append("ok: Claude Code has the Terminess tools.") }
            else { lines.append("problem: Claude Code can't start the Terminess tools: \(line)") }
            if !has("claude", "--help", "--chrome") { lines.append("problem: claude --chrome is gone, so borrowed tasks can't use Claude in Chrome.") }
        } else {
            lines.append("skip: Claude Code isn't installed here.")
        }
        if let codex = find("codex") {
            let dir = (codex as NSString).deletingLastPathComponent
            let r = shell("PATH=\(q(dir)):$PATH \(q(codex)) mcp list 2>&1")
            if r.status != 0 { lines.append("problem: Codex rejects its config (a Codex update may have changed it): \(r.output.split(separator: "\n").first ?? "")") }
            else if !r.output.contains(name) { lines.append("problem: Codex doesn't list the Terminess tools (terminessd tools install adds them).") }
            else { lines.append("ok: Codex has the Terminess tools.") }
            if !has("codex", "exec --help", "--output-last-message") { lines.append("problem: codex exec --output-last-message is gone, so borrowed Codex tasks can't return an answer.") }
        } else {
            lines.append("skip: Codex isn't installed here.")
        }
        if find("gemini") != nil {
            lines.append(has("gemini", "--help", "--yolo") ? "ok: Gemini CLI is here." : "problem: gemini --yolo is gone, so borrowed Gemini tasks would stop for approval.")
        }
        return lines
    }
}

func toolsCommand(_ args: [String]) -> Never {
    switch args.first {
    case "check":
        let lines = AgentToolsSetup.check()
        lines.forEach { print($0) }
        exit(lines.contains { $0.hasPrefix("problem:") } ? 1 : 0)
    case "install":
        AgentToolsSetup.install().forEach { print($0) }
        print("They only act inside Terminess sessions.")
    case "status", nil:
        print("Claude Code: " + (AgentToolsSetup.claudeHas() ? "on" : "off (terminessd tools install to turn on)"))
        print("Codex: " + (AgentToolsSetup.codexHas() ? "on" : "off (terminessd tools install to turn on)"))
    default:
        fail("usage: terminessd tools install|status|check")
    }
    exit(0)
}
