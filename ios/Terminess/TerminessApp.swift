import SwiftUI

@main
struct TerminessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(.white)
                .onOpenURL { url in HostStore.shared.open(url) }
        }
    }
}
