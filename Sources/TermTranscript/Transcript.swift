import Foundation

public struct TranscriptItem: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: Equatable, Codable, Sendable {
        case user(String)
        case assistant(String)
        case tool(name: String, summary: String, detail: String, result: String?)
        case thinking(String)
    }
    public let id: Int
    public var kind: Kind
    public init(id: Int, kind: Kind) { self.id = id; self.kind = kind }
}

public enum Transcript {
    public static let home = ProcessInfo.processInfo.environment["TERMAPP_HOME"]
        ?? ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

    public static func claudeSession(pid: Int32, home: String = Transcript.home) -> String? {
        guard pid > 0,
              let data = FileManager.default.contents(atPath: home + "/.claude/sessions/\(pid).json"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["sessionId"] as? String, !id.isEmpty, !id.contains("/") else { return nil }
        let projects = home + "/.claude/projects/"
        if let cwd = obj["cwd"] as? String {
            let p = projects + String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" }) + "/" + id + ".jsonl"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] {
            let p = projects + dir + "/" + id + ".jsonl"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    public static func locate(agent: String, directory: String, started: Date, arguments: [String], pid: Int32 = 0) -> String? {
        if agent == "claude", let p = claudeSession(pid: pid) { return p }
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

    public static func locate(agent: String, directory: String) -> String? {
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

    public static func mtime(_ path: String) -> Date? {
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


    public static func parse(_ path: String, agent: String) -> [TranscriptItem] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return parse(data: data, agent: agent).items
    }

    public struct Survey: Equatable, Sendable {
        public var version: String?
        public var unknown: [String: Int] = [:]
        public init(version: String? = nil, unknown: [String: Int] = [:]) { self.version = version; self.unknown = unknown }
    }

    public static func survey(_ path: String, agent: String) -> Survey {
        guard let data = FileManager.default.contents(atPath: path) else { return Survey() }
        return parse(data: data, agent: agent).survey
    }

    public static func parse(data: Data, agent: String) -> (items: [TranscriptItem], survey: Survey) {
        var items: [TranscriptItem] = []
        var toolIndex: [String: Int] = [:]
        var survey = Survey()
        var partial: Range<Int>?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if agent == "claude" {
                if let v = obj["version"] as? String { survey.version = v }
                parseClaude(obj, items: &items, toolIndex: &toolIndex, survey: &survey)
            } else if agent == "ollama" || agent == "harness" {
                parseLocalChat(obj, items: &items, partial: &partial, survey: &survey)
            } else if agent == "codex-exec" {
                parseCodexExec(obj, items: &items, toolIndex: &toolIndex, survey: &survey)
            } else {
                if let p = obj["payload"] as? [String: Any], let v = p["cli_version"] as? String { survey.version = v }
                parseCodex(obj, items: &items, toolIndex: &toolIndex, survey: &survey)
            }
        }
        return (items, survey)
    }

    static let claudeRecords: Set<String> = [
        "user", "assistant", "attachment", "system", "summary", "custom-title", "progress",
        "atis-latch", "last-prompt", "mode", "permission-mode", "ai-title", "frame-link", "api-request",
        "api-request-blob", "api-request-shape", "session-owner", "queue-operation", "file-history-snapshot",
        "file-history-delta", "cost-state", "tools-used", "artifact-comment-monitor", "artifact-autoreact-ledger",
    ]
    static let claudeAttachments: Set<String> = [
        "queued_command", "total_tokens_reminder", "deferred_tools_record", "deferred_tools_delta", "prompt_snapshot",
        "environment", "date", "mcp_instructions_delta", "model", "session_context", "credential_org", "skill_listing",
        "instructions", "agent_listing_delta", "remote_session_change", "auto_mode", "silent_turn_reminder",
        "edited_text_file", "file", "compact_file_reference", "invoked_skills", "thinking_drop",
        "command_permissions", "task_status",
    ]
    static let claudeUserParts: Set<String> = ["text", "tool_result", "image", "document"]
    static let claudeAssistantParts: Set<String> = [
        "text", "thinking", "redacted_thinking", "tool_use", "tool_result", "tool_addition", "tool_removal",
        "image", "server_tool_use", "web_search_tool_result",
    ]
    static let codexRecords: Set<String> = [
        "session_meta", "turn_context", "compacted", "world_state", "token_usage_record",
        "inter_agent_communication_metadata",
        "event_msg/user_message", "event_msg/agent_message", "event_msg/item_completed", "event_msg/token_count",
        "event_msg/task_started", "event_msg/task_complete", "event_msg/thread_settings_applied",
        "event_msg/context_compacted", "event_msg/turn_aborted", "event_msg/agent_reasoning",
        "response_item/reasoning", "response_item/message", "response_item/agent_message",
        "response_item/function_call", "response_item/function_call_output",
        "response_item/custom_tool_call", "response_item/custom_tool_call_output",
        "response_item/additional_tools", "response_item/compaction",
    ]

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

    private static func parseClaude(_ obj: [String: Any], items: inout [TranscriptItem], toolIndex: inout [String: Int],
                                    survey: inout Survey) {
        func add(_ k: TranscriptItem.Kind) { items.append(TranscriptItem(id: items.count, kind: k)) }
        func unknown(_ kind: String) { survey.unknown[kind, default: 0] += 1 }
        func attachResult(_ part: [String: Any]) {
            guard let id = part["tool_use_id"] as? String, let i = toolIndex[id],
                  case .tool(let n, let sum, let det, _) = items[i].kind else { return }
            var result = text(part["content"])
            if result.count > 4_000 { result = String(result.prefix(4_000)) + "\n…" }
            items[i].kind = .tool(name: n, summary: sum, detail: det, result: result)
        }
        guard let type = obj["type"] as? String else { return }
        if !claudeRecords.contains(type) { unknown("record:" + type) }
        if type == "attachment", let a = obj["attachment"] as? [String: Any] {
            let kind = a["type"] as? String ?? "?"
            if !claudeAttachments.contains(kind) { unknown("attachment:" + kind) }
            if kind == "queued_command" || a["humanTurn"] as? Bool == true {
                let s = text(a["prompt"] ?? a["content"])
                if !s.isEmpty, !isNoise(s) { add(.user(s)) }
            }
            return
        }
        guard obj["isMeta"] as? Bool != true, let message = obj["message"] as? [String: Any] else { return }
        if type == "user" {
            if let s = message["content"] as? String {
                if !isNoise(s) { add(.user(s)) }
                return
            }
            for part in message["content"] as? [[String: Any]] ?? [] {
                let kind = part["type"] as? String ?? "?"
                switch kind {
                case "text":
                    if let s = part["text"] as? String, !isNoise(s) { add(.user(s)) }
                case "tool_result":
                    attachResult(part)
                default:
                    if !claudeUserParts.contains(kind) {
                        unknown("part:" + kind)
                        if let s = part["text"] as? String, !isNoise(s) { add(.user(s)) }
                    }
                }
            }
        } else if type == "assistant" {
            for part in message["content"] as? [[String: Any]] ?? [] {
                let kind = part["type"] as? String ?? "?"
                switch kind {
                case "text":
                    if let s = part["text"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.assistant(s)) }
                case "thinking":
                    if let s = part["thinking"] as? String, !s.isEmpty { add(.thinking(s)) }
                case "tool_use", "server_tool_use":
                    let name = part["name"] as? String ?? "tool"
                    let input = part["input"] as? [String: Any] ?? [:]
                    add(.tool(name: name, summary: toolSummary(name, input), detail: pretty(input), result: nil))
                    if let id = part["id"] as? String { toolIndex[id] = items.count - 1 }
                case "tool_result", "web_search_tool_result":
                    attachResult(part)
                default:
                    if !claudeAssistantParts.contains(kind) {
                        unknown("part:" + kind)
                        if let s = part["text"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.assistant(s)) }
                    }
                }
            }
        }
    }

    private static func parseLocalChat(_ obj: [String: Any], items: inout [TranscriptItem], partial: inout Range<Int>?,
                                       survey: inout Survey) {
        func add(_ k: TranscriptItem.Kind) { items.append(TranscriptItem(id: items.count, kind: k)) }
        func reply() {
            if let r = partial { items.removeSubrange(r); partial = nil }
            let start = items.count
            if let t = obj["thinking"] as? String, !t.isEmpty { add(.thinking(t)) }
            if let s = obj["text"] as? String, !s.isEmpty { add(.assistant(s)) }
            if obj["type"] as? String == "partial" { partial = start..<items.count }
        }
        switch obj["type"] as? String {
        case "meta":
            survey.version = obj["model"] as? String
        case "user":
            partial = nil
            if let s = obj["text"] as? String, !s.isEmpty { add(.user(s)) }
        case "assistant", "partial":
            reply()
        case "tool":
            let summary = obj["summary"] as? String ?? ""
            add(.tool(name: obj["name"] as? String ?? "tool", summary: summary, detail: summary, result: obj["result"] as? String))
        case let other:
            survey.unknown["record:" + (other ?? "?"), default: 0] += 1
        }
    }

    private static func parseCodexExec(_ obj: [String: Any], items: inout [TranscriptItem], toolIndex: inout [String: Int],
                                       survey: inout Survey) {
        func add(_ k: TranscriptItem.Kind) { items.append(TranscriptItem(id: items.count, kind: k)) }
        let type = obj["type"] as? String ?? "?"
        switch type {
        case "thread.started", "turn.started", "turn.completed":
            return
        case "error", "turn.failed":
            let message = (obj["message"] as? String) ?? ((obj["error"] as? [String: Any])?["message"] as? String) ?? "Codex stopped."
            add(.assistant("**Codex stopped:** " + message))
            return
        case "item.started", "item.updated", "item.completed":
            break
        default:
            survey.unknown["record:" + type, default: 0] += 1
            return
        }
        guard let item = obj["item"] as? [String: Any] else { return }
        let id = item["id"] as? String ?? UUID().uuidString
        let done = type == "item.completed"
        func clip(_ s: String) -> String { s.count > 4_000 ? String(s.prefix(4_000)) + "\n…" : s }
        func step(_ name: String, _ summary: String, _ detail: String, result: String?) {
            if let i = toolIndex[id] {
                items[i].kind = .tool(name: name, summary: summary, detail: detail, result: result)
            } else {
                add(.tool(name: name, summary: summary, detail: detail, result: result))
                toolIndex[id] = items.count - 1
            }
        }
        switch item["type"] as? String ?? "?" {
        case "agent_message":
            if done, let t = item["text"] as? String, !t.isEmpty { add(.assistant(t)) }
        case "reasoning":
            if done, let t = item["text"] as? String, !t.isEmpty { add(.thinking(t)) }
        case "command_execution":
            let command = shellCommand(item["command"] as? String ?? "")
            var result: String?
            if done {
                result = clip(item["aggregated_output"] as? String ?? "")
                if let code = item["exit_code"] as? Int, code != 0 { result = (result ?? "") + "\n(exit code \(code))" }
            }
            step("Shell", command.split(separator: "\n").first.map(String.init) ?? command, command, result: result)
        case "file_change":
            let changes = (item["changes"] as? [[String: Any]] ?? []).map { "\($0["kind"] as? String ?? "change") \($0["path"] as? String ?? "")" }
            step("Edit", changes.first ?? "files", changes.joined(separator: "\n"), result: done ? "" : nil)
        case "web_search":
            let query = item["query"] as? String ?? ""
            step("Web search", query, query, result: done ? "\((item["results"] as? [Any])?.count ?? 0) results" : nil)
        case "mcp_tool_call":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            let args = item["arguments"].map(pretty) ?? ""
            var result: String?
            if done {
                if let e = item["error"], !(e is NSNull) { result = "Error: " + pretty(e) }
                else { result = clip(item["result"].map(pretty) ?? "") }
            }
            step(name.isEmpty ? "Tool" : name, "", args, result: result)
        case "todo_list":
            let list = (item["items"] as? [[String: Any]] ?? []).map { (($0["completed"] as? Bool) == true ? "[x] " : "[ ] ") + ($0["text"] as? String ?? "") }
            if !list.isEmpty { step("Plan", "\(list.count) steps", list.joined(separator: "\n"), result: "") }
        case let other:
            survey.unknown["item:" + other, default: 0] += 1
        }
    }

    public static func shellCommand(_ s: String) -> String {
        guard let m = s.firstMatch(of: #/^\S*/(?:ba|z)?sh -lc (.*)$/#.dotMatchesNewlines()) else { return s }
        var inner = String(m.1)
        if inner.count >= 2, let q = inner.first, q == "'" || q == "\"", inner.last == q {
            inner = String(inner.dropFirst().dropLast())
            if q == "'" { inner = inner.replacingOccurrences(of: "'\\''", with: "'") }
        }
        return inner
    }

    private static func parseCodex(_ obj: [String: Any], items: inout [TranscriptItem], toolIndex: inout [String: Int],
                                   survey: inout Survey) {
        func add(_ k: TranscriptItem.Kind) { items.append(TranscriptItem(id: items.count, kind: k)) }
        guard let type = obj["type"] as? String else { return }
        let p = obj["payload"] as? [String: Any] ?? [:]
        let ptype = p["type"] as? String
        let kind = (type == "event_msg" || type == "response_item") ? type + "/" + (ptype ?? "?") : type
        if !codexRecords.contains(kind) { survey.unknown["record:" + kind, default: 0] += 1 }
        func recent(_ k: TranscriptItem.Kind) -> Bool { items.suffix(4).contains { $0.kind == k } }
        if type == "event_msg" && ptype == "user_message", let s = p["message"] as? String, !isNoise(s) {
            if !recent(.user(s)) { add(.user(s)) }
        } else if type == "event_msg" && ptype == "agent_message", let s = p["message"] as? String, !s.isEmpty {
            if !recent(.assistant(s)) { add(.assistant(s)) }
        } else if type == "event_msg" && ptype == "item_completed", let it = p["item"] as? [String: Any] {
            let itemType = it["type"] as? String ?? "?"
            let words = ((it["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            switch itemType {
            case "UserMessage":
                if !isNoise(words), !recent(.user(words)) { add(.user(words)) }
            case "AgentMessage":
                let s = words.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty, !recent(.assistant(s)) { add(.assistant(s)) }
            case "CommandExecution":
                let raw = (it["command"] as? [String])?.joined(separator: " ") ?? (it["command"] as? String) ?? ""
                let cmd = shellCommand((it["command"] as? [String]).map { $0.count == 3 ? "\($0[0]) \($0[1]) \($0[2])" : raw } ?? raw)
                var out = it["aggregated_output"] as? String ?? ""
                if out.count > 4_000 { out = String(out.prefix(4_000)) + "\n…" }
                add(.tool(name: "Shell", summary: cmd, detail: cmd, result: out))
            case "FileChange":
                let changes = it["changes"] as? [String: Any] ?? [:]
                let paths = changes.keys.sorted()
                let diffs = paths.compactMap { path in ((changes[path] as? [String: Any])?["unified_diff"] as? String).map { "\(path)\n\($0)" } }
                add(.tool(name: "Edit", summary: paths.joined(separator: ", "), detail: diffs.joined(separator: "\n\n"),
                          result: it["stdout"] as? String ?? ""))
            case "Reasoning", "Plan", "TodoList":
                break
            default:
                survey.unknown["item:" + itemType, default: 0] += 1
            }
        } else if type == "response_item" && (ptype == "function_call" || ptype == "custom_tool_call") {
            let name = p["name"] as? String ?? "tool"
            let rawArgs = (p["arguments"] as? String) ?? (p["input"] as? String) ?? ""
            if name == "exec", rawArgs.hasPrefix("text(await tools.") || rawArgs.contains("await tools.") { return }
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
