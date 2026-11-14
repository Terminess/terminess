import Foundation

public struct AgentToolCall {
    public let id: String
    public let name: String
    public let input: [String: Any]
    public let invalid: Bool
    public init(id: String, name: String, input: [String: Any], invalid: Bool) {
        self.id = id; self.name = name; self.input = input; self.invalid = invalid
    }
}

public struct AgentTurn {
    public var text = "", thinking = "", stopReason = "", error: String?
    public var calls: [AgentToolCall] = []
    public init() {}
}

public struct AnthropicStream {
    public init() {}
    private var buffer = ""
    private var blocks: [Int: [String: Any]] = [:]
    private var json: [Int: String] = [:]
    public private(set) var stopReason = ""
    public private(set) var error: String?

    public mutating func feed(_ data: Data) -> [(String, Bool)] {
        buffer += String(decoding: data, as: UTF8.self)
        var out: [(String, Bool)] = []
        while let r = buffer.range(of: "\n\n") {
            let event = String(buffer[..<r.lowerBound])
            buffer.removeSubrange(..<r.upperBound)
            for line in event.split(separator: "\n") where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                out += handle(obj)
            }
        }
        return out
    }

    private mutating func append(_ index: Int, _ key: String, _ piece: String) {
        var b = blocks[index] ?? [:]
        b[key] = ((b[key] as? String) ?? "") + piece
        blocks[index] = b
    }

    private mutating func handle(_ e: [String: Any]) -> [(String, Bool)] {
        let index = e["index"] as? Int ?? 0
        switch e["type"] as? String {
        case "content_block_start":
            blocks[index] = e["content_block"] as? [String: Any] ?? [:]
            if blocks[index]?["type"] as? String == "tool_use" { json[index] = "" }
        case "content_block_delta":
            let d = e["delta"] as? [String: Any] ?? [:]
            switch d["type"] as? String {
            case "text_delta":
                let t = d["text"] as? String ?? ""
                append(index, "text", t)
                return [(t, false)]
            case "thinking_delta":
                let t = d["thinking"] as? String ?? ""
                append(index, "thinking", t)
                return [(t, true)]
            case "signature_delta":
                append(index, "signature", d["signature"] as? String ?? "")
            case "input_json_delta":
                json[index, default: ""] += d["partial_json"] as? String ?? ""
            default:
                break
            }
        case "content_block_stop":
            if let raw = json[index] {
                if raw.isEmpty { blocks[index]?["input"] = [String: Any]() }
                else if let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] { blocks[index]?["input"] = input }
                else { blocks[index]?["input"] = [String: Any](); blocks[index]?["_invalid"] = true }
            }
        case "message_delta":
            if let s = (e["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = s }
        case "error":
            error = ((e["error"] as? [String: Any])?["message"] as? String) ?? "The API returned an error."
        default:
            break
        }
        return []
    }

    public var content: [[String: Any]] {
        blocks.keys.sorted().compactMap { i in
            guard var b = blocks[i] else { return nil }
            b["_invalid"] = nil
            if b["type"] as? String == "text", (b["text"] as? String ?? "").isEmpty { return nil }
            return b
        }
    }

    public func result() -> AgentTurn {
        var t = AgentTurn()
        t.stopReason = stopReason
        t.error = error
        for i in blocks.keys.sorted() {
            guard let b = blocks[i] else { continue }
            switch b["type"] as? String {
            case "text": t.text += b["text"] as? String ?? ""
            case "thinking": t.thinking += b["thinking"] as? String ?? ""
            case "tool_use":
                t.calls.append(AgentToolCall(id: b["id"] as? String ?? "", name: b["name"] as? String ?? "",
                                             input: b["input"] as? [String: Any] ?? [:], invalid: b["_invalid"] as? Bool == true))
            default: break
            }
        }
        return t
    }
}

