import SwiftUI
import TermHost
import TermCore

struct ApprovalBar: View {
    let request: PermissionInfo
    let agent: String
    let answer: (String) -> Void

    private var verb: String {
        switch request.tool {
        case "Bash", "Shell", "exec_command": return "run"
        case "Write": return "write"
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch": return "edit"
        case "WebFetch": return "open"
        case "WebSearch": return "search for"
        default: return "use \(request.tool) on"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(agent) wants to \(verb)").font(.callout.weight(.semibold))
                Text(request.summary.isEmpty ? request.tool : request.summary)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("Deny") { answer("deny") }.keyboardShortcut(.escape, modifiers: [.command])
            if request.canAlways {
                Button("Always Allow") { answer("always") }
                    .help("Allow this and remember the rule the agent suggested, as its own prompt would.")
            }
            Button("Allow") { answer("allow") }.keyboardShortcut(.return, modifiers: [.command]).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}


struct QuestionBar: View {
    let question: QuestionInfo
    let agent: String
    let answer: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(agent) asks").font(.caption).foregroundStyle(.secondary)
                    Text(question.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                ForEach(question.choices, id: \.self) { c in Button(c) { answer(c) } }
                TextField(question.choices.isEmpty ? "Your answer" : "Or write an answer", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !text.isEmpty { answer(text) } }
                Button("Send") { answer(text) }.disabled(text.isEmpty).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue.opacity(0.3)))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

struct NoticeBar: View {
    let text: String
    var openNewest: (() -> Void)? = nil
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 8)
            if let openNewest {
                Button("Open newest", action: openNewest).buttonStyle(.link)
                    .help("Open the newest conversation in this folder in a new tab")
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10)))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

struct MenuBar: View {
    let menu: ScreenMenu
    let agent: String
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "list.bullet.circle.fill").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(agent) is waiting on a choice").font(.callout.weight(.semibold))
                    ForEach(Array(menu.text.prefix(4).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(menu.options.enumerated()), id: \.offset) { i, option in
                    if i == menu.selected {
                        Button(option) { choose(i) }.buttonStyle(.borderedProminent).lineLimit(1)
                    } else {
                        Button(option) { choose(i) }.lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}


struct WaitingBar: View {
    let lines: [String]
    let agent: String
    let key: (Key) -> Void
    let type: (String) -> Void
    let showTerminal: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.title3)
                Text("\(agent) is waiting for you").font(.callout.weight(.semibold))
                Spacer()
                Button("Show Terminal", action: showTerminal).buttonStyle(.link)
            }
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            HStack(spacing: 6) {
                keyButton("arrow.up", .up, "Up")
                keyButton("arrow.down", .down, "Down")
                keyButton("arrow.left", .left, "Left")
                keyButton("arrow.right", .right, "Right")
                Button("Tab") { key(.tab) }
                Button("Esc") { key(.escape) }
                Button("Enter") { key(.enter) }.buttonStyle(.borderedProminent)
                TextField("Type an answer", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !text.isEmpty { type(text); text = "" } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func keyButton(_ symbol: String, _ k: Key, _ help: String) -> some View {
        Button { key(k) } label: { Image(systemName: symbol) }.help(help)
    }
}
