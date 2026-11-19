import Foundation
import CryptoKit
import Network

/// What a lyrics lookup found.
enum LyricsResult: Equatable {
    case synced(id: Int?, lrc: String)
    case instrumental
    case missing     // nothing usable for this song
    case offline     // LRCLIB couldn't be reached: try again later
}

/// One version of a song's lyrics on LRCLIB.
struct LyricsCandidate: Equatable, Identifiable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let synced: String?        // LRC text; nil when LRCLIB only has untimed lyrics
    let instrumental: Bool

    init(id: Int, title: String, artist: String, album: String = "", duration: Double,
         synced: String?, instrumental: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.synced = synced
        self.instrumental = instrumental
    }

    init?(json: [String: Any]) {
        guard let id = (json["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        title = json["trackName"] as? String ?? json["name"] as? String ?? ""
        artist = json["artistName"] as? String ?? ""
        album = json["albumName"] as? String ?? ""
        duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
        let lrc = (json["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        synced = (lrc?.isEmpty ?? true) ? nil : lrc
        instrumental = json["instrumental"] as? Bool ?? false
    }

    /// Timed lyrics, or marked as having no words.
    var usable: Bool { synced != nil || instrumental }

    var result: LyricsResult {
        if let synced { return .synced(id: id, lrc: synced) }
        return instrumental ? .instrumental : .missing
    }
}

// MARK: - LRCLIB

/// Looks lyrics up on LRCLIB (free, no account). Only timed lyrics are used.
enum LyricsClient {
    private static let base = "https://lrclib.net/api"
    /// Versions longer or shorter than this are skipped automatically (a radio edit or a
    /// live take would be out of time). They can still be picked by hand.
    static let maxLengthGap = 8.0

    /// Finds the best timed lyrics for a song.
    static func lookup(title: String, artist: String, duration: Double) async -> LyricsResult {
        // 1. Exact match by title, artist and length (LRCLIB allows about ±2 s).
        if duration > 0 {
            for t in titleVariants(title) {
                guard case .ok(let json) = await request("/get", [
                    "track_name": t, "artist_name": artist, "duration": String(Int(duration.rounded()))
                ]) else { continue }
                if let c = (json as? [String: Any]).flatMap(LyricsCandidate.init(json:)), c.usable {
                    return c.result
                }
            }
        }
        // 2. Search, then take the closest version.
        guard let found = await search(title: title, artist: artist) else { return .offline }
        return best(found, title: title, artist: artist, duration: duration)?.result ?? .missing
    }

    /// Versions to offer in "Lyrics for This Song": timed or instrumental, best match first.
    /// nil when LRCLIB couldn't be reached.
    static func choices(title: String, artist: String, duration: Double) async -> [LyricsCandidate]? {
        guard let found = await search(title: title, artist: artist, broad: true) else { return nil }
        var seen = Set<String>()     // LRCLIB often has the same lyrics several times
        return Array(ranked(found.filter(\.usable), title: title, artist: artist, duration: duration)
            .filter { seen.insert($0.synced ?? "instrumental \(match($0.title))").inserted }
            .prefix(15))
    }

    /// Every version LRCLIB lists for this song. `broad` also runs a free-text search.
    static func search(title: String, artist: String, broad: Bool = false) async -> [LyricsCandidate]? {
        let name = clean(title)
        let main = mainArtist(artist)
        var queries: [[String: String]] = [["track_name": name, "artist_name": artist]]
        if main != artist { queries.append(["track_name": name, "artist_name": main]) }
        if broad { queries.append(["q": "\(main) \(name)"]) }

        var all: [LyricsCandidate] = []
        var reached = false
        for q in queries {
            switch await request("/search", q) {
            case .ok(let json):
                reached = true
                all += (json as? [[String: Any]] ?? []).compactMap(LyricsCandidate.init(json:))
            case .notFound:
                reached = true
            case .failed:
                continue
            }
        }
        guard reached else { return nil }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
    }

    // MARK: Matching

    /// The version to use: same title and artist, closest length, timed lyrics preferred.
    static func best(_ cs: [LyricsCandidate], title: String, artist: String, duration: Double) -> LyricsCandidate? {
        cs.filter(\.usable)
            .compactMap { c in score(c, title: title, artist: artist, duration: duration).map { (c, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    /// All versions, matches first (best first), then the rest by length.
    static func ranked(_ cs: [LyricsCandidate], title: String, artist: String, duration: Double) -> [LyricsCandidate] {
        cs.map { c in (c, score(c, title: title, artist: artist, duration: duration)
                          ?? 1000 + abs(c.duration - duration)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Lower is better; nil = not this song.
    static func score(_ c: LyricsCandidate, title: String, artist: String, duration: Double) -> Double? {
        let want = match(clean(title)), got = match(clean(c.title))
        guard !want.isEmpty, want == got else { return nil }
        let a = match(mainArtist(artist)), b = match(c.artist)
        guard a.isEmpty || b.isEmpty || b.contains(a) || a.contains(b) else { return nil }
        var s = 0.0
        if duration > 0, c.duration > 0 {
            let gap = abs(c.duration - duration)
            guard gap <= maxLengthGap else { return nil }
            s += gap
        }
        if match(c.artist) != match(artist) { s += 1 }
        if match(c.title) != match(title) { s += 0.5 }    // "(Remastered)" etc. differ
        if c.synced == nil { s += 3 }                      // the flag is sometimes wrong: words win unless 3 s further off
        return s
    }

    /// "Song - Remastered 2011" / "Song (feat. X)" / "Song [Live]" -> "Song"
    static func clean(_ title: String) -> String {
        var t = title
        for cut in [" - ", " (", " ["] {
            if let r = t.range(of: cut), r.lowerBound > t.startIndex { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "A, B" / "A & B" / "A feat. B" -> "A"
    static func mainArtist(_ artist: String) -> String {
        var a = artist
        for cut in [", ", " & ", " feat. ", " feat ", " ft. ", " featuring ", " with ", " x ", " X "] {
            if let r = a.range(of: cut), r.lowerBound > a.startIndex { a = String(a[..<r.lowerBound]) }
        }
        return a.trimmingCharacters(in: .whitespaces)
    }

    /// For comparing names: no case, accents or punctuation, "&" = "and".
    static func match(_ s: String) -> String {
        let t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: "and")
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func titleVariants(_ title: String) -> [String] {
        let c = clean(title)
        return c.isEmpty || c == title ? [title] : [title, c]
    }

    // MARK: Network

    private enum Reply { case ok(Any), notFound, failed }

    private static func request(_ path: String, _ items: [String: String]) async -> Reply {
        var comps = URLComponents(string: base + path)
        comps?.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps?.url else { return .failed }
        var req = URLRequest(url: url)
        req.setValue("Velyn/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .failed }
        if http.statusCode == 404 { return .notFound }
        guard http.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) else { return .failed }
        return .ok(json)
    }
}

// MARK: - Saved lyrics

/// Lyrics saved on this Mac, one small file per song in ~/Library/Application Support/Velyn/Lyrics,
/// so songs you've played before show lyrics at once, even offline.
enum LyricsStore {
    struct Entry: Codable, Equatable {
        var id: Int?
        var lrc: String?            // nil = no timed lyrics
        var instrumental = false
        var duration: Double
        var picked = false          // chosen by hand in "Lyrics for This Song"
        var saved = Date()
    }

    /// "Nothing found" is looked up again after this long (LRCLIB keeps growing).
    static let missingLifetime: TimeInterval = 3 * 86_400
    static let maxFiles = 3000

    static var folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Velyn/Lyrics", isDirectory: true)

    static func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".json")
    }

    static func entry(for track: Track) -> Entry? {
        guard let data = try? Data(contentsOf: file(track.key)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    /// Saved lyrics for this song; nil if there are none, or they're for another version or out of date.
    static func load(_ track: Track, now: Date = Date()) -> LyricsResult? {
        guard let e = entry(for: track), let r = result(e, track: track, now: now) else { return nil }
        // Recently played songs are the last to be cleaned up.
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file(track.key).path)
        return r
    }

    static func result(_ e: Entry, track: Track, now: Date) -> LyricsResult? {
        if !e.picked, track.duration > 0, e.duration > 0, abs(track.duration - e.duration) > 3 { return nil }
        if let lrc = e.lrc { return .synced(id: e.id, lrc: lrc) }
        if e.instrumental { return .instrumental }
        return now.timeIntervalSince(e.saved) < missingLifetime ? .missing : nil
    }

    static func save(_ r: LyricsResult, for track: Track, picked: Bool = false, now: Date = Date()) {
        var e = Entry(duration: track.duration, picked: picked, saved: now)
        switch r {
        case .synced(let id, let lrc): e.id = id; e.lrc = lrc
        case .instrumental: e.instrumental = true
        case .missing: break
        case .offline: return
        }
        // An automatic lookup never replaces lyrics you picked by hand.
        if !picked, let old = entry(for: track), old.picked { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: file(track.key), options: .atomic) }
    }

    static func forget(_ track: Track) {
        try? FileManager.default.removeItem(at: file(track.key))
    }

    /// Keeps the folder small: removes the least recently played songs past `maxFiles`.
    static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > maxFiles else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxFiles) {
            try? fm.removeItem(at: url)
        }
    }
}

// MARK: - Connection

/// Calls `onOnline` when the Mac gets its internet connection back.
final class NetworkWatch {
    var onOnline: (() -> Void)?
    private let monitor = NWPathMonitor()
    private var wasOnline = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                if online && !self.wasOnline { self.onOnline?() }
                self.wasOnline = online
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    deinit { monitor.cancel() }
}
