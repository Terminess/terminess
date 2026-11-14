import AppKit
import TermHost
import TermPTY

@MainActor
protocol SessionBackend: AnyObject {
    var foregroundCommand: String? { get }
    var foregroundDirectory: String? { get }
    var foregroundArguments: [String] { get }
    var foregroundStartTime: Double? { get }
    var foregroundPID: Int32 { get }
    var hostSessionID: String? { get }
    func write(_ bytes: [UInt8])
    func respond(_ bytes: [UInt8])
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)
    func hangUp()
    func detach()
    @discardableResult func terminateForeground() -> Bool
}

extension PTYProcess: SessionBackend {
    var hostSessionID: String? { nil }
    func respond(_ bytes: [UInt8]) { write(bytes) }
    func detach() {}
}

@MainActor
final class HostBackend: SessionBackend {
    let attachment: HostAttachment
    private var info: ForegroundInfo?

    init(attachment: HostAttachment) {
        self.attachment = attachment
    }

    func update(_ fg: ForegroundInfo) { info = fg }

    var foregroundCommand: String? { info?.command }
    var foregroundDirectory: String? { info.map(\.cwd).flatMap { $0.isEmpty ? nil : $0 } }
    var foregroundArguments: [String] { info?.args ?? [] }
    var foregroundStartTime: Double? { info.flatMap { $0.started > 0 ? $0.started : nil } }
    var foregroundPID: Int32 { info?.pid ?? 0 }
    var hostSessionID: String? { attachment.sessionID }

    func write(_ bytes: [UInt8]) { attachment.write(bytes) }
    func respond(_ bytes: [UInt8]) { attachment.respond(bytes) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) { attachment.resize(cols: columns, rows: rows) }
    func hangUp() { attachment.kill() }
    func detach() { attachment.detach() }

    @discardableResult
    func terminateForeground() -> Bool {
        guard let info, info.pid > 0, info.pid != info.shellPid else { return false }
        attachment.signal("TERM")
        return true
    }
}

@MainActor
enum HostService {
    static var executable: String? {
        let candidates = [Bundle.main.url(forAuxiliaryExecutable: "terminessd")?.path,
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("terminessd").path]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var gaveUp = false

    static func ensureRunning() -> Bool {
        guard !gaveUp, UnixSocket.fits(HostPaths.socket) else { return false }
        if let fd = UnixSocket.connect(HostPaths.socket) { close(fd); return true }
        guard let exe = executable else { gaveUp = true; return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["serve"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        for k in PTYProcess.agentSessionVariables { env[k] = nil }
        p.environment = env
        do { try p.run() } catch { gaveUp = true; return false }
        for _ in 0..<40 {
            usleep(25_000)
            if let fd = UnixSocket.connect(HostPaths.socket) { close(fd); return true }
        }
        gaveUp = true
        return false
    }
}
