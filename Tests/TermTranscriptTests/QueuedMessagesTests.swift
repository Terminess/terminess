import XCTest
@testable import TermTranscript

final class QueuedMessagesTests: XCTestCase {
    func testOneShortMessage() {
        let screen = [
            "\u{25CF} Reading src/discounts.js",
            "",
            "> also check the free shipping threshold",
            "  \u{23BF} Queued \u{00B7} ctrl+enter to send now",
            "",
        ]
        XCTAssertEqual(QueuedMessages.parse(screen), ["also check the free shipping threshold"])
    }

    func testWrappedMessageIsJoined() {
        let screen = [
            "\u{276F} when you're done, add a test for SPRING20 stacking with",
            "  WELCOME10 and make sure [Image #1] matches the totals",
            "  \u{23BF} Queued \u{00B7} ctrl+enter to send now",
        ]
        XCTAssertEqual(QueuedMessages.parse(screen),
                       ["when you're done, add a test for SPRING20 stacking with WELCOME10 and make sure [Image #1] matches the totals"])
    }

    func testSeveralQueuedInOrder() {
        let screen = [
            "> first",
            "  \u{23BF} Queued \u{00B7} ctrl+enter to send now",
            "> second one",
            "  \u{23BF} Queued \u{00B7} ctrl+enter to send now",
        ]
        XCTAssertEqual(QueuedMessages.parse(screen), ["first", "second one"])
    }

    func testNoQueueNoMessages() {
        let screen = ["> done earlier", "  \u{23BF} Updated src/discounts.js with 1 addition", ""]
        XCTAssertEqual(QueuedMessages.parse(screen), [])
    }
}
