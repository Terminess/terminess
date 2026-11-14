import AppKit
import TermTranscript

enum LibraryImport {
    struct Fetched: Sendable {
        var location: AgentLibrary.GitHubLocation
        var isSkill: Bool
        var name: String
        var files: [(path: String, data: Data)]
        var preview: String
    }

    static let maxFiles = 100
    static let maxBytes = 5_000_000

    private struct Entry: Sendable { var path: String; var type: String; var download: String? }

    static func fetch(_ urlString: String) async throws -> Fetched {
        guard var loc = AgentLibrary.parseGitHubURL(urlString) else {
            throw Library.Failure("That is not a GitHub link to a folder or file.")
        }
        let leaf = loc.leafName
        if loc.isFile && leaf == "SKILL.md" {
            loc.path = (loc.path as NSString).deletingLastPathComponent
            loc.isFile = false
        }
        let gh = await ghAvailable()
        if loc.isFile {
            guard leaf.lowercased().hasSuffix(".md") else {
                throw Library.Failure("Point at a folder holding a SKILL.md, or at a single .md command or agent file.")
            }
            let data = try await raw(loc, path: loc.path, download: nil, gh: gh)
            let name = String(leaf.dropLast(3))
            return Fetched(location: loc, isSkill: false, name: name, files: [(leaf, data)],
                           preview: String(decoding: data, as: UTF8.self))
        }
        var files: [(String, Data)] = []
        var total = 0
        func walk(_ path: String, depth: Int) async throws {
            for e in try await list(loc, path: path, gh: gh) {
                let rel = loc.path.isEmpty ? e.path : String(e.path.dropFirst(loc.path.count + 1))
                guard AgentLibrary.isSafeRelativePath(rel) else { continue }
                if e.type == "dir" {
                    if depth < 4 { try await walk(e.path, depth: depth + 1) }
                } else if e.type == "file" {
                    guard files.count < maxFiles else { throw Library.Failure("That folder has more than \(maxFiles) files; is it really one skill?") }
                    let data = try await raw(loc, path: e.path, download: e.download, gh: gh)
                    total += data.count
                    guard total <= maxBytes else { throw Library.Failure("That folder is larger than 5 MB; is it really one skill?") }
                    files.append((rel, data))
                }
            }
        }
        let top = try await list(loc, path: loc.path, gh: gh)
        guard top.contains(where: { ($0.path as NSString).lastPathComponent == "SKILL.md" && $0.type == "file" }) else {
            let subfolders = top.filter { $0.type == "dir" }.map { ($0.path as NSString).lastPathComponent }
            throw Library.Failure("There is no SKILL.md in that folder." + (subfolders.isEmpty ? "" : " Link to one of its skill folders instead: " + subfolders.prefix(12).joined(separator: ", ") + "."))
        }
        try await walk(loc.path, depth: 0)
        let skill = files.first { $0.0 == "SKILL.md" }?.1 ?? Data()
        var name = loc.leafName
        if !AgentLibrary.isValidName(name) {
            name = AgentLibrary.frontmatter(String(decoding: skill, as: UTF8.self))["name"] ?? name
        }
        return Fetched(location: loc, isSkill: true, name: name, files: files.map { (path: $0.0, data: $0.1) },
                       preview: String(decoding: skill, as: UTF8.self))
    }

    private static func endpoint(_ loc: AgentLibrary.GitHubLocation, _ path: String) -> String {
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let ref = loc.ref.map { "?ref=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) } ?? ""
        return "repos/\(loc.owner)/\(loc.repo)/contents/\(encoded)" + ref
    }

    private static func ghAvailable() async -> Bool {
        await Task.detached { Library.shell("command -v gh >/dev/null && gh auth status >/dev/null 2>&1").status == 0 }.value
    }

    private static func gh(_ args: String) async -> Data? {
        await Task.detached {
            let r = Library.shell("gh api " + args)
            return r.status == 0 ? r.out : nil
        }.value
    }

    private static func http(_ url: String, raw: Bool) async throws -> Data {
        guard let u = URL(string: url) else { throw Library.Failure("Bad address: \(url)") }
        var req = URLRequest(url: u)
        req.setValue("Terminess", forHTTPHeaderField: "User-Agent")
        if raw { req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 404 { throw Library.Failure("GitHub says that does not exist (or is private; signing in to gh lets Terminess see private repositories).") }
            if status == 403 { throw Library.Failure("GitHub refused the request, probably its hourly limit for requests without a token. Installing gh and signing in avoids that.") }
            throw Library.Failure("GitHub answered \(status) for \(url).")
        }
        return data
    }

    private static func list(_ loc: AgentLibrary.GitHubLocation, path: String, gh useGH: Bool) async throws -> [Entry] {
        let ep = endpoint(loc, path)
        var data: Data?
        if useGH { data = await gh(shellQuote(ep)) }
        if data == nil { data = try await http("https://api.github.com/" + ep, raw: false) }
        guard let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) else {
            throw Library.Failure("GitHub sent something unexpected for \(path.isEmpty ? loc.repo : path).")
        }
        guard let array = obj as? [[String: Any]] else {
            throw Library.Failure("That link is a file, not a folder.")
        }
        return array.compactMap { d in
            guard let p = d["path"] as? String, let t = d["type"] as? String else { return nil }
            return Entry(path: p, type: t, download: d["download_url"] as? String)
        }
    }

    private static func raw(_ loc: AgentLibrary.GitHubLocation, path: String, download: String?, gh useGH: Bool) async throws -> Data {
        let ep = endpoint(loc, path)
        if useGH, let data = await gh("-H 'Accept: application/vnd.github.raw' " + shellQuote(ep)) { return data }
        if let download { return try await http(download, raw: false) }
        return try await http("https://api.github.com/" + ep, raw: true)
    }

    @MainActor
    static func install(_ fetched: Fetched, name: String, kind: Library.Kind, agents: [Library.Agent],
                        scope: Library.Scope, project: String?, replace: (String) -> Bool) async throws -> [String] {
        guard AgentLibrary.isValidName(name) else { throw Library.Failure("Use letters, digits, hyphens and underscores for the name.") }
        let fm = FileManager.default
        var installed: [String] = []
        for agent in agents {
            guard let root = Library.installRoot(kind, agent: agent, scope: scope, project: project) else {
                throw Library.Failure(scope == .project && project == nil ? "There is no project folder for the key window." : "\(agent.rawValue) has no \(kind.rawValue.lowercased()) folder.")
            }
            let target = kind == .skills ? root + "/" + name : root + "/" + name + ".md"
            let existing = [target, Library.disabledTarget(root: root, name: name, kind: kind)].filter { fm.fileExists(atPath: $0) }
            if !existing.isEmpty {
                guard existing.allSatisfy(replace) else { continue }
                try await Library.trash(existing, project: project)
            }
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            let stage = NSTemporaryDirectory() + "terminess-import-" + UUID().uuidString
            try fm.createDirectory(atPath: stage, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: stage) }
            for file in fetched.files {
                let dest = stage + "/" + file.path
                try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try file.data.write(to: URL(fileURLWithPath: dest))
                if file.path.hasPrefix("scripts/") || file.path.hasSuffix(".sh") || file.path.hasSuffix(".py") {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
                }
            }
            if kind == .skills {
                try fm.moveItem(atPath: stage, toPath: target)
                installed.append(target + "/SKILL.md")
            } else {
                try fm.moveItem(atPath: stage + "/" + (fetched.files.first?.path ?? ""), toPath: target)
                installed.append(target)
            }
        }
        return installed
    }
}
