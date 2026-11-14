import AppKit
import UniformTypeIdentifiers

enum Drops {
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string]
    static let utTypes: [UTType] = [.fileURL, .url, .image, .plainText]

    static func text(from pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var paths: [String] = [], unreadable: [String] = []
            for url in urls {
                if let path = readablePath(url) { paths.append(escape(path)) } else { unreadable.append(url.path) }
            }
            if !unreadable.isEmpty { DispatchQueue.main.async { Privacy.explain(unreadable: unreadable) } }
            return paths.isEmpty ? nil : paths.joined(separator: " ")
        }
        if let image = NSImage(pasteboard: pb), let url = save(image) {
            return escape(url.path)
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map(\.absoluteString).joined(separator: " ")
        }
        return pb.string(forType: .string)
    }

    static func escape(_ path: String) -> String {
        let special = Set(" \t\\'\"()[]{}<>|&;$`!*?#~=%^,")
        var out = ""
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func readablePath(_ url: URL) -> String? {
        let path = url.path
        let readable = (try? FileHandle(forReadingFrom: url)).map { try? $0.close(); return true } ?? false
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return path }
        guard readable else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let attachment = type.map { $0.conforms(to: .image) || $0.conforms(to: .pdf) } ?? false
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard attachment, Privacy.isProtected(path), size < 50_000_000 else { return path }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy.path : path
    }

    private static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Dropped image \(f.string(from: Date())).png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }
}

@MainActor
final class WindowLink {
    var handler: ((NSPasteboard) -> Bool)?
    var owner: ObjectIdentifier?
    func drop(_ pb: NSPasteboard) -> Bool { handler?(pb) ?? false }
    func dropFromSwiftUI() -> Bool { drop(NSPasteboard(name: .drag)) }
}

enum Privacy {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func isProtected(_ path: String) -> Bool {
        let guarded = ["/Desktop/", "/Documents/", "/Downloads/", "/Library/Mobile Documents/", "/Pictures/", "/Movies/"]
        return guarded.contains { path.hasPrefix(home + $0) }
            || path.contains("/TemporaryItems/") || path.hasPrefix("/Volumes/")
    }

    static var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: home + "/Library/Application Support/com.apple.TCC/TCC.db")
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    @MainActor static func explain(unreadable: [String]) {
        let alert = NSAlert()
        alert.messageText = unreadable.count == 1 ? "Terminess can't read that file" : "Terminess can't read those files"
        alert.informativeText = "macOS is blocking access to \(unreadable.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")). "
            + "Give Terminess Full Disk Access in System Settings. New tabs get it once Terminess and its session service restart; tabs already open keep the old access until then."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openFullDiskAccessSettings() }
    }
}
