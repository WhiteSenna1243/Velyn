import SwiftUI
import AppKit

/// Font families the user can pick for lyrics (Settings > Lyrics > Font).
enum LyricFont: String, Codable, CaseIterable, Identifiable {
    case sfPro = "SF Pro"
    case sfRounded = "SF Rounded"
    case newYork = "New York"
    case helvetica = "Helvetica Neue"
    case avenir = "Avenir Next"
    case futura = "Futura"
    case didot = "Didot"
    var id: String { rawValue }

    /// Installed family name for non-system fonts.
    var family: String? {
        switch self {
        case .helvetica: return "Helvetica Neue"
        case .avenir: return "Avenir Next"
        case .futura: return "Futura"
        case .didot: return "Didot"
        default: return nil
        }
    }
}

/// One place that builds fonts, so measuring text (NSFont) and drawing it (SwiftUI Font) always match.
enum LyricFonts {
    private static var cache: [String: NSFont] = [:]

    static func ns(_ f: LyricFont, size: Double, weight: NSFont.Weight) -> NSFont {
        let key = "\(f.rawValue)|\(Int(size * 4))|\(weight.rawValue)"
        if let hit = cache[key] { return hit }
        let sz = CGFloat(size)
        var font = NSFont.systemFont(ofSize: sz, weight: weight)
        switch f {
        case .sfPro:
            break
        case .sfRounded:
            if let d = font.fontDescriptor.withDesign(.rounded), let g = NSFont(descriptor: d, size: sz) { font = g }
        case .newYork:
            if let d = font.fontDescriptor.withDesign(.serif), let g = NSFont(descriptor: d, size: sz) { font = g }
        default:
            if let fam = f.family {
                let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
                let attrs: [NSFontDescriptor.AttributeName: Any] = [.family: fam, .traits: traits]
                if let g = NSFont(descriptor: NSFontDescriptor(fontAttributes: attrs), size: sz) { font = g }
            }
        }
        if cache.count > 400 { cache.removeAll() }
        cache[key] = font
        return font
    }

    static func font(_ f: LyricFont, size: Double, weight: NSFont.Weight) -> Font {
        Font(ns(f, size: size, weight: weight) as CTFont)
    }

    static func mono(size: Double, weight: NSFont.Weight = .regular) -> Font {
        Font(NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: weight) as CTFont)
    }
}

// MARK: - Shared timing helpers

enum LyricTiming {
    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { max(lo, min(hi, x)) }

    static func smooth(_ x: Double) -> Double {
        let c = clamp(x)
        return c * c * (3 - 2 * c)
    }

    /// Index of the line being sung (-1 before the first one).
    static func currentIndex(_ lines: [LyricLine], _ t: Double) -> Int {
        var r = -1
        for (i, l) in lines.enumerated() {
            if l.start <= t { r = i } else { break }
        }
        return r
    }

    /// When a line starts to leave.
    static func exitTime(_ line: LyricLine) -> Double {
        guard let last = line.words.last else { return line.start + 1.2 }
        return max(last.end + 0.2, min(line.end, last.end + 1.3))
    }

    /// Line position as a smooth number: eases to the next line just before it starts.
    static func fractionalIndex(_ lines: [LyricLine], _ t: Double) -> Double {
        let cur = currentIndex(lines, t)
        if cur < 0 { return 0 }
        guard cur + 1 < lines.count else { return Double(cur) }
        let next = lines[cur + 1].start
        return Double(cur) + smooth((t - (next - 0.5)) / 0.5)
    }

    /// The words of a line, or a single note symbol for an instrumental line.
    static func words(_ line: LyricLine) -> [LyricWord] {
        line.words.isEmpty
            ? [LyricWord(text: "♪", start: line.start, end: max(line.end, line.start + 1))]
            : line.words
    }
}

/// Everything a lyric style needs for one frame.
struct LyricInput {
    let lines: [LyricLine]
    let t: Double              // song position, seconds
    let clock: Double          // wall clock for idle motion
    let size: Double           // text size multiplier
    let motion: Double         // 0...1.5
    let palette: KPalette
    let colors: LyricColors
    let font: LyricFont
    let snap: AudioSnapshot
}
