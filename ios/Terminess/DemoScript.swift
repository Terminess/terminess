#if DEBUG
import SwiftUI

@MainActor
enum DemoScript {
    static let modeChange = Notification.Name("DemoScriptMode")
    static let pickModel = Notification.Name("DemoScriptModel")
    static let sendText = Notification.Name("DemoScriptSend")
    static let typeText = Notification.Name("DemoScriptType")

    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard env["TERMINESS_DEMO_ADD"] != nil || env["TERMINESS_DEMO_STEPS"] != nil else { return }
        let key = DeviceKey.authorizedKeyLine()
        print("demo key: \(key)")
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? key.write(to: docs.appendingPathComponent("demo-key.txt"), atomically: true, encoding: .utf8)
        }
        if env["TERMINESS_DEMO_ADD"] == "demo" {
            if !HostStore.shared.hosts.contains(where: { DemoMachine.isDemo($0) }) { DemoMachine.hosts.forEach(HostStore.shared.save) }
            AppState.shared.start()
        } else if let link = env["TERMINESS_DEMO_ADD"].flatMap(URL.init(string:)) {
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
        case "pair":
            HostStore.shared.open(URL(string: "terminess://add?name=Studio%20Mac&address=studio.local&user=demo&pair=http://studio.local:7860/pair&token=demo")!)
        default:
            if action.hasPrefix("host:"), let n = Int(action.dropFirst(5)), n < app.hosts.count {
                app.newHost = app.hosts[n].id
                app.newProject = app.connection(app.hosts[n].id).projects.first?.path
                return
            }
            if action.hasPrefix("menu:"), let n = Int(action.dropFirst(5)) { openMenu(n); return }
            if action.hasPrefix("model:"), let n = Int(action.dropFirst(6)) { NotificationCenter.default.post(name: pickModel, object: n); return }
            if action.hasPrefix("type:") { NotificationCenter.default.post(name: typeText, object: String(action.dropFirst(5))); return }
            if action.hasPrefix("send:") { NotificationCenter.default.post(name: sendText, object: String(action.dropFirst(5))); return }
            if action.hasPrefix("session:"), let r = app.running.first(where: { $0.session.id == action.dropFirst(8) }) {
                app.open(SessionTarget(host: r.host.id, session: r.session.id, title: SessionText.title(r.session), cwd: r.session.cwd))
                return
            }
            if action.hasPrefix("open:"), let n = Int(action.dropFirst(5)), n < app.running.count {
                let r = app.running[n]
                app.open(SessionTarget(host: r.host.id, session: r.session.id, title: r.session.name, cwd: r.session.cwd))
            } else if action.hasPrefix("mode:"), let mode = ViewMode(rawValue: String(action.dropFirst(5))) {
                NotificationCenter.default.post(name: modeChange, object: mode)
            }
        }
    }

    private static func openMenu(_ n: Int) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        var found: [(UIView, UIContextMenuInteraction)] = []
        func walk(_ v: UIView) {
            if v is UIControl, v.bounds.width > 40 {
                for i in v.interactions { if let m = i as? UIContextMenuInteraction { found.append((v, m)) } }
            }
            v.subviews.forEach(walk)
        }
        walk(window)
        found.sort { $0.0.convert($0.0.bounds, to: window).minX < $1.0.convert($1.0.bounds, to: window).minX }
        print("demo menus: \(found.map { "\(type(of: $0.0)) \($0.0.convert($0.0.bounds, to: window))" })")
        guard n < found.count else { return }
        let (view, interaction) = found[n]
        let sel = NSSelectorFromString("_presentMenuAtLocation:")
        guard interaction.responds(to: sel), let imp = class_getMethodImplementation(type(of: interaction), sel) else {
            print("demo menus: can't present"); return
        }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        unsafeBitCast(imp, to: Present.self)(interaction, sel, CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }
}
#endif
