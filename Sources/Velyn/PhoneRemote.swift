import AppKit
import Combine
import CoreImage
import SystemConfiguration

/// Phone remote: a web page on your Wi-Fi (no app to install) to search your songs and playlists,
/// queue them and control playback. The music plays on the Mac; the phone only sends commands.
/// Every API call needs the secret key from the pairing link, so others on the network can't use it.
final class PhoneRemote: ObservableObject {
    static let shared = PhoneRemote()
    static let defaultPort: UInt16 = 47_820

    /// Listening port while it's running; nil when off (or it couldn't start).
    @Published private(set) var port: UInt16?
    @Published private(set) var token: String

    private var engine: Engine?
    private var settings: Settings?
    private var server: RemoteServer?
    private var bag: Set<AnyCancellable> = []
    private var artCache: (NSImage, Data)?
    private static let tokenKey = "velyn.remote.token"

    init() {
        token = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
        if token.isEmpty { token = Self.makeToken(); UserDefaults.standard.set(token, forKey: Self.tokenKey) }
    }

    func configure(engine: Engine, settings: Settings) {
        self.engine = engine
        self.settings = settings
        settings.$prefs.map(\.phoneRemote).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in if on { self?.start() } else { self?.stop() } }
            .store(in: &bag)
    }

    func start(port: UInt16 = PhoneRemote.defaultPort, loopbackOnly: Bool = false) {
        let s = server ?? RemoteServer { [weak self] req, respond in
            guard let self else { return respond(.error(503, "off")) }
            self.handle(req, respond)
        }
        s.onState = { [weak self] p in self?.port = p }
        server = s
        s.start(port: port, loopbackOnly: loopbackOnly)
    }

    func stop() {
        server?.stop()
        port = nil
    }

    #if DEBUG
    /// Dev aid: serve on this Mac only (no Wi-Fi), for `--remote-check`.
    func debugStart(engine: Engine, settings: Settings) {
        self.engine = engine
        self.settings = settings
        start(port: 0, loopbackOnly: true)
    }
    #endif

    /// A new secret key: links and Home Screen icons made before stop working.
    func newToken() {
        token = Self.makeToken()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
    }

    static func makeToken() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<22).map { _ in chars[Int(rng.next() % UInt64(chars.count))] })
    }

    // MARK: Pairing link

    /// The link to open on the phone: the Mac's network name (keeps working if its address changes).
    var link: URL? { port.flatMap { p in Self.localHostName().flatMap { URL(string: "http://\($0).local:\(p)/?k=\(token)") } } }
    /// Fallback with the Mac's address on the network.
    var addressLink: URL? { port.flatMap { p in Self.localIPv4().flatMap { URL(string: "http://\($0):\(p)/?k=\(token)") } } }

    static func localHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }

    /// The Mac's IPv4 address on Wi-Fi or Ethernet.
    static func localIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (a.ifa_flags & UInt32(IFF_UP)) != 0, (a.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  String(cString: a.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
                break
            }
        }
        return found
    }

    /// QR code for a link, drawn with sharp pixels.
    static func qrCode(_ url: URL, size: CGFloat = 180) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scale = size / out.extent.width
        let big = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(big, from: big.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    // MARK: Requests (main thread)

    /// Compares without leaking how much of the key matched.
    static func sameKey(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func handle(_ req: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        let keyOK = Self.sameKey(req.query["k"] ?? "", token)
        if req.method == "GET" {
            switch req.path {
            case "/", "/index.html":
                // With a good key, the page points at a manifest whose start address keeps the key:
                // a Home Screen app has its own storage, so that's how it stays paired.
                let manifest = keyOK ? "/manifest.webmanifest?k=\(token)" : "/manifest.webmanifest"
                let page = RemotePage.html.replacingOccurrences(of: "{{MANIFEST}}", with: manifest)
                    .replacingOccurrences(of: "{{LAUNCH}}", with: RemotePage.launchLinks)
                return respond(HTTPResponse(type: "text/html; charset=utf-8", body: Data(page.utf8)))
            case "/manifest.webmanifest":
                return respond(HTTPResponse(type: "application/manifest+json", body: RemotePage.manifest(key: keyOK ? token : nil)))
            case "/icon.png":
                return respond(HTTPResponse(type: "image/png", body: RemotePage.icon(180)))
            case "/icon-192.png":
                return respond(HTTPResponse(type: "image/png", body: RemotePage.icon(192)))
            case "/icon-512.png":
                return respond(HTTPResponse(type: "image/png", body: RemotePage.icon(512)))
            case "/mark.png":
                return respond(HTTPResponse(type: "image/png", body: RemotePage.mark))
            case "/launch.png":
                guard let w = Int(req.query["w"] ?? ""), let h = Int(req.query["h"] ?? ""),
                      (300...3000).contains(w), (300...3000).contains(h),
                      let png = RemotePage.launchImage(width: w, height: h) else { return respond(.error(404, "no")) }
                return respond(HTTPResponse(type: "image/png", body: png))
            default: break
            }
        }
        guard req.path.hasPrefix("/api/") else { return respond(.error(404, "not found")) }
        guard keyOK else { return respond(.error(401, "This link is old. Scan the QR code in Velyn's settings again.")) }
        guard let engine else { return respond(.error(503, "not ready")) }
        let library = MusicLibrary.shared

        switch (req.method, req.path) {
        case ("GET", "/api/state"):
            respond(.json(state(engine)))

        case ("GET", "/api/look"):
            guard let p = settings?.prefs else { return respond(.error(503, "not ready")) }
            var out = Self.look(p)
            out["modes"] = GlowAnimation.allCases.map { ["id": $0.rawValue, "title": $0.title] }
            out["styles"] = LyricStyle.allCases.map { ["id": $0.rawValue, "title": $0.title, "art": $0.supportsArt] }
            out["presets"] = GlowPresets.all.indices.map { i -> [String] in
                let (a, b) = GlowPresets.colors(i)
                return [Self.hex(a), Self.hex(b)]
            }
            respond(.json(out))

        case ("POST", "/api/look"):
            guard let settings else { return respond(.error(503, "not ready")) }
            let j = req.json
            if let v = j["glow"] as? Bool { settings.prefs.glowEnabled = v }
            if let v = j["mode"] as? String, let m = GlowAnimation(rawValue: v) { settings.prefs.glowMode = m }
            if let v = j["brightness"] as? Double, v.isFinite { settings.prefs.brightness = max(0, min(1, v)) }
            if let v = j["preset"] as? Int {
                if v == -1 { settings.prefs.overrideAlbum = false }
                else if GlowPresets.all.indices.contains(v) { GlowPresets.apply(v, to: settings) }
            }
            if let v = j["style"] as? String, let s = LyricStyle(rawValue: v) { settings.prefs.lyricStyle = s }
            if let v = j["art"] as? Bool { settings.prefs.lyricArt = v }
            if let v = j["lyricsWindow"] as? Bool { settings.prefs.showStage = v }
            respond(.json(Self.look(settings.prefs)))

        case ("GET", "/api/art"):
            guard let img = engine.artwork, let data = jpeg(img) else { return respond(.error(404, "no art")) }
            respond(HTTPResponse(type: "image/jpeg", body: data))

        case ("GET", "/api/search"):
            let q = req.query["q"] ?? ""
            if let uri = SpotifyLink.uri(from: q) {
                Task {
                    let title = await SpotifyLink.title(of: uri) ?? "Spotify song"
                    let s = Song(title: title, artist: "Spotify", album: "", duration: 0, source: .spotify(uri))
                    await MainActor.run { respond(.json(["songs": [Self.row(s)], "status": "ready"])) }
                }
                return
            }
            library.refreshIfNeeded()
            respond(.json(["songs": library.search(q, limit: 60).map(Self.row), "status": Self.status(library)]))

        case ("GET", "/api/playlists"):
            library.refreshIfNeeded()
            respond(.json(["playlists": library.playlists.map { ["id": $0.id, "name": $0.name, "count": $0.songs.count] },
                           "status": Self.status(library)]))

        case ("GET", "/api/playlist"):
            library.refreshIfNeeded()
            guard let pl = library.playlists.first(where: { $0.id == req.query["id"] }) else { return respond(.error(404, "no such playlist")) }
            respond(.json(["id": pl.id, "name": pl.name, "songs": pl.songs.map(Self.row)]))

        case ("POST", "/api/play"):
            guard let s = Self.song(req.json["song"]) else { return respond(.error(400, "bad song")) }
            respond(engine.play(s) ? .ok : .error(503, s.isSpotify ? "Open Spotify on the Mac first." : "Open Music on the Mac first."))

        case ("POST", "/api/queue"):
            guard let s = Self.song(req.json["song"]) else { return respond(.error(400, "bad song")) }
            if req.json["next"] as? Bool == true { engine.playNext(s) } else { engine.addToQueue(s) }
            respond(.ok)

        case ("POST", "/api/queue/remove"):
            guard let id = (req.json["id"] as? String).flatMap(UUID.init(uuidString:)) else { return respond(.error(400, "bad id")) }
            engine.queue.remove(id)
            respond(.ok)

        case ("GET", "/api/lyrics"):
            let offset = settings.map { engine.lyricOffset($0.prefs) } ?? 0
            let m = engine.lyricsStatus.message
            respond(.json(["lines": engine.lines.map { ["t": $0.start, "s": $0.words.isEmpty ? "♪" : $0.text] },
                           "offset": offset, "message": engine.state.track == nil ? "Nothing playing" : m.title]))

        case ("POST", "/api/sleep"):
            guard let m = req.json["minutes"] as? Int, [-1, 0, 15, 30, 45, 60].contains(m) else { return respond(.error(400, "bad time")) }
            engine.setSleep(minutes: m)
            respond(.ok)

        case ("POST", "/api/queue/clear"):
            engine.queue.clear()
            respond(.ok)

        case ("POST", "/api/playlist/play"):
            guard let id = req.json["id"] as? String, library.playlists.contains(where: { $0.id == id }) else {
                return respond(.error(404, "no such playlist"))
            }
            engine.playPlaylist(id)
            respond(.ok)

        case ("POST", "/api/control"):
            switch req.json["action"] as? String {
            case "playpause": engine.togglePlay()
            case "next": engine.next()
            case "previous": engine.previous()
            case "seek":
                guard let p = req.json["position"] as? Double, p.isFinite else { return respond(.error(400, "bad position")) }
                engine.seek(to: p)
            case "volume":
                guard let v = req.json["value"] as? Double, v.isFinite else { return respond(.error(400, "bad volume")) }
                engine.setVolume(v)
            case "macvolume":
                guard let v = req.json["value"] as? Double, v.isFinite else { return respond(.error(400, "bad volume")) }
                SystemVolume.set(v)
            default: return respond(.error(400, "bad action"))
            }
            respond(.ok)

        default:
            respond(.error(404, "not found"))
        }
    }

    private func state(_ e: Engine) -> [String: Any] {
        // The same colours as the Mac's glow: your custom colours when they're on, otherwise the album's.
        var c1 = e.accent, c2 = e.accent2
        if let p = settings?.prefs {
            (c1, c2) = e.glowColors(p)
            if p.gradientColors == 1 { c2 = c1 }
        }
        var out: [String: Any] = ["playing": e.isPlaying, "position": e.time(at: Date(), offset: 0), "volume": e.volume,
                                  "colors": [Self.hex(c1), Self.hex(c2)]]
        if let mv = SystemVolume.get() { out["macVolume"] = mv }
        if let p = settings?.prefs { out["look"] = Self.look(p) }
        out["sleep"] = e.sleepAtSongEnd ? -1 : (e.sleepMinutesLeft ?? 0)
        out["lyricsKey"] = "\(e.state.track?.key ?? "")|\(e.lyricsID ?? 0)|\(e.lines.count)"
        if let t = e.state.track {
            out["track"] = ["title": t.title, "artist": t.artist, "album": t.album, "duration": t.duration,
                            "spotify": t.isSpotify, "art": e.artwork != nil]
        }
        out["queue"] = e.queue.entries.map { ["id": $0.id.uuidString, "title": $0.song.title, "artist": $0.song.artist] }
        return out
    }

    /// The glow and lyric settings the phone shows (and can change).
    static func look(_ p: Prefs) -> [String: Any] {
        ["glow": p.glowEnabled, "mode": p.glowMode.rawValue, "brightness": p.brightness,
         "preset": GlowPresets.current(p) ?? (p.overrideAlbum ? -2 : -1),     // -1 album colours, -2 picked on the wheels
         "style": p.lyricStyle.rawValue, "art": p.lyricArt, "artOK": p.lyricStyle.supportsArt, "lyricsWindow": p.showStage]
    }

    static func hex(_ c: RGB) -> String {
        func b(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", b(c.r), b(c.g), b(c.b))
    }

    private static func status(_ l: MusicLibrary) -> String {
        switch l.status {
        case .ready: return "ready"
        case .notRunning: return "notRunning"
        case .failed: return "failed"
        case .loading, .idle: return "loading"
        }
    }

    /// A song for the page: what to show, plus the song itself to send back.
    static func row(_ s: Song) -> [String: Any] {
        var r: [String: Any] = ["id": s.id, "title": s.title, "artist": s.artist, "album": s.album, "duration": s.duration]
        if let data = try? JSONEncoder().encode(s), let obj = try? JSONSerialization.jsonObject(with: data) { r["song"] = obj }
        return r
    }

    /// The song the page sent back. Its IDs are checked again before they go anywhere near a script.
    static func song(_ any: Any?) -> Song? {
        guard let any, JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(Song.self, from: data)
    }

    private func jpeg(_ img: NSImage) -> Data? {
        if let c = artCache, c.0 === img { return c.1 }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(600, cg.width)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        if let data { artCache = (img, data) }
        return data
    }
}
