import SwiftUI

/// A plain sRGB colour that is easy to store, blend and compare.
struct RGB: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init(h: Double, s: Double, v: Double) {
        let hh = (h - floor(h)) * 6
        let c = v * s
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        var r1 = 0.0, g1 = 0.0, b1 = 0.0
        switch Int(hh) {
        case 0: r1 = c; g1 = x
        case 1: r1 = x; g1 = c
        case 2: g1 = c; b1 = x
        case 3: g1 = x; b1 = c
        case 4: r1 = x; b1 = c
        default: r1 = c; b1 = x
        }
        self.init(r: r1 + m, g: g1 + m, b: b1 + m)
    }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        let k = max(0, min(1, t))
        return RGB(r: r + (other.r - r) * k, g: g + (other.g - g) * k, b: b + (other.b - b) * k)
    }

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)
}

/// A choice saved in settings: a stable id on disk (`rawValue`), a name for the UI (`title`),
/// and the names older builds saved (`legacy`) so their settings still load.
protocol SettingChoice: RawRepresentable, Codable, CaseIterable, Identifiable, Hashable where RawValue == String {
    var title: String { get }
    static var legacy: [String: Self] { get }
}

extension SettingChoice {
    var id: String { rawValue }
    static var legacy: [String: Self] { [:] }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = Self(rawValue: s) ?? Self.legacy[s] else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown value \(s)")
        }
        self = v
    }
}

/// How the glow moves.
enum GlowAnimation: String, SettingChoice {
    case standard = "flow"       // colours flow slowly around the edge
    case musicSync = "beat"      // reacts to bass, loudness and beats
    case idle = "breathe"        // slow breathing
    case none = "still"          // no movement

    var title: String {
        switch self {
        case .standard: return "Flow"
        case .musicSync: return "Beat Sync"
        case .idle: return "Breathe"
        case .none: return "Still"
        }
    }
    static var legacy: [String: GlowAnimation] {
        ["Default": .standard, "Music Sync": .musicSync, "Idle": .idle, "No Animation": .none]
    }
}

/// How Beat Sync turns the music into light.
enum SyncStyle: String, SettingChoice {
    case energy        // brightness follows loudness + bass, colours step on beats
    case pulse         // calm between beats, flashes on every beat

    var title: String { self == .energy ? "Energy" : "Pulse" }
    static var legacy: [String: SyncStyle] { ["Energic": .energy, "Pulse": .pulse] }
}

/// How the edge glow is drawn.
enum GlowStyle: String, SettingChoice {
    case liquid        // rippling band with bulges that slide around the edge (GPU shader)
    case classic = "soft"   // even soft ring

    var title: String { self == .liquid ? "Liquid" : "Soft" }
    static var legacy: [String: GlowStyle] { ["Liquid": .liquid, "Classic": .classic] }
}

/// What the lock screen shows (when "Show on the lock screen" is on).
enum LockLook: String, SettingChoice {
    case player        // big album art, the song, how much has played
    case lyrics        // album art and progress on the left, synced lyrics on the right
    case style         // your lyric style under the clock

    var title: String {
        switch self {
        case .player: return "Player"
        case .lyrics: return "Lyrics"
        case .style: return "Lyric style"
        }
    }
}

/// Lock screen background behind the Player and Lyrics looks.
enum LockBackground: String, SettingChoice {
    case black, white
    var title: String { self == .black ? "Black" : "White" }
}

/// Lyric styles, in menu order.
enum LyricStyle: String, SettingChoice {
    case stream        // word stream: the new word lands boxed at the bottom and moves up
    case lens          // lines wrap around a lens
    case code          // lyrics as source code
    case vine          // words grow along a branch
    case weave         // words on a web of threads
    case stars         // words become stars joined by lines
    case spotlight     // big lines that fill in as they're sung, blurred art behind

