public protocol ParserHandler: AnyObject {
    func print(_ scalar: Unicode.Scalar)
    func printASCII(_ bytes: UnsafeBufferPointer<UInt8>)
    func execute(_ byte: UInt8)
    func csiDispatch(_ params: CSIParams, _ intermediates: Intermediates, final: UInt8)
    func escDispatch(_ intermediates: Intermediates, final: UInt8)
    func oscDispatch(_ data: [UInt8])
    func dcsHook(_ params: CSIParams, _ intermediates: Intermediates, final: UInt8)
    func dcsPut(_ byte: UInt8)
    func dcsUnhook()
}

public struct Intermediates: Equatable, Sendable {
    public var prefix: UInt8 = 0
    public private(set) var count: Int = 0
    private var b0: UInt8 = 0
    private var b1: UInt8 = 0
    public private(set) var overflow = false

    public init() {}

    public init(prefix: UInt8 = 0, _ bytes: [UInt8] = []) {
        self.prefix = prefix
        for b in bytes { append(b) }
    }

    public subscript(i: Int) -> UInt8 { i == 0 ? b0 : b1 }

    public var first: UInt8 { count > 0 ? b0 : 0 }

    mutating func append(_ b: UInt8) {
        switch count {
        case 0: b0 = b; count = 1
        case 1: b1 = b; count = 2
        default: overflow = true
        }
    }

    mutating func clear() { self = Intermediates() }
}

public struct CSIParams: Equatable, Sendable {
    public static let maxValues = 32

    public private(set) var values: [Int] = []
    public private(set) var starts: [Int] = []

    public init() {
        values.reserveCapacity(Self.maxValues)
        starts.reserveCapacity(Self.maxValues)
    }

    public init(_ groups: [[Int]]) {
        self.init()
        for g in groups {
            starts.append(values.count)
            values.append(contentsOf: g.isEmpty ? [-1] : g)
        }
    }

    public var count: Int { starts.count }
    public var isEmpty: Bool { starts.isEmpty }

    public func get(_ i: Int, _ d: Int) -> Int {
        guard i < starts.count else { return d }
        let v = values[starts[i]]
        return v <= 0 ? d : v
    }

    public func raw(_ i: Int, _ d: Int = -1) -> Int {
        guard i < starts.count else { return d }
        let v = values[starts[i]]
        return v < 0 ? d : v
    }

    public func group(_ i: Int) -> ArraySlice<Int> {
        guard i < starts.count else { return [] }
        let end = i + 1 < starts.count ? starts[i + 1] : values.count
        return values[starts[i]..<end]
    }

    private var current = -1
    private var pendingSub = false
    private var touched = false

    mutating func reset() {
        values.removeAll(keepingCapacity: true)
        starts.removeAll(keepingCapacity: true)
        current = -1
        pendingSub = false
        touched = false
    }

    mutating func digit(_ d: Int) {
        touched = true
        if current < 0 { current = 0 }
        if current < 100_000 { current = current * 10 + d }
    }

    mutating func separator() {
        touched = true
        commit()
        pendingSub = false
    }

    mutating func subSeparator() {
        touched = true
        commit()
        pendingSub = true
    }

    mutating func finish() {
        if touched { commit() }
    }

    private mutating func commit() {
        guard values.count < Self.maxValues else { current = -1; return }
        if !pendingSub { starts.append(values.count) }
        values.append(current)
        current = -1
    }
}

public final class Parser {
    enum State: UInt8 {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
        case oscString, sosPmApcString
    }

    public var maxOSCLength = 8 * 1024 * 1024

    private(set) var state: State = .ground
    private var params = CSIParams()
    private var intermediates = Intermediates()
    private var osc: [UInt8] = []
    private var oscOverflow = false

    private var utf8Codepoint: UInt32 = 0
    private var utf8Remaining = 0
    private var utf8Lower: UInt8 = 0x80
    private var utf8Upper: UInt8 = 0xBF

    public init() {}

    public func reset() {
        state = .ground
        params.reset()
        intermediates.clear()
        osc.removeAll(keepingCapacity: true)
        utf8Remaining = 0
    }

