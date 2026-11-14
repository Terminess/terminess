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


final class ChatReply: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var content = "", thinking = "", error: String?
    private var buffer = Data()
    let finished = DispatchSemaphore(value: 0)
    var onText: ((String, Bool) -> Void)?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let e = obj["error"] as? String { error = e; continue }
            let m = obj["message"] as? [String: Any] ?? [:]
            if let t = m["thinking"] as? String, !t.isEmpty { thinking += t; onText?(t, true) }
            if let c = m["content"] as? String, !c.isEmpty { content += c; onText?(c, false) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled { self.error = self.error ?? error.localizedDescription }
        finished.signal()
    }
}

func chat(_ args: [String]) -> Never {
    guard let model = args.first, !model.hasPrefix("-") else { fail("usage: terminessd chat MODEL [first message]") }
    let env = ProcessInfo.processInfo.environment
    let context = Int(env["TERMINESS_CHAT_CONTEXT"] ?? "") ?? 16384
    var think = false
    var messages: [[String: String]] = []
    var pending = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let path = LocalChat.newPath(session: env["TERMINESS_SESSION"])

    func record(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
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
    record(["type": "meta", "model": model, "cwd": FileManager.default.currentDirectoryPath,
            "started": Date().timeIntervalSince1970])

    let dim = "\u{1B}[2m", bold = "\u{1B}[1m", red = "\u{1B}[31m", reset = "\u{1B}[0m"
    func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
    func title(working: Bool) { out("\u{1B}]0;\(working ? "◐" : "✳") \(model)\u{07}") }
    title(working: false)

    var saved = termios()
    let isTTY = isatty(0) == 1
    if isTTY {
        tcgetattr(0, &saved)
        var t = saved
        t.c_lflag &= ~tcflag_t(ECHOCTL)
        tcsetattr(0, TCSANOW, &t)
        out("\u{1B}[?2004h")
    }
    func finish(_ code: Int32) -> Never {
        if isTTY { out("\u{1B}[?2004l"); tcsetattr(0, TCSANOW, &saved) }
        exit(code)
    }

    signal(SIGINT, SIG_IGN)
    var current: URLSessionDataTask?
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { current?.cancel() }
    interrupt.resume()

    let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "this machine"
    out("\(dim)\(model) on \(host), remembering about \(context / 1000)k tokens. /think shows its reasoning, /clear starts afresh, /bye ends.\(reset)\n")

    func readMessage() -> String? {
        out("\n\(bold)›\(reset) ")
        guard var line = readLine(strippingNewline: true) else { return nil }
        guard line.contains("\u{1B}[200~") else { return line }
        var lines = [line.replacingOccurrences(of: "\u{1B}[200~", with: "")]
        while !lines.last!.contains("\u{1B}[201~"), let next = readLine(strippingNewline: true) { lines.append(next) }
        line = lines.joined(separator: "\n").replacingOccurrences(of: "\u{1B}[201~", with: "")
        return line
    }

    while true {
        let text: String
        if !pending.isEmpty {
            text = pending
            pending = ""
            out("\n\(bold)›\(reset) \(text)\n")
        } else {
            guard let line = readMessage() else { out("\n"); finish(0) }
            text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch text {
        case "": continue
        case "/bye", "/exit", "/quit": finish(0)
        case "/think":
            think.toggle()
            out("\(dim)Reasoning \(think ? "shown (slower)" : "off").\(reset)\n")
            continue
        case "/clear":
            messages = []
            out("\(dim)Starting afresh; earlier messages are forgotten.\(reset)\n")
            continue
        default: break
        }
        messages.append(["role": "user", "content": text])
        record(["type": "user", "text": text])
        report(["hook_event_name": "UserPromptSubmit", "transcript_path": path])

        var body: [String: Any] = ["model": model, "messages": messages, "stream": true, "think": think,
                                   "options": ["num_ctx": context]]
        var reply = ChatReply()
        var thinkingShown = false
        func send() {
            reply = ChatReply()
            var lastSaved = Date()
            reply.onText = { [weak reply] t, isThinking in
                if let reply, Date().timeIntervalSince(lastSaved) > 1 {
                    lastSaved = Date()
                    record(["type": "partial", "text": reply.content, "thinking": reply.thinking])
                }
                if isThinking { out(dim + t + reset) ; thinkingShown = true }
                else {
                    if thinkingShown { out("\n\n"); thinkingShown = false }
                    out(t)
                }
            }
            guard let url = URL(string: LocalModels.base + "/api/chat"),
                  let data = try? JSONSerialization.data(withJSONObject: body) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = data
            req.timeoutInterval = 600
            let session = URLSession(configuration: .default, delegate: reply, delegateQueue: nil)
            let task = session.dataTask(with: req)
            current = task
            task.resume()
            reply.finished.wait()
            current = nil
            session.finishTasksAndInvalidate()
        }
        out("\n")
        title(working: true)
        send()
        if let e = reply.error, e.lowercased().contains("think"), reply.content.isEmpty {
            body["think"] = nil
            send()
        }
        title(working: false)
        if let e = reply.error {
            record(["type": "partial", "text": "", "thinking": ""])
            out("\n\(red)\(e)\(reset)\n")
            messages.removeLast()
            report(["hook_event_name": "StopFailure", "transcript_path": path])
            continue
        }
        if reply.content.isEmpty && reply.thinking.isEmpty {
            record(["type": "partial", "text": "", "thinking": ""])
            out("\(dim)[stopped]\(reset)\n")
            messages.removeLast()
            report(["hook_event_name": "SessionStart", "transcript_path": path])
            continue
        }
        out("\n")
        messages.append(["role": "assistant", "content": reply.content])
        var entry: [String: Any] = ["type": "assistant", "text": reply.content]
        if !reply.thinking.isEmpty { entry["thinking"] = reply.thinking }
        record(entry)
        report(["hook_event_name": "Stop", "transcript_path": path, "last_assistant_message": reply.content])
    }
}
