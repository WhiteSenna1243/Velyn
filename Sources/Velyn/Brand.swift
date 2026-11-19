import SwiftUI
import AppKit

/// Velyn's look: the colours and the logo (a ring of dotted rays, like a sound visualiser made of LEDs).
enum Brand {
    static let blue = RGB(r: 0.45, g: 0.40, b: 1.0)
    static let violet = RGB(r: 0.68, g: 0.42, b: 1.0)
    static let magenta = RGB(r: 0.98, g: 0.36, b: 0.86)
    static let red = RGB(r: 1.0, g: 0.34, b: 0.46)
    /// Switches, selections and links in the app's own controls.
    static let accent = Color(red: 0.62, green: 0.38, blue: 1.0)

    /// Window background: near-black in dark mode, near-white in light mode.
    static let background = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.035, alpha: 1) : NSColor(white: 0.965, alpha: 1)
    }

    /// Colour along a ray: blue at the centre, through violet and magenta, red at the tips.
    static func ray(_ t: Double) -> RGB {
        let t = max(0, min(1, t))
        if t < 0.22 { return blue.mixed(with: violet, t / 0.22) }
        if t < 0.5 { return violet.mixed(with: magenta, (t - 0.22) / 0.28) }
        return magenta.mixed(with: red, min(1, (t - 0.5) / 0.35))
    }

    /// Length of each ray, 0...1: a fixed, made-up "spectrum" (smooth swells plus a few spikes).
    static func rayLengths(_ n: Int) -> [Double] {
        var seed: UInt64 = 0x56454C59   // "VELY"
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        return (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi
            let swell = 0.62 + 0.12 * sin(3 * a + 1.1) + 0.08 * sin(7 * a + 0.3)
            let jitter = rnd()
            let spike = jitter > 0.92 ? 0.25 : 0
            return max(0.18, min(1, swell * (0.45 + 0.55 * jitter) + spike))
        }
    }
}

/// The logo, drawn live: rays of dots around an empty centre. `bloom` adds the LED glow.
struct AuraMark: View {
    var rays = 120
    var bloom = true

    var body: some View {
        Canvas { ctx, size in AuraMark.draw(&ctx, size: size, rays: rays, bloom: bloom) }
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, rays: Int, bloom: Bool) {
        let side = Double(min(size.width, size.height))
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r0 = side * 0.205, reach = side * 0.215
        let step = max(1.2, side * 0.0115)
        let lengths = Brand.rayLengths(rays)

        // Dots in rings of the same colour, so each ring is one fill.
        let rings = Int(reach / step) + 1
        var paths = Array(repeating: Path(), count: rings)
        for (i, len) in lengths.enumerated() {
            let a = Double(i) / Double(rays) * 2 * .pi - .pi / 2
            let (dx, dy) = (cos(a), sin(a))
            let count = Int(len * reach / step) + 1
            for k in 0..<min(count, rings) {
                let r = r0 + Double(k) * step
                let dot = step * (0.26 + 0.12 * Double(k) / Double(rings))
                paths[k].addEllipse(in: CGRect(x: c.x + dx * r - dot, y: c.y + dy * r - dot, width: dot * 2, height: dot * 2))
            }
        }
        func dots(_ g: inout GraphicsContext) {
            for (k, p) in paths.enumerated() {
                let t = Double(k) / Double(max(1, rings - 1))
                g.fill(p, with: .color(Brand.ray(t).color.opacity(0.75 + 0.25 * min(1, t * 2.5))))
            }
        }
        if bloom {
            // The LED glow: a soft, brighter copy behind the dots.
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: step * 1.4))
                g.blendMode = .plusLighter
                dots(&g)
            }
        }
        dots(&ctx)
    }
}

/// The app icon: the logo glowing on a dark rounded square (rendered to AppIcon.png by `--make-icon`).
struct AppIconView: View {
    /// Phones: the background fills the whole square (iOS and Android round it themselves).
    var fullBleed = false

    var body: some View {
        ZStack {
            if fullBleed {
                Rectangle().fill(RadialGradient(colors: [Color(red: 0.22, green: 0.15, blue: 0.38), Color(red: 0.10, green: 0.07, blue: 0.20)],
                                                center: .center, startRadius: 40, endRadius: 720))
            } else {
                frame
            }
            // Faint light from the centre, like the glow of the ring.
            Circle()
                .fill(RadialGradient(colors: [Brand.violet.color.opacity(0.38), .clear], center: .center,
                                     startRadius: 60, endRadius: 330))
                .frame(width: 700, height: 700)
            AuraMark(rays: 144, bloom: true)
                .frame(width: fullBleed ? 1000 : 900, height: fullBleed ? 1000 : 900)
        }
        .frame(width: 1024, height: 1024)
    }

    private var frame: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(RadialGradient(colors: [Color(red: 0.22, green: 0.15, blue: 0.38), Color(red: 0.10, green: 0.07, blue: 0.20)],
                                     center: .center, startRadius: 40, endRadius: 520))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 2))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        }
    }
}

/// The phone remote's launch screen: the logo glowing on the page's dark background.
struct LaunchScreenView: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let side = min(width, height) * 0.5
        ZStack {
            Color(red: 0.043, green: 0.027, blue: 0.086)
            RadialGradient(colors: [Brand.violet.color.opacity(0.25), .clear], center: .center,
                           startRadius: 0, endRadius: side * 1.1)
            AuraMark(rays: 120, bloom: true).frame(width: side, height: side)
        }
        .frame(width: width, height: height)
    }
}

extension Brand {
    /// Menu bar icon: the same ring of rays as short lines (a template image, so macOS tints it).
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let n = 24
            let lengths = rayLengths(n)
            NSColor.black.setStroke()
            for (i, len) in lengths.enumerated() {
                let a = Double(i) / Double(n) * 2 * .pi
                let r1 = 3.6, r2 = 3.6 + 1.6 + 3.4 * len
                let p = NSBezierPath()
                p.move(to: NSPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                p.line(to: NSPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
                p.lineWidth = 1.1
                p.lineCapStyle = .round
                p.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = AppInfo.name
        return img
    }
}
