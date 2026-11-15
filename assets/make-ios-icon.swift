import AppKit
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(starting: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.176, alpha: 1),
           ending: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
let s = 1.15, o = 90.0
func p(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: (x - 150) * s + o, y: size - ((y - 150) * s + o)) }
NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).setFill()
let c = (x: 288.0, y: 300.0), r = 145.0, k = 0.30 * r
let star = NSBezierPath()
star.move(to: p(c.x, c.y - r))
star.curve(to: p(c.x + r, c.y), controlPoint1: p(c.x + k, c.y - k), controlPoint2: p(c.x + k, c.y - k))
star.curve(to: p(c.x, c.y + r), controlPoint1: p(c.x + k, c.y + k), controlPoint2: p(c.x + k, c.y + k))
star.curve(to: p(c.x - r, c.y), controlPoint1: p(c.x - k, c.y + k), controlPoint2: p(c.x - k, c.y + k))
star.curve(to: p(c.x, c.y - r), controlPoint1: p(c.x - k, c.y - k), controlPoint2: p(c.x - k, c.y - k))
star.close()
star.fill()
let tl = p(448, 414), br = p(584, 443)
NSBezierPath(roundedRect: NSRect(x: tl.x, y: br.y, width: br.x - tl.x, height: tl.y - br.y), xRadius: 6, yRadius: 6).fill()
NSGraphicsContext.restoreGraphicsState()
let cg = rep.cgImage!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
