import SwiftUI
import UIKit

struct TerminalScreen: View {
    @ObservedObject var model: ScreenModel

    var body: some View {
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
            .onAppear {
                model.terminalVisible = true
                fit(geo.size)
            }
            .onDisappear { model.terminalVisible = false }
            .onChange(of: geo.size) { _, size in fit(size) }
        }
        .background(model.background)
    }

    private func fit(_ size: CGSize) {
        guard size.width > 50, size.height > 50 else { return }
        let g = model.grid(for: size)
        model.resize(cols: g.cols, rows: g.rows)
    }
}

enum ImageShrinker {
    static func jpeg(_ data: Data, maxSide: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
