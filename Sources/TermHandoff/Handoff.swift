import Foundation
import TermTranscript


public struct HandoffInfo: Codable, Equatable, Sendable {
    public var agent: String
    public var conversation: String
    public var cwd: String
    public var repoRoot: String?
    public var repoName: String?
    public var relativeCwd: String
    public var branch: String?
    public var head: String?
    public var changedFiles: Int
    public var transcriptPath: String
    public var transcriptBytes: Int
    public var home: String?

    public init(agent: String, conversation: String, cwd: String, repoRoot: String?, repoName: String?, relativeCwd: String,
                branch: String?, head: String?, changedFiles: Int, transcriptPath: String, transcriptBytes: Int) {
        self.agent = agent; self.conversation = conversation; self.cwd = cwd; self.repoRoot = repoRoot
        self.repoName = repoName; self.relativeCwd = relativeCwd; self.branch = branch; self.head = head
        self.changedFiles = changedFiles; self.transcriptPath = transcriptPath; self.transcriptBytes = transcriptBytes
        self.home = Handoff.home
    }

    public var resumeCommand: String {
        agent == "codex" ? "codex resume \(Handoff.shellQuote(conversation))" : "claude --resume \(Handoff.shellQuote(conversation))"
    }
}

public struct HandoffFile: Codable, Equatable, Sendable {
    public var path: String
    public var data: Data
    public var executable: Bool
    public init(path: String, data: Data, executable: Bool) { self.path = path; self.data = data; self.executable = executable }
}

public struct HandoffBundle: Codable, Equatable, Sendable {
    public var info: HandoffInfo
    public var transcript: Data
    public var codexRelativePath: String?
    public var patch: Data?
    public var untracked: [HandoffFile]
    public init(info: HandoffInfo, transcript: Data, codexRelativePath: String?, patch: Data?, untracked: [HandoffFile]) {
        self.info = info; self.transcript = transcript; self.codexRelativePath = codexRelativePath
        self.patch = patch; self.untracked = untracked
    }
}

public struct HandoffResult: Codable, Equatable, Sendable {
    public var cwd: String
    public var resumeCommand: String
    public var backups: [String]
    public var notes: [String]
    public init(cwd: String, resumeCommand: String, backups: [String], notes: [String]) {
        self.cwd = cwd; self.resumeCommand = resumeCommand; self.backups = backups; self.notes = notes
    }
}

public enum HandoffError: Error, Equatable, CustomStringConvertible {
    case noAgent
    case unknownConversation(String)
    case missingTranscript(String)
    case outsideRoots(String)
    case missingRepo(String)
    case notARepo(String)
    case diverged(source: String, target: String)
    case tooLarge(String)
    case applyFailed(String)
    case io(String)

    public var description: String {
        switch self {
        case .noAgent:
            return "No Claude Code or Codex agent is running in that session."
        case .unknownConversation(let why):
            return "Can't tell which conversation that agent is on (\(why)), so it can't be moved safely."
        case .missingTranscript(let p):
            return "The conversation's transcript isn't where it should be: \(p)."
        case .outsideRoots(let p):
            return "\(p) isn't inside a repository or the folder of repositories, so there's no matching folder on the other machine."
        case .missingRepo(let p):
            return "There's no copy of the repository at \(p) on the other machine. Clone or copy it there first."
        case .notARepo(let p):
            return "\(p) on the other machine isn't a git repository."
        case .diverged(let s, let t):
            return "The two copies aren't on the same commit (here \(s), there \(t)). Push from one side and pull on the other first, then move it."
        case .tooLarge(let what):
            return "Too much to carry: \(what). Commit or clean up first."
        case .applyFailed(let why):
            return "The uncommitted changes didn't apply cleanly on the other machine, so nothing was changed there: \(why)"
        case .io(let why):
            return why
        }
    }
}

public enum Handoff {
    public static var home: String { Transcript.home }

    public static let untrackedLimit = 64 * 1024 * 1024


    public static func info(pid: Int32, agent: String, home: String = Handoff.home) -> Result<HandoffInfo, HandoffError> {
        guard pid > 0 else { return .failure(.noAgent) }
        var conversation: String, cwd: String, transcript: String
        switch agent {
        case "claude":
            guard let data = FileManager.default.contents(atPath: home + "/.claude/sessions/\(pid).json"),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = obj["sessionId"] as? String, isSafeID(id) else {
                return .failure(.unknownConversation("no session record for process \(pid)"))
            }
            guard let path = Transcript.claudeSession(pid: pid, home: home) else { return .failure(.missingTranscript(id + ".jsonl")) }
            conversation = id
            cwd = (obj["cwd"] as? String) ?? ""
            transcript = path
        case "codex":
            guard let path = openCodexRollout(pid: pid) else {
                return .failure(.unknownConversation("no open Codex rollout for process \(pid)"))
            }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let id = String(name.suffix(36))
            guard UUID(uuidString: id) != nil else { return .failure(.unknownConversation("unexpected rollout name")) }
            conversation = id
            cwd = codexCwd(path) ?? ""
            transcript = path
        default:
            return .failure(.noAgent)
        }
        guard !cwd.isEmpty else { return .failure(.unknownConversation("no working folder recorded")) }
        return .success(describe(agent: agent, conversation: conversation, cwd: cwd, transcript: transcript))
    }

