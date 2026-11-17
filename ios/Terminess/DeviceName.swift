import UIKit
import TermHost

enum DeviceName {
    static let key = "deviceName"

    static var custom: String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor static var current: String {
        if !custom.isEmpty { return custom }
        let given = UIDevice.current.name
        if !DevicePresence.isGenericDeviceName(given) { return given }
        return model
    }

    static var model: String { DevicePresence.iPhoneModelName(modelIdentifier) }

    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
