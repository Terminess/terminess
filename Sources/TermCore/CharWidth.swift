public enum CharWidth {
    @inline(__always)
    public static func of(_ s: Unicode.Scalar) -> Int {
        let v = s.value
        if v < 0x300 { return v < 0x20 || (v >= 0x7F && v < 0xA0) ? 0 : 1 }
        if inRanges(v, zeroWidthRanges) { return 0 }
        if v >= 0x1100 && inRanges(v, wideRanges) { return 2 }
        return 1
    }

    public static func ofCluster(_ scalars: String.UnicodeScalarView) -> Int {
        var first: Unicode.Scalar?
        var regionalCount = 0
        for s in scalars {
            if first == nil { first = s }
            switch s.value {
            case 0xFE0F: return 2
            case 0xFE0E: return 1
            case 0x1F1E6...0x1F1FF: regionalCount += 1
            default: break
            }
        }
        guard let base = first else { return 0 }
        if regionalCount >= 2 { return 2 }
        return max(1, of(base))
    }

    @inline(__always)
    public static func isRegionalIndicator(_ s: Unicode.Scalar) -> Bool {
        s.value >= 0x1F1E6 && s.value <= 0x1F1FF
    }

    @inline(__always)
    public static func isEmojiModifier(_ s: Unicode.Scalar) -> Bool {
        s.value >= 0x1F3FB && s.value <= 0x1F3FF
    }

    public static var unicodeVersion: String { unicodeDataVersion }

    @inline(__always)
    static func inRanges(_ v: UInt32, _ table: [(UInt32, UInt32)]) -> Bool {
        var lo = 0
        var hi = table.count - 1
        if v < table[0].0 || v > table[hi].1 { return false }
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let r = table[mid]
            if v < r.0 { hi = mid - 1 } else if v > r.1 { lo = mid + 1 } else { return true }
        }
        return false
    }
}
