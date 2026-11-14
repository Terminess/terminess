import SwiftUI

enum Theme {
    static let background = Color.black
    static let surface = Color(white: 0.12)
    static let raised = Color(white: 0.18)
    static let attention = Color.orange
}

struct CircleButton: View {
    let symbol: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .medium))
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.surface))
        }
        .buttonStyle(.plain)
    }
}

struct DrawerButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Capsule().frame(width: 18, height: 2.2)
                Capsule().frame(width: 18, height: 2.2)
            }
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Menu")
    }
}

struct LogoMark: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack(alignment: .topLeading) {
            StarShape().frame(width: size * 0.62, height: size * 0.62)
            RoundedRectangle(cornerRadius: size * 0.025)
                .frame(width: size * 0.35, height: size * 0.09)
                .offset(x: size * 0.66, y: size * 0.55)
        }
        .frame(width: size * 1.05, height: size * 0.66, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2, k = 0.30 * r
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
        p.closeSubpath()
        return p
    }
}

struct Chip: View {
    let text: String
    var symbol: String?
    var percent: Double?
    var menu: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
            Text(text).lineLimit(1)
            if let percent {
                Capsule().fill(Color.white.opacity(0.15)).frame(width: 22, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(percent > 0.8 ? Theme.attention : Color.white.opacity(0.7))
                            .frame(width: 22 * percent, height: 4)
                    }
            }
            if menu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Theme.raised))
    }
}
