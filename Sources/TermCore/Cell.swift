public struct Color: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt32

    public static let `default` = Color(raw: 0)
    public static func indexed(_ i: UInt8) -> Color { Color(raw: 0x0100_0000 | UInt32(i)) }
    public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color {
        Color(raw: 0x0200_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
    }

    public init(raw: UInt32) { self.raw = raw }

    public var isDefault: Bool { raw == 0 }
    public var index: UInt8? { raw >> 24 == 1 ? UInt8(raw & 0xFF) : nil }
    public var rgb: (r: UInt8, g: UInt8, b: UInt8)? {
        raw >> 24 == 2 ? (UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)) : nil
    }

    public var description: String {
        if let i = index { return "idx(\(i))" }
        if let c = rgb { return "rgb(\(c.r),\(c.g),\(c.b))" }
        return "default"
    }
}

public struct CellFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold          = CellFlags(rawValue: 1 << 0)
    public static let faint         = CellFlags(rawValue: 1 << 1)
    public static let italic        = CellFlags(rawValue: 1 << 2)
    public static let blink         = CellFlags(rawValue: 1 << 3)
    public static let inverse       = CellFlags(rawValue: 1 << 4)
    public static let invisible     = CellFlags(rawValue: 1 << 5)
    public static let strikethrough = CellFlags(rawValue: 1 << 6)
    public static let overline      = CellFlags(rawValue: 1 << 7)
    public static let wide          = CellFlags(rawValue: 1 << 8)
    public static let wideTail      = CellFlags(rawValue: 1 << 9)
    public static let cluster       = CellFlags(rawValue: 1 << 10)
}

public enum UnderlineStyle: UInt8, Sendable {
    case none, single, double, curly, dotted, dashed
}

public struct Attributes: Hashable, Sendable {
    public var fg: Color = .default
    public var bg: Color = .default
    public var underlineColor: Color = .default
    public var flags: CellFlags = []
    public var underline: UnderlineStyle = .none
    public var link: UInt16 = 0

    public init() {}

    public static let plain = Attributes()

    var erased: Attributes {
        var a = Attributes()
        a.bg = bg
        return a
    }
}

public struct Cell: Hashable, Sendable {
    public var scalar: UInt32
    public var attrs: Attributes

    public init(scalar: UInt32 = 0, attrs: Attributes = .plain) {
        self.scalar = scalar
        self.attrs = attrs
    }

    public static let blank = Cell()

    public var isEmpty: Bool { scalar == 0 }
    public var isWide: Bool { attrs.flags.contains(.wide) }
    public var isWideTail: Bool { attrs.flags.contains(.wideTail) }
}

public struct RowMark: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let prompt = RowMark(rawValue: 1)
    public static let output = RowMark(rawValue: 2)
    public static let finished = RowMark(rawValue: 4)
    public static let failed = RowMark(rawValue: 8)
}

public struct Row: Sendable {
    public var cells: [Cell]
    public var mark: RowMark = []
    public var wrapped = false
    public var clusters: [Int: String] = [:]

    public init(columns: Int, fill: Cell = .blank) {
        cells = Array(repeating: fill, count: columns)
    }

    public var count: Int { cells.count }

    public func text(at x: Int) -> String {
        let c = cells[x]
        if c.isWideTail || c.isEmpty { return "" }
        if c.attrs.flags.contains(.cluster), let s = clusters[x] { return s }
        return Unicode.Scalar(c.scalar).map { String(Character($0)) } ?? ""
    }

    public func plainText(trimTrailing: Bool = true) -> String {
        var out = ""
        var pendingSpaces = 0
        for x in 0..<cells.count {
            let c = cells[x]
            if c.isWideTail { continue }
            if c.isEmpty {
                pendingSpaces += 1
                continue
            }
            if pendingSpaces > 0 { out += String(repeating: " ", count: pendingSpaces); pendingSpaces = 0 }
            out += text(at: x)
        }
        if !trimTrailing && pendingSpaces > 0 { out += String(repeating: " ", count: pendingSpaces) }
        if trimTrailing {
            while out.last == " " { out.removeLast() }
        }
        return out
    }

    mutating func clear(_ range: Range<Int>, with fill: Cell) {
        guard !range.isEmpty else { return }
        for x in range { cells[x] = fill }
        if !clusters.isEmpty { for x in range { clusters[x] = nil } }
    }

    mutating func resize(to columns: Int, fill: Cell = .blank) {
        if columns < cells.count {
            cells.removeLast(cells.count - columns)
            if !clusters.isEmpty { clusters = clusters.filter { $0.key < columns } }
            if let last = cells.last, last.isWide { cells[columns - 1] = fill }
        } else if columns > cells.count {
            cells.append(contentsOf: repeatElement(fill, count: columns - cells.count))
        }
    }
}
