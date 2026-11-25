#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#else
import Darwin
#endif
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TermHost



struct AgentToolResult { let id: String; let name: String; let text: String; let isError: Bool }

enum AgentTools {
    static let definitions: [(name: String, description: String, schema: [String: Any])] = [
        ("bash", "Run a shell command in the project folder and return its output (stdout and stderr). Use for builds, tests, git and inspecting the system. Commands time out after timeout_seconds (default 120, at most 600).",
         ["type": "object", "required": ["command"], "properties": [
            "command": ["type": "string"], "timeout_seconds": ["type": "integer"]]]),
        ("read_file", "Read a text file, with line numbers. Use offset and limit (in lines) for large files.",
         ["type": "object", "required": ["path"], "properties": [
            "path": ["type": "string"], "offset": ["type": "integer"], "limit": ["type": "integer"]]]),
        ("write_file", "Create or overwrite a file with the given content.",
         ["type": "object", "required": ["path", "content"], "properties": [
            "path": ["type": "string"], "content": ["type": "string"]]]),
        ("edit_file", "Replace old_string with new_string in a file. old_string must appear exactly once unless replace_all is true.",
         ["type": "object", "required": ["path", "old_string", "new_string"], "properties": [
            "path": ["type": "string"], "old_string": ["type": "string"], "new_string": ["type": "string"],
            "replace_all": ["type": "boolean"]]]),
        ("list_files", "List files whose path matches a glob pattern (for example **/*.swift), skipping .git and dependency folders.",
         ["type": "object", "required": ["pattern"], "properties": [
            "pattern": ["type": "string"], "path": ["type": "string"]]]),
        ("search", "Search file contents for a regular expression and return matching lines with file and line number.",
         ["type": "object", "required": ["pattern"], "properties": [
            "pattern": ["type": "string"], "path": ["type": "string"]]]),
    ]

    static func needsApproval(_ name: String, mode: String) -> Bool {
        switch name {
        case "read_file", "list_files", "search": return false
        case "write_file", "edit_file": return mode == "off"
        default: return mode != "all"
        }
    }

    static func summary(_ c: AgentToolCall) -> String {
        let s = (c.input["command"] as? String) ?? (c.input["path"] as? String) ?? (c.input["pattern"] as? String) ?? ""
        return s.replacingOccurrences(of: "\n", with: " ")
    }

    static func run(_ c: AgentToolCall, cwd: String) -> AgentToolResult {
        func ok(_ t: String) -> AgentToolResult { AgentToolResult(id: c.id, name: c.name, text: cap(t), isError: false) }
        func err(_ t: String) -> AgentToolResult { AgentToolResult(id: c.id, name: c.name, text: t, isError: true) }
        func path(_ key: String = "path") -> String? {
            guard let p = c.input[key] as? String, !p.isEmpty else { return nil }
            let expanded = (p as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        }
        if c.invalid { return err("INVALID_JSON: the tool input was cut off or malformed. Send the call again.") }
        if c.name != "bash", let p = path(), isSecret(p) { return err("That path holds Terminess's API keys, which agents can't read or change.") }
        switch c.name {
        case "bash":
            guard let cmd = c.input["command"] as? String else { return err("Give a command.") }
            let timeout = min(600, max(1, c.input["timeout_seconds"] as? Int ?? 120))
            return ok(shell(cmd, cwd: cwd, timeout: TimeInterval(timeout)))
        case "read_file":
            guard let p = path(), let text = try? String(contentsOfFile: p, encoding: .utf8) else { return err("Couldn't read that file as text.") }
            let lines = text.components(separatedBy: "\n")
            let offset = max(0, (c.input["offset"] as? Int ?? 1) - 1)
            let limit = min(2000, c.input["limit"] as? Int ?? 2000)
            guard offset < max(lines.count, 1) else { return ok("(the file has \(lines.count) lines)") }
            let slice = lines[offset..<min(lines.count, offset + limit)]
            return ok(slice.enumerated().map { "\($0.offset + offset + 1)\t\($0.element)" }.joined(separator: "\n"))
        case "write_file":
            guard let p = path(), let content = c.input["content"] as? String else { return err("Give a path and content.") }
            do {
                try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try content.write(toFile: p, atomically: true, encoding: .utf8)
                return ok("Wrote \(content.components(separatedBy: "\n").count) lines to \(c.input["path"] as? String ?? p).")
            } catch { return err("Couldn't write: \(error.localizedDescription)") }
        case "edit_file":
            guard let p = path(), let old = c.input["old_string"] as? String, let new = c.input["new_string"] as? String else {
                return err("Give path, old_string and new_string.")
            }
            guard var text = try? String(contentsOfFile: p, encoding: .utf8) else { return err("Couldn't read that file.") }
            let count = text.components(separatedBy: old).count - 1
            if count == 0 { return err("old_string wasn't found. Read the file and copy the text exactly.") }
            if count > 1 && c.input["replace_all"] as? Bool != true { return err("old_string appears \(count) times; give more context or set replace_all.") }
            text = text.replacingOccurrences(of: old, with: new)
            do { try text.write(toFile: p, atomically: true, encoding: .utf8) } catch { return err("Couldn't write: \(error.localizedDescription)") }
            return ok("Edited \(c.input["path"] as? String ?? p) (\(count) change\(count == 1 ? "" : "s")).")
        case "list_files":
            guard let pattern = c.input["pattern"] as? String else { return err("Give a pattern.") }
            let root = path() ?? cwd
            return ok(listFiles(pattern, root: root))
        case "search":
            guard let pattern = c.input["pattern"] as? String else { return err("Give a pattern.") }
            let root = path() ?? cwd
            let q = "'" + pattern.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let r = "'" + root.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return ok(shell("if command -v rg >/dev/null; then rg -n --max-count 50 -e \(q) \(r) | head -300; else grep -rnE \(q) \(r) | head -300; fi",
                            cwd: cwd, timeout: 60))
        default:
            return err("Unknown tool \(c.name).")
        }
    }

    static func isSecret(_ path: String) -> Bool {
        let home = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) as NSString
        let dir = (home.appendingPathComponent(".config/terminess") as NSString).resolvingSymlinksInPath
        let p = (path as NSString).standardizingPath
        let real = (p as NSString).resolvingSymlinksInPath
        return [p, real].contains { $0 == dir || $0.hasPrefix(dir + "/") || (dir.hasPrefix($0 + "/") && $0 != "/") || $0 == "/" }
    }

