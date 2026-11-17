import AppKit
import CryptoKit
import SwiftUI
import TermTranscript

enum HistoryImport {
    static let agents = ["claude", "codex", "gemini"]
    private static let key = "history.imported"

    static func name(_ agent: String) -> String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        default: return agent
        }
    }

    static var imported: Set<String> {
        if let forced = ProcessInfo.processInfo.environment["TERMAPP_IMPORTED"] {
            return Set(forced.split(separator: ",").map(String.init))
        }
        let d = UserDefaults.standard
        if let list = d.stringArray(forKey: key) { return Set(list) }
        let earlier = d.object(forKey: "viewMode") != nil || d.object(forKey: "NSWindow Frame TerminalWindow") != nil
        let start: Set<String> = earlier ? ["claude", "codex"] : []
        d.set(Array(start).sorted(), forKey: key)
        return start
    }

    static func markImported(_ agent: String) {
        var now = imported
        now.insert(agent)
        UserDefaults.standard.set(Array(now).sorted(), forKey: key)
    }

    nonisolated static func counts(candidates: [String]) -> [String: Int] {
        let fm = FileManager.default
        let home = Transcript.home
        var out: [String: Int] = [:]
        var claude = 0
        let projects = home + "/.claude/projects"
        for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            claude += ((try? fm.contentsOfDirectory(atPath: projects + "/" + dir)) ?? []).filter { $0.hasSuffix(".jsonl") }.count
        }
        out["claude"] = claude
        var codex = 0
        if let walk = fm.enumerator(atPath: home + "/.codex/sessions") {
            for case let f as String in walk where (f as NSString).lastPathComponent.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                codex += 1
            }
        }
        out["codex"] = codex
        out["gemini"] = GeminiHistory.list(candidates: candidates).count
        return out
    }
}

enum GeminiHistory {
    struct Message: Hashable { let fromUser: Bool; let text: String }
    struct Conversation: Identifiable, Hashable {
        let id: String
        let cwd: String
        let title: String
        let used: Double
        let resumable: Bool
        let messages: [Message]
    }

    static var root: String { Transcript.home + "/.gemini/tmp" }

    nonisolated static func hash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func folders(_ candidates: [String]) -> [String: String] {
        let fm = FileManager.default
        let home = Transcript.home
        var paths = Set(candidates + [home])
        for parent in ["github", "code", "src", "Projects", "Developer"] {
            let p = home + "/" + parent
            for c in (try? fm.contentsOfDirectory(atPath: p)) ?? [] { paths.insert(p + "/" + c) }
        }
        var out: [String: String] = [:]
        for p in paths { out[hash(p)] = p }
        return out
    }

    nonisolated static func list(candidates: [String]) -> [Conversation] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let known = folders(candidates)
        var out: [Conversation] = []
        for dir in dirs {
            let base = root + "/" + dir
            let marker = (try? String(contentsOfFile: base + "/.project_root", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = marker ?? known[dir] ?? Transcript.home
            var seen = Set<String>()
            let chats = base + "/chats"
            for f in (try? fm.contentsOfDirectory(atPath: chats)) ?? [] where f.hasPrefix("session-") && f.hasSuffix(".json") {
                guard let c = chat(chats + "/" + f, cwd: cwd) else { continue }
                seen.insert(c.id)
                out.append(c)
            }
            out += logs(base + "/logs.json", cwd: cwd).filter { !seen.contains($0.id) }
        }
        return out.sorted { $0.used > $1.used }
    }

    nonisolated private static func date(_ s: Any?) -> Double? {
        guard let s = s as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s))?.timeIntervalSince1970
    }

    nonisolated private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }

    nonisolated private static func title(_ messages: [Message]) -> String {
        let first = messages.first { $0.fromUser && !$0.text.hasPrefix("/") }?.text ?? ""
        let line = first.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    nonisolated private static func chat(_ path: String, cwd: String) -> Conversation? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["sessionId"] as? String else { return nil }
        let messages = (obj["messages"] as? [[String: Any]] ?? []).compactMap { m -> Message? in
            let t = text(m["content"])
            guard !t.isEmpty, let type = m["type"] as? String, type == "user" || type == "gemini" else { return nil }
            return Message(fromUser: type == "user", text: t)
        }
        let name = title(messages)
        guard !name.isEmpty else { return nil }
        let used = date(obj["lastUpdated"]) ?? date(obj["startTime"]) ?? Transcript.mtime(path)?.timeIntervalSince1970 ?? 0
        return Conversation(id: id, cwd: cwd, title: name, used: used, resumable: true, messages: messages)
    }

    nonisolated private static func logs(_ path: String, cwd: String) -> [Conversation] {
        guard let data = FileManager.default.contents(atPath: path),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var order: [String] = []
        var byID: [String: (messages: [Message], used: Double)] = [:]
        for entry in list {
            guard let id = entry["sessionId"] as? String, entry["type"] as? String == "user",
                  let message = entry["message"] as? String, !message.isEmpty else { continue }
            if byID[id] == nil { order.append(id); byID[id] = ([], 0) }
            byID[id]!.messages.append(Message(fromUser: true, text: message))
            byID[id]!.used = max(byID[id]!.used, date(entry["timestamp"]) ?? 0)
        }
        return order.compactMap { id in
            guard let s = byID[id] else { return nil }
            let name = title(s.messages)
            guard !name.isEmpty else { return nil }
            return Conversation(id: id, cwd: cwd, title: name, used: s.used, resumable: false, messages: s.messages)
        }
    }
}

@MainActor
enum GeminiReader {
    private static var windows: [NSWindow] = []

    static func show(_ c: GeminiHistory.Conversation) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: GeminiReaderView(conversation: c)))
        w.title = c.title
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 560, height: 520))
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
    }
}

struct GeminiReaderView: View {
    let conversation: GeminiHistory.Conversation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Read only: this conversation was saved by a Gemini CLI that only kept your prompts, so it can't be resumed.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array(conversation.messages.enumerated()), id: \.offset) { _, m in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.fromUser ? "You" : "Gemini").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(m.text).textSelection(.enabled).font(.system(size: 13))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 300)
    }
}
