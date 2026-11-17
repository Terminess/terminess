import Foundation
import TermHost

public final class CommitCounter: @unchecked Sendable {
    public typealias Git = (_ folder: String, _ arguments: [String]) -> String?

    private let git: Git
    private let lock = NSLock()
    private var cache: [String: (head: String, counts: [Int: Int])] = [:]
    private var refreshing = false
    private let work = DispatchQueue(label: "terminess.commits", qos: .utility)

    public init(git: @escaping Git = CommitCounter.runGit) { self.git = git }

    public func cached(folder: String, since time: Double) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return cache[folder]?.counts[Int(time)]
    }

    @discardableResult
    public func count(folder: String, since time: Double) -> Int? {
        guard let head = git(folder, ["rev-parse", "HEAD"]), !head.isEmpty else { return nil }
        lock.lock()
        if cache[folder]?.head != head { cache[folder] = (head, [:]) }
        if let n = cache[folder]?.counts[Int(time)] { lock.unlock(); return n }
        lock.unlock()
        guard let n = git(folder, ProjectGrouping.commitsSinceArguments(time)).flatMap(ProjectGrouping.commitCount) else { return nil }
        lock.lock(); cache[folder]?.counts[Int(time)] = n; lock.unlock()
        return n
    }

    public func annotate(_ items: [HistoryItem]) -> [HistoryItem] {
        let marked = Self.markNewest(items)
        var wanted: [(String, Double)] = []
        let out = marked.map { item -> HistoryItem in
            var i = item
            if i.newest == false {
                i.commitsSince = cached(folder: i.cwd, since: i.used)
                wanted.append((i.cwd, i.used))
            }
            return i
        }
        refresh(wanted)
        return out
    }

    public func settle() { work.sync {} }

    private func refresh(_ wanted: [(String, Double)]) {
        guard !wanted.isEmpty else { return }
        lock.lock()
        if refreshing { lock.unlock(); return }
        refreshing = true
        lock.unlock()
        work.async { [self] in
            for (folder, time) in wanted { count(folder: folder, since: time) }
            lock.lock(); refreshing = false; lock.unlock()
        }
    }

    public static func markNewest(_ items: [HistoryItem]) -> [HistoryItem] {
        var best: [String: (id: String, used: Double)] = [:]
        for i in items where (best[i.cwd]?.used ?? -.infinity) < i.used { best[i.cwd] = (i.id, i.used) }
        return items.map { var i = $0; i.newest = best[i.cwd]?.id == i.id; return i }
    }

    public static func notice(for item: HistoryItem, commits: Int?) -> String? {
        guard item.newest == false else { return nil }
        if let n = commits, n > 0 {
            return "Older conversation: \(n) commit\(n == 1 ? " has" : "s have") landed since. Check the repo state before carrying on."
        }
        return "Older conversation: a newer one exists in this folder. Check the repo state before carrying on."
    }

    public static func runGit(_ folder: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", folder] + arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