    public func feed(_ bytes: [UInt8], to h: ParserHandler) {
        bytes.withUnsafeBufferPointer { feed($0, to: h) }
    }

    public func feed(_ text: String, to h: ParserHandler) {
        feed(Array(text.utf8), to: h)
    }

    public func feed(_ buf: UnsafeBufferPointer<UInt8>, to h: ParserHandler) {
        var i = 0
        let n = buf.count
        while i < n {
            if state == .ground && utf8Remaining == 0 {
                var j = i
                while j < n, buf[j] >= 0x20, buf[j] < 0x7F { j += 1 }
                if j > i {
                    h.printASCII(UnsafeBufferPointer(rebasing: buf[i..<j]))
                    i = j
                    continue
                }
            }
            step(buf[i], h)
            i += 1
        }
    }


    private func step(_ b: UInt8, _ h: ParserHandler) {
        if b == 0x18 || b == 0x1A {
            if state == .dcsPassthrough { h.dcsUnhook() }
            if utf8Remaining > 0 { utf8Remaining = 0; h.print("\u{FFFD}") }
            state = .ground
            if b == 0x1A { h.execute(b) }
            return
        }
        if b == 0x1B {
            switch state {
            case .oscString: dispatchOSC(h)
            case .dcsPassthrough: h.dcsUnhook()
            default: break
            }
            if utf8Remaining > 0 { utf8Remaining = 0; h.print("\u{FFFD}") }
            enterEscape()
            return
        }

        switch state {
        case .ground:
            ground(b, h)

        case .escape:
            if isC0(b) { h.execute(b); return }
            switch b {
            case 0x20...0x2F: intermediates.append(b); state = .escapeIntermediate
            case 0x5B: enterCSI()
            case 0x5D: osc.removeAll(keepingCapacity: true); oscOverflow = false; state = .oscString
            case 0x50: params.reset(); intermediates.clear(); state = .dcsEntry
            case 0x58, 0x5E, 0x5F: state = .sosPmApcString
            case 0x30...0x7E: h.escDispatch(intermediates, final: b); state = .ground
            case 0x7F: break
            default: reprocessInGround(b, h)
            }

        case .escapeIntermediate:
            if isC0(b) { h.execute(b); return }
            switch b {
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x7E: h.escDispatch(intermediates, final: b); state = .ground
            case 0x7F: break
            default: reprocessInGround(b, h)
            }

        case .csiEntry:
            if isC0(b) { h.execute(b); return }
            switch b {
            case 0x30...0x39: params.digit(Int(b - 0x30)); state = .csiParam
            case 0x3B: params.separator(); state = .csiParam
            case 0x3A: params.subSeparator(); state = .csiParam
            case 0x3C...0x3F: intermediates.prefix = b; state = .csiParam
            case 0x20...0x2F: intermediates.append(b); state = .csiIntermediate
            case 0x40...0x7E: dispatchCSI(b, h)
            case 0x7F: break
            default: reprocessInGround(b, h)
            }

        case .csiParam:
            if isC0(b) { h.execute(b); return }
            switch b {
            case 0x30...0x39: params.digit(Int(b - 0x30))
            case 0x3B: params.separator()
            case 0x3A: params.subSeparator()
            case 0x3C...0x3F: state = .csiIgnore
            case 0x20...0x2F: intermediates.append(b); state = .csiIntermediate
            case 0x40...0x7E: dispatchCSI(b, h)
            case 0x7F: break
            default: reprocessInGround(b, h)
            }

        case .csiIntermediate:
            if isC0(b) { h.execute(b); return }
            switch b {
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x3F: state = .csiIgnore
            case 0x40...0x7E: dispatchCSI(b, h)
            case 0x7F: break
            default: reprocessInGround(b, h)
            }

        case .csiIgnore:
            if isC0(b) { h.execute(b); return }
            switch b {
            case 0x40...0x7E: state = .ground
            case 0x20...0x3F, 0x7F: break
            default: reprocessInGround(b, h)
            }

        case .dcsEntry:
            switch b {
            case 0x30...0x39: params.digit(Int(b - 0x30)); state = .dcsParam
            case 0x3B: params.separator(); state = .dcsParam
            case 0x3A: params.subSeparator(); state = .dcsParam
            case 0x3C...0x3F: intermediates.prefix = b; state = .dcsParam
            case 0x20...0x2F: intermediates.append(b); state = .dcsIntermediate
            case 0x40...0x7E: hookDCS(b, h)
            default: break
            }

        case .dcsParam:
            switch b {
            case 0x30...0x39: params.digit(Int(b - 0x30))
            case 0x3B: params.separator()
            case 0x3A: params.subSeparator()
            case 0x3C...0x3F: state = .dcsIgnore
            case 0x20...0x2F: intermediates.append(b); state = .dcsIntermediate
            case 0x40...0x7E: hookDCS(b, h)
            default: break
            }

        case .dcsIntermediate:
            switch b {
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x3F: state = .dcsIgnore
            case 0x40...0x7E: hookDCS(b, h)
            default: break
            }

        case .dcsPassthrough:
            if b != 0x7F { h.dcsPut(b) }

        case .dcsIgnore:
            break

        case .oscString:
            if b == 0x07 { dispatchOSC(h); state = .ground; return }
            if b >= 0x20 {
                if osc.count < maxOSCLength { osc.append(b) } else { oscOverflow = true }
            }

        case .sosPmApcString:
            break
        }
    }

