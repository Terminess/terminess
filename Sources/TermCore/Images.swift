import Foundation
import ImageIO

public struct ImagePlacement: Identifiable, Sendable {
    public let id: Int
    public let data: Data
    public let line: Int
    public let column: Int
    public let widthCells: Int
    public let heightCells: Int
    public let onAlternate: Bool
}

extension Terminal {
    public var images: [ImagePlacement] { imagePlacements }

    func inlineImage(_ payload: String) {
        guard payload.hasPrefix("File="), let colon = payload.firstIndex(of: ":") else { return }
        var args: [String: String] = [:]
        for pair in payload[payload.index(payload.startIndex, offsetBy: 5)..<colon].split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { args[String(kv[0])] = String(kv[1]) }
        }
        guard args["inline"] == "1",
              let data = Data(base64Encoded: String(payload[payload.index(after: colon)...]), options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int,
              pw > 0, ph > 0 else { return }

        let cw = max(1, cellPixelWidth), ch = max(1, cellPixelHeight)
        func cells(_ spec: String?, total: Int, pixel: Int, cellPx: Int) -> Int? {
            guard let spec, spec != "auto" else { return nil }
            if spec.hasSuffix("px"), let v = Int(spec.dropLast(2)) { return max(1, (v + cellPx - 1) / cellPx) }
            if spec.hasSuffix("%"), let v = Int(spec.dropLast()) { return max(1, total * v / 100) }
            return Int(spec).map { max(1, $0) }
        }
        let preserve = args["preserveAspectRatio"] != "0"
        let natW = max(1, (pw + cw - 1) / cw), natH = max(1, (ph + ch - 1) / ch)
        var w = cells(args["width"], total: columns, pixel: pw, cellPx: cw)
        var h = cells(args["height"], total: rows, pixel: ph, cellPx: ch)
        switch (w, h) {
        case (nil, nil): w = natW; h = natH
        case (let ww?, nil): h = preserve ? max(1, ww * cw * ph / pw / ch) : natH
        case (nil, let hh?): w = preserve ? max(1, hh * ch * pw / ph / cw) : natW
        default: break
        }
        var width = w ?? natW, height = h ?? natH
        let room = columns - cursor.x
        if width > room {
            height = max(1, height * room / width)
            width = room
        }

        imageCounter += 1
        let placement = ImagePlacement(id: imageCounter, data: data, line: screen.scrolledOff + cursor.y,
                                       column: cursor.x, widthCells: width, heightCells: height, onAlternate: isAlternate)
        imagePlacements.append(placement)
        imageBytes += data.count
        while imageBytes > 64 * 1024 * 1024, let first = imagePlacements.first {
            imageBytes -= first.data.count
            imagePlacements.removeFirst()
        }
        let x = cursor.x
        for _ in 0..<height { index() }
        cursor.x = x
        touchAll()
    }

    func pruneImages(clearingVisible: Bool = false, all: Bool = false) {
        guard !imagePlacements.isEmpty else { return }
        let first = firstAbsoluteLine
        let visibleTop = screen.scrolledOff
        imagePlacements.removeAll { img in
            if all { return true }
            if img.onAlternate != isAlternate { return false }
            if img.line + img.heightCells <= first { return true }
            if clearingVisible && img.line + img.heightCells > visibleTop { return true }
            return false
        }
        imageBytes = imagePlacements.reduce(0) { $0 + $1.data.count }
    }
}
