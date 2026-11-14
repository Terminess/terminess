import Foundation

public enum AgentLibrary {


    public static func frontmatter(_ text: String) -> [String: String] {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines.removeFirst()
        var out: [String: String] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value == "|" || value == ">" || value == "|-" || value == ">-" || value.isEmpty {
                var parts: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") {
                    parts.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = parts.joined(separator: " ")
            }
            out[key] = unquote(value)
        }
        return out
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f {
            return String(s.dropFirst().dropLast())
        }
        return s
    }


    public struct MCPServer: Equatable, Sendable {
        public var name: String
        public var command: String
        public var args: [String]
        public var url: String?
        public init(name: String, command: String, args: [String] = [], url: String? = nil) {
            self.name = name; self.command = command; self.args = args; self.url = url
        }
        public var summary: String {
            if let url, command.isEmpty { return url }
            return ([command] + args).joined(separator: " ")
        }
    }

    public static func mcpServers(inJSON object: Any?) -> [MCPServer] {
        guard let dict = object as? [String: Any], let servers = dict["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().map { name in
            let s = servers[name] as? [String: Any] ?? [:]
            return MCPServer(name: name, command: s["command"] as? String ?? "",
                             args: (s["args"] as? [Any])?.map { "\($0)" } ?? [], url: s["url"] as? String)
        }
    }

    static func tableKeys(_ line: String) -> [String]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") else { return nil }
        if t.hasPrefix("[[") { return ["[["] }
        guard let close = t.lastIndex(of: "]") else { return nil }
        let inner = t[t.index(after: t.startIndex)..<close]
        var keys: [String] = [], cur = "", quote: Character?
        for c in inner {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "." {
                keys.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(c)
            }
        }
        keys.append(cur.trimmingCharacters(in: .whitespaces))
        return keys
    }

    static func tomlStrings(_ value: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, escaped = false
        for c in value {
            if let q = quote {
                if escaped { cur.append(c); escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q { out.append(cur); cur = ""; quote = nil }
                else { cur.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                break
            }
        }
        return out
    }

    public static func codexMCPServers(_ toml: String) -> [MCPServer] {
        var out: [MCPServer] = []
        var current: Int?
        for line in toml.components(separatedBy: "\n") {
            if let keys = tableKeys(line) {
                current = nil
                if keys.count == 2, keys[0] == "mcp_servers" {
                    out.append(MCPServer(name: keys[1], command: ""))
                    current = out.count - 1
                }
                continue
            }
            guard let i = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "command": out[i].command = tomlStrings(value).first ?? ""
            case "args": out[i].args = tomlStrings(value)
            case "url": out[i].url = tomlStrings(value).first
            default: break
            }
        }
        return out
    }

    public static func removingCodexMCPServer(_ name: String, from toml: String) -> (toml: String, removed: String)? {
        var kept = "", removed = ""
        var inside = false, found = false
        var rest = Substring(toml)
        while !rest.isEmpty {
            let end = rest.firstIndex(of: "\n").map { rest.index(after: $0) } ?? rest.endIndex
            let line = String(rest[..<end])
            rest = rest[end...]
            if let keys = tableKeys(line) {
                inside = keys.count >= 2 && keys[0] == "mcp_servers" && keys[1] == name
                found = found || inside
            }
            if inside { removed += line } else { kept += line }
        }
        return found ? (kept, removed) : nil
    }

    public static func appendingCodexMCPServer(name: String, command: String, args: [String],
                                               env: [(String, String)] = [], to toml: String) -> String {
        var out = toml
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
        out += "[mcp_servers.\(tomlKey(name))]\n"
        out += "command = \(tomlString(command))\n"
        if !args.isEmpty { out += "args = [ " + args.map(tomlString).joined(separator: ", ") + " ]\n" }
        if !env.isEmpty {
            out += "\n[mcp_servers.\(tomlKey(name)).env]\n"
            for (k, v) in env { out += "\(tomlKey(k)) = \(tomlString(v))\n" }
        }
        return out
    }

    static func tomlKey(_ s: String) -> String {
        s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } && !s.isEmpty ? s : tomlString(s)
    }

    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func splitArgs(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, escaped = false, has = false
        for c in s {
            if escaped { cur.append(c); escaped = false; continue }
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"" { escaped = true } else { cur.append(c) }
            } else if c == "\\" { escaped = true; has = true }
            else if c == "\"" || c == "'" { quote = c; has = true }
            else if c == " " || c == "\t" || c == "\n" {
                if has || !cur.isEmpty { out.append(cur) }
                cur = ""; has = false
            } else { cur.append(c) }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }


    public static func isValidName(_ s: String) -> Bool {
        guard let first = s.first, first != "-", s.count <= 64 else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }


    public struct GitHubLocation: Equatable, Sendable {
        public var owner: String
        public var repo: String
        public var ref: String?
        public var path: String
        public var isFile: Bool
        public init(owner: String, repo: String, ref: String?, path: String, isFile: Bool) {
            self.owner = owner; self.repo = repo; self.ref = ref; self.path = path; self.isFile = isFile
        }
        public var leafName: String { path.isEmpty ? repo : (path as NSString).lastPathComponent }
    }

    public static func parseGitHubURL(_ string: String) -> GitHubLocation? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host?.lowercased() else { return nil }
        var parts = url.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if host == "raw.githubusercontent.com" {
            guard parts.count >= 4 else { return nil }
            return GitHubLocation(owner: parts[0], repo: parts[1], ref: parts[2],
                                  path: parts[3...].joined(separator: "/"), isFile: true)
        }
        guard host == "github.com" || host == "www.github.com", parts.count >= 2 else { return nil }
        let owner = parts.removeFirst()
        var repo = parts.removeFirst()
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !parts.isEmpty else { return GitHubLocation(owner: owner, repo: repo, ref: nil, path: "", isFile: false) }
        let kind = parts.removeFirst()
        guard kind == "tree" || kind == "blob", !parts.isEmpty else { return nil }
        let ref = parts.removeFirst()
        return GitHubLocation(owner: owner, repo: repo, ref: ref, path: parts.joined(separator: "/"), isFile: kind == "blob")
    }

    public static func isSafeRelativePath(_ p: String) -> Bool {
        guard !p.isEmpty, !p.hasPrefix("/") else { return false }
        return p.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
