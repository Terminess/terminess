import Foundation
import TermTranscript

public struct AgentModel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public init(id: String, name: String, detail: String) { self.id = id; self.name = name; self.detail = detail }
}

public enum AgentModels {
    public typealias Model = AgentModel

    public static func list(for agentID: String?) -> [AgentModel] {
        switch agentID {
        case "claude": return claude
        case "codex": return codex()
        default: return []
        }
    }

    public static let claude: [AgentModel] = [
        AgentModel(id: "claude-fable-5-2", name: "Fable 5.2", detail: "For your toughest challenges"),
        AgentModel(id: "claude-opus-5-5", name: "Opus 5.5", detail: "For complex work and everyday tasks"),
        AgentModel(id: "claude-sonnet-5-5", name: "Sonnet 5.5", detail: "Most efficient for simpler tasks"),
        AgentModel(id: "claude-haiku-5-5", name: "Haiku 5.5", detail: "Fastest for quick answers"),
    ]

    public static func codex() -> [AgentModel] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? Transcript.home + "/.codex"
        guard let data = FileManager.default.contents(atPath: home + "/models_cache.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
            .compactMap { m in
                guard let slug = m["slug"] as? String else { return nil }
                return AgentModel(id: slug, name: m["display_name"] as? String ?? slug, detail: m["description"] as? String ?? "")
            }
    }

    public static func current(onScreen text: String, agentID: String?) -> String? {
        current(onScreen: text, models: list(for: agentID))
    }

    public static func current(onScreen text: String, models: [AgentModel]) -> String? {
        var best: (line: Int, name: String)?
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lower = line.lowercased()
            for m in models where lower.contains(m.name.lowercased()) || lower.contains(m.id.lowercased()) {
                if best == nil || i >= best!.line { best = (i, m.name) }
            }
        }
        return best?.name
    }

    static func flat(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }

    static func pickerRows(_ picker: String, wanted name: String) -> (cursor: Int, target: Int)? {
        var cursor: Int?, target: Int?
        for line in picker.split(separator: "\n") {
            var t = line.trimmingCharacters(in: .whitespaces)
            let isCursor = t.hasPrefix("❯")
            if isCursor { t = t.dropFirst().trimmingCharacters(in: .whitespaces) }
            guard let dot = t.firstIndex(of: "."), let n = Int(t[..<dot]) else { continue }
            let rest = t[t.index(after: dot)...]
            guard rest.first == " " else { continue }
            if isCursor { cursor = n }
            if rest.trimmingCharacters(in: .whitespaces).hasPrefix(name) { target = n }
        }
        guard let cursor, let target else { return nil }
        return (cursor, target)
    }

    @MainActor
    public static func switchModel(_ model: AgentModel, agentID: String,
                                   screen: @MainActor () -> String,
                                   send: @MainActor ([UInt8]) -> Void) async -> Bool {
        func waitFor(_ check: (String) -> Bool, seconds: Double = 4) async -> String? {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                let s = screen()
                if check(flat(s)) { return s }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return nil
        }

        switch agentID {
        case "claude":
            send(Array("/model".utf8))
            try? await Task.sleep(nanoseconds: 150_000_000)
            send([0x0D])
            guard let picker = await waitFor({ $0.contains("Select model") }) else { return false }
            guard let rows = pickerRows(picker, wanted: model.name) else { send([0x1B]); return false }
            let arrow: [UInt8] = rows.target > rows.cursor ? [0x1B, 0x5B, 0x42] : [0x1B, 0x5B, 0x41]
            for _ in 0..<abs(rows.target - rows.cursor) {
                send(arrow)
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            send(Array("s".utf8))
            return await waitFor({ $0.contains("for this session only") && !$0.contains("Select model") }) != nil
        case "codex":
            send(Array("/model \(model.id)".utf8))
            try? await Task.sleep(nanoseconds: 150_000_000)
            send([0x0D])
            return await waitFor({ $0.contains("Model changed to") }) != nil
        default:
            return false
        }
    }
}
