import SwiftUI
import AppKit

// MARK: - Glow layer

/// The edge glow. Performance design (this is why two colours no longer lag):
///  - the soft ring shape is drawn ONCE into a small bitmap (`GlowMaskCache`),
///    only when the window size / Thickness / Glow change;
///  - every frame only a rotating gradient is drawn through that mask.
/// There are no live blurs, which were what made 2 colours stutter.
struct GlowLayer: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings

    /// Notch area in view points (origin top-left). The glow bends around it when Notch compatibility is on.
    var notch: CGRect? = nil

    @State private var driver = GlowDriver()
    @State private var masks = GlowMaskCache()
    @ObservedObject private var power = Power.shared
    @Environment(\.onLockScreen) private var onLockScreen

    var body: some View {
        let p = settings.prefs
        let fps = power.glowFPS(playing: engine.isPlaying, mode: p.glowMode, lockScreen: onLockScreen)
        if p.glowEnabled && p.glowStyle == .liquid && LiquidRenderer.shared.available {
            LiquidGlow(engine: engine, settings: settings, notch: notch, fps: fps)
        } else if p.glowEnabled {
            let cols = engine.glowColors(p)
            GeometryReader { geo in
                let mask = masks.image(size: geo.size, thickness: p.thickness, glow: p.glow,
                                       notch: p.notchCompat ? notch : nil)
                TimelineView(Power.schedule(min(45, fps))) { tl in
                    let f = driver.step(time: tl.date.timeIntervalSinceReferenceDate,
                                        prefs: p,
                                        playing: engine.isPlaying,
                                        audio: engine.audio)
                    ring(p, cols.0, cols.1, f, mask)
                }
            }
        } else {
            Color.clear
        }
    }

    private func gradient(_ a: RGB, _ b: RGB, two: Bool, share: Double) -> Gradient {
        if !two { return Gradient(colors: [a.color, a.color]) }
        let w = min(max(share, 0.2), 0.8)
        let k = 0.06
        return Gradient(stops: [
            .init(color: a.color, location: 0),
            .init(color: a.color, location: w - k),
            .init(color: b.color, location: w + k),
            .init(color: b.color, location: 1 - k),
            .init(color: a.color, location: 1)
        ])
    }

    private func ring(_ p: Prefs, _ a: RGB, _ b: RGB, _ f: GlowDriver.Frame, _ mask: CGImage?) -> some View {
        let g = AngularGradient(gradient: gradient(a, b, two: p.gradientColors == 2, share: p.primaryShare),
                                center: .center, angle: .degrees(f.rotation))
        return Rectangle()
            .fill(g)
            .mask(
                Group {
                    if let mask {
                        Image(decorative: mask, scale: 1)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Color.clear
                    }
                }
            )
            .opacity(f.intensity * (0.15 + 0.85 * p.brightness))
    }
}

// MARK: - Per-frame animation

/// Turns audio (or a fallback rhythm) into the glow's brightness and rotation.
/// Modelled on how Govee-style music sync behaves:
///  - brightness snaps up with the loudness and bass, then eases off;
///  - every detected beat kicks the colours around the edge by a step;
///  - between beats the colours drift slowly, faster when the music is louder.
final class GlowDriver {
    struct Frame {
        var rotation: Double   // degrees
        var intensity: Double  // 0...1
        var energy = 0.0       // music push 0...1 (liquid bulges swell with it)
        var phase = 0.0        // liquid flow position; runs faster when the music is louder
    }

    private var lastTime = 0.0
    private var rotation = 0.0
    private var rotationTarget = 0.0
    private var intensity = 0.3
    private var lastBeat = -1
    private var energy = 0.0
    private var phase = 0.0

