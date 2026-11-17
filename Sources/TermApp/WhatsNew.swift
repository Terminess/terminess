import AppKit
import SwiftUI

struct ReleaseNote: Identifiable, Equatable {
    let id: Int
    let title: String
    let date: String
    let items: [String]
}

enum ReleaseNotes {
    static let all: [ReleaseNote] = [
        ReleaseNote(id: 4, title: "A calmer window", date: "November 2026", items: [
            "The sidebar runs the full height of the window, with the traffic lights and the sidebar button in its top row.",
            "Terminal, Split and Chat are plain icons at the top right of every session.",
            "New sessions open on a start page: pick This Mac or another machine, choose a folder, or bring in past conversations.",
            "Import past Claude Code, Codex and Gemini CLI conversations into the sidebar, ready to read and resume.",
            "Settings open inside the window, with search and a description beside every option.",
            "A larger composer with the machine, folder, branch, model and context underneath.",
            "Pair iPhone moves to the Terminess menu once a phone is paired, and Open no longer repeats tabs listed under a project.",
        ]),
        ReleaseNote(id: 3, title: "Machines and named devices", date: "November 2026", items: [
            "One flat Machines list: This Mac, each remote machine with its role, and every iPhone with a session open.",
            "Sessions show which machine and which device they're on, and an Other group catches the rest.",
        ]),
        ReleaseNote(id: 2, title: "Menus in Chat", date: "October 2026", items: [
            "Chat answers menus that no hook reports, such as Claude Code's folder trust check, as cards you can tap.",
            "Tabs always bring forward the tab the tab bar highlights.",
        ]),
        ReleaseNote(id: 1, title: "Notarised releases", date: "October 2026", items: [
            "Releases are signed with a Developer ID and notarised by Apple.",
            "Check for Updates in the Terminess menu tells you when a newer build is out. Terminess never checks on its own.",
        ]),
    ]

    static var newest: Int { all.map(\.id).max() ?? 0 }
}

@MainActor
enum WhatsNew {
    static let changed = Notification.Name("WhatsNewChanged")
    private static let seenKey = "whatsNew.seen"
    private static let feedKey = "whatsNew.feed"

    static var hasUnseen: Bool {
        if let forced = ProcessInfo.processInfo.environment["TERMAPP_WHATS_NEW"] { return forced == "1" }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: seenKey) != nil else {
            defaults.set(ReleaseNotes.newest, forKey: seenKey)
            return false
        }
        return ReleaseNotes.newest > defaults.integer(forKey: seenKey)
    }

    static func markSeen() {
        UserDefaults.standard.set(ReleaseNotes.newest, forKey: seenKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func rememberFeed(version: String, notes: String?) {
        guard let notes, !notes.isEmpty else { UserDefaults.standard.removeObject(forKey: feedKey); return }
        UserDefaults.standard.set(["version": version, "notes": notes], forKey: feedKey)
    }

    static var feed: (version: String, notes: String)? {
        guard let d = UserDefaults.standard.dictionary(forKey: feedKey) as? [String: String],
              let v = d["version"], let n = d["notes"] else { return nil }
        return (v, n)
    }

    private static var popover: NSPopover?

    static func show(relativeTo view: NSView) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: WhatsNewView(notes: ReleaseNotes.all, feed: feed))
        p.contentSize = NSSize(width: 380, height: 440)
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        popover = p
        markSeen()
    }
}

struct WhatsNewView: View {
    let notes: [ReleaseNote]
    let feed: (version: String, notes: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("What\u{2019}s new").font(.system(size: 15, weight: .semibold))
                if let feed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Available: \(feed.version)").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(nsColor: .whatsNew))
                        Text(feed.notes).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(note.title).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(note.id == ReleaseNotes.newest ? Color(nsColor: .whatsNew) : .primary)
                            Spacer()
                            Text(note.id == ReleaseNotes.newest ? "This version" : note.date)
                                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        }
                        ForEach(note.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Circle().fill(Color.secondary.opacity(0.6)).frame(width: 3.5, height: 3.5)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3.5 }
                                Text(item).font(.system(size: 12.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}
