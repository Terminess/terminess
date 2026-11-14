import SwiftUI
import TermHost

struct ApprovalBar: View {
    let request: PermissionInfo
    let agent: String
    let answer: (String) -> Void

    private var verb: String {
        switch request.tool {
        case "Bash", "Shell", "exec_command": return "run"
        case "Write": return "create"
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
