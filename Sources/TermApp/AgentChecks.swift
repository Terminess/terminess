import Foundation

@MainActor
enum AgentChecks {
    static var problems: [String: [String]] = [:]

    static func checkThisMac() {
        guard let exe = HostService.executable else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["tools", "check"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            DispatchQueue.main.async { MainActor.assumeIsolated { report(text, on: "This Mac") } }
        }
    }

    static func report(_ output: String, on place: String) {
        let found = output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("problem:") }
            .map { String($0.dropFirst("problem:".count)).trimmingCharacters(in: .whitespaces) }
        let before = problems[place] ?? []
        problems[place] = found
        guard !found.isEmpty, found != before else { return }
        let key = "agentChecksTold." + place
        let told = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard found != told else { return }
        UserDefaults.standard.set(found, forKey: key)
        AttentionCenter.shared.notice(title: "Something changed in an agent on \(place)",
                                      body: found.joined(separator: " "))
    }
}
