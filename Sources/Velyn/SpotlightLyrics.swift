import SwiftUI
import AppKit
import CoreImage

/// Spotlight style: big bold lines on the left. The sung words fill in white with a soft
/// edge and lift a little; the other lines are dim and blurred more the further away they are.
/// The list glides up on springs, lines further down following a moment later (a gentle wave).
/// Long gaps show three dots that fill up. Behind it: the album art, blurred and slowly turning.
struct SpotlightStage: View {
    let input: LyricInput
    let artwork: NSImage?
    /// Lock screen: no art behind (the wallpaper shows) and the column is centred under the clock.
    var lockScreen = false
    /// Dev aid (demo video): keep the springs going across separately rendered frames.
    var external: SpotlightSim? = nil
    @State private var sim = SpotlightSim()

    var body: some View {
        let sim = external ?? self.sim
        ZStack {
            if !lockScreen, let artwork {
                SpotlightBackdrop(image: artwork, clock: input.clock, spin: min(input.motion, 1))
            }
            Canvas { ctx, size in sim.draw(&ctx, size: size, input: input, centered: lockScreen) }
        }
    }
}

/// Layout and motion state for `SpotlightStage` (kept between frames).
final class SpotlightSim {
    private struct Item {
        let line: LyricLine           // no words = the three dots
        var rows: [String] = []
        var wordX: [Double] = []
        var wordRow: [Int] = []
        var wordW: [Double] = []
        var height = 0.0
        var isDots: Bool { line.words.isEmpty }
    }

    private var key = ""
    private var items: [Item] = []
    private var fs = 40.0, rowH = 48.0, gap = 38.0, margin = 40.0

    private var pos: [Double] = []      // line tops on screen (springs)
    private var vel: [Double] = []
    private var active: [Double] = []   // 0...1: how "current" each line looks
    private var lastClock = 0.0
    private var lastFocus = -1
    private var fresh = true

    static let dim = 0.30               // other lines
    static let unsung = 0.55            // words of the current line not sung yet

    // MARK: Layout

    /// The lines to show: lyric lines, plus dots for the intro and long gaps.
    /// Short empty lines in the LRC are dropped so the last sung line stays lit.
    static func items(_ lines: [LyricLine]) -> [LyricLine] {
        var out: [LyricLine] = []
        if let first = lines.first, first.start > 3 {
            out.append(LyricLine(start: 0, end: first.start, words: []))
        }
        for (i, l) in lines.enumerated() {
            let hasNext = i + 1 < lines.count
            let next = hasNext ? lines[i + 1].start : l.end
            if l.words.isEmpty {
                if hasNext, next - l.start >= 3 { out.append(LyricLine(start: l.start, end: next, words: [])) }
                continue
            }
            out.append(l)
            // A long instrumental break with no marker in the lyrics.
            if hasNext, let last = l.words.last, next - last.end > 7 {
                out.append(LyricLine(start: last.end + 1.5, end: next, words: []))
            }
        }
        return out
    }

