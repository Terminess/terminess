import AppKit
import SwiftUI
import TermHost

@MainActor
final class RemindersPageState: ObservableObject {
    static let shared = RemindersPageState()
    enum Tab: String { case upcoming = "Upcoming", done = "Done" }
    @Published var tab: Tab = .upcoming
    @Published var query = ""
    @Published var detail: String?
    @Published var draft: ReminderDraft?
}

struct ReminderDraft: Equatable {
    var machineID = ""
    var sessionID = ""
    var when = "+1h"
    var title = ""
    var prompt = ""
    var replacing: String?
    var replacingMachine: String?
}

enum ReminderHistory {
    struct Entry: Codable, Identifiable, Equatable {
        var id: String
        var title: String
        var due: Double
        var machine: String
        var outcome: String
        var at: Double
    }
    private static let key = "reminders.done"

    static var all: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static func record(_ r: ReminderInfo, machine: RemoteMachine?, outcome: String) {
        var list = all.filter { $0.id != r.id }
        list.insert(Entry(id: r.id, title: r.title, due: r.due, machine: machine?.name ?? "This Mac",
                          outcome: outcome, at: Date().timeIntervalSince1970), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(50))) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum ReminderText {
    static func relative(_ due: Double, fired: Bool = false) -> String {
        let left = due - Date().timeIntervalSince1970
        if fired || left <= 0 { return "due" }
        if left < 3600 { return "in \(max(1, Int(left / 60)))m" }
        if left < 86400 { return "in \(Int((left / 3600).rounded()))h" }
        return "in \(Int((left / 86400).rounded()))d"
    }
}

@MainActor
enum ReminderSaver {
    static func save(_ d: ReminderDraft, done: @escaping (String?) -> Void) {
        guard let due = ReminderTime.parse(d.when) else { done("Try a time like +2h, 22:00 or 2026-11-18 09:00."); return }
        let r = ReminderInfo(id: "", title: d.title.trimmingCharacters(in: .whitespaces), due: due.timeIntervalSince1970,
                             actionPrompt: d.prompt.isEmpty ? nil : d.prompt,
                             sessionId: d.sessionID.isEmpty ? nil : d.sessionID, created: Date().timeIntervalSince1970)
        var m = Message(op: "remind-add")
        m.reminder = r
        let replacing = d.replacing, oldMachine = d.replacingMachine
        func dropOld() {
            guard let replacing else { return }
            let machine = RemoteMachines.all.first { $0.id == oldMachine }
            ReminderCenter.shared.dismiss(replacing, machine: machine, remember: false)
        }
        if !d.machineID.isEmpty {
            guard let monitor = SidebarModel.shared.monitor(d.machineID) else { done("That machine isn't connected."); return }
            monitor.send(m)
            dropOld()
            done(nil)
            return
        }
        Task { @MainActor in
            let problem: String? = await Task.detached(priority: .userInitiated) {
                let reply = HostAttachment.request(m, expecting: ["reminder-added", "error"], timeout: 3)
                return reply?.op == "reminder-added" ? nil : (reply?.message ?? "Couldn't reach the Terminess service.")
            }.value
            if problem == nil {
                dropOld()
                SidebarModel.shared.refreshBackground()
            }
            done(problem)
        }
    }
}

final class RemindersHostView: NSHostingView<RemindersPage> {}

struct RemindersPage: View {
    let onClose: () -> Void
    @ObservedObject private var model = SidebarModel.shared
    @ObservedObject private var state = RemindersPageState.shared

