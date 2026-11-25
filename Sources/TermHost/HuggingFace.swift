import Foundation

public enum HuggingFace {
    public static let prefix = "hf:"
    public static let chatURL = "https://router.huggingface.co/v1/chat/completions"
    public static let tokenPage = "https://huggingface.co/settings/tokens"

    public static let defaultModels = [
        "moonshotai/Kimi-K3",
        "zai-org/GLM-5.3",
        "deepseek-ai/DeepSeek-V4-Pro",
        "Qwen/Qwen3.8-2.4T-A95B",
        "MiniMaxAI/MiniMax-M3",
        "openai/gpt-oss-120b",
    ]

    static var configDirectory: String {
        (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.config/terminess"
    }
    public static var tokenPath: String { configDirectory + "/hf_token" }
    public static var modelsPath: String { configDirectory + "/hf_models" }
    static var statusPath: String { configDirectory + "/hf_status" }
    public static let billingPage = "https://huggingface.co/settings/billing"

    public static func modelID(_ name: String) -> String? {
        name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : nil
    }

    public static func token() -> String? {
        if let t = ProcessInfo.processInfo.environment["HF_TOKEN"], !t.isEmpty { return t }
        let t = (try? String(contentsOfFile: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    public static func models() -> [String] {
        guard let text = try? String(contentsOfFile: modelsPath, encoding: .utf8) else { return defaultModels }
        return parseModels(text)
    }

    public static func parseModels(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "\n" || $0 == "," }).compactMap { raw in
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
            guard !s.isEmpty, !s.hasPrefix("#"), seen.insert(s).inserted else { return nil }
            return s
        }
    }

    public static func savePrivate(_ text: String, to path: String) throws {
        let fm = FileManager.default
        if text.isEmpty { try? fm.removeItem(atPath: path); return }
        try fm.createDirectory(atPath: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(atPath: path)
        guard fm.createFile(atPath: path, contents: Data((text + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public enum Notice: String, Sendable {
        case noToken = "no-token", badToken = "bad-token", noCredit = "no-credit"

        public var message: String {
            switch self {
            case .noToken: return "No Hugging Face token yet. Add one in Settings, Agents."
            case .badToken: return "Hugging Face didn't accept the token. Make a new one and save it in Settings."
            case .noCredit: return "No Hugging Face credit left. Add some at huggingface.co/settings/billing."
            }
        }
        public var url: String? { self == .noCredit ? HuggingFace.billingPage : self == .badToken ? HuggingFace.tokenPage : nil }
    }

    public static func notice() -> Notice? {
        guard token() != nil else { return .noToken }
        let s = (try? String(contentsOfFile: statusPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Notice(rawValue: s).flatMap { $0 == .noToken ? nil : $0 }
    }

    public static func record(status: Int) {
        let fm = FileManager.default
        switch status {
        case 200: if fm.fileExists(atPath: statusPath) { try? fm.removeItem(atPath: statusPath) }
        case 401: try? savePrivate(Notice.badToken.rawValue, to: statusPath)
        case 402: try? savePrivate(Notice.noCredit.rawValue, to: statusPath)
        default: break
        }
    }

    public static func clearNotice() { try? FileManager.default.removeItem(atPath: statusPath) }

    public static func errorMessage(status: Int, body: Data) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (obj?["error"] as? [String: Any])?["message"] as? String ?? obj?["error"] as? String
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401: return "HTTP 401: Hugging Face didn't accept the token. Make one at \(tokenPage) with \"Make calls to Inference Providers\" ticked."
        case 402: return "HTTP 402: no inference credit left on your Hugging Face account. Add credit or upgrade to PRO at huggingface.co/settings/billing. (\(message))"
        default: return "HTTP \(status): \(message)"
        }
    }
}

public struct OpenAIStream {
    public init() {}
    private var buffer = Data()
    public private(set) var text = "", reasoning = "", finishReason = ""
    public private(set) var error: String?
    public private(set) var complete = false
    public private(set) var promptTokens = 0, completionTokens = 0
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]

    public mutating func feed(_ data: Data) -> [(String, Bool)] {
        buffer.append(data)
        var out: [(String, Bool)] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.hasSuffix("\r") { line.removeLast() }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { complete = true; continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            out += handle(obj)
        }
        return out
    }

    private mutating func handle(_ obj: [String: Any]) -> [(String, Bool)] {
        if let e = obj["error"] {
            error = (e as? [String: Any])?["message"] as? String ?? e as? String ?? "The provider returned an error."
            return []
        }
        if let u = obj["usage"] as? [String: Any] {
            promptTokens = u["prompt_tokens"] as? Int ?? promptTokens
            completionTokens = u["completion_tokens"] as? Int ?? completionTokens
        }
        var out: [(String, Bool)] = []
        for choice in obj["choices"] as? [[String: Any]] ?? [] {
            if let f = choice["finish_reason"] as? String { finishReason = f; complete = true }
            let d = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
            if let r = (d["reasoning_content"] ?? d["reasoning"]) as? String, !r.isEmpty { reasoning += r; out.append((r, true)) }
            if let c = d["content"] as? String, !c.isEmpty { text += c; out.append((c, false)) }
            for (n, call) in (d["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let i = call["index"] as? Int ?? n
                let f = call["function"] as? [String: Any] ?? [:]
                var c = calls[i] ?? (id: "", name: "", arguments: "")
                if let id = call["id"] as? String, !id.isEmpty { c.id = id }
                if let name = f["name"] as? String, !name.isEmpty { c.name = name }
                if let a = f["arguments"] as? String { c.arguments += a }
                else if let a = f["arguments"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: a) {
                    c.arguments = String(decoding: data, as: UTF8.self)
                }
                calls[i] = c
            }
        }
        return out
    }

    private var orderedCalls: [(id: String, name: String, arguments: String)] {
        calls.keys.sorted().enumerated().map { n, k in
            var c = calls[k]!
            if c.id.isEmpty { c.id = "call_\(n + 1)" }
            return c
        }
    }

    public func assistantMessage(withReasoning: Bool = false) -> [String: Any] {
        let cs = orderedCalls
        var m: [String: Any] = ["role": "assistant", "content": text.isEmpty && !cs.isEmpty ? NSNull() : text]
        if withReasoning, !cs.isEmpty, !reasoning.isEmpty { m["reasoning_content"] = reasoning }
        if !cs.isEmpty {
            m["tool_calls"] = cs.map { ["id": $0.id, "type": "function",
                                        "function": ["name": $0.name, "arguments": $0.arguments.isEmpty ? "{}" : $0.arguments]] as [String: Any] }
        }
        return m
    }

    public func result() -> AgentTurn {
        var t = AgentTurn()
        t.text = text
        t.thinking = reasoning
        t.error = error
        if error == nil && !complete {
            t.error = "The reply was cut off before it finished."
            return t
        }
        for c in orderedCalls {
            let raw = c.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            let input = raw.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            t.calls.append(AgentToolCall(id: c.id, name: c.name, input: input ?? [:], invalid: input == nil))
        }
        switch finishReason {
        case "length": t.stopReason = "max_tokens"
        case "content_filter": t.stopReason = "refusal"
        default: t.stopReason = t.calls.isEmpty ? "end_turn" : "tool_use"
        }
        return t
    }
}