    public static func describe(agent: String, conversation: String, cwd: String, transcript: String) -> HandoffInfo {
        let root = git(["rev-parse", "--show-toplevel"], in: cwd).flatMap { $0.status == 0 ? trimmed($0.out) : nil }
        var rel = ""
        if let root, cwd.hasPrefix(root) { rel = String(cwd.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let branch = root.flatMap { r in git(["rev-parse", "--abbrev-ref", "HEAD"], in: r).flatMap { $0.status == 0 ? trimmed($0.out) : nil } }
        let head = root.flatMap { r in git(["rev-parse", "HEAD"], in: r).flatMap { $0.status == 0 ? trimmed($0.out) : nil } }
        let changed = root.flatMap { r in git(["status", "--porcelain"], in: r).map { $0.out.split(separator: "\n").count } } ?? 0
        let size = ((try? FileManager.default.attributesOfItem(atPath: transcript))?[.size] as? NSNumber)?.intValue ?? 0
        return HandoffInfo(agent: agent, conversation: conversation, cwd: cwd, repoRoot: root,
                           repoName: root.map { ($0 as NSString).lastPathComponent }, relativeCwd: rel,
                           branch: branch, head: head, changedFiles: changed, transcriptPath: transcript, transcriptBytes: size)
    }


    public static func bundle(_ info: HandoffInfo, home: String = Handoff.home) -> Result<HandoffBundle, HandoffError> {
        guard let transcript = FileManager.default.contents(atPath: info.transcriptPath) else {
            return .failure(.missingTranscript(info.transcriptPath))
        }
        var codexRel: String?
        if info.agent == "codex" {
            let base = home + "/.codex/sessions/"
            codexRel = info.transcriptPath.hasPrefix(base) ? String(info.transcriptPath.dropFirst(base.count))
                                                           : (info.transcriptPath as NSString).lastPathComponent
        }
        var patch: Data?
        var files: [HandoffFile] = []
        if let root = info.repoRoot {
            guard let diff = gitData(["diff", "--binary", "HEAD"], in: root), diff.status == 0 else {
                return .failure(.io("git diff failed in \(root)"))
            }
            patch = diff.out.isEmpty ? nil : diff.out
            guard let list = gitData(["ls-files", "--others", "--exclude-standard", "-z"], in: root), list.status == 0 else {
                return .failure(.io("git ls-files failed in \(root)"))
            }
            var total = 0
            for rel in list.out.split(separator: 0).map({ String(decoding: $0, as: UTF8.self) }) where !rel.isEmpty {
                let full = root + "/" + rel
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                      let data = FileManager.default.contents(atPath: full) else { continue }
                total += data.count
                guard total <= untrackedLimit else {
                    return .failure(.tooLarge("untracked files over \(untrackedLimit / 1024 / 1024) MB in \(info.repoName ?? root)"))
                }
                let mode = ((try? FileManager.default.attributesOfItem(atPath: full))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
                files.append(HandoffFile(path: rel, data: data, executable: mode & 0o111 != 0))
            }
        }
        return .success(HandoffBundle(info: info, transcript: transcript, codexRelativePath: codexRel, patch: patch, untracked: files))
    }


    public static func projectDirName(_ cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    public static func expand(_ path: String, home: String = Handoff.home) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    public static func targetCwd(_ info: HandoffInfo, sourceRoot: String, targetRoot: String) -> Result<String, HandoffError> {
        if let name = info.repoName {
            let base = (targetRoot as NSString).appendingPathComponent(name)
            return .success(info.relativeCwd.isEmpty ? base : (base as NSString).appendingPathComponent(info.relativeCwd))
        }
        let src = sourceRoot.hasSuffix("/") ? String(sourceRoot.dropLast()) : sourceRoot
        if info.cwd == src { return .success(targetRoot) }
        if info.cwd.hasPrefix(src + "/") { return .success(targetRoot + info.cwd.dropFirst(src.count)) }
        return .failure(.outsideRoots(info.cwd))
    }

    public static func rewrite(_ data: Data, from: String, to: String) -> Data {
        guard from != to, !from.isEmpty, var text = String(data: data, encoding: .utf8) else { return data }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        while let r = text.range(of: from) {
            let next = text[r.upperBound...].first
            let whole = next == nil || next == "/" || next == "\"" || next == "\\" || next == "'" || next == " " || next == "\n"
            out += text[..<r.lowerBound]
            out += whole ? to : from
            text = String(text[r.upperBound...])
        }
        out += text
        return Data(out.utf8)
    }


    public static func importBundle(_ b: HandoffBundle, sourceRoot: String, targetRoot: String,
                                    home: String = Handoff.home, now: Date = Date()) -> Result<HandoffResult, HandoffError> {
        let info = b.info
        let sourceRoot = expand(sourceRoot, home: info.home ?? home)
        let targetRoot = expand(targetRoot, home: home)
        let target: String
        switch targetCwd(info, sourceRoot: sourceRoot, targetRoot: targetRoot) {
        case .success(let t): target = t
        case .failure(let e): return .failure(e)
        }
        var backups: [String] = []
        var notes: [String] = []
        let stamp = stampString(now)
        let backupDir = home + "/.local/state/terminess/handoff-backups/" + stamp
        func backup(_ name: String, _ data: Data) throws {
            try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            let p = backupDir + "/" + name
            try data.write(to: URL(fileURLWithPath: p))
            backups.append(p)
        }

        var targetRepo: String?
        if let name = info.repoName {
            let root = (targetRoot as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return .failure(.missingRepo(root)) }
            guard let top = git(["rev-parse", "--show-toplevel"], in: root), top.status == 0,
                  let topPath = trimmed(top.out), resolve(topPath) == resolve(root) else { return .failure(.notARepo(root)) }
            let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: root).flatMap { trimmed($0.out) } ?? "?"
            let head = git(["rev-parse", "HEAD"], in: root).flatMap { trimmed($0.out) } ?? "?"
            if let sh = info.head, sh != head || (info.branch != nil && info.branch != branch) {
                return .failure(.diverged(source: "\(info.branch ?? "?") at \(sh.prefix(8))", target: "\(branch) at \(head.prefix(8))"))
            }
            targetRepo = root
        } else {
            try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        }

        if let root = targetRepo, b.patch != nil || !b.untracked.isEmpty {
            let ownDiff = gitData(["diff", "--binary", "HEAD"], in: root)?.out ?? Data()
            let ownUntracked = gitData(["ls-files", "--others", "--exclude-standard", "-z"], in: root)?.out ?? Data()
            let sameChanges = ownDiff == (b.patch ?? Data()) && untrackedMatch(b.untracked, in: root, list: ownUntracked)
            if sameChanges {
                notes.append("The uncommitted changes were already here.")
            } else {
                if !ownDiff.isEmpty || !ownUntracked.isEmpty {
                    do { try backup("\(info.repoName ?? "repo")-before.patch", ownDiff) } catch { return .failure(.io("Couldn't write a backup: \(error)")) }
                    let msg = "terminess handoff \(stamp): changes that were here before \(info.agent) \(info.conversation.prefix(8)) arrived"
                    guard let st = git(["stash", "push", "--include-untracked", "-m", msg], in: root), st.status == 0 else {
                        return .failure(.io("Couldn't stash the changes already in \(root), so nothing was changed."))
                    }
                    notes.append("This copy had its own uncommitted changes; they're saved in git stash (\"\(msg)\") and as a patch.")
                }
                if let patch = b.patch {
                    let tmp = NSTemporaryDirectory() + "terminess-handoff-\(UUID().uuidString).patch"
                    FileManager.default.createFile(atPath: tmp, contents: patch)
                    defer { try? FileManager.default.removeItem(atPath: tmp) }
                    let check = git(["apply", "--binary", "--check", tmp], in: root)
                    guard let check, check.status == 0 else {
                        restoreStash(root, made: !ownDiff.isEmpty || !ownUntracked.isEmpty)
                        return .failure(.applyFailed(check.map { trimmed($0.err) ?? "" } ?? "git apply didn't run"))
                    }
                    guard let applied = git(["apply", "--binary", tmp], in: root), applied.status == 0 else {
                        restoreStash(root, made: !ownDiff.isEmpty || !ownUntracked.isEmpty)
                        return .failure(.applyFailed("git apply failed"))
                    }
                }
                for f in b.untracked {
                    guard isSafeRelative(f.path) else { continue }
                    let full = root + "/" + f.path
                    try? FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: full, contents: f.data,
                                                   attributes: [.posixPermissions: f.executable ? 0o755 : 0o644])
                }
                let n = (b.patch == nil ? 0 : 1) + b.untracked.count
                if n > 0 { notes.append("Carried the uncommitted changes across (tracked changes\(b.untracked.isEmpty ? "" : " and \(b.untracked.count) untracked file\(b.untracked.count == 1 ? "" : "s")")).") }
            }
        }

        let toPath = targetRepo ?? target
        var froms: [String] = []
        if let root = info.repoRoot { froms.append(root) }
        let logical = info.relativeCwd.isEmpty ? info.cwd
            : (info.cwd.hasSuffix("/" + info.relativeCwd) ? String(info.cwd.dropLast(info.relativeCwd.count + 1)) : info.cwd)
        if !froms.contains(logical) { froms.append(logical) }
        var transcript = b.transcript
        for from in froms.sorted(by: { $0.count > $1.count }) { transcript = rewrite(transcript, from: from, to: toPath) }
        let dest: String
        if info.agent == "codex" {
            let rel = (b.codexRelativePath.flatMap { isSafeRelative($0) ? $0 : nil }) ?? "rollout-\(info.conversation).jsonl"
            dest = home + "/.codex/sessions/" + rel
        } else {
            dest = home + "/.claude/projects/" + projectDirName(target) + "/" + info.conversation + ".jsonl"
        }
        do {
            if let old = FileManager.default.contents(atPath: dest), old != transcript {
                try backup((dest as NSString).lastPathComponent, old)
            }
            try FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try transcript.write(to: URL(fileURLWithPath: dest))
        } catch {
            return .failure(.io("Couldn't write the transcript to \(dest): \(error)"))
        }
        return .success(HandoffResult(cwd: target, resumeCommand: info.resumeCommand, backups: backups, notes: notes))
    }


    public static func stop(pid: Int32, timeout: TimeInterval = 15) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 { return true }
        _ = kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            usleep(100_000)
        }
        return kill(pid, 0) != 0
    }


    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    static func isSafeRelative(_ p: String) -> Bool {
        !p.isEmpty && !p.hasPrefix("/") && !p.split(separator: "/").contains("..")
    }