    private var upcoming: [(machine: RemoteMachine?, reminder: ReminderInfo)] {
        let words = state.query.lowercased().split(separator: " ").map(String.init)
        return model.allReminders.filter { e in
            let hay = "\(e.reminder.title) \(e.reminder.body ?? "") \(e.machine?.name ?? "This Mac")".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let draft = state.draft {
                        ReminderForm(draft: draft)
                    } else if let key = state.detail, let entry = entry(key) {
                        backButton
                        ReminderDetailView(reminder: entry.reminder, machine: entry.machine,
                                           close: { state.detail = nil },
                                           edit: { edit(entry.reminder, entry.machine) })
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pageCard()
                    } else {
                        header
                        tabs
                        if state.tab == .upcoming { upcomingList } else { doneList }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Reminders (Esc)")
            .keyboardShortcut(.cancelAction)
            .padding(.top, 14).padding(.trailing, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .noTopScrollEdge()
    }

    private func entry(_ key: String) -> (machine: RemoteMachine?, reminder: ReminderInfo)? {
        model.allReminders.first { "\($0.machine?.id ?? "")/\($0.reminder.id)" == key }
    }

    private func edit(_ r: ReminderInfo, _ m: RemoteMachine?) {
        var d = ReminderDraft()
        d.machineID = m?.id ?? ""
        d.sessionID = r.sessionId ?? ""
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        d.when = f.string(from: Date(timeIntervalSince1970: r.due))
        d.title = r.title
        d.prompt = r.actionPrompt ?? ""
        d.replacing = r.id
        d.replacingMachine = m?.id
        state.detail = nil
        state.draft = d
    }

    private var backButton: some View {
        Button { state.detail = nil } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text("Reminders")
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Reminders").font(.system(size: 26, weight: .semibold))
            Spacer()
            Button { state.draft = ReminderDraft() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("New reminder").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 30)
        }
    }

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach([RemindersPageState.Tab.upcoming, .done], id: \.self) { t in
                Button { state.tab = t } label: {
                    VStack(spacing: 6) {
                        Text(t.rawValue + (t == .upcoming && !model.allReminders.isEmpty ? " \(model.allReminders.count)" : ""))
                            .font(.system(size: 13, weight: state.tab == t ? .medium : .regular))
                            .foregroundStyle(state.tab == t ? .primary : .secondary)
                        Rectangle().fill(state.tab == t ? Color.primary : .clear).frame(height: 1.5)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search", text: $state.query).textFieldStyle(.plain).font(.system(size: 12.5))
            }
            .padding(.horizontal, 8).frame(width: 190, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).offset(y: 0) }
    }

    @ViewBuilder private var upcomingList: some View {
        let list = upcoming
        if list.isEmpty {
            if state.query.isEmpty { emptyState } else {
                Text("No reminders match \u{201C}\(state.query)\u{201D}.").foregroundStyle(.secondary).padding(.top, 8)
            }
            templates
        } else {
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.reminder.id) { i, e in
                    if i > 0 { Divider().padding(.leading, 44) }
                    ReminderRow(reminder: e.reminder, machine: e.machine) {
                        state.detail = "\(e.machine?.id ?? "")/\(e.reminder.id)"
                    }
                }
            }
            .pageCard(padding: 0)
            templates
        }
    }

    private var doneList: some View {
        let words = state.query.lowercased().split(separator: " ").map(String.init)
        let list = ReminderHistory.all.filter { e in words.allSatisfy { "\(e.title) \(e.machine)".lowercased().contains($0) } }
        return Group {
            if list.isEmpty {
                Text("Reminders you proceed with or dismiss show here.").foregroundStyle(.secondary).padding(.top, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider().padding(.leading, 44) }
                        HStack(spacing: 12) {
                            Image(systemName: e.outcome == "proceeded" ? "checkmark.circle" : "xmark.circle")
                                .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(.system(size: 13.5))
                                Text("\(e.outcome == "proceeded" ? "Proceeded" : "Dismissed") \(ReminderDetailView.when(e.at)) · \(e.machine)")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
                .pageCard(padding: 0)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.05)).frame(width: 84, height: 84)
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 1).frame(width: 84, height: 84)
                Image(systemName: "clock").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Image(systemName: "bell.fill").font(.system(size: 13)).foregroundStyle(Color(nsColor: .whatsNew))
                    .offset(x: 30, y: -28)
            }
            Text("No reminders yet").font(.system(size: 15, weight: .medium))
            Text("Ask an agent to remind you, or set one here. When it goes off, Proceed picks the work back up in its session.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private struct Template: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let when: String
        let shown: String
        let prompt: String
    }

