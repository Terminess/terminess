import SwiftUI
import TermHost

enum SessionText {
    static func isAgent(_ s: SessionInfo) -> Bool { ["claude", "codex", "ollama", "harness"].contains(s.command) }

    static func agentName(_ command: String) -> String? {
        if command.hasPrefix("ollama:") { return String(command.dropFirst(7)) }
        if command == "ollama" { return "Local model" }
        if command == "harness" { return "Terminess Agent" }
        return command == "claude" ? "Claude Code" : (command == "codex" ? "Codex" : nil)
    }

    static func topic(_ title: String?) -> String {
        String((title ?? "").drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }

    static func givenName(_ s: SessionInfo) -> String? {
        let n = s.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n.allSatisfy(\.isNumber) ? nil : n
    }

    static func title(_ s: SessionInfo) -> String {
        if let n = givenName(s) { return n }
        let t = topic(s.title)
        if let agent = agentName(s.command) { return t.isEmpty || t.lowercased() == agent.lowercased() ? agent : t }
        if ["zsh", "bash", "fish", "sh"].contains(s.command) { return "Shell" }
        return t.isEmpty ? s.command : t
    }

    static func state(_ s: SessionInfo) -> String? {
        if s.busy == true { return "working" }
        if s.attention == true { return "needs you" }
        return s.active.map(relative)
    }

    static func folderName(_ path: String) -> String {
        guard !path.isEmpty else { return "Home" }
        let parts = path.split(separator: "/")
        if parts.count == 2, parts[0] == "home" || parts[0] == "Users" { return "Home" }
        return parts.last.map(String.init) ?? path
    }

    static func relative(_ t: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }
}
