import AppKit
import TermHost

@MainActor
final class LocalModelMenu: NSObject, NSMenuDelegate, ObservableObject {
    static let shared = LocalModelMenu()
    @Published private(set) var models: [String]?
    @Published private(set) var note = "Looking for models…"
    @Published private(set) var hfModels: [String] = HuggingFace.models()
    @Published private(set) var hfNotice: HuggingFace.Notice? = HuggingFace.notice()
    private var loading = false
    private weak var menu: NSMenu?

    func attach(to menu: NSMenu) {
        menu.delegate = self
        self.menu = menu
        refresh()
    }

    private var host: String {
        let h = Settings.shared.localModelsHost.trimmingCharacters(in: .whitespaces)
        let ok = !h.hasPrefix("-") && h.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "@._-:[]".unicodeScalars.contains($0) }
        return ok ? h : ""
    }
    nonisolated static let sshOptions = ["-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes"]
    private var place: String { host.isEmpty ? "this Mac" : host }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
        refresh()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        if let models, !models.isEmpty {
            let header = NSMenuItem(title: "On \(place)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for m in models {
                let item = NSMenuItem(title: m, action: #selector(open(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hfHeader = NSMenuItem(title: "Hugging Face", action: nil, keyEquivalent: "")
        hfHeader.isEnabled = false
        menu.addItem(hfHeader)
        if let notice = hfNotice { menu.addItem(Self.noticeItem(notice)) }
        for id in hfModels {
            let item = NSMenuItem(title: id, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = HuggingFace.prefix + id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Choose the Machine and Models…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
        menu.addItem(settings)
    }

    static func noticeItem(_ notice: HuggingFace.Notice) -> NSMenuItem {
        let item = NSMenuItem(title: notice.message, action: #selector(openNotice(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = notice.rawValue
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Needs attention")?
            .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        return item
    }

    @objc func openNotice(_ sender: NSMenuItem) {
        guard let notice = (sender.representedObject as? String).flatMap(HuggingFace.Notice.init(rawValue:)) else { return }
        Self.open(notice)
    }

    static func open(_ notice: HuggingFace.Notice) {
        if let s = notice.url, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        else { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
    }

    func refresh() {
        hfModels = HuggingFace.models()
        hfNotice = HuggingFace.notice()
        guard !loading else { return }
        loading = true
        let host = self.host
        let finish: @Sendable ([String]?, String) -> Void = { models, note in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = LocalModelMenu.shared
                    m.loading = false
                    m.models = models
                    m.note = note
                    if let menu = m.menu { m.rebuild(menu) }
                }
            }
        }
        if host.isEmpty {
            LocalModels.installed { names in
                finish(names, names == nil ? "Ollama isn't running on this Mac. Set the machine in Settings." : "No models installed in Ollama")
            }
            return
        }
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"] + Self.sshOptions + ["--", host,
                           "curl -s --max-time 3 http://127.0.0.1:11434/api/tags"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { finish(nil, "Couldn't run ssh"); return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 255 { finish(nil, "Couldn't reach \(host) over SSH"); return }
            let names = LocalModels.parse(data)
            finish(names, names == nil ? "Ollama isn't running on \(host)" : "No models installed in Ollama on \(host)")
        }
    }

    var placeName: String { place }

    func command(for model: String, message: String = "") -> String {
        if host.isEmpty || HuggingFace.modelID(model) != nil {
            return LocalModels.chatCommand(terminessd: HostService.executable ?? "terminessd", model: model, message: message)
        }
        let run = LocalModels.chatCommand(terminessd: "~/.local/bin/terminessd", model: model, message: message)
        return (["ssh", "-t"] + Self.sshOptions).joined(separator: " ") + " -- \(shellQuote(host)) \(shellQuote(run))"
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String, let app = NSApp.delegate as? AppDelegate else { return }
        if HuggingFace.modelID(model) != nil, !app.hasHuggingFaceToken() { return }
        let c = app.open(tabbedWith: NSApp.keyWindow, command: command(for: model))
        c.customTitle = HuggingFace.modelID(model) ?? model
    }
}

enum StartAgent {
    static var current: String { UserDefaults.standard.string(forKey: "startAgent") ?? "claude" }

    static func localModel(_ agent: String) -> String? {
        agent.hasPrefix("local:") ? String(agent.dropFirst(6)) : nil
    }

    @MainActor
    static func command(_ agent: String, remote: Bool, message: String = "") -> String {
        if let model = localModel(agent) {
            return remote ? LocalModels.chatCommand(terminessd: "~/.local/bin/terminessd", model: model, message: message)
                          : LocalModelMenu.shared.command(for: model, message: message)
        }
        let exe = agent == "codex" ? "codex" : "claude"
        return message.isEmpty ? exe : "\(exe) \(shellQuote(message))"
    }
}
