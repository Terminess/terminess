#if DEBUG
import SwiftUI

@MainActor
enum DemoScript {
    static let modeChange = Notification.Name("DemoScriptMode")

    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard env["TERMINESS_DEMO_ADD"] != nil || env["TERMINESS_DEMO_STEPS"] != nil else { return }
        let key = DeviceKey.authorizedKeyLine()
        print("demo key: \(key)")
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? key.write(to: docs.appendingPathComponent("demo-key.txt"), atomically: true, encoding: .utf8)
        }
        if let link = env["TERMINESS_DEMO_ADD"].flatMap(URL.init(string:)) {
            HostStore.shared.addForDemo(link)
            AppState.shared.start()
        }
        for step in (env["TERMINESS_DEMO_STEPS"] ?? "").split(separator: "|") {
            guard let colon = step.firstIndex(of: ":"), let delay = Double(step[..<colon]) else { continue }
            let action = String(step[step.index(after: colon)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { perform(action) } }
        }
    }

    private static func perform(_ action: String) {
        let app = AppState.shared
        print("demo step: \(action) running=\(app.running.count)")
        switch action {
        case "drawer": withAnimation { app.drawerOpen = true }
        case "close": withAnimation { app.drawerOpen = false }
        case "newchat": app.newChat()
        case "settings": app.showSettings = true
        default:
            if action.hasPrefix("open:"), let n = Int(action.dropFirst(5)), n < app.running.count {
                let r = app.running[n]
                app.open(SessionTarget(host: r.host.id, session: r.session.id, title: r.session.name, cwd: r.session.cwd))
            } else if action.hasPrefix("mode:"), let mode = ViewMode(rawValue: String(action.dropFirst(5))) {
                NotificationCenter.default.post(name: modeChange, object: mode)
            }
        }
    }
}
#endif