    func step(time: Double, prefs p: Prefs, playing: Bool, audio: AudioReactor) -> Frame {
        let dt = lastTime == 0 ? 1.0 / 60 : min(max(time - lastTime, 0), 0.1)
        lastTime = time
        let calm = Power.shared.reduceMotion

        var target = 0.9
        var spin = 0.0
        var push = 0.15          // target energy
        var flow = 0.7           // liquid speed

        switch p.glowMode {
        case .musicSync:
            if !playing {
                target = 0.20 + 0.06 * sin(time * 0.8)
                spin = 5
            } else if p.audioReactive, audio.isRunning {
                let s = audio.snapshot()
                let gain = Float(p.syncSensitivity)
                if lastBeat < 0 { lastBeat = s.beatCount }
                if s.beatCount != lastBeat {
                    lastBeat = s.beatCount
                    if !calm { rotationTarget += 22 + 34 * Double(s.beatPulse) }
                }
                if s.hasSignal {
                    let loud = Double(min(1, s.level * gain))
                    let low = Double(min(1, s.bass * gain))
                    let hit = Double(min(1, s.beatPulse * gain))
                    switch p.syncStyle {
                    case .energy:
                        target = 0.12 + 0.46 * loud + 0.30 * low + 0.30 * hit
                    case .pulse:
                        target = 0.08 + 0.12 * loud + 0.85 * pow(hit, 1.2)
                    }
                    spin = 6 + 30 * loud
                    push = min(1, 0.55 * low + 0.65 * hit)
                    flow = 0.5 + 2.4 * loud + 1.5 * hit
                } else {
                    // Silent (or access not granted yet): breathe gently.
                    target = 0.26 + 0.10 * sin(time * 1.4)
                    spin = 6
                }
            } else {
                // No audio access: a steady breathing rhythm.
                target = 0.30 + 0.35 * (0.5 + 0.5 * sin(time * 1.4))
                spin = 14
            }
        case .idle:
            target = 0.55 + 0.40 * sin(time * 0.9)
            spin = 10
            flow = 0.35
        case .standard:
            spin = 45
            flow = 0.9
        case .none:
            flow = 0
            push = 0.1
        }

        if calm {
            // Reduce Motion: no jumps on beats, slower drift and ripples, softer flashes.
            spin *= 0.3
            flow *= 0.4
            push *= 0.5
            target = 0.45 + (target - 0.45) * 0.5
        }

        // Quick to brighten, slower to dim.
        let k = target > intensity ? min(1, dt * (calm ? 5 : 30)) : min(1, dt * (calm ? 3 : 7))
        intensity += (target - intensity) * k

        let ek = push > energy ? min(1, dt * 18) : min(1, dt * 4)
        energy += (push - energy) * ek
        phase += flow * dt
        if phase > 10_000 { phase -= 10_000 }

        rotationTarget += spin * dt
        rotation += (rotationTarget - rotation) * min(1, dt * 9)
        if rotationTarget > 36000 { rotationTarget -= 36000; rotation -= 36000 }

        return Frame(rotation: rotation, intensity: max(0, min(1, intensity)), energy: energy, phase: phase)
    }
}

// MARK: - Cached ring mask

/// Renders the soft "inner glow along the edges" shape into a small bitmap.
/// Alpha = brightness. Rebuilt only when its inputs change.
final class GlowMaskCache {
    private var key = ""
    private var cached: CGImage?

    func image(size: CGSize, thickness: Double, glow: Double, notch: CGRect? = nil) -> CGImage? {
        guard size.width > 8, size.height > 8 else { return nil }
        let qw = (size.width / 8).rounded() * 8
        let qh = (size.height / 8).rounded() * 8
        let n = notch ?? .zero
        let k = String(format: "%.0fx%.0f-%.3f-%.3f-%.0f,%.0f,%.0f,%.0f", qw, qh, thickness, glow,
                       n.minX, n.minY, n.width, n.height)
        if k == key, let c = cached { return c }
        let img = Self.render(size: CGSize(width: qw, height: qh), thickness: thickness, glow: glow, notch: notch)
        key = k
        cached = img
        return img
    }

