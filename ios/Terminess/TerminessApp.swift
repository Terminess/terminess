import SwiftUI

@main
struct TerminessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .onOpenURL { url in AppLock.shared.whenUnlocked { HostStore.shared.open(url) } }
        }
    }
}

struct ThemedRoot: View {
    @AppStorage("appearance") private var chosen = Appearance.dark.rawValue
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var store = HostStore.shared
    @ObservedObject private var lock = AppLock.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        let choice = Appearance(rawValue: chosen) ?? .dark
        let look = choice.resolved(scheme)
        Theme.appearance = look
        return Group {
            if lock.locked {
                LockScreen(showsButton: true)
            } else {
                RootView().id(look)
            }
        }
            .overlay { if lock.enabled && phase != .active && !lock.locked { LockScreen(showsButton: false) } }
            .onChange(of: phase, initial: true) { _, p in lock.phase(p) }
            .preferredColorScheme(choice == .system ? nil : (look.isDark ? .dark : .light))
            .tint(Theme.ink)
            .sheet(isPresented: $app.showSettings) { SettingsView() }
            .alert(store.pendingLink?.title ?? "", isPresented: Binding(
                get: { store.pendingLink != nil && !lock.locked }, set: { if !$0 { store.decline() } }
            ), presenting: store.pendingLink) { link in
                Button(link.changesTrust ? "Change It" : "Add", role: link.changesTrust ? .destructive : nil) { store.accept() }
                Button("Cancel", role: .cancel) { store.decline() }
            } message: { link in Text(link.message) }
    }
}