    static func cap(_ s: String) -> String { s.count > 30_000 ? String(s.prefix(30_000)) + "\n(output cut at 30,000 characters)" : s }

    static func shell(_ command: String, cwd: String, timeout: TimeInterval) -> String {
        let p = Process()
        #if os(Linux)
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        #else
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        #endif
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "HF_TOKEN"] { env[k] = nil }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return "Couldn't run the shell: \(error.localizedDescription)" }
        try? out.fileHandleForWriting.close()
        let fd = out.fileHandleForReading.fileDescriptor
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        func drain(until deadline: Date) -> Bool {
            while Date() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ms = Int32(max(1, min(200, deadline.timeIntervalSinceNow * 1000)))
                guard poll(&pfd, 1, ms) > 0 else { continue }
                let n = read(fd, &buf, buf.count)
                if n <= 0 { return true }
                if data.count < 2_000_000 { data.append(contentsOf: buf[0..<n]) }
            }
            return false
        }
        var status: Int32?
        func ended() -> Bool {
            if exited.wait(timeout: .now()) == .success {
                status = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
                return true
            }
            #if os(Linux)
            if let stat = try? String(contentsOfFile: "/proc/\(p.processIdentifier)/stat", encoding: .utf8),
               let close = stat.lastIndex(of: ")") {
                let f = stat[stat.index(after: close)...].split(separator: " ")
                if let state = f.first, state == "Z" || state == "X" {
                    let raw = f.count > 49 ? Int32(f[49].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
                    status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
                    return true
                }
            }
            #endif
            return false
        }
        let end = Date().addingTimeInterval(timeout)
        var finished = false, closed = false
        while !finished && Date() < end {
            if !closed { closed = drain(until: min(end, Date().addingTimeInterval(0.2))) }
            else { Thread.sleep(forTimeInterval: 0.05) }
            finished = ended()
        }
        if !finished {
            p.terminate()
            _ = drain(until: Date().addingTimeInterval(1))
            try? out.fileHandleForReading.close()
            return String(decoding: data, as: UTF8.self) + "\n(stopped after \(Int(timeout)) seconds)"
        }
        let stillOpen = !closed && !drain(until: Date().addingTimeInterval(0.5))
        try? out.fileHandleForReading.close()
        let text = String(decoding: data, as: UTF8.self)
        let code = status ?? 0
        return (text.isEmpty ? "(no output)" : text) + (code == 0 ? "" : "\n(exit code \(code))")
            + (stillOpen ? "\n(something it started is still running in the background; its later output isn't shown)" : "")
    }

    static func listFiles(_ pattern: String, root: String) -> String {
        let skip: Set<String> = [".git", "node_modules", ".build", "build", "dist", ".venv", "__pycache__", "Pods", "DerivedData"]
        guard let e = FileManager.default.enumerator(atPath: root) else { return "No such folder." }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            if skip.contains((rel as NSString).lastPathComponent) { e.skipDescendants(); continue }
            if fnmatch(pattern, rel, 0) == 0 || (!pattern.contains("/") && fnmatch(pattern, (rel as NSString).lastPathComponent, 0) == 0) {
                out.append(rel)
                if out.count >= 500 { out.append("(stopped at 500)"); break }
            }
        }
        return out.isEmpty ? "No files match." : out.joined(separator: "\n")
    }
}



