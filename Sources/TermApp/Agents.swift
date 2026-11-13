import AppKit

struct Agent: Equatable {
    let id: String
    let name: String
    let tint: NSColor

    static func topic(fromTitle title: String, agentName: String) -> String? {
        let topic = String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
        let plain = topic.lowercased()
        guard !topic.isEmpty, plain != agentName.lowercased(), plain != "claude", plain != "codex" else { return nil }
        return topic
    }

    static let claude = Agent(id: "claude", name: "Claude Code", tint: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
    static let codex = Agent(id: "codex", name: "Codex", tint: NSColor(srgbRed: 0.36, green: 0.62, blue: 0.95, alpha: 1))
    static let local = NSColor(srgbRed: 0.38, green: 0.72, blue: 0.45, alpha: 1)
    static let other = NSColor(srgbRed: 0.62, green: 0.55, blue: 0.90, alpha: 1)

    private static let catalog: [(String, Agent)] = [
        ("claude", .claude),
        ("codex", .codex),
        ("gemini", Agent(id: "gemini", name: "Gemini", tint: other)),
        ("aider", Agent(id: "aider", name: "Aider", tint: other)),
        ("opencode", Agent(id: "opencode", name: "OpenCode", tint: other)),
        ("goose", Agent(id: "goose", name: "Goose", tint: other)),
        ("amp", Agent(id: "amp", name: "Amp", tint: other)),
        ("cursor-agent", Agent(id: "cursor", name: "Cursor Agent", tint: other)),
        ("qwen", Agent(id: "qwen", name: "Qwen Code", tint: other)),
        ("ollama", Agent(id: "ollama", name: "Ollama", tint: local)),
        ("lms", Agent(id: "lmstudio", name: "LM Studio", tint: local)),
        ("llama", Agent(id: "llama", name: "llama.cpp", tint: local)),
        ("llm", Agent(id: "llm", name: "llm", tint: local)),
        ("mlx_lm", Agent(id: "mlx", name: "MLX", tint: local)),
    ]

    static func detect(_ command: String?) -> Agent? {
        guard let c = command?.lowercased(), !c.isEmpty else { return nil }
        for (prefix, agent) in catalog where c == prefix || c.hasPrefix(prefix + "-") || c.hasPrefix(prefix + ".") {
            return agent
        }
        return nil
    }

    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "ksh", "nu", "-zsh", "-bash"]
}
