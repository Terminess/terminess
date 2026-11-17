import AppKit
import TermHost
import UserNotifications

@MainActor
final class ReminderCenter {
    static let shared = ReminderCenter()
    static let category = "REMINDER"

    private var notified: Set<String> = []

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: category,
                               actions: [UNNotificationAction(identifier: "PROCEED", title: "Proceed", options: [.foreground]),
                                         UNNotificationAction(identifier: "DISMISS", title: "Dismiss", options: [.destructive])],
                               intentIdentifiers: [])
    }

    private func key(_ id: String, _ machine: RemoteMachine?) -> String { "\(machine?.id ?? "local")/\(id)" }

    func saw(_ reminders: [ReminderInfo], machine: RemoteMachine?) {
        for r in reminders where r.fired == true && !notified.contains(key(r.id, machine)) {
            notified.insert(key(r.id, machine))
            notify(r, machine: machine)
        }
    }

    private func notify(_ r: ReminderInfo, machine: RemoteMachine?) {
        NSApp.requestUserAttention(.informationalRequest)
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.subtitle = machine.map { "Reminder on \($0.name)" } ?? "Reminder"
        if let body = r.body { content.body = body } else if let p = r.actionPrompt { content.body = "\(r.label): \(p)" }
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["reminder": r.id, "machine": machine?.id ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "reminder-" + key(r.id, machine), content: content, trigger: nil))
    }

    func handle(action: String, reminder id: String, machineID: String) {
        let machine = machineID.isEmpty ? nil : RemoteMachines.all.first { $0.id == machineID }
        if !machineID.isEmpty && machine == nil { return }
        if action == "DISMISS" { dismiss(id, machine: machine) } else { proceed(id, machine: machine) }
    }

    func proceed(_ id: String, machine: RemoteMachine?) {
        record(id, machine, "proceeded")
        clearNotification(id, machine)
        NSApp.activate(ignoringOtherApps: true)
        if let machine {
            SidebarModel.shared.monitor(machine.id)?.send(Message(op: "reminder-act", id: id))
            removeShown(id, machine)
            return
        }
        removeShown(id, nil)
        Task.detached(priority: .userInitiated) {
            let reply = HostAttachment.request(Message(op: "reminder-act", id: id), expecting: ["reminder-acted"])
            guard reply?.op == "reminder-acted", let session = reply?.id else { return }
            let info = HostAttachment.list(timeout: 2)?.first { $0.id == session }
            await MainActor.run { ReminderCenter.shared.openLocal(session, cwd: info?.cwd) }
        }
    }

    private func record(_ id: String, _ machine: RemoteMachine?, _ outcome: String) {
        guard let r = SidebarModel.shared.allReminders.first(where: { $0.reminder.id == id && $0.machine?.id == machine?.id })?.reminder
        else { return }
        ReminderHistory.record(r, machine: machine, outcome: outcome)
    }

    func dismiss(_ id: String, machine: RemoteMachine?, remember: Bool = true) {
        if remember { record(id, machine, "dismissed") }
        clearNotification(id, machine)
        removeShown(id, machine)
        if let machine {
            SidebarModel.shared.monitor(machine.id)?.send(Message(op: "reminder-dismiss", id: id))
        } else {
            HostAttachment.send(Message(op: "reminder-dismiss", id: id))
        }
    }

    func acted(session: String, machine: RemoteMachine) {
        let known = SidebarModel.shared.remote.first { $0.id == machine.id }?.sessions.first { $0.id == session }
        let info = known ?? SessionInfo(id: session, name: "", command: "", cwd: "", created: 0, clients: 0)
        SidebarModel.shared.actions?.attachRemote(machine, info)
    }

    private func openLocal(_ session: String, cwd: String?) {
        let model = SidebarModel.shared
        if let tab = model.tabs.first(where: { $0.hostIDs.contains(session) }) { model.actions?.focusTab(tab.id); return }
        model.actions?.attachHost(SessionInfo(id: session, name: "", command: "", cwd: cwd ?? "", created: 0, clients: 0))
    }

    private func removeShown(_ id: String, _ machine: RemoteMachine?) {
        let model = SidebarModel.shared
        if let machine, let i = model.remote.firstIndex(where: { $0.id == machine.id }) {
            model.remote[i].reminders.removeAll { $0.id == id }
        } else if machine == nil {
            model.localReminders.removeAll { $0.id == id }
        }
    }

    private func clearNotification(_ id: String, _ machine: RemoteMachine?) {
        guard canNotify else { return }
        let ident = "reminder-" + key(id, machine)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [ident])
    }
}
