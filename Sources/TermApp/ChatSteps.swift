import TermTranscript
import SwiftUI

enum ChatLayout {
    static func margin(_ width: CGFloat) -> CGFloat {
        guard width > 0 else { return 90 }
        return min(90, max(16, (width - 520) / 4))
    }
    static func textTrailing(_ width: CGFloat) -> CGFloat { width <= 0 || width >= 880 ? 80 : 24 }
    static let textLeading: CGFloat = 20
    static let textSize: CGFloat = 15
    static let gap: CGFloat = 28
}

private struct ChatInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
}

extension EnvironmentValues {
    var chatTextInsets: EdgeInsets {
        get { self[ChatInsetsKey.self] }
        set { self[ChatInsetsKey.self] = newValue }
    }
}

struct StepsGroup: View {
    let steps: [TranscriptItem]
    var folder: String?
    @State private var open = false
    @Environment(\.chatTextInsets) private var insets

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(ChatRow.summary(steps)).lineLimit(1)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: ChatLayout.textSize))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the steps" : "Show each step")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { ItemView(item: $0, folder: folder) }
                }
            }
        }
        .padding(.leading, insets.leading)
    }
}
