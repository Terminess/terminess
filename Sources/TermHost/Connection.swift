#if canImport(Glibc)
import Glibc
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

    public init(readFD: Int32, writeFD: Int32? = nil, queue: DispatchQueue) {
        self.readFD = readFD
        self.writeFD = writeFD ?? readFD
        self.queue = queue
    }

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
        if !Connection.writeAll(writeFD, frame.encoded()) { close() }
    }

    public func send(_ message: Message) { send(.control(message)) }

    public func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
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

    public static func listen(_ path: String) throws -> Int32 {
        guard var addr = address(path) else { throw HostError("socket path too long: \(path)") }
        unlink(path)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValueCompat), 0)
        guard fd >= 0 else { throw HostError("socket: \(String(cString: strerror(errno)))") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw HostError("bind \(path): \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard sysListen(fd, 16) == 0 else { throw HostError("listen: \(String(cString: strerror(errno)))") }
        return fd
    }
}

@inline(__always) private func sysConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Glibc)
    return Glibc.connect(fd, addr, len)
    #else
    return Darwin.connect(fd, addr, len)
    #endif
}

@inline(__always) private func sysListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Glibc)
    return Glibc.listen(fd, backlog)
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
