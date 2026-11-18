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

    var body: some View {
        let _ = PerfCounters.tick("body.tabStrip")
        let tabs = self.tabs
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                items(tabs)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { items(tabs) }
                        .onAppear { proxy.scrollTo(owner) }
                        .onChange(of: tabs.count) { _, _ in proxy.scrollTo(owner) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Button { NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil) } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .regular))
                    .frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New tab (Cmd-T)")
            if tabs.count > 1 {
                Menu {
                    ForEach(tabs) { tab in
                        Button((tab.attention ? "\u{25CF} " : "") + tab.title) { model.actions?.focusTab(tab.id) }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("All tabs in this window")
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private func items(_ tabs: [OpenTab]) -> some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                TabItem(tab: tab, active: tab.id == owner, closable: tabs.count > 1)
                    .id(tab.id)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 16)
            }
        }
    }
}

private struct TabItem: View {
    let tab: OpenTab
    let active: Bool
    let closable: Bool
    @State private var hovering = false
    @State private var dropTarget = false

    private var agent: Agent? { Agent.detect(tab.command) }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if tab.busy && !tab.attention {
                    WorkingMark(tint: .secondary)
                } else {
                    Image(systemName: tab.parked ? "moon.zzz" : (agent != nil ? "sparkle" : "apple.terminal"))
                        .font(.system(size: 11))
                        .foregroundStyle(agent.map { Color(nsColor: $0.tint) } ?? .secondary)
                }
            }
            .frame(width: 14)
            Text(tab.title)
                .font(.system(size: 12.5, weight: active ? .medium : .regular))
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            ZStack {
                if hovering && closable {
                    Button { SidebarModel.shared.actions?.closeTab(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close tab (Cmd-W)")
                } else if tab.attention {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).help("Needs you")
                }
            }
            .frame(width: 16)
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 30)
        .background(Rectangle().fill(Color.primary.opacity(active ? 0.075 : (hovering ? 0.035 : 0))))
        .overlay(alignment: .leading) {
            if dropTarget { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { if !active { SidebarModel.shared.actions?.focusTab(tab.id) } })
        .onHover { hovering = $0 }
        .help([tab.title, tab.directory].filter { !$0.isEmpty }.joined(separator: "\n"))
        .contextMenu {
            Button("Rename…") { SidebarModel.shared.actions?.renameTab(tab.id) }
            Button("Close Tab") { SidebarModel.shared.actions?.closeTab(tab.id) }
        }
        .onDrag { NSItemProvider(object: TabDrag.string(tab.id) as NSString) }
        .onDrop(of: [.plainText], isTargeted: $dropTarget) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let moving = SidebarModel.shared.tabs.first(where: { TabDrag.string($0.id) == s })?.id,
                              moving != tab.id else { return }
                        (NSApp.delegate as? AppDelegate)?.reorderTab(moving, before: tab.id)
                    }
                }
            }
            return true
        }
    }
}

enum TabDrag {
    static func string(_ id: ObjectIdentifier) -> String { "terminess-tab:\(UInt(bitPattern: id.hashValue))" }
}