protocol AgentProvider: AnyObject {
    var label: String { get }
    func addUser(_ text: String)
    func addResults(_ results: [AgentToolResult])
    func clear()
    func turn(system: String, onText: @escaping (String, Bool) -> Void) -> AgentTurn
    func cancel()
}

final class AnthropicProvider: NSObject, AgentProvider, URLSessionDataDelegate, @unchecked Sendable {
    let model: String, effort: String, key: String
    var label: String { model }
    var baseURL = "https://api.anthropic.com"
    var maxOutput = 64000
    var bearer = false
    private var messages: [[String: Any]] = []
    private var task: URLSessionDataTask?
    private var parser = AnthropicStream()
    private var onText: ((String, Bool) -> Void)?
    private var httpError: String?
    private var errorBody = Data()
    private let done = DispatchSemaphore(value: 0)
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(model: String, effort: String, key: String) { self.model = model; self.effort = effort; self.key = key }

    func addUser(_ text: String) { messages.append(["role": "user", "content": text]) }
    func addResults(_ results: [AgentToolResult]) {
        messages.append(["role": "user", "content": results.map {
            ["type": "tool_result", "tool_use_id": $0.id, "content": $0.text, "is_error": $0.isError] as [String: Any]
        }])
    }
    func clear() { messages = [] }
    func cancel() { task?.cancel() }

    private var takesFallback: Bool {
        ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-fable-5-1", "claude-fable-5-2"].contains(model)
    }

