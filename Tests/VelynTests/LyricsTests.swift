import Foundation
import Testing
@testable import Velyn

// MARK: - LRC parsing

@Suite struct LRCTests {
    @Test func parsesTimesAndText() {
        let lines = LRC.parse("""
        [ar:Someone]
        [00:01.50] First line here
        [00:04.00]Second line
        """, duration: 10)
        #expect(lines.count == 2)
        #expect(lines[0].start == 1.5)
        #expect(lines[0].text == "First line here")
        #expect(lines[0].end == 4.0)          // runs until the next line
        #expect(lines[1].end == 10)           // the last line runs to the end of the song
    }

    @Test func repeatedStampsAndSorting() {
        let lines = LRC.parse("""
        [00:10.00]Later
        [00:02.00][00:06.00]Chorus
        """, duration: 20)
        #expect(lines.map(\.start) == [2, 6, 10])
        #expect(lines.map(\.text) == ["Chorus", "Chorus", "Later"])
    }

    @Test func wordTimesStayInsideTheLine() {
        let line = LRC.parse("[01:00.00]one two three four\n[01:05.00]next", duration: 90)[0]
        #expect(line.start == 60)
        #expect(line.words.count == 4)
        #expect(line.words.first?.start == 60)
        for (a, b) in zip(line.words, line.words.dropFirst()) { #expect(a.end <= b.start + 1e-9) }
        #expect(line.words.last!.end <= 65)
    }

    @Test func emptyLineHasNoWords() {
        let lines = LRC.parse("[00:01.00]Hello\n[00:03.00]\n[00:09.00]Again", duration: 12)
        #expect(lines.count == 3)
        #expect(lines[1].words.isEmpty)
    }
}

// MARK: - Matching

@Suite struct MatchingTests {
    @Test func cleansTitles() {
        #expect(LyricsClient.clean("Money - 2011 Remaster") == "Money")
        #expect(LyricsClient.clean("Song (feat. Someone)") == "Song")
        #expect(LyricsClient.clean("Song [Live]") == "Song")
        #expect(LyricsClient.clean("(Untitled)") == "(Untitled)")
    }

    @Test func mainArtist() {
        #expect(LyricsClient.mainArtist("A, B") == "A")
        #expect(LyricsClient.mainArtist("A & B") == "A")
        #expect(LyricsClient.mainArtist("A feat. B") == "A")
        #expect(LyricsClient.mainArtist("Lil Nas X") == "Lil Nas X")
    }

    @Test func namesCompareWithoutAccentsOrPunctuation() {
        #expect(LyricsClient.match("Beyoncé") == LyricsClient.match("BEYONCE"))
        #expect(LyricsClient.match("Simon & Garfunkel") == LyricsClient.match("simon and garfunkel"))
    }

    private func c(_ id: Int, _ title: String = "Halo", _ artist: String = "Beyoncé", d: Double,
                   synced: Bool = true, instrumental: Bool = false) -> LyricsCandidate {
        LyricsCandidate(id: id, title: title, artist: artist, duration: d,
                        synced: synced ? "[00:01.00]words" : nil, instrumental: instrumental)
    }

    @Test func picksTheClosestLength() {
        let best = LyricsClient.best([c(1, d: 250), c(2, d: 262), c(3, d: 259)],
                                     title: "Halo", artist: "Beyonce", duration: 261)
        #expect(best?.id == 2)
    }

    @Test func skipsOtherVersionsAndSongs() {
        #expect(LyricsClient.best([c(1, d: 300)], title: "Halo", artist: "Beyoncé", duration: 261) == nil)   // 39 s longer
        #expect(LyricsClient.best([c(1, "Halo", "Someone Else", d: 261)], title: "Halo", artist: "Beyoncé", duration: 261) == nil)
        #expect(LyricsClient.best([c(1, "Halo Again", "Beyoncé", d: 261)], title: "Halo", artist: "Beyoncé", duration: 261) == nil)
    }

    @Test func prefersWordsOverInstrumentalFlag() {
        let best = LyricsClient.best([c(1, d: 261, synced: false, instrumental: true), c(2, d: 262)],
                                     title: "Halo", artist: "Beyoncé", duration: 261)
        #expect(best?.id == 2)
        let only = LyricsClient.best([c(1, d: 261, synced: false, instrumental: true)],
                                     title: "Halo", artist: "Beyoncé", duration: 261)
        #expect(only?.result == .instrumental)
    }

