import SwiftUI

@main
struct TerminessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            HostsView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if let name = HostStore.shared.add(from: url) { HostStore.shared.justAdded = name }
                }
        }
    }
}
