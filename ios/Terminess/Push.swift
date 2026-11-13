import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class PushTokens: ObservableObject {
    static let shared = PushTokens()
    @Published private(set) var token: String?

    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func set(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var path: [UUID] = []
    @Published var pendingSession: (host: UUID, session: String)?

    func open(host: UUID, session: String?) {
        path = [host]
        if let session { pendingSession = (host, session) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushTokens.shared.set(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let host = (info["host"] as? String).flatMap(UUID.init(uuidString:))
        let session = info["session"] as? String
        Task { @MainActor in
            if let host { Router.shared.open(host: host, session: session) }
            completionHandler()
        }
    }
}
