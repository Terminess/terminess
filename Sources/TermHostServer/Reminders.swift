import Foundation
import TermHost

public final class ReminderStore {
    public let path: String
    public private(set) var items: [ReminderInfo] = []

    public init(path: String = HostPaths.stateDirectory + "/reminders.json") {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let saved = try? JSONDecoder().decode([ReminderInfo].self, from: data) { items = saved }
    }

    @discardableResult
    public func add(_ r: ReminderInfo, now: Date = Date()) -> ReminderInfo {
        var r = r
        r.id = String(UUID().uuidString.prefix(8)).lowercased()
        r.created = now.timeIntervalSince1970
        r.fired = nil
        r.title = String(r.title.prefix(200))
        r.body = r.body.map { String($0.prefix(1000)) }
        r.actionLabel = r.actionLabel.map { String($0.prefix(30)) }
        r.actionPrompt = r.actionPrompt.map { String($0.prefix(4000)) }
        items.append(r)
        items.sort { $0.due < $1.due }
        save()
        return r
    }

    public func reminder(_ id: String) -> ReminderInfo? { items.first { $0.id == id } }

    @discardableResult
    public func remove(_ id: String) -> ReminderInfo? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let r = items.remove(at: i)
        save()
        return r
    }

    public func fireDue(now: Date = Date()) -> [ReminderInfo] {
        var fired: [ReminderInfo] = []
        for i in items.indices where items[i].fired != true && items[i].due <= now.timeIntervalSince1970 {
            items[i].fired = true
            fired.append(items[i])
        }
        if !fired.isEmpty { save() }
        return fired
    }

    public var pending: [ReminderInfo] { items.filter { $0.fired == true } }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    public static func claudeConversation(pid: Int32, home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) -> String? {
        guard pid > 0, let data = FileManager.default.contents(atPath: "\(home)/.claude/sessions/\(pid).json"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["sessionId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    public static func resumeShellCommand(_ r: ReminderInfo) -> String? {
        guard var argv = r.resumeCommand else { return nil }
        if let p = r.actionPrompt, !p.isEmpty { argv.append(p) }
        return argv.map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
