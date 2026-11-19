import AppKit

enum RepeatMode: String {
    case off, all, one
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String = ""
    var duration: Double          // seconds
    var artworkURL: String?
    var isSpotify: Bool = true

    /// Stable per-song key: artist and title, letters and digits only.
    var key: String { MotionArtwork.norm(artist) + "|" + MotionArtwork.norm(title) }
}

struct PlaybackState {
    var track: Track?
    var position: Double          // seconds, at `sampledAt`
    var isPlaying: Bool
    var sampledAt: Date
    var shuffle = false
    var repeatMode = RepeatMode.off
    var volume = 1.0              // 0...1
    var favorited = false

    static let idle = PlaybackState(track: nil, position: 0, isPlaying: false, sampledAt: Date())
}

enum PlayerCommand {
    case playPause, next, previous
    case seek(Double)
    case shuffle(Bool)
    case repeatMode(RepeatMode)
    case volume(Int)
    case favorite(Bool)
}

/// Escapes text for use inside an AppleScript string literal.
func asEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Polls Spotify / Apple Music via AppleScript once a second and sends them
/// commands. The apps are only touched when they are already running, so Velyn
/// never launches a player by itself.
///
/// AppleScript waits for the player to answer, sometimes for a long time. Every script runs on
/// one background queue, never the main thread, so the lyrics and the glow keep moving meanwhile.
/// Everything else here (`onUpdate`, `activeIsSpotify`, the calls in) is main thread only.
final class NowPlayingMonitor: @unchecked Sendable {
    var onUpdate: ((PlaybackState) -> Void)?
    private var timer: Timer?
    /// Which player produced the last state (nil until something plays).
    private(set) var activeIsSpotify: Bool?

    private let scripts = DispatchQueue(label: "velyn.applescript", qos: .userInitiated)
    /// Polls sent to `scripts` and not answered yet.
    private var polling = 0
    /// Goes up with every command. A poll that started before a command is out of date when it
    /// comes back (it could undo a pause shown straight away), so it is dropped.
    private var commandCount = 0

