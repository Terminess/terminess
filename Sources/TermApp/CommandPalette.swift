import AppKit
import SwiftUI
import TermHost

struct CommandPalette: View {
    weak var controller: TerminalWindowController?
    let onClose: () -> Void
    @ObservedObject private var model = SidebarModel.shared
    @State private var query = ""
    @State private var type = 0
    @State private var selected = 0
    @FocusState private var focused: Bool

    private static let types = ["All", "Sessions", "Projects", "Machines", "Reminders"]

    struct Item: Identifiable {
        let id: String
        let kind: Int
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let run: @MainActor () -> Void
    }


    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    private var sessions: [Item] {
        let tabs = model.tabs.map { t in
            Item(id: "tab:\(t.title)\(t.id.hashValue)", kind: 1,
                 symbol: Agent.detect(t.command) != nil ? "sparkle" : "apple.terminal",
                 tint: Agent.detect(t.command).map { Color(nsColor: $0.tint) } ?? .secondary,
                 title: t.title, detail: "Open tab", run: { model.actions?.focusTab(t.id) })
        }
        let past = model.sessions.filter { $0.pair == nil }.map { s in
            Item(id: "session:\(s.id)", kind: 1, symbol: "text.bubble", tint: toolTint(s.tool),
                 title: s.title, detail: "\(s.repo) · \(HistoryImport.name(s.tool))", run: { model.actions?.resume(s) })
        }
        return tabs + past
    }

    private var projects: [Item] {
        var seen = Set<String>()
        var out: [Item] = []
        for path in model.sessions.map(\.cwd) + model.tabs.map(\.path) where !path.isEmpty {
            let root = model.repoRoot(path) ?? path
            guard root != SidebarModel.home, seen.insert(root).inserted else { continue }
            out.append(Item(id: "project:\(root)", kind: 2, symbol: "folder", tint: .secondary,
                            title: (root as NSString).lastPathComponent, detail: SidebarModel.tilde(root),
                            run: { _ = (NSApp.delegate as? AppDelegate)?.open(tabbedWith: NSApp.keyWindow, directory: root) }))
        }
        return out
    }

    private var machines: [Item] {
        [Item(id: "machine:local", kind: 3, symbol: "laptopcomputer", tint: .connected, title: "This Mac",
              detail: DeviceIdentity.name, run: { _ = (NSApp.delegate as? AppDelegate)?.open(tabbedWith: NSApp.keyWindow) })]
        + model.remote.map { r in
            Item(id: "machine:\(r.id)", kind: 3, symbol: r.symbol, tint: r.note == nil ? .connected : .secondary,
                 title: r.displayName, detail: r.note == nil ? "connected" : "offline",
                 run: { (NSApp.delegate as? AppDelegate)?.newRemote(r.machine, agent: nil, directory: nil) })
        }
    }

    private var reminders: [Item] {
        model.allReminders.map { e in
            Item(id: "reminder:\(e.machine?.id ?? "")/\(e.reminder.id)", kind: 4,
                 symbol: e.reminder.fired == true ? "bell.badge.fill" : "clock",
                 tint: e.reminder.fired == true ? .orange : .secondary,
                 title: e.reminder.title, detail: ReminderText.relative(e.reminder.due, fired: e.reminder.fired == true),
                 run: {
                     RemindersPageState.shared.detail = "\(e.machine?.id ?? "")/\(e.reminder.id)"
                     (NSApp.delegate as? AppDelegate)?.showReminders(nil)
                 })
        }
    }

