import SwiftUI
import AppKit

// MARK: - Fisheye

/// Lyrics on a vertical lens: the current line is large and sharp in the middle,
/// lines further away shrink, fade and tilt back as if wrapped on a sphere.
struct FisheyeStage: View {
    let input: LyricInput

    var body: some View {
        GeometryReader { geo in
            let f = LyricTiming.fractionalIndex(input.lines, input.t)
            let cur = LyricTiming.currentIndex(input.lines, input.t)
            let base = min(Double(geo.size.width) * 0.058, Double(geo.size.height) * 0.105) * input.size
            let cy = Double(geo.size.height) / 2
            let span = Double(geo.size.height) * 0.47
            let lo = max(0, Int(f.rounded(.down)) - 5)
            let hi = min(input.lines.count - 1, Int(f.rounded(.down)) + 6)

            ZStack {
                if hi >= lo {
                    ForEach(Array(lo...hi), id: \.self) { i in
                        row(i, f: f, cur: cur, base: base, cy: cy, span: span, width: Double(geo.size.width))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func row(_ i: Int, f: Double, cur: Int, base: Double, cy: Double, span: Double, width: Double) -> some View {
        let r = Double(i) - f
        let d = abs(r)
        let sign: Double = r < 0 ? -1 : 1
        let scale = 0.28 + 0.72 * exp(-d * 0.62)
        let y = cy + sign * span * (1 - exp(-d * 0.52))
        let opacity = max(0.06, exp(-d * 0.40))
        let isCur = i == cur
        let line = input.lines[i]

        lineText(line, isCur: isCur)
            .font(LyricFonts.font(input.font, size: base, weight: .bold))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.5)
            .frame(width: width * 0.82)
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(-r * 9), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .opacity(opacity)
            .position(x: CGFloat(width / 2), y: CGFloat(y))
    }

    private func lineText(_ line: LyricLine, isCur: Bool) -> Text {
        if line.words.isEmpty { return Text("♪").foregroundColor(input.colors.secondary.color) }
        if !isCur { return Text(line.text).foregroundColor(input.colors.secondary.color) }
        var out = Text("")
        let n = line.words.count
        for (i, w) in line.words.enumerated() {
            let prog = LyricTiming.clamp((input.t - w.start) / max(0.12, w.end - w.start))
            let c = input.colors.text.mixed(with: input.colors.highlight, prog)
            out = out + Text(w.text + (i < n - 1 ? " " : "")).foregroundColor(c.color)
        }
        return out
    }
}

// MARK: - Code

/// Lyrics as source code in an editor: line numbers, syntax colours, a highlighted
/// current line and a blinking caret that follows the words being sung.
/// Always uses a monospaced font (the font picker doesn't apply here).
struct CodeStage: View {
    let input: LyricInput

    var body: some View {
        GeometryReader { geo in
            let f = LyricTiming.fractionalIndex(input.lines, input.t)
            let cur = LyricTiming.currentIndex(input.lines, input.t)
            let fs = min(Double(geo.size.width) * 0.026, Double(geo.size.height) * 0.046) * input.size
            let lineH = fs * 1.75
            let W = Double(geo.size.width), H = Double(geo.size.height)
            let rowW = W * 0.84
            let cy = H / 2
            let lo = max(0, Int(f.rounded(.down)) - 6)
            let hi = min(input.lines.count - 1, Int(f.rounded(.down)) + 7)

            ZStack(alignment: .topLeading) {
                // Current-line highlight bar.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: rowW + 16, height: lineH)
                    .position(x: CGFloat(W / 2), y: CGFloat(cy))

                if hi >= lo {
                    ForEach(Array(lo...hi), id: \.self) { i in
                        row(i, f: f, cur: cur, fs: fs, rowW: rowW)
                            .position(x: CGFloat(W / 2), y: CGFloat(cy + (Double(i) - f) * lineH))
                    }
                }

                // Editor chrome: three dots and a file name.
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 9, height: 9)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 9, height: 9)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 9, height: 9)
                    Text("lyrics.swift")
                        .font(LyricFonts.mono(size: max(11, fs * 0.5)))
                        .foregroundColor(Color.white.opacity(0.35))
                        .padding(.leading, 8)
                }
                .padding(.leading, CGFloat(W * 0.08 + 8))
                .padding(.top, CGFloat(H * 0.07))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1.0)
                ], startPoint: .top, endPoint: .bottom)
            )
        }
    }

    private func tokenColor(_ word: String) -> Color {
        let key = word.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        var h = 5381
        for u in key.unicodeScalars { h = (h &* 33) &+ Int(u.value) }
        let pal = input.palette
        let choices: [RGB] = [pal.accents[0], pal.accents.count > 1 ? pal.accents[1] : pal.accents[0],
                              pal.text, pal.accents.count > 2 ? pal.accents[2] : pal.text]
        return choices[abs(h) % choices.count].color
    }

    private func row(_ i: Int, f: Double, cur: Int, fs: Double, rowW: Double) -> some View {
        let d = abs(Double(i) - f)
        let line = input.lines[i]
        let isCur = i == cur
        let dim = Color.white.opacity(0.32)
        let punct = Color(red: 0.55, green: 0.60, blue: 0.70)
        let blink = Int(input.clock * 2) % 2 == 0

        var code = Text("lyric(\"").foregroundColor(punct)
        let words = line.words
        if words.isEmpty {
            code = code + Text("♪").foregroundColor(dim)
        } else {
            for (k, w) in words.enumerated() {
                let sung = !isCur || input.t >= w.start
                let c = sung ? tokenColor(w.text) : dim
                code = code + Text(w.text + (k < words.count - 1 ? " " : "")).foregroundColor(c)
            }
        }
        if isCur && blink {
            code = code + Text("▍").foregroundColor(input.palette.accents[0].color)
        }
        code = code + Text("\");").foregroundColor(punct)

        return HStack(spacing: fs * 1.1) {
            Text("\(i + 1)")
                .foregroundColor(Color.white.opacity(isCur ? 0.7 : 0.25))
                .frame(width: fs * 2.4, alignment: .trailing)
            code
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(LyricFonts.mono(size: fs, weight: isCur ? .semibold : .regular))
        .frame(width: rowW)
        .opacity(isCur ? 1 : max(0.12, 0.62 - 0.09 * d))
    }
}
