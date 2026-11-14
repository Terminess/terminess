import Foundation
import Testing
@testable import TermTranscript

@Suite struct AgentLibraryTests {
    @Test func frontmatter() {
        let text = """
        ---
        name: pdf-tools
        description: "Fill and merge PDFs: forms too."
        long: >
          First line
          second line
        ---
        # Body
        description: not this
        """
        let f = AgentLibrary.frontmatter(text)
        #expect(f["name"] == "pdf-tools")
        #expect(f["description"] == "Fill and merge PDFs: forms too.")
        #expect(f["long"] == "First line second line")
        #expect(AgentLibrary.frontmatter("# No frontmatter\nname: x").isEmpty)
    }

    static let toml = """
    model = "gpt-5"

    [mcp_servers.acme]
    command = "npx"
    args = [ "-y", "@acme/mcp@1.3.7" ]

    [mcp_servers.acme.env]
    TOKEN = "abc"

    [projects."/Users/me/code"]
    trust_level = "trusted"

    [mcp_servers."docs-server"]
    command = 'uvx' # comment
    url = "https://example.com/mcp"
    """

    @Test func codexServers() {
        let s = AgentLibrary.codexMCPServers(Self.toml)
        #expect(s.map(\.name) == ["acme", "docs-server"])
        #expect(s[0].command == "npx")
        #expect(s[0].args == ["-y", "@acme/mcp@1.3.7"])
        #expect(s[1].command == "uvx")
        #expect(s[1].url == "https://example.com/mcp")
    }

    @Test func removeKeepsEverythingElse() throws {
        let r = try #require(AgentLibrary.removingCodexMCPServer("acme", from: Self.toml))
        #expect(r.toml == """
        model = "gpt-5"

        [projects."/Users/me/code"]
        trust_level = "trusted"

        [mcp_servers."docs-server"]
        command = 'uvx' # comment
        url = "https://example.com/mcp"
        """)
        #expect(r.removed.hasPrefix("[mcp_servers.acme]\n"))
        #expect(r.removed.contains("TOKEN = \"abc\""))
        #expect(AgentLibrary.removingCodexMCPServer("missing", from: Self.toml) == nil)
        let last = try #require(AgentLibrary.removingCodexMCPServer("docs-server", from: Self.toml))
        #expect(last.toml.hasSuffix("trust_level = \"trusted\"\n\n"))
    }

    @Test func appendRoundTrips() {
        let out = AgentLibrary.appendingCodexMCPServer(name: "fs", command: "npx", args: ["-y", "say \"hi\""],
                                                       env: [("KEY", "v")], to: "model = \"x\"")
        #expect(out.hasPrefix("model = \"x\"\n\n[mcp_servers.fs]\n"))
        let s = AgentLibrary.codexMCPServers(out)
        #expect(s == [AgentLibrary.MCPServer(name: "fs", command: "npx", args: ["-y", "say \"hi\""])])
        #expect(AgentLibrary.removingCodexMCPServer("fs", from: out)?.toml == "model = \"x\"\n\n")
    }

    @Test func claudeJSON() {
        let obj: [String: Any] = ["mcpServers": [
            "b": ["command": "npx", "args": ["-y", "pkg"]],
            "a": ["type": "http", "url": "https://x.dev/mcp"],
        ]]
        let s = AgentLibrary.mcpServers(inJSON: obj)
        #expect(s.map(\.name) == ["a", "b"])
        #expect(s[0].summary == "https://x.dev/mcp")
        #expect(s[1].summary == "npx -y pkg")
    }

    @Test func splitArgs() {
        #expect(AgentLibrary.splitArgs(#"npx -y "a b" 'c d' e\ f """#) == ["npx", "-y", "a b", "c d", "e f", ""])
    }

    @Test func names() {
        #expect(AgentLibrary.isValidName("pdf-tools_2"))
        #expect(!AgentLibrary.isValidName(".disabled"))
        #expect(!AgentLibrary.isValidName("../x"))
        #expect(!AgentLibrary.isValidName("-x"))
        #expect(AgentLibrary.isSafeRelativePath("scripts/run.sh"))
        #expect(!AgentLibrary.isSafeRelativePath("../etc"))
        #expect(!AgentLibrary.isSafeRelativePath("/etc"))
    }

    @Test func gitHubURLs() {
        typealias L = AgentLibrary.GitHubLocation
        #expect(AgentLibrary.parseGitHubURL("https://github.com/acme/skills/tree/main/skills/pdf")
                == L(owner: "acme", repo: "skills", ref: "main", path: "skills/pdf", isFile: false))
        #expect(AgentLibrary.parseGitHubURL("github.com/acme/skills/blob/v1/pdf/SKILL.md")
                == L(owner: "acme", repo: "skills", ref: "v1", path: "pdf/SKILL.md", isFile: true))
        #expect(AgentLibrary.parseGitHubURL("https://raw.githubusercontent.com/acme/skills/main/a.md")
                == L(owner: "acme", repo: "skills", ref: "main", path: "a.md", isFile: true))
        #expect(AgentLibrary.parseGitHubURL("https://github.com/acme/skills.git")
                == L(owner: "acme", repo: "skills", ref: nil, path: "", isFile: false))
        #expect(AgentLibrary.parseGitHubURL("https://example.com/a/b") == nil)
        #expect(AgentLibrary.parseGitHubURL("https://github.com/acme/skills/issues/3") == nil)
    }
}
