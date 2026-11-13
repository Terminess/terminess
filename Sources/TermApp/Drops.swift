import AppKit
import UniformTypeIdentifiers

enum Drops {
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string]
    static let utTypes: [UTType] = [.fileURL, .url, .image, .plainText]

    static func text(from pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { escape($0.path) }.joined(separator: " ")
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
final class DropRelay {
    var handler: ((NSPasteboard) -> Bool)?
    func drop(_ pb: NSPasteboard) -> Bool { handler?(pb) ?? false }
    func dropFromSwiftUI() -> Bool { drop(NSPasteboard(name: .drag)) }
}
