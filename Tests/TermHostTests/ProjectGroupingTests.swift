import XCTest
@testable import TermHost

final class ProjectGroupingTests: XCTestCase {
    let home = "/Users/me"
    let repos: Set<String> = ["/Users/me/github/terminal", "/Users/me/github/Webapp", "/tmp/scratch"]

    private func root(_ p: String) -> String? {
        ProjectGrouping.repoRoot(of: p, home: home, isRepo: { repos.contains($0) })
    }

    func testLocalRepoRoot() {
        XCTAssertEqual(root("/Users/me/github/terminal"), "/Users/me/github/terminal")
        XCTAssertEqual(root("/Users/me/github/terminal/Sources/TermApp"), "/Users/me/github/terminal")
        XCTAssertEqual(root("/Users/me/github/terminal/"), "/Users/me/github/terminal")
        XCTAssertEqual(root("/tmp/scratch/a"), "/tmp/scratch")
    }

    func testLocalNotInARepo() {
        XCTAssertNil(root("/Users/me"))
        XCTAssertNil(root("/Users/me/github"))
        XCTAssertNil(root("/Users/me/Documents/notes"))
        XCTAssertNil(root("/opt/thing"))
        XCTAssertNil(root(""))
        XCTAssertNil(ProjectGrouping.repoRoot(of: "/Users/me/x", home: home, isRepo: { $0 == "/Users/me" }))
    }

    func testRemoteMatchesLocalProjectByName() {
        let names: Set<String> = ["terminal", "Webapp"]
        XCTAssertEqual(ProjectGrouping.remoteProject(cwd: "/home/ubuntu/github/terminal", localNames: names, remoteProjects: []), "terminal")
        XCTAssertEqual(ProjectGrouping.remoteProject(cwd: "/home/ubuntu/github/terminal/Sources", localNames: names, remoteProjects: []), "terminal")
        XCTAssertEqual(ProjectGrouping.remoteProject(cwd: "/root/work/Webapp", localNames: names, remoteProjects: []), "Webapp")
    }

    func testRemoteFallsBackToItsOwnProjects() {
        let projects = ["/home/ubuntu/github", "/home/ubuntu/github/newthing", "/home/ubuntu"]
        XCTAssertEqual(ProjectGrouping.remoteProject(cwd: "/home/ubuntu/github/newthing/src", localNames: [], remoteProjects: projects), "newthing")
        XCTAssertNil(ProjectGrouping.remoteProject(cwd: "/home/ubuntu/github", localNames: [], remoteProjects: projects))
        XCTAssertNil(ProjectGrouping.remoteProject(cwd: "/home/ubuntu", localNames: [], remoteProjects: projects))
        XCTAssertNil(ProjectGrouping.remoteProject(cwd: "/home/ubuntu/github/unknown", localNames: [], remoteProjects: projects))
    }

    func testRemoteHomeIsNotAProjectEvenIfNamedLikeOne() {
        XCTAssertNil(ProjectGrouping.remoteProject(cwd: "/home/terminal", localNames: ["terminal"], remoteProjects: []))
    }

    func testBelowRemoteHome() {
        XCTAssertEqual(ProjectGrouping.belowRemoteHome("/home/ubuntu/github/x"), ["github", "x"])
        XCTAssertEqual(ProjectGrouping.belowRemoteHome("/Users/me"), [])
        XCTAssertEqual(ProjectGrouping.belowRemoteHome("/root/a"), ["a"])
        XCTAssertEqual(ProjectGrouping.belowRemoteHome("/srv/app"), ["srv", "app"])
    }

    func testLimitThree() {
        let items = Array(1...8)
        let folded = ProjectGrouping.limited(items, expanded: false)
        XCTAssertEqual(folded.visible, [1, 2, 3])
        XCTAssertEqual(folded.more, 5)
        let open = ProjectGrouping.limited(items, expanded: true)
        XCTAssertEqual(open.visible, items)
        XCTAssertEqual(open.more, 5)
        let few = ProjectGrouping.limited([1, 2], expanded: false)
        XCTAssertEqual(few.visible, [1, 2])
        XCTAssertEqual(few.more, 0)
    }

    func testCommitCount() {
        XCTAssertEqual(ProjectGrouping.commitCount("12\n"), 12)
        XCTAssertEqual(ProjectGrouping.commitCount(" 0 "), 0)
        XCTAssertNil(ProjectGrouping.commitCount("fatal: not a git repository"))
        XCTAssertNil(ProjectGrouping.commitCount(""))
        XCTAssertEqual(ProjectGrouping.commitsSinceArguments(1794700000.7), ["rev-list", "--count", "--since=@1794700000", "HEAD"])
    }

    func testPathProject() {
        let known = ["/home/ubuntu/notes/site", "/Users/user/Documents"]
        XCTAssertEqual(ProjectGrouping.pathProject(cwd: "/home/ubuntu/github/terminal", knownFolders: []), "terminal")
        XCTAssertEqual(ProjectGrouping.pathProject(cwd: "/Users/user/github/terminal/Sources/TermApp", knownFolders: []), "terminal")
        XCTAssertNil(ProjectGrouping.pathProject(cwd: "/home/ubuntu/github", knownFolders: known))
        XCTAssertNil(ProjectGrouping.pathProject(cwd: "/home/ubuntu", knownFolders: known))
        XCTAssertEqual(ProjectGrouping.pathProject(cwd: "/home/ubuntu/notes/site/drafts", knownFolders: known), "site")
        XCTAssertNil(ProjectGrouping.pathProject(cwd: "/tmp/x", knownFolders: known))
    }
}
