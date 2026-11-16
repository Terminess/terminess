import Foundation

public struct ModelRoles: Codable, Equatable, Sendable {
    public var claude: [String: String]
    public var codex: [String: String]

    public init(claude: [String: String] = [:], codex: [String: String] = [:]) {
        self.claude = claude; self.codex = codex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = (try? c.decode([String: String].self, forKey: .claude)) ?? [:]
        codex = (try? c.decode([String: String].self, forKey: .codex)) ?? [:]
    }

    public static var path: String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["PAIR_MODELS"], !p.isEmpty { return p }
        let config = env["XDG_CONFIG_HOME"] ?? (env["HOME"] ?? NSHomeDirectory()) + "/.config"
        return config + "/pair/models.json"
    }

    public static func load(from path: String = ModelRoles.path) -> ModelRoles {
        guard let data = FileManager.default.contents(atPath: path),
              let roles = try? JSONDecoder().decode(ModelRoles.self, from: data) else { return ModelRoles() }
        return roles
    }

    public func save(to path: String = ModelRoles.path) throws {
        var clean = self
        clean.claude = claude.filter { !$0.value.isEmpty }
        clean.codex = codex.filter { !$0.value.isEmpty }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (try encoder.encode(clean) + Data("\n".utf8)).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static let roles: [String: [String]] = [
        "claude": ["main", "subagents", "review", "work", "ask"],
        "codex": ["review", "work", "ask"],
    ]

    public func model(_ agent: String, _ role: String) -> String {
        (agent == "claude" ? claude : codex)[role] ?? ""
    }

    public mutating func set(_ agent: String, _ role: String, _ model: String) {
        if agent == "claude" { claude[role] = model.isEmpty ? nil : model }
        else { codex[role] = model.isEmpty ? nil : model }
    }

    public func environment() -> [String: String] {
        var env: [String: String] = [:]
        if let m = claude["main"], !m.isEmpty { env["ANTHROPIC_MODEL"] = m }
        if let m = claude["subagents"], !m.isEmpty { env["CLAUDE_CODE_SUBAGENT_MODEL"] = m }
        return env
    }
}