    private static func render(size: CGSize, thickness: Double, glow: Double, notch: CGRect?) -> CGImage? {
        let maxSide: CGFloat = 960
        let scale = Double(min(0.5, maxSide / max(size.width, size.height)))   // pixels per point
        let w = max(8, Int((Double(size.width) * scale).rounded()))
        let h = max(8, Int((Double(size.height) * scale).rounded()))

        // Brightness by depth (points in from the edge): a hot rim, a body, a long soft wash.
        // A thin hot rim with a soft halo. Thickness = rim width, Glow = halo reach.
        let main = 6 + thickness * 110
        let wash = main * (1.0 + glow * 1.6)
        let washGain = 0.12 + 0.38 * glow
        let maxDepth = min(w, h) / 2 + 2
        var lut = [UInt8](repeating: 0, count: maxDepth + 1)
        for i in 0...maxDepth {
            let d = Double(i) / scale
            let core = exp(-d / (main * 0.10))
            let mid = exp(-d / main)
            let far = exp(-d / wash)
            let a = min(1, 0.50 * core + 0.55 * mid + washGain * far)
            lut[i] = UInt8(max(0, min(255, a * 255)))
        }

        // Distance to the edge of a rounded rectangle, so corners glow smoothly.
        let hw = Double(w) / 2, hh = Double(h) / 2
        let r = min(28 * scale, min(hw, hh) * 0.5)
        // Notch as a rounded box (in pixels) hanging from the top edge; the glow traces its outline.
        let nb: (cx: Double, cy: Double, hx: Double, hy: Double, r: Double)? = notch.map { n in
            let top = -20.0, bottom = Double(n.maxY)
            return (Double(n.midX) * scale, (top + bottom) / 2 * scale,
                    Double(n.width) / 2 * scale, (bottom - top) / 2 * scale, 9 * scale)
        }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let dy = abs(Double(y) + 0.5 - hh) - (hh - r)
            for x in 0..<w {
                let dx = abs(Double(x) + 0.5 - hw) - (hw - r)
                let ox = max(dx, 0), oy = max(dy, 0)
                let sd = (ox * ox + oy * oy).squareRoot() + min(max(dx, dy), 0) - r
                var depth = max(0, -sd)
                if let nb {
                    let qx = abs(Double(x) + 0.5 - nb.cx) - (nb.hx - nb.r)
                    let qy = abs(Double(y) + 0.5 - nb.cy) - (nb.hy - nb.r)
                    let out = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
                        + min(max(qx, qy), 0) - nb.r
                    depth = out < 0 ? -1 : min(depth, out)    // nothing inside the notch itself
                }
                let a: UInt8 = depth < 0 ? 0 : lut[min(maxDepth, Int(depth))]
                let o = (y * w + x) * 4
                px[o] = a; px[o + 1] = a; px[o + 2] = a; px[o + 3] = a   // premultiplied
            }
        }

        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Debug meter (tuning aid)

/// Shows live audio bands and beats. Turn on with:
///   defaults write com.velyn.app velyn.debug.audio -bool true
/// and off with `-bool false`. Helps tune how the glow reacts.
struct AudioDebugHUD: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        if UserDefaults.standard.bool(forKey: "velyn.debug.audio") {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                let s = engine.audio.snapshot()
                VStack(alignment: .leading, spacing: 3) {
                    bar("level", s.level)
                    bar("bass", s.bass)
                    bar("lowmid", s.lowMid)
                    bar("mid", s.mid)
                    bar("treble", s.treble)
                    bar("beat", s.beatPulse)
                    Text("beats \(s.beatCount)  signal \(s.hasSignal ? "yes" : "no")  tap \(engine.audio.isRunning ? "on" : "off")")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.6))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
            }
        }
    }

    private func bar(_ name: String, _ v: Float) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 9, design: .monospaced)).frame(width: 44, alignment: .leading)
                .foregroundColor(Color.white.opacity(0.6))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 100, height: 5)
                Rectangle().fill(Color.green).frame(width: 100 * CGFloat(max(0, min(1, v))), height: 5)
            }
        }
    }
}