    func turn(system: String, onText: @escaping (String, Bool) -> Void) -> AgentTurn {
        self.onText = onText
        parser = AnthropicStream()
        httpError = nil
        errorBody = Data()
        var body: [String: Any] = [
            "model": model, "max_tokens": maxOutput, "stream": true,
            "system": [["type": "text", "text": system]],
            "tools": AgentTools.definitions.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema,
                                                   "eager_input_streaming": true] as [String: Any] },
            "messages": messages,
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": effort],
            "cache_control": ["type": "ephemeral"],
        ]
        if takesFallback { body["fallbacks"] = "default" }
        guard let endpoint = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages") else {
            var t = AgentTurn(); t.error = "ANTHROPIC_BASE_URL isn't a URL."; return t
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if bearer { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        else { req.setValue(key, forHTTPHeaderField: "x-api-key") }
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if takesFallback { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        task = session.dataTask(with: req)
        task?.resume()
        done.wait()
        var result = parser.result()
        if let e = httpError { result.error = e }
        if result.error == nil, !parser.content.isEmpty { messages.append(["role": "assistant", "content": parser.content]) }
        return result
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { httpError = "HTTP \(http.statusCode)" }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if httpError != nil { errorBody.append(data); return }
        for (text, thinking) in parser.feed(data) { onText?(text, thinking) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if httpError != nil {
            let obj = (try? JSONSerialization.jsonObject(with: errorBody)) as? [String: Any]
            let message = (obj?["error"] as? [String: Any])?["message"] as? String
            httpError = "\(httpError!): \(message ?? String(decoding: errorBody.prefix(300), as: UTF8.self))"
        } else if let error, (error as NSError).code != NSURLErrorCancelled {
            httpError = error.localizedDescription
        } else if error != nil {
            httpError = "Stopped."
        }
        done.signal()
    }
}

final class OllamaAgentProvider: NSObject, AgentProvider, URLSessionDataDelegate, @unchecked Sendable {
    let model: String
    var label: String { "ollama:\(model)" }
    private var messages: [[String: Any]] = []
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var current = AgentTurn()
    private var callsRaw: [[String: Any]] = []
    private var onText: ((String, Bool) -> Void)?
    private let done = DispatchSemaphore(value: 0)
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var counter = 0

    init(model: String) { self.model = model }
    func addUser(_ text: String) { messages.append(["role": "user", "content": text]) }
    func addResults(_ results: [AgentToolResult]) {
        for r in results { messages.append(["role": "tool", "content": r.text, "tool_name": r.name]) }
    }
    func clear() { messages = [] }
    func cancel() { task?.cancel() }

    func turn(system: String, onText: @escaping (String, Bool) -> Void) -> AgentTurn {
        self.onText = onText
        current = AgentTurn()
        callsRaw = []
        buffer = Data()
        let body: [String: Any] = [
            "model": model, "stream": true, "think": false,
            "options": ["num_ctx": Int(ProcessInfo.processInfo.environment["TERMINESS_CHAT_CONTEXT"] ?? "") ?? 32768],
            "messages": [["role": "system", "content": system]] + messages,
            "tools": AgentTools.definitions.map { ["type": "function", "function": ["name": $0.name, "description": $0.description,
                                                                                    "parameters": $0.schema]] as [String: Any] },
        ]
        var req = URLRequest(url: URL(string: LocalModels.base + "/api/chat")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        task = session.dataTask(with: req)
        task?.resume()
        done.wait()
        var assistant: [String: Any] = ["role": "assistant", "content": current.text]
        if !callsRaw.isEmpty { assistant["tool_calls"] = callsRaw }
        if current.error == nil { messages.append(assistant) }
        current.stopReason = current.calls.isEmpty ? "end_turn" : "tool_use"
        return current
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let e = obj["error"] as? String { current.error = e; continue }
            let m = obj["message"] as? [String: Any] ?? [:]
            if let c = m["content"] as? String, !c.isEmpty { current.text += c; onText?(c, false) }
            for call in m["tool_calls"] as? [[String: Any]] ?? [] {
                let f = call["function"] as? [String: Any] ?? [:]
                counter += 1
                callsRaw.append(call)
                current.calls.append(AgentToolCall(id: "call_\(counter)", name: f["name"] as? String ?? "",
                                                   input: f["arguments"] as? [String: Any] ?? [:], invalid: false))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { current.error = (error as NSError).code == NSURLErrorCancelled ? "Stopped." : error.localizedDescription }
        done.signal()
    }
}

final class OpenAIChatProvider: NSObject, AgentProvider, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL, token: String?, model: String, label: String
    let maxOutput: Int
    static let defaultMaxOutput = 32768
    var reasoningEffort: String?
    private var sendsReasoning: Bool { model.hasPrefix("deepseek-ai/") || model.lowercased().hasPrefix("deepseek") }
    private var messages: [[String: Any]] = []
    private var context: AgentContext
    private var task: URLSessionDataTask?
    private var parser = OpenAIStream()
    private var onText: ((String, Bool) -> Void)?
    private var status = 200
    private var errorBody = Data()
    private var failure: String?
    private let done = DispatchSemaphore(value: 0)
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    var onCompact: ((String) -> Void)?
    private(set) var inputTokens = 0, outputTokens = 0
    var usedTokens: Int { inputTokens + outputTokens }

    init(url: URL, token: String?, model: String, label: String, contextWindow: Int, maxOutput: Int?, compactAt: Int) {
        self.url = url; self.token = token; self.model = model; self.label = label
        self.maxOutput = maxOutput ?? Self.defaultMaxOutput
        context = AgentContext(window: contextWindow, reply: self.maxOutput, compactAt: compactAt)
    }
    func addUser(_ text: String) { messages.append(["role": "user", "content": text]) }
    func addResults(_ results: [AgentToolResult]) {
        for r in results { messages.append(["role": "tool", "tool_call_id": r.id, "content": r.text]) }
    }
    func clear() { messages = [] }
    func cancel() { task?.cancel() }

    func continueAfterCutoff() {
        addUser("Your last reply hit the length limit before you did anything, so nothing ran. Don't start the plan over. Take the next concrete step now with a tool (write the file, run the command, try the simplest version and look at the result), and keep your thinking short.")
    }

    private var tools: [[String: Any]] {
        AgentTools.definitions.map { ["type": "function", "function": ["name": $0.name, "description": $0.description,
                                                                       "parameters": $0.schema]] as [String: Any] }
    }

    private func send(_ body: [String: Any], onText: ((String, Bool) -> Void)?) -> (OpenAIStream, String?) {
        self.onText = onText
        parser = OpenAIStream()
        status = 200
        errorBody = Data()
        failure = nil
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        task = session.dataTask(with: req)
        task?.resume()
        done.wait()
        if parser.promptTokens > 0 { context.learn(bytes: req.httpBody?.count ?? 0, promptTokens: parser.promptTokens) }
        inputTokens += parser.promptTokens
        outputTokens += parser.completionTokens
        return (parser, failure)
    }

    private func body(system: String, _ msgs: [[String: Any]], tools: Bool) -> [String: Any] {
        var b: [String: Any] = ["model": model, "stream": true, "stream_options": ["include_usage": true],
                                "messages": [["role": "system", "content": system]] + msgs]
        if tools { b["tools"] = self.tools }
        b[limitField] = maxOutput
        if tools, let reasoningEffort { b["reasoning_effort"] = reasoningEffort }
        return b
    }

    private var limitField: String { url.host == "api.openai.com" ? "max_completion_tokens" : "max_tokens" }

    private func compactIfNeeded(system: String) {
        func size() -> Int { AgentContext.size(body(system: system, messages, tools: true)) }
        guard context.needsCompacting(bytes: size()) else { return }
        defer {
            let over = size() - context.requestBudget
            if over > 0 {
                AgentContext.shrinkToolResults(&messages, by: over)
                onCompact?("Shortened long tool output to fit the context window.")
            }
        }
        guard let cut = context.cut(messages) else { return }
        let before = cut.map { AgentContext.size(messages[$0]) }.reduce(0, +)
        guard before > 2000 else { return }
        let summaryOut = max(256, min(2048, context.limit / 8))
        let limit = max(1000, Int(Double(context.limit - summaryOut - 600) * context.bytesPerToken * 0.9))
        let text = AgentContext.transcript(messages[cut], limit: limit)
        let ask = "Summarise this part of a coding agent's session so the agent can carry on without it. Keep every fact it will need: files read or changed and how, commands run and what they showed, errors and what fixed them, decisions made, and what is still to do. Be concise and specific; no preamble.\n\n" + text
        var summaryBody: [String: Any] = ["model": model, "stream": true,
                                          "messages": [["role": "user", "content": ask]]]
        summaryBody[limitField] = summaryOut
        let (stream, error) = send(summaryBody, onText: nil)
        let ok = error == nil && stream.error == nil && stream.complete && !stream.text.isEmpty
        let summary = ok
            ? "Earlier in this session (summarised to fit the context window):\n" + stream.text
            : "\(cut.count) earlier messages were left out to fit the context window."
        messages.replaceSubrange(cut, with: [["role": "user", "content": summary]])
        onCompact?(ok ? "Summarised \(cut.count) earlier messages to fit the context window."
                                                       : "Left out \(cut.count) earlier messages to fit the context window.")
    }

    func turn(system: String, onText: @escaping (String, Bool) -> Void) -> AgentTurn {
        compactIfNeeded(system: system)
        let (stream, error) = send(body(system: system, messages, tools: true), onText: onText)
        var result = stream.result()
        if let error { result.error = error }
        if result.error == nil {
            if result.stopReason == "max_tokens" {
                let trace = result.text.isEmpty ? "(I was still thinking when my reply hit the length limit. Where I'd got to: …"
                    + String(result.thinking.suffix(1500)) + ")" : result.text
                messages.append(["role": "assistant", "content": trace])
            }
            else { messages.append(stream.assistantMessage(withReasoning: sendsReasoning)) }
        }
        return result
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if status != 200 { errorBody.append(data); return }
        for (text, thinking) in parser.feed(data) { onText?(text, thinking) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if url.host == "router.huggingface.co", status != 200 || error == nil { HuggingFace.record(status: status) }
        if status != 200 {
            failure = url.host == "router.huggingface.co" ? HuggingFace.errorMessage(status: status, body: errorBody)
                : "HTTP \(status): " + (((try? JSONSerialization.jsonObject(with: errorBody)) as? [String: Any]).flatMap {
                    ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String
                } ?? String(decoding: errorBody.prefix(300), as: UTF8.self))
        }
        else if let error { failure = (error as NSError).code == NSURLErrorCancelled ? "Stopped." : error.localizedDescription }
        done.signal()
    }
}


func anthropicKey() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let k = env["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
    let home = env["HOME"] ?? NSHomeDirectory()
    if let k = try? String(contentsOfFile: home + "/.config/terminess/anthropic_key", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
    return nil
}

func agent(_ args: [String]) -> Never {
    var model = "claude-opus-5-5", effort = "high", mode = "off", once = false, effortChosen = false
    var words: [String] = []
    let env0 = ProcessInfo.processInfo.environment
    func positive(_ key: String) -> Int? { Int(env0[key] ?? "").flatMap { $0 > 0 ? $0 : nil } }
    var maxTurns = positive("TERMINESS_AGENT_MAX_TURNS") ?? 60
    var contextWindow = positive("TERMINESS_CONTEXT_WINDOW") ?? 0
    var maxOutput = positive("TERMINESS_MAX_OUTPUT")
    var compactAt = Int(env0["TERMINESS_COMPACT_AT"] ?? "").flatMap { $0 >= 0 ? $0 : nil } ?? AgentContext.defaultCompactAt
    var tokenBudget = positive("TERMINESS_TOKEN_BUDGET")
    var baseURL = env0["OPENAI_BASE_URL"] ?? ""
    func number(_ flag: String, _ value: String?) -> Int {
        guard let v = value.flatMap({ Int($0) }), v > 0 else { fail("\(flag) takes a positive number") }
        return v
    }
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--model": i += 1; if i < args.count { model = args[i] }
        case "--effort": i += 1; if i < args.count { effort = args[i]; effortChosen = true }
        case "--auto": i += 1; if i < args.count { mode = args[i] }
        case "--once": once = true
        case "--max-turns": i += 1; maxTurns = number("--max-turns", i < args.count ? args[i] : nil)
        case "--context-window": i += 1; contextWindow = number("--context-window", i < args.count ? args[i] : nil)
        case "--max-output": i += 1; maxOutput = number("--max-output", i < args.count ? args[i] : nil)
        case "--compact-at":
            i += 1
            guard i < args.count, let v = Int(args[i]), v >= 0 else { fail("--compact-at takes a number of tokens (0 for the window alone)") }
            compactAt = v
        case "--token-budget": i += 1; tokenBudget = number("--token-budget", i < args.count ? args[i] : nil)
        case "--base-url": i += 1; if i < args.count { baseURL = args[i] }
        default: words.append(args[i])
        }
        i += 1
    }
    guard ["off", "edits", "all"].contains(mode) else { fail("--auto takes off, edits or all") }
    let env = ProcessInfo.processInfo.environment
    let cwd = FileManager.default.currentDirectoryPath
    let dim = "\u{1B}[2m", bold = "\u{1B}[1m", red = "\u{1B}[31m", cyan = "\u{1B}[36m", reset = "\u{1B}[0m"
    func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

    func makeProvider(_ m: String) -> AgentProvider? {
        if m.hasPrefix("ollama:") { return OllamaAgentProvider(model: String(m.dropFirst(7))) }
        if let id = HuggingFace.modelID(m) {
            guard !id.isEmpty, let token = HuggingFace.token() else {
                out("\(red)No Hugging Face token. Add one in Terminess Settings, set HF_TOKEN, or save it in ~/.config/terminess/hf_token.\(reset)\n")
                return nil
            }
            return openAI(URL(string: HuggingFace.chatURL)!, token: token, model: id, label: m)
        }
        if m.hasPrefix("openai:") {
            let name = String(m.dropFirst(7))
            let base = (baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty, let url = URL(string: base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"),
                  url.scheme == "http" || url.scheme == "https" else {
                out("\(red)openai:<model> needs a model name and an http(s) --base-url or OPENAI_BASE_URL.\(reset)\n")
                return nil
            }
            return openAI(url, token: env["OPENAI_API_KEY"], model: name, label: m)
        }
        let gatewayToken = env["ANTHROPIC_AUTH_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        guard let key = gatewayToken ?? anthropicKey() else {
            out("\(red)No Anthropic API key. Add one in Terminess Settings, set ANTHROPIC_API_KEY, or use --model ollama:<model> or hf:<org>/<model>.\(reset)\n")
            return nil
        }
        let p = AnthropicProvider(model: m, effort: effort, key: key)
        p.bearer = gatewayToken != nil
        if let b = env["ANTHROPIC_BASE_URL"], !b.isEmpty { p.baseURL = b }
        if let maxOutput { p.maxOutput = maxOutput }
        return p
    }
    func openAI(_ url: URL, token: String?, model id: String, label: String) -> AgentProvider {
        let p = OpenAIChatProvider(url: url, token: token, model: id, label: label, contextWindow: contextWindow, maxOutput: maxOutput,
                                   compactAt: compactAt)
        p.onCompact = { note in out("\(dim)\(note)\(reset)\n") }
        if effortChosen { p.reasoningEffort = effort }
        return p
    }
    guard var provider = makeProvider(model) else { exit(1) }

    let path = LocalChat.newPath(session: env["TERMINESS_SESSION"])
    func record(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(data + Data([0x0A]))
        try? h.close()
    }
    func report(_ event: [String: Any]) {
        guard let session = env["TERMINESS_SESSION"], let fd = UnixSocket.connect(HostPaths.socket),
              let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        _ = Connection.writeAll(fd, Wire.Frame.control(Message(op: "hook", id: session, name: "claude",
                                                               message: String(decoding: data, as: UTF8.self))).encoded())
        close(fd)
    }
    record(["type": "meta", "model": provider.label, "cwd": cwd, "kind": "harness", "started": Date().timeIntervalSince1970])

    let system = """
        You are a coding agent working in \(cwd) on the person's machine, inside Terminess. Use the tools to read, \
        change and run things; read before you edit, keep changes focused on what was asked, and run the relevant \
        tests or build when you change code. Work in small steps: try something, run it and look at the result, \
        rather than planning at length in your head; a quick experiment usually settles a question faster. Before you \
        say you're done, check the result really works. Commands that change files or the system may need the person's approval. \
        When you finish, say briefly what you did and anything left for the person to decide.
        """

    var always: Set<String> = []
    func approve(_ c: AgentToolCall) -> String {
        if !AgentTools.needsApproval(c.name, mode: mode) || always.contains(c.name) { return "allow" }
        if once && env["TERMINESS_SESSION"] == nil { return "deny" }
        out("\n\(bold)Allow \(c.name)?\(reset) \(AgentTools.summary(c))\n\(dim)  y yes · a always for \(c.name) · n no\(reset) ")
        var fd: Int32 = -1
        if let session = env["TERMINESS_SESSION"], let s = UnixSocket.connect(HostPaths.socket) {
            fd = s
            let event: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": c.name, "tool_input": c.input, "cwd": cwd,
                                        "permission_suggestions": [["type": "session", "tool": c.name]]]
            if let data = try? JSONSerialization.data(withJSONObject: event) {
                _ = Connection.writeAll(s, Wire.Frame.control(Message(op: "permission", id: session, name: "harness",
                                                                      message: String(decoding: data, as: UTF8.self))).encoded())
            }
        }
        defer { if fd >= 0 { close(fd) } }
        var saved = termios()
        let interactive = isatty(0) != 0 && tcgetattr(0, &saved) == 0
        if interactive { var raw = saved; raw.c_lflag &= ~tcflag_t(ICANON | ECHO); tcsetattr(0, TCSANOW, &raw) }
        defer { if interactive { tcsetattr(0, TCSANOW, &saved) } }
        var decoder = Wire.Decoder()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var fds = [pollfd(fd: interactive ? 0 : -1, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, -1) > 0 else { continue }
            if fds[0].revents != 0 {
                var ch: UInt8 = 0
                guard read(0, &ch, 1) == 1 else { return "deny" }
                switch ch {
                case UInt8(ascii: "y"), UInt8(ascii: "Y"), 13, 10: out("yes\n"); return "allow"
                case UInt8(ascii: "a"), UInt8(ascii: "A"): out("always\n"); always.insert(c.name); return "allow"
                case UInt8(ascii: "n"), UInt8(ascii: "N"), 27: out("no\n"); return "deny"
                default: continue
                }
            }
            if fds[1].revents != 0 {
                let n = read(fd, &buf, buf.count)
                guard n > 0, let frames = try? decoder.feed(Array(buf[0..<n])) else { fd = -1; continue }
                if let answer = frames.compactMap(\.message).first(where: { $0.op == "decision" })?.message, !answer.isEmpty {
                    out("\(answer == "deny" ? "no" : "yes") (answered in Terminess)\n")
                    if answer == "always" { always.insert(c.name) }
                    return answer == "deny" ? "deny" : "allow"
                }
            }
        }
    }

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigint.setEventHandler { provider.cancel() }
    sigint.resume()

    @discardableResult func run(_ text: String) -> Bool {
        var finished = true
        provider.addUser(text)
        record(["type": "user", "text": text])
        report(["hook_event_name": "UserPromptSubmit"])
        out("\u{1B}]0;\u{25D0} Terminess agent\u{07}")
        var reply = ""
        var turns = 0, cutoffs = 0
        while true {
            if let budget = tokenBudget, let p = provider as? OpenAIChatProvider, p.usedTokens >= budget {
                out("\(red)Stopped at the token budget: \(p.usedTokens) of \(budget) tokens used (--token-budget).\(reset)\n")
                record(["type": "assistant", "text": "(Stopped at the token budget.)"])
                finished = false
                break
            }
            if turns > 0, turns % 20 == 0, let p = provider as? OpenAIChatProvider {
                out("\(dim)Tokens so far: \(p.inputTokens) in, \(p.outputTokens) out, after \(turns) requests.\(reset)\n")
            }
            if turns >= maxTurns {
                out("\(red)Stopped after \(maxTurns) model requests (--max-turns).\(reset)\n")
                record(["type": "assistant", "text": "(Stopped after \(maxTurns) model requests.)"])
                finished = false
                break
            }
            turns += 1
            var shown = false, thinking = false
            let t = provider.turn(system: system) { piece, isThinking in
                if isThinking != thinking { out(isThinking ? dim : reset); thinking = isThinking }
                if !shown && !isThinking { out("\n"); shown = true }
                out(piece)
            }
            out(reset + (shown ? "\n" : ""))
            if let e = t.error { out("\(red)\(e)\(reset)\n"); record(["type": "assistant", "text": "(\(e))"]); finished = false; break }
            if !t.text.isEmpty || !t.thinking.isEmpty { record(["type": "assistant", "text": t.text, "thinking": t.thinking]) }
            reply = t.text
            if t.stopReason == "refusal" { out("\(red)The model declined this request.\(reset)\n"); finished = false; break }
            if t.stopReason == "max_tokens" {
                if let p = provider as? OpenAIChatProvider, cutoffs < 3 {
                    cutoffs += 1
                    out("\(dim)The reply hit the length limit; asking the model to act (\(cutoffs) of 3).\(reset)\n")
                    p.continueAfterCutoff()
                    continue
                }
                out("\(red)The reply hit the length limit.\(reset)\n"); finished = false; break
            }
            cutoffs = 0
            guard !t.calls.isEmpty else { break }
            var results: [AgentToolResult] = []
            for c in t.calls {
                out("\(cyan)\u{25B8} \(c.name)\(reset) \(dim)\(AgentTools.summary(c).prefix(160))\(reset)\n")
                let decision = approve(c)
                let r = decision == "allow" ? AgentTools.run(c, cwd: cwd)
                    : AgentToolResult(id: c.id, name: c.name, text: "The person declined this. Don't try it again another way; ask or carry on.", isError: true)
                results.append(r)
                record(["type": "tool", "name": c.name, "summary": AgentTools.summary(c), "result": String(r.text.prefix(4000))])
            }
            provider.addResults(results)
        }
        report(["hook_event_name": "Stop", "last_assistant_message": reply])
        out("\u{1B}]0;\u{2733} Terminess agent\u{07}")
        return finished
    }

    if once {
        let task = words.joined(separator: " ")
        guard !task.isEmpty else { fail("--once needs a task") }
        let ok = run(task)
        if let p = provider as? OpenAIChatProvider, p.inputTokens + p.outputTokens > 0 {
            out("\(dim)Tokens: \(p.inputTokens) in, \(p.outputTokens) out.\(reset)\n")
        }
        exit(ok ? 0 : 1)
    }

    out("\(bold)Terminess agent\(reset) \(dim)\(provider.label) in \(cwd). Approvals: \(mode == "off" ? "ask for edits and commands" : mode == "edits" ? "edits allowed, commands ask" : "everything allowed").\n")
    out("/model M, /auto off|edits|all, /clear, /bye.\(reset)\n")
    var pending = words.joined(separator: " ")
    while true {
        let text: String
        if !pending.isEmpty { text = pending; pending = ""; out("\(cyan)\u{203A}\(reset) \(text)\n") }
        else {
            out("\n\(cyan)\u{203A}\(reset) ")
            guard let line = readLine(strippingNewline: true) else { break }
            text = line.trimmingCharacters(in: .whitespaces)
        }
        if text.isEmpty { continue }
        if text == "/bye" || text == "/exit" { break }
        if text == "/clear" { provider.clear(); out("\(dim)Starting afresh.\(reset)\n"); continue }
        if text.hasPrefix("/auto ") {
            let m = String(text.dropFirst(6)); if ["off", "edits", "all"].contains(m) { mode = m; out("\(dim)Approvals: \(m).\(reset)\n") }
            continue
        }
        if text.hasPrefix("/model ") {
            if let p = makeProvider(String(text.dropFirst(7))) { provider = p; out("\(dim)Now using \(p.label), starting afresh.\(reset)\n") }
            continue
        }
        run(text)
    }
    exit(0)
}
