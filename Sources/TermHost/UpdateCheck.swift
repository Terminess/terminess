import Foundation

public struct UpdateInfo: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int
    public var url: String
    public var sha256: String?
    public var notes: String?

    public init(version: String, build: Int, url: String, sha256: String? = nil, notes: String? = nil) {
        self.version = version; self.build = build; self.url = url; self.sha256 = sha256; self.notes = notes
    }
}

public enum UpdateCheck {
    public static let feed = URL(string: "https://terminess.com/version.json")!

    public enum Outcome: Equatable, Sendable {
        case upToDate
        case available(UpdateInfo)
    }

    public static func parse(_ data: Data) -> UpdateInfo? {
        guard let info = try? JSONDecoder().decode(UpdateInfo.self, from: data),
              info.build > 0, URL(string: info.url)?.scheme == "https" else { return nil }
        return info
    }

    public static func compare(currentBuild: String?, latest: UpdateInfo) -> Outcome {
        guard let current = currentBuild.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            return .available(latest)
        }
        return latest.build > current ? .available(latest) : .upToDate
    }
}
