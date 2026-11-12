import CoreGraphics

enum BoxDrawing {
    private struct Arms { var u: UInt8, r: UInt8, d: UInt8, l: UInt8 }

    private static let table: [UInt32: Arms] = {
        let light: [(UInt8, UInt8, UInt8, UInt8)] = [
            (0,1,0,1), (0,2,0,2), (1,0,1,0), (2,0,2,0), (0,1,0,1), (0,2,0,2), (1,0,1,0), (2,0,2,0),
            (0,1,0,1), (0,2,0,2), (1,0,1,0), (2,0,2,0), (0,1,1,0), (0,2,1,0), (0,1,2,0), (0,2,2,0),
            (0,0,1,1), (0,0,1,2), (0,0,2,1), (0,0,2,2), (1,1,0,0), (1,2,0,0), (2,1,0,0), (2,2,0,0),
            (1,0,0,1), (1,0,0,2), (2,0,0,1), (2,0,0,2), (1,1,1,0), (1,2,1,0), (2,1,1,0), (1,1,2,0),
            (2,1,2,0), (2,2,1,0), (1,2,2,0), (2,2,2,0), (1,0,1,1), (1,0,1,2), (2,0,1,1), (1,0,2,1),
            (2,0,2,1), (2,0,1,2), (1,0,2,2), (2,0,2,2), (0,1,1,1), (0,1,1,2), (0,2,1,1), (0,2,1,2),
            (0,1,2,1), (0,1,2,2), (0,2,2,1), (0,2,2,2), (1,1,0,1), (1,1,0,2), (1,2,0,1), (1,2,0,2),
            (2,1,0,1), (2,1,0,2), (2,2,0,1), (2,2,0,2), (1,1,1,1), (1,1,1,2), (1,2,1,1), (1,2,1,2),
            (2,1,1,1), (1,1,2,1), (2,1,2,1), (2,1,1,2), (2,2,1,1), (1,1,2,2), (1,2,2,1), (2,2,1,2),
            (1,2,2,2), (2,1,2,2), (2,2,2,1), (2,2,2,2), (0,1,0,1), (0,2,0,2), (1,0,1,0), (2,0,2,0),
        ]
        let double: [(UInt8, UInt8, UInt8, UInt8)] = [
            (0,3,0,3), (3,0,3,0), (0,3,1,0), (0,1,3,0), (0,3,3,0), (0,0,1,3), (0,0,3,1), (0,0,3,3),
            (1,3,0,0), (3,1,0,0), (3,3,0,0), (1,0,0,3), (3,0,0,1), (3,0,0,3), (1,3,1,0), (3,1,3,0),
            (3,3,3,0), (1,0,1,3), (3,0,3,1), (3,0,3,3), (0,3,1,3), (0,1,3,1), (0,3,3,3), (1,3,0,3),
            (3,1,0,1), (3,3,0,3), (1,3,1,3), (3,1,3,1), (3,3,3,3),
        ]
        let halves: [(UInt8, UInt8, UInt8, UInt8)] = [
            (0,0,0,1), (1,0,0,0), (0,1,0,0), (0,0,1,0), (0,0,0,2), (2,0,0,0), (0,2,0,0), (0,0,2,0),
            (0,2,0,1), (1,0,2,0), (0,1,0,2), (2,0,1,0),
        ]
        var t: [UInt32: Arms] = [:]
        for (i, a) in light.enumerated() { t[0x2500 + UInt32(i)] = Arms(u: a.0, r: a.1, d: a.2, l: a.3) }
        for (i, a) in double.enumerated() { t[0x2550 + UInt32(i)] = Arms(u: a.0, r: a.1, d: a.2, l: a.3) }
        for (i, a) in halves.enumerated() { t[0x2574 + UInt32(i)] = Arms(u: a.0, r: a.1, d: a.2, l: a.3) }
        return t
    }()

    static func handles(_ scalar: UInt32) -> Bool {
        (0x2500...0x259F).contains(scalar) || (0xE0B0...0xE0B3).contains(scalar)
    }

    static func draw(_ scalar: UInt32, in rect: CGRect, color: CGColor, lineWidth light: CGFloat,
                     scale: CGFloat, _ ctx: CGContext) -> Bool {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)

        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let heavy = snap(light * 2)
        let lw = max(snap(light), 1 / scale)
        let cx = snap(rect.midX), cy = snap(rect.midY)

