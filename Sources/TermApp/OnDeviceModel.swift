import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum OnDeviceModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static func generate(_ prompt: String, instructions: String, maxTokens: Int = 200) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens)
            if let response = try? await session.respond(to: prompt, options: options) {
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }
        #endif
        return nil
    }
}

enum TabNamer {
    static func name(for messages: [String]) async -> String? {
        let asked = messages.prefix(3).enumerated().map { i, text in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Message \(i + 1):\n" + (t.count > 700 ? String(t.prefix(700)) + " [cut]" : t)
        }.joined(separator: "\n\n")
        let instructions = """
        You name conversations between a person and a coding assistant, so the person can find them again in a list. \
        Reply with only the name: 2 to 6 words saying what the conversation is about, like a document title \
        (for example "Hugging Face pricing vs OpenRouter" or "Sidebar width keeps shrinking"). \
        Name the subject, not the request: no "Help with", no "Question about". \
        Keep product and project names as written. Ignore file paths and pasted logs. \
        No quotes, no full stop at the end. British English. Do not use em dashes or en dashes.
        """
        guard let text = await OnDeviceModel.generate(asked, instructions: instructions, maxTokens: 24) else { return nil }
        return clean(text)
    }

    static func clean(_ text: String) -> String? {
        var t = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for label in ["Title:", "Name:"] where t.lowercased().hasPrefix(label.lowercased()) {
            t = String(t.dropFirst(label.count))
        }
        t = t.replacingOccurrences(of: "\u{2014}", with: ",").replacingOccurrences(of: "\u{2013}", with: " to ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#\u{201C}\u{201D}\u{2018}\u{2019}").union(.whitespaces))
        while t.hasSuffix(".") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return t.count > 48 ? String(t.prefix(47)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : t
    }
}