    @Test func untimedLyricsAreNotUsed() {
        #expect(LyricsClient.best([c(1, d: 261, synced: false)], title: "Halo", artist: "Beyoncé", duration: 261) == nil)
    }

    @Test func remasterTitleStillMatches() {
        let best = LyricsClient.best([c(7, "Money", "Pink Floyd", d: 383)],
                                     title: "Money - 2011 Remaster", artist: "Pink Floyd", duration: 382)
        #expect(best?.id == 7)
    }

    @Test func rankedPutsMatchesFirst() {
        let list = LyricsClient.ranked([c(1, d: 330), c(2, d: 262), c(3, "Other", "X", d: 261)],
                                       title: "Halo", artist: "Beyoncé", duration: 261)
        #expect(list.first?.id == 2)
        #expect(list.count == 3)
    }

    @Test func readsLRCLIBJSON() {
        let json: [String: Any] = ["id": 42, "trackName": "Halo", "artistName": "Beyoncé", "albumName": "I Am...",
                                   "duration": 261.0, "instrumental": false, "syncedLyrics": "  "]
        let cand = LyricsCandidate(json: json)
        #expect(cand?.id == 42)
        #expect(cand?.synced == nil)          // blank lyrics count as none
        #expect(cand?.usable == false)
        #expect(LyricsCandidate(json: ["trackName": "No id"]) == nil)
    }
}

// MARK: - Saved lyrics

@Suite(.serialized) struct StoreTests {
    let track = Track(title: "Halo", artist: "Beyoncé", duration: 261)

    init() throws {
        LyricsStore.folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("velyn-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func savesAndLoads() {
        LyricsStore.save(.synced(id: 5, lrc: "[00:01.00]hi"), for: track)
        #expect(LyricsStore.load(track) == .synced(id: 5, lrc: "[00:01.00]hi"))
        var other = track
        other.duration = 300                  // another version of the song
        #expect(LyricsStore.load(other) == nil)
    }

    @Test func offlineIsNeverSaved() {
        LyricsStore.save(.offline, for: track)
        #expect(LyricsStore.load(track) == nil)
    }

    @Test func nothingFoundIsTriedAgainLater() {
        let now = Date()
        LyricsStore.save(.missing, for: track, now: now)
        #expect(LyricsStore.load(track, now: now.addingTimeInterval(60)) == .missing)
        #expect(LyricsStore.load(track, now: now.addingTimeInterval(LyricsStore.missingLifetime + 1)) == nil)
    }

    @Test func handPickWins() {
        LyricsStore.save(.synced(id: 9, lrc: "[00:01.00]picked"), for: track, picked: true)
        LyricsStore.save(.synced(id: 1, lrc: "[00:01.00]auto"), for: track)
        #expect(LyricsStore.load(track) == .synced(id: 9, lrc: "[00:01.00]picked"))
        var other = track
        other.duration = 300
        #expect(LyricsStore.load(other) != nil)       // a pick is kept even if the length differs
        LyricsStore.forget(track)
        #expect(LyricsStore.load(track) == nil)
    }
}

// MARK: - Spotlight style

@Suite struct SpotlightStyleTests {
    private func line(_ s: Double, _ e: Double, _ text: String) -> LyricLine {
        LyricLine(start: s, end: e, words: text.isEmpty ? [] : [LyricWord(text: text, start: s, end: s + 0.5)])
    }

    @Test func addsDotsForIntroAndLongGaps() {
        let items = SpotlightSim.items([line(5, 8, "a"), line(8, 9, ""), line(9, 20, "b"), line(20, 25, "c")])
        #expect(items.map { $0.words.isEmpty } == [true, false, false, true, false])
        #expect(items[0].start == 0)              // intro dots before a late first line
        #expect(items[3].start == 9.5 + 1.5)      // dots in the break after "b"
    }

