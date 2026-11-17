import AppKit
import TermHost
import UniformTypeIdentifiers

extension AppDelegate {

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(string: "A terminal for Claude Code and Codex, on your own machines.\n",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "terminess.com",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://terminess.com")!]))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }


    @objc func checkForUpdates(_ sender: Any?) {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        var request = URLRequest(url: UpdateCheck.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Terminess", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let info = ok ? data.flatMap(UpdateCheck.parse) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.showUpdateResult(info, current: current) }
            }
        }.resume()
    }

    private func showUpdateResult(_ info: UpdateInfo?, current: String?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard let info else {
            alert("Couldn't check for updates", "terminess.com didn't answer. Check your connection and try again.")
            return
        }
        switch UpdateCheck.compare(currentBuild: current, latest: info) {
        case .upToDate:
            alert("Terminess is up to date", "You have \(version) (\(current ?? "?")), the newest build.")
        case .available(let latest):
            let a = NSAlert()
            a.messageText = "Terminess \(latest.version) (\(latest.build)) is available"
            var text = "You have \(version) (\(current ?? "?"))."
            if let notes = latest.notes, !notes.isEmpty { text += "\n\n" + notes }
            a.informativeText = String(text.prefix(2_000))
            a.addButton(withTitle: "Download")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn, let url = URL(string: latest.url) {
                NSWorkspace.shared.open(url)
            }
        }
    }


    static var shellScriptTypes: [UTType] {
        [UTType.shellScript, UTType.unixExecutable, UTType("com.apple.terminal.shell-script")].compactMap { $0 }
    }

    @objc func makeDefaultTerminal(_ sender: Any?) {
        guard confirm("Make Terminess the default terminal?",
                      "Shell scripts you open from Finder (.command, .sh, .tool) will run in a Terminess tab instead of Terminal. To undo, choose Terminal for those files in Finder's Get Info, Open With, Change All.",
                      "Make Default") else { return }
        let app = Bundle.main.bundleURL
        let types = Self.shellScriptTypes
        Task { @MainActor in
            var failed: [String] = []
            for type in types {
                do { try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) }
                catch { failed.append(type.identifier) }
            }
            if failed.isEmpty {
                alert("Terminess is now the default terminal", "Shell scripts opened from Finder run in a new Terminess tab.")
            } else {
                alert("Couldn't change every default", "macOS refused: \(failed.joined(separator: ", ")). Try again, or set it in Finder's Get Info.")
            }
        }
    }


    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            let path = url.path
            let folder = url.deletingLastPathComponent().path
            let command = FileManager.default.isExecutableFile(atPath: path) ? shellQuote(path) : "/bin/sh " + shellQuote(path)
            open(tabbedWith: keyController?.window, directory: folder, command: command)
        }
    }
}
