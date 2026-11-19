import Foundation

struct LyricWord: Equatable {
    let text: String
    let start: Double
    let end: Double
}

struct LyricLine: Equatable {
    let start: Double
    let end: Double
    let words: [LyricWord]
    var text: String { words.map(\.text).joined(separator: " ") }
}

enum LRC {
    /// Parses "[mm:ss.xx] text" lines. LRCLIB only has line-level timing, so word
    /// timings are interpolated across each line, weighted by word length.
    static func parse(_ raw: String, duration: Double) -> [LyricLine] {
        guard let stamp = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#) else { return [] }
        var entries: [(Double, String)] = []

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let ns = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                guard let mins = Double(ns.substring(with: m.range(at: 1))),
                      let secs = Double(ns.substring(with: m.range(at: 2))) else { continue }
                entries.append((mins * 60 + secs, text))
            }
        }
        entries.sort { $0.0 < $1.0 }

        var lines: [LyricLine] = []
        for (i, e) in entries.enumerated() {
            let next = i + 1 < entries.count ? entries[i + 1].0 : max(duration, e.0 + 4)
            lines.append(makeLine(start: e.0, end: next, text: e.1))
        }
        return lines
    }

    private static func makeLine(start: Double, end: Double, text: String) -> LyricLine {
        let tokens = text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return LyricLine(start: start, end: end, words: []) }

        let weights = tokens.map { Double($0.count) + 1 }
        let total = weights.reduce(0, +)
        // Singers rarely fill the whole gap to the next line.
        let available = max(end - start - 0.05, 0.3)
        let span = min(available, max(0.8, Double(text.count) * 0.09))

        var t = start
        var words: [LyricWord] = []
        for (token, w) in zip(tokens, weights) {
            let dur = span * w / total
            words.append(LyricWord(text: token, start: t, end: t + dur))
            t += dur
        }
        return LyricLine(start: start, end: end, words: words)
    }
}

