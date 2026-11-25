import AppKit
import Foundation
import SwiftUI
import TermHost

struct HFTokenField: View {
    @State private var draft = ""
    @State private var saved = HuggingFace.token() != nil
    private var fromEnvironment: Bool { !(ProcessInfo.processInfo.environment["HF_TOKEN"] ?? "").isEmpty }

    var body: some View {
        HStack {
            SecureField("Hugging Face token", text: $draft,
                        prompt: Text(fromEnvironment ? "Set by HF_TOKEN" : saved ? "Saved. Paste a new token to replace it" : "hf_…"))
                .labelsHidden()
                .frame(width: 200)
            Button("Save") {
                do {
                    try HuggingFace.savePrivate(draft.trimmingCharacters(in: .whitespacesAndNewlines), to: HuggingFace.tokenPath)
                    HuggingFace.clearNotice()
                    draft = ""
                    saved = HuggingFace.token() != nil
                    LocalModelMenu.shared.refresh()
                } catch { AgentEvents.report(error) }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if saved && !fromEnvironment {
                Button("Remove") {
                    do { try FileManager.default.removeItem(atPath: HuggingFace.tokenPath) } catch { AgentEvents.report(error) }
                    saved = HuggingFace.token() != nil
                    LocalModelMenu.shared.refresh()
                }
            }
        }
        .help("For hosted models through Hugging Face, billed to your HF account. Make a fine-grained token at huggingface.co/settings/tokens with \"Make calls to Inference Providers\" ticked. Saved in ~/.config/terminess/hf_token, readable only by you.")
    }
}

struct HFModelsField: View {
    @State private var text = HuggingFace.models().joined(separator: "\n")
    @State private var changed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 260, height: 96)
                .onChange(of: text) { changed = true }
            HStack {
                Button("Defaults") {
                    text = HuggingFace.defaultModels.joined(separator: "\n")
                    try? HuggingFace.savePrivate("", to: HuggingFace.modelsPath)
                    changed = false
                    LocalModelMenu.shared.refresh()
                }
                Button("Save") {
                    let ids = HuggingFace.parseModels(text)
                    do {
                        try HuggingFace.savePrivate(ids.joined(separator: "\n"), to: HuggingFace.modelsPath)
                        text = ids.joined(separator: "\n")
                        changed = false
                        LocalModelMenu.shared.refresh()
                    } catch { AgentEvents.report(error) }
                }
                .disabled(!changed)
            }
        }
    }
}

@MainActor
final class HFAgentMenu: NSObject, NSMenuDelegate {
    static let shared = HFAgentMenu()
    let menu = NSMenu(title: "Hugging Face")

    override init() {
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let notice = HuggingFace.notice() {
            menu.addItem(LocalModelMenu.noticeItem(notice))
            menu.addItem(.separator())
        }
        for id in HuggingFace.models() {
            let item = menu.addItem(withTitle: id, action: #selector(AppDelegate.newAgentTab(_:)), keyEquivalent: "")
            item.representedObject = HuggingFace.prefix + id
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uses your Hugging Face token (Settings). Type /model hf:ORG/MODEL for any other.", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Choose the Models…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
    }
}
