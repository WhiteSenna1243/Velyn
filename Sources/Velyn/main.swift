import AppKit
import SwiftUI

let app = NSApplication.shared
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    // Dev aid: renders the main screens to PNGs with sample data, then quits.
    // swift build && .build/debug/Velyn --snapshot <outdir> [artwork.png]
    let args = CommandLine.arguments
    MainActor.assumeIsolated { Snapshot.run(dir: args.count > i + 1 ? args[i + 1] : "snapshots",
                 art: args.count > i + 2 ? args[i + 2] : nil) }
    exit(0)
}
#endif
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--find-motion"), CommandLine.arguments.count > i + 3 {
    // Dev aid: swift build && .build/debug/Velyn --find-motion "<artist>" "<title>" "<album>"
    let a = CommandLine.arguments
    MotionCheck.run(artist: a[i + 1], title: a[i + 2], album: a[i + 3])
    exit(0)
}
#endif
#if DEBUG
if CommandLine.arguments.contains("--lock-check") {
    // Dev aid: swift build && .build/debug/Velyn --lock-check
    print(LockScreen.shared.selfTest())
    exit(0)
}
#endif
#if DEBUG
if CommandLine.arguments.contains("--hotkey-check") {
    // Dev aid: swift build && .build/debug/Velyn --hotkey-check
    print(HotKeys.shared.selfTest())
    exit(0)
}
#endif
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--lyrics-check"), CommandLine.arguments.count > i + 3 {
    // Dev aid: swift build && .build/debug/Velyn --lyrics-check "<artist>" "<title>" <seconds>
    // Looks the song up on LRCLIB (nothing is saved) and lists the versions "Lyrics for This Song" offers.
    let a = CommandLine.arguments
    let (artist, title, secs) = (a[i + 1], a[i + 2], Double(a[i + 3]) ?? 0)
    let done = DispatchSemaphore(value: 0)
    Task {
        switch await LyricsClient.lookup(title: title, artist: artist, duration: secs) {
        case .synced(let id, let lrc):
            let lines = LRC.parse(lrc, duration: secs)
            print("found id \(id ?? -1): \(lines.count) lines, first: \(lines.first?.text ?? "")")
        case let other: print("result: \(other)")
        }
        for c in await LyricsClient.choices(title: title, artist: artist, duration: secs) ?? [] {
            let s = LyricsClient.score(c, title: title, artist: artist, duration: secs)
            print("  \(c.id)  \(c.artist) — \(c.title)  \(LyricChoicesMenu.time(c.duration))  " +
                  "\(c.synced == nil ? "instrumental" : "synced")  score \(s.map { String(format: "%.1f", $0) } ?? "-")")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}
#endif
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > i + 1 {
    // Dev aid: swift build && .build/debug/Velyn --make-icon Resources/AppIcon.png  (1024 px app icon)
    let out = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: AppIconView())
        r.scale = 1
        if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
            print("icon written to \(out)")
        }
    }
    exit(0)
}
#endif
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--library-check"), CommandLine.arguments.count > i + 1 {
    // Dev aid (read-only, plays nothing): open -n -W Velyn.app --args --library-check /tmp/out.txt
    // Run it as the app (via open) so it uses the app's Automation permission.
    let start = Date()
    let loaded = MusicLibrary.load()
    var out = "loaded in \(String(format: "%.2f", Date().timeIntervalSince(start))) s\n"
    if let loaded {
        out += "library songs: \(loaded.library.count)\n"
        let inLibrary = Set(loaded.library.map(\.id))
        for (n, p) in loaded.playlists.enumerated() {
            out += "playlist \(n + 1): \(p.songs.count) songs, \(p.songs.filter { inLibrary.contains($0.id) }.count) also in library\n"
        }
        let lib = MusicLibrary()
        lib.set(loaded)
        out += "searchable songs: \(lib.count)\n"
    } else {
        out += "failed\n"
    }
    try? out.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
    exit(0)
}
#endif
#if DEBUG
if CommandLine.arguments.contains("--remote-check") {
    // Dev aid: swift build && .build/debug/Velyn --remote-check
    // Runs the phone remote on this Mac only (127.0.0.1) with made-up songs and calls it like a phone would.
    // Play and the play/pause/skip controls are left out: they would start music for real.
    MainActor.assumeIsolated {
        let engine = Engine()
        engine.queue.clear()
        let songs = (1...4).map { i in Song(title: "Paper Song \(i)", artist: "Sample", album: "Mix", duration: 200,
                                            source: .music(String(format: "%016X", i)), playlist: "00000000000000B1") }
        MusicLibrary.shared.set(MusicLibrary.Loaded(library: [], playlists: [.init(id: "00000000000000B1", name: "Mix", songs: songs)]), ready: true)
        let remote = PhoneRemote.shared
        remote.debugStart(engine: engine, settings: Settings())
        let deadline = Date().addingTimeInterval(5)
        while remote.port == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let port = remote.port else { print("server didn't start"); exit(1) }
        let base = "http://127.0.0.1:\(port)", k = remote.token
        var done = false
        Task.detached {
            func call(_ path: String, _ body: Any? = nil) async -> (Int, Data) {
                var r = URLRequest(url: URL(string: base + path)!)
                if let body { r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
                guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return (0, Data()) }
                return ((resp as? HTTPURLResponse)?.statusCode ?? 0, d)
            }
            func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
            var (s, d) = await call("/")
            print("page:", s, d.count, "bytes")
            (s, d) = await call("/icon.png"); print("icon:", s, d.count, "bytes")
            (s, _) = await call("/api/state"); print("no key:", s)
            (s, _) = await call("/api/state?k=wrong"); print("wrong key:", s)
            (s, d) = await call("/api/state?k=\(k)"); print("state:", s, String(data: d, encoding: .utf8) ?? "")
            (s, d) = await call("/api/search?q=paper%202&k=\(k)")
            let hits = json(d)["songs"] as? [[String: Any]] ?? []
            print("search:", s, hits.count, "hit(s):", hits.first?["title"] ?? "-")
            (s, d) = await call("/api/playlists?k=\(k)"); print("playlists:", s, String(data: d, encoding: .utf8) ?? "")
            (s, d) = await call("/api/playlist?id=00000000000000B1&k=\(k)")
            print("playlist songs:", s, (json(d)["songs"] as? [Any])?.count ?? 0)
            let song = hits.first?["song"] ?? [:]
            (s, _) = await call("/api/queue?k=\(k)", ["song": song]); print("queue add:", s)
            (s, _) = await call("/api/queue?k=\(k)", ["song": song, "next": true]); print("queue next:", s)
            (s, d) = await call("/api/state?k=\(k)")
            let q = json(d)["queue"] as? [[String: Any]] ?? []
            print("queue now:", q.count)
            (s, _) = await call("/api/queue/remove?k=\(k)", ["id": q.first?["id"] ?? ""]); print("queue remove:", s)
            (s, _) = await call("/api/queue?k=\(k)", ["song": ["title": "x"]]); print("bad song:", s)
            (s, _) = await call("/api/control?k=\(k)", ["action": "explode"]); print("bad action:", s)
            (s, _) = await call("/api/queue/clear?k=\(k)", [String: Any]()); print("queue clear:", s)
            (s, d) = await call("/api/state?k=\(k)"); print("queue after clear:", (json(d)["queue"] as? [Any])?.count ?? -1)
            (s, _) = await call("/nope"); print("unknown path:", s)
            (s, d) = await call("/manifest.webmanifest?k=\(k)"); print("manifest:", s, String(data: d, encoding: .utf8) ?? "")
            (s, d) = await call("/mark.png"); print("logo:", s, d.count, "bytes")
            (s, d) = await call("/launch.png?w=1179&h=2556"); print("launch screen:", s, d.count, "bytes")
            (s, _) = await call("/launch.png?w=99999&h=2"); print("silly launch size:", s)
            (s, d) = await call("/api/look?k=\(k)")
            let lk = json(d)
            print("look:", s, "modes", (lk["modes"] as? [Any])?.count ?? 0, "styles", (lk["styles"] as? [Any])?.count ?? 0,
                  "presets", (lk["presets"] as? [Any])?.count ?? 0)
            (s, d) = await call("/api/look?k=\(k)", ["preset": 2, "mode": "beat", "style": "stream", "art": true, "brightness": 0.5])
            print("look change:", s, String(data: d, encoding: .utf8) ?? "")
            (s, d) = await call("/api/state?k=\(k)"); print("colors now:", json(d)["colors"] ?? "-")
            (s, _) = await call("/api/look?k=\(k)", ["preset": -1, "mode": "still", "style": "spotlight", "art": false, "brightness": 1.0])
            await MainActor.run { done = true }
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // `--remote-check preview`: keep serving for five minutes, to look at the page in a browser.
        if CommandLine.arguments.contains("preview") {
            engine.addToQueue(songs[2])
            // A song playing, with cover and lyrics, so the page looks real.
            engine.debugLoad(track: Track(title: "Paper Lanterns", artist: "Sample Artist", album: "Night Lights", duration: 214),
                             position: 9.5, artwork: DemoVideo.cover(), lines: DemoVideo.lyrics())
            print("preview: \(base)/?k=\(k)")
            fflush(stdout)
            RunLoop.main.run(until: Date().addingTimeInterval(300))
        }
        remote.stop()
    }
    exit(0)
}
#endif
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--demo-video"), CommandLine.arguments.count > i + 1 {
    // Dev aid: swift build && .build/debug/Velyn --demo-video out.mp4 [phone1.png phone2.png] [--review dir]
    let a = CommandLine.arguments
    var rest = Array(a[(i + 2)...])
    var review: String?
    if let r = rest.firstIndex(of: "--review"), rest.count > r + 1 { review = rest[r + 1]; rest.removeSubrange(r...(r + 1)) }
    MainActor.assumeIsolated { DemoVideo.run(out: a[i + 1], phones: rest, review: review) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--demo-sound"), CommandLine.arguments.count > i + 1 {
    // Dev aid: --demo-sound out.m4a (audio only) | --demo-sound out.mp4 out-silent.mp4 (redo the soundtrack)
    let a = CommandLine.arguments
    let silent = a.count > i + 2 ? URL(fileURLWithPath: a[i + 2]) : nil
    MainActor.assumeIsolated {
        let phones = silent.map(DemoSound.hasPhones) ?? true
        DemoSound.make(out: URL(fileURLWithPath: a[i + 1]), silent: silent, cues: DemoVideo.cues(phones: phones))
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--demo-check"), CommandLine.arguments.count > i + 1 {
    // Dev aid: --demo-check out.mp4 (tracks, levels and kick timing of a finished demo video)
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated { DemoSound.check(url, cues: DemoVideo.cues(phones: DemoSound.hasPhones(url))) }
    exit(0)
}
#endif
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--lyrics-bench") {
    // Dev aid: swift build && .build/debug/Velyn --lyrics-bench [frames]
    let a = CommandLine.arguments
    let frames = a.count > i + 1 ? Int(a[i + 1]) ?? 240 : 240
    MainActor.assumeIsolated { LyricsBench.run(frames: frames) }
    exit(0)
}
#endif
#if DEBUG
if CommandLine.arguments.contains("--panel-check") {
    // Dev aid: swift build && .build/debug/Velyn --panel-check
    MainActor.assumeIsolated {
        let engine = Engine()
        let settings = Settings()
        settings.prefs = Prefs()
        WindowManager.shared.configure(engine: engine, settings: settings)
        engine.debugLoad(track: Track(title: "Paper Lanterns", artist: "Sample Artist", album: "Night Lights", duration: 214),
                         position: 20, artwork: DemoVideo.cover(), lines: DemoVideo.lyrics())
        MenuBarPanel.shared.debugCheck(engine: engine, settings: settings)
    }
    exit(0)
}
#endif
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
