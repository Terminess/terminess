import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let size = CGFloat(args.count > 2 ? Double(args[2]) ?? 1024 : 1024)
let s = size / 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gc = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gc
let ctx = gc.cgContext
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s),
           cornerWidth: r * s, cornerHeight: r * s, transform: nil)
}

func gradient(_ path: CGPath, _ top: NSColor, _ bottom: NSColor) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    let box = path.boundingBox
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
    ctx.restoreGState()
}

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 28 * s,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(rr(100, 100, 824, 824, 185))
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

gradient(rr(100, 100, 824, 824, 185),
         NSColor(srgbRed: 0.86, green: 0.90, blue: 0.92, alpha: 1),
         NSColor(srgbRed: 0.50, green: 0.51, blue: 0.53, alpha: 1))
ctx.addPath(rr(114, 114, 796, 796, 172))
ctx.setFillColor(NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1).cgColor)
ctx.fillPath()
gradient(rr(150, 150, 724, 724, 140),
         NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1),
         NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1))

func sparkle(cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let cxs = cx * s, cys = cy * s, rs = r * s
    let k1: CGFloat = 0.15, k2: CGFloat = 0.36
    p.move(to: CGPoint(x: cxs, y: cys - rs))
    p.addCurve(to: CGPoint(x: cxs + rs, y: cys),
               control1: CGPoint(x: cxs + rs * k1, y: cys - rs * k2),
               control2: CGPoint(x: cxs + rs * k2, y: cys - rs * k1))
    p.addCurve(to: CGPoint(x: cxs, y: cys + rs),
               control1: CGPoint(x: cxs + rs * k2, y: cys + rs * k1),
               control2: CGPoint(x: cxs + rs * k1, y: cys + rs * k2))
    p.addCurve(to: CGPoint(x: cxs - rs, y: cys),
               control1: CGPoint(x: cxs - rs * k1, y: cys + rs * k2),
               control2: CGPoint(x: cxs - rs * k2, y: cys + rs * k1))
    p.addCurve(to: CGPoint(x: cxs, y: cys - rs),
               control1: CGPoint(x: cxs - rs * k2, y: cys - rs * k1),
               control2: CGPoint(x: cxs - rs * k1, y: cys - rs * k2))
    p.closeSubpath()
    return p
}

let white = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).cgColor
ctx.setFillColor(white)
ctx.addPath(sparkle(cx: 312, cy: 312, r: 122))
ctx.fillPath()
ctx.addPath(rr(448, 408, 136, 36, 4))
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
