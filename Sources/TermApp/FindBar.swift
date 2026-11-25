import AppKit

@MainActor
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let regexButton = NSButton()
    private let caseButton = NSButton()

    var onChange: ((String, Bool, Bool) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    var regex: Bool { regexButton.state == .on }
    var caseSensitive: Bool { caseButton.state == .on }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        field.placeholderString = "Find"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        field.font = .systemFont(ofSize: 12)

        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right

        func toggle(_ b: NSButton, _ title: String, _ tip: String) {
            b.setButtonType(.pushOnPushOff)
            b.isBordered = false
            b.title = title
            b.contentTintColor = .secondaryLabelColor
            b.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            b.toolTip = tip
            b.target = self
            b.action = #selector(changed)
        }
        toggle(regexButton, ".*", "Regular expression")
        toggle(caseButton, "Aa", "Match case")

        func icon(_ name: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.toolTip = tip
            return b
        }
        let prev = icon("chevron.up", "Previous  \u{21E7}\u{2318}G", #selector(previous))
        let next = icon("chevron.down", "Next  \u{2318}G", #selector(nextMatch))
        let close = icon("xmark", "Close  \u{238B}", #selector(close))

        let stack = NSStackView(views: [field, count, caseButton, regexButton, prev, next, close])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 180),
            count.widthAnchor.constraint(equalToConstant: 64),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setCount(current: Int?, total: Int, valid: Bool) {
        if !valid { count.stringValue = "invalid"; return }
        if field.stringValue.isEmpty { count.stringValue = ""; return }
        count.stringValue = total == 0 ? "no matches" : "\((current ?? 0) + 1) of \(total)"
    }

    @objc private func changed() {
        for b in [regexButton, caseButton] {
            b.contentTintColor = b.state == .on ? .controlAccentColor : .secondaryLabelColor
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: b.state == .on ? .bold : .medium),
                .foregroundColor: b.state == .on ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ])
        }
        onChange?(field.stringValue, regex, caseSensitive)
    }
    @objc private func nextMatch() { onNext?() }
    @objc private func previous() { onPrevious?() }
    @objc private func close() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.shift) { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
