import SwiftUI
import UIKit

enum Appearance: String, CaseIterable, Identifiable {
    case system, dark, offBlack, light, paper

    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: return "System"
        case .dark: return "Black"
        case .offBlack: return "Off-black"
        case .light: return "White"
        case .paper: return "Paper"
        }
    }

    func resolved(_ scheme: ColorScheme) -> Appearance {
        self == .system ? (scheme == .dark ? .dark : .light) : self
    }

    var isDark: Bool { self == .dark || self == .offBlack || (self == .system && UITraitCollection.current.userInterfaceStyle == .dark) }
}

enum Theme {
    static var appearance: Appearance = .dark

    private static func pick(dark: Color, offBlack: Color, light: Color, paper: Color) -> Color {
        switch appearance {
        case .dark, .system: return dark
        case .offBlack: return offBlack
        case .light: return light
        case .paper: return paper
        }
    }

    static var background: Color { pick(dark: .black, offBlack: Color(red: 0.086, green: 0.086, blue: 0.094),
                                        light: .white, paper: Color(red: 0.976, green: 0.965, blue: 0.937)) }
    static var surface: Color { pick(dark: Color(white: 0.12), offBlack: Color(red: 0.15, green: 0.15, blue: 0.16),
                                     light: Color(white: 0.945), paper: Color(red: 0.93, green: 0.915, blue: 0.88)) }
    static var raised: Color { pick(dark: Color(white: 0.18), offBlack: Color(red: 0.21, green: 0.21, blue: 0.22),
                                    light: Color(white: 0.89), paper: Color(red: 0.88, green: 0.86, blue: 0.82)) }
    static var ink: Color { pick(dark: .white, offBlack: Color(white: 0.93),
                                 light: .black, paper: Color(red: 0.16, green: 0.145, blue: 0.12)) }
    static var onInk: Color { background }
    static var userBubble: Color { pick(dark: Color(red: 0.106, green: 0.133, blue: 0.196),
                                        offBlack: Color(red: 0.13, green: 0.16, blue: 0.23),
                                        light: Color(red: 0.89, green: 0.92, blue: 0.98),
                                        paper: Color(red: 0.87, green: 0.89, blue: 0.93)) }
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
            .foregroundStyle(Theme.ink)
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
            StarShape().frame(width: size * 0.744, height: size * 0.744)
            RoundedRectangle(cornerRadius: size * 0.02)
                .frame(width: size * 0.349, height: size * 0.074)
                .offset(x: size * 0.783, y: size * 0.664)
        }
        .frame(width: size * 1.132, height: size * 0.744, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2, k = 0.30 * r
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        func side(_ to: CGPoint, _ h: CGPoint) { p.addCurve(to: to, control1: h, control2: h) }
        side(CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x + k, y: c.y - k))
        side(CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + k, y: c.y + k))
        side(CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x - k, y: c.y + k))
        side(CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - k, y: c.y - k))
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
                Capsule().fill(Theme.ink.opacity(0.15)).frame(width: 22, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(percent > 0.8 ? Theme.attention : Theme.ink.opacity(0.7))
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
