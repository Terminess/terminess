import Foundation

public enum LocalChat {
    public static var directory: String {
        let dir = HostPaths.stateDirectory + "/chats"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    public static func newPath(session: String?) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return directory + "/\(session ?? "local")-\(f.string(from: Date())).jsonl"
    }

    public static func latest(for session: String) -> String? {
        let dir = directory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix(session + "-") && $0.hasSuffix(".jsonl") }
        return names.max().map { dir + "/" + $0 }
    }

    public static func isChat(command: String?, args: [String]) -> Bool {
        command == "terminessd" && args.dropFirst().first == "chat"
    }
}
