import XCTest
@testable import TermHostServer

final class ProjectFoldersTests: XCTestCase {
    func testListsHomeFoldersAndCodeFolderChildren() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "folders-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: home) }
        for d in ["github/alpha", "github/Beta", "github/.hidden", "notes/deep", ".config", "sessions"] {
            try fm.createDirectory(atPath: home + "/" + d, withIntermediateDirectories: true)
        }
        try Data().write(to: URL(fileURLWithPath: home + "/github/file.txt"))
        let got = Projects.folders(home: home).map { String($0.dropFirst(home.count + 1)) }
        XCTAssertEqual(got, ["github", "notes", "sessions", "github/alpha", "github/Beta"])
    }
}
