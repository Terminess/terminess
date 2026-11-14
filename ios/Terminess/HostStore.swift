import Foundation

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
        hosts.removeAll { ids.contains($0.id) }
        persist()
    }

    func host(_ id: UUID) -> SavedHost? { hosts.first { $0.id == id } }

    func open(_ url: URL) {
        guard let id = add(from: url) else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pair = items.first { $0.name == "pair" }?.value.flatMap(URL.init(string:))
        let token = items.first { $0.name == "token" }?.value
        let name = host(id)?.name ?? "the machine"
        Task {
            if let pair, let token {
                pairing = "Pairing with \(name)…"
                var req = URLRequest(url: pair)
                req.httpMethod = "POST"
                req.timeoutInterval = 8
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token, "key": DeviceKey.authorizedKeyLine()])
                let ok = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
                pairing = ok ? nil : "Couldn't reach \(name) to pair. Be on the same Wi-Fi (or Tailscale) and scan again, or add this iPhone's key in Settings by hand."
            }
            let c = AppState.shared.connection(id)
            c.disconnect()
            await c.connect()
            AppState.shared.newHost = id
            AppState.shared.newChat()
        }
    }

    @discardableResult
    func add(from url: URL) -> UUID? {
        guard url.scheme == "terminess", url.host == "add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ k: String) -> String? { items.first { $0.name == k }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let address = value("address"), let user = value("user") else { return nil }
        let port = value("port").flatMap(Int.init) ?? 22
        var host = hosts.first { $0.address == address && $0.user == user && $0.port == port }
            ?? SavedHost(name: address, address: address, port: port, user: user)
        host.name = value("name") ?? host.name
        if let path = value("path") { host.terminessd = path }
        if let key = value("hostkey") { host.hostKey = key }
        save(host)
        return host.id
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: key) }
    }
}
