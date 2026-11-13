import Foundation

struct TranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        case tool(name: String, summary: String, detail: String, result: String?)
        case thinking(String)
    }
    let id: Int
    var kind: Kind
}

enum Transcript {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func locate(agent: String, directory: String, started: Date, arguments: [String]) -> String? {
        let fm = FileManager.default
        func created(_ p: String) -> Date? { (try? fm.attributesOfItem(atPath: p))?[.creationDate] as? Date }
        var named: String?
        for (i, a) in arguments.enumerated() where i + 1 < arguments.count {
            if a == "--resume" || a == "-r" || (agent == "codex" && a == "resume") { named = arguments[i + 1] }
        }
        if let named, !named.hasPrefix("-") {
            if agent == "claude" {
                let munged = String(directory.map { $0.isLetter || $0.isNumber ? $0 : "-" })
                let p = home + "/.claude/projects/" + munged + "/" + named + ".jsonl"
                if fm.fileExists(atPath: p) { return p }
            } else if let p = codexFiles(directory: directory, days: 60).first(where: { $0.contains(named) }) {
                return p
            }
        }
        let candidates: [String]
        if agent == "claude" {
            let munged = String(directory.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            let dir = home + "/.claude/projects/" + munged
            candidates = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }.map { dir + "/" + $0 }
        } else {
            candidates = codexFiles(directory: directory, days: 2)
        }
        let after = candidates.compactMap { p -> (String, Date)? in
            guard let c = created(p), c >= started.addingTimeInterval(-3) else { return nil }
            return (p, c)
        }
        if let first = after.min(by: { $0.1 < $1.1 }) { return first.0 }
        if arguments.contains("--continue") || arguments.contains("-c") {
            return candidates.max { (mtime($0) ?? .distantPast) < (mtime($1) ?? .distantPast) }
        }
        return nil
    }

