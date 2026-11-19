import SwiftUI
import AppKit
import IOKit.pwr_mgt

enum LyricsStatus {
    case idle, loading, found, missing, instrumental, offline

    /// What to show instead of lyrics: a title and a smaller line under it.
    var message: (title: String, detail: String) {
        switch self {
        case .idle, .found: return ("", "")
        case .loading: return ("Finding lyrics…", "")
        case .missing: return ("Lyrics not available", "No synced lyrics for this song.")
        case .instrumental: return ("Instrumental", "")
        case .offline: return ("Waiting for internet…", "Lyrics will load when you're back online.")
        }
    }
}

struct LyricColors: Equatable {
    var text: RGB
    var highlight: RGB
    var secondary: RGB
}

/// Owns playback state, lyrics, artwork, the Up Next queue and the audio level.
/// One Engine is shared by every Velyn window.
final class Engine: ObservableObject {
    @Published private(set) var state = PlaybackState.idle
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var lyricsStatus = LyricsStatus.idle
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette: (RGB, RGB)?
    /// Other versions of this song's lyrics ("Lyrics for This Song"); nil until looked up.
    @Published private(set) var lyricChoices: [LyricsCandidate]?
    @Published private(set) var lyricChoicesFailed = false
    /// LRCLIB id of the lyrics showing now.
    @Published private(set) var lyricsID: Int?

    /// Volume 0...1; follows the player unless you are dragging it.
    @Published var volume = 1.0

    let audio = AudioReactor()
    /// Velyn's own up-next list (see `PlayQueue`).
    let queue = PlayQueue()
    /// Animated album cover (Apple Music motion artwork), shared by every view that shows the art.
    let motion = MotionPlayer()
    private let monitor = NowPlayingMonitor()
    private weak var settings: Settings?
    private var started = false
    private var lyricTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var choicesTask: Task<Void, Never>?
    private let network = NetworkWatch()
    private var retryWork: DispatchWorkItem?
    private var queueWork: DispatchWorkItem?
    private var lastQueueAdvance = Date.distantPast
    private var retryDelay = 15.0
    private var lastPlayingAt = Date()
    private var bannerArmed = false        // no banner for the song already playing at launch
    /// Sleep timer: pause at this time, or when the current song ends.
    @Published private(set) var sleepAt: Date?
    @Published private(set) var sleepAtSongEnd = false
    /// True after 5 minutes without music: the lock screen goes back to your own wallpaper.
    @Published private(set) var idle = false
    private var lastAudioTry = Date.distantPast
    private var artTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var awakeAssertion: IOPMAssertionID = 0

    private var lastVolumeSet = Date.distantPast
    private var lastVolumeSend = Date.distantPast
    private var pendingVolume: DispatchWorkItem?

    func start(settings: Settings) {
        guard !started else { return }
        started = true
        self.settings = settings
        monitor.onUpdate = { [weak self] in self?.handle($0) }
        monitor.start()
        syncAudio()
        network.onOnline = { [weak self] in
            self?.retryDelay = 15
            self?.retryLyrics()
        }
        DispatchQueue.global(qos: .utility).async { LyricsStore.prune() }
    }

    // MARK: - Clock

    /// Playback position in seconds at `date`, including the user's timing offset.
    func time(at date: Date, offset: Double) -> Double {
        guard state.track != nil else { return 0 }
        let elapsed = state.isPlaying ? date.timeIntervalSince(state.sampledAt) : 0
        return state.position + elapsed + offset
    }

    var isPlaying: Bool { state.isPlaying && state.track != nil }

    // MARK: - Colours

    func glowColors(_ p: Prefs) -> (RGB, RGB) {
        if !p.overrideAlbum, let pal = palette { return pal }
        return (RGB(h: p.primaryH, s: p.primaryS, v: p.primaryB),
                RGB(h: p.secondaryH, s: p.secondaryS, v: p.secondaryB))
    }

