import AppKit
import SwiftUI


struct PageShell<Side: View, Main: View>: View {
    let onClose: () -> Void
    var scrolls = true
    @ViewBuilder var side: Side
    @ViewBuilder var main: Main

    var body: some View {
        HStack(spacing: 0) {
            if Side.self != EmptyView.self {
                VStack(alignment: .leading, spacing: 2) { side; Spacer(minLength: 0) }
                    .padding(12)
                    .frame(width: 214)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .sidebarPane))
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)
            }
            ZStack(alignment: .topTrailing) {
                if scrolls {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) { main }
                            .frame(maxWidth: 760, alignment: .leading)
                            .padding(.horizontal, 32).padding(.vertical, 26)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) { main }
                        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                PageCloseButton(action: onClose)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .noTopScrollEdge()
    }
}

extension PageShell where Side == EmptyView {
    init(onClose: @escaping () -> Void, scrolls: Bool = true, @ViewBuilder main: () -> Main) {
        self.onClose = onClose
        self.scrolls = scrolls
        self.side = EmptyView()
        self.main = main()
    }
}

struct PageCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close  \u{238B}")
        .keyboardShortcut(.cancelAction)
        .padding(.top, 14).padding(.trailing, 14)
    }
}

struct PageTitle<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.trailing, 30)
    }
}

extension PageTitle where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = EmptyView()
    }
}

struct PageSection<Content: View>: View {
    let title: String
    var count: Int? = nil
    var expanded: Binding<Bool>? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let expanded {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() } } label: { header(expanded.wrappedValue) }
                    .buttonStyle(.plain)
            } else {
                header(nil)
            }
            if expanded?.wrappedValue ?? true { content }
        }
    }

    private func header(_ open: Bool?) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit() }
            if let open {
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 0 : -90))
            }
        }
        .contentShape(Rectangle())
    }
}

struct PageGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        _VariadicView.Tree(GroupLayout()) { content }
            .pageCard(padding: 0)
    }

    private struct GroupLayout: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { i, child in
                    if i > 0 { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 44) }
                    child
                }
            }
        }
    }
}

struct PageRow<Accessory: View>: View {
    let symbol: String
    var tint: Color = .secondary
    let title: String
    var status: (text: String, color: Color)? = nil
    var detail: String? = nil
    var mono: String? = nil
    var dimmed = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13.5)).lineLimit(1)
                        .foregroundStyle(dimmed ? .secondary : .primary)
                    if let status {
                        HStack(spacing: 4) {
                            Circle().fill(status.color).frame(width: 6, height: 6)
                            Text(status.text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let mono, !mono.isEmpty {
                    Text(mono).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { accessory }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

extension PageRow where Accessory == EmptyView {
    init(symbol: String, tint: Color = .secondary, title: String, status: (text: String, color: Color)? = nil,
         detail: String? = nil, mono: String? = nil, dimmed: Bool = false) {
        self.symbol = symbol; self.tint = tint; self.title = title; self.status = status
        self.detail = detail; self.mono = mono; self.dimmed = dimmed
        self.accessory = EmptyView()
    }
}

struct PageSideItem: View {
    let symbol: String
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
                    .foregroundStyle(selected ? .primary : .secondary)
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let count { Text("\(count)").font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).frame(height: 30)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : (hovering ? 0.04 : 0))))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PageSideHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.top, 10).padding(.bottom, 2)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.85 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07)))
            .opacity(enabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

final class PageHostView: NSHostingView<AnyView> {
    var pageID = ""
    var shouldClose: () -> Bool = { true }
}
