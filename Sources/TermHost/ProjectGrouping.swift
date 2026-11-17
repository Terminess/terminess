import Foundation

public enum ProjectGrouping {
    public static let historyLimit = 3

    public static func repoRoot(of path: String, home: String, isRepo: (String) -> Bool) -> String? {
        var p = trimmed(path)
        let h = trimmed(home)
        guard p.hasPrefix("/") else { return nil }
        let underHome = p.hasPrefix(h + "/")
        while p != "/" && !p.isEmpty {
            if underHome && (p == h || !p.hasPrefix(h + "/")) { return nil }
            if isRepo(p) { return p }
            p = parent(p)
        }
        return nil
    }

    public static func belowRemoteHome(_ path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "home" || parts[0] == "Users" { return Array(parts.dropFirst(2)) }
        if parts.first == "root" { return Array(parts.dropFirst()) }
        return parts
    }

    public static func remoteProject(cwd: String, localNames: Set<String>, remoteProjects: [String]) -> String? {
        let below = belowRemoteHome(cwd)
        guard !below.isEmpty else { return nil }
        for name in below.reversed() where localNames.contains(name) { return name }
        let c = trimmed(cwd)
        let candidates = remoteProjects.map(trimmed).filter { p in
            !belowRemoteHome(p).isEmpty && !remoteProjects.contains { q in trimmed(q).hasPrefix(p + "/") }
        }
        let best = candidates.filter { c == $0 || c.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        return best.flatMap { $0.split(separator: "/").last.map(String.init) }
    }

    public static func pathProject(cwd: String, knownFolders: [String]) -> String? {
        let below = belowRemoteHome(cwd)
        if let i = below.firstIndex(of: "github") {
            return i + 1 < below.count ? below[i + 1] : nil
        }
        return remoteProject(cwd: cwd, localNames: [], remoteProjects: knownFolders)
    }

    public static func limited<T>(_ items: [T], expanded: Bool, limit: Int = historyLimit) -> (visible: [T], more: Int) {
        let more = max(0, items.count - limit)
        return (expanded ? items : Array(items.prefix(limit)), more)
    }

    public static func commitCount(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func commitsSinceArguments(_ time: Double) -> [String] {
        ["rev-list", "--count", "--since=@\(Int(time))", "HEAD"]
    }

    private static func trimmed(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func parent(_ p: String) -> String {
        guard let i = p.lastIndex(of: "/") else { return "" }
        return i == p.startIndex ? "/" : String(p[..<i])
    }
}
