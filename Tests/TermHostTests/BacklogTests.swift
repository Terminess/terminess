import Darwin
import XCTest
@testable import TermHost

final class BacklogTests: XCTestCase {
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
    }

    func testStalledReaderIsDropped() {
        let (a, b) = pair()
        defer { close(b) }
        let q = DispatchQueue(label: "t")
        let conn = Connection(readFD: a, queue: q, buffered: true)
        conn.stallTimeout = 0
        let closed = expectation(description: "closed")
        conn.onClose = { closed.fulfill() }
        let chunk = [UInt8](repeating: 65, count: 64 * 1024)
        q.sync {
            let start = Date()
            for _ in 0..<200 { conn.send(.init(.output, chunk)) }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, "sending must not wait for the reader")
        }
        wait(for: [closed], timeout: 2)
    }

    func testSlowReaderGetsEverything() {
        let (a, b) = pair()
        let q = DispatchQueue(label: "t")
        let conn = Connection(readFD: a, queue: q, buffered: true)
        let chunk = [UInt8](repeating: 66, count: 256 * 1024)
        let frames = 48
        let expected = frames * Wire.Frame(.output, chunk).encoded().count
        q.sync { for _ in 0..<frames { conn.send(.init(.output, chunk)) } }
        var got = 0
        var buf = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(5)
        while got < expected && Date() < deadline {
            let n = read(b, &buf, buf.count)
            if n > 0 { got += n }
            else { usleep(1000) }
        }
        XCTAssertEqual(got, expected)
        q.sync { XCTAssertEqual(conn.backlogCount, 0) }
        q.sync { conn.close() }
        close(b)
    }
}
