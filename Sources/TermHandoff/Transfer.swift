import Foundation
import TermHost
#if canImport(Glibc)
import Glibc
private let sockStream = Int32(SOCK_STREAM.rawValue)
private func Darwin_or_Glibc_close(_ fd: Int32) { _ = Glibc.close(fd) }
#else
import Darwin
private let sockStream = SOCK_STREAM
private func Darwin_or_Glibc_close(_ fd: Int32) { _ = Darwin.close(fd) }
#endif

public final class HandoffPeer: @unchecked Sendable {
    private let fd: Int32
    private var decoder = Wire.Decoder()
    private var pending: [Message] = []
    private let ssh: Process?

    public init(fd: Int32, ssh: Process? = nil) { self.fd = fd; self.ssh = ssh }

    deinit { close() }

    public func close() {
        if fd >= 0 { Darwin_or_Glibc_close(fd) }
        if let ssh, ssh.isRunning { ssh.terminate() }
    }

    public func request(_ m: Message) -> Message? {
        guard Connection.writeAll(fd, Wire.Frame.control(m).encoded()) else { return nil }
        return next()
    }

    private func next() -> Message? {
        if !pending.isEmpty { return pending.removeFirst() }
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            guard let frames = try? decoder.feed(Array(buf[0..<n])) else { return nil }
            pending += frames.compactMap(\.message)
            if !pending.isEmpty { return pending.removeFirst() }
        }
    }

    public static func ssh(host: String, port: Int = 22, path: String) -> HandoffPeer? {
        guard !host.hasPrefix("-"), !host.contains(where: \.isWhitespace), RemotePath.isSafe(path) else { return nil }
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, sockStream, 0, &pair) == 0 else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15"]
        if port != 22 { args += ["-p", String(port)] }
        args += ["--", host, RemotePath.shellQuoted(path) + " stdio"]
        p.arguments = args
        let theirs = FileHandle(fileDescriptor: pair[1], closeOnDealloc: false)
        p.standardInput = theirs
        p.standardOutput = theirs
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDE") || k == "TERMINESS_SESSION" { env[k] = nil }
        p.environment = env
        do { try p.run() } catch { Darwin_or_Glibc_close(pair[0]); Darwin_or_Glibc_close(pair[1]); return nil }
        Darwin_or_Glibc_close(pair[1])
        let peer = HandoffPeer(fd: pair[0], ssh: p)
        guard let hello = peer.request(Message(op: "hello", version: Wire.version)), hello.op == "hello" else { return nil }
        return peer
    }
}


public enum HandoffTransfer {
    public static let chunk = 3 * 1024 * 1024

    public static func encode(_ b: HandoffBundle) -> Data? { try? JSONEncoder().encode(b) }
    public static func decode(_ d: Data) -> HandoffBundle? { try? JSONDecoder().decode(HandoffBundle.self, from: d) }

    private static func failure(_ reply: Message?) -> HandoffError {
        .io(reply?.op == "error" ? (reply?.message ?? "error") : (reply == nil ? "The connection closed." : "Unexpected reply \(reply!.op)."))
    }

    public static func info(_ peer: HandoffPeer, session: String) -> Result<HandoffInfo, HandoffError> {
        let r = peer.request(Message(op: "handoff-info", id: session))
        guard r?.op == "handoff-info", let json = r?.message,
              let info = try? JSONDecoder().decode(HandoffInfo.self, from: Data(json.utf8)) else {
            if r?.message?.contains("unknown op") == true { return .failure(.io("That machine's terminessd is too old to move conversations; update it first.")) }
            return .failure(failure(r))
        }
        return .success(info)
    }

    public static func export(_ peer: HandoffPeer, session: String) -> Result<HandoffBundle, HandoffError> {
        let r = peer.request(Message(op: "handoff-export", id: session))
        guard r?.op == "handoff-ready", let token = r?.name, let total = r?.code else { return .failure(failure(r)) }
        var data = Data()
        data.reserveCapacity(total)
        while data.count < total {
            let c = peer.request(Message(op: "handoff-get", name: token, code: data.count))
            guard c?.op == "handoff-data", let b64 = c?.data, let part = Data(base64Encoded: b64), !part.isEmpty else {
                return .failure(failure(c))
            }
            data.append(part)
        }
        _ = peer.request(Message(op: "handoff-drop", name: token))
        guard let bundle = decode(data) else { return .failure(.io("The bundle didn't decode.")) }
        return .success(bundle)
    }

    public static func importRemote(_ peer: HandoffPeer, bundle: HandoffBundle, sourceRoot: String, targetRoot: String) -> Result<HandoffResult, HandoffError> {
        guard let data = encode(bundle) else { return .failure(.io("Couldn't encode the bundle.")) }
        let token = String(UUID().uuidString.prefix(12)).lowercased()
        var offset = 0
        repeat {
            let end = min(offset + chunk, data.count)
            var m = Message(op: "handoff-put", name: token, code: offset)
            m.data = data[offset..<end].base64EncodedString()
            let r = peer.request(m)
            guard r?.op == "ok" else { return .failure(failure(r)) }
            offset = end
        } while offset < data.count
        let roots = (try? JSONSerialization.data(withJSONObject: ["sourceRoot": sourceRoot, "targetRoot": targetRoot])).map { String(decoding: $0, as: UTF8.self) }
        let r = peer.request(Message(op: "handoff-import", name: token, message: roots))
        guard r?.op == "handoff-imported", let json = r?.message,
              let result = try? JSONDecoder().decode(HandoffResult.self, from: Data(json.utf8)) else { return .failure(failure(r)) }
        return .success(result)
    }
}
