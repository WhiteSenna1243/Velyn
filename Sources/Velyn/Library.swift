import AppKit
import ScriptingBridge
import Combine

// MARK: - Songs

/// A song Velyn can play: one in your Music library (by its persistent ID) or a Spotify track link.
struct Song: Codable, Hashable, Identifiable {
    enum Source: Codable, Hashable {
        case music(String)       // Music persistent ID (hex)
        case spotify(String)     // "spotify:track:<id>"
    }

    var title: String
    var artist: String
    var album: String
    var duration: Double
    var source: Source
    /// Music only: the playlist the song was found in (persistent ID). nil = it's in your library.
    /// Songs from Apple Music playlists often aren't in the library, so they're played inside their playlist.
    var playlist: String? = nil

    var id: String {
        switch source {
        case .music(let p): return "m:" + p
        case .spotify(let u): return "s:" + u
        }
    }
    var isSpotify: Bool { if case .spotify = source { return true } else { return false } }
    var track: Track { Track(title: title, artist: artist, album: album, duration: duration, isSpotify: isSpotify) }
}

/// Spotify can't be searched without a Spotify developer login, but a pasted song link can be played.
enum SpotifyLink {
    /// "https://open.spotify.com/track/<id>?si=…", "https://open.spotify.com/intl-de/track/<id>" or
    /// "spotify:track:<id>" -> "spotify:track:<id>".
    static func uri(from text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [#"open\.spotify\.com/(?:intl-[a-zA-Z-]+/)?track/([A-Za-z0-9]{10,32})"#, #"^spotify:track:([A-Za-z0-9]{10,32})$"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { continue }
            return "spotify:track:" + s[r]
        }
        return nil
    }

    /// The song's title from Spotify's public link preview (no login needed).
    static func title(of uri: String) async -> String? {
        let id = uri.replacingOccurrences(of: "spotify:track:", with: "")
        guard var c = URLComponents(string: "https://open.spotify.com/oembed") else { return nil }
        c.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/track/\(id)")]
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["title"] as? String
    }
}

// MARK: - Queue

/// Velyn's own "up next" list. Music and Spotify don't let other apps add to their queues, so Velyn
/// keeps one and plays the next song itself when the current one ends (or when you press Next in Velyn).
/// After the queue runs out, the player carries on as it normally would.
final class PlayQueue: ObservableObject {
    struct Entry: Codable, Hashable, Identifiable {
        var id = UUID()
        var song: Song
    }

    @Published private(set) var entries: [Entry] = [] {
        didSet { save() }
    }
    private let key: String?

