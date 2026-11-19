import SwiftUI
import AppKit

// MARK: - Palette

/// Colours the graph / code styles draw from. Built from the lyric colours.
struct KPalette: Equatable {
    var text: RGB          // brightest text colour
    var accents: [RGB]     // highlight, plain text, secondary, light highlight
}

extension KPalette {
    /// Cheap value that changes when the colours change.
    var hashStamp: Int {
        var h = Hasher()
        h.combine(text.r); h.combine(text.g); h.combine(text.b)
        for a in accents { h.combine(a.r); h.combine(a.g); h.combine(a.b) }
        return h.finalize()
    }
}

// MARK: - Shared helpers

enum KineticEngine {
    /// Small deterministic random generator, so a line always looks the same.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Stable 0..<1 number for a word (same word, same line -> same value).
    static func unit(_ text: String, _ salt: Int) -> Double {
        var h: UInt64 = 1469598103934665603
        for u in text.lowercased().unicodeScalars { h = (h ^ UInt64(u.value)) &* 1099511628211 }
        var r = SplitMix(state: h &+ UInt64(truncatingIfNeeded: salt) &* 0x2545F4914F6CDD1D)
        return Double(r.next() % 10_000) / 10_000
    }

    /// Words that get an icon beside them (SF Symbol names, or an emoji).
    /// Names that don't exist on this macOS are ignored.
    static let iconMap: [String: String] = [
        "love": "heart.fill", "heart": "heart.fill", "hearts": "heart.fill", "need": "heart.fill", "kiss": "heart.fill",
        "fire": "flame.fill", "burn": "flame.fill", "burning": "flame.fill", "burned": "flame.fill", "hot": "flame.fill",
        "sun": "sun.max.fill", "sunshine": "sun.max.fill", "summer": "sun.max.fill",
        "moon": "moon.fill", "night": "moon.stars.fill", "tonight": "moon.stars.fill", "nights": "moon.stars.fill",
        "star": "star.fill", "stars": "sparkles", "shine": "sparkles", "glow": "sparkles", "magic": "sparkles",
        "rain": "cloud.rain.fill", "cloud": "cloud.fill", "clouds": "cloud.fill", "storm": "cloud.bolt.fill",
        "thunder": "bolt.fill", "lightning": "bolt.fill",
        "money": "dollarsign.circle.fill", "cash": "dollarsign.circle.fill", "gold": "dollarsign.circle.fill",
        "phone": "iphone", "call": "phone.fill", "calling": "phone.fill", "car": "car.fill", "cars": "car.fill",
        "drive": "car.fill", "hummer": "car.fill", "ride": "car.fill",
        "eyes": "eye.fill", "eye": "eye.fill", "see": "eye.fill", "look": "eye.fill", "watch": "eye.fill",
        "start": "play.fill", "play": "play.fill", "push": "figure.run", "run": "figure.run", "running": "figure.run",
        "walk": "figure.walk", "dance": "figure.dance", "dancing": "figure.dance",
        "telling": "bubble.left.fill", "tell": "bubble.left.fill", "told": "bubble.left.fill", "say": "bubble.left.fill",
        "talk": "bubble.left.fill", "talking": "bubble.left.fill",
        "chances": "dice.fill", "chance": "dice.fill", "luck": "dice.fill", "blew": "wind", "blow": "wind", "wind": "wind",
        "you": "person.fill", "number": "number", "name": "signature",
        "music": "music.note", "song": "music.note", "sing": "music.mic",
        "fly": "airplane", "wings": "bird.fill", "bird": "bird.fill",
        "shirt": "tshirt.fill", "home": "house.fill", "house": "house.fill",
        "time": "clock.fill", "clock": "clock.fill", "crown": "crown.fill", "king": "crown.fill", "queen": "crown.fill",
        "world": "globe", "ocean": "water.waves", "sea": "water.waves", "water": "drop.fill", "tears": "drop.fill",
        "snow": "snowflake", "cold": "snowflake", "flower": "leaf.fill", "rose": "leaf.fill",
        "key": "key.fill", "lock": "lock.fill", "gift": "gift.fill", "game": "gamecontroller.fill",
        "wine": "wineglass.fill", "drink": "wineglass.fill", "coffee": "cup.and.saucer.fill",
        "hand": "hand.raised.fill", "hands": "hand.raised.fill", "dream": "cloud.moon.fill", "sleep": "bed.double.fill",
        "light": "lightbulb.fill", "lights": "lightbulb.fill", "smile": "face.smiling", "cry": "drop.fill",
        "bridges": "road.lanes", "bridge": "road.lanes", "button": "button.programmable",
        // Emoji for a few words.
        "hundred": "💯", "hundreds": "💯", "swish": "👆", "point": "👆", "vegetables": "🥦", "shame": "😳"
    ]

    /// Words that get an icon only now and then, so they don't get one every time.
    static let sometimesIcon: Set<String> = ["you", "need", "see", "start", "say", "look"]

    private static var symbolOK: [String: Bool] = [:]
    static func symbolExists(_ name: String) -> Bool {
        if let ok = symbolOK[name] { return ok }
        let ok = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        symbolOK[name] = ok
        return ok
    }

    static func isEmoji(_ s: String) -> Bool {
        s.unicodeScalars.first.map { $0.properties.isEmojiPresentation } ?? false
    }
}
