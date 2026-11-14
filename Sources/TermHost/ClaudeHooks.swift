import Foundation

public enum ClaudeHooks {
    public static let events = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Notification", "SessionEnd"]
    static let marker = " hook claude"

    public static var settingsPath: String {
        (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.claude/settings.json"
    }

    public static func command(executable: String) -> String {
        let q = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "[ -n \"$TERMINESS_SESSION\" ] && [ -x \(q) ] && \(q)\(marker); exit 0"
    }

    static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String).map { $0.contains("TERMINESS_SESSION") && $0.contains(marker) } ?? false
    }

    public enum Status: Equatable {
        case off
        case on
        case outdated
    }

    public static func status(executable: String, settingsPath: String = settingsPath) -> Status {
        guard let obj = read(settingsPath), let hooks = obj["hooks"] as? [String: Any] else { return .off }
        var found = 0, current = 0
        for event in events {
            let ours = (hooks[event] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter(isOurs)
            if !ours.isEmpty { found += 1 }
            if ours.contains(where: { $0["command"] as? String == command(executable: executable) }) { current += 1 }
        }
        return found == 0 ? .off : current == events.count ? .on : .outdated
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case unwritable(String)
        public var description: String {
            switch self {
            case .unreadable(let p): return "\(p) isn't valid JSON, so it was left alone. Fix it and try again."
            case .unwritable(let p): return "Couldn't write \(p)."
            }
        }
    }

    public static func install(executable: String, settingsPath: String = settingsPath) throws {
        try edit(settingsPath) { hooks in
            for event in events {
                var groups = strip(hooks[event])
                groups.append(["hooks": [["type": "command", "command": command(executable: executable), "timeout": 5]]])
                hooks[event] = groups
            }
        }
    }

    public static func uninstall(settingsPath: String = settingsPath) throws {
        try edit(settingsPath) { hooks in
            for event in events {
                let groups = strip(hooks[event])
                hooks[event] = groups.isEmpty ? nil : groups
            }
        }
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

    static func read(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func edit(_ path: String, _ change: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        var obj: [String: Any] = [:]
        if let data = fm.contents(atPath: path), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw Failure.unreadable(path)
            }
            obj = parsed
            let backup = path + ".before-terminess"
            if !fm.fileExists(atPath: backup) { try? data.write(to: URL(fileURLWithPath: backup)) }
        }
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        change(&hooks)
        obj["hooks"] = hooks.isEmpty ? nil : hooks
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? out.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else {
            throw Failure.unwritable(path)
        }
    }
}