    private var actions: [Item] {
        [
            Item(id: "a:new", kind: 0, symbol: "plus", tint: .secondary, title: "New session", detail: "\u{2318}T",
                 run: { NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil) }),
            Item(id: "a:reminder", kind: 0, symbol: "bell", tint: .secondary, title: "New reminder", detail: "",
                 run: {
                     RemindersPageState.shared.draft = ReminderDraft()
                     (NSApp.delegate as? AppDelegate)?.showReminders(nil)
                 }),
            Item(id: "a:settings", kind: 0, symbol: "gearshape", tint: .secondary, title: "Settings", detail: "\u{2318},",
                 run: { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }),
            Item(id: "a:agents", kind: 0, symbol: "sparkles", tint: .secondary, title: "Agents", detail: "",
                 run: { AgentsDashboardWindow.show() }),
            Item(id: "a:library", kind: 0, symbol: "books.vertical", tint: .secondary, title: "Library", detail: "",
                 run: { (NSApp.delegate as? AppDelegate)?.showLibrary(nil) }),
            Item(id: "a:instructions", kind: 0, symbol: "doc.text", tint: .secondary, title: "Instructions", detail: "",
                 run: { (NSApp.delegate as? AppDelegate)?.showProjectInstructions(nil) }),
            Item(id: "a:opsguide", kind: 0, symbol: "book.closed", tint: .secondary, title: "Operations guide", detail: "",
                 run: { OpsGuideWindow.show() }),
            Item(id: "a:pair", kind: 0, symbol: "iphone", tint: .secondary, title: "Pair iPhone", detail: "",
                 run: { (NSApp.delegate as? AppDelegate)?.showPairPhone(nil) }),
        ]
    }

    private func matches(_ item: Item) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let hay = "\(item.title) \(item.detail)".lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    private var groups: [(title: String, items: [Item])] {
        var out: [(String, [Item])] = []
        if query.isEmpty {
            switch type {
            case 0:
                let recent = Array((sessions.filter { $0.detail == "Open tab" } + sessions.filter { $0.detail != "Open tab" }).prefix(7))
                out.append(("Recents", recent))
            case 1: out.append(("Sessions", Array(sessions.prefix(30))))
            case 2: out.append(("Projects", projects))
            case 3: out.append(("Machines", machines))
            default: out.append(("Reminders", reminders))
            }
        } else {
            let pools: [(String, [Item])] = [("Sessions", sessions), ("Projects", projects), ("Machines", machines), ("Reminders", reminders)]
            for (i, pool) in pools.enumerated() where type == 0 || type == i + 1 {
                let found = pool.1.filter(matches)
                if !found.isEmpty { out.append((pool.0, Array(found.prefix(type == 0 ? 6 : 30)))) }
            }
        }
        if type == 0 {
            let acts = query.isEmpty ? actions : actions.filter(matches)
            if !acts.isEmpty { out.append(("Actions", acts)) }
        }
        return out.filter { !$0.1.isEmpty }
    }


    var body: some View {
        let groups = self.groups
        let flat = groups.flatMap(\.items)
        GeometryReader { geo in
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onChange(of: query) { _, _ in selected = 0 }
                        .onKeyPress(.downArrow) { selected = min(selected + 1, max(flat.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                        .onKeyPress(.leftArrow) {
                            guard query.isEmpty else { return .ignored }
                            type = (type + Self.types.count - 1) % Self.types.count; selected = 0; return .handled
                        }
                        .onKeyPress(.rightArrow) {
                            guard query.isEmpty else { return .ignored }
                            type = (type + 1) % Self.types.count; selected = 0; return .handled
                        }
                        .onKeyPress(.tab) { type = (type + 1) % Self.types.count; selected = 0; return .handled }
                        .onKeyPress(keys: [.return]) { press in
                            if press.modifiers.contains(.option) {
                                if let i = flat.firstIndex(where: { $0.kind == 0 }) { selected = i }
                                return .handled
                            }
                            open(flat, selected)
                            return .handled
                        }
                        .onExitCommand { onClose() }
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                HStack(spacing: 4) {
                    ForEach(Array(Self.types.enumerated()), id: \.offset) { i, t in
                        Button { type = i; selected = 0 } label: {
                            Text(t).font(.system(size: 12, weight: type == i ? .medium : .regular))
                                .foregroundStyle(type == i ? .primary : .secondary)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(type == i ? 0.09 : 0)))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if groups.isEmpty {
                                Text("Nothing matches \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
                                    .padding(16)
                            }
                            ForEach(groups, id: \.title) { g in
                                Text(g.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                                ForEach(g.items) { item in
                                    let index = flat.firstIndex { $0.id == item.id } ?? 0
                                    row(item, selected: index == selected)
                                        .id(index)
                                        .onTapGesture { open(flat, index) }
                                        .onHover { if $0 { selected = index } }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selected) { _, s in proxy.scrollTo(s) }
                }
                .frame(maxHeight: min(340, max(120, geo.size.height - 260)))
                Divider()
                HStack(spacing: 16) {
                    hint("Close", "Esc")
                    hint("Change type", "\u{2190} \u{2192}")
                    hint("Actions", "\u{2325}\u{21A9}")
                    Spacer()
                    hint("Open", "\u{21A9}")
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
            }
            .frame(width: 620)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
            .padding(.top, min(90, max(24, geo.size.height * 0.07)))
        }
        }
        .onAppear { focused = true }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).font(.system(size: 13)).foregroundStyle(item.tint).frame(width: 18)
            Text(item.title).font(.system(size: 13.5)).lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            if selected {
                Text("\u{21A9}").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(selected ? 0.08 : 0)))
        .contentShape(Rectangle())
    }

    private func hint(_ label: String, _ key: String) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(key).padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5))
    }

    private func open(_ flat: [Item], _ index: Int) {
        guard flat.indices.contains(index) else { return }
        let item = flat[index]
        onClose()
        item.run()
    }
}
