import AppKit
import Combine
import SwiftUI


let chromeHeaderHeight: CGFloat = 40
let trafficLightsWidth: CGFloat = 78

@MainActor func chromeTopInset(_ window: NSWindow?) -> CGFloat { chromeHeaderHeight }

extension NSColor {
    static let sidebarPane = NSColor(name: "sidebarPane") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.105, alpha: 1)
            : NSColor(white: 0.955, alpha: 1)
    }
    static let whatsNew = NSColor(name: "whatsNew") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.655, green: 0.545, blue: 0.980, alpha: 1)
            : NSColor(srgbRed: 0.486, green: 0.361, blue: 0.839, alpha: 1)
    }
}

final class HeaderIconButton: NSButton {
    var isActive = false { didSet { needsDisplay = true; updateTint() } }
    private var hovering = false { didSet { needsDisplay = true; updateTint() } }

    init(symbol: String, tooltip: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 26))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        toolTip = tooltip
        self.target = target
        self.action = action
        updateTint()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 26) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    private var pressed = false { didSet { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside, let action {
            let sent = NSApp.sendAction(action, to: target, from: self)
            if ProcessInfo.processInfo.environment["TERMAPP_CLICK_AT"] != nil {
                print("click: header button sent \(NSStringFromSelector(action)): \(sent)"); fflush(stdout)
            }
        }
    }

    private func updateTint() { contentTintColor = isActive || hovering ? .labelColor : .secondaryLabelColor }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        if isActive || hovering || pressed {
            NSColor.labelColor.withAlphaComponent(isActive || pressed ? 0.10 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

final class SidebarPaneController: NSViewController {
    private let content: NSView
    init(content: NSView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let pane = SidebarPaneView()
        pane.content = content
        pane.addSubview(content)
        pane.addSubview(pane.toggle)
        view = pane
    }
}

final class SidebarPaneView: NSView {
    var content: NSView?
    let toggle = HeaderIconButton(symbol: "sidebar.left", tooltip: "Hide the sidebar (Control-Command-S)",
                                  target: nil, action: #selector(AppDelegate.showHideSidebar(_:)))
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.sidebarPane.setFill()
        dirtyRect.fill()
    }
    override func layout() {
        super.layout()
        let top = chromeTopInset(window)
        let t = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: trafficLightsWidth, y: (chromeHeaderHeight - t.height) / 2, width: t.width, height: t.height)
        content?.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }
}

final class ContentHeaderView: NSView {
    let toggle: HeaderIconButton
    let whatsNew = NSButton(title: "What\u{2019}s new", target: nil, action: nil)
    let modeButtons: [HeaderIconButton]
    private let strip: NSView
    private var stripLeading: NSLayoutConstraint!

    var sidebarHidden = false {
        didSet {
            toggle.isHidden = !sidebarHidden
            stripLeading.constant = sidebarHidden ? trafficLightsWidth + 34 : 0
        }
    }

    init(controller: TerminalWindowController) {
        toggle = HeaderIconButton(symbol: "sidebar.left", tooltip: "Show the sidebar (Control-Command-S)",
                                  target: nil, action: #selector(AppDelegate.showHideSidebar(_:)))
        modeButtons = [
            HeaderIconButton(symbol: "apple.terminal", tooltip: "Terminal (Option-Command-1)",
                             target: controller, action: #selector(TerminalWindowController.showTerminalMode(_:))),
            HeaderIconButton(symbol: "rectangle.split.2x1", tooltip: "Terminal and Chat (Option-Command-2)",
                             target: controller, action: #selector(TerminalWindowController.showSplitMode(_:))),
            HeaderIconButton(symbol: "text.bubble", tooltip: "Chat (Option-Command-3)",
                             target: controller, action: #selector(TerminalWindowController.showChatMode(_:))),
        ]
        let owner = ObjectIdentifier(controller)
        let host = TabStripHostingView(rootView: TabStripView(gate: controller.gate, owner: owner, group: { [weak controller] in
            controller?.window?.tabGroup.map { ObjectIdentifier($0) }
        }))
        host.sizingOptions = []
        host.safeAreaRegions = []
        strip = host
        super.init(frame: .zero)
        whatsNew.isBordered = false
        whatsNew.attributedTitle = NSAttributedString(string: "What\u{2019}s new", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.whatsNew])
        whatsNew.target = controller
        whatsNew.action = #selector(TerminalWindowController.showWhatsNew(_:))
        whatsNew.toolTip = "What changed in this version of Terminess"
        whatsNew.setContentCompressionResistancePriority(.required, for: .horizontal)
        let modes = NSStackView(views: modeButtons)
        modes.spacing = 2
        let right = NSStackView(views: [whatsNew, modes])
        right.spacing = 12
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        strip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        strip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [strip, toggle, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        stripLeading = strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: trafficLightsWidth),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            stripLeading,
            strip.centerYAnchor.constraint(equalTo: centerYAnchor),
            strip.heightAnchor.constraint(equalToConstant: 30),
            strip.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -12).withPriority(999),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12).withPriority(999),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toggle.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { true }

    func setMode(_ index: Int) {
        for (i, b) in modeButtons.enumerated() { b.isActive = i == index }
    }
}

final class RootView: NSView {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    var fill: NSColor? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let fill else { return }
        fill.setFill()
        dirtyRect.fill()
    }
    var overlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let overlay {
                overlay.frame = bounds
                overlay.autoresizingMask = [.width, .height]
                addSubview(overlay)
            }
        }
    }
}

final class RootViewController: NSViewController {
    let split: NSSplitViewController
    init(split: NSSplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = RootView()
        addChild(split)
        split.view.frame = root.bounds
        split.view.autoresizingMask = [.width, .height]
        root.addSubview(split.view)
        view = root
    }
}

extension View {
    @ViewBuilder func noTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

final class TabStripHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ViewGate: ObservableObject {
    private var subscription: AnyCancellable?
    private var missed = false
    var active = true {
        didSet {
            guard active != oldValue else { return }
            if active && missed { missed = false; objectWillChange.send() }
        }
    }

    init() {
        subscription = SidebarModel.shared.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.active { self.objectWillChange.send() } else { self.missed = true }
            }
        }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: Float) -> NSLayoutConstraint {
        priority = NSLayoutConstraint.Priority(p)
        return self
    }
}

final class PageGapView: NSView {
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
