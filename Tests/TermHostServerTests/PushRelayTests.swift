import XCTest
@testable import TermHostServer

final class PushRelayTests: XCTestCase {
    func testOnlyPlainHTTPSRelaysAreAccepted() {
        XCTAssertEqual(PushRegistry.validRelay("https://push.example.com/v1"), "https://push.example.com/v1")
        XCTAssertEqual(PushRegistry.validRelay("https://push.example.com/v1/"), "https://push.example.com/v1")
        XCTAssertNil(PushRegistry.validRelay("http://push.example.com/v1"))
        XCTAssertNil(PushRegistry.validRelay("https://user:pass@push.example.com/v1"))
        XCTAssertNil(PushRegistry.validRelay("https://push.example.com/v1?x=1"))
        XCTAssertNil(PushRegistry.validRelay("file:///etc/passwd"))
        XCTAssertNil(PushRegistry.validRelay(""))
        XCTAssertNil(PushRegistry.validRelay(nil))
    }

    func testDefaultRelayIsTheTerminessRelayBase() {
        if ProcessInfo.processInfo.environment["TERMINESS_PUSH_RELAY"] == nil {
            XCTAssertEqual(PushRegistry.defaultRelay, "https://push.terminess.com/v1")
        }
    }
}