    var title: String {
        switch self {
        case .stream: return "Stream"
        case .lens: return "Lens"
        case .code: return "Code"
        case .vine: return "Vine"
        case .weave: return "Weave"
        case .stars: return "Stars"
        case .spotlight: return "Spotlight"
        }
    }

    /// Styles that can show the album art behind the words ("Album art behind lyrics").
    var supportsArt: Bool { self == .stream || self == .lens || self == .code }

    static var legacy: [String: LyricStyle] {
        ["Ship": .stream, "Visual": .stream, "Fisheye": .lens, "Fisheye Visual": .lens,
         "Codestyle": .code, "Codestyle Visual": .code, "Branches": .vine, "Web": .weave,
         "Constellation": .stars, "Apple Music": .spotlight]
    }
    /// Old style names that meant "with the album art".
    static let legacyWithArt: Set<String> = ["Visual", "Fisheye Visual", "Codestyle Visual"]
}

/// Every user-facing setting in one Codable value, saved as JSON.
struct Prefs: Codable, Equatable {
    // Glow
    var glowEnabled = true
    var gradientColors = 2                 // 1 or 2
    var glowMode = GlowAnimation.musicSync
    var glowStyle = GlowStyle.liquid
    var glowFollowsApp = true              // only glow on displays where a Velyn window is open
    var notchCompat = false                // glow follows the notch outline
    var thickness = 0.3                    // 0...1
    var glow = 1.0                         // 0...1
    var brightness = 1.0                   // 0...1 (light bulb in the toolbar)
    var overrideAlbum = false              // true = use the wheels, false = album colours
    var primaryH = 0.0, primaryS = 0.0, primaryB = 0.0
    var secondaryH = 0.60, secondaryS = 0.85, secondaryB = 1.0
    var primaryShare = 0.6                 // primary / secondary balance
    var glowDisplays: [UInt32] = []        // empty = main display
    var audioReactive = true               // listen to system audio for Music Sync
    var syncStyle = SyncStyle.energy
    var syncSensitivity = 1.0              // 0.5...2
    var lockScreen = true                  // lyrics + glow on the real lock screen
    var lockLook = LockLook.player         // what the lock screen shows (displays without their own choice)
    var lockDisplayLooks: [String: LockLook] = [:]   // per display (display ID -> look)
    var lockBackground = LockBackground.black
    var showInDock = true
    var motionArt = true                   // animated album covers from Apple Music
    var checkUpdates = true
    var hotKeys = true                     // global keyboard shortcuts (⌃⌥⌘ + key)
    var songBanners = false                // notification when a new song starts
    var phoneRemote = false                // web remote on the local network (PhoneRemote)

    // Lyrics
    var showStage = true                   // lyrics window shown
    var lyricStyle = LyricStyle.stream
    var lyricArt = false                   // album art behind the lyrics (styles with `supportsArt`)
    var lyricFont = LyricFont.sfPro
    var lyricMotion = 0.6                  // 0...1.5, idle drift
    var lyricSize = 1.0                    // 0.6...1.4
    var autoSync = true                    // lyric colours from album art
    var lyricColor = RGB(r: 0.91, g: 0.22, b: 0.17)       // plain words (red)
    var highlightColor = RGB(r: 1.0, g: 0.27, b: 0.43)    // box behind the word being sung (pink)
    var secondaryColor = RGB(r: 1.0, g: 0.50, b: 0.42)    // words on the dark box (coral)
    var lyricLead = 0.5                    // all songs: lyrics this many seconds earlier
    var lyricOffsets: [String: Double] = [:]   // lyric timing per song (Track.key -> seconds)
    var keepAwake = true

    static let defaultLyricSize = 1.0