    @Test func noDotsForShortGaps() {
        let items = SpotlightSim.items([line(1, 3, "a"), line(3, 4, ""), line(4, 6, "b")])
        #expect(items.allSatisfy { !$0.words.isEmpty })
    }
}

// MARK: - Settings

@Suite struct PrefsTests {
    @Test func emptyOrBrokenSettingsFallBackToDefaults() throws {
        let p = try JSONDecoder().decode(Prefs.self, from: Data(#"{"thickness": "oops", "unknown": 1}"#.utf8))
        #expect(p == Prefs())
    }

    /// Every setting must survive saving and loading (catches a field missing from CodingKeys or init(from:)).
    @Test func everySettingRoundTrips() throws {
        var p = Prefs()
        p.glowEnabled = false; p.gradientColors = 1; p.glowMode = .idle; p.glowStyle = .classic
        p.glowFollowsApp = false; p.notchCompat = true; p.thickness = 0.7; p.glow = 0.4; p.brightness = 0.5
        p.overrideAlbum = true; p.primaryH = 0.1; p.primaryS = 0.2; p.primaryB = 0.3
        p.secondaryH = 0.4; p.secondaryS = 0.5; p.secondaryB = 0.6; p.primaryShare = 0.3
        p.glowDisplays = [1, 2]; p.audioReactive = false; p.syncStyle = .pulse; p.syncSensitivity = 1.7
        p.lockScreen = false; p.lockLook = .lyrics; p.lockDisplayLooks = ["1": .player]; p.lockBackground = .white; p.showInDock = false; p.motionArt = false; p.checkUpdates = false; p.hotKeys = false; p.phoneRemote = true; p.songBanners = true
        p.showStage = false; p.lyricStyle = .spotlight; p.lyricArt = true; p.lyricFont = .futura; p.lyricMotion = 1.2; p.lyricSize = 1.3
        p.autoSync = false; p.lyricColor = RGB(r: 0.1, g: 0.2, b: 0.3); p.highlightColor = RGB(r: 0.4, g: 0.5, b: 0.6)
        p.secondaryColor = RGB(r: 0.7, g: 0.8, b: 0.9); p.lyricLead = 0.75; p.lyricOffsets = ["a|b": 0.5]; p.keepAwake = false

        // The test itself must change every field, so a new setting can't slip through untested.
        let changed = zip(Mirror(reflecting: p).children, Mirror(reflecting: Prefs()).children)
            .filter { String(describing: $0.value) == String(describing: $1.value) }
            .map { $0.0.label ?? "?" }
        #expect(changed.isEmpty, "add these to the test: \(changed)")

        let back = try JSONDecoder().decode(Prefs.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    /// Settings saved by Halo (the earlier build) still load, with the new names.
    @Test func oldHaloSettingsLoad() throws {
        let old = #"{"lyricStyle": "Fisheye Visual", "glowMode": "Music Sync", "syncStyle": "Energic", "glowStyle": "Classic", "glowFollowsHalo": false, "thickness": 0.5}"#
        let p = try JSONDecoder().decode(Prefs.self, from: Data(old.utf8))
        #expect(p.lyricStyle == .lens)
        #expect(p.lyricArt)
        #expect(p.glowMode == .musicSync)
        #expect(p.syncStyle == .energy)
        #expect(p.glowStyle == .classic)
        #expect(p.glowFollowsApp == false)
        #expect(p.thickness == 0.5)
        let ship = try JSONDecoder().decode(Prefs.self, from: Data(#"{"lyricStyle": "Ship"}"#.utf8))
        #expect(ship.lyricStyle == .stream && !ship.lyricArt)
    }

    @Test func updateVersionsCompareAsNumbers() {
        #expect(Updates.isNewer("1.10", than: "1.9"))
        #expect(Updates.isNewer("2.0", than: "1.9.9"))
        #expect(!Updates.isNewer("1.0", than: "1.0"))
    }
}

// MARK: - Search & queue

@Suite struct LibraryTests {
    private func song(_ t: String, _ a: String, _ al: String = "", id: Int) -> Song {
        Song(title: t, artist: a, album: al, duration: 200, source: .music(String(format: "%016X", id)))
    }

    @Test func searchRanksTitlesFirst() {
        let lib = MusicLibrary()
        lib.set([song("Halo", "Beyoncé", "I Am... Sasha Fierce", id: 1), song("Halo Theme", "Someone", id: 2),
                 song("Love", "Halo Band", id: 3), song("Paper Moon", "Other", id: 4)])
        let r = lib.search("halo")
        #expect(r.map(\.title) == ["Halo", "Halo Theme", "Love"])     // exact, then starts-with, then artist
        #expect(lib.search("beyonce sasha").map(\.title) == ["Halo"])  // every word, accents ignored
        #expect(lib.search("   ").isEmpty)
        #expect(lib.search("zzz").isEmpty)
    }

    @Test func spotifyLinks() {
        #expect(SpotifyLink.uri(from: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc") == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(SpotifyLink.uri(from: "https://open.spotify.com/intl-de/track/4uLU6hMCjMI75M1A2tKUQC") == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(SpotifyLink.uri(from: " spotify:track:4uLU6hMCjMI75M1A2tKUQC ") == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(SpotifyLink.uri(from: "https://open.spotify.com/album/4uLU6hMCjMI75M1A2tKUQC") == nil)
        #expect(SpotifyLink.uri(from: "paper lanterns") == nil)
        #expect(SpotifyLink.uri(from: "spotify:track:abc\" & do shell script \"x") == nil)   // nothing odd reaches a script
    }

    @Test func playlistSongsAreSearchable() {
        let lib = MusicLibrary()
        let inLib = song("Halo", "Beyoncé", id: 1)
        var fromList = song("River Song", "Other", id: 2)
        fromList.playlist = "00000000000000B1"
        var dup = inLib
        dup.playlist = "00000000000000B1"
        lib.set(MusicLibrary.Loaded(library: [inLib],
                                    playlists: [MusicLibrary.Playlist(id: "00000000000000B1", name: "Mix", songs: [dup, fromList])]))
        #expect(lib.count == 2)                                   // each song once
        #expect(lib.search("halo").first?.playlist == nil)        // the library copy wins
        #expect(lib.search("river").first?.playlist == "00000000000000B1")
        #expect(lib.playlists.count == 1)
    }

    @Test func oldQueueStillLoads() throws {
        // A queued song saved before songs remembered their playlist.
        let json = #"{"title":"A","artist":"x","album":"","duration":200,"source":{"music":{"_0":"0000000000000001"}}}"#
        let s = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        #expect(s.playlist == nil && s.title == "A")
    }

    @Test func queueOrder() {
        let q = PlayQueue(saveKey: nil)
        let a = song("A", "x", id: 1), b = song("B", "x", id: 2), c = song("C", "x", id: 3)
        q.append(a); q.append(b); q.playNext(c)
        #expect(q.entries.map(\.song.title) == ["C", "A", "B"])
        q.move(from: IndexSet(integer: 2), to: 0)
        #expect(q.entries.map(\.song.title) == ["B", "C", "A"])
        q.remove(q.entries[1].id)
        #expect(q.popFirst()?.title == "B")
        #expect(q.entries.map(\.song.title) == ["A"])
        q.append(a)                                   // the same song twice is fine
        #expect(q.entries.count == 2)
        q.clear()
        #expect(q.isEmpty && q.popFirst() == nil)
    }
}

// MARK: - Phone remote

@Suite struct RemoteTests {
    @Test func parsesGetAndPost() throws {
        let get = try #require(HTTPRequest.parse(Data("GET /api/search?q=paper%20moon&k=abc HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        #expect(get.method == "GET" && get.path == "/api/search")
        #expect(get.query["q"] == "paper moon" && get.query["k"] == "abc")
        let body = #"{"action":"next"}"#
        let post = try #require(HTTPRequest.parse(Data("POST /api/control HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)))
        #expect(post.json["action"] as? String == "next")
    }

    @Test func waitsForTheWholeRequest() {
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)                    // headers not done
        #expect(HTTPRequest.parse(Data("POST /a HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)) == nil)  // body not done
        #expect(HTTPRequest.parse(Data("\r\n\r\n".utf8)) == nil)                                          // not HTTP
    }

    @Test func secretKey() {
        let a = PhoneRemote.makeToken(), b = PhoneRemote.makeToken()
        #expect(a.count == 22 && a != b)
        #expect(PhoneRemote.sameKey(a, a))
        #expect(!PhoneRemote.sameKey(a, b))
        #expect(!PhoneRemote.sameKey("", ""))
        #expect(!PhoneRemote.sameKey(a, String(a.dropLast())))
    }

    @Test func songsRoundTripThroughThePage() {
        var s = Song(title: "A", artist: "B", album: "C", duration: 200, source: .music("00000000000000AB"))
        s.playlist = "00000000000000B1"
        let row = PhoneRemote.row(s)
        #expect(PhoneRemote.song(row["song"]) == s)
        #expect(PhoneRemote.song(["title": "x"]) == nil)
        #expect(PhoneRemote.song(nil) == nil)
    }

    @Test func pairingQRCode() {
        #expect(PhoneRemote.qrCode(URL(string: "http://mac.local:47820/?k=abc")!) != nil)
    }
}
