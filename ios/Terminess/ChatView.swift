import SwiftUI
import TermTranscript

struct ChatView: View {
    @ObservedObject var chat: ChatModel
    let agentName: String
    let working: Bool
    var folder: String? = nil
    var notice: String? = nil
    var pending: String? = nil
    @State private var turnStart: Date?

    private var waitingFor: String? {
        guard let pending, !pending.isEmpty else { return nil }
        let arrived = chat.items.contains { if case .user = $0.kind { return true } else { return false } }
        return arrived ? nil : pending
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let text = waitingFor {
                        ChatItemView(item: TranscriptItem(id: -1, kind: .user(text)), folder: folder)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Starting \(agentName.isEmpty ? "the agent" : agentName)…").font(.callout).foregroundStyle(.secondary)
                        }
                    } else if chat.loaded && chat.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                            Text(agentName.isEmpty ? "No agent in this session" : "No messages yet").font(.headline).foregroundStyle(.secondary)
                            Text(agentName.isEmpty ? "Start Claude Code or Codex and the conversation appears here."
                                                   : "Send a message and the conversation appears here.")
                                .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    if let notice {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text(notice)
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(ChatRow.rows(chat.items)) { row in
                        switch row {
                        case .item(let item):
                            ChatItemView(item: item, folder: folder).id(item.id)
                        case .steps(let steps):
                            PhoneStepsGroup(steps: steps, folder: folder).id(row.id)
                        case .done(let item):
                            DoneLine(item: item).padding(.horizontal, 10).id(row.id)
                        }
                    }
                    if working && waitingFor == nil {
                        WorkingLine(activity: ChatRow.activity(chat.items, short: { ChatItemView.short($0, folder: folder) }),
                                    started: turnStart ?? Date(), tint: ChatTint.of(agentName), size: 15)
                            .padding(.horizontal, 10)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.items.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: working) { _, now in
                if now && turnStart == nil { turnStart = Date() }
                if !now { turnStart = nil }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { if working && turnStart == nil { turnStart = Date() } }
        }
    }
}

private struct PhoneStepsGroup: View {
    let steps: [TranscriptItem]
    var folder: String?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Text(ChatRow.summary(steps)).lineLimit(1)
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { ChatItemView(item: $0, folder: folder) }
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

private struct ChatItemView: View {
    let item: TranscriptItem
    var folder: String?
    @State private var open = false

    private func short(_ s: String) -> String { Self.short(s, folder: folder) }

    static func short(_ s: String, folder: String?) -> String {
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
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.userBubble))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.vertical, 8)
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
