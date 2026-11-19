#if DEBUG
import AppKit
import SwiftUI
import AVFoundation

/// Dev aid: looks up an animated cover and checks that AVFoundation can play it.
enum MotionCheck {
    static func run(artist: String, title: String, album: String) {
        UserDefaults.standard.removeObject(forKey: "velyn.motion.cache")
        var result: URL?
        var done = false
        Task {
            result = await MotionArtwork.find(title: title, artist: artist, album: album)
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard let url = result else { print("no animated cover"); return }
        print("stream:", url.absoluteString)
        NSApplication.shared.finishLaunching()
        // Same setup as MotionPlayer, with a layer in a window like the real app.
        let mp = MotionPlayer()
        mp.debugAlwaysPlay = true          // the test window is off-screen, so it never counts as seen
        let player = mp.player
        mp.load(url)
        let item = player.currentItem!
        let view = MotionArtView.PlayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        view.motion = mp
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 300, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.orderFrontRegardless()
        let end = Date().addingTimeInterval(15)
        while item.status == .unknown && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        print("rate:", player.rate, "| control:", player.timeControlStatus.rawValue,
              "| waiting:", player.reasonForWaitingToPlay?.rawValue ?? "-",
              "| buffered:", item.loadedTimeRanges.map { $0.timeRangeValue.duration.seconds })
        print("status:", item.status == .readyToPlay ? "ready" : "failed \(String(describing: item.error))",
              "| size:", item.presentationSize, "| playing at:", String(format: "%.2fs", item.currentTime().seconds))
    }
}

/// Dev aid (debug builds only): renders the main screens to PNG files with sample data,
/// so changes can be checked without running the app. See main.swift.
enum Snapshot {
    @MainActor
    static func run(dir: String, art: String?) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let engine = Engine()
        let settings = Settings()
        settings.prefs = Prefs()
        WindowManager.shared.configure(engine: engine, settings: settings)
        // (GlowOverlays is not configured here: it would put real glow windows on the screen.)

        let image = art.flatMap { NSImage(contentsOfFile: $0) }
        let lines = sampleLines()
        let track = Track(title: "Paper Lanterns", artist: "Sample Artist", duration: 200)
        func load(_ pos: Double) { engine.debugLoad(track: track, position: pos, artwork: image, lines: lines) }

        func env<V: View>(_ v: V) -> some View {
            v.environmentObject(engine).environmentObject(settings)
                .environmentObject(WindowManager.shared).environmentObject(WindowContext())
                .preferredColorScheme(.dark)
        }

        // Player window, three modes.
        load(13.3)
        shoot(env(PlayerRoot(mode: .player)), CGSize(width: 1060, height: 744), "\(dir)/player.png")
        render(env(PlayerRoot(mode: .expanded)), CGSize(width: 1060, height: 744), "\(dir)/player_expanded.png")
        shoot(env(PlayerRoot(mode: .lyrics)), CGSize(width: 1060, height: 744), "\(dir)/player_lyrics.png")

        // Search & Queue with a made-up library.
        let names = ["Paper Lanterns", "Paper Boats", "Lanterns on the Water", "River Song", "Night Drive", "City Lights",
                     "Lantern Festival", "Paper Moon"]
        MusicLibrary.shared.set(names.enumerated().map { i, n in
            Song(title: n, artist: i % 2 == 0 ? "Sample Artist" : "The Examples", album: i < 4 ? "Lanterns" : "Night",
                 duration: 180 + Double(i * 17), source: .music(String(format: "%016X", i + 1)))
        }, ready: true)
        engine.queue.clear()
        engine.queue.append(Song(title: "Night Drive", artist: "Sample Artist", album: "Night", duration: 201, source: .music("00000000000000A1")))
        engine.queue.append(Song(title: "City Lights", artist: "The Examples", album: "Night", duration: 222, source: .music("00000000000000A2")))
        shoot(env(PlayerRoot(mode: .browse, browseQuery: "paper")), CGSize(width: 1060, height: 744), "\(dir)/player_browse.png")
        let sample = (0..<6).map { i in
            Song(title: names[i], artist: "Sample Artist", album: "Mix", duration: 190, source: .music(String(format: "%016X", 100 + i)),
                 playlist: "00000000000000B1")
        }
        let mixes = [MusicLibrary.Playlist(id: "00000000000000B1", name: "Late Night Mix", songs: sample),
                     MusicLibrary.Playlist(id: "00000000000000B2", name: "Road Trip", songs: Array(sample.prefix(2))),
                     MusicLibrary.Playlist(id: "00000000000000B3", name: "Focus", songs: Array(sample.suffix(3)))]
        MusicLibrary.shared.set(MusicLibrary.Loaded(library: [], playlists: mixes), ready: true)
        shoot(env(PlayerRoot(mode: .browse)), CGSize(width: 1060, height: 744), "\(dir)/player_playlists.png")
        shoot(env(PlayerRoot(mode: .browse, browsePlaylist: mixes[0])), CGSize(width: 1060, height: 744), "\(dir)/player_playlist.png")
        engine.queue.clear()

