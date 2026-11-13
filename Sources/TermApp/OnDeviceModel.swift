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