    private func layout(_ size: CGSize, _ input: LyricInput, centered: Bool) {
        let W = Double(size.width), H = Double(size.height)
        let size = min(max(min(W * 0.043, H * 0.075), 22), 84) * input.size
        let k = "\(input.lines.count)|\(input.lines.first?.start ?? 0)|\(input.lines.last?.text ?? "")|"
            + "\(Int(W))|\(Int(size * 10))|\(input.font.rawValue)|\(centered)"
        guard k != key else { return }
        key = k
        fs = size
        rowH = fs * 1.2
        gap = fs * 0.95
        margin = max(24, W * 0.075)
        var maxW = min(W - margin * 1.6, fs * 14)
        if centered {
            maxW = min(W - 48, fs * 14)
            margin = (W - maxW) / 2
        }

        let font = LyricFonts.ns(input.font, size: fs, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func width(_ s: String) -> Double { Double((s as NSString).size(withAttributes: attrs).width) }
        let space = width(" ")

        items = Self.items(input.lines).map { line in
            var it = Item(line: line)
            guard !line.words.isEmpty else {
                it.height = fs * 0.9
                return it
            }
            var x = 0.0, row = 0
            var rowWords: [[String]] = [[]]
            for w in line.words {
                let ww = width(w.text)
                if x > 0, x + ww > maxW {
                    row += 1
                    x = 0
                    rowWords.append([])
                }
                it.wordX.append(x)
                it.wordRow.append(row)
                it.wordW.append(ww)
                rowWords[row].append(w.text)
                x += ww + space
            }
            it.rows = rowWords.map { $0.joined(separator: " ") }
            it.height = Double(it.rows.count) * rowH
            return it
        }
        pos = Array(repeating: 0, count: items.count)
        vel = pos
        active = pos
        fresh = true
    }

    // MARK: Frame

    func draw(_ ctx: inout GraphicsContext, size: CGSize, input: LyricInput, centered: Bool = false) {
        layout(size, input, centered: centered)
        guard !items.isEmpty else { return }
        let H = Double(size.height)
        let t = input.t
        let dt = fresh ? 0 : min(max(input.clock - lastClock, 0), 0.1)
        lastClock = input.clock

        var cur = -1
        for (i, it) in items.enumerated() {
            if it.line.start <= t { cur = i } else { break }
        }
        let focus = max(cur, 0)
        let jump = fresh || abs(focus - lastFocus) > 6      // a seek: no long glide
        lastFocus = focus

        for i in items.indices {
            let want = i == cur ? 1.0 : 0.0
            if jump { active[i] = want; continue }
            let rate = want > active[i] ? 9.0 : 5.0
            active[i] += (want - active[i]) * (1 - exp(-dt * rate))
        }

        // Dots only take room while they show.
        var tops = Array(repeating: 0.0, count: items.count)
        var y = 0.0
        for i in items.indices {
            tops[i] = y
            y += (items[i].height + gap) * (items[i].isDots ? active[i] : 1)
        }
        let anchor = H * 0.30
        let scroll = tops[focus]
        for i in items.indices {
            let target = anchor + tops[i] - scroll
            if jump { pos[i] = target; vel[i] = 0; continue }
            // Softer springs further down: those lines arrive a little later.
            let k = 170 / (1 + 0.22 * Double(max(0, i - focus)))
            let damping = 2 * 0.9 * k.squareRoot()
            var left = dt
            while left > 0 {
                let h = min(left, 1.0 / 120)
                vel[i] += (k * (target - pos[i]) - damping * vel[i]) * h
                pos[i] += vel[i] * h
                left -= h
            }
        }
        fresh = false

        let font = LyricFonts.font(input.font, size: fs, weight: .bold)
        for i in items.indices {
            let it = items[i], top = pos[i]
            guard top + it.height > -fs * 2, top < H + fs else { continue }
            // Fade out towards the top and bottom edges.
            let edge = LyricTiming.smooth((top + it.height) / (H * 0.16)) * LyricTiming.smooth((H - top) / (H * 0.22))
            guard edge > 0.01 else { continue }
            if it.isDots {
                drawDots(&ctx, it, top: top, a: active[i], edge: edge, input: input)
            } else {
                drawLine(&ctx, it, top: top, a: active[i], distance: Double(abs(i - focus)),
                         edge: edge, font: font, t: t)
            }
        }
    }

    private func drawLine(_ ctx: inout GraphicsContext, _ it: Item, top: Double, a: Double, distance: Double,
                          edge: Double, font: Font, t: Double) {
        let blur = (1 - a) * fs * min(0.07, 0.022 + 0.011 * distance)
        let fs = self.fs, rowH = self.rowH, margin = self.margin
        ctx.drawLayer { l in
            l.opacity = edge
            if blur > 0.3 { l.addFilter(.blur(radius: blur)) }
            if a < 0.02 {
                for (r, text) in it.rows.enumerated() {
                    l.draw(Text(text).font(font).foregroundColor(.white.opacity(Self.dim)),
                           at: CGPoint(x: margin, y: top + Double(r) * rowH), anchor: .topLeading)
                }
                return
            }
            let base = Self.dim + (Self.unsung - Self.dim) * a
            for (j, w) in it.line.words.enumerated() {
                let p = LyricTiming.clamp((t - w.start) / max(0.12, w.end - w.start))
                let x = margin + it.wordX[j]
                let y = top + Double(it.wordRow[j]) * rowH - fs * 0.04 * LyricTiming.smooth(p) * a
                let at = CGPoint(x: x, y: y)
                l.draw(Text(w.text).font(font).foregroundColor(.white.opacity(base)), at: at, anchor: .topLeading)
                guard p > 0 else { continue }
                let bright = Text(w.text).font(font).foregroundColor(.white)
                if p >= 1 {
                    l.drawLayer { b in
                        b.opacity = a
                        b.draw(bright, at: at, anchor: .topLeading)
                    }
                    continue
                }
                // Reveal the white copy left to right with a soft edge.
                let ww = it.wordW[j], soft = fs * 0.6
                let e = x - soft / 2 + p * (ww + soft)
                l.drawLayer { b in
                    b.opacity = a
                    b.clipToLayer { m in
                        let box = CGRect(x: x - fs * 0.3, y: y - fs * 0.3, width: ww + fs * 0.6, height: rowH + fs * 0.6)
                        m.fill(Path(box), with: .linearGradient(Gradient(colors: [.white, .clear]),
                                                                startPoint: CGPoint(x: e - soft / 2, y: y),
                                                                endPoint: CGPoint(x: e + soft / 2, y: y)))
                    }
                    b.draw(bright, at: at, anchor: .topLeading)
                }
            }
        }
    }

    /// Three dots that fill one after another through the gap, breathing gently.
    private func drawDots(_ ctx: inout GraphicsContext, _ it: Item, top: Double, a: Double, edge: Double,
                          input: LyricInput) {
        guard a > 0.01 else { return }
        let t = input.t
        let start = it.line.start, end = it.line.end
        let prog = LyricTiming.clamp((t - start) / max(0.5, end - start - 0.4))
        let out = LyricTiming.smooth((end - t) / 0.45)                 // shrink away as the words return
        let breathe = 1 + 0.07 * sin(input.clock * 2.4) * min(1, input.motion * 2)
        let r = fs * 0.12 * breathe * (0.55 + 0.45 * out) * (0.6 + 0.4 * a)
        let cy = top + it.height * 0.5
        for k in 0..<3 {
            let fill = LyricTiming.clamp(prog * 3 - Double(k))
            let cx = margin + fs * 0.12 + Double(k) * fs * 0.42
            let dot = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(.white.opacity((0.3 + 0.7 * fill) * a * out * edge)))
        }
    }
}

