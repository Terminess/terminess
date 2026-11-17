import Foundation

public struct ReminderInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String?
    public var due: Double
    public var actionLabel: String?
    public var actionPrompt: String?
    public var sessionId: String?
    public var cwd: String?
    public var agent: String?
    public var conversation: String?
    public var created: Double
    public var fired: Bool?

    public init(id: String, title: String, body: String? = nil, due: Double, actionLabel: String? = nil,
                actionPrompt: String? = nil, sessionId: String? = nil, cwd: String? = nil,
                agent: String? = nil, conversation: String? = nil, created: Double, fired: Bool? = nil) {
        self.id = id; self.title = title; self.body = body; self.due = due; self.actionLabel = actionLabel
        self.actionPrompt = actionPrompt; self.sessionId = sessionId; self.cwd = cwd
        self.agent = agent; self.conversation = conversation; self.created = created; self.fired = fired
    }

    public var label: String { (actionLabel?.isEmpty == false) ? actionLabel! : "Proceed" }

    public var resumeCommand: [String]? {
        guard let agent, let conversation, !conversation.isEmpty else { return nil }
        switch agent {
        case "claude": return ["claude", "--resume", conversation]
        case "codex": return ["codex", "resume", conversation]
        default: return nil
        }
    }
}

public enum ReminderTime {
    public static func parse(_ text: String, now: Date = Date(), zone: TimeZone = .current) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("+") { return relative(String(s.dropFirst()), now: now) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        if let hm = hourMinute(s) {
            var c = cal.dateComponents([.year, .month, .day], from: now)
            c.hour = hm.0; c.minute = hm.1; c.second = 0
            guard let today = cal.date(from: c) else { return nil }
            return today > now ? today : cal.date(byAdding: .day, value: 1, to: today)
        }
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = opts
            if let d = iso.date(from: s) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        if let r = s.range(of: #"^(\d{4}-\d{2}-\d{2})[T ](\d{1,2}:\d{2})(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression), r.lowerBound == s.startIndex {
            let parts = s.split(whereSeparator: { $0 == "T" || $0 == " " })
            if parts.count == 2 {
                let tail = String(parts[1])
                let idx = tail.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })!
                iso.formatOptions = [.withInternetDateTime]
                return iso.date(from: "\(parts[0])T\(tail[..<idx]):00\(tail[idx...])")
            }
        }
        return nil
    }

    private static func hourMinute(_ s: String) -> (Int, Int)? {
        let p = s.split(separator: ":")
        guard p.count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0...23).contains(h), (0...59).contains(m), p[0].count <= 2 else { return nil }
        return (h, m)
    }

    private static func relative(_ s: String, now: Date) -> Date? {
        var total = 0.0, number = ""
        var sawUnit = false
        for ch in s {
            if ch.isNumber { number.append(ch); continue }
            guard let n = Double(number) else { return nil }
            switch ch {
            case "s": total += n
            case "m": total += n * 60
            case "h": total += n * 3600
            case "d": total += n * 86400
            default: return nil
            }
            number = ""; sawUnit = true
        }
        guard number.isEmpty, sawUnit, total > 0 else { return nil }
        return now.addingTimeInterval(total)
    }
}
