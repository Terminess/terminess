import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TermHost
import TermTranscript

struct OutputScanner {
    enum Event: Equatable {
        case title(String)
        case bell
        case notify(String)
    }

    private enum State { case normal, escape, osc, oscEscape, string, stringEscape }
    private var state = State.normal
    private var osc: [UInt8] = []

    mutating func scan(_ bytes: [UInt8]) -> [Event] {
        var events: [Event] = []
        for b in bytes {
            switch state {
            case .normal:
                if b == 0x1B { state = .escape } else if b == 0x07 { events.append(.bell) }
            case .escape:
                switch b {
                case UInt8(ascii: "]"): state = .osc; osc.removeAll(keepingCapacity: true)
                case UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"): state = .string
                default: state = .normal
                }
            case .osc:
                if b == 0x07 { finish(&events); state = .normal }
                else if b == 0x1B { state = .oscEscape }
                else if osc.count < 4096 { osc.append(b) }
            case .oscEscape:
                if b == UInt8(ascii: "\\") { finish(&events); state = .normal } else { state = .osc }
            case .string:
                if b == 0x1B { state = .stringEscape } else if b == 0x07 { state = .normal }
            case .stringEscape:
                state = b == UInt8(ascii: "\\") ? .normal : .string
            }
        }
        return events
    }

    private func finish(_ events: inout [Event]) {
        let s = String(decoding: osc, as: UTF8.self)
        guard let semi = s.firstIndex(of: ";") else { return }
        let code = s[..<semi], rest = String(s[s.index(after: semi)...])
        switch code {
        case "0", "2": events.append(.title(rest))
        case "9":
            if !rest.hasPrefix("4;") { events.append(.notify(rest)) }
        case "777":
            let parts = rest.split(separator: ";", maxSplits: 2).map(String.init)
            if parts.first == "notify" { events.append(.notify(parts.dropFirst().joined(separator: ": "))) }
        default: break
        }
    }
}

enum TitleState {
    static func busy(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first else { return false }
        return (0x25D0...0x25D3).contains(first.value) || (0x2800...0x28FF).contains(first.value)
    }

    static func clean(_ title: String) -> String {
        String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }
}

enum Projects {
    static func recent(limit: Int = 50) -> [ProjectInfo] {
        let fm = FileManager.default
        let home = Transcript.home
        var used: [String: Double] = [:]
        func note(_ path: String, _ t: Double) {
            guard !path.isEmpty else { return }
            used[path] = max(used[path] ?? 0, t)
        }
        let claude = home + "/.claude/projects"
        for dir in (try? fm.contentsOfDirectory(atPath: claude)) ?? [] {
            let full = claude + "/" + dir
            let files = ((try? fm.contentsOfDirectory(atPath: full)) ?? []).filter { $0.hasSuffix(".jsonl") }.map { full + "/" + $0 }
            guard let newest = files.max(by: { (Transcript.mtime($0) ?? .distantPast) < (Transcript.mtime($1) ?? .distantPast) }),
                  let cwd = recordedCwd(newest) else { continue }
            note(cwd, Transcript.mtime(newest)?.timeIntervalSince1970 ?? 0)
        }
        let cal = Calendar.current
        for back in 0..<30 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "%@/.codex/sessions/%04d/%02d/%02d", home, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                let p = dir + "/" + f
                if let cwd = recordedCwd(p) { note(cwd, Transcript.mtime(p)?.timeIntervalSince1970 ?? 0) }
            }
        }
        var isDir: ObjCBool = false
        return used.filter { fm.fileExists(atPath: $0.key, isDirectory: &isDir) && isDir.boolValue && $0.key != home }
            .map { ProjectInfo(path: $0.key, used: $0.value) }
            .sorted { $0.used > $1.used }
            .prefix(limit).map { $0 }
    }

    private static func recordedCwd(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let data = h.readData(ofLength: 128 * 1024)
        for line in data.split(separator: UInt8(ascii: "\n")).prefix(40) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let cwd = obj["cwd"] as? String { return cwd }
            if let p = obj["payload"] as? [String: Any], let cwd = p["cwd"] as? String { return cwd }
        }
        return nil
    }
}

final class PushRegistry {
    struct Device: Codable { var token: String; var environment: String; var host: String?; var added: Double }
    private(set) var devices: [Device] = []
    private let file = HostPaths.stateDirectory + "/push.json"
    let relay = ProcessInfo.processInfo.environment["TERMINESS_PUSH_RELAY"] ?? "https://push.terminess.com/v1/notify"

    init() {
        if let data = FileManager.default.contents(atPath: file),
           let saved = try? JSONDecoder().decode([Device].self, from: data) { devices = saved }
    }

    func register(token: String, environment: String, host: String?) {
        devices.removeAll { $0.token == token }
        devices.append(Device(token: token, environment: environment, host: host, added: Date().timeIntervalSince1970))
        if let data = try? JSONEncoder().encode(devices) {
            FileManager.default.createFile(atPath: file, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    func notify(title: String, body: String, session: String) {
        guard !devices.isEmpty, let url = URL(string: relay) else { return }
        for d in devices {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 10
            let payload: [String: String] = ["token": d.token, "environment": d.environment,
                                             "title": title, "body": body, "session": session, "host": d.host ?? ""]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
        }
    }
}
