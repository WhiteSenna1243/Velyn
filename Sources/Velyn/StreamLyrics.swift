import SwiftUI
import AppKit
import CoreImage

// MARK: - Stream (word stream)
//
// One word per row, centred. Each new word arrives at the bottom in a pink box with
// white text. When the next word comes, it slides up into the middle row and grows,
// its box turns dark maroon (coral text) and then fades to plain red. Then it shrinks
// into the top row and leaves. A new line clears the stack.

struct StreamStage: View {
    let input: LyricInput
    /// Visual mode: smaller text, sitting under the album art.
    var compact = false

    /// Size of a row, by slot (0 = newest/bottom, 1 = middle, 2 = top, 3 = gone).
    private static let slotScale: [Double] = [0.60, 1.0, 0.50, 0.40]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let cur = LyricTiming.currentIndex(input.lines, input.t)
            ZStack {
                if cur >= 0 {
                    if cur > 0 {
                        let out = LyricTiming.smooth((input.t - input.lines[cur].start) / 0.18)
                        if out < 1 { stack(cur - 1, size: size, fade: 1 - out) }
                    }
                    let line = input.lines[cur]
                    let late = LyricTiming.smooth((input.t - (LyricTiming.exitTime(line) + 1.6)) / 0.6)
                    if late < 1 { stack(cur, size: size, fade: 1 - late) }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private struct Row {
        let id: Int
        let word: LyricWord
        let slot: Double       // continuous slot
        let fontSize: Double
        let height: Double     // space it takes in the stack right now
    }

    @ViewBuilder
    private func stack(_ index: Int, size: CGSize, fade: Double) -> some View {
        let line = input.lines[index]
        let words = LyricTiming.words(line)
        let t = input.t
        let k = words.lastIndex(where: { $0.start <= t }) ?? -1
        if k >= 0 {
            let W = Double(size.width), H = Double(size.height)
            let base = min(W * 0.15, H * 0.24) * input.size * (compact ? 0.42 : 1)
            let rows: [Row] = (max(0, k - 3)...k).compactMap { i -> Row? in
                var s = 0.0
                if i < k { for j in (i + 1)...k { s += ease(LyricTiming.clamp((t - words[j].start) / 0.30)) } }
                guard s < 3 else { return nil }
                var scale = interp(s)
                if i == 0 && s < 1 { scale = 1.0 }           // first word of a line starts big
                let w = words[i]
                let maxW = W * (compact ? 0.6 : 0.82)
                let fs = min(base * scale, maxW / max(0.01, widthPerPoint(w.text, salt: index * 131 + i)))
                let grow = s > 2 ? (3 - s) : 1                // the leaving word gives its space back
                return Row(id: i, word: w, slot: s, fontSize: fs, height: fs * 1.06 * grow)
            }
            let total = rows.reduce(0) { $0 + $1.height }
            let centerY = compact ? H * 0.74 : H * 0.5
            let ys: [Double] = {
                var y = centerY - total / 2
                return rows.map { r in defer { y += r.height }; return y + r.height / 2 }
            }()
            ZStack {
                ForEach(Array(rows.enumerated()), id: \.element.id) { n, r in
                    wordView(r, words: words, k: k, lineIndex: index, W: W, y: ys[n])
                }
            }
            .opacity(fade)
            .offset(y: -(1 - fade) * 24)
        }
    }

    @ViewBuilder
    private func wordView(_ r: Row, words: [LyricWord], k: Int, lineIndex: Int, W: Double, y: Double) -> some View {
        let t = input.t
        let c = input.colors
        let salt = lineIndex * 131 + r.id
        let key = r.word.text.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        let rnd = { (n: Int) in KineticEngine.unit(key, salt * 7 + n) }

        // Box and text colour over the word's life.
        let q: Double = r.id < k ? t - words[r.id + 1].start : -1     // time since it left the bottom row
        let maroon: RGB = c.highlight.mixed(with: .black, 0.68)
        let toMaroon: Double = LyricTiming.smooth(q / 0.12)
        let keepsBox: Bool = rnd(1) < 0.45
        let keptFade: Double = 1 - LyricTiming.smooth((r.slot - 1.35) / 0.4)
        let quickFade: Double = 1 - LyricTiming.smooth((q - 0.12) / 0.3)
        let boxAlpha: Double = q < 0 ? 1 : (keepsBox ? keptFade : quickFade)
        let boxColor: RGB = c.highlight.mixed(with: maroon, toMaroon)
        let onBox: RGB = RGB.white.mixed(with: c.secondary, toMaroon)
        let textColor: RGB = q < 0 ? RGB.white : onBox.mixed(with: c.text, 1 - boxAlpha)

        // Enter (bottom row), leave (past the top row).
        let age: Double = t - r.word.start
        let enter: Double = LyricTiming.smooth(age / 0.14)
        let pop: Double = 0.86 + 0.14 * ease(LyricTiming.clamp(age / 0.22))
        let leave: Double = r.slot > 2 ? LyricTiming.smooth(r.slot - 2) : 0
        let beat = Double(input.snap.beatPulse)
        let middle: Double = max(0, 1 - abs(r.slot - 1))

        let fs: Double = r.fontSize
        let idle: Double = input.motion
        let driftX: Double = sin(input.clock * 0.5 + rnd(3) * 6) * 2 * idle
        let dx: Double = (rnd(2) - 0.5) * W * 0.10 + driftX
        let dy: Double = cos(input.clock * 0.6 + rnd(4) * 6) * 1.5 * idle + (1 - enter) * fs * 0.14
        let tiltZ: Double = (rnd(5) - 0.5) * 5
        let tiltY: Double = (rnd(6) - 0.5) * 26
        let scale: Double = pop * (1 + 0.025 * beat * middle) * (1 - 0.15 * leave)
        let alpha: Double = enter * (1 - leave)
        let px = CGFloat(W / 2 + dx)
        let py = CGFloat(y + dy - leave * fs * 0.4)

        let word = StreamWord(text: r.word.text, fontSize: fs, font: input.font, italic: rnd(7) < 0.28,
                            textColor: textColor, box: boxAlpha > 0.01 ? boxColor : nil, boxAlpha: boxAlpha,
                            icon: icon(for: key, salt: salt), iconLeft: rnd(8) < 0.45, iconColor: c.highlight,
                            skew: (rnd(9) - 0.5) * 0.16)
        word
            .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .rotationEffect(.degrees(tiltZ))
            .scaleEffect(scale)
            .opacity(alpha)
            .position(x: px, y: py)
    }

    private func icon(for key: String, salt: Int) -> String? {
        guard let name = KineticEngine.iconMap[key] else { return nil }
        if KineticEngine.sometimesIcon.contains(key), KineticEngine.unit(key, salt * 7 + 11) < 0.5 { return nil }
        return KineticEngine.isEmoji(name) || KineticEngine.symbolExists(name) ? name : nil
    }

    private func ease(_ x: Double) -> Double {
        let p = 1 - x
        return 1 - p * p * p
    }

    private func interp(_ s: Double) -> Double {
        let i = min(Int(s), 2)
        let f = s - Double(i)
        return Self.slotScale[i] + (Self.slotScale[i + 1] - Self.slotScale[i]) * f
    }

    /// Width of the word (with any box / icon) per point of font size.
    private func widthPerPoint(_ text: String, salt: Int) -> Double {
        let key = "\(input.font.rawValue)|\(text)"
        if let w = Self.widths[key] { return w }
        let f = LyricFonts.ns(input.font, size: 100, weight: .semibold)
        var w = Double((text as NSString).size(withAttributes: [.font: f]).width) / 100 + 0.3
        let k = text.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        if KineticEngine.iconMap[k] != nil { w += 1.1 }
        if Self.widths.count > 2000 { Self.widths.removeAll() }
        Self.widths[key] = w
        return w
    }
    private static var widths: [String: Double] = [:]
}

/// One Ship word: text, optional tape-like box, optional icon.
struct StreamWord: View {
    let text: String
    let fontSize: Double
    let font: LyricFont
    let italic: Bool
    let textColor: RGB
    let box: RGB?
    let boxAlpha: Double
    let icon: String?
    let iconLeft: Bool
    let iconColor: RGB
    let skew: Double

    var body: some View {
        HStack(spacing: fontSize * 0.16) {
            if iconLeft, let icon { iconView(icon) }
            Text(text)
                .font(LyricFonts.font(font, size: fontSize, weight: .semibold))
                .italic(italic)
                .foregroundColor(textColor.color)
                .shadow(color: box != nil ? Color.black.opacity(0.22 * boxAlpha) : .clear, radius: 1.5, y: 1)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, fontSize * 0.07)
                .background(
                    TapeShape(skew: skew)
                        .fill((box ?? .black).color.opacity(box == nil ? 0 : boxAlpha))
                        .padding(.vertical, fontSize * 0.07)   // boxes hug the letters
                )
            if !iconLeft, let icon { iconView(icon) }
        }
    }

    @ViewBuilder
    private func iconView(_ name: String) -> some View {
        if KineticEngine.isEmoji(name) {
            Text(name).font(.system(size: fontSize * 0.7))
        } else {
            Image(systemName: name)
                .font(.system(size: fontSize * 0.62, weight: .bold))
                .foregroundColor(iconColor.color)
        }
    }
}

/// A box with slightly uneven corners, like a strip of tape.
struct TapeShape: Shape {
    let skew: Double
    func path(in r: CGRect) -> Path {
        let h = r.height, k = CGFloat(skew) * h
        var p = Path()
        p.move(to: CGPoint(x: r.minX + max(0, k), y: r.minY + h * 0.03))
        p.addLine(to: CGPoint(x: r.maxX + min(0, k), y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - max(0, k) * 0.6, y: r.maxY - h * 0.02))
        p.addLine(to: CGPoint(x: r.minX - min(0, k) * 0.6, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Album art as the visual (the "Visual" styles)

/// The album art turned into a single-colour picture: bright parts take the colour,
/// dark parts become see-through. Rendered once per artwork / colour.
struct ArtVisual: View {
    let image: NSImage
    let color: RGB
    var opacity = 1.0

    var body: some View {
        if let cg = ArtTint.image(image, color: color) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .opacity(opacity)
        }
    }
}

enum ArtTint {
    private static var key: (ObjectIdentifier, Int)?
    private static var cached: CGImage?
    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    static func image(_ img: NSImage, color: RGB) -> CGImage? {
        let stamp = Int(color.r * 255) << 16 | Int(color.g * 255) << 8 | Int(color.b * 255)
        if let k = key, k.0 == ObjectIdentifier(img), k.1 == stamp { return cached }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var ci = CIImage(cgImage: cg)
        let s = min(1, 640 / max(ci.extent.width, ci.extent.height))
        ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let mono = ci.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputContrastKey: 1.45, kCIInputBrightnessKey: -0.06
        ])
        let mask = mono.applyingFilter("CIMaskToAlpha")
        let fill = CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b)).cropped(to: ci.extent)
        let out = fill.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
        let result = ctx.createCGImage(out, from: ci.extent)
        key = (ObjectIdentifier(img), stamp)
        cached = result
        return result
    }
}
