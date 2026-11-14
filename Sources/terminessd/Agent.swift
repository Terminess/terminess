#if os(Linux)
import Glibc
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
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return "Couldn't run the shell: \(error.localizedDescription)" }
        var data = Data()
        let reader = DispatchQueue(label: "agent.shell")
        let done = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            return String(decoding: data, as: UTF8.self) + "\n(stopped after \(Int(timeout)) seconds)"
        }
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return (text.isEmpty ? "(no output)" : text) + (p.terminationStatus == 0 ? "" : "\n(exit code \(p.terminationStatus))")
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
    private var messages: [[String: Any]] = []
    private var task: URLSessionDataTask?
    private var parser = AnthropicStream()
    private var onText: ((String, Bool) -> Void)?
    private var httpError: String?
    private var errorBody = Data()
    private let done = DispatchSemaphore(value: 0)

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
            "model": model, "max_tokens": 64000, "stream": true,
            "system": [["type": "text", "text": system]],
            "tools": AgentTools.definitions.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema,
                                                   "eager_input_streaming": true] as [String: Any] },
            "messages": messages,
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": effort],
            "cache_control": ["type": "ephemeral"],
        ]
        if takesFallback { body["fallbacks"] = "default" }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if takesFallback { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.dataTask(with: req)
        task?.resume()
        done.wait()
        session.finishTasksAndInvalidate()
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
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.dataTask(with: req)
        task?.resume()
        done.wait()
        session.finishTasksAndInvalidate()
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


func anthropicKey() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let k = env["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
    let home = env["HOME"] ?? NSHomeDirectory()
    if let k = try? String(contentsOfFile: home + "/.config/terminess/anthropic_key", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
    return nil
}

func agent(_ args: [String]) -> Never {
    var model = "claude-opus-5-5", effort = "high", mode = "off", once = false
    var words: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--model": i += 1; if i < args.count { model = args[i] }
        case "--effort": i += 1; if i < args.count { effort = args[i] }
        case "--auto": i += 1; if i < args.count { mode = args[i] }
        case "--once": once = true
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
        guard let key = anthropicKey() else {
            out("\(red)No Anthropic API key. Add one in Terminess Settings, set ANTHROPIC_API_KEY, or use --model ollama:<model> for a local model.\(reset)\n")
            return nil
        }
        return AnthropicProvider(model: m, effort: effort, key: key)
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
        tests or build when you change code. Commands that change files or the system may need the person's approval. \
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

    func run(_ text: String) {
        provider.addUser(text)
        record(["type": "user", "text": text])
        report(["hook_event_name": "UserPromptSubmit"])
        out("\u{1B}]0;\u{25D0} Terminess agent\u{07}")
        var reply = ""
        for _ in 0..<60 {
            var shown = false, thinking = false
            let t = provider.turn(system: system) { piece, isThinking in
                if isThinking != thinking { out(isThinking ? dim : reset); thinking = isThinking }
                if !shown && !isThinking { out("\n"); shown = true }
                out(piece)
            }
            out(reset + (shown ? "\n" : ""))
            if let e = t.error { out("\(red)\(e)\(reset)\n"); record(["type": "assistant", "text": "(\(e))"]); break }
            if !t.text.isEmpty || !t.thinking.isEmpty { record(["type": "assistant", "text": t.text, "thinking": t.thinking]) }
            reply = t.text
            if t.stopReason == "refusal" { out("\(red)The model declined this request.\(reset)\n"); break }
            if t.stopReason == "max_tokens" { out("\(red)The reply hit the length limit.\(reset)\n"); break }
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
    }

    if once {
        let task = words.joined(separator: " ")
        guard !task.isEmpty else { fail("--once needs a task") }
        run(task)
        exit(0)
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
