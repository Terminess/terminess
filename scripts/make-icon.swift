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

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

let shape = CGPath(roundedRect: CGRect(x: tile.minX * s, y: tile.minY * s, width: tile.width * s, height: tile.height * s),
                   cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 24 * s,
              color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                   colors: [NSColor(srgbRed: 0.165, green: 0.165, blue: 0.176, alpha: 1).cgColor,
                            NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1).cgColor] as CFArray,
                   locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: tile.minY * s), end: CGPoint(x: 0, y: tile.maxY * s), options: [])
ctx.restoreGState()

let fit = tile.width / 1024
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: (tile.minX + ((x - 150) * 1.15 + 90) * fit) * s, y: (tile.minY + ((y - 150) * 1.15 + 90) * fit) * s)
}
ctx.setFillColor(NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).cgColor)
let c = (x: 288.0 as CGFloat, y: 300.0 as CGFloat), r: CGFloat = 145, k = 0.30 * r
let star = CGMutablePath()
star.move(to: p(c.x, c.y - r))
star.addCurve(to: p(c.x + r, c.y), control1: p(c.x + k, c.y - k), control2: p(c.x + k, c.y - k))
star.addCurve(to: p(c.x, c.y + r), control1: p(c.x + k, c.y + k), control2: p(c.x + k, c.y + k))
star.addCurve(to: p(c.x - r, c.y), control1: p(c.x - k, c.y + k), control2: p(c.x - k, c.y + k))
star.addCurve(to: p(c.x, c.y - r), control1: p(c.x - k, c.y - k), control2: p(c.x - k, c.y - k))
star.closeSubpath()
ctx.addPath(star)
ctx.fillPath()
let tl = p(448, 414), br = p(584, 443)
let radius = 6 * fit * s
ctx.addPath(CGPath(roundedRect: CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y),
                   cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
