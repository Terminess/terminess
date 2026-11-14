import XCTest
@testable import TermHost

final class PairingTests: XCTestCase {
    let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample phone"

    func testProofChecksOut() {
        let p = Pairing.proof(code: "abc123", key: key)
        XCTAssertTrue(Pairing.verify(code: "abc123", key: key, proof: p))
    }

    func testSwappedKeyFails() {
        let p = Pairing.proof(code: "abc123", key: key)
        XCTAssertFalse(Pairing.verify(code: "abc123", key: key + "x", proof: p))
        XCTAssertFalse(Pairing.verify(code: "other", key: key, proof: p))
        XCTAssertFalse(Pairing.verify(code: "", key: key, proof: Pairing.proof(code: "", key: key)))
        XCTAssertFalse(Pairing.verify(code: "abc123", key: key, proof: "zz"))
        XCTAssertFalse(Pairing.verify(code: "abc123", key: key, proof: ""))
    }

    func testReplyIsNotTheProof() {
        XCTAssertNotEqual(Pairing.proof(code: "c", key: key), Pairing.reply(code: "c", key: key))
    }

    func testContentLength() {
        XCTAssertEqual(Pairing.contentLength(head: "POST /pair HTTP/1.1\r\nContent-Length: 42"), 42)
        XCTAssertEqual(Pairing.contentLength(head: "POST /pair HTTP/1.1\r\ncontent-length:0"), 0)
        XCTAssertNil(Pairing.contentLength(head: "POST /pair HTTP/1.1\r\nContent-Length:"))
        XCTAssertNil(Pairing.contentLength(head: "POST /pair HTTP/1.1\r\nContent-Length: -5"))
        XCTAssertNil(Pairing.contentLength(head: "POST /pair HTTP/1.1\r\nContent-Length: 99999999999999999999999"))
        XCTAssertNil(Pairing.contentLength(head: "POST /pair HTTP/1.1\r\nContent-Length: 1e3"))
        XCTAssertNil(Pairing.contentLength(head: "POST /pair HTTP/1.1"))
        XCTAssertNil(Pairing.contentLength(head: "POST /pair HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2"))
    }

    func testRemotePath() {
        XCTAssertTrue(RemotePath.isSafe("~/.local/bin/terminessd"))
        XCTAssertTrue(RemotePath.isSafe("/Applications/Terminess.app/Contents/MacOS/terminessd"))
        XCTAssertFalse(RemotePath.isSafe("terminessd"))
        XCTAssertFalse(RemotePath.isSafe("/bin/sh -c 'id';"))
        XCTAssertFalse(RemotePath.isSafe("/x/$(id)"))
        XCTAssertFalse(RemotePath.isSafe("/x/`id`"))
        XCTAssertFalse(RemotePath.isSafe("/x\n/y"))
        XCTAssertFalse(RemotePath.isSafe("~root/x"))
        XCTAssertFalse(RemotePath.isSafe("/a/../etc/x"))
        XCTAssertEqual(RemotePath.shellQuoted("~/.local/bin/terminessd"), "~/'.local/bin/terminessd'")
        XCTAssertEqual(RemotePath.shellQuoted("/a b/it's"), "'/a b/it'\\''s'")
    }
}