        switch scalar {
        case 0x256D...0x2570:
            let r = min(rect.width, rect.height) / 2
            let path = CGMutablePath()
            switch scalar {
            case 0x256D:
                path.move(to: CGPoint(x: cx, y: rect.maxY))
                path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: rect.maxX, y: cy), radius: r)
                path.addLine(to: CGPoint(x: rect.maxX, y: cy))
            case 0x256E:
                path.move(to: CGPoint(x: cx, y: rect.maxY))
                path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: rect.minX, y: cy), radius: r)
                path.addLine(to: CGPoint(x: rect.minX, y: cy))
            case 0x256F:
                path.move(to: CGPoint(x: cx, y: rect.minY))
                path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: rect.minX, y: cy), radius: r)
                path.addLine(to: CGPoint(x: rect.minX, y: cy))
            default:
                path.move(to: CGPoint(x: cx, y: rect.minY))
                path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: rect.maxX, y: cy), radius: r)
                path.addLine(to: CGPoint(x: rect.maxX, y: cy))
            }
            ctx.setLineWidth(lw)
            ctx.addPath(path)
            ctx.strokePath()
            return true

        case 0x2571...0x2573:
            ctx.setLineWidth(lw)
            if scalar != 0x2572 {
                ctx.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY)])
            }
            if scalar != 0x2571 {
                ctx.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)])
            }
            return true

        case 0x2580...0x259F:
            drawBlock(scalar, rect, color, snap, ctx)
            return true

        case 0xE0B0...0xE0B3:
            let path = CGMutablePath()
            let right = scalar == 0xE0B0 || scalar == 0xE0B1
            if right {
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            } else {
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            }
            if scalar == 0xE0B0 || scalar == 0xE0B2 {
                path.closeSubpath()
                ctx.addPath(path)
                ctx.fillPath()
            } else {
                ctx.setLineWidth(lw)
                ctx.addPath(path)
                ctx.strokePath()
            }
            return true

        default:
            guard let arms = table[scalar] else { return false }
            func width(_ w: UInt8) -> CGFloat { w == 2 ? heavy : lw }
            let vReach = max(arms.l == 2 || arms.r == 2 ? heavy : lw, arms.l == 3 || arms.r == 3 ? lw * 3 : 0) / 2
            let hReach = max(arms.u == 2 || arms.d == 2 ? heavy : lw, arms.u == 3 || arms.d == 3 ? lw * 3 : 0) / 2

            func vertical(_ w: UInt8, from y0: CGFloat, to y1: CGFloat) {
                guard w > 0 else { return }
                let lo = min(y0, y1), hi = max(y0, y1)
                if w == 3 {
                    ctx.fill(CGRect(x: cx - lw * 1.5, y: lo, width: lw, height: hi - lo))
                    ctx.fill(CGRect(x: cx + lw * 0.5, y: lo, width: lw, height: hi - lo))
                } else {
                    let ww = width(w)
                    ctx.fill(CGRect(x: cx - ww / 2, y: lo, width: ww, height: hi - lo))
                }
            }
            func horizontal(_ w: UInt8, from x0: CGFloat, to x1: CGFloat) {
                guard w > 0 else { return }
                let lo = min(x0, x1), hi = max(x0, x1)
                if w == 3 {
                    ctx.fill(CGRect(x: lo, y: cy - lw * 1.5, width: hi - lo, height: lw))
                    ctx.fill(CGRect(x: lo, y: cy + lw * 0.5, width: hi - lo, height: lw))
                } else {
                    let ww = width(w)
                    ctx.fill(CGRect(x: lo, y: cy - ww / 2, width: hi - lo, height: ww))
                }
            }
            vertical(arms.u, from: rect.minY, to: cy + vReach)
            vertical(arms.d, from: cy - vReach, to: rect.maxY)
            horizontal(arms.l, from: rect.minX, to: cx + hReach)
            horizontal(arms.r, from: cx - hReach, to: rect.maxX)
            return true
        }
    }

    private static func drawBlock(_ s: UInt32, _ r: CGRect, _ color: CGColor, _ snap: (CGFloat) -> CGFloat, _ ctx: CGContext) {
        let w = r.width, h = r.height
        func fill(_ x: CGFloat, _ y: CGFloat, _ fw: CGFloat, _ fh: CGFloat) {
            let x0 = snap(r.minX + x), y0 = snap(r.minY + y)
            ctx.fill(CGRect(x: x0, y: y0, width: snap(r.minX + x + fw) - x0, height: snap(r.minY + y + fh) - y0))
        }
        switch s {
        case 0x2580: fill(0, 0, w, h / 2)
        case 0x2581...0x2588:
            let f = CGFloat(s - 0x2580) / 8
            fill(0, h * (1 - f), w, h * f)
        case 0x2589...0x258F:
            let f = CGFloat(0x2590 - s) / 8
            fill(0, 0, w * f, h)
        case 0x2590: fill(w / 2, 0, w / 2, h)
        case 0x2591, 0x2592, 0x2593:
            ctx.setAlpha(CGFloat(s - 0x2590) * 0.25)
            fill(0, 0, w, h)
        case 0x2594: fill(0, 0, w, h / 8)
        case 0x2595: fill(w * 7 / 8, 0, w / 8, h)
        default:
            let quads: [UInt32: (Bool, Bool, Bool, Bool)] = [
                0x2596: (false, false, true, false), 0x2597: (false, false, false, true),
                0x2598: (true, false, false, false), 0x2599: (true, false, true, true),
                0x259A: (true, false, false, true), 0x259B: (true, true, true, false),
                0x259C: (true, true, false, true), 0x259D: (false, true, false, false),
                0x259E: (false, true, true, false), 0x259F: (false, true, true, true),
            ]
            guard let q = quads[s] else { return }
            if q.0 { fill(0, 0, w / 2, h / 2) }
            if q.1 { fill(w / 2, 0, w / 2, h / 2) }
            if q.2 { fill(0, h / 2, w / 2, h / 2) }
            if q.3 { fill(w / 2, h / 2, w / 2, h / 2) }
        }
    }
}