        // Settings panel (album colours, then custom colours on).
        for tab in PanelTab.allCases {
            let st = PanelState()
            st.tab = tab
            shoot(env(SettingsPanelView(state: st, engine: engine, onQuit: {}).background(Color(white: 0.16))),
                  CGSize(width: 340, height: 900), "\(dir)/panel_\(tab.rawValue.lowercased()).png")
        }
        // General tab with the phone remote on (served on this Mac only, for the QR code).
        settings.prefs.phoneRemote = true
        PhoneRemote.shared.debugStart(engine: engine, settings: settings)
        let until = Date().addingTimeInterval(3)
        while PhoneRemote.shared.port == nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let gen = PanelState()
        gen.tab = .general
        shoot(env(SettingsPanelView(state: gen, engine: engine, onQuit: {}).background(Color(white: 0.16))),
              CGSize(width: 340, height: 1000), "\(dir)/panel_remote.png")
        PhoneRemote.shared.stop()
        settings.prefs.phoneRemote = false
        settings.prefs.overrideAlbum = true
        shoot(env(SettingsPanelView(state: PanelState(), engine: engine, onQuit: {}).background(Color(white: 0.16))),
              CGSize(width: 340, height: 1000), "\(dir)/panel_custom.png")
        settings.prefs.overrideAlbum = false

        // Edge glow, with the notch outline.
        settings.prefs.notchCompat = true
        settings.prefs.glowMode = .none
        let notch = CGRect(x: 1512 / 2 - 100, y: 0, width: 200, height: 32)
        settings.prefs.glowStyle = .classic
        render(env(ZStack { Color.black; GlowLayer(notch: notch) }), CGSize(width: 1512, height: 982), "\(dir)/glow.png")
        settings.prefs.glowStyle = .liquid
        // Liquid glow: a few moments of the flow, with and without music energy.
        let liquidSize = CGSize(width: 1512, height: 982)
        for (i, (phase, energy)) in [(0.0, 0.1), (1.5, 0.1), (3.0, 0.8), (4.5, 0.8)].enumerated() {
            let f = GlowDriver.Frame(rotation: 40 + Double(i) * 25, intensity: 1, energy: energy, phase: phase)
            let u = LiquidGlow.uniforms(settings.prefs, colors: (RGB(r: 0.1, g: 0.45, b: 1), RGB(r: 0.0, g: 0.85, b: 0.85)),
                                        frame: f, size: liquidSize, scale: 1, notch: notch)
            if let cg = LiquidRenderer.shared.image(u) {
                render(ZStack { Color(white: 0.06); Image(decorative: cg, scale: 1) }, liquidSize, "\(dir)/liquid_\(i).png")
            }
        }
        settings.prefs.notchCompat = false

