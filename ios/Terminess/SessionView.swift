import SwiftUI
import TermCore
import TermHost

struct SessionView: View {
    let connection: HostConnection
    let target: SessionTarget
    @StateObject private var model = ScreenModel()
    @State private var draft = ""
    @State private var error: String?
    @State private var started = false
    @FocusState private var composing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.detach(); dismiss() } label: { Image(systemName: "chevron.down").font(.headline) }
                Text(target.title).font(.headline)
                Spacer()
                if let status = model.status ?? error { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.text)
                            .font(Font(model.font))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .id("screen")
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: model.text) { _, _ in proxy.scrollTo("screen", anchor: .bottom) }
                }
                .task(id: started) {
                    guard !started else { return }
                    started = true
                    let g = model.grid(for: geo.size)
                    do {
                        let t: HostAttachment.Target = target.id.map { .attach(id: $0) }
                            ?? .create(cwd: nil, command: nil, args: [], env: nil, name: nil)
                        let a = try await connection.attachment(to: t, cols: g.cols, rows: g.rows)
                        model.start(a, cols: g.cols, rows: g.rows)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .onChange(of: geo.size) { _, size in
                    let g = model.grid(for: size)
                    model.resize(cols: g.cols, rows: g.rows)
                }
            }
            .background(model.background)

            keyRow
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message or command", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                Button {
                    model.sendLine(draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(model.ended)
            }
            .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 4)
        }
        .onDisappear { model.detach() }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { model.key(.escape) }
                key("tab") { model.key(.tab) }
                key("^C") { model.send([0x03]) }
                key("↑") { model.key(.up) }
                key("↓") { model.key(.down) }
                key("←") { model.key(.left) }
                key("→") { model.key(.right) }
                key("return") { model.send([0x0D]) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func key(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
        }
        .buttonStyle(.plain)
        .disabled(model.ended)
    }
}
