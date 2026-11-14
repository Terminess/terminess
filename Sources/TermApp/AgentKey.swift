import Foundation
import SwiftUI
import TermTranscript

enum AgentKey {
    static var path: String { Transcript.home + "/.config/terminess/anthropic_key" }

    static func read() -> String? {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        let k = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return k.isEmpty ? nil : k
    }

    static func save(_ key: String) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        if k.isEmpty { try? fm.removeItem(atPath: path); return }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(atPath: path)
        guard fm.createFile(atPath: path, contents: Data((k + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

struct AgentKeyField: View {
    @State private var draft = ""
    @State private var saved = AgentKey.read() != nil

    var body: some View {
        HStack {
            SecureField("Anthropic API key", text: $draft, prompt: Text(saved ? "Saved. Paste a new key to replace it" : "sk-ant-…"))
            Button("Save") {
                do { try AgentKey.save(draft); draft = ""; saved = AgentKey.read() != nil } catch { AgentEvents.report(error) }
            }
            .disabled(draft.isEmpty)
            if saved {
                Button("Remove") { try? AgentKey.save(""); saved = false }
            }
        }
        .help("For Shell, New Agent Tab: Terminess runs the agent itself, billed to your Anthropic account. Saved in ~/.config/terminess/anthropic_key, readable only by you.")
    }
}
