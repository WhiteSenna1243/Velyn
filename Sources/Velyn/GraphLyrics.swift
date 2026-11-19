import SwiftUI
import AppKit

// Constellation, Branches and Web: each word of the line becomes a node, nodes are
// joined by lines that draw themselves as the words are sung. One Canvas, no per-word views.

enum GraphKind { case constellation, branches, web }

struct GraphNode {
    var pos: CGPoint
    var text: String
    var start: Double
    var end: Double
    var phase: Double
    var labelAbove: Bool      // constellation / branches
    var labelRight: Bool      // web
    var twigEnd: CGPoint?     // branches: small side branch
    var twigCtrl: CGPoint?
}

enum GraphEngine {
    typealias RNG = KineticEngine.SplitMix

    static func layout(kind: GraphKind, line: LyricLine, index: Int, size: CGSize) -> [GraphNode] {
        let words = LyricTiming.words(line)
        var rng = RNG(state: UInt64(truncatingIfNeeded: index) &* 104729 &+ 77 &+ UInt64(max(0, line.start) * 1000))
        switch kind {
        case .constellation: return constellation(words, &rng, size)
        case .branches: return branches(words, &rng, size, index: index)
        case .web: return web(words, &rng, size)
        }
    }

    private static func node(_ w: LyricWord, _ p: CGPoint, _ rng: inout RNG) -> GraphNode {
        GraphNode(pos: p, text: w.text, start: w.start, end: w.end,
                  phase: Double.random(in: 0..<(2 * Double.pi), using: &rng),
                  labelAbove: false, labelRight: true, twigEnd: nil, twigCtrl: nil)
    }

    // MARK: Constellation. A random walk across the sky.

    private static func constellation(_ words: [LyricWord], _ rng: inout RNG, _ size: CGSize) -> [GraphNode] {
        let W = Double(size.width), H = Double(size.height)
        let minX = W * 0.10, maxX = W * 0.90, minY = H * 0.20, maxY = H * 0.78
        let n = words.count
        let step = max(80.0, min(230.0, W * 0.80 / Double(max(n, 3)) * 1.4))

        let startsLeft = Bool.random(using: &rng)
        var heading = startsLeft ? Double.random(in: -0.5...0.5, using: &rng)
                                 : Double.pi + Double.random(in: -0.5...0.5, using: &rng)
        let fx = startsLeft ? Double.random(in: 0.0...0.2, using: &rng) : Double.random(in: 0.8...1.0, using: &rng)
        let fy = Double.random(in: 0.25...0.75, using: &rng)
        var px = minX + (maxX - minX) * fx
        var py = minY + (maxY - minY) * fy
        var placed: [(Double, Double)] = []
        var out: [GraphNode] = []

        for (i, w) in words.enumerated() {
            if i > 0 {
                var bx = px, by = py
                for _ in 0..<10 {
                    let a = heading + Double.random(in: -0.95...0.95, using: &rng)
                    let len = step * Double.random(in: 0.8...1.2, using: &rng)
                    var cx = px + cos(a) * len
                    var cy = py + sin(a) * len
                    if cx < minX || cx > maxX { heading = Double.pi - heading; continue }
                    if cy < minY || cy > maxY { heading = -heading; continue }
                    cx = max(minX, min(maxX, cx))
                    cy = max(minY, min(maxY, cy))
                    var clear = true
                    for q in placed where hypot(q.0 - cx, q.1 - cy) <= step * 0.55 { clear = false }
                    bx = cx; by = cy
                    if clear { heading = a; break }
                }
                px = bx; py = by
            }
            placed.append((px, py))
            var nd = node(w, CGPoint(x: px, y: py), &rng)
            nd.labelAbove = py > maxY - 40
            out.append(nd)
        }
        return out
    }

    // MARK: Branches. A tree limb growing across the screen with twigs.

