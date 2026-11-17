import Foundation

public enum DevicePresence {
    public static func others(_ s: SessionInfo, ownKind: String, ownName: String?, attachedHere: Bool) -> [ClientDevice] {
        let devices: [ClientDevice]
        if let d = s.clientDevices {
            devices = d
        } else if let kinds = s.clientKinds {
            devices = kinds.map { ClientDevice(kind: $0) }
        } else {
            devices = s.clients > 0 ? [ClientDevice(kind: "other")] : []
        }
        guard attachedHere else { return devices }
        var rest = devices
        if let i = rest.firstIndex(where: { $0.kind == ownKind && $0.name != nil && $0.name == ownName })
            ?? rest.firstIndex(where: { $0.kind == ownKind }) {
            rest.remove(at: i)
        }
        return rest
    }

    public static func displayName(_ d: ClientDevice) -> String {
        if let n = d.name, !n.isEmpty { return n }
        switch d.kind {
        case "iphone": return "an iPhone"
        case "mac": return "a Mac"
        default: return "another device"
        }
    }

    public static func connectedLabel(_ devices: [ClientDevice]) -> String? {
        guard !devices.isEmpty else { return nil }
        let names = devices.map(displayName)
        switch names.count {
        case 1: return "\(names[0]) connected"
        case 2: return "\(names[0]), \(names[1]) connected"
        default: return "\(names[0]) and \(names.count - 1) others connected"
        }
    }

    public static func allNames(_ devices: [ClientDevice]) -> String {
        devices.map(displayName).joined(separator: "\n")
    }

    public static func symbol(_ devices: [ClientDevice]) -> String {
        let kinds = Set(devices.map(\.kind))
        if kinds == ["iphone"] { return "iphone" }
        if kinds == ["mac"] { return "laptopcomputer" }
        if kinds.contains("iphone"), kinds.contains("mac") { return "laptopcomputer.and.iphone" }
        return kinds.contains("iphone") ? "iphone" : (kinds.contains("mac") ? "laptopcomputer" : "display")
    }

    public static func originLabel(_ s: SessionInfo) -> String? {
        guard let origin = s.origin, origin == "iphone" || origin == "mac" else { return nil }
        if let n = s.originName, !n.isEmpty { return "from \(n)" }
        return origin == "iphone" ? "from iPhone" : "from a Mac"
    }


    public static func iPhoneModelName(_ identifier: String) -> String {
        models[identifier] ?? (identifier.hasPrefix("iPhone") ? "iPhone" : identifier.hasPrefix("iPad") ? "iPad" : "iPhone")
    }

    static let models: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
    ]

    public static func isGenericDeviceName(_ name: String) -> Bool {
        ["iphone", "ipad", "ipod touch", ""].contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }
}


public enum MachineRole {
    public static let presets = ["Production", "Staging", "Development", "Agents"]

    public static func clean(_ role: String?) -> String? {
        guard let r = role?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        return String(r.prefix(24))
    }
}
