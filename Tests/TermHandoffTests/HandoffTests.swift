import XCTest
import Foundation
@testable import TermHandoff

final class HandoffTests: XCTestCase {
    var base: String!

    override func setUp() {
        base = NSTemporaryDirectory() + "handoff-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: base) }

    @discardableResult
    func sh(_ cmd: String, in dir: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@t"; env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@t"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func makePair() -> (srcHome: String, dstHome: String, src: String, dst: String) {
        let srcHome = base + "/src-home", dstHome = base + "/dst-home"
        let src = srcHome + "/github/app", dst = dstHome + "/github/app"
        try! FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        sh("git init -q -b main && printf 'one\\n' > a.txt && printf '\\x00\\x01bin' > b.bin && git add . && git commit -q -m init", in: src)
        try! FileManager.default.createDirectory(atPath: dstHome + "/github", withIntermediateDirectories: true)
        sh("git clone -q \(src) \(dst)", in: dstHome + "/github")
        return (srcHome, dstHome, src, dst)
    }

    func transcript(cwd: String) -> Data {
        Data("""
        {"type":"user","cwd":"\(cwd)","message":{"content":"edit \(cwd)/a.txt"}}
        {"type":"assistant","cwd":"\(cwd)","message":{"content":"done, see \(cwd)/a.txt and not \(cwd)x"}}

        """.utf8)
    }


    func testProjectDirNameMatchesClaudeCode() {
        XCTAssertEqual(Handoff.projectDirName("/Users/user/github/terminal"), "-Users-user-github-terminal")
        XCTAssertEqual(Handoff.projectDirName("/home/ubuntu/.local/state/ops"), "-home-ubuntu--local-state-ops")
        XCTAssertEqual(Handoff.projectDirName("/home/ubuntu/github/acme.dev"), "-home-ubuntu-github-acme-dev")
    }

    func testRewriteReplacesWholePathsOnly() {
        let d = Data(#"{"cwd":"/home/u/github/app","x":"/home/u/github/app/a.txt","y":"/home/u/github/apple"}"#.utf8)
        let out = String(decoding: Handoff.rewrite(d, from: "/home/u/github/app", to: "/Users/n/github/app"), as: UTF8.self)
        XCTAssertEqual(out, #"{"cwd":"/Users/n/github/app","x":"/Users/n/github/app/a.txt","y":"/home/u/github/apple"}"#)
    }

    func testTargetCwdByRepoNameAndSubfolder() {
        var info = HandoffInfo(agent: "claude", conversation: "c1", cwd: "/home/u/github/app/web", repoRoot: "/home/u/github/app",
                               repoName: "app", relativeCwd: "web", branch: "main", head: "abc", changedFiles: 0, transcriptPath: "", transcriptBytes: 0)
        XCTAssertEqual(try Handoff.targetCwd(info, sourceRoot: "/home/u/github", targetRoot: "/Users/n/github").get(), "/Users/n/github/app/web")
        info.repoRoot = nil; info.repoName = nil; info.relativeCwd = ""; info.cwd = "/home/u/github"
        XCTAssertEqual(try Handoff.targetCwd(info, sourceRoot: "/home/u/github", targetRoot: "/Users/n/github").get(), "/Users/n/github")
        info.cwd = "/etc"
        XCTAssertEqual(Handoff.targetCwd(info, sourceRoot: "/home/u/github", targetRoot: "/Users/n/github").failureValue, .outsideRoots("/etc"))
    }


    func testBundleCarriesTrackedBinaryAndUntrackedThenImports() throws {
        let (srcHome, dstHome, src, dst) = makePair()
        sh("printf 'two\\n' >> a.txt && printf '\\x02\\x03' >> b.bin && mkdir -p new && printf 'hi' > new/n.txt && chmod +x new/n.txt", in: src)
        let tpath = srcHome + "/.claude/projects/" + Handoff.projectDirName(src) + "/conv-1.jsonl"
        try FileManager.default.createDirectory(atPath: (tpath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try transcript(cwd: src).write(to: URL(fileURLWithPath: tpath))

        let info = Handoff.describe(agent: "claude", conversation: "conv-1", cwd: src, transcript: tpath)
        XCTAssertEqual(info.repoName, "app")
        XCTAssertEqual(info.branch, "main")
        XCTAssertEqual(info.changedFiles, 3)
        var bundle = try Handoff.bundle(info, home: srcHome).get()
        bundle.info.home = srcHome
        XCTAssertNotNil(bundle.patch)
        XCTAssertEqual(bundle.untracked.map(\.path), ["new/n.txt"])
        XCTAssertTrue(bundle.untracked[0].executable)

        let wire = try XCTUnwrap(HandoffTransfer.decode(try XCTUnwrap(HandoffTransfer.encode(bundle))))
        let result = try Handoff.importBundle(wire, sourceRoot: "~/github", targetRoot: "~/github", home: dstHome).get()
        XCTAssertEqual(result.cwd, dst)
        XCTAssertEqual(result.resumeCommand, "claude --resume conv-1")
        XCTAssertEqual(try String(contentsOfFile: dst + "/a.txt", encoding: .utf8), "one\ntwo\n")
        XCTAssertEqual(FileManager.default.contents(atPath: dst + "/b.bin"), FileManager.default.contents(atPath: src + "/b.bin"))
        XCTAssertEqual(try String(contentsOfFile: dst + "/new/n.txt", encoding: .utf8), "hi")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dst + "/new/n.txt"))
        XCTAssertEqual(sh("git rev-list --count HEAD", in: dst).1.trimmingCharacters(in: .whitespacesAndNewlines), "1")

        let placed = dstHome + "/.claude/projects/" + Handoff.projectDirName(dst) + "/conv-1.jsonl"
        let text = try String(contentsOfFile: placed, encoding: .utf8)
        XCTAssertTrue(text.contains("\"cwd\":\"\(dst)\""))
        XCTAssertTrue(text.contains("\(dst)/a.txt"))
        XCTAssertTrue(text.contains("not \(src)x"), "a longer path that merely starts the same is left alone")
        XCTAssertFalse(text.contains("\"cwd\":\"\(src)\""))
    }

    func testRefusesWhenCopiesDiverge() throws {
        let (srcHome, dstHome, src, dst) = makePair()
        sh("printf 'x' > c.txt && git add . && git commit -q -m other", in: dst)
        let tpath = srcHome + "/t.jsonl"
        try transcript(cwd: src).write(to: URL(fileURLWithPath: tpath))
        var bundle = try Handoff.bundle(Handoff.describe(agent: "claude", conversation: "c2", cwd: src, transcript: tpath), home: srcHome).get()
        bundle.info.home = srcHome
        guard case .failure(.diverged) = Handoff.importBundle(bundle, sourceRoot: "~/github", targetRoot: "~/github", home: dstHome) else {
            return XCTFail("expected diverged")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstHome + "/.claude"), "nothing written when refusing")
    }

    func testRefusesWhenRepoMissing() throws {
        let (srcHome, dstHome, src, dst) = makePair()
        try FileManager.default.removeItem(atPath: dst)
        let tpath = srcHome + "/t.jsonl"
        try transcript(cwd: src).write(to: URL(fileURLWithPath: tpath))
        var bundle = try Handoff.bundle(Handoff.describe(agent: "claude", conversation: "c3", cwd: src, transcript: tpath), home: srcHome).get()
        bundle.info.home = srcHome
        XCTAssertEqual(Handoff.importBundle(bundle, sourceRoot: "~/github", targetRoot: "~/github", home: dstHome).failureValue, .missingRepo(dst))
    }

    func testTargetsOwnChangesAreStashedAndBackedUpNotLost() throws {
        let (srcHome, dstHome, src, dst) = makePair()
        sh("printf 'mine\\n' >> a.txt", in: src)
        sh("printf 'theirs\\n' > a.txt && printf 'keep' > local.txt", in: dst)
        let tpath = srcHome + "/t.jsonl"
        try transcript(cwd: src).write(to: URL(fileURLWithPath: tpath))
        var bundle = try Handoff.bundle(Handoff.describe(agent: "claude", conversation: "c4", cwd: src, transcript: tpath), home: srcHome).get()
        bundle.info.home = srcHome
        let result = try Handoff.importBundle(bundle, sourceRoot: "~/github", targetRoot: "~/github", home: dstHome).get()
        XCTAssertEqual(try String(contentsOfFile: dst + "/a.txt", encoding: .utf8), "one\nmine\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/local.txt"), "stashed, not deleted")
        XCTAssertTrue(sh("git stash list", in: dst).1.contains("terminess handoff"))
        XCTAssertEqual(result.backups.count, 1)
        XCTAssertTrue(try String(contentsOfFile: result.backups[0], encoding: .utf8).contains("theirs"))
        sh("git checkout -- . && git stash pop -q", in: dst)
        XCTAssertEqual(try String(contentsOfFile: dst + "/local.txt", encoding: .utf8), "keep")
    }

    func testSameChangesAlreadyThereAreLeftAlone() throws {
        let (srcHome, dstHome, src, dst) = makePair()
        sh("printf 'same\\n' >> a.txt", in: src)
        sh("printf 'same\\n' >> a.txt", in: dst)
        let tpath = srcHome + "/t.jsonl"
        try transcript(cwd: src).write(to: URL(fileURLWithPath: tpath))
        var bundle = try Handoff.bundle(Handoff.describe(agent: "claude", conversation: "c5", cwd: src, transcript: tpath), home: srcHome).get()
        bundle.info.home = srcHome
        let result = try Handoff.importBundle(bundle, sourceRoot: "~/github", targetRoot: "~/github", home: dstHome).get()
        XCTAssertTrue(result.notes.contains { $0.contains("already here") })
        XCTAssertFalse(sh("git stash list", in: dst).1.contains("terminess"))
    }

    func testExistingTranscriptOnTargetIsBackedUp() throws {
        let (srcHome, dstHome, src, dst) = makePair()
        let tpath = srcHome + "/t.jsonl"
        try transcript(cwd: src).write(to: URL(fileURLWithPath: tpath))
        let old = dstHome + "/.claude/projects/" + Handoff.projectDirName(dst) + "/c6.jsonl"
        try FileManager.default.createDirectory(atPath: (old as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("older copy\n".utf8).write(to: URL(fileURLWithPath: old))
        var bundle = try Handoff.bundle(Handoff.describe(agent: "claude", conversation: "c6", cwd: src, transcript: tpath), home: srcHome).get()
        bundle.info.home = srcHome
        let result = try Handoff.importBundle(bundle, sourceRoot: "~/github", targetRoot: "~/github", home: dstHome).get()
        XCTAssertEqual(result.backups.count, 1)
        XCTAssertEqual(try String(contentsOfFile: result.backups[0], encoding: .utf8), "older copy\n")
    }

    func testUnknownConversationIsRefusedNotGuessed() {
        XCTAssertEqual(Handoff.info(pid: 999_999, agent: "claude", home: base).failureValue,
                       .unknownConversation("no session record for process 999999"))
        XCTAssertEqual(Handoff.info(pid: 123, agent: "bash", home: base).failureValue, .noAgent)
    }

    func testClaudeSessionRecordIdentifiesConversation() throws {
        let home = base + "/h"
        let cwd = home + "/github/app"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        try Data(#"{"pid":4242,"sessionId":"abc-123","cwd":"\#(cwd)"}"#.utf8).write(to: URL(fileURLWithPath: home + "/.claude/sessions/4242.json"))
        let t = home + "/.claude/projects/" + Handoff.projectDirName(cwd) + "/abc-123.jsonl"
        try FileManager.default.createDirectory(atPath: (t as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: t))
        let info = try Handoff.info(pid: 4242, agent: "claude", home: home).get()
        XCTAssertEqual(info.conversation, "abc-123")
        XCTAssertEqual(info.cwd, cwd)
        XCTAssertEqual(info.transcriptPath, t)
        XCTAssertNil(info.repoRoot)
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e }; return nil }
}
