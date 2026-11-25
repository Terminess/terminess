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

final class ScreenMenuCodexApprovalTests: XCTestCase {
    func testCodexMCPApproval() {
        let lines = """

          Field 1/1
          Allow the terminess MCP server to run tool "borrow"?

          task: Open https://www.google.com/ in a visible Chrome tab on t...

        › 1. Allow                Run the tool and continue
          2. Allow for this session  Run the tool and remember this choice for this session
          3. Always allow         Run the tool and remember this choice for future tool calls
          4. Cancel               Cancel this tool call
          enter to submit | esc to cancel

        """.components(separatedBy: "\n")
        let m = ScreenMenu.find(lines: lines, width: 120)
        XCTAssertEqual(m?.options, ["Allow", "Allow for this session", "Always allow", "Cancel"])
        XCTAssertEqual(m?.selected, 0)
    }
}

final class ScreenMenuShapeTests: XCTestCase {
    private func split(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    func testTrustCheckWithoutAnyFooter() {
        let m = ScreenMenu.find(lines: split("""
         Accessing workspace:

         /srv/app

         Is this a project you trust?

         ❯ No, exit
           Yes, I trust this folder

        """), width: 100)
        XCTAssertEqual(m?.options, ["No, exit", "Yes, I trust this folder"])
    }

    func testNumberedMenuWithInventedFooter() {
        let m = ScreenMenu.find(lines: split("""
          Run this command?
          rm -rf build

        › 1. Yes
          2. Yes, and don't ask again for rm
          3. No, tell the agent what to do differently
          ⏎ pick one   ⎋ back out

        """), width: 100)
        XCTAssertEqual(m?.options, ["Yes", "Yes, and don't ask again for rm", "No, tell the agent what to do differently"])
        XCTAssertEqual(m?.text.last, "Run this command? rm -rf build")
    }

    func testCursorOnSecondOption() {
        let m = ScreenMenu.find(lines: split("""
          Pick a model
            1. Small
          > 2. Large
            3. Huge
        """), width: 80)
        XCTAssertEqual(m?.options, ["Small", "Large", "Huge"])
        XCTAssertEqual(m?.selected, 1)
    }

    func testIdleInputBoxIsNotAMenu() {
        XCTAssertNil(ScreenMenu.find(lines: split("""
        ────────────────────────────────────────
        ❯ Try "edit <filepath> to…"
        ────────────────────────────────────────
          ⏵⏵ auto mode on (shift+tab to cycle)
        """), width: 100))
    }

    func testTypedMessageIsNotAMenu() {
        XCTAssertNil(ScreenMenu.find(lines: split("""
        ❯ now search for something on it
        ────────────────────────────────────────
          /home/ubuntu/github | Opus 5.5
        """), width: 100))
    }

    func testShellPromptAndBulletsAreNotAMenu() {
        XCTAssertNil(ScreenMenu.find(lines: split("""
        I've made three changes:
          - src/cart.js: rounding
          - src/discounts.js: SPRING20
        > npm test
        ubuntu@vps:~$
        """), width: 100))
    }
    func testWrappedMessageOnPhoneIsNotAMenu() {
        XCTAssertNil(ScreenMenu.find(lines: split("""
        ❯ I want to see the latest version of aai.example.com
          that you mocked up yesterday

        ✻ Thinking…

        ──────────────────────────────────────────────────
        ❯ 
        ──────────────────────────────────────────────────
        """), width: 50))
    }
}