    private static func branches(_ words: [LyricWord], _ rng: inout RNG, _ size: CGSize, index: Int) -> [GraphNode] {
        let W = Double(size.width), H = Double(size.height)
        let n = words.count
        let leftToRight = index % 2 == 0
        let x0 = W * 0.10, x1 = W * 0.90
        let amp = H * Double.random(in: 0.10...0.18, using: &rng)
        let freq = Double.random(in: 0.8...1.3, using: &rng)
        let phase = Double.random(in: 0..<(2 * Double.pi), using: &rng)
        var out: [GraphNode] = []
        for (i, w) in words.enumerated() {
            let u = n == 1 ? 0.5 : Double(i) / Double(n - 1)
            let ux = leftToRight ? u : 1 - u
            let x = x0 + (x1 - x0) * ux
            let y = H * 0.50 + amp * sin(u * Double.pi * 2 * freq + phase) + Double.random(in: -12...12, using: &rng)
            var nd = node(w, CGPoint(x: x, y: y), &rng)
            nd.labelAbove = i % 2 == 0
            if i % 2 == 1 || i == 0 || Double.random(in: 0...1, using: &rng) < 0.4 {
                let side: Double = nd.labelAbove ? 1 : -1     // twig grows away from the label
                let dx = Double.random(in: 25...55, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                let dy = side * Double.random(in: 50...90, using: &rng)
                let end = CGPoint(x: x + dx, y: y + dy)
                nd.twigEnd = end
                nd.twigCtrl = CGPoint(x: x + dx * 0.1, y: y + dy * 0.55)
            }
            out.append(nd)
        }
        return out
    }

    // MARK: Web. Nodes sit on the crossings of spokes and rings.

    static let spokes = 10
    static let rings: [Double] = [0.30, 0.55, 0.80, 1.0]

    static func webCenterRadius(_ size: CGSize) -> (CGPoint, Double) {
        (CGPoint(x: size.width / 2, y: size.height * 0.52), Double(min(size.width * 0.40, size.height * 0.36)))
    }

    private static func web(_ words: [LyricWord], _ rng: inout RNG, _ size: CGSize) -> [GraphNode] {
        let (c, R) = webCenterRadius(size)
        let spokeStart = Int(rng.next() % UInt64(spokes))
        var out: [GraphNode] = []
        for (i, w) in words.enumerated() {
            let s = (spokeStart + i * 3) % spokes
            let r = rings[(i + (i / 4) * 2) % rings.count] * R * (1 + 0.04 * Double(i / spokes))
            let a = Double(s) / Double(spokes) * 2 * Double.pi - Double.pi / 2
            let p = CGPoint(x: Double(c.x) + cos(a) * r, y: Double(c.y) + sin(a) * r * 0.92)
            var nd = node(w, p, &rng)
            nd.labelRight = cos(a) >= -0.05
            out.append(nd)
        }
        return out
    }
}

struct GraphStage: View {
    let input: LyricInput
    let kind: GraphKind

    /// A word's label, laid out once as a Canvas symbol and only scaled while it grows.
    /// (Laying the text out again at a new size every frame was most of the drawing time.)
    private struct LabelID: Hashable {
        let line: Int
        let word: Int
        let bright: Bool
    }

    /// Bright (sung) labels are made at their biggest size and scaled down, dim ones at their
    /// resting size, so both are drawn at scale 1 most of the time.
    private static let brightScale = 2.5

    #if DEBUG
    /// Dev aid (`--lyrics-bench`): lay the text out again every frame, the old way, to compare.
    nonisolated(unsafe) static var debugOldText = false
    #endif

    var body: some View {
        GeometryReader { geo in
            let base = baseSize(geo.size)
            let cur = LyricTiming.currentIndex(input.lines, input.t)
            let accent = input.palette.accents[0]
            let dim = accent.mixed(with: .white, 0.35).color
            let bright = input.palette.text.color
            Canvas { ctx, size in
                draw(ctx, size)
            } symbols: {
                ForEach(labels(cur)) { l in
                    Text(l.text)
                        .font(LyricFonts.font(input.font, size: l.id.bright ? base * Self.brightScale : base,
                                              weight: l.id.bright ? .bold : .medium))
                        .foregroundColor(l.id.bright ? bright : dim)
                        .fixedSize()
                        .tag(l.id)
                }
            }
        }
    }

    private struct Label: Identifiable {
        let id: LabelID
        let text: String
    }

