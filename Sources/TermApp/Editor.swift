import AppKit

@MainActor
enum Editor {
    static let choices: [(String, String)] = [
        ("default", "Default app"), ("vscode", "Visual Studio Code"), ("cursor", "Cursor"),
        ("zed", "Zed"), ("sublime", "Sublime Text"), ("xcode", "Xcode"),
    ]

    static func open(_ path: String, line: Int?, column: Int?) {
        let l = line ?? 1, c = column ?? 1
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var url: URL?
        switch Settings.shared.editor {
        case "vscode": url = URL(string: "vscode://file\(encoded):\(l):\(c)")
        case "cursor": url = URL(string: "cursor://file\(encoded):\(l):\(c)")
        case "zed": url = URL(string: "zed://file\(encoded):\(l):\(c)")
        case "sublime": url = URL(string: "subl://open?url=file://\(encoded)&line=\(l)&column=\(c)")
        case "xcode":
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            p.arguments = line != nil ? ["--line", "\(l)", path] : [path]
            if (try? p.run()) != nil { return }
        default: break
        }
        if let url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
