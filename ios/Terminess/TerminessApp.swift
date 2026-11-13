import SwiftUI

@main
struct TerminessApp: App {
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
