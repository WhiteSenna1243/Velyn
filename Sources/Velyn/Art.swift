import AppKit

/// Loads album artwork and pulls two vivid colours out of it.
enum Art {
    static func load(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    static func palette(from image: NSImage) -> (RGB, RGB)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }

        var cands: [(h: CGFloat, s: CGFloat, score: CGFloat)] = []
        for i in 0..<(n * n) {
            let c = NSColor(srgbRed: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255,
                            blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            if b > 0.25 { cands.append((h, s, s * b)) }
        }
        cands.sort { $0.score > $1.score }
        guard let first = cands.first else { return nil }

        func dist(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let d = abs(a - b)
            return min(d, 1 - d)
        }
        let other = cands.first { dist($0.h, first.h) > 0.12 }
        let secondHue = other?.h ?? (first.h + 0.12).truncatingRemainder(dividingBy: 1)
        let secondSat = other?.s ?? first.s

        func vivid(_ h: CGFloat, _ s: CGFloat) -> RGB {
            RGB(h: Double(h), s: Double(min(1, max(s, 0.6))), v: 1)
        }
        return (vivid(first.h, first.s), vivid(secondHue, secondSat))
    }
}
