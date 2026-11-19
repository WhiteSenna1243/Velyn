import AppKit
import AVFoundation
import Combine
import SwiftUI
#if APPSTORE
import MusicKit
#endif

// MARK: - Finding animated covers

/// Apple Music's animated album covers ("motion artwork"), HLS video streams. We find the album with
/// Apple's public search API (by artist, song and album name), so this works for Spotify too. Then:
///  - App Store build: the official Apple Music API (`editorialVideo`, via MusicKit; needs the MusicKit
///    service on your App ID);
///  - website build: the public album page at music.apple.com (no developer token needed).
/// Spotify's own Canvas clips are not used: they are only available through Spotify's private API.
enum MotionArtwork {
    private static var misses: Set<String> = []            // per launch
    private static let cacheKey = "velyn.motion.cache"      // album key -> stream URL

    static func find(title: String, artist: String, album: String) async -> URL? {
        let key = norm(artist) + "|" + norm(album.isEmpty ? title : album)
        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        if let s = cache[key], let u = URL(string: s) { return u }
        if misses.contains(key) { return nil }

        let country = (Locale.current.region?.identifier ?? "US").lowercased()
        var found: URL?
        for cc in country == "us" ? ["us"] : [country, "us"] {
            guard let id = await albumID(title: title, artist: artist, album: album, country: cc) else { continue }
            if let u = await streamURL(albumID: id, country: cc) { found = u; break }
        }
        if let found {
            if cache.count > 300 { cache.removeAll() }
            cache[key] = found.absoluteString
            UserDefaults.standard.set(cache, forKey: cacheKey)
        } else {
            misses.insert(key)
        }
        return found
    }

    /// Best matching album in Apple's catalogue for this song.
    private static func albumID(title: String, artist: String, album: String, country: String) async -> Int? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country)
        ]
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }

        let wantAlbum = norm(album), wantArtist = norm(artist), wantTitle = norm(title)
        var best: (score: Int, id: Int)?
        for r in results {
            guard let id = r["collectionId"] as? Int else { continue }
            let a = norm(r["collectionName"] as? String ?? "")
            let ar = norm(r["artistName"] as? String ?? "")
            let t = norm(r["trackName"] as? String ?? "")
            var score = 0
            if !wantAlbum.isEmpty {
                if a == wantAlbum { score += 6 } else if a.hasPrefix(wantAlbum) || wantAlbum.hasPrefix(a) { score += 3 }
                else { continue }            // another album by the same artist would show the wrong cover
            }
            if ar == wantArtist { score += 3 } else if ar.contains(wantArtist) || wantArtist.contains(ar) { score += 1 }
            if t == wantTitle { score += 2 } else if t.hasPrefix(wantTitle) || wantTitle.hasPrefix(t) { score += 1 }
            if score > (best?.score ?? 2) { best = (score, id) }
        }
        return best?.id
    }

    private static let videoKeys = ["motionDetailSquare", "motionSquareVideo1x1", "motionDetailTall"]

    #if APPSTORE
    /// The square animated cover from the Apple Music API (falls back to the tall one).
    private static func streamURL(albumID: Int, country: String) async -> URL? {
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(country)/albums/\(albumID)?extend=editorialVideo"),
              let resp = try? await MusicDataRequest(urlRequest: URLRequest(url: url)).response(),
              let json = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let album = (json["data"] as? [[String: Any]])?.first,
              let video = (album["attributes"] as? [String: Any])?["editorialVideo"] as? [String: Any] else { return nil }
        for key in videoKeys {
            if let s = (video[key] as? [String: Any])?["video"] as? String, s.hasPrefix("https://"), let u = URL(string: s) {
                return u
            }
        }
        return nil
    }
    #else
    /// The square animated cover on the album page (falls back to the tall one).
    private static func streamURL(albumID: Int, country: String) async -> URL? {
        guard let url = URL(string: "https://music.apple.com/\(country)/album/\(albumID)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return nil }
        let page = html.replacingOccurrences(of: "\\u002F", with: "/").replacingOccurrences(of: "\\/", with: "/")
        for key in videoKeys {
            if let u = firstStream(in: page, after: "\"\(key)\"") { return u }
        }
        return nil
    }

    private static func firstStream(in page: String, after key: String) -> URL? {
        guard let r = page.range(of: key) else { return nil }
        let tail = page[r.upperBound...].prefix(4000)
        guard let v = tail.range(of: "\"video\":\""),
              let end = tail[v.upperBound...].range(of: "\"") else { return nil }
        let s = String(tail[v.upperBound..<end.lowerBound])
        guard s.hasPrefix("https://"), s.contains(".m3u8") else { return nil }
        return URL(string: s)
    }
    #endif

    /// Lowercase letters and digits only, without "(Deluxe)", "- Single" and similar tails.
    static func norm(_ s: String) -> String {
        var t = s.lowercased()
        for tail in [" - single", " - ep", " (deluxe)", " (deluxe edition)", " [deluxe]"] {
            if t.hasSuffix(tail) { t.removeLast(tail.count) }
        }
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

// MARK: - Playing it

/// One muted, looping player shared by every view that shows the animated cover.
/// Battery: it only plays while the song plays and at least one cover on screen can be seen.
final class MotionPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var url: URL?
    /// True once the first frame is ready, so views can fade from the still image to the video.
    @Published private(set) var ready = false
    /// Set by Engine: the cover moves while the song plays and holds still when it's paused.
    var musicPlaying = true { didSet { if musicPlaying != oldValue { updatePlayback() } } }
    #if DEBUG
    var debugAlwaysPlay = false
    #endif
    private var statusObs: NSKeyValueObservation?
    private var endToken: NSObjectProtocol?
    private var powerToken: Any?
    private let views = NSHashTable<MotionArtView.PlayerView>.weakObjects()
    private var preloaded: AVURLAsset?

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false   // Keep Screen Awake decides that
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil,
                                                          queue: .main) { [weak self] n in
            guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.player.seek(to: .zero)
            self.updatePlayback()
        }
        powerToken = Power.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePlayback() }
        }
    }

    /// Starts fetching a cover we expect next (the song after this one), so it appears sooner.
    func preload(_ u: URL) {
        guard u != url, preloaded?.url != u else { return }
        let a = AVURLAsset(url: u)
        preloaded = a
        Task { _ = try? await a.load(.isPlayable) }
    }

    func load(_ new: URL?) {
        guard new != url else { return }
        url = new
        ready = false
        statusObs = nil
        guard let new else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let asset = preloaded?.url == new ? preloaded! : AVURLAsset(url: new)
        preloaded = nil
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        // The cover is never shown bigger than ~840 px, so skip the 2K/4K streams.
        item.preferredMaximumResolution = CGSize(width: 1080, height: 1080)
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self, it === self.player.currentItem else { return }
                self.ready = it.status == .readyToPlay
            }
        }
        player.replaceCurrentItem(with: item)
        updatePlayback()
    }

    func attach(_ v: MotionArtView.PlayerView) {
        views.add(v)
        updatePlayback()
    }

    /// Re-checks whether anyone can see the cover. Called when a cover view moves, hides or is covered.
    func updatePlayback() {
        guard player.currentItem != nil else { return }
        var go = musicPlaying && !Power.shared.dark && views.allObjects.contains { $0.isSeen }
        #if DEBUG
        if debugAlwaysPlay { go = true }
        #endif
        if go { if player.rate == 0 { player.play() } }
        else if player.rate != 0 { player.pause() }
    }
}

