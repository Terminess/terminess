#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import TermHost
import TermHandoff

func handoffCommand(_ args: [String]) -> Never {
    let usage = """
    usage: terminessd handoff info SESSION [--host HOST]
           terminessd handoff pull HOST SESSION [--yes] [--no-open] [--local-root DIR] [--remote-root DIR] [--path P]
           terminessd handoff push SESSION HOST [--yes] [--no-open] [--local-root DIR] [--remote-root DIR] [--path P]
      pull: end the agent in SESSION on HOST and carry on here.  push: the reverse.
      Roots default to ~/github on both sides; repositories are matched by folder name.
    """
    let positional = args.enumerated().filter { i, a in
        !a.hasPrefix("--") && (i == 0 || !["--host", "--local-root", "--remote-root", "--path"].contains(args[i - 1]))
    }.map(\.element)
    let localRoot = value(after: "--local-root", in: args) ?? "~/github"
    let remoteRoot = value(after: "--remote-root", in: args) ?? "~/github"
    let path = value(after: "--path", in: args) ?? "~/.local/bin/terminessd"
    let yes = args.contains("--yes"), open = !args.contains("--no-open")

    func local() -> HandoffPeer { HandoffPeer(fd: connectToService()) }
    func remote(_ host: String) -> HandoffPeer {
        guard let p = HandoffPeer.ssh(host: host, path: path) else { fail("can't reach terminessd on \(host) with ssh") }
        return p
    }
    func show(_ i: HandoffInfo) {
        print("\(i.agent == "claude" ? "Claude Code" : "Codex") conversation \(i.conversation)")
        print("  folder: \(i.cwd)")
        if let r = i.repoName { print("  repository: \(r) on \(i.branch ?? "?") at \(String((i.head ?? "?").prefix(8)))") }
        print("  uncommitted changes: \(i.changedFiles == 0 ? "none" : "\(i.changedFiles) file\(i.changedFiles == 1 ? "" : "s")")")
        print("  transcript: \(i.transcriptBytes / 1024) KB")
    }
    func confirm(_ question: String) {
        guard !yes else { return }
        print(question + " [y/N] ", terminator: "")
        guard readLine()?.lowercased().hasPrefix("y") == true else { print("Nothing moved."); exit(1) }
    }
    func unwrap<T>(_ r: Result<T, HandoffError>) -> T {
        switch r { case .success(let v): return v; case .failure(let e): fail(e.description) }
    }
    func openSession(_ peer: HandoffPeer, _ result: HandoffResult, _ info: HandoffInfo) {
        let name = "\(info.agent)-\(info.repoName ?? (result.cwd as NSString).lastPathComponent)"
        let r = peer.request(Message(op: "create", host: "cli", name: name, cwd: result.cwd, command: "bash",
                                     args: ["-ic", result.resumeCommand + "; exec bash -i"]))
        if r?.op == "created", let id = r?.id { print("Resumed in session \(id) (\(name)).") } else { print("Resume it with: cd \(result.cwd) && \(result.resumeCommand)") }
    }
    func report(_ r: HandoffResult) {
        for n in r.notes { print("  " + n) }
        for b in r.backups { print("  backup: \(b)") }
    }

    switch positional.first {
    case "info":
        guard positional.count >= 2 else { fail(usage) }
        let peer = value(after: "--host", in: args).map(remote) ?? local()
        show(unwrap(HandoffTransfer.info(peer, session: positional[1])))
        exit(0)
    case "pull":
        guard positional.count >= 3 else { fail(usage) }
        let peer = remote(positional[1])
        let info = unwrap(HandoffTransfer.info(peer, session: positional[2]))
        show(info)
        confirm("End it on \(positional[1]) and carry on here?")
        let bundle = unwrap(HandoffTransfer.export(peer, session: positional[2]))
        let result = unwrap(Handoff.importBundle(bundle, sourceRoot: remoteRoot, targetRoot: localRoot))
        print("Moved to \(result.cwd).")
        report(result)
        if open { openSession(local(), result, info) } else { print("Resume it with: cd \(result.cwd) && \(result.resumeCommand)") }
        exit(0)
    case "push":
        guard positional.count >= 3 else { fail(usage) }
        let here = local()
        let info = unwrap(HandoffTransfer.info(here, session: positional[1]))
        show(info)
        let peer = remote(positional[2])
        confirm("End it here and carry on on \(positional[2])?")
        let bundle = unwrap(HandoffTransfer.export(here, session: positional[1]))
        let result = unwrap(HandoffTransfer.importRemote(peer, bundle: bundle, sourceRoot: localRoot, targetRoot: remoteRoot))
        print("Moved to \(positional[2]):\(result.cwd).")
        report(result)
        if open { openSession(peer, result, info) } else { print("Resume it there with: cd \(result.cwd) && \(result.resumeCommand)") }
        exit(0)
    default:
        fail(usage)
    }
}

func borrowCommand(_ args: [String]) -> Never {
    let task = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !task.isEmpty else { fail("usage: terminessd borrow \"what the Mac should do and report back\"") }
    let fd = connectToService()
    let session = ProcessInfo.processInfo.environment["TERMINESS_SESSION"] ?? ""
    let json = (try? JSONSerialization.data(withJSONObject: ["task": task])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    guard Connection.writeAll(fd, Wire.Frame.control(Message(op: "agent-tool", id: session, name: "borrow", message: json)).encoded()) else {
        fail("couldn't reach the service")
    }
    var decoder = Wire.Decoder()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0, let frames = try? decoder.feed(Array(buf[0..<n])) else { fail("the service closed the connection") }
        if let m = frames.compactMap(\.message).first(where: { $0.op == "agent-result" }) {
            print(m.message ?? "")
            exit(m.code == 1 ? 1 : 0)
        }
    }
}
