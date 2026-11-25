import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MarkdownView: View {
    let text: String

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, ordered: String?, level: Int)
        case code(String, lang: String)
        case table([[String]])
        case quote(String)
        case rule
    }

    var codeSize: CGFloat = 12
    var bodySize: CGFloat? = nil
    var lineGap: CGFloat = 3
    var blockGap: CGFloat? = nil

    var body: some View {
        let blocks = MarkdownView.blocks(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                view(for: block)
                    .padding(.top, i == 0 ? 0 : gap(before: block, after: blocks[i - 1]))
            }
        }
        .font(bodySize.map { .system(size: $0) } ?? .body)
        .lineSpacing(lineGap)
        .textSelection(.enabled)
    }

    func gap(before block: Block, after previous: Block) -> CGFloat {
        if let even = blockGap {
            if case .bullet = previous, case .bullet = block { return 8 }
            return even
        }
        switch (previous, block) {
        case (.bullet, .bullet): return 8
        case (_, .heading): return 22
        case (.heading, _): return 8
        case (.bullet, _), (_, .bullet): return 12
        default: return 14
        }
    }

    static let listStep: CGFloat = 26
    private static let markerWidth: CGFloat = 22

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            if let size = bodySize {
                inline(s).font(.system(size: level <= 1 ? size + 5 : level == 2 ? size + 2 : size, weight: .semibold))
            } else {
                inline(s).font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
            }
        case .paragraph(let s):
            inline(s).fixedSize(horizontal: false, vertical: true)
        case .bullet(let s, let ordered, let level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordered.map { "\($0)." } ?? MarkdownView.marker(level))
                    .foregroundStyle(.secondary)
                    .frame(width: MarkdownView.markerWidth, alignment: ordered == nil ? .center : .trailing)
                inline(s).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2 + CGFloat(level) * MarkdownView.listStep)
        case .code(let s, _):
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(s).font(.system(size: codeSize, design: .monospaced)).padding(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                CopyButton(text: s).padding(5)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        case .table(let rows):
            TableBlock(rows: rows)
        case .quote(let s):
            inline(s).foregroundStyle(.secondary).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .rule:
            Divider()
        }
    }

    static func marker(_ level: Int) -> String {
        ["\u{2022}", "\u{25E6}", "\u{25AA}"][min(level, 2)]
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var lines = text.components(separatedBy: "\n")[...]
        var listIndents: [Int] = []
        var inItem = false
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        func indent(_ line: String) -> Int {
            var n = 0
            for c in line { if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break } }
            return n
        }
        func item(_ text: String, ordered: String?, indent: Int) {
            flush()
            while let last = listIndents.last, last > indent { listIndents.removeLast() }
            if listIndents.last != indent { listIndents.append(indent) }
            out.append(.bullet(text, ordered: ordered, level: max(0, listIndents.count - 1)))
            inItem = true
        }
        while let line = lines.first {
            lines = lines.dropFirst()
            let t = line.trimmingCharacters(in: .whitespaces)
            let isItem = t.firstMatch(of: #/^([-*+]|\d+[.)])\s+/#) != nil
            if inItem, !t.isEmpty, !isItem, !t.hasPrefix("```"), !t.hasPrefix("|"), !t.hasPrefix("#"), !t.hasPrefix(">"),
               case .bullet(let s, let o, let l)? = out.last {
                out[out.count - 1] = .bullet(s + " " + t, ordered: o, level: l)
                continue
            }
            if !isItem && !t.isEmpty {
                inItem = false
                if indent(line) == 0 { listIndents = [] }
            }
            if t.hasPrefix("```") {
                flush()
                let lang = String(t.dropFirst(3))
                var code: [String] = []
                while let l = lines.first, !l.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(l); lines = lines.dropFirst()
                }
                lines = lines.dropFirst()
                out.append(.code(code.joined(separator: "\n"), lang: lang))
            } else if t.hasPrefix("|") && t.hasSuffix("|") {
                flush()
                var rows: [[String]] = []
                var l: String? = line
                while let row = l?.trimmingCharacters(in: .whitespaces), row.hasPrefix("|") {
                    let cells = row.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { rows.append(cells) }
                    if let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                        l = next; lines = lines.dropFirst()
                    } else { l = nil }
                }
                out.append(.table(rows))
            } else if let m = t.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flush()
                out.append(.heading(m.1.count, String(m.2)))
            } else if let m = t.firstMatch(of: #/^[-*+]\s+(.*)$/#), t != "---", t != "***" {
                item(String(m.1), ordered: nil, indent: indent(line))
            } else if let m = t.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                item(String(m.2), ordered: String(m.1), indent: indent(line))
            } else if t.hasPrefix(">") {
                flush()
                out.append(.quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if t == "---" || t == "***" {
                flush()
                out.append(.rule)
            } else if t.isEmpty {
                flush()
                inItem = false
            } else {
                para.append(t)
            }
        }
        flush()
        return out
    }
}

private struct TableBlock: View {
    let rows: [[String]]
    var body: some View {
        let cols = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            let cell = c < row.count ? row[c] : ""
                            Group {
                                if let a = try? AttributedString(markdown: cell) { Text(a) } else { Text(cell) }
                            }
                            .font(i == 0 ? .callout.weight(.semibold) : .callout)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy")
    }
}
