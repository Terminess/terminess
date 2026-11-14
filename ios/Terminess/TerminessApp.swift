import SwiftUI

@main
struct TerminessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .onOpenURL { url in HostStore.shared.open(url) }
        }
    }
}

struct ThemedRoot: View {
    @AppStorage("appearance") private var chosen = Appearance.dark.rawValue
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var app = AppState.shared

    var body: some View {
        let choice = Appearance(rawValue: chosen) ?? .dark
        let look = choice.resolved(scheme)
        Theme.appearance = look
        return RootView()
            .id(look)
            .preferredColorScheme(choice == .system ? nil : (look.isDark ? .dark : .light))
            .tint(Theme.ink)
            .sheet(isPresented: $app.showSettings) { SettingsView() }
    }
}