    /// `key` = where it's saved between launches (nil in tests).
    init(saveKey: String? = "velyn.queue") {
        key = saveKey
        if let key, let data = UserDefaults.standard.data(forKey: key),
           let e = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = e
        }
    }

    var isEmpty: Bool { entries.isEmpty }
    var first: Song? { entries.first?.song }

    func append(_ s: Song) { entries.append(Entry(song: s)) }
    func playNext(_ s: Song) { entries.insert(Entry(song: s), at: 0) }
    func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    func move(from: IndexSet, to: Int) { entries.move(fromOffsets: from, toOffset: to) }
    func clear() { entries.removeAll() }

    func popFirst() -> Song? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst().song
    }

    private func save() {
        guard let key else { return }
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Music library

/// Your Music library, read once (a few seconds for a big library, off the main thread) and then
/// searched on the Mac as you type. Read again when you come back after 10 minutes.
final class MusicLibrary: ObservableObject {
    static let shared = MusicLibrary()
    init() {}

    enum Status: Equatable { case idle, loading, ready, notRunning, failed }

    @Published private(set) var status = Status.idle
    @Published private(set) var count = 0
    @Published private(set) var playlists: [Playlist] = []

    /// One of your playlists (not folders or Music's built-in lists).
    struct Playlist: Identifiable, Hashable {
        let id: String              // persistent ID
        let name: String
        let songs: [Song]
    }

    struct Loaded {
        var library: [Song]
        var playlists: [Playlist]
    }

    private struct Entry {
        let song: Song
        let title: String, artist: String, album: String     // folded for matching
    }
    private var entries: [Entry] = []
    private var loadedAt: Date?
    private let work = DispatchQueue(label: "velyn.library", qos: .userInitiated)
    static let musicID = "com.apple.Music"

    var musicRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicID).isEmpty }

    func refreshIfNeeded(force: Bool = false) {
        guard musicRunning else {
            if entries.isEmpty { status = .notRunning }
            return
        }
        if status == .loading { return }
        if !force, status == .ready, let t = loadedAt, Date().timeIntervalSince(t) < 20 { return }
        if entries.isEmpty { status = .loading }
        work.async {
            let loaded = Self.load()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let loaded {
                    self.set(loaded)
                    self.status = .ready
                } else if self.entries.isEmpty {
                    self.status = self.musicRunning ? .failed : .notRunning
                }
            }
        }
    }

    /// The loader's last step: everything searchable is the library plus every playlist's songs
    /// (each song once; the library copy wins).
    func set(_ loaded: Loaded, ready: Bool = false) {
        var seen = Set<String>()
        var all: [Song] = []
        for s in loaded.library + loaded.playlists.flatMap(\.songs) where seen.insert(s.id).inserted { all.append(s) }
        playlists = loaded.playlists
        set(all, ready: ready)
    }

    /// Test hook.
    func set(_ songs: [Song], ready: Bool = false) {
        if ready { status = .ready }
        entries = songs.map { Entry(song: $0, title: Self.fold($0.title), artist: Self.fold($0.artist), album: Self.fold($0.album)) }
        count = entries.count
        loadedAt = Date()
    }

    /// Every word must appear in the title, artist or album. Titles that start with what you typed come first.
    func search(_ query: String, limit: Int = 80) -> [Song] {
        let q = Self.fold(query).trimmingCharacters(in: .whitespaces)
        let words = q.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var hits: [(Song, Int)] = []
        for e in entries {
            let all = e.title + " " + e.artist + " " + e.album
            guard words.allSatisfy({ all.contains($0) }) else { continue }
            var score = 0
            if e.title == q { score += 100 }
            if e.title.hasPrefix(q) { score += 60 } else if e.title.contains(q) { score += 40 }
            if e.artist.hasPrefix(q) { score += 30 } else if e.artist.contains(q) { score += 15 }
            if e.album.contains(q) { score += 8 }
            hits.append((e.song, score))
        }
        hits.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending }
        return hits.prefix(limit).map(\.0)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Reads your library and every playlist: name, artist, album, length and ID of each song. Scripting
    /// Bridge sends one Apple event per property for a whole list, so it's quick even for big libraries.
    static func load() -> Loaded? {
        guard let app = SBApplication(bundleIdentifier: musicID), app.isRunning,
              let all = app.value(forKey: "playlists") as? SBElementArray else { return nil }
        func values(_ list: SBElementArray, _ name: String) -> [Any] { list.array(byApplying: NSSelectorFromString(name)) }
        let ids = values(all, "persistentID").map { $0 as? String ?? "" }
        let names = values(all, "name").map { $0 as? String ?? "" }
        let kinds = values(all, "specialKind").map(fourCC)
        guard names.count == ids.count, kinds.count == ids.count else { return nil }

        var library: [Song] = []
        var playlists: [Playlist] = []
        for i in ids.indices where !ids[i].isEmpty {
            let isLibrary = kinds[i] == code("kSpL")
            guard isLibrary || kinds[i] == code("kNon"),
                  let pl = all.object(at: i) as? SBObject,
                  let tracks = pl.value(forKey: "tracks") as? SBElementArray,
                  let songs = songs(in: tracks, playlist: isLibrary ? nil : ids[i]) else { continue }
            if isLibrary {
                if library.isEmpty { library = songs }
            } else if !songs.isEmpty {
                playlists.append(Playlist(id: ids[i], name: names[i], songs: songs))
            }
        }
        return Loaded(library: library, playlists: playlists)
    }

    private static func songs(in tracks: SBElementArray, playlist: String?) -> [Song]? {
        func values(_ name: String) -> [Any] { tracks.array(byApplying: NSSelectorFromString(name)) }
        let ids = values("persistentID").map { $0 as? String ?? "" }
        guard !ids.isEmpty else { return [] }
        let names = values("name"), artists = values("artist"), albums = values("album"), durations = values("duration")
        guard names.count == ids.count, artists.count == ids.count, albums.count == ids.count,
              durations.count == ids.count else { return nil }
        var out: [Song] = []
        out.reserveCapacity(ids.count)
        for i in ids.indices where !ids[i].isEmpty {
            out.append(Song(title: names[i] as? String ?? "", artist: artists[i] as? String ?? "",
                            album: albums[i] as? String ?? "", duration: (durations[i] as? NSNumber)?.doubleValue ?? 0,
                            source: .music(ids[i]), playlist: playlist))
        }
        return out
    }

    /// Music's four-letter codes (special playlist kinds come back as numbers or descriptors).
    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func fourCC(_ v: Any) -> UInt32 {
        if let d = v as? NSAppleEventDescriptor { return d.enumCodeValue }
        if let n = v as? NSNumber { return n.uint32Value }
        return 0
    }
}

// MARK: - Apple Music catalogue

/// Songs from the whole Apple Music catalogue (Apple's public search API, no login). Music's
/// scripting can only play songs that are in your library, so these open in Music instead.
struct CatalogSong: Identifiable, Hashable {
    let id: Int                 // Apple's track id
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let artwork: URL?
    let link: URL               // opens the song in the Music app

    static func search(_ query: String, limit: Int = 25) async -> [CatalogSong] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, var c = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        let country = (Locale.current.region?.identifier ?? "US").lowercased()
        c.queryItems = [URLQueryItem(name: "term", value: q), URLQueryItem(name: "entity", value: "song"),
                        URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "country", value: country)]
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let id = r["trackId"] as? Int, let album = r["collectionId"] as? Int,
                  let link = URL(string: "music://music.apple.com/\(country)/album/\(album)?i=\(id)") else { return nil }
            return CatalogSong(id: id, title: r["trackName"] as? String ?? "", artist: r["artistName"] as? String ?? "",
                               album: r["collectionName"] as? String ?? "",
                               duration: ((r["trackTimeMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                               artwork: (r["artworkUrl60"] as? String).flatMap(URL.init(string:)), link: link)
        }
    }
}
