import AppKit
import UserNotifications

@MainActor
final class AttentionCenter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = AttentionCenter()

    private var flagged: [ObjectIdentifier: WeakController] = [:]
    private var lastNotified: [ObjectIdentifier: Date] = [:]
    private var authorised = false

    private final class WeakController {
        weak var controller: TerminalWindowController?
        init(_ c: TerminalWindowController) { controller = c }
    }

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func setUp() {
        guard canNotify else { return }
        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        centre.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { AttentionCenter.shared.authorised = granted } }
        }
    }

    func alert(controller: TerminalWindowController, pane: Pane, title: String, body: String, always: Bool = false) {
        let inFront = NSApp.isActive && controller.window?.isKeyWindow == true && controller.focused === pane
        if inFront {
            if body == "Bell" { NSSound.beep() }
            return
        }
        let id = ObjectIdentifier(pane)
        flagged[id] = WeakController(controller)
        controller.updateTabBadge()
        SidebarModel.shared.refreshTabs()
        updateDockBadge()

        if let last = lastNotified[id], Date().timeIntervalSince(last) < 5 { return }
        lastNotified[id] = Date()
        guard canNotify, authorised, !NSApp.isActive || always || body != "Bell" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body == "Bell" ? "Needs your attention" : body
        content.sound = .default
        content.userInfo = ["controller": "\(ObjectIdentifier(controller).hashValue)"]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        NSApp.requestUserAttention(.informationalRequest)
    }

    func clear(pane: Pane) {
        let id = ObjectIdentifier(pane)
        guard let entry = flagged.removeValue(forKey: id) else { return }
        entry.controller?.updateTabBadge()
        SidebarModel.shared.refreshTabs()
        updateDockBadge()
    }

    func needsAttention(_ controller: TerminalWindowController) -> Bool {
        flagged.values.contains { $0.controller === controller }
    }

    private func updateDockBadge() {
        flagged = flagged.filter { $0.value.controller != nil }
        let tabs = Set(flagged.values.compactMap { $0.controller.map(ObjectIdentifier.init) }).count
        NSApp.dockTile.badgeLabel = tabs > 0 ? "\(tabs)" : nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo["controller"] as? String
        if let app = NSApp.delegate as? AppDelegate,
           let c = app.controllers.first(where: { "\(ObjectIdentifier($0).hashValue)" == key }) {
            NSApp.activate(ignoringOtherApps: true)
            c.focus()
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
