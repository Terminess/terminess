import Foundation

public struct AgentSchedule: Codable, Equatable {
    public var id: String
    public var task: String
    public var cwd: String
    public var model: String
    public var auto: String
    public var everyMinutes: Int
    public var at: String?
    public var next: Double
    public var lastRun: Double?

    public init(id: String, task: String, cwd: String, model: String, auto: String, everyMinutes: Int, at: String?, next: Double) {
        self.id = id; self.task = task; self.cwd = cwd; self.model = model; self.auto = auto
        self.everyMinutes = everyMinutes; self.at = at; self.next = next
    }
}

public enum AgentSchedules {
    public static var path: String { HostPaths.stateDirectory + "/schedules.json" }

    public static func load() -> [AgentSchedule] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([AgentSchedule].self, from: data)) ?? []
    }

    public static func save(_ list: [AgentSchedule]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    public static func minutes(_ text: String) -> Int? {
        guard let unit = text.last, let n = Int(text.dropLast()), n > 0 else { return nil }
        switch unit {
        case "m": return n
        case "h": return n * 60
        case "d": return n * 1440
        case "w": return n * 10080
        default: return nil
        }
    }

    public static func next(after date: Date, every: Int, at: String?) -> Date {
        guard let at, every >= 1440 else { return date.addingTimeInterval(TimeInterval(every * 60)) }
        let parts = at.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return date.addingTimeInterval(TimeInterval(every * 60)) }
        let cal = Calendar.current
        var day = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date) ?? date
        if day <= date { day = cal.date(byAdding: .minute, value: every, to: day) ?? day }
        return day
    }
}