    private let spotifyID = "com.spotify.client"
    private let musicID = "com.apple.Music"

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // If the player is slow to answer, don't pile up more polls behind it.
            if self?.polling == 0 { self?.poll() }
        }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    var spotifyRunning: Bool { isRunning(spotifyID) }
    var musicRunning: Bool { isRunning(musicID) }

    /// Reads the players in the background; `onUpdate` gets the result on the main thread.
    func poll() {
        polling += 1
        let asked = commandCount
        scripts.async { [weak self] in
            guard let self else { return }
            var best: PlaybackState?
            if self.isRunning(self.spotifyID), let s = self.query(spotify: true) { best = s }
            if best?.isPlaying != true, self.isRunning(self.musicID), let m = self.query(spotify: false) {
                if best == nil || m.isPlaying { best = m }
            }
            DispatchQueue.main.async {
                self.polling -= 1
                guard asked == self.commandCount else { return }
                self.activeIsSpotify = best?.track?.isSpotify
                self.onUpdate?(best ?? .idle)
            }
        }
    }

    /// Runs a command script in the background, after anything already waiting.
    private func perform(_ source: String) {
        commandCount += 1
        scripts.async { [weak self] in self?.run(source) }
    }

    /// Scripts that run over and over (the once-a-second poll) are compiled once and kept.
    /// Compiling is the expensive part: macOS also runs a malware scan on every new script.
    /// Only touched on `scripts`.
    private var compiled: [String: NSAppleScript] = [:]

    @discardableResult
    private func run(_ source: String, keep: Bool = false) -> String? {
        var err: NSDictionary?
        let script: NSAppleScript
        if let s = compiled[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            if keep, s.compileAndReturnError(&err) { compiled[source] = s }
            err = nil
            script = s
        }
        let result = script.executeAndReturnError(&err)
        if let err { NSLog("Velyn: AppleScript error: \(err)") ; return nil }
        return result.stringValue ?? ""
    }

    private func query(spotify: Bool) -> PlaybackState? {
        let source: String
        if spotify {
            source = """
            tell application "Spotify"
                if player state is stopped then return "stopped"
                set t to current track
                return (player state as string) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (((duration of t) / 1000) as string) & "||" & (player position as string) & "||" & (artwork url of t) & "||" & (shuffling as string) & "||" & (repeating as string) & "||" & (sound volume as string) & "||false"
            end tell
            """
        } else {
            source = """
            tell application "Music"
                if player state is stopped then return "stopped"
                set t to current track
                set f to false
                try
                    set f to favorited of t
                end try
                set rp to "off"
                try
                    set rp to (song repeat as string)
                end try
                return (player state as string) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & ((duration of t) as string) & "||" & (player position as string) & "||" & "" & "||" & (shuffle enabled as string) & "||" & rp & "||" & (sound volume as string) & "||" & (f as string)
            end tell
            """
        }
        guard let str = run(source, keep: true), str != "stopped" else { return nil }

        let parts = str.components(separatedBy: "||")
        guard parts.count >= 11 else { return nil }
        func num(_ s: String) -> Double {
            Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        let art = parts[6].isEmpty ? nil : parts[6]
        let track = Track(title: parts[1], artist: parts[2], album: parts[3],
                          duration: num(parts[4]), artworkURL: art, isSpotify: spotify)
        let rep: RepeatMode
        if spotify { rep = parts[8] == "true" ? .all : .off }
        else { rep = RepeatMode(rawValue: parts[8]) ?? .off }

        return PlaybackState(track: track,
                             position: num(parts[5]),
                             isPlaying: parts[0] == "playing",
                             sampledAt: Date(),
                             shuffle: parts[7] == "true",
                             repeatMode: rep,
                             volume: max(0, min(1, num(parts[9]) / 100)),
                             favorited: parts[10] == "true")
    }

    // MARK: - Commands

    /// The player that commands should go to.
    private func targetApp() -> String? {
        if let s = activeIsSpotify {
            let name = s ? "Spotify" : "Music"
            if isRunning(s ? spotifyID : musicID) { return name }
        }
        if isRunning(musicID) { return "Music" }
        if isRunning(spotifyID) { return "Spotify" }
        return nil
    }

    func send(_ cmd: PlayerCommand) {
        guard let app = targetApp() else { return }
        let spotify = app == "Spotify"
        let body: String
        switch cmd {
        case .playPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .seek(let s): body = "set player position to \(String(format: "%.2f", max(0, s)))"
        case .shuffle(let on):
            body = spotify ? "set shuffling to \(on)" : "set shuffle enabled to \(on)"
        case .repeatMode(let m):
            body = spotify ? "set repeating to \(m != .off)" : "set song repeat to \(m.rawValue)"
        case .volume(let v): body = "set sound volume to \(max(0, min(100, v)))"
        case .favorite(let on):
            if spotify { return }
            body = """
            try
                set favorited of current track to \(on)
            on error
                try
                    set loved of current track to \(on)
                end try
            end try
            """
        }
        perform("tell application \"\(app)\"\n\(body)\nend tell")
    }

    /// Plays one song now: a Music library track or a Spotify link. Pauses the other player first,
    /// so only one plays. Returns false if the player it needs isn't open.
    @discardableResult
    func play(_ song: Song) -> Bool {
        switch song.source {
        case .music(let id):
            guard !id.isEmpty, id.allSatisfy(\.isHexDigit), isRunning(musicID) else { return false }
            if activeIsSpotify == true, isRunning(spotifyID) { perform("tell application \"Spotify\" to pause") }
            // A song from a playlist plays inside it (so the playlist carries on after it);
            // a library song plays from the library.
            let fromLibrary = "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"\(id)\")"
            if let pl = song.playlist, !pl.isEmpty, pl.allSatisfy(\.isHexDigit) {
                let inPlaylist = "tell application \"Music\" to play (first track of (first playlist whose persistent ID is \"\(pl)\") whose persistent ID is \"\(id)\")"
                commandCount += 1
                scripts.async { [weak self] in
                    if self?.run(inPlaylist) == nil { self?.run(fromLibrary) }
                }
            } else {
                perform(fromLibrary)
            }
            activeIsSpotify = false
        case .spotify(let uri):
            guard SpotifyLink.uri(from: uri) == uri else { return false }
            guard isRunning(spotifyID) else {
                // Spotify opens on that song; press play there.
                if let u = URL(string: uri) { NSWorkspace.shared.open(u) }
                return false
            }
            if activeIsSpotify == false, isRunning(musicID) { perform("tell application \"Music\" to pause") }
            perform("tell application \"Spotify\" to play track \"\(uri)\"")
            activeIsSpotify = true
        }
        return true
    }

    /// Plays one of your playlists from the start.
    func playPlaylist(_ id: String) {
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit), isRunning(musicID) else { return }
        if activeIsSpotify == true, isRunning(spotifyID) { perform("tell application \"Spotify\" to pause") }
        perform("tell application \"Music\" to play (first playlist whose persistent ID is \"\(id)\")")
        activeIsSpotify = false
    }

    /// The song after this one, so its lyrics and animated cover can load early.
    /// Apple Music only, with shuffle off (Spotify doesn't share its queue with other apps).
    /// `spotify` is `activeIsSpotify`, read on the main thread.
    func upNext(spotify: Bool?) async -> Track? {
        guard spotify == false, isRunning(musicID) else { return nil }
        return await withCheckedContinuation { done in
            scripts.async { [weak self] in done.resume(returning: self?.readUpNext()) }
        }
    }

    private func readUpNext() -> Track? {
        let source = """
        tell application "Music"
            try
                if shuffle enabled then return ""
                set pl to current playlist
                set i to index of current track
                if (persistent ID of track i of pl) is not (persistent ID of current track) then return ""
                set n to track (i + 1) of pl
                return (name of n) & "||" & (artist of n) & "||" & (album of n) & "||" & ((duration of n) as string)
            on error
                return ""
            end try
        end tell
        """
        guard let s = run(source, keep: true), !s.isEmpty else { return nil }
        let p = s.components(separatedBy: "||")
        guard p.count >= 4 else { return nil }
        return Track(title: p[0], artist: p[1], album: p[2],
                     duration: Double(p[3].replacingOccurrences(of: ",", with: ".")) ?? 0,
                     artworkURL: nil, isSpotify: false)
    }

    /// Apple Music has no artwork URL, so read the raw image bytes instead.
    func musicArtwork() async -> NSImage? {
        guard isRunning(musicID) else { return nil }
        return await withCheckedContinuation { done in
            scripts.async { [weak self] in done.resume(returning: self?.readArtwork()) }
        }
    }

    private func readArtwork() -> NSImage? {
        let source = """
        tell application "Music"
            try
                return data of artwork 1 of current track
            on error
                return missing value
            end try
        end tell
        """
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&err)
        guard err == nil else { return nil }
        return NSImage(data: result.data)
    }
}
