import SwiftUI

struct Composer<Chips: View>: View {
    @Binding var text: String
    let placeholder: String
    var busy = false
    var disabled = false
    var focus: FocusState<Bool>.Binding
    let onSend: () -> Void
    var onStop: (() -> Void)?
    var onPhoto: (() -> Void)?
    var onFile: (() -> Void)?
    @ViewBuilder let chips: () -> Chips
    @StateObject private var dictation = Dictation()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...7)
                .focused(focus)
                .font(.system(size: 17))
                .padding(.horizontal, 16).padding(.top, 14)
            HStack(spacing: 8) {
                if onPhoto != nil || onFile != nil {
                    Menu {
                        if let onPhoto { Button(action: onPhoto) { Label("Photo Library", systemImage: "photo") } }
                        if let onFile { Button(action: onFile) { Label("Files", systemImage: "folder") } }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 34)
                    }
                    .disabled(disabled)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { chips() }
                }
                Button {
                    if dictation.listening { dictation.stop() } else { dictation.start(appendingTo: text) { text = $0 } }
                } label: {
                    Image(systemName: dictation.listening ? "waveform" : "mic")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(dictation.listening ? Color.white : Color.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: dictation.listening)
                        .frame(width: 30, height: 34)
                }
                .disabled(disabled)
                if busy && text.isEmpty, let onStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 34, height: 34).background(Circle().fill(.white))
                    }
                } else {
                    Button {
                        dictation.stop()
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(text.isEmpty || disabled ? Color.white.opacity(0.35) : .black)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(text.isEmpty || disabled ? Theme.raised : .white))
                    }
                    .disabled(text.isEmpty || disabled)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .overlay(alignment: .topTrailing) {
            if let problem = dictation.problem {
                Text(problem).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.surface))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }
}
