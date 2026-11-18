import AppKit
import SwiftUI

struct HoverIcon: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
    }
}

extension View {
    func hoverIcon() -> some View { modifier(HoverIcon()) }
}