    private static func codexFiles(directory: String, days: Int) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let cal = Calendar.current
        for back in 0..<days {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "%@/.codex/sessions/%04d/%02d/%02d", home, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                let path = dir + "/" + f
                if codexDirectory(path) == directory { out.append(path) }
            }
        }
        return out
    }

    static func locate(agent: String, directory: String) -> String? {
        let fm = FileManager.default
        func newest(_ paths: [String]) -> String? {
            paths.max { (mtime($0) ?? .distantPast) < (mtime($1) ?? .distantPast) }
        }
        if agent == "claude" {
            let munged = String(directory.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            let dir = home + "/.claude/projects/" + munged
            let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }.map { dir + "/" + $0 }
            return newest(files)
        }
        if agent == "codex" {
            var candidates: [String] = []
            let cal = Calendar.current
            for back in 0..<4 {
                guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
                let c = cal.dateComponents([.year, .month, .day], from: day)
                let dir = String(format: "%@/.codex/sessions/%04d/%02d/%02d", home, c.year ?? 0, c.month ?? 0, c.day ?? 0)
                for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                    let path = dir + "/" + f
                    if codexDirectory(path) == directory { candidates.append(path) }
                }
            }
            return newest(candidates)
        }
        return nil
    }

    static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func codexDirectory(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let data = h.readData(ofLength: 64 * 1024)
        guard let line = data.split(separator: UInt8(ascii: "\n")).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        guard let source = payload["source"] as? String, source == "cli" || source == "vscode" else { return nil }
        return payload["cwd"] as? String
    }


    static func parse(_ path: String, agent: String) -> [TranscriptItem] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        var items: [TranscriptItem] = []
        var toolIndex: [String: Int] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if agent == "claude" { parseClaude(obj, items: &items, toolIndex: &toolIndex) }
            else { parseCodex(obj, items: &items, toolIndex: &toolIndex) }
        }
        return items
    }

    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { ($0["type"] as? String) == "text" || ($0["type"] as? String) == "output_text" || ($0["type"] as? String) == "input_text"
                ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }

    private static func isNoise(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("<") || t.hasPrefix("Caveat:") || t.hasPrefix("[Request interrupted")
            || t.hasPrefix("# AGENTS.md")
    }

    private static func toolSummary(_ name: String, _ input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty {
                let short = v.split(separator: "\n").first.map(String.init) ?? v
                return short.count > 120 ? String(short.prefix(119)) + "…" : short
            }
        }
        return ""
    }

    private static func pretty(_ value: Any) -> String {
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "\(value)" }
        return String(decoding: d, as: UTF8.self)
    }

    private static func parseClaude(_ obj: [String: Any], items: inout [TranscriptItem], toolIndex: inout [String: Int]) {
        func add(_ k: TranscriptItem.Kind) { items.append(TranscriptItem(id: items.count, kind: k)) }
        guard let type = obj["type"] as? String, obj["isMeta"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return }
        if type == "user" {
            if let s = message["content"] as? String {
                if !isNoise(s) { add(.user(s)) }
                return
            }
            for part in message["content"] as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "text":
                    if let s = part["text"] as? String, !isNoise(s) { add(.user(s)) }
                case "tool_result":
                    if let id = part["tool_use_id"] as? String, let i = toolIndex[id],
                       case .tool(let n, let sum, let det, _) = items[i].kind {
                        var result = text(part["content"])
                        if result.count > 4_000 { result = String(result.prefix(4_000)) + "\n…" }
                        items[i].kind = .tool(name: n, summary: sum, detail: det, result: result)
                    }
                default: break
                }
            }
        } else if type == "assistant" {
            for part in message["content"] as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "text":
                    if let s = part["text"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.assistant(s)) }
                case "thinking":
                    if let s = part["thinking"] as? String, !s.isEmpty { add(.thinking(s)) }
                case "tool_use":
                    let name = part["name"] as? String ?? "tool"
                    let input = part["input"] as? [String: Any] ?? [:]
                    add(.tool(name: name, summary: toolSummary(name, input), detail: pretty(input), result: nil))
                    if let id = part["id"] as? String { toolIndex[id] = items.count - 1 }
                default: break
                }
            }
        }
    }

    private static func parseCodex(_ obj: [String: Any], items: inout [TranscriptItem], toolIndex: inout [String: Int]) {
        func add(_ k: TranscriptItem.Kind) { items.append(TranscriptItem(id: items.count, kind: k)) }
        guard let type = obj["type"] as? String, let p = obj["payload"] as? [String: Any] else { return }
        let ptype = p["type"] as? String
        if type == "event_msg" && ptype == "user_message", let s = p["message"] as? String, !isNoise(s) {
            add(.user(s))
        } else if type == "event_msg" && ptype == "agent_message", let s = p["message"] as? String, !s.isEmpty {
            add(.assistant(s))
        } else if type == "response_item" && (ptype == "function_call" || ptype == "custom_tool_call") {
            let name = p["name"] as? String ?? "tool"
            let rawArgs = (p["arguments"] as? String) ?? (p["input"] as? String) ?? ""
            let args = (try? JSONSerialization.jsonObject(with: Data(rawArgs.utf8))) as? [String: Any] ?? [:]
            var summary = toolSummary(name, args)
            if summary.isEmpty, let cmd = args["cmd"] as? [String] { summary = cmd.joined(separator: " ") }
            if summary.isEmpty { summary = String(rawArgs.prefix(120)) }
            add(.tool(name: name, summary: summary, detail: args.isEmpty ? rawArgs : pretty(args), result: nil))
            if let id = p["call_id"] as? String { toolIndex[id] = items.count - 1 }
        } else if type == "response_item" && (ptype == "function_call_output" || ptype == "custom_tool_call_output"),
                  let id = p["call_id"] as? String, let i = toolIndex[id],
                  case .tool(let n, let sum, let det, _) = items[i].kind {
            var result = (p["output"] as? String) ?? text(p["output"])
            if result.count > 4_000 { result = String(result.prefix(4_000)) + "\n…" }
            items[i].kind = .tool(name: n, summary: sum, detail: det, result: result)
        }
    }
}
