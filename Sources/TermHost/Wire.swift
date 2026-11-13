import Foundation

public enum Wire {
    public static let version = 2
    public static let maxFrame = 8 * 1024 * 1024

    public enum Kind: UInt8 {
        case control = 1
        case output = 2
        case input = 3
    }

    public struct Frame {
        public let kind: Kind
        public let payload: [UInt8]
        public init(_ kind: Kind, _ payload: [UInt8]) { self.kind = kind; self.payload = payload }

        public static func control(_ message: Message) -> Frame {
            Frame(.control, Array((try? JSONEncoder().encode(message)) ?? Data()))
        }

        public var message: Message? {
            guard kind == .control else { return nil }
            return try? JSONDecoder().decode(Message.self, from: Data(payload))
        }

        public func encoded() -> [UInt8] {
            let n = UInt32(payload.count + 1)
            return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF), kind.rawValue] + payload
        }
    }

    public struct Decoder {
        private var buffer: [UInt8] = []
        public init() {}

        public mutating func feed(_ bytes: [UInt8]) throws -> [Frame] {
            buffer.append(contentsOf: bytes)
            var frames: [Frame] = []
            var start = 0
            while buffer.count - start >= 5 {
                let n = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                guard n >= 1, n <= Wire.maxFrame else { throw WireError.badLength(n) }
                guard buffer.count - start >= 4 + n else { break }
                guard let kind = Kind(rawValue: buffer[start + 4]) else { throw WireError.badKind(buffer[start + 4]) }
                frames.append(Frame(kind, Array(buffer[(start + 5)..<(start + 4 + n)])))
                start += 4 + n
            }
            if start > 0 { buffer.removeFirst(start) }
            return frames
        }
    }

    public enum WireError: Error, CustomStringConvertible {
        case badLength(Int)
        case badKind(UInt8)
        public var description: String {
            switch self {
            case .badLength(let n): return "bad frame length \(n)"
            case .badKind(let k): return "unknown frame type \(k)"
            }
        }
    }
}

public struct SessionInfo: Codable, Equatable {
    public var id: String
    public var name: String
    public var command: String
    public var cwd: String
    public var created: Double
    public var clients: Int
}

public struct ForegroundInfo: Codable, Equatable {
    public var command: String
    public var cwd: String
    public var args: [String]
    public var started: Double
    public var pid: Int32
    public var shellPid: Int32
    public init(command: String, cwd: String, args: [String], started: Double, pid: Int32, shellPid: Int32) {
        self.command = command; self.cwd = cwd; self.args = args; self.started = started; self.pid = pid; self.shellPid = shellPid
    }
}

public struct Message: Codable, Equatable {
    public var op: String
    public var version: Int?
    public var host: String?
    public var id: String?
    public var name: String?
    public var cwd: String?
    public var command: String?
    public var args: [String]?
    public var cols: Int?
    public var rows: Int?
    public var code: Int?
    public var message: String?
    public var sessions: [SessionInfo]?
    public var env: [String: String]?
    public var foreground: ForegroundInfo?
    public var signal: String?

    public init(op: String, version: Int? = nil, host: String? = nil, id: String? = nil, name: String? = nil,
                cwd: String? = nil, command: String? = nil, args: [String]? = nil, cols: Int? = nil, rows: Int? = nil,
                code: Int? = nil, message: String? = nil, sessions: [SessionInfo]? = nil,
                env: [String: String]? = nil, foreground: ForegroundInfo? = nil, signal: String? = nil) {
        self.op = op; self.version = version; self.host = host; self.id = id; self.name = name
        self.cwd = cwd; self.command = command; self.args = args; self.cols = cols; self.rows = rows
        self.code = code; self.message = message; self.sessions = sessions
        self.env = env; self.foreground = foreground; self.signal = signal
    }
}

public enum HostPaths {
    public static var stateDirectory: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = home + "/.local/state/terminess"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    public static var socket: String {
        ProcessInfo.processInfo.environment["TERMINESSD_SOCKET"] ?? stateDirectory + "/terminessd.sock"
    }
}
