import Foundation
import TermHost

enum MCPServer {
    static let tools: [[String: Any]] = [
        ["name": "open_tab",
         "description": "Open a new Terminess tab next to this one, optionally running a command (for example a dev server or tests) in a folder. The person sees it straight away.",
         "inputSchema": ["type": "object", "properties": [
            "command": ["type": "string", "description": "Shell command to run in the new tab; leave out for a plain shell"],
            "directory": ["type": "string", "description": "Folder to open in; defaults to this session's folder"],
            "title": ["type": "string", "description": "Tab title"]]]],
        ["name": "start_worktree",
         "description": "Create a git worktree (its own branch and working copy of this repository) and open it in a Terminess tab with Claude Code, Codex or a shell, optionally starting it on a task. Use it to work on something in parallel without touching this copy.",
         "inputSchema": ["type": "object", "required": ["branch"], "properties": [
            "branch": ["type": "string", "description": "New branch name, for example agent/fix-login"],
            "agent": ["type": "string", "enum": ["claude", "codex", "shell"], "description": "What runs in the new tab (default claude)"],
            "task": ["type": "string", "description": "First message for the agent in the new tab"]]]],
        ["name": "notify",
         "description": "Tell the person something important (finished a long job, found a problem) with a notification on their Mac and phone. Don't use it for routine progress.",
         "inputSchema": ["type": "object", "required": ["message"], "properties": [
            "message": ["type": "string", "description": "One or two sentences"]]]],
        ["name": "remind",
         "description": "Schedule a reminder for the person to pick this work back up later (for example \"10pm: switch on the firewall\"). At that time they get a notification on their Mac and phone with a button; pressing it types action_prompt into this session, or resumes this conversation in a new session if this one has ended. Use it whenever the person says to do something later, instead of relying on the chat staying open.",
         "inputSchema": ["type": "object", "required": ["at", "title"], "properties": [
            "at": ["type": "string", "description": "When: 22:00 (today, or tomorrow if passed), +2h, +90m, or 2026-11-17T22:00; this machine's time zone unless an offset is given"],
            "title": ["type": "string", "description": "Short title shown in the notification, for example Switch on the prod-server firewall"],
            "body": ["type": "string", "description": "One or two sentences of context"],
            "action_prompt": ["type": "string", "description": "What to type into the session when the person presses the button, for example: It's 10pm, go ahead with the firewall switch-on and run the checks"],
            "action_label": ["type": "string", "description": "Button label (default Proceed)"]]]],
        ["name": "borrow",
         "description": "Hand a task to the person's Mac when it needs something only the Mac has: their logged-in Chrome (Claude in Chrome), Mac apps or files there. The Terminess app on the Mac asks the person to allow it, runs it with a local Claude Code and returns its final answer here. Only works while Terminess is open on their Mac. Keep the task self-contained: say exactly what to look at or do and what to report back.",
         "inputSchema": ["type": "object", "required": ["task"], "properties": [
            "task": ["type": "string", "description": "What the Mac should do and what to report back, for example: Open https://example.com/dashboard in Chrome (logged in) and report the numbers on the Billing card"]]]],
        ["name": "ask_user",
         "description": "Ask the person a question and wait for the answer, which they can give on their Mac or phone. Offer choices when there are a few clear options. Waits up to nine minutes; if nobody answers, carry on with your best judgement or stop and explain.",
         "inputSchema": ["type": "object", "required": ["question"], "properties": [
            "question": ["type": "string"],
            "choices": ["type": "array", "items": ["type": "string"], "description": "Up to five short options"]]]],
    ]

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            guard id != nil else { continue }
            switch method {
            case "initialize":
                let params = msg["params"] as? [String: Any] ?? [:]
                reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                           "capabilities": ["tools": [:]],
                           "serverInfo": ["name": "terminess", "version": "1"],
                           "instructions": "Tools for working inside Terminess: open tabs, start worktree tabs, notify the person, ask them a question, schedule a reminder that brings them back to this work later, and borrow the person's Mac for a task only it can do (their Chrome, Mac apps)."])
            case "ping":
                reply(id, [:])
            case "tools/list":
                reply(id, ["tools": tools])
            case "tools/call":
                let params = msg["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                let (text, failed) = call(name, args)
                reply(id, ["content": [["type": "text", "text": text]], "isError": failed])
            default:
                let err: [String: Any] = ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "unknown method \(method)"]]
                write(err)
            }
        }
        exit(0)
    }

    private static func reply(_ id: Any?, _ result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    private static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        guard tools.contains(where: { $0["name"] as? String == name }) else { return ("Unknown tool \(name).", true) }
        guard let session = ProcessInfo.processInfo.environment["TERMINESS_SESSION"], !session.isEmpty else {
            return ("This only works for an agent running inside Terminess.", true)
        }
        guard let fd = UnixSocket.connect(HostPaths.socket) else { return ("The Terminess service isn't running.", true) }
        defer { close(fd) }
        let json = (try? JSONSerialization.data(withJSONObject: args)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        guard Connection.writeAll(fd, Wire.Frame.control(Message(op: "agent-tool", id: session, name: name, message: json)).encoded()) else {
            return ("Couldn't reach the Terminess service.", true)
        }
        var decoder = Wire.Decoder()
        var buf = [UInt8](repeating: 0, count: 16384)
        let deadline = Date().addingTimeInterval(name == "ask_user" ? 560 : name == "borrow" ? 960 : 60)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 1000) >= 0 else { break }
            guard p.revents != 0 else { continue }
            let n = read(fd, &buf, buf.count)
            guard n > 0, let frames = try? decoder.feed(Array(buf[0..<n])) else { break }
            if let m = frames.compactMap(\.message).first(where: { $0.op == "agent-result" }) {
                return (m.message ?? "", m.code == 1)
            }
        }
        return (name == "ask_user" ? "No answer came. Carry on with your best judgement, or stop and explain what you need." : "Terminess didn't answer in time.", name != "ask_user")
    }
}
