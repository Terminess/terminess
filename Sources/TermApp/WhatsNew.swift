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
        ReleaseNote(id: 8, title: "Several chats at once", date: "November 2026", items: [
            "Split Right (Cmd-D) and Split Down (Shift-Cmd-D) now work in Chat: each pane gets its own column with its conversation and message box, so you can work with several agents side by side.",
            "A new column opens on the start page: pick a project and an agent there. Click a column to type in it; its message box shows a clearer edge.",
            "Questions and permission requests appear in the column of the agent that asked.",
        ]),
        ReleaseNote(id: 7, title: "An easier read", date: "November 2026", items: [
            "Chat folds each run of tool steps into one line, such as \u{201C}Ran 4 commands, read a file\u{201D}. Click it to see each step.",
            "While the agent works, one line shows what it is doing now and how long the turn has taken, beside a turning star.",
            "Replies are easier to read: larger text, more room between lines, and nested lists that indent properly.",
            "More room either side of the message box.",
            "The sidebar is calmer: New session isn\u{2019}t highlighted all the time, Library and Models sit under More (rest the pointer on it), and each session\u{2019}s machine shows beside its mark.",
            "No folder lists the conversations started outside any project, such as in your home folder.",
            "Sidebar rows are taller and lighter, with larger text and more room between sections. Session icons are grey; green stays in Machines, to show what\u{2019}s connected.",
            "Rest the pointer on a project to start a new session there: pick Claude Code, Codex or a shell, on this Mac or a server.",
            "Projects or Recent is now the sort icon beside Sessions.",
            "No more tab strip: the header shows the session\u{2019}s name, with Rename, Notify My Phone, Show in Finder and Close under its chevron. The sidebar\u{2019}s Open section lists every tab, and Cmd-1 to 9 and Ctrl-Tab still switch.",
            "Screenshots and files you drop into Terminess reach agents on your servers without a prompt.",
            "Chat reads more evenly: one text size throughout, the same room between every paragraph, and a copy button on code.",
            "The agent\u{2019}s name and star sit before the session\u{2019}s name in the header.",
            "Conversations in scratch folders (borrowed tasks, temporary folders) sit under No folder.",
            "Each finished reply in Chat ends with how long it took and when it finished, plus any background shells still running.",
            "The working line names Terminess\u{2019}s own steps plainly (\u{201C}Working on your Mac\u{201D}), and its time restarts with each message.",
        ]),
        ReleaseNote(id: 6, title: "Straight to the newest", date: "November 2026", items: [
            "When you open an older conversation, the notice that a newer one exists has Open newest: it brings forward the tab showing the newest one, or resumes it in a new tab.",
            "What\u{2019}s new stays open when you click it.",
            "Borrowing this Mac: Always Allow lets a machine borrow it without asking (undo in Settings, Agents), and a borrowed Claude Code can run ordinary build and git commands.",
        ]),
        ReleaseNote(id: 5, title: "Tabs that come back", date: "November 2026", items: [
            "A tab that loses its connection (sleep, a network change, a timed-out ssh link) reconnects to the same session on its own, and the sidebar shows it reconnecting.",
            "Refresh, beside Open in the sidebar, reconnects every machine and tab at once and reloads your sessions. Waking the Mac does the same.",
            "Projects or Recent: switch the sidebar between sessions grouped by project and one list of every session, any agent or machine, newest first.",
            "Running sessions outside a project now sit with the other running ones instead of at the bottom.",
            "Agents on another machine can copy a file from this Mac (copy_from_mac), after you allow it.",
        ]),
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
    private static var closeObserver: NSObjectProtocol?

    static func show(relativeTo view: NSView) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: WhatsNewView(notes: ReleaseNotes.all, feed: feed))
        p.contentSize = NSSize(width: 380, height: 440)
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        popover = p
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                closeObserver = nil
                markSeen()
            }
        }
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