    @inline(__always) private func isC0(_ b: UInt8) -> Bool { b < 0x20 }

    private func enterEscape() {
        intermediates.clear()
        state = .escape
    }

    private func enterCSI() {
        params.reset()
        intermediates.clear()
        state = .csiEntry
    }

    private func dispatchCSI(_ final: UInt8, _ h: ParserHandler) {
        params.finish()
        if !intermediates.overflow { h.csiDispatch(params, intermediates, final: final) }
        state = .ground
    }

    private func hookDCS(_ final: UInt8, _ h: ParserHandler) {
        params.finish()
        h.dcsHook(params, intermediates, final: final)
        state = .dcsPassthrough
    }

    private func dispatchOSC(_ h: ParserHandler) {
        h.oscDispatch(osc)
        osc.removeAll(keepingCapacity: true)
    }

    private func reprocessInGround(_ b: UInt8, _ h: ParserHandler) {
        state = .ground
        ground(b, h)
    }


    private func ground(_ b: UInt8, _ h: ParserHandler) {
        if utf8Remaining > 0 {
            if b >= utf8Lower && b <= utf8Upper {
                utf8Codepoint = (utf8Codepoint << 6) | UInt32(b & 0x3F)
                utf8Lower = 0x80; utf8Upper = 0xBF
                utf8Remaining -= 1
                if utf8Remaining == 0 {
                    h.print(Unicode.Scalar(utf8Codepoint) ?? "\u{FFFD}")
                }
                return
            }
            utf8Remaining = 0
            h.print("\u{FFFD}")
        }

        switch b {
        case 0x00..<0x20: h.execute(b)
        case 0x20..<0x7F: h.print(Unicode.Scalar(b))
        case 0x7F: break
        case 0xC2...0xDF: utf8Codepoint = UInt32(b & 0x1F); utf8Remaining = 1
        case 0xE0: utf8Codepoint = UInt32(b & 0x0F); utf8Remaining = 2; utf8Lower = 0xA0
        case 0xE1...0xEC, 0xEE, 0xEF: utf8Codepoint = UInt32(b & 0x0F); utf8Remaining = 2
        case 0xED: utf8Codepoint = UInt32(b & 0x0F); utf8Remaining = 2; utf8Upper = 0x9F
        case 0xF0: utf8Codepoint = UInt32(b & 0x07); utf8Remaining = 3; utf8Lower = 0x90
        case 0xF1...0xF3: utf8Codepoint = UInt32(b & 0x07); utf8Remaining = 3
        case 0xF4: utf8Codepoint = UInt32(b & 0x07); utf8Remaining = 3; utf8Upper = 0x8F
        default: h.print("\u{FFFD}")
        }
    }
}
