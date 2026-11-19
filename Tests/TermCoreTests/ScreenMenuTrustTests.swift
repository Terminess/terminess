import XCTest
@testable import TermCore

final class ScreenMenuTrustTests: XCTestCase {
    func testClaudeTrustCheck() {
        let lines = """

        ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
         Accessing workspace:

         /tmp/trusttest-a

         Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open
         source project, or work from your team). If not, take a moment to review what's in this folder first.

         Claude Code'll be able to read, edit, and execute files here.

         Security guide

         ❯ No, exit
           Yes, I trust this folder

         Enter to confirm · Esc to cancel

        """.components(separatedBy: "\n")
        let m = ScreenMenu.find(lines: lines, width: 110)
        XCTAssertEqual(m?.options, ["No, exit", "Yes, I trust this folder"])
        XCTAssertEqual(m?.selected, 0)
        XCTAssertEqual(m?.text.first, "Accessing workspace:")
    }

    func testCodexHookReview() {
        let lines = """

          Hooks need review
          1 hook is new or changed.
          Hooks can run outside the sandbox after you trust them.


        › 1. Review hooks
          2. Trust all and continue
          3. Continue without trusting (hooks won't run)

          enter confirm · esc skip

        """.components(separatedBy: "\n")
        let m = ScreenMenu.find(lines: lines, width: 110)
        XCTAssertEqual(m?.options, ["Review hooks", "Trust all and continue", "Continue without trusting (hooks won't run)"])
        XCTAssertEqual(m?.selected, 0)
    }
}
