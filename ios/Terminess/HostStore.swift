import Foundation
import TermHost

struct SavedHost: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var port: Int = 22
    var user: String
    var terminessd = "~/.local/bin/terminessd"
    var hostKey: String?
}

@MainActor
final class HostStore: ObservableObject {
    static let shared = HostStore()
    @Published private(set) var hosts: [SavedHost] = []
    @Published var justAdded: String?
    @Published var pairing: String?
    private let key = "hosts"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([SavedHost].self, from: data) { hosts = saved }
    }

    func save(_ host: SavedHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        persist()
    }

    func delete(_ ids: [UUID]) {
        for id in ids {
            guard let c = AppState.shared.connections[id] else { continue }
            Task { await c.unregisterPush(); c.disconnect() }
        }
        hosts.removeAll { ids.contains($0.id) }
        persist()
    }

    func host(_ id: UUID) -> SavedHost? { hosts.first { $0.id == id } }

    struct PendingLink: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let message: String
        let changesTrust: Bool
    }
    @Published var pendingLink: PendingLink?

    private struct LinkInfo {
        var name: String?, address: String, user: String, port: Int
        var path: String?, hostKey: String?, pair: URL?, code: String?
    }

    private func info(_ url: URL) -> LinkInfo? {
        guard url.scheme == "terminess", url.host == "add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ k: String) -> String? { items.first { $0.name == k }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let address = value("address"), let user = value("user"),
              address.count < 256, user.count < 64, !address.hasPrefix("-"), !user.hasPrefix("-") else { return nil }
        let pair = value("pair").flatMap(URL.init(string:)).flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0 : nil }
        return LinkInfo(name: value("name").map { String($0.prefix(60)) }, address: address, user: user,
                        port: value("port").flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil } ?? 22,
                        path: value("path"), hostKey: value("hostkey"), pair: pair, code: value("token"))
    }

    private func existing(_ i: LinkInfo) -> SavedHost? {
        hosts.first { $0.address == i.address && $0.user == i.user && $0.port == i.port }
    }

    func open(_ url: URL) {
        guard let i = info(url) else { return }
        if let path = i.path, !RemotePath.isSafe(path) {
            pairing = "That link wasn't used: the terminessd location in it doesn't look like a normal path."
            return
        }
        let name = i.name ?? i.address
        let target = "\(i.user)@\(i.address)\(i.port == 22 ? "" : ":\(i.port)")"
        guard let saved = existing(i) else {
            pendingLink = PendingLink(url: url, title: "Add \(name)?",
                                      message: "Terminess will connect to \(target) over SSH. Only add machines you set up yourself.",
                                      changesTrust: false)
            return
        }
        var changes: [String] = []
        if let key = i.hostKey, let old = saved.hostKey, key != old { changes.append("its security key (the machine's SSH host key)") }
        if let path = i.path, path != saved.terminessd { changes.append("where terminessd is on it") }
        if changes.isEmpty {
            pendingLink = PendingLink(url: url, title: "Pair again with \(saved.name)?",
                                      message: "\(target) is already saved. Nothing about how it's trusted changes.", changesTrust: false)
        } else {
            pendingLink = PendingLink(url: url, title: "Change \(saved.name)?",
                                      message: "This link changes \(changes.joined(separator: " and ")) for \(target). Only accept if you just reinstalled or re-paired that machine yourself; otherwise someone may be trying to intercept your connection.",
                                      changesTrust: true)
        }
    }

    func decline() { pendingLink = nil }

    func accept() {
        guard let link = pendingLink else { return }
        pendingLink = nil
        guard let i = info(link.url), let id = add(i) else { return }
        let name = host(id)?.name ?? "the machine"
        Task {
            if let pair = i.pair, let code = i.code {
                pairing = "Pairing with \(name)…"
                pairing = await Self.pair(pair, code: code, name: name)
            }
            let c = AppState.shared.connection(id)
            c.disconnect()
            await c.connect()
            AppState.shared.newHost = id
            AppState.shared.newChat()
        }
    }

    private static func pair(_ url: URL, code: String, name: String) async -> String? {
        let key = DeviceKey.authorizedKeyLine()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key, "proof": Pairing.proof(code: code, key: key)])
        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            return "Couldn't reach \(name) to pair. Be on the same Wi-Fi (or Tailscale) and scan again, or add this iPhone's key in Settings by hand."
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return "\(name) said: \(body["result"] ?? "pairing failed"). Open the pairing window again and rescan."
        }
        guard body["proof"] == Pairing.reply(code: code, key: key) else {
            return "The pairing answer didn't come from \(name). Check you're on your own network and scan again."
        }
        return nil
    }

    private func add(_ i: LinkInfo) -> UUID? {
        var host = existing(i) ?? SavedHost(name: i.address, address: i.address, port: i.port, user: i.user)
        host.name = i.name ?? host.name
        if let path = i.path {
            guard RemotePath.isSafe(path) else { return nil }
            host.terminessd = path
        }
        if let key = i.hostKey { host.hostKey = key }
        save(host)
        return host.id
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: key) }
    }
}
