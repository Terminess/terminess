import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    static var pages: [(id: String, label: String, symbol: String)] { SettingsPages.all }

    static let width: CGFloat = 680

    private init() {
        let host = NSHostingController(rootView: SettingsView())
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "Settings"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .preference
        super.init(window: w)

        let toolbar = NSToolbar(identifier: "SettingsPages")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(Self.currentPage)

        w.contentMinSize = NSSize(width: Self.width, height: 360)
        w.contentMaxSize = NSSize(width: Self.width, height: .greatestFiniteMagnitude)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        let saved = UserDefaults.standard.double(forKey: Self.heightKey)
        let height = saved >= 360 ? min(saved, visible - 80) : min(720, visible - 80)
        w.setContentSize(NSSize(width: Self.width, height: height))
        w.center()
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSWindow.didEndLiveResizeNotification, object: w)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static let heightKey = "settingsWindowHeight"
    private static var currentPage: String { UserDefaults.standard.string(forKey: "settingsPage") ?? "appearance" }

    func show() {
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(Self.currentPage)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func resized() {
        guard let w = window else { return }
        UserDefaults.standard.set(w.contentLayoutRect.height, forKey: Self.heightKey)
    }

    @objc private func pick(_ sender: NSToolbarItem) {
        UserDefaults.standard.set(sender.itemIdentifier.rawValue, forKey: "settingsPage")
    }


    private var ids: [NSToolbarItem.Identifier] { Self.pages.map { NSToolbarItem.Identifier($0.id) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = Self.pages.first(where: { $0.id == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = page.label
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.label)
        item.target = self
        item.action = #selector(pick(_:))
        return item
    }
}
