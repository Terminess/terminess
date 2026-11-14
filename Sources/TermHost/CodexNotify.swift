import Foundation

public enum CodexNotify {
    public static var configPath: String {
        let env = ProcessInfo.processInfo.environment
        let dir = env["CODEX_HOME"] ?? ((env["HOME"] ?? NSHomeDirectory()) + "/.codex")
        return dir + "/config.toml"
    }

    static let comment = "# Terminess: tells it when a Codex turn finishes (only inside Terminess sessions)."

    public static func line(executable: String) -> String {
        func toml(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "notify = [\(toml(executable)), \"hook\", \"codex\"]"
    }

    public enum Status: Equatable {
        case off, on, outdated
        case taken
    }

    public enum Failure: Error, CustomStringConvertible {
        case taken(String)
        case unwritable(String)
        public var description: String {
            switch self {
            case .taken(let p): return "\(p) already sets notify to another program, and Codex allows only one. It was left alone."
            case .unwritable(let p): return "Couldn't write \(p)."
            }
        }
    }

    static func notifyLine(_ lines: [String]) -> Int? {
        for (i, raw) in lines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { return nil }
            if t.hasPrefix("notify") && t.dropFirst(6).trimmingCharacters(in: .whitespaces).hasPrefix("=") { return i }
        }
        return nil
    }

    static func isOurs(_ line: String) -> Bool { line.contains("terminessd") && line.contains("\"hook\", \"codex\"") }

    static func lines(_ path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    public static func status(executable: String, configPath: String = configPath) -> Status {
        let l = lines(configPath)
        guard let i = notifyLine(l) else { return .off }
        if !isOurs(l[i]) { return .taken }
        return l[i].trimmingCharacters(in: .whitespaces) == line(executable: executable) ? .on : .outdated
    }

    public static func install(executable: String, configPath: String = configPath) throws {
        var l = lines(configPath)
        if let i = notifyLine(l) {
            guard isOurs(l[i]) else { throw Failure.taken(configPath) }
            l[i] = line(executable: executable)
        } else {
            l.insert(contentsOf: [comment, line(executable: executable)], at: 0)
        }
        try write(l, to: configPath)
    }

    public static func uninstall(configPath: String = configPath) throws {
        var l = lines(configPath)
        guard let i = notifyLine(l), isOurs(l[i]) else { return }
        l.remove(at: i)
        if i > 0, l[i - 1] == comment { l.remove(at: i - 1) }
        try write(l, to: configPath)
    }

    static func write(_ lines: [String], to path: String) throws {
        let fm = FileManager.default
        if let original = fm.contents(atPath: path), !fm.fileExists(atPath: path + ".before-terminess") {
            try? original.write(to: URL(fileURLWithPath: path + ".before-terminess"))
        }
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard (try? Data(lines.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else {
            throw Failure.unwritable(path)
        }
    }
}
