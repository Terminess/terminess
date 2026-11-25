#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#else
import Darwin
#endif
import Dispatch
import Foundation

public final class Connection: @unchecked Sendable {
    public let readFD: Int32
    public let writeFD: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var decoder = Wire.Decoder()
    private var closed = false
    public var onFrame: ((Wire.Frame) -> Void)?
    public var onClose: (() -> Void)?
    private let buffered: Bool
    public static let maxBacklog = 8 * 1024 * 1024
    public static let hardBacklog = 128 * 1024 * 1024
    public var stallTimeout: TimeInterval = 20
    private var lastProgress = Date()
    private var backlog: [UInt8] = []
    private var backlogStart = 0
    private var writer: DispatchSourceWrite?

    public init(readFD: Int32, writeFD: Int32? = nil, queue: DispatchQueue, buffered: Bool = false) {
        self.readFD = readFD
        self.writeFD = writeFD ?? readFD
        self.queue = queue
        self.buffered = buffered
        #if canImport(Darwin)
        var on: Int32 = 1
        for fd in Set([readFD, self.writeFD]) {
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        #endif
        if buffered {
            let flags = fcntl(self.writeFD, F_GETFL)
            if flags >= 0 { _ = fcntl(self.writeFD, F_SETFL, flags | O_NONBLOCK) }
        }
    }

    public var backlogCount: Int { backlog.count - backlogStart }

    public func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let n = buf.withUnsafeMutableBytes { read(self.readFD, $0.baseAddress, $0.count) }
            if n > 0 {
                do {
                    for frame in try self.decoder.feed(Array(buf[0..<n])) { self.onFrame?(frame) }
                } catch {
                    self.close()
                }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                self.close()
            }
        }
        source = src
        src.resume()
    }

    public func send(_ frame: Wire.Frame) {
        guard !closed else { return }
        guard buffered else {
            if !Connection.writeAll(writeFD, frame.encoded()) { close() }
            return
        }
        let bytes = frame.encoded()
        if backlogCount == 0 {
            lastProgress = Date()
            let n = bytes.withUnsafeBytes { write(writeFD, $0.baseAddress!, bytes.count) }
            if n == bytes.count { return }
            if n < 0 && errno != EAGAIN && errno != EINTR { close(); return }
            backlog = Array(bytes[max(n, 0)...])
            backlogStart = 0
        } else {
            backlog.append(contentsOf: bytes)
        }
        if backlogCount > Connection.hardBacklog
            || (backlogCount > Connection.maxBacklog && Date().timeIntervalSince(lastProgress) > stallTimeout) {
            close()
            return
        }
        if writer == nil {
            let w = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: queue)
            w.setEventHandler { [weak self] in self?.drain() }
            writer = w
            w.resume()
        }
    }

    private func drain() {
        guard !closed else { return }
        while backlogCount > 0 {
            let n = backlog.withUnsafeBytes { write(writeFD, $0.baseAddress! + backlogStart, backlogCount) }
            if n > 0 { backlogStart += n; lastProgress = Date(); continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { break }
            close()
            return
        }
        if backlogCount == 0 {
            backlog = []
            backlogStart = 0
            writer?.cancel()
            writer = nil
        } else if backlogStart > 1 << 20 {
            backlog.removeFirst(backlogStart)
            backlogStart = 0
        }
    }

    public func send(_ message: Message) { send(.control(message)) }

    public func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        writer?.cancel()
        writer = nil
        backlog = []
        backlogStart = 0
        Darwin_close(readFD)
        if writeFD != readFD { Darwin_close(writeFD) }
        onClose?()
    }

    @discardableResult
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 { offset += n; continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 1000)
                continue
            }
            return false
        }
        return true
    }
}

@inline(__always) func Darwin_close(_ fd: Int32) {
    #if canImport(Glibc)
    _ = Glibc.close(fd)
    #elseif canImport(Musl)
    _ = Musl.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
}

public enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    public static func fits(_ path: String) -> Bool { address(path) != nil }

    public static func connect(_ path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValueCompat), 0)
        guard fd >= 0 else { return nil }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sysConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { Darwin_close(fd); return nil }
        return fd
    }

    public static func checkPrivate(directory dir: String) throws {
        guard let a = ownFile(dir) else { throw HostError("\(dir) is missing or belongs to another user") }
        guard a.type == .typeDirectory else { throw HostError("\(dir) isn't a plain folder") }
        if a.mode & 0o077 != 0 {
            guard chmod(dir, 0o700) == 0 else { throw HostError("couldn't make \(dir) private") }
        }
    }

    public static func ownFile(_ path: String) -> (type: FileAttributeType, mode: Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let type = a[.type] as? FileAttributeType else { return nil }
        return (type, (a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777)
    }

    public static func listen(_ path: String) throws -> Int32 {
        guard var addr = address(path) else { throw HostError("socket path too long: \(path)") }
        try checkPrivate(directory: (path as NSString).deletingLastPathComponent)
        if (try? FileManager.default.attributesOfItem(atPath: path)) != nil {
            guard ownFile(path)?.type == .typeSocket else { throw HostError("\(path) exists and isn't our socket") }
        }
        unlink(path)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValueCompat), 0)
        guard fd >= 0 else { throw HostError("socket: \(String(cString: strerror(errno)))") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw HostError("bind \(path): \(String(cString: strerror(errno)))") }
        guard chmod(path, 0o600) == 0 else { Darwin_close(fd); throw HostError("couldn't make \(path) private") }
        guard sysListen(fd, 16) == 0 else { throw HostError("listen: \(String(cString: strerror(errno)))") }
        return fd
    }
}

@inline(__always) private func sysConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Glibc)
    return Glibc.connect(fd, addr, len)
    #elseif canImport(Musl)
    return Musl.connect(fd, addr, len)
    #else
    return Darwin.connect(fd, addr, len)
    #endif
}

@inline(__always) private func sysListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Glibc)
    return Glibc.listen(fd, backlog)
    #elseif canImport(Musl)
    return Musl.listen(fd, backlog)
    #else
    return Darwin.listen(fd, backlog)
    #endif
}

#if canImport(Glibc)
extension __socket_type { var rawValueCompat: UInt32 { rawValue } }
#else
extension Int32 { var rawValueCompat: Int32 { self } }
#endif

public struct HostError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public enum HostRequest {
    public static func send(_ m: Message, socket: String = HostPaths.socket, timeout: Int32 = 5000) -> Message? {
        guard let fd = UnixSocket.connect(socket) else { return nil }
        defer { Darwin_close(fd) }
        guard Connection.writeAll(fd, Wire.Frame.control(m).encoded()) else { return nil }
        var decoder = Wire.Decoder()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, timeout) > 0 else { return nil }
            let n = read(fd, &buf, buf.count)
            guard n > 0, let frames = try? decoder.feed(Array(buf[0..<n])) else { return nil }
            if let reply = frames.compactMap(\.message).first { return reply }
        }
    }
}
