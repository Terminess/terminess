import XCTest
@testable import TermHost

final class UpdateCheckTests: XCTestCase {
    private let feed = #"{"version":"0.1.0","build":160,"url":"https://terminess.com/download","sha256":"abc","notes":"Fixes"}"#

    func testParsesFeed() {
        let info = UpdateCheck.parse(Data(feed.utf8))
        XCTAssertEqual(info, UpdateInfo(version: "0.1.0", build: 160, url: "https://terminess.com/download", sha256: "abc", notes: "Fixes"))
    }

    func testRejectsHTMLAndBadFeeds() {
        XCTAssertNil(UpdateCheck.parse(Data("<html>404 Not Found</html>".utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"version":"0.1.0","build":0,"url":"https://x"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"version":"0.1.0","build":5,"url":"http://insecure"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"build":5}"#.utf8)))
    }

    func testCompare() {
        let latest = UpdateInfo(version: "0.1.0", build: 160, url: "https://terminess.com/download")
        XCTAssertEqual(UpdateCheck.compare(currentBuild: "156", latest: latest), .available(latest))
        XCTAssertEqual(UpdateCheck.compare(currentBuild: "160", latest: latest), .upToDate)
        XCTAssertEqual(UpdateCheck.compare(currentBuild: "170", latest: latest), .upToDate)
        XCTAssertEqual(UpdateCheck.compare(currentBuild: nil, latest: latest), .available(latest))
        XCTAssertEqual(UpdateCheck.compare(currentBuild: "dev", latest: latest), .available(latest))
    }
}
