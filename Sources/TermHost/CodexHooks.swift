import Foundation

public enum CodexHooks {
    static let marker = " hook codex"

    public static var hooksPath: String {
        let env = ProcessInfo.processInfo.environment
        return (env["CODEX_HOME"] ?? ((env["HOME"] ?? NSHomeDirectory()) + "/.codex")) + "/hooks.json"
    }

    public static func command(executable: String) -> String {
        let q = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "[ -n \"$TERMINESS_SESSION\" ] && [ -x \(q) ] && \(q)\(marker); exit 0"
    }

    static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String).map { $0.contains("TERMINESS_SESSION") && $0.contains(marker) } ?? false
    }

    static func strip(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]] ?? []).compactMap { group in
            guard let list = group["hooks"] as? [[String: Any]] else { return group }
            let kept = list.filter { !isOurs($0) }
            if kept.isEmpty { return nil }
            var g = group
            g["hooks"] = kept
            return g
        }
    }

    public static func status(executable: String, path: String = hooksPath) -> ClaudeHooks.Status {
        guard let obj = ClaudeHooks.read(path), let hooks = obj["hooks"] as? [String: Any] else { return .off }
        let ours = (hooks["PermissionRequest"] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter(isOurs)
        if ours.isEmpty { return .off }
        return ours.contains { $0["command"] as? String == command(executable: executable) } ? .on : .outdated
    }

    public static func install(executable: String, path: String = hooksPath) throws {
        try ClaudeHooks.edit(path) { hooks in
            var groups = strip(hooks["PermissionRequest"])
            groups.append(["matcher": "", "hooks": [["type": "command", "command": command(executable: executable), "timeout": 600]]])
            hooks["PermissionRequest"] = groups
        }
    }

    public static func uninstall(path: String = hooksPath) throws {
        try ClaudeHooks.edit(path) { hooks in
            let groups = strip(hooks["PermissionRequest"])
            hooks["PermissionRequest"] = groups.isEmpty ? nil : groups
        }
    }
}
