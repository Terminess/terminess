import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TabStripView: View {
    private var model: SidebarModel { SidebarModel.shared }
    @ObservedObject var gate: ViewGate
    let owner: ObjectIdentifier
    let group: () -> ObjectIdentifier?

    private var tabs: [OpenTab] {
        let g = group()
        let mine = model.tabs.filter { g != nil && $0.group == g }
        return mine.isEmpty ? model.tabs.filter { $0.id == owner } : mine
    }

    private var current: OpenTab? { model.tabs.first { $0.id == owner } }

    @State private var editing = false
    @State private var draft = ""
    @State private var hoveringName = false
    @State private var cursorPushed = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let _ = PerfCounters.tick("body.tabStrip")
        let tab = current
        let agent = tab.flatMap { Agent.detect($0.command, title: $0.terminalTitle) }
        HStack(spacing: 4) {
            if let agent {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(Color(nsColor: agent.tint))
                    Text(agent.name).foregroundStyle(.secondary)
                }
                .font(.system(size: 14))
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .fixedSize()
            }
            name(tab)
                .padding(.leading, agent == nil ? 6 : -6)
            Menu {
                if let tab {
                    Button("Rename\u{2026}") { model.actions?.renameTab(tab.id) }
                    Toggle("Notify My Phone", isOn: Binding(get: { model.notifies(tab) },
                                                           set: { model.setNotify(tab, $0) }))
                    if tab.machineID == nil, !tab.directory.isEmpty {
                        Divider()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.directory)])
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(tab.directory, forType: .string)
                        }
                    }
                    Divider()
                }
                Button("New Session") { NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil) }
                if let tab {
                    Button("Close") { model.actions?.closeTab(tab.id) }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
            .hoverIcon()
            .help("Options for this session")
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

extension TabStripView {
    @ViewBuilder
    private func name(_ tab: OpenTab?) -> some View {
        if editing, let tab {
            TextField("Automatic name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($fieldFocused)
                .onSubmit { finishRename(tab, keep: true) }
                .onExitCommand { finishRename(tab, keep: false) }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused && editing { finishRename(tab, keep: true) }
                }
                .frame(minWidth: 120, maxWidth: 360)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(tab?.title ?? "New session")
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hoveringName && tab != nil ? 0.08 : 0)))
                .contentShape(Rectangle())
                .onHover { inside in
                    hoveringName = inside
                    if inside && tab != nil && !cursorPushed { NSCursor.iBeam.push(); cursorPushed = true }
                    if !inside { popCursor() }
                }
                .onDisappear { hoveringName = false; popCursor() }
                .onTapGesture {
                    guard let tab else { return }
                    draft = model.actions?.tabName(tab.id) ?? tab.title
                    hoveringName = false
                    popCursor()
                    editing = true
                    DispatchQueue.main.async { fieldFocused = true }
                }
                .help(tab == nil ? "" : "Click to rename")
        }
    }

    private func popCursor() {
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    private func finishRename(_ tab: OpenTab, keep: Bool) {
        guard editing else { return }
        editing = false
        if keep, draft != model.actions?.tabName(tab.id) { model.actions?.setTabName(tab.id, draft) }
    }
}

enum TabDrag {
    static func string(_ id: ObjectIdentifier) -> String { "terminess-tab:\(UInt(bitPattern: id.hashValue))" }
}
