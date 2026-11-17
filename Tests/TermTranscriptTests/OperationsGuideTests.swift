import XCTest
@testable import TermTranscript

final class OperationsGuideTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "opsguide-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    func testCandidatesPutConfiguredFirstThenHomeAndDedupe() {
        let c = OperationsGuide.candidateFolders(home: "/h", configured: "~/github")
        XCTAssertEqual(c.first, "/h/github")
        XCTAssertEqual(c[1], "/h")
        XCTAssertEqual(c.filter { $0 == "/h/github" }.count, 1)
    }

    func testLocateFallsBackToHomeWhenNothingExists() {
        let s = OperationsGuide.locate(home: home, configured: nil)
        XCTAssertEqual(s.folder, home)
        XCTAssertFalse(s.exists)
        XCTAssertEqual(s.operations.path, home + "/OPERATIONS.md")
    }

    func testLocateFindsAGuideBesideTheRepos() throws {
        let gh = home + "/github"
        try FileManager.default.createDirectory(atPath: gh, withIntermediateDirectories: true)
        try "# OPERATIONS.md\nline two\n".write(toFile: gh + "/OPERATIONS.md", atomically: true, encoding: .utf8)
        let s = OperationsGuide.locate(home: home, configured: nil)
        XCTAssertEqual(s.folder, gh)
        XCTAssertTrue(s.operations.exists)
        XCTAssertFalse(s.orchestrate.exists)
        XCTAssertFalse(s.complete)
        XCTAssertEqual(s.operations.lines, 3)
        XCTAssertNotNil(s.operations.modified)
    }

    func testConfiguredFolderWinsEvenWhenEmpty() {
        let s = OperationsGuide.locate(home: home, configured: "~/notes")
        XCTAssertEqual(s.folder, home + "/notes")
    }

    func testTildeAndExpand() {
        XCTAssertEqual(OperationsGuide.tilde("/h/github/OPERATIONS.md", home: "/h"), "~/github/OPERATIONS.md")
        XCTAssertEqual(OperationsGuide.expand("~/x", home: "/h"), "/h/x")
        XCTAssertEqual(OperationsGuide.tilde("/other/x", home: "/h"), "/other/x")
    }

    func testBuildPromptCoversScanInterviewSectionsSecretsAndReview() {
        let p = OperationsGuide.buildPrompt(operations: "~/OPERATIONS.md", orchestrate: "~/ORCHESTRATE.md",
                                            agent: "claude", projectRoots: ["~/github"], machines: ["headless"])
        XCTAssertTrue(p.contains("~/github"))
        XCTAssertTrue(p.contains("headless"))
        XCTAssertTrue(p.contains("~/.ssh/config"))
        XCTAssertTrue(p.contains("crontab"))
        XCTAssertTrue(p.contains("NEVER write a secret value"))
        XCTAssertTrue(p.contains("pair review codex"), "Claude's draft is reviewed by Codex")
        for s in OperationsGuide.operationsSections + OperationsGuide.orchestrateSections {
            XCTAssertTrue(p.contains(s.title), "missing section \(s.title)")
        }
        XCTAssertTrue(p.contains("Maintaining this file"))
    }

    func testCodexDraftIsReviewedByClaude() {
        XCTAssertEqual(OperationsGuide.reviewer(for: "codex"), "claude")
        let p = OperationsGuide.buildPrompt(operations: "a", orchestrate: "b", agent: "codex", projectRoots: [], machines: [])
        XCTAssertTrue(p.contains("pair review claude"))
        XCTAssertTrue(p.contains("none configured"))
    }

    func testUpdatePromptAsksBeforeEditing() {
        let p = OperationsGuide.updatePrompt(operations: "~/OPERATIONS.md", orchestrate: "~/ORCHESTRATE.md",
                                             agent: "claude", projectRoots: [], machines: [])
        XCTAssertTrue(p.contains("Do not edit anything until I agree"))
        XCTAssertTrue(p.contains("~/.codex/sessions"))
    }

    func testPromptsUseNoDashCharacters() {
        let all = OperationsGuide.buildPrompt(operations: "a", orchestrate: "b", agent: "claude", projectRoots: [], machines: [])
            + OperationsGuide.updatePrompt(operations: "a", orchestrate: "b", agent: "claude", projectRoots: [], machines: [])
        for ch in ["\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}"] { XCTAssertFalse(all.contains(ch)) }
    }

    func testPointerIsAddedOnceUnderItsOwnHeading() {
        let start = "# Rules\nBe nice."
        let added = OperationsGuide.addingPointer(to: start, operations: "~/OPERATIONS.md", orchestrate: "~/ORCHESTRATE.md")
        XCTAssertNotNil(added)
        XCTAssertTrue(added!.hasPrefix("# Rules\nBe nice.\n\n## Operations guide\n\n"))
        XCTAssertTrue(added!.contains("Read ~/OPERATIONS.md before infrastructure work; ~/ORCHESTRATE.md for dividing work."))
        XCTAssertNil(OperationsGuide.addingPointer(to: added!, operations: "x", orchestrate: "y"), "never added twice")
        XCTAssertEqual(OperationsGuide.addingPointer(to: "", operations: "a", orchestrate: "b"),
                       "## Operations guide\n\nRead a before infrastructure work; b for dividing work.\n")
    }

    func testExistingMentionCountsAsAPointer() {
        XCTAssertTrue(OperationsGuide.hasPointer("Read `~/github/OPERATIONS.md` before work"))
        XCTAssertFalse(OperationsGuide.hasPointer("nothing here"))
    }
}
