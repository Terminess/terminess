import Foundation

public enum Instructions {
    public static let importLine = "@AGENTS.md"

    public static func claudeProjectName(_ directory: String) -> String {
        String(directory.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    public static func lineEnding(_ text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
    }

    public static func normalised(_ text: String, to ending: String) -> String {
        let plain = text.replacingOccurrences(of: "\r\n", with: "\n")
        return ending == "\n" ? plain : plain.replacingOccurrences(of: "\n", with: ending)
    }

    public static func importsAgents(_ claude: String) -> Bool {
        claude.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line == importLine || line == "@./AGENTS.md"
        }
    }

    public static func sharedClaude(keeping extra: String? = nil, ending: String = "\n") -> String {
        var out = importLine + "\n"
        let rest = (extra ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out += "\n" + rest + "\n" }
        return normalised(out, to: ending)
    }

    public static func addingNote(_ note: String, to text: String) -> String {
        let ending = lineEnding(text)
        let noteLines = note.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        guard let first = noteLines.first, !first.isEmpty else { return text }
        let bullet = ["- " + first] + noteLines.dropFirst().map { $0.isEmpty ? "" : "  " + $0 }

        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var heading: Int?
        var end = lines.count
        var fenced = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced { continue }
            if heading == nil {
                if line.lowercased() == "## notes" { heading = i }
            } else if line.hasPrefix("# ") || line.hasPrefix("## ") || line == "#" || line == "##" {
                end = i
                break
            }
        }

        if let h = heading {
            let last = (h + 1..<end).last { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            var insert = bullet
            let at: Int
            if let last {
                at = last + 1
            } else {
                insert = [""] + bullet
                at = h + 1
            }
            if at < lines.count, !lines[at].trimmingCharacters(in: .whitespaces).isEmpty { insert.append("") }
            lines.insert(contentsOf: insert, at: at)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += ["## Notes", ""] + bullet
        }
        return lines.joined(separator: ending) + ending
    }

    public static let agentsTemplate = """
    # Project instructions

    Read by Codex (AGENTS.md) and, when CLAUDE.md imports it, by Claude Code.

    ## Overview

    What this project is and how it is laid out.

    ## Build and test

    - Build:
    - Test:

    ## Conventions

    -

    ## Notes

    """

    public static let claudeTemplate = """
    # Project instructions

    Read by Claude Code at the start of every session in this project.

    ## Overview

    What this project is and how it is laid out.

    ## Build and test

    - Build:
    - Test:

    ## Conventions

    -

    ## Notes

    """
}
