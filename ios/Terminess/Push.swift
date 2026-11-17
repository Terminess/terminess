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

    @Published private(set) var credential: String?
    static let relay = URL(string: "https://push.terminess.com/v1")!
    private var asked: Date?

    init() {
        credential = UserDefaults.standard.string(forKey: "pushCredential")
    }

    private var credentialKey: String { "\(token ?? "")|\(Self.environment)" }

    func set(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        if UserDefaults.standard.string(forKey: "pushCredentialFor") != credentialKey { credential = nil }
        if credential == nil { requestChallenge() }
    }

    func requestChallenge() {
        guard let token, asked.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        asked = Date()
        Task { _ = await Self.post("register", ["token": token, "environment": Self.environment]) }
    }

    func confirm(_ challenge: String) {
        guard let token else { return }
        let key = credentialKey
        Task {
            guard let reply = await Self.post("confirm", ["token": token, "environment": Self.environment, "challenge": challenge]),
                  let cred = reply["credential"], !cred.isEmpty else { return }
            credential = cred
            UserDefaults.standard.set(cred, forKey: "pushCredential")
            UserDefaults.standard.set(key, forKey: "pushCredentialFor")
            for c in AppState.shared.connections.values where c.isConnected { await c.registerPush() }
        }
    }

    private static func post(_ path: String, _ body: [String: String]) async -> [String: String]? {
        var req = URLRequest(url: relay.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        signal(SIGPIPE, SIG_IGN)
        #if DEBUG
        DispatchQueue.main.async { MainActor.assumeIsolated { DemoScript.run() } }
        #endif
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [.authenticationRequired, .foreground])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.authenticationRequired, .destructive, .foreground])
        let proceed = UNNotificationAction(identifier: "PROCEED", title: "Proceed", options: [.authenticationRequired, .foreground])
        let dismiss = UNNotificationAction(identifier: "DISMISS", title: "Dismiss", options: [.authenticationRequired, .destructive, .foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "APPROVAL", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "REMINDER", actions: [proceed, dismiss], intentIdentifiers: []),
        ])
        #if DEBUG
        if ProcessInfo.processInfo.environment["TERMINESS_DEMO_ADD"] != nil { return true }
        #endif
        PushPermission.askIfUseful()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushTokens.shared.set(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if let challenge = notification.request.content.userInfo["challenge"] as? String {
            Task { @MainActor in PushTokens.shared.confirm(challenge) }
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let challenge = info["challenge"] as? String {
            Task { @MainActor in PushTokens.shared.confirm(challenge); completionHandler() }
            return
        }
        let host = (info["host"] as? String).flatMap(UUID.init(uuidString:))
        let session = info["session"] as? String
        let action = response.actionIdentifier
        if let reminder = info["reminder"] as? String, !reminder.isEmpty, let host {
            Task { @MainActor in
                AppLock.shared.whenUnlocked {
                    Task {
                        let c = AppState.shared.connection(host)
                        await c.connect()
                        guard let r = c.reminders.first(where: { $0.id == reminder }) else {
                            if let session, !session.isEmpty { AppState.shared.open(SessionTarget(host: host, session: session, title: "Session")) }
                            return
                        }
                        if action == "DISMISS" { AppState.shared.dismiss(r, on: host) }
                        else if action == "PROCEED" { await AppState.shared.proceed(r, on: host) }
                        else {
                            AppState.shared.drawerOpen = true
                        }
                    }
                }
                completionHandler()
            }
            return
        }
        Task { @MainActor in
            if let host, let session {
                AppLock.shared.whenUnlocked {
                    AppState.shared.open(SessionTarget(host: host, session: session, title: "Session"))
                    guard action == "ALLOW" || action == "DENY" else { return }
                    Task {
                        let c = AppState.shared.connection(host)
                        await c.connect()
                        if let p = c.sessions.first(where: { $0.id == session })?.permission {
                            await c.decide(session: session, requestID: p.id, answer: action == "ALLOW" ? "allow" : "deny")
                        }
                    }
                }
            }
            completionHandler()
        }
    }
}

@MainActor
enum PushPermission {
    static func askIfUseful() {
        guard HostStore.shared.hosts.contains(where: { !DemoMachine.isDemo($0) }) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }
}