    /// Lyric colours: plain words, the box behind the sung word, words on the dark box.
    /// Auto Sync builds the same red / pink / coral family from the album's main hue.
    func lyricColors(_ p: Prefs) -> LyricColors {
        if p.autoSync, let pal = palette {
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            NSColor(srgbRed: pal.0.r, green: pal.0.g, blue: pal.0.b, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            let hue = Double(h)
            return LyricColors(text: RGB(h: hue + 0.03, s: 0.82, v: 0.92),
                               highlight: RGB(h: hue, s: 0.74, v: 1.0),
                               secondary: RGB(h: hue + 0.03, s: 0.58, v: 1.0))
        }
        return LyricColors(text: p.lyricColor, highlight: p.highlightColor, secondary: p.secondaryColor)
    }

    /// Main accent colour for player chrome (tints the art glow and active buttons).
    var accent: RGB { palette?.0 ?? Brand.violet }
    /// Second album colour (Velyn's magenta without art).
    var accent2: RGB { palette?.1 ?? Brand.magenta }

    /// Starts or stops listening to system audio to match the "React to system audio" setting.
    /// Battery: the tap keeps the audio hardware awake, so it stops after 30 s with nothing playing
    /// and starts again as soon as a song plays.
    func syncAudio() {
        if isPlaying { lastPlayingAt = Date() }
        let quiet = !isPlaying && Date().timeIntervalSince(lastPlayingAt) > 300
        if quiet != idle { idle = quiet }
        let want = (settings?.prefs.audioReactive ?? true) && Date().timeIntervalSince(lastPlayingAt) < 30
        if want, !audio.isRunning {
            guard Date().timeIntervalSince(lastAudioTry) > 20 else { return }   // don't hammer a failing tap
            lastAudioTry = Date()
            audio.start()
            if audio.isRunning { lastAudioTry = .distantPast }
        } else if !want, audio.isRunning {
            audio.stop()
        }
    }

    // MARK: - Lyric timing (remembered per song)

    /// Total lyric timing: the setting for all songs plus this song's own adjustment.
    func lyricOffset(_ p: Prefs) -> Double {
        p.lyricLead + songLyricOffset(p)
    }

    /// Just this song's adjustment (what Sync −/+ changes).
    func songLyricOffset(_ p: Prefs) -> Double {
        guard let t = state.track else { return 0 }
        return p.lyricOffsets[t.key] ?? 0
    }

    func setLyricOffset(_ v: Double) {
        guard let t = state.track, let settings else { return }
        let r = max(-10, min(10, (v * 100).rounded() / 100))
        var all = settings.prefs.lyricOffsets
        all[t.key] = abs(r) < 0.005 ? nil : r
        if all.count > 1000, let k = all.keys.first(where: { $0 != t.key }) { all[k] = nil }   // keep settings small
        settings.prefs.lyricOffsets = all
    }

    func nudgeLyrics(_ d: Double) {
        guard let settings else { return }
        setLyricOffset(songLyricOffset(settings.prefs) + d)
    }

    /// Colours for kinetic lyrics: the glow colours plus the lyric highlight colour.
    func kineticPalette(_ p: Prefs) -> KPalette {
        let c = lyricColors(p)
        return KPalette(text: c.highlight.mixed(with: .white, 0.9),
                        accents: [c.highlight, c.text, c.secondary, c.highlight.mixed(with: .white, 0.4)])
    }

    // MARK: - Transport controls

    private func refreshSoon() {
        monitor.poll()
    }

    func togglePlay() {
        // Optimistic: freeze/unfreeze the clock right away.
        var s = state
        s.position = time(at: Date(), offset: 0)
        s.sampledAt = Date()
        s.isPlaying.toggle()
        state = s
        motion.musicPlaying = isPlaying
        monitor.send(.playPause)
        refreshSoon()
    }

    /// Next: the first queued song if there is one, otherwise the player's own next song.
    func next() {
        if !advanceQueue() { monitor.send(.next) }
        refreshSoon()
    }

    // MARK: - Playing songs and the queue

    /// Sleep timer: minutes from now; -1 = at the end of this song; 0 = off.
    func setSleep(minutes: Int) {
        sleepAt = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
        sleepAtSongEnd = minutes == -1
    }

    /// Minutes left on the sleep timer (rounded up), nil when it's off or set to the song's end.
    var sleepMinutesLeft: Int? {
        sleepAt.map { max(1, Int(ceil($0.timeIntervalSinceNow / 60))) }
    }

    /// Plays a song now. False if its player isn't open (a Spotify link then opens in Spotify).
    @discardableResult
    func play(_ song: Song) -> Bool {
        let ok = monitor.play(song)
        refreshSoon()
        return ok
    }

    /// Plays one of your Music playlists from the start.
    func playPlaylist(_ id: String) {
        monitor.playPlaylist(id)
        refreshSoon()
    }

    func playNext(_ song: Song) { queue.playNext(song); scheduleQueueAdvance() }
    func addToQueue(_ song: Song) { queue.append(song); scheduleQueueAdvance() }

    /// Plays the first queued song. False when the queue is empty.
    @discardableResult
    private func advanceQueue() -> Bool {
        queueWork?.cancel()
        queueWork = nil
        while let s = queue.popFirst() {
            lastQueueAdvance = Date()
            if monitor.play(s) { return true }       // skip songs whose player isn't open
        }
        return false
    }

    /// A moment before the current song ends, start the first queued one (so the player's own next
    /// song never gets going). Re-armed on every poll.
    private func scheduleQueueAdvance() {
        queueWork?.cancel()
        queueWork = nil
        guard !queue.isEmpty, !sleepAtSongEnd, state.isPlaying, let t = state.track, t.duration > 5 else { return }
        let remaining = t.duration - time(at: Date(), offset: 0)
        guard remaining < 2.5 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.advanceQueue()
            self.refreshSoon()
        }
        queueWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, remaining - 0.3), execute: work)
    }

    /// Like Apple Music: restart the song if it's past 3 seconds, otherwise go back.
    func previous() {
        if time(at: Date(), offset: 0) > 3 {
            seek(to: 0)
        } else {
            monitor.send(.previous)
            refreshSoon()
        }
    }

    /// The 15-second skip buttons.
    func skip(by seconds: Double) {
        seek(to: time(at: Date(), offset: 0) + seconds)
    }

    func seek(to seconds: Double) {
        guard let t = state.track else { return }
        let clamped = max(0, min(seconds, max(t.duration - 0.5, 0)))
        var s = state
        s.position = clamped
        s.sampledAt = Date()
        state = s
        monitor.send(.seek(clamped))
    }

    func toggleShuffle() {
        state.shuffle.toggle()
        monitor.send(.shuffle(state.shuffle))
        refreshSoon()
    }

    func cycleRepeat() {
        let isSpotify = state.track?.isSpotify ?? false
        // Spotify only has repeat off/on; Music has off/all/one.
        var m = state.repeatMode.next
        if isSpotify && m == .one { m = .off }
        state.repeatMode = m
        monitor.send(.repeatMode(m))
        refreshSoon()
    }

    func toggleFavorite() {
        state.favorited.toggle()
        monitor.send(.favorite(state.favorited))
    }

    var canFavorite: Bool { state.track?.isSpotify == false }

    /// Volume changes are sent at most ~12 times a second while dragging.
    func setVolume(_ v: Double) {
        let clamped = max(0, min(1, v))
        volume = clamped
        lastVolumeSet = Date()
        pendingVolume?.cancel()
        let send = { [weak self] in
            guard let self else { return }
            self.lastVolumeSend = Date()
            self.monitor.send(.volume(Int((clamped * 100).rounded())))
        }
        if Date().timeIntervalSince(lastVolumeSend) > 0.08 {
            send()
        } else {
            let work = DispatchWorkItem(block: send)
            pendingVolume = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
        }
    }

    func nudgeVolume(_ delta: Double) { setVolume(volume + delta) }

    // MARK: - Playback

    private func handle(_ new: PlaybackState) {
        let changed = new.track != state.track
        // The song ran out on its own (no Velyn timer in time): the player moved on, so start the queue.
        let endedByItself = changed && state.isPlaying && state.track.map { $0.duration > 5 &&
            $0.duration - time(at: Date(), offset: 0) < 2.5 } == true
        state = new
        if let at = sleepAt, Date() >= at {
            setSleep(minutes: 0)
            if isPlaying { togglePlay() }
        }
        var slept = false
        if endedByItself, sleepAtSongEnd {
            // "End of song": the next one has only just started, so pause it (and leave the queue alone).
            setSleep(minutes: 0)
            if new.isPlaying { togglePlay() }
            slept = true
        }
        if !slept, endedByItself, !queue.isEmpty, Date().timeIntervalSince(lastQueueAdvance) > 4 {
            advanceQueue()
            refreshSoon()
        }
        scheduleQueueAdvance()
        if Date().timeIntervalSince(lastVolumeSet) > 1.5, abs(volume - new.volume) > 0.005 {
            volume = new.volume
        }
        updateAwake()
        motion.musicPlaying = isPlaying
        syncAudio()
        guard changed else { return }

        lines = []
        lyricsID = nil
        lyricTask?.cancel()
        artTask?.cancel()
        prefetchTask?.cancel()
        choicesTask?.cancel()
        choicesTask = nil
        lyricChoices = nil
        retryWork?.cancel()
        retryDelay = 15
        refreshMotion()
        guard let track = new.track else {
            lyricsStatus = .idle
            artwork = nil
            palette = nil
            return
        }
        prefetchNext()
        if let saved = LyricsStore.load(track) {
            apply(saved, duration: track.duration)
        } else {
            lyricsStatus = .loading
            fetchLyrics(track)
        }
        loadArt(track)
    }

    // MARK: - Lyrics

    private func fetchLyrics(_ track: Track) {
        lyricTask?.cancel()
        lyricTask = Task { [weak self] in
            let r = await LyricsClient.lookup(title: track.title, artist: track.artist, duration: track.duration)
            guard !Task.isCancelled else { return }
            LyricsStore.save(r, for: track)
            await MainActor.run { [weak self] in
                guard let self, self.state.track?.key == track.key else { return }
                self.apply(r, duration: track.duration)
            }
        }
    }

    private func apply(_ r: LyricsResult, duration: Double) {
        switch r {
        case .synced(let id, let lrc):
            lines = LRC.parse(lrc, duration: duration)
            lyricsID = id
            lyricsStatus = lines.isEmpty ? .missing : .found
        case .instrumental:
            lines = []
            lyricsID = nil
            lyricsStatus = .instrumental
        case .missing:
            lines = []
            lyricsID = nil
            lyricsStatus = .missing
        case .offline:
            lines = []
            lyricsID = nil
            lyricsStatus = .offline
            scheduleRetry()
        }
    }

    /// Offline: look again when the connection comes back, or after 15 s, 30 s, ... up to 5 min.
    private func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retryLyrics() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 300)
    }

    private func retryLyrics() {
        guard lyricsStatus == .offline, let track = state.track else { return }
        retryWork?.cancel()
        fetchLyrics(track)
    }

    /// Looks up the other versions LRCLIB has for this song (for "Lyrics for This Song").
    func loadLyricChoices() {
        guard let track = state.track, lyricChoices == nil, choicesTask == nil else { return }
        lyricChoicesFailed = false
        choicesTask = Task { [weak self] in
            let found = await LyricsClient.choices(title: track.title, artist: track.artist, duration: track.duration)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.state.track?.key == track.key else { return }
                self.choicesTask = nil
                self.lyricChoicesFailed = found == nil
                self.lyricChoices = found
            }
        }
    }

    /// Uses this version for the song from now on.
    func pickLyrics(_ c: LyricsCandidate) {
        guard let track = state.track else { return }
        lyricTask?.cancel()
        retryWork?.cancel()
        LyricsStore.save(c.result, for: track, picked: true)
        apply(c.result, duration: track.duration)
    }

    /// Forgets the saved (or picked) lyrics for this song and looks them up again.
    func findLyricsAgain() {
        guard let track = state.track else { return }
        LyricsStore.forget(track)
        lyricChoices = nil
        lines = []
        lyricsID = nil
        lyricsStatus = .loading
        fetchLyrics(track)
    }

    /// True when you picked this song's lyrics by hand.
    var lyricsPicked: Bool {
        guard let t = state.track else { return false }
        return LyricsStore.entry(for: t)?.picked ?? false
    }

    /// A few seconds into a song, look up the next one (Apple Music queue) so its lyrics are
    /// saved and its animated cover is already found when it starts.
    private func prefetchNext() {
        let monitor = self.monitor
        let wantMotion = settings?.prefs.motionArt ?? true
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            // The first queued song if there is one, otherwise what the player plays next.
            guard !Task.isCancelled else { return }
            let (queued, spotify) = await MainActor.run { [weak self] in (self?.queue.first?.track, monitor.activeIsSpotify) }
            var upcoming = queued
            if upcoming == nil { upcoming = await monitor.upNext(spotify: spotify) }
            guard !Task.isCancelled, let next = upcoming else { return }
            if LyricsStore.load(next) == nil {
                let r = await LyricsClient.lookup(title: next.title, artist: next.artist, duration: next.duration)
                guard !Task.isCancelled else { return }
                LyricsStore.save(r, for: next)    // handle() finds it there when the song starts
            }
            guard wantMotion,
                  let url = await MotionArtwork.find(title: next.title, artist: next.artist, album: next.album),
                  !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.motion.preload(url) }
        }
    }

    private func loadArt(_ track: Track) {
        let monitor = self.monitor
        artTask = Task { [weak self] in
            var image: NSImage?
            if let s = track.artworkURL, let url = URL(string: s) {
                image = await Art.load(url)
            } else if !track.isSpotify {
                image = await monitor.musicArtwork()
            }
            guard !Task.isCancelled else { return }
            let finalImage = image
            let pal = finalImage.flatMap { Art.palette(from: $0) }
            await MainActor.run { [weak self] in
                // The old cover stays until the new one is ready, then they cross-fade (colours too).
                withAnimation(.easeInOut(duration: 0.7)) {
                    self?.artwork = finalImage
                    self?.palette = pal
                }
                guard let self, self.state.track?.key == track.key else { return }
                if self.bannerArmed, self.settings?.prefs.songBanners == true { SongBanner.show(track, art: finalImage) }
                self.bannerArmed = true
            }
        }
    }

    #if DEBUG
    /// Snapshot mode only: fake a playing track.
    func debugLoad(track: Track, position: Double, artwork: NSImage?, lines: [LyricLine]) {
        state = PlaybackState(track: track, position: position, isPlaying: true, sampledAt: Date())
        if self.artwork !== artwork {
            self.artwork = artwork
            palette = artwork.flatMap { Art.palette(from: $0) }
        }
        self.lines = lines
        lyricsStatus = .found
    }
    #endif

    /// Looks up the animated cover for the current song (or clears it when the setting is off).
    func refreshMotion() {
        motionTask?.cancel()
        guard let track = state.track, settings?.prefs.motionArt ?? true else {
            motion.load(nil)
            return
        }
        // Same album as before: keep the video running across songs.
        let sameAlbum = !track.album.isEmpty && track.album == motionAlbum
        if !sameAlbum { motion.load(nil) }
        motionTask = Task { [weak self] in
            let url = await MotionArtwork.find(title: track.title, artist: track.artist, album: track.album)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.state.track == track else { return }
                self.motionAlbum = track.album
                self.motion.load(url)
            }
        }
    }
    private var motionAlbum = ""

    // MARK: - Keep display awake

    private func updateAwake() {
        let want = isPlaying && (settings?.prefs.keepAwake ?? false)
        if want, awakeAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "\(AppInfo.name): lyrics on screen" as CFString, &awakeAssertion)
        } else if !want, awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
    }
}
