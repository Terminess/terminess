import Foundation
import SwiftUI
import TermTranscript

@MainActor
enum AgentTools {
    enum Agent: String, CaseIterable { case claude, codex }
    static let name = "terminess"

    private static var claudeJSON: String {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["CLAUDE_CONFIG_DIR"] { return dir + "/.claude.json" }
        return Transcript.home + "/.claude.json"
    }
    private static var codexConfig: String {
        (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? Transcript.home + "/.codex") + "/config.toml"
    }

    static func isOn(_ a: Agent) -> Bool {
        switch a {
        case .claude:
            guard let data = FileManager.default.contents(atPath: claudeJSON),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let servers = obj["mcpServers"] as? [String: Any] else { return false }
            return servers[name] != nil
        case .codex:
            let text = (try? String(contentsOfFile: codexConfig, encoding: .utf8)) ?? ""
            return text.contains("[mcp_servers.\(name)]")
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case noTerminessd, command(String)
        var description: String {
            switch self {
            case .noTerminessd: return "terminessd isn't bundled with this build."
            case .command(let s): return s
            }
        }
    }

    static func set(_ a: Agent, _ on: Bool) throws {
        guard let exe = HostService.executable else { throw Failure.noTerminessd }
        switch (a, on) {
        case (.claude, true):
            _ = try? run("claude", ["mcp", "remove", "--scope", "user", name])
            try run("claude", ["mcp", "add", "--scope", "user", name, "--", exe, "mcp"])
        case (.claude, false):
            try run("claude", ["mcp", "remove", "--scope", "user", name])
        case (.codex, true):
            try editCodex { text in
                text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n")
                    + "\n[mcp_servers.\(name)]\ncommand = \"\(exe.replacingOccurrences(of: "\"", with: "\\\""))\"\nargs = [\"mcp\"]\n"
                    + "env_vars = [\"TERMINESS_SESSION\", \"TERMINESSD_SOCKET\"]\ntool_timeout_sec = 960\n"
                    + ["borrow", "copy_from_mac", "notify", "ask_user", "remind", "open_tab"].map { "\n[mcp_servers.\(name).tools.\($0)]\napproval_mode = \"approve\"\n" }.joined()
            }
        case (.codex, false):
            try editCodex { $0 }
        }
    }

    private static func editCodex(_ add: (String) -> String) throws {
        let path = codexConfig
        let original = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var kept: [Substring] = []
        var skipping = false
        for line in original.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { skipping = t == "[mcp_servers.\(name)]" || t.hasPrefix("[mcp_servers.\(name).") }
            if !skipping { kept.append(line) }
        }
        var text = kept.joined(separator: "\n")
        while text.hasSuffix("\n\n") { text.removeLast() }
        text = add(text)
        let backup = path + ".before-terminess"
        if !original.isEmpty, !FileManager.default.fileExists(atPath: backup) { try? original.write(toFile: backup, atomically: true, encoding: .utf8) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", ([tool] + args).map(shellQuote).joined(separator: " ")]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw Failure.command(text.isEmpty ? "\(tool) failed" : text) }
        return text
    }
}

struct AgentToolsToggle: View {
    let agent: AgentTools.Agent
    @State private var on = false

    var body: some View {
        Toggle(agent == .claude ? "Give Claude Code Terminess tools (tabs, worktrees, notify, ask you)"
                                : "Give Codex Terminess tools (tabs, worktrees, notify, ask you)",
               isOn: Binding(get: { on }, set: { value in
                   do { try AgentTools.set(agent, value) } catch { AgentEvents.report(error) }
                   on = AgentTools.isOn(agent)
               }))
            .help("Adds the terminess MCP server (terminessd mcp), so the agent can open tabs and worktree tabs, notify you and ask you questions, answerable on your Mac or iPhone. It only works inside Terminess.")
            .onAppear { on = AgentTools.isOn(agent) }
    }
}
