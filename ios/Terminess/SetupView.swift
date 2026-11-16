import SwiftUI

struct WelcomeView: View {
    private enum Route { case mac, server }

    @ObservedObject private var store = HostStore.shared
    @State private var route: Route?
    @State private var step = 0
    @State private var adding: SavedHost?
    @State private var copied = false

    #if DEBUG
    init() {
        let parts = (ProcessInfo.processInfo.environment["TERMINESS_DEMO_SETUP"] ?? "").split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]) else { return }
        _route = State(initialValue: parts[0] == "server" ? .server : .mac)
        _step = State(initialValue: n)
    }
    #endif

    private struct Step {
        let title: String
        let text: String
        var code: String? = nil
        var note: String? = nil
    }

    private var steps: [Step] {
        switch route {
        case .mac:
            return [
                Step(title: "Get Terminess on your Mac",
                     text: "Terminess for iPhone shows what's running in Terminess on your Mac. On the Mac, download it from:",
                     code: "terminess.com/download",
                     note: "Already have it? Go straight on."),
                Step(title: "Open Pair iPhone on the Mac",
                     text: "In Terminess on your Mac, click Pair iPhone in the sidebar, or choose Terminess, Pair iPhone… in the menu bar. A code appears.",
                     note: "If it asks you to turn on Remote Login, do: that is how this iPhone reaches your Mac."),
                Step(title: "Scan the code",
                     text: "Open the Camera on this iPhone, point it at the code on your Mac, and tap the Terminess link that appears. Your Mac's sessions then show up here.",
                     note: "Keep the iPhone and the Mac on the same Wi-Fi for this step."),
            ]
        case .server:
            return [
                Step(title: "Install terminessd on the machine",
                     text: "terminessd keeps your shells and agents running and lets this iPhone attach to them. In a copy of the Terminess source on the machine, run:",
                     code: "swift build -c release --product terminessd\n.build/release/terminessd service install"),
                Step(title: "Let this iPhone in",
                     text: "Add this iPhone's key to ~/.ssh/authorized_keys on the machine. Copy it here and paste it there as one line."),
                Step(title: "Scan the code",
                     text: "On the machine, run the command below. Then open the Camera on this iPhone, point it at the code and tap the Terminess link.",
                     code: "terminessd pair",
                     note: "No camera to hand? Add the machine by typing its address instead."),
            ]
        case nil:
            return []
        }
    }

    var body: some View {
        Group {
            if route == nil { start } else { guide }
        }
        .background(Theme.background)
        .overlay(alignment: .topTrailing) {
            Button { AppState.shared.showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3).foregroundStyle(.secondary).padding(20)
            }
            .accessibilityLabel("Settings")
        }
        .sheet(item: $adding) { HostEditor(host: $0) }
    }


    private var start: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LogoMark(size: 56).foregroundStyle(Theme.ink).padding(.top, 56)
                Text("Your agents, on your phone").font(.system(size: 30, weight: .bold))
                Text("Terminess follows and steers Claude Code and Codex where they already run: on your Mac or a Linux machine. Nothing runs on the iPhone itself, so the first step is to connect one.")
                    .foregroundStyle(.secondary)
                Text("What are you connecting?").font(.headline).padding(.top, 10)
                choice("My Mac", "Scan one code from Terminess on the Mac. About a minute.", "laptopcomputer") { begin(.mac) }
                choice("A Linux PC or server", "Install a small service, then scan its code.", "server.rack") { begin(.server) }
            }
            .padding(.horizontal, 24).padding(.bottom, 40)
        }
    }

    private func choice(_ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 22)).frame(width: 34).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        }
        .buttonStyle(.plain)
    }

    private func begin(_ r: Route) {
        withAnimation(.easeOut(duration: 0.2)) { route = r; step = 0 }
    }


    private var guide: some View {
        let all = steps
        let s = all[min(step, all.count - 1)]
        let last = step == all.count - 1
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { if step == 0 { route = nil } else { step -= 1 } }
            } label: {
                Label("Back", systemImage: "chevron.left").font(.body.weight(.medium))
            }
            .padding(.horizontal, 20).padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Step \(step + 1) of \(all.count)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Text(s.title).font(.system(size: 28, weight: .bold))
                    Text(s.text).foregroundStyle(.secondary)
                    if let code = s.code {
                        Button {
                            UIPasteboard.general.string = code
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            HStack(alignment: .top) {
                                Text(code).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.ink)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Copies it")
                    }
                    if route == .server && step == 1 {
                        List { KeySection() }.frame(height: 260).scrollDisabled(true).listStyle(.insetGrouped)
                            .padding(.horizontal, -16)
                    }
                    if let note = s.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    if last { waiting }
                }
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
            }

            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<all.count, id: \.self) { i in
                        Capsule().fill(i == step ? Theme.ink : Theme.raised).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                if last {
                    Button("Add a machine by typing its address") { adding = SavedHost(name: "", address: "", user: "") }
                        .font(.callout)
                } else {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { step += 1 }
                    } label: {
                        Text(step == 0 && route == .mac ? "It's on my Mac" : "Next")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.onInk)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.ink))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
    }

    private var waiting: some View {
        HStack(spacing: 10) {
            if store.pairing == nil { ProgressView().controlSize(.small) }
            Text(store.pairing ?? "Waiting for you to scan the code…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}
