import CryptoKit
import Foundation
import NIOSSH
import Security

enum DeviceKey {
    private static let service = "com.terminess.devicekey"

    static func load() throws -> NIOSSHPrivateKey {
        if let stored = try read() {
            if stored.secureEnclave {
                return NIOSSHPrivateKey(secureEnclaveP256Key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.data))
            }
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: stored.data))
        }
        if SecureEnclave.isAvailable {
            let k = try SecureEnclave.P256.Signing.PrivateKey()
            try write(k.dataRepresentation, secureEnclave: true)
            return NIOSSHPrivateKey(secureEnclaveP256Key: k)
        }
        let k = P256.Signing.PrivateKey()
        try write(k.rawRepresentation, secureEnclave: false)
        return NIOSSHPrivateKey(p256Key: k)
    }

    static func authorizedKeyLine() -> String {
        guard let key = try? load() else { return "" }
        return String(openSSHPublicKey: key.publicKey) + " terminess-iphone"
    }

    static var usesSecureEnclave: Bool { ((try? read()) ?? nil)?.secureEnclave ?? SecureEnclave.isAvailable }

    private static func read() throws -> (data: Data, secureEnclave: Bool)? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = out as? [String: Any],
              let data = item[kSecValueData as String] as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return (data, (item[kSecAttrAccount as String] as? String) == "secure-enclave")
    }

    private static func write(_ data: Data, secureEnclave: Bool) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: secureEnclave ? "secure-enclave" : "software",
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                kSecValueData as String: data]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