    private enum CodingKeys: String, CodingKey {
        case glowEnabled, gradientColors, glowMode, glowStyle, glowFollowsApp, notchCompat, thickness, glow, brightness
        case overrideAlbum, primaryH, primaryS, primaryB, secondaryH, secondaryS, secondaryB, primaryShare
        case glowDisplays, audioReactive, syncStyle, syncSensitivity, lockScreen, lockLook, lockDisplayLooks, lockBackground, showInDock, checkUpdates, motionArt, hotKeys, phoneRemote, songBanners
        case showStage, lyricStyle, lyricArt, lyricFont, lyricMotion, lyricSize, autoSync
        case lyricColor, highlightColor, secondaryColor, lyricLead, lyricOffsets, keepAwake
    }

    /// Keys older builds used.
    private enum LegacyKeys: String, CodingKey { case glowFollowsHalo }

    init() {}

    /// Tolerant decoding: unknown or missing values fall back to the default, field by field.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ into: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: k) { into = v }
        }
        get(.glowEnabled, &glowEnabled); get(.gradientColors, &gradientColors); get(.glowMode, &glowMode)
        get(.glowStyle, &glowStyle); get(.glowFollowsApp, &glowFollowsApp)
        get(.notchCompat, &notchCompat); get(.thickness, &thickness); get(.glow, &glow); get(.brightness, &brightness)
        get(.overrideAlbum, &overrideAlbum)
        get(.primaryH, &primaryH); get(.primaryS, &primaryS); get(.primaryB, &primaryB)
        get(.secondaryH, &secondaryH); get(.secondaryS, &secondaryS); get(.secondaryB, &secondaryB)
        get(.primaryShare, &primaryShare); get(.glowDisplays, &glowDisplays)
        get(.audioReactive, &audioReactive); get(.syncStyle, &syncStyle); get(.syncSensitivity, &syncSensitivity)
        get(.lockScreen, &lockScreen); get(.lockLook, &lockLook); get(.lockDisplayLooks, &lockDisplayLooks); get(.lockBackground, &lockBackground); get(.showInDock, &showInDock); get(.checkUpdates, &checkUpdates)
        get(.motionArt, &motionArt); get(.hotKeys, &hotKeys); get(.phoneRemote, &phoneRemote); get(.songBanners, &songBanners)
        get(.showStage, &showStage); get(.lyricStyle, &lyricStyle); get(.lyricArt, &lyricArt); get(.lyricFont, &lyricFont)
        get(.lyricMotion, &lyricMotion); get(.lyricSize, &lyricSize); get(.autoSync, &autoSync)
        get(.lyricColor, &lyricColor); get(.highlightColor, &highlightColor); get(.secondaryColor, &secondaryColor)
        get(.lyricLead, &lyricLead); get(.lyricOffsets, &lyricOffsets); get(.keepAwake, &keepAwake)

        // Settings from older builds.
        if let old = try? c.decodeIfPresent(String.self, forKey: .lyricStyle), LyricStyle.legacyWithArt.contains(old) {
            lyricArt = true
        }
        if let l = try? decoder.container(keyedBy: LegacyKeys.self),
           let v = try? l.decodeIfPresent(Bool.self, forKey: .glowFollowsHalo) {
            glowFollowsApp = v
        }
    }

    /// What the lock screen shows on this display.
    func lockLook(for display: UInt32) -> LockLook { lockDisplayLooks[String(display)] ?? lockLook }

    /// "Reset Colors": lyric colours back to default.
    mutating func resetColors() {
        let d = Prefs()
        lyricColor = d.lyricColor
        highlightColor = d.highlightColor
        secondaryColor = d.secondaryColor
    }
}

final class Settings: ObservableObject {
    private static let key = "velyn.prefs"

    @Published var prefs: Prefs {
        didSet {
            if let data = try? JSONEncoder().encode(prefs) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    init() {
        let mine = UserDefaults.standard.data(forKey: Self.key)
        let saved = mine ?? Migration.oldPrefs()
        prefs = saved.flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) } ?? Prefs()
        // Settings brought over from Halo are saved as Velyn's own straight away.
        if mine == nil, saved != nil, let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
