import AppKit

@MainActor
enum DebugScript {
    static func run(on controller: TerminalWindowController) {
        let env = ProcessInfo.processInfo.environment
        var last = 0.0
        if let script = env["TERMAPP_SCRIPT"] {
            for step in script.split(separator: "|") {
                guard let colon = step.firstIndex(of: ":"), let delay = Double(step[..<colon]) else { continue }
                let text = String(step[step.index(after: colon)...])
                    .replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\e", with: "\u{1B}").replacingOccurrences(of: "\\t", with: "\t")
                last = max(last, delay)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in
                    MainActor.assumeIsolated { controller?.session.send(Array(text.utf8)) }
                }
            }
        }
        if let path = env["TERMAPP_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + last + 1.0) { [weak controller] in
                MainActor.assumeIsolated {
                    guard let view = controller?.terminalView else { return }
                    view.displayIfNeeded()
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }
        if let quit = env["TERMAPP_QUIT_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + quit) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
    }
}