    /// Both versions of every word on the lines that can be on screen (this one and the last).
    private func labels(_ cur: Int) -> [Label] {
        guard cur >= 0 else { return [] }
        var out: [Label] = []
        for i in max(0, cur - 1)...cur {
            for (w, word) in LyricTiming.words(input.lines[i]).enumerated() {
                out.append(Label(id: LabelID(line: i, word: w, bright: false), text: word.text))
                out.append(Label(id: LabelID(line: i, word: w, bright: true), text: word.text))
            }
        }
        return out
    }

    private func baseSize(_ size: CGSize) -> Double {
        max(13.0, min(Double(size.width) * 0.0125, 24)) * input.size * (kind == .constellation ? 1 : 1.15)
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let cur = LyricTiming.currentIndex(input.lines, input.t)
        let pal = input.palette
        let accent = pal.accents[0]
        let accent2 = pal.accents.count > 1 ? pal.accents[1] : accent

        if kind == .constellation { drawSky(ctx, size, accent) }
        if kind == .web { drawWebFrame(ctx, size, accent, visible: cur >= 0) }
        guard cur >= 0 else { return }

        for i in max(0, cur - 1)...cur {
            let line = input.lines[i]
            let fade = 1 - LyricTiming.smooth((input.t - LyricTiming.exitTime(line)) / 0.9)
            if fade <= 0.01 { continue }
            let nodes = GraphEngine.layout(kind: kind, line: line, index: i, size: size)
            drawLine(ctx, size, nodes, line: i, fade, accent, accent2)
        }
    }