/// Shows the shared animated cover. Clipping is done on the layer (SwiftUI clip shapes don't clip
/// AppKit views), so pass the corner radius in.
struct MotionArtView: NSViewRepresentable {
    let motion: MotionPlayer
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.motion = motion
        v.cornerRadius = cornerRadius
        return v
    }

    func updateNSView(_ v: PlayerView, context: Context) {
        if v.motion !== motion { v.motion = motion }
        v.cornerRadius = cornerRadius
    }

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()
        private var readyObs: NSKeyValueObservation?
        private var occlusionToken: NSObjectProtocol?
        var cornerRadius: CGFloat = 0 { didSet { layer?.cornerRadius = cornerRadius } }
        weak var motion: MotionPlayer? {
            didSet {
                playerLayer.player = motion?.player
                motion?.attach(self)
            }
        }

        /// On screen and not covered, minimised or hidden.
        var isSeen: Bool {
            guard let w = window, w.isVisible, !isHiddenOrHasHiddenAncestor, bounds.width > 1 else { return false }
            // Lock-screen windows (far above everything) may not report as visible, so trust the lock.
            if Power.shared.locked, w.level.rawValue > NSWindow.Level.screenSaver.rawValue { return true }
            return w.occlusionState.contains(.visible)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
            occlusionToken = nil
            if let w = window {
                occlusionToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
                ) { [weak self] _ in self?.motion?.updatePlayback() }
            }
            DispatchQueue.main.async { [weak self] in self?.motion?.updatePlayback() }
        }

        override func viewDidHide() { super.viewDidHide(); motion?.updatePlayback() }
        override func viewDidUnhide() { super.viewDidUnhide(); motion?.updatePlayback() }

        deinit { if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = CALayer()          // layer-hosting: set the layer before wantsLayer
            wantsLayer = true
            layer?.masksToBounds = true
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.opacity = 0
            layer?.addSublayer(playerLayer)
            // Fade in on the first frame; until then the still artwork underneath shows.
            readyObs = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] l, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let anim = CABasicAnimation(keyPath: "opacity")
                    anim.duration = 0.35
                    self.playerLayer.add(anim, forKey: "fade")
                    self.playerLayer.opacity = l.isReadyForDisplay ? 1 : 0
                }
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to SwiftUI
    }
}
