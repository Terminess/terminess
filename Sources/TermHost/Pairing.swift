#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

public enum Pairing {
    public static let lifetime: TimeInterval = 10 * 60
    public static let maxRequest = 16 * 1024

    #if canImport(CryptoKit)
    public static func proof(code: String, key: String) -> String {
        mac(code: code, label: "terminess-pair-v1 phone", message: key)
    }

    public static func reply(code: String, key: String) -> String {
        mac(code: code, label: "terminess-pair-v1 mac", message: key)
    }

    public static func verify(code: String, key: String, proof: String) -> Bool {
        guard !code.isEmpty, let given = Data(hex: proof) else { return false }
        guard let expected = Data(hex: Pairing.proof(code: code, key: key)) else { return false }
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func mac(code: String, label: String, message: String) -> String {
        let m = HMAC<SHA256>.authenticationCode(for: Data((label + "\n" + message).utf8), using: SymmetricKey(data: Data(code.utf8)))
        return Data(m).map { String(format: "%02x", $0) }.joined()
    }

    #endif

    public static func contentLength(head: String) -> Int? {
        let lines = head.split(separator: "\r\n").filter { $0.lowercased().hasPrefix("content-length:") }
        guard lines.count == 1, let colon = lines[0].firstIndex(of: ":") else { return nil }
        let value = lines[0][lines[0].index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber),
              let n = Int(value), n >= 0, n <= maxRequest else { return nil }
        return n
    }
}

public enum RemotePath {
    public static func isSafe(_ path: String) -> Bool {
        guard path.count <= 512, path.hasPrefix("/") || path.hasPrefix("~/") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+ ~")
        return path.unicodeScalars.allSatisfy(allowed.contains) && !path.dropFirst().contains("~")
            && !path.split(separator: "/").contains("..")
    }

    public static func shellQuoted(_ path: String) -> String {
        func quote(_ s: Substring) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if path.hasPrefix("~/") { return "~/" + quote(path.dropFirst(2)) }
        return quote(Substring(path))
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, hex.count <= 256 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
