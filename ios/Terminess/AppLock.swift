import LocalAuthentication
import SwiftUI

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    enum Delay: Int, CaseIterable, Identifiable {
        case immediately = 0, oneMinute = 60, fifteenMinutes = 900
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .immediately: return "Immediately"
            case .oneMinute: return "After 1 minute"
            case .fifteenMinutes: return "After 15 minutes"
            }
        }
    }

    @Published private(set) var locked: Bool
    @Published private(set) var problem: String?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "lockEnabled") }
    }
    @Published var delay: Delay {
        didSet { UserDefaults.standard.set(delay.rawValue, forKey: "lockDelay") }
    }
    private var leftAt: Date?
    private var asking = false
    private var waiting: [() -> Void] = []

    init() {
        let d = UserDefaults.standard
        let on = d.object(forKey: "lockEnabled") as? Bool ?? true
        enabled = on
        delay = Delay(rawValue: d.integer(forKey: "lockDelay")) ?? .oneMinute
        locked = on && Self.available
    }

    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    func whenUnlocked(_ action: @escaping () -> Void) {
        if locked { waiting.append(action) } else { action() }
    }

    func unlock() {
        guard locked, !asking else { return }
        guard Self.available else { finishUnlock(); return }
        asking = true
        problem = nil
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Terminess") { ok, error in
            Task { @MainActor in
                let me = AppLock.shared
                me.asking = false
                if ok { me.finishUnlock() }
                else if let e = error as? LAError, e.code != .userCancel, e.code != .appCancel, e.code != .systemCancel {
                    me.problem = e.localizedDescription
                }
            }
        }
    }

    private func finishUnlock() {
        locked = false
        problem = nil
        let run = waiting
        waiting = []
        AppState.shared.resume()
        run.forEach { $0() }
    }

    func phase(_ p: ScenePhase) {
        switch p {
        case .background:
            if leftAt == nil { leftAt = Date() }
            if enabled, Self.available, delay == .immediately { lock() }
        case .active:
            if let left = leftAt, enabled, Self.available, Date().timeIntervalSince(left) >= Double(delay.rawValue) { lock() }
            leftAt = nil
            if locked { unlock() }
        default:
            break
        }
    }

    private func lock() {
        guard !locked else { return }
        locked = true
        AppState.shared.showSettings = false
        for c in AppState.shared.connections.values { c.disconnect() }
    }

    func setEnabled(_ on: Bool) {
        guard !on else { enabled = true; return }
        guard Self.available else { enabled = false; return }
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn off the lock") { ok, _ in
            Task { @MainActor in if ok { AppLock.shared.enabled = false } }
        }
    }
}

struct LockScreen: View {
    @ObservedObject var lock = AppLock.shared
    var showsButton: Bool

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                LogoMark(size: 64).foregroundStyle(Theme.ink.opacity(0.3))
                if showsButton {
                    Button { lock.unlock() } label: {
                        Label("Unlock with \(lock.biometryName)", systemImage: lock.biometryName == "Face ID" ? "faceid" : "lock")
                            .padding(.horizontal, 18).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    if let p = lock.problem {
                        Text(p).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                }
            }
        }
    }
}
