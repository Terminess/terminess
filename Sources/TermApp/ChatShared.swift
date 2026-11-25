import TermTranscript
import SwiftUI


enum ChatTint {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.36, green: 0.62, blue: 0.95)
    static func of(_ agent: String) -> Color { agent.lowercased().contains("codex") ? codex : claude }
}

enum ChatRow: Identifiable {
    case item(TranscriptItem)
    case steps([TranscriptItem])
    case done(TranscriptItem)

    var id: Int {
        switch self {
        case .item(let i), .done(let i): return i.id
        case .steps(let s): return -(s.first?.id ?? 0) - 1
        }
    }

    static func rows(_ items: [TranscriptItem]) -> [ChatRow] {
        var out: [ChatRow] = []
        var run: [TranscriptItem] = []
        for item in items {
            if item.turnDone != nil {
                if !run.isEmpty { out.append(.steps(run)); run = [] }
                out.append(.done(item))
                continue
            }
            switch item.kind {
            case .tool, .thinking:
                run.append(item)
            case .user, .assistant:
                if !run.isEmpty { out.append(.steps(run)); run = [] }
                out.append(.item(item))
            }
        }
        if !run.isEmpty { out.append(.steps(run)) }
        return out
    }

    static func summary(_ steps: [TranscriptItem]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var others: [String] = []
        for step in steps {
            let key: String
            switch step.kind {
            case .thinking: key = "think"
            case .tool(let name, _, _, _):
                let k = kind(name)
                if k == "other" {
                    let n = terminessTool(name)?.did ?? ("used " + pretty(name))
                    if !others.contains(n) { others.append(n) }
                }
                key = k
            default: continue
            }
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let parts: [String] = order.map { key in
            let n = counts[key] ?? 0
            switch key {
            case "bash": return n == 1 ? "ran a command" : "ran \(n) commands"
            case "read": return n == 1 ? "read a file" : "read \(n) files"
            case "edit": return n == 1 ? "edited a file" : "edited \(n) files"
            case "search": return n == 1 ? "searched" : "searched \(n) times"
            case "fetch": return n == 1 ? "fetched a page" : "fetched \(n) pages"
            case "web": return "searched the web"
            case "agent": return n == 1 ? "ran an agent" : "ran \(n) agents"
            case "tools": return "loaded tools"
            case "todo": return "updated the to-do list"
            case "think": return "thought"
            default: return others.count <= 2 ? others.joined(separator: " and ") : "used \(others.count) tools"
            }
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func activity(_ items: [TranscriptItem], short: (String) -> String = { $0 }) -> String {
        guard let last = items.last, last.turnDone == nil else { return "Thinking" }
        switch last.kind {
        case .tool(let name, let summary, _, _):
            let what = short(summary.components(separatedBy: "\n").first ?? "")
            let verb: String
            switch kind(name) {
            case "bash": verb = "Running"
            case "read": verb = "Reading"
            case "edit": verb = "Editing"
            case "search": verb = "Searching"
            case "fetch": verb = "Fetching"
            case "web": verb = "Searching the web for"
            case "agent": verb = "Running an agent:"
            case "tools": verb = "Loading tools"
            case "todo": return "Updating the to-do list"
            default:
                if let plain = terminessTool(name)?.doing { return plain }
                verb = pretty(name).prefix(1).uppercased() + pretty(name).dropFirst()
            }
            return what.isEmpty ? verb : verb + " " + what
        default:
            return "Thinking"
        }
    }

    private static func kind(_ tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "exec", "exec_command", "shell", "bashoutput": return "bash"
        case "read", "view", "notebookread": return "read"
        case "edit", "write", "multiedit", "apply_patch", "notebookedit": return "edit"
        case "grep", "glob", "search", "ls": return "search"
        case "webfetch": return "fetch"
        case "websearch", "web_search": return "web"
        case "task", "agent": return "agent"
        case "toolsearch": return "tools"
        case "todowrite", "update_plan": return "todo"
        default: return "other"
        }
    }

    private static func terminessTool(_ tool: String) -> (doing: String, did: String)? {
        guard tool.hasPrefix("mcp__terminess__") || tool.hasPrefix("terminess.") else { return nil }
        let name = tool.components(separatedBy: tool.contains("__") ? "__" : ".").last ?? ""
        switch name {
        case "borrow": return ("Working on your Mac", "worked on your Mac")
        case "copy_from_mac": return ("Copying a file from your Mac", "copied a file from your Mac")
        case "notify": return ("Sending you a notification", "sent you a notification")
        case "ask_user": return ("Asking you", "asked you")
        case "remind": return ("Setting a reminder", "set a reminder")
        case "open_tab": return ("Opening a tab", "opened a tab")
        case "start_worktree": return ("Starting a worktree", "started a worktree")
        default: return nil
        }
    }

    private static func pretty(_ tool: String) -> String {
        if tool.hasPrefix("mcp__"), let last = tool.components(separatedBy: "__").last, !last.isEmpty {
            return last.replacingOccurrences(of: "_", with: " ")
        }
        return tool
    }
}

struct WorkingLine: View {
    let activity: String
    let started: Date
    let tint: Color
    var size: CGFloat = 14

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(started)))
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: size - 1, weight: .semibold))
                    .foregroundStyle(tint)
                    .rotationEffect(.degrees(Double(seconds) * 90))
                    .animation(.easeInOut(duration: 0.4), value: seconds)
                Text(activity)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                Text(WorkingLine.elapsed(seconds))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: size))
        }
    }

    static func elapsed(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}

struct DoneLine: View {
    let item: TranscriptItem
    var extra: String? = nil
    var size: CGFloat = 13

    var body: some View {
        if let done = item.turnDone {
            Text(([done.worked, DoneLine.time(done.ended).map { "done " + $0 }, extra].compactMap { $0 })
                    .joined(separator: " \u{00B7} "))
                .font(.system(size: size))
                .foregroundStyle(.tertiary)
        }
    }

    static func time(_ iso: String) -> String? {
        let parse = ISO8601DateFormatter()
        parse.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parse.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        return f.string(from: date)
    }
}