    private func drawLine(_ ctx: GraphicsContext, _ size: CGSize, _ nodes: [GraphNode], line: Int, _ fade: Double,
                          _ accent: RGB, _ accent2: RGB) {
        let t = input.t
        let motion = input.motion
        let beat = Double(input.snap.beatPulse)
        let lineColor = accent.mixed(with: .white, 0.25).color
        let starColor = accent.mixed(with: .white, 0.55).color

        // Gentle drift so the picture never sits perfectly still.
        func pos(_ n: GraphNode) -> CGPoint {
            CGPoint(x: Double(n.pos.x) + sin(input.clock * 0.30 + n.phase) * 3.0 * motion,
                    y: Double(n.pos.y) + cos(input.clock * 0.37 + n.phase) * 3.0 * motion)
        }
        func appear(_ n: GraphNode) -> Double { LyricTiming.smooth((t - n.start) / 0.40) }
        func active(_ n: GraphNode) -> Double {
            if t < n.start { return 0 }
            let endT = max(n.end, n.start + 0.35)
            return LyricTiming.smooth((t - n.start) / 0.25) * (1 - LyricTiming.smooth((t - endT) / 0.5))
        }

        // 1. Branch stub and twigs (branches only).
        if kind == .branches, let first = nodes.first {
            let a = appear(first)
            if a > 0 {
                let p = pos(first)
                let dir: Double = nodes.count > 1 && nodes[1].pos.x < first.pos.x ? 1 : -1
                var path = Path()
                path.move(to: CGPoint(x: Double(p.x) + dir * 90, y: Double(p.y) + 46))
                path.addQuadCurve(to: p, control: CGPoint(x: Double(p.x) + dir * 40, y: Double(p.y) + 30))
                var c = ctx; c.opacity = a * fade * 0.8
                c.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            }
        }

        // 2. Edges between consecutive words, drawn as the next word arrives.
        if nodes.count > 1 {
            for i in 1..<nodes.count {
                let prog = LyricTiming.smooth((t - nodes[i].start) / 0.45)
                if prog <= 0 { continue }
                let a = pos(nodes[i - 1]), b = pos(nodes[i])
                var path = Path()
                switch kind {
                case .branches:
                    let mid = CGPoint(x: (Double(a.x) + Double(b.x)) / 2, y: (Double(a.y) + Double(b.y)) / 2)
                    let bend = (i % 2 == 0 ? 1.0 : -1.0) * hypot(Double(b.x - a.x), Double(b.y - a.y)) * 0.12
                    let ctrl = CGPoint(x: Double(mid.x), y: Double(mid.y) + bend)
                    path.move(to: a)
                    let steps = 18
                    for s in 1...steps {
                        let u = prog * Double(s) / Double(steps)
                        let x = (1 - u) * (1 - u) * Double(a.x) + 2 * (1 - u) * u * Double(ctrl.x) + u * u * Double(b.x)
                        let y = (1 - u) * (1 - u) * Double(a.y) + 2 * (1 - u) * u * Double(ctrl.y) + u * u * Double(b.y)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                default:
                    path.move(to: a)
                    path.addLine(to: CGPoint(x: Double(a.x) + Double(b.x - a.x) * prog,
                                             y: Double(a.y) + Double(b.y - a.y) * prog))
                }
                var c = ctx; c.opacity = fade * (kind == .branches ? 0.85 : 0.65)
                let width = kind == .branches ? max(1.3, 3.0 - 0.18 * Double(i)) : 1.2
                c.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        if kind == .branches {
            for n in nodes {
                guard let end = n.twigEnd, let ctrl = n.twigCtrl else { continue }
                let prog = LyricTiming.smooth((t - n.start - 0.2) / 0.55)
                if prog <= 0 { continue }
                let a = pos(n)
                var path = Path()
                path.move(to: a)
                for s in 1...12 {
                    let u = prog * Double(s) / 12
                    let x = (1 - u) * (1 - u) * Double(a.x) + 2 * (1 - u) * u * Double(ctrl.x) + u * u * Double(end.x)
                    let y = (1 - u) * (1 - u) * Double(a.y) + 2 * (1 - u) * u * Double(ctrl.y) + u * u * Double(end.y)
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                var c = ctx; c.opacity = fade * 0.7
                c.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                if prog > 0.95 {
                    var l = ctx; l.opacity = fade * 0.9
                    l.fill(Path(ellipseIn: CGRect(x: Double(end.x) - 3.5, y: Double(end.y) - 3.5, width: 7, height: 7)),
                           with: .color(accent2.mixed(with: .white, 0.3).color))
                }
            }
        }

        // 3. Markers and labels.
        for (w, n) in nodes.enumerated() {
            let ap = appear(n)
            if ap <= 0 { continue }
            let act = active(n)
            let p = pos(n)
            let r = (kind == .constellation ? 6.5 : 4.5) * (0.4 + 0.6 * ap) * (1 + 0.12 * beat * motion) * (1 + 0.5 * act)

            if act > 0.02 {
                // Soft glow behind the word being sung.
                var g = ctx; g.opacity = fade * act
                let gr = 52.0
                g.fill(Path(ellipseIn: CGRect(x: Double(p.x) - gr, y: Double(p.y) - gr, width: gr * 2, height: gr * 2)),
                       with: .radialGradient(Gradient(colors: [accent.color.opacity(0.55), accent.color.opacity(0)]),
                                             center: p, startRadius: 0, endRadius: gr))
                var ring = ctx; ring.opacity = fade * act
                ring.stroke(Path(ellipseIn: CGRect(x: Double(p.x) - 13, y: Double(p.y) - 13, width: 26, height: 26)),
                            with: .color(accent.color), lineWidth: 2)
            }

            switch kind {
            case .constellation:
                let twinkle = 1 + 0.10 * sin(input.clock * 2.1 + n.phase) * motion
                drawStar(ctx, p, r * 1.5 * twinkle, starColor, fade * ap)
            case .branches:
                var c = ctx; c.opacity = fade * ap
                c.fill(Path(ellipseIn: CGRect(x: Double(p.x) - r, y: Double(p.y) - r, width: r * 2, height: r * 2)),
                       with: .color(starColor))
            case .web:
                var c = ctx; c.opacity = fade * ap
                c.fill(Path(ellipseIn: CGRect(x: Double(p.x) - r, y: Double(p.y) - r, width: r * 2, height: r * 2)),
                       with: .color(starColor))
            }

            // Label: small and dim, or large and bright (bold) while it is being sung.
            let grow = 1 + 1.5 * act
            let bright = act > 0.5
            let id = LabelID(line: line, word: w, bright: bright)
            let scale = bright ? grow / Self.brightScale : grow
            let alpha = fade * ap * (0.55 + 0.45 * max(act, 0.35))
            switch kind {
            case .web:
                let dx = (n.labelRight ? 1.0 : -1.0) * (12 + 8 * act)
                label(ctx, id, n.text, CGPoint(x: Double(p.x) + dx, y: Double(p.y)),
                      n.labelRight ? .leading : .trailing, scale, alpha)
            default:
                if act > 0.3 || n.labelAbove {
                    label(ctx, id, n.text, CGPoint(x: Double(p.x), y: Double(p.y) - 16 - 12 * act), .bottom, scale, alpha)
                } else {
                    label(ctx, id, n.text, CGPoint(x: Double(p.x), y: Double(p.y) + 14), .top, scale, alpha)
                }
            }
        }
    }

    private func label(_ ctx: GraphicsContext, _ id: LabelID, _ text: String, _ p: CGPoint, _ anchor: UnitPoint,
                       _ scale: Double, _ alpha: Double) {
        var c = ctx
        c.opacity = max(0, min(1, alpha))
        #if DEBUG
        if Self.debugOldText {
            let size = (id.bright ? Self.brightScale : 1) * scale * baseSize(CGSize(width: 1512, height: 982))
            let t = Text(text).font(LyricFonts.font(input.font, size: size, weight: id.bright ? .bold : .medium))
                .foregroundColor(id.bright ? input.palette.text.color : input.palette.accents[0].mixed(with: .white, 0.35).color)
            c.draw(c.resolve(t), at: p, anchor: anchor)
            return
        }
        #endif
        guard let symbol = ctx.resolveSymbol(id: id) else { return }
        c.translateBy(x: p.x, y: p.y)
        c.scaleBy(x: scale, y: scale)
        c.draw(symbol, at: .zero, anchor: anchor)
    }

    /// Four-pointed sparkle.
    private func drawStar(_ ctx: GraphicsContext, _ p: CGPoint, _ r: Double, _ color: Color, _ alpha: Double) {
        var path = Path()
        for k in 0..<8 {
            let a = Double(k) * Double.pi / 4 - Double.pi / 2
            let rad = k % 2 == 0 ? r : r * 0.28
            let pt = CGPoint(x: Double(p.x) + cos(a) * rad, y: Double(p.y) + sin(a) * rad)
            if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        var c = ctx
        c.opacity = max(0, min(1, alpha))
        c.fill(path, with: .color(color))
    }

    /// Faint background stars (constellation).
    private func drawSky(_ ctx: GraphicsContext, _ size: CGSize, _ accent: RGB) {
        var rng = KineticEngine.SplitMix(state: 424242)
        for _ in 0..<70 {
            let x = Double.random(in: 0...Double(size.width), using: &rng)
            let y = Double.random(in: 0...Double(size.height), using: &rng)
            let r = Double.random(in: 0.5...1.4, using: &rng)
            let ph = Double.random(in: 0..<(2 * Double.pi), using: &rng)
            let a = 0.18 + 0.14 * sin(input.clock * 0.8 + ph) * input.motion
            var c = ctx; c.opacity = max(0.04, a)
            c.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                   with: .color(accent.mixed(with: .white, 0.6).color))
        }
    }

    /// Rings and spokes of the web.
    private func drawWebFrame(_ ctx: GraphicsContext, _ size: CGSize, _ accent: RGB, visible: Bool) {
        guard visible else { return }
        let (c, R) = GraphEngine.webCenterRadius(size)
        let spokes = GraphEngine.spokes
        var path = Path()
        for ring in GraphEngine.rings {
            for s in 0...spokes {
                let a = Double(s % spokes) / Double(spokes) * 2 * Double.pi - Double.pi / 2
                let p = CGPoint(x: Double(c.x) + cos(a) * R * ring, y: Double(c.y) + sin(a) * R * ring * 0.92)
                if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        for s in 0..<spokes {
            let a = Double(s) / Double(spokes) * 2 * Double.pi - Double.pi / 2
            path.move(to: c)
            path.addLine(to: CGPoint(x: Double(c.x) + cos(a) * R, y: Double(c.y) + sin(a) * R * 0.92))
        }
        var g = ctx
        g.opacity = 0.16
        g.stroke(path, with: .color(accent.mixed(with: .white, 0.3).color), lineWidth: 0.8)
    }
}