    private var templateList: [Template] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 10:00"
        let cal = Calendar.current
        let monday = cal.nextDate(after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? Date()
        return [
            Template(id: "morning", symbol: "sun.max", title: "Morning check-in",
                     detail: "Ask the agent what changed overnight and what's next.", when: "09:00", shown: "Tomorrow 09:00",
                     prompt: "Good morning. Summarise what changed since yesterday and suggest what to do next."),
            Template(id: "ship", symbol: "shippingbox", title: "Ship check before release",
                     detail: "Run the tests and review the diff before you tag.", when: "17:00", shown: "Today 17:00",
                     prompt: "Run the full test suite and review the diff since the last release. List anything that blocks shipping."),
            Template(id: "follow", symbol: "hourglass", title: "Follow up a long-running agent",
                     detail: "Check back on a long task and nudge it if it stalled.", when: "+2h", shown: "In 2 hours",
                     prompt: "How is the task going? If you're stuck, say what's blocking you."),
            Template(id: "deps", symbol: "checklist", title: "Weekly dependency audit",
                     detail: "Look for outdated or vulnerable packages.", when: f.string(from: monday), shown: "Monday 10:00",
                     prompt: "Check this project's dependencies for outdated or vulnerable packages and propose upgrades."),
        ]
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start from a template").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.top, 6)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(templateList) { t in
                    Button {
                        var d = ReminderDraft()
                        d.title = t.title
                        d.when = t.when
                        d.prompt = t.prompt
                        state.draft = d
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: t.symbol).font(.system(size: 15)).foregroundStyle(.secondary)
                            Text(t.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                            Text(t.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 4) {
                                Image(systemName: "clock").font(.system(size: 10))
                                Text(t.shown).font(.system(size: 11))
                            }
                            .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                        .padding(14)
                        .contentShape(Rectangle())
                        .pageCard(padding: 0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ReminderRow: View {
    let reminder: ReminderInfo
    let machine: RemoteMachine?
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        let due = reminder.fired == true
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: due ? "bell.badge.fill" : "clock")
                    .font(.system(size: 14)).foregroundStyle(due ? Color.orange : .secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.title).font(.system(size: 13.5)).foregroundStyle(.primary)
                    Text([ReminderDetailView.when(reminder.due), machine?.name ?? "This Mac", reminder.body]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(ReminderText.relative(reminder.due, fired: due))
                    .font(.system(size: 12)).foregroundStyle(due ? Color.orange : .secondary)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ReminderForm: View {
    @State var draft: ReminderDraft
    @ObservedObject private var model = SidebarModel.shared
    @State private var problem: String?
    @State private var saving = false

    private var sessions: [SessionInfo] {
        draft.machineID.isEmpty
            ? model.localSessions.values.sorted { $0.created > $1.created }
            : model.remote.first { $0.id == draft.machineID }?.sessions ?? []
    }

    private var parsed: Date? { ReminderTime.parse(draft.when) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { RemindersPageState.shared.draft = nil } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Reminders")
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Text(draft.replacing == nil ? "New reminder" : "Edit reminder").font(.system(size: 26, weight: .semibold))
            Form {
                Section {
                    LabeledContent("Machine") {
                        Picker("Machine", selection: $draft.machineID) {
                            Label("This Mac", systemImage: "laptopcomputer").tag("")
                            ForEach(model.remote) { r in
                                Label(r.displayName, systemImage: r.symbol).tag(r.id)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    LabeledContent("Session") {
                        Picker("Session", selection: $draft.sessionID) {
                            Text("None, start fresh").tag("")
                            ForEach(sessions, id: \.id) { s in
                                Text(SessionNames.title(s)).tag(s.id)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    LabeledContent {
                        HStack(spacing: 8) {
                            TextField("When", text: $draft.when, prompt: Text("+2h, 22:00 or 2026-11-18 09:00"))
                                .labelsHidden().frame(width: 200)
                            Menu("Quick") {
                                Button("In 30 minutes") { draft.when = "+30m" }
                                Button("In 1 hour") { draft.when = "+1h" }
                                Button("In 2 hours") { draft.when = "+2h" }
                                Button("Tomorrow at 09:00") { draft.when = "09:00" }
                            }
                            .fixedSize()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("When")
                            Text(parsed.map { ReminderDetailView.when($0.timeIntervalSince1970) } ?? "Not a time yet")
                                .font(.system(size: 11.5)).foregroundStyle(parsed == nil ? Color.orange : .secondary)
                        }
                    }
                    TextField("Title", text: $draft.title, prompt: Text("What it's about"))
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Follow-up prompt")
                        Text("Proceed types this into the session (or a fresh one in the same folder).")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        TextEditor(text: $draft.prompt)
                            .font(.system(size: 13))
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(minHeight: 420)
            .padding(.horizontal, -20)
            HStack {
                if let problem { Text(problem).font(.callout).foregroundStyle(.orange) }
                Spacer()
                Button("Cancel") { RemindersPageState.shared.draft = nil }
                Button(draft.replacing == nil ? "Set Reminder" : "Save") {
                    saving = true
                    ReminderSaver.save(draft) { err in
                        saving = false
                        problem = err
                        if err == nil { RemindersPageState.shared.draft = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || draft.title.trimmingCharacters(in: .whitespaces).isEmpty || parsed == nil)
            }
        }
    }
}

extension View {
    func pageCard(padding: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.09), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