    public static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "-_./".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func stampString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    static func resolve(_ p: String) -> String { (p as NSString).resolvingSymlinksInPath }

    static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func untrackedMatch(_ files: [HandoffFile], in root: String, list: Data) -> Bool {
        let names = Set(list.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty })
        guard names == Set(files.map(\.path)) else { return false }
        return files.allSatisfy { FileManager.default.contents(atPath: root + "/" + $0.path) == $0.data }
    }

    private static func restoreStash(_ root: String, made: Bool) {
        if made { _ = git(["stash", "pop", "--index"], in: root) }
    }

    static func openCodexRollout(pid: Int32) -> String? {
        let fdDir = "/proc/\(pid)/fd"
        if let fds = try? FileManager.default.contentsOfDirectory(atPath: fdDir) {
            for fd in fds {
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: fdDir + "/" + fd),
                   isRollout(target) { return target }
            }
            return nil
        }
        guard let out = run("/usr/sbin/lsof", ["-p", String(pid), "-Fn"]), out.status == 0 else { return nil }
        for line in out.out.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if isRollout(path) { return path }
        }
        return nil
    }

    static func isRollout(_ p: String) -> Bool {
        let name = (p as NSString).lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    static func codexCwd(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 64 * 1024), as: UTF8.self)
        for line in head.split(separator: "\n").prefix(20) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let cwd = obj["cwd"] as? String { return cwd }
            if let p = obj["payload"] as? [String: Any], let cwd = p["cwd"] as? String { return cwd }
        }
        return nil
    }

    struct Ran { var status: Int32; var out: String; var err: String }
    struct RanData { var status: Int32; var out: Data }

    static func git(_ args: [String], in dir: String) -> Ran? {
        run(gitPath, ["-C", dir] + args)
    }

    static func gitData(_ args: [String], in dir: String) -> RanData? {
        runData(gitPath, ["-C", dir] + args)
    }

    static var gitPath: String {
        for p in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/git"
    }

    static func run(_ exe: String, _ args: [String]) -> Ran? {
        guard let r = runData(exe, args, captureErr: true) else { return nil }
        return Ran(status: r.status, out: String(decoding: r.out, as: UTF8.self), err: lastErr)
    }

    nonisolated(unsafe) private static var lastErr = ""

    static func runData(_ exe: String, _ args: [String], captureErr: Bool = false) -> RanData? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        p.waitUntilExit()
        group.wait()
        if captureErr { lastErr = String(decoding: errData, as: UTF8.self) }
        return RanData(status: p.terminationStatus, out: outData)
    }
}