        // Lyrics window: Stream through one line, then the other styles.
        let stage = CGSize(width: 1440, height: 900)
        settings.prefs.autoSync = false
        for (i, t) in [7.95, 8.3, 8.45, 8.75, 9.2, 9.65, 11.45, 12.3].enumerated() {
            load(t)
            render(env(StageView()), stage, "\(dir)/ship_\(i).png")
        }
        // Lock screen: what Velyn adds over the wallpaper (the clock is drawn by macOS).
        load(9.2)
        render(env(ZStack {
            LinearGradient(colors: [Color(red: 0.15, green: 0.2, blue: 0.35), Color(red: 0.05, green: 0.05, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
            Text("10:41").font(.system(size: 110, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.75)).frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)
            LockStage(glow: false, lyrics: true, notch: nil)
        }), stage, "\(dir)/lockscreen.png")
        // The three lock screen looks, with a stand-in clock.
        for look in LockLook.allCases {
            settings.prefs.lockLook = look
            // The lyric list scrolls, which only draws in a real window (shoot), not ImageRenderer.
            let draw: (AnyView, CGSize, String) -> Void = look == .lyrics ? { shoot($0, $1, $2) } : { render($0, $1, $2) }
            draw(AnyView(env(ZStack {
                LinearGradient(colors: [Color(red: 0.15, green: 0.2, blue: 0.35), Color(red: 0.05, green: 0.05, blue: 0.1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    Text("Thursday 29 October").font(.system(size: 22, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                    Text("10:41").font(.system(size: 110, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.8))
                }
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 70)
                LockStage(glow: false, lyrics: true, notch: nil)
            })), stage, "\(dir)/lock_\(look.rawValue).png")
        }
        settings.prefs.lockBackground = .white
        settings.prefs.lockLook = .player
        render(env(LockStage(glow: false, lyrics: true, notch: nil)), stage, "\(dir)/lock_player_white.png")
        settings.prefs.lockLook = .lyrics
        shoot(env(LockStage(glow: false, lyrics: true, notch: nil)), stage, "\(dir)/lock_lyrics_white.png")
        settings.prefs.lockBackground = .black
        settings.prefs.lockLook = .style
        settings.prefs.autoSync = true
        for (s, art) in [(LyricStyle.stream, true), (.lens, true), (.code, false), (.stars, false), (.weave, false), (.vine, false)] {
            settings.prefs.lyricStyle = s
            settings.prefs.lyricArt = art
            load(9.2)
            render(env(StageView()), stage, "\(dir)/style_\(s.rawValue)\(art ? "_art" : "").png")
        }
        settings.prefs.lyricArt = false
        // Apple Music: intro dots, mid-line (word filling in), next line, and on the lock screen.
        settings.prefs.lyricStyle = .spotlight
        for (i, t) in [1.2, 9.2, 10.3, 13.0].enumerated() {
            load(t)
            render(env(StageView()), stage, "\(dir)/spotlight_\(i).png")
        }
        load(9.2)
        render(env(ZStack {
            LinearGradient(colors: [Color(red: 0.15, green: 0.2, blue: 0.35), Color(red: 0.05, green: 0.05, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
            LockStage(glow: false, lyrics: true, notch: nil)
        }), stage, "\(dir)/spotlight_lock.png")
        shoot(env(WelcomeView(onDone: {})), CGSize(width: 560, height: 470), "\(dir)/welcome.png")
        // Light mode
        load(13.3)
        shoot(env(PlayerRoot(mode: .player).environment(\.colorScheme, .light)), CGSize(width: 1060, height: 744), "\(dir)/light_player.png", light: true)
        shoot(env(PlayerRoot(mode: .lyrics).environment(\.colorScheme, .light)), CGSize(width: 1060, height: 744), "\(dir)/light_lyrics.png", light: true)
        let lt = PanelState()
        lt.tab = .lyrics
        shoot(env(SettingsPanelView(state: lt, engine: engine, onQuit: {}).background(Color(white: 0.93)).environment(\.colorScheme, .light)),
              CGSize(width: 340, height: 900), "\(dir)/light_panel.png", light: true)
        shoot(env(WelcomeView(onDone: {}).environment(\.colorScheme, .light)), CGSize(width: 560, height: 470), "\(dir)/light_welcome.png", light: true)
        print("snapshots in \(dir)")
    }

    /// Lines with evenly spaced word timings (made-up words, not real lyrics).
    private static func sampleLines() -> [LyricLine] {
        let text = [
            "Paper lanterns on the river",
            "Now when you see me running",
            "Telling me the chances I blew up",
            "Push the button start the car",
            "Call my name and I will be there",
            "Lights all over the city tonight"
        ]
        var out: [LyricLine] = []
        var t = 2.0
        for s in text {
            let ws = s.split(separator: " ").map(String.init)
            var words: [LyricWord] = []
            for (i, w) in ws.enumerated() {
                let st = t + Double(i) * 0.42
                words.append(LyricWord(text: w, start: st, end: st + 0.38))
            }
            let end = t + Double(ws.count) * 0.42 + 0.6
            out.append(LyricLine(start: t, end: end, words: words))
            t = end
        }
        return out
    }

    /// Pure SwiftUI renderer: handles 3D effects, but not AppKit controls.
    @MainActor
    private static func render<V: View>(_ view: V, _ size: CGSize, _ path: String) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        r.scale = 1
        guard let cg = r.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Renders a view in an off-screen window, so AppKit controls draw too.
    private static func shoot<V: View>(_ view: V, _ size: CGSize, _ path: String, light: Bool = false) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.backgroundColor = light ? .white : .black; w.appearance = host.appearance
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        w.orderOut(nil)
    }
}
#endif
