import SwiftUI
import TermTranscript

struct ChatView: View {
    @ObservedObject var chat: ChatModel
    let agentName: String
    let working: Bool
    var folder: String? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.loaded && chat.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                            Text(agentName.isEmpty ? "No agent in this session" : "No messages yet").font(.headline).foregroundStyle(.secondary)
                            Text(agentName.isEmpty ? "Start Claude Code or Codex and the conversation appears here."
                                                   : "Send a message and the conversation appears here.")
                                .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    ForEach(chat.items) { item in
                        ChatItemView(item: item, folder: folder).id(item.id)
                    }
                    if working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(agentName.isEmpty ? "The agent" : agentName) is working…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.items.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: working) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }
}

private struct ChatItemView: View {
    let item: TranscriptItem
    var folder: String?
    @State private var open = false

    private func short(_ s: String) -> String {
        var out = s
        if let f = folder, f.count > 1 { out = out.replacingOccurrences(of: f + "/", with: "") }
        return out.replacingOccurrences(of: #"/(Users|home)/[^/\s'"]+"#, with: "~", options: .regularExpression)
    }

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.userBubble))
                    .foregroundStyle(Theme.ink)
            }
        case .assistant(let text):
            MarkdownView(text: text, codeSize: 13)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let text):
            folded(icon: "brain", title: "Thinking", detail: text)
        case .tool(let name, let summary, let detail, let result):
            folded(icon: icon(for: name), title: name + (summary.isEmpty ? "" : "  " + short(summary)),
                   detail: [detail, result.map { "Result:\n" + $0 }].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    private func folded(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
                    Text(title).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if open {
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 0.5))
    }

    private func icon(for tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "exec", "exec_command", "shell": return "terminal"
        case "read": return "doc.text"
        case "edit", "write", "multiedit", "apply_patch": return "pencil"
        case "grep", "glob", "search": return "magnifyingglass"
        case "webfetch", "websearch": return "globe"
        case "task", "agent": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }
}
