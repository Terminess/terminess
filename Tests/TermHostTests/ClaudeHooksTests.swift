import Foundation
import Testing
@testable import TermHost

@Suite struct ClaudeHooksTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-tests-\(UUID().uuidString)").path
    var path: String { dir + "/settings.json" }
    let exe = "/Applications/Terminess.app/Contents/MacOS/terminessd"

    func write(_ json: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
    }
    func read() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    @Test func installKeepsTheUsersSettingsAndHooks() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#)
        #expect(ClaudeHooks.status(executable: exe, settingsPath: path) == .off)
        try ClaudeHooks.install(executable: exe, settingsPath: path)
        #expect(ClaudeHooks.status(executable: exe, settingsPath: path) == .on)
        let obj = try read()
        #expect(obj["model"] as? String == "opus")
        let stop = try #require((obj["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
        #expect(commands.count == 2 && commands[0] == "say done")
        #expect(FileManager.default.fileExists(atPath: path + ".before-terminess"))
    }

    @Test func installingTwiceOrFromElsewhereLeavesOneCopy() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write("{}")
        try ClaudeHooks.install(executable: "/old/terminessd", settingsPath: path)
        #expect(ClaudeHooks.status(executable: exe, settingsPath: path) == .outdated)
        try ClaudeHooks.install(executable: exe, settingsPath: path)
        try ClaudeHooks.install(executable: exe, settingsPath: path)
        let hooks = try #require(try read()["hooks"] as? [String: Any])
        for event in ClaudeHooks.events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            #expect(groups.count == 1, "\(event)")
        }
    }

    @Test func uninstallRemovesOnlyOurs() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#)
        try ClaudeHooks.install(executable: exe, settingsPath: path)
        try ClaudeHooks.uninstall(settingsPath: path)
        let hooks = try #require(try read()["hooks"] as? [String: Any])
        #expect(Array(hooks.keys) == ["Stop"])
        #expect(ClaudeHooks.status(executable: exe, settingsPath: path) == .off)
    }

    @Test func leavesAnUnreadableFileAlone() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write("{ not json")
        #expect(throws: ClaudeHooks.Failure.self) { try ClaudeHooks.install(executable: exe, settingsPath: path) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "{ not json")
    }

    @Test func commandOnlyActsInsideTerminess() {
        let c = ClaudeHooks.command(executable: "/Apps/It's here/terminessd")
        #expect(c.hasPrefix(#"[ -n "$TERMINESS_SESSION" ]"#))
        #expect(c.hasSuffix("; exit 0"))
        #expect(c.contains(#"'/Apps/It'\''s here/terminessd'"#))
    }
}