/// The album art, heavily blurred and darkened, turning slowly (two copies in opposite directions).
struct SpotlightBackdrop: View {
    let image: NSImage
    let clock: Double
    let spin: Double          // 0 = still

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let side = max(w, h) * 1.5
            let turn = (clock * 3 * spin).truncatingRemainder(dividingBy: 360)
            ZStack {
                Color.black
                if let cg = Self.blurred(image) {
                    blob(cg, side, turn).position(x: w * 0.62, y: h * 0.56)
                    blob(cg, side * 0.8, 180 - (turn * 1.4).truncatingRemainder(dividingBy: 360))
                        .position(x: w * 0.28, y: h * 0.32)
                        .opacity(0.6)
                }
                // Dark, and darkest on the left where the words are.
                LinearGradient(colors: [.black.opacity(0.74), .black.opacity(0.5)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    /// One turning copy, faded out to round soft edges (no square corners showing).
    private func blob(_ cg: CGImage, _ side: Double, _ degrees: Double) -> some View {
        Image(decorative: cg, scale: 1)
            .resizable()
            .interpolation(.medium)
            .frame(width: side, height: side)
            .rotationEffect(.degrees(degrees))
            .mask(RadialGradient(colors: [.black, .black, .clear], center: .center,
                                 startRadius: 0, endRadius: side * 0.5))
    }

    private static var cache: (NSImage, CGImage)?
    private static let context = CIContext()

    /// A small, very blurred, more colourful copy of the art (made once per cover).
    static func blurred(_ img: NSImage) -> CGImage? {
        if let c = cache, c.0 === img { return c.1 }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        let s = 96 / max(ci.extent.width, ci.extent.height, 1)
        let small = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let out = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 9)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.5])
            .cropped(to: small.extent)
        guard let res = context.createCGImage(out, from: small.extent) else { return nil }
        cache = (img, res)
        return res
    }
}
