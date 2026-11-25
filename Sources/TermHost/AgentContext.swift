import Foundation

public struct AgentContext {
    public var window: Int
    public var reply: Int
    public var compactAt: Int
    public static let defaultCompactAt = 64_000
    public private(set) var bytesPerToken = 3.2

    public init(window: Int, reply: Int, compactAt: Int = AgentContext.defaultCompactAt) {
        self.window = window
        self.reply = reply
        self.compactAt = compactAt
    }

    public var limit: Int {
        let fromWindow = window > 0 ? max(1000, window * 85 / 100 - reply) : Int.max
        let fromSetting = compactAt > 0 ? compactAt : Int.max
        return min(fromWindow, fromSetting)
    }

    public static func size(_ value: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: value))?.count ?? 0
    }

    public mutating func learn(bytes: Int, promptTokens: Int) {
        guard bytes > 0, promptTokens > 50 else { return }
        bytesPerToken = min(8, max(1.5, Double(bytes) / Double(promptTokens)))
    }

    public func tokens(bytes: Int) -> Int { Int(Double(bytes) / bytesPerToken) }

    public func needsCompacting(bytes: Int) -> Bool {
        limit != Int.max && tokens(bytes: bytes) > limit
    }

    public func cut(_ messages: [[String: Any]]) -> Range<Int>? {
        guard messages.count > 3 else { return nil }
        let budget = limit == Int.max ? Int.max : Int(Double(limit / 3) * bytesPerToken)
        var kept = 0
        var end = messages.count
        var best: Int?
        var i = messages.count - 1
        while i >= 2 {
            kept += Self.size(messages[i])
            if kept > budget { break }
            if (messages[i]["role"] as? String) != "tool" { best = i }
            i -= 1
        }
        if best == nil {
            best = (2..<messages.count).last { (messages[$0]["role"] as? String) != "tool" }
        }
        guard let b = best else { return nil }
        end = b
        return end > 1 ? 1..<end : nil
    }

    public var requestBudget: Int {
        limit == Int.max ? Int.max : Int(Double(limit) * bytesPerToken)
    }

    public static func shrinkToolResults(_ messages: inout [[String: Any]], by over: Int) {
        var left = over
        let order = messages.indices.filter { (messages[$0]["role"] as? String) == "tool" }
            .sorted { (messages[$0]["content"] as? String ?? "").utf8.count > (messages[$1]["content"] as? String ?? "").utf8.count }
        for i in order where left > 0 {
            let text = messages[i]["content"] as? String ?? ""
            let bytes = text.utf8.count
            guard bytes > 600 else { continue }
            let keep = max(400, bytes - left - 120)
            let head = String(decoding: Array(text.utf8.prefix(keep * 2 / 3)), as: UTF8.self)
            let tail = String(decoding: Array(text.utf8.suffix(keep / 3)), as: UTF8.self)
            let short = head + "\n…(\(bytes - keep) bytes left out to fit the context window)…\n" + tail
            left -= bytes - short.utf8.count
            messages[i]["content"] = short
        }
    }

    public static func transcript(_ messages: ArraySlice<[String: Any]>, limit: Int) -> String {
        var parts: [String] = []
        for m in messages {
            let role = m["role"] as? String ?? "?"
            var text = m["content"] as? String ?? ""
            if let calls = m["tool_calls"] as? [[String: Any]] {
                for c in calls {
                    let f = c["function"] as? [String: Any] ?? [:]
                    text += "\n[called \(f["name"] as? String ?? "?") \(f["arguments"] as? String ?? "")]"
                }
            }
            if text.count > 4000 { text = String(text.prefix(2000)) + "\n…\n" + String(text.suffix(1500)) }
            parts.append("\(role.uppercased()): \(text)")
        }
        let all = parts.joined(separator: "\n\n")
        guard all.utf8.count > limit else { return all }
        return "…" + String(decoding: Array(all.utf8.suffix(max(0, limit))), as: UTF8.self)
    }
}
