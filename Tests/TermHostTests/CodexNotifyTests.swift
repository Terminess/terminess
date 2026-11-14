import Foundation
import Testing
@testable import TermHost

@Suite struct CodexNotifyTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-tests-\(UUID().uuidString)").path
    var path: String { dir + "/config.toml" }
    let exe = "/Applications/Terminess.app/Contents/MacOS/terminessd"

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    func read() throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    @Test func installGoesBeforeTheFirstTable() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write("model = \"gpt\"\n\n[mcp_servers.x]\ncommand = \"x\"\n")
        try CodexNotify.install(executable: exe, configPath: path)
        let text = try read()
        let notify = try #require(text.range(of: "notify = ")), table = try #require(text.range(of: "[mcp_servers.x]"))
        #expect(notify.lowerBound < table.lowerBound)
        #expect(text.contains(#"notify = ["/Applications/Terminess.app/Contents/MacOS/terminessd", "hook", "codex"]"#))
        #expect(text.contains("model = \"gpt\"") && text.contains("command = \"x\""))
        #expect(CodexNotify.status(executable: exe, configPath: path) == .on)
    }

    @Test func neverReplacesSomeoneElsesNotify() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let original = "notify = [\"python3\", \"/home/me/notify.py\"]\n[tui]\nnotifications = true\n"
        try write(original)
        #expect(CodexNotify.status(executable: exe, configPath: path) == .taken)
        #expect(throws: CodexNotify.Failure.self) { try CodexNotify.install(executable: exe, configPath: path) }
        try CodexNotify.uninstall(configPath: path)
        #expect(try read() == original)
    }

    @Test func refreshAndUninstallTouchOnlyOurLine() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write("model = \"gpt\"\n")
        try CodexNotify.install(executable: "/old/terminessd", configPath: path)
        #expect(CodexNotify.status(executable: exe, configPath: path) == .outdated)
        try CodexNotify.install(executable: exe, configPath: path)
        #expect(try read().components(separatedBy: "notify = ").count == 2)
        try CodexNotify.uninstall(configPath: path)
        #expect(try read() == "model = \"gpt\"\n")
        #expect(CodexNotify.status(executable: exe, configPath: path) == .off)
    }

    @Test func notifyInsideATableIsntTopLevel() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write("[tui]\nnotify = true\n")
        #expect(CodexNotify.status(executable: exe, configPath: path) == .off)
        try CodexNotify.install(executable: exe, configPath: path)
        #expect(try read().hasPrefix(CodexNotify.comment + "\nnotify = ["))
    }
}
