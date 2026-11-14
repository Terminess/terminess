import SwiftUI

struct MarkdownView: View {
    let text: String

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, ordered: String?)
        case code(String, lang: String)
        case table([[String]])
        case quote(String)
        case rule
    }

    var codeSize: CGFloat = 12

    var body: some View {
        let blocks = MarkdownView.blocks(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                view(for: block)
                    .padding(.top, i == 0 ? 0 : MarkdownView.gap(before: block, after: blocks[i - 1]))
            }
        }
        .lineSpacing(3)
        .textSelection(.enabled)
    }

    static func gap(before block: Block, after previous: Block) -> CGFloat {
        switch (previous, block) {
        case (.bullet, .bullet): return 6
        case (_, .heading): return 20
        case (.heading, _): return 8
        default: return 14
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            inline(s).font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
        case .paragraph(let s):
            inline(s).fixedSize(horizontal: false, vertical: true)
        case .bullet(let s, let ordered):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordered.map { "\($0)." } ?? "•").foregroundStyle(.secondary)
                inline(s).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        case .code(let s, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(size: codeSize, design: .monospaced)).padding(10)
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

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var lines = text.components(separatedBy: "\n")[...]
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        while let line = lines.first {
            lines = lines.dropFirst()
            let t = line.trimmingCharacters(in: .whitespaces)
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
            } else if let m = t.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
                flush()
                out.append(.bullet(String(m.1), ordered: nil))
            } else if let m = t.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                flush()
                out.append(.bullet(String(m.2), ordered: String(m.1)))
            } else if t.hasPrefix(">") {
                flush()
                out.append(.quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if t == "---" || t == "***" {
                flush()
                out.append(.rule)
            } else if t.isEmpty {
                flush()
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
