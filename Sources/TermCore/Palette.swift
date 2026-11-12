public struct RGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    public init?(spec: String) {
        if spec.hasPrefix("#"), spec.count == 7, let v = UInt32(spec.dropFirst(), radix: 16) {
            self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
            return
        }
        guard spec.hasPrefix("rgb:") else { return nil }
        let parts = spec.dropFirst(4).split(separator: "/")
        guard parts.count == 3 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 4, let v = UInt32(p, radix: 16) else { return nil }
            let maxV = (UInt32(1) << (4 * UInt32(p.count))) - 1
            out.append(UInt8((v * 255 + maxV / 2) / maxV))
        }
        self.init(out[0], out[1], out[2])
    }

    public var xtermSpec: String {
        func h(_ v: UInt8) -> String {
            let s = String(UInt16(v) * 257, radix: 16)
            return String(repeating: "0", count: 4 - s.count) + s
        }
        return "rgb:\(h(r))/\(h(g))/\(h(b))"
    }
}

public struct Palette: Sendable {
    public var colors: [RGB]
    public var foreground = RGB(0xE6, 0xE6, 0xE6)
    public var background = RGB(0x16, 0x16, 0x18)
    public var cursor = RGB(0xE6, 0xE6, 0xE6)

    public init() {
        colors = Palette.xterm256
    }

    public static let ansi16: [RGB] = [
        RGB(0x00, 0x00, 0x00), RGB(0xCD, 0x31, 0x31), RGB(0x0D, 0xBC, 0x79), RGB(0xE5, 0xE5, 0x10),
        RGB(0x24, 0x72, 0xC8), RGB(0xBC, 0x3F, 0xBC), RGB(0x11, 0xA8, 0xCD), RGB(0xCC, 0xCC, 0xCC),
        RGB(0x66, 0x66, 0x66), RGB(0xF1, 0x4C, 0x4C), RGB(0x23, 0xD1, 0x8B), RGB(0xF5, 0xF5, 0x43),
        RGB(0x3B, 0x8E, 0xEA), RGB(0xD6, 0x70, 0xD6), RGB(0x29, 0xB8, 0xDB), RGB(0xF2, 0xF2, 0xF2),
    ]

    public static let xterm256: [RGB] = {
        var c = ansi16
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 { c.append(RGB(steps[r], steps[g], steps[b])) } } }
        for i in 0..<24 { let v = UInt8(8 + i * 10); c.append(RGB(v, v, v)) }
        return c
    }()

    public func resolve(_ color: Color, isForeground: Bool) -> RGB {
        if let i = color.index { return colors[Int(i)] }
        if let c = color.rgb { return RGB(c.r, c.g, c.b) }
        return isForeground ? foreground : background
    }
}
