import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LocalModels {
    public static var base: String {
        guard var h = ProcessInfo.processInfo.environment["OLLAMA_HOST"], !h.isEmpty else { return "http://127.0.0.1:11434" }
        if !h.hasPrefix("http") { h = "http://" + h }
        return h.hasSuffix("/") ? String(h.dropLast()) : h
    }

    public static func installed(timeout: Double = 2, completion: @escaping @Sendable ([String]?) -> Void) {
        guard let url = URL(string: base + "/api/tags") else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        URLSession.shared.dataTask(with: req) { data, _, _ in
            completion(data.flatMap(parse))
        }.resume()
    }

    public static func parse(_ data: Data) -> [String]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }.sorted()
    }

    public static func chatCommand(terminessd: String, model: String, message: String = "") -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let exe = terminessd.hasPrefix("~/") ? "~/" + q(String(terminessd.dropFirst(2))) : q(terminessd)
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeModel = model.filter { $0.isLetter || $0.isNumber || ":._-/".contains($0) }
        return "\(exe) chat \(safeModel)" + (m.isEmpty ? "" : " " + q(m))
    }

}
