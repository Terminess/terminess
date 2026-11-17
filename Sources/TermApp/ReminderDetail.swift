import SwiftUI
import TermHost

struct ReminderDetailView: View {
    let reminder: ReminderInfo
    let machine: RemoteMachine?
    let close: () -> Void

    private var due: Bool { reminder.fired == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: due ? "bell.badge.fill" : "clock")
                    .foregroundStyle(due ? Color.orange : Color.secondary)
                Text(reminder.title).font(.title3).fontWeight(.semibold)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("When", (due ? "Due since " : "") + Self.when(reminder.due))
                row("Machine", machine?.name ?? "This Mac")
                if let s = reminder.sessionId { row("Session", s) }
                if let cwd = reminder.cwd { row("Folder", cwd) }
                if let agent = reminder.agent {
                    row("Agent", agent == "claude" ? "Claude Code" : (agent == "codex" ? "Codex" : agent))
                }
            }
            if let body = reminder.body, !body.isEmpty {
                Text(body).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("\(reminder.label) types this into the agent:").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(reminder.actionPrompt ?? "Nothing; it opens the session.")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
            HStack {
                Button(due ? "Dismiss" : "Cancel Reminder", role: .destructive) {
                    ReminderCenter.shared.dismiss(reminder.id, machine: machine)
                    close()
                }
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                if due {
                    Button(reminder.label) {
                        ReminderCenter.shared.proceed(reminder.id, machine: machine)
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
    }

    static func when(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'today at' HH:mm" : "EEE d MMM 'at' HH:mm"
        return f.string(from: d)
    }
}

extension Color {
    static let connected = Color(nsColor: NSColor(name: "connected") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.30, green: 0.68, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.50, blue: 0.24, alpha: 1)
    })
}
