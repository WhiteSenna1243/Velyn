#if DEBUG
import SwiftUI
import AppKit
import AVFoundation

/// Dev aid: renders a ~55 s demo video of Velyn from its real views, with made-up lyrics,
/// original cover art and an original synthesised soundtrack (DemoSound). Nothing copyrighted.
///   swift build && .build/debug/Velyn --demo-video out.mp4 [phone1.png phone2.png]
/// Also keeps out-silent.mp4 (picture only) so the music can be redone with --demo-sound.
///
/// Sync: the glow and lyric pulse run on one 112 BPM grid in video time with a downbeat at
/// `gridOrigin` (where the drums start). Lyric words sit on a 16th grid in song time, and each
/// lyric scene's song start is nudged so they also land on the music's grid in video time.
@MainActor
enum DemoVideo {
    static let W: CGFloat = 1440, H: CGFloat = 810
    static let scale: CGFloat = 4.0 / 3.0          // 1920 x 1080 pixels
    static let fps = 30
    static let beat = 60.0 / 112.0                 // 112 BPM, shared with DemoSound
    static let eighth = beat / 2
    static let gridOrigin = 4.0                    // a downbeat: the drums come in here

    enum Shot { case title, player, spotlight, stream, lens, stars, lockPlayer, lockLyrics, search, phone, panel, end }

    struct Spec {
        var shot: Shot
        var duration: Double
        var song: Double = 0                        // song position at the start of the scene
        var glow = false
        var title: String? = nil
        var subtitle: String? = nil
        var sings = false                           // shows lyrics (the soundtrack's lead follows them)
        var start = 0.0                             // video time, filled in by specs()
    }

    /// The scene list with video start times, and lyric scenes nudged onto the beat grid.
    static func specs(phones: Bool) -> [Spec] {
        var list: [Spec] = [
            Spec(shot: .title, duration: 4),
            Spec(shot: .player, duration: 5.5, song: 3, glow: true, title: "A player that glows with your music",
                 subtitle: "For Apple Music and Spotify", sings: true),
            Spec(shot: .spotlight, duration: 6.5, song: 5.2, glow: true, title: "Synced lyrics, word by word",
                 subtitle: "Spotlight", sings: true),
            Spec(shot: .stream, duration: 4.5, song: 12, glow: true, title: "Seven lyric styles", subtitle: "Stream", sings: true),
            Spec(shot: .lens, duration: 3.5, song: 18, glow: true, title: "Seven lyric styles", subtitle: "Lens", sings: true),
            Spec(shot: .stars, duration: 3.5, song: 22, glow: true, title: "Seven lyric styles", subtitle: "Stars", sings: true),
            Spec(shot: .lockPlayer, duration: 4.5, song: 30, title: "Right on your lock screen", subtitle: "Player look", sings: true),
            Spec(shot: .lockLyrics, duration: 4.5, song: 7.5, title: "Right on your lock screen", subtitle: "With your lyrics", sings: true),
            Spec(shot: .search, duration: 4, title: "Search your playlists, queue what's next"),
            Spec(shot: .phone, duration: 5, song: 40, title: "Control it from your phone",
                 subtitle: "No app to install. The music plays on your Mac."),
            Spec(shot: .panel, duration: 4.5, title: "Make it yours", subtitle: "Colors, glow, styles, fonts"),
            Spec(shot: .end, duration: 4.5)
        ].filter { phones || $0.shot != .phone }
        var t = 0.0
        for i in list.indices {
            list[i].start = t
            if list[i].sings {
                // Shift the song start (by half an 8th at most) so song-grid words land on the video grid.
                let off = t - gridOrigin - list[i].song
                list[i].song += off - (off / eighth).rounded() * eighth
            }
            t += list[i].duration
        }
        return list
    }

    /// Beat pulse (1 on the beat, decaying) and beat count at video time v.
    static func pulse(_ v: Double, decay: Double) -> (Double, Int) {
        let x = v - gridOrigin
        let n = (x / beat).rounded(.down)
        return (exp(-(x - n * beat) * decay), Int(n))
    }

    /// What the soundtrack needs to know about the picture.
    static func cues(phones: Bool) -> DemoSound.Cues {
        let specs = specs(phones: phones)
        let lines = lyrics()
        let start = { (shot: Shot) in specs.first { $0.shot == shot }?.start }
        var c = DemoSound.Cues(length: specs.reduce(0) { $0 + $1.duration }, drop: gridOrigin,
                               outro: start(.end) ?? specs.last!.start)
        c.cuts = specs.map(\.start).filter { $0 > 0 && $0 != c.drop && $0 != c.outro && $0 != start(.phone) }
        c.phones = start(.phone)
        c.pop = start(.panel).map { $0 + 0.45 }       // the panel drops in at local 0.2 to 0.8
        c.chimes = [0.25, c.outro + 0.25]               // the logo fades in
        for s in specs where s.sings {
            let end = s.start + s.duration - 0.2
            for (li, line) in lines.enumerated() {
                for (wi, w) in line.words.enumerated() {
                    let v = s.start + w.start - s.song
                    guard w.start >= s.song - 0.01, v < end else { continue }
                    let last = wi == line.words.count - 1
                    let next = last ? line.end : line.words[wi + 1].start
                    c.notes.append(.init(time: v, length: min(next - w.start - (last ? 0.08 : 0.03), end - v),
                                         line: li, word: wi, count: line.words.count, last: last))
                }
            }
        }
        return c
    }

    static func run(out: String, phones: [String], review: String?) {
        let engine = Engine()
        let settings = Settings()
        settings.prefs = Prefs()
        WindowManager.shared.configure(engine: engine, settings: settings)
        let art = cover()
        let lines = lyrics()
        let track = Track(title: "Paper Lanterns", artist: "Sample Artist", album: "Night Lights", duration: 214)
        func load(_ t: Double) { engine.debugLoad(track: track, position: t, artwork: art, lines: lines) }
        load(0)

        func env<V: View>(_ v: V) -> AnyView {
            AnyView(v.environmentObject(engine).environmentObject(settings)
                .environmentObject(WindowManager.shared).environmentObject(WindowContext())
                .environment(\.colorScheme, .dark))
        }
        var videoTime = 0.0                         // the beat follows the music, not the song position
        func input(_ t: Double) -> LyricInput {
            let p = settings.prefs
            let (pulse, count) = Self.pulse(videoTime, decay: 7)
            var snap = AudioSnapshot()
            snap.beatPulse = Float(pulse)
            snap.beatCount = count
            snap.level = 0.6
            snap.bass = 0.4 + 0.5 * snap.beatPulse
            snap.hasSignal = true
            return LyricInput(lines: lines, t: t, clock: t, size: 1.0, motion: 0.6,
                              palette: engine.kineticPalette(p), colors: engine.lyricColors(p),
                              font: .sfPro, snap: snap)
        }

        // Still shots of AppKit-backed screens (lists, the settings panel).
        MusicLibrary.shared.set(MusicLibrary.Loaded(library: [], playlists: [
            .init(id: "00000000000000B1", name: "Late Night Drive", songs: demoSongs()),
            .init(id: "00000000000000B2", name: "Golden Hour", songs: Array(demoSongs().prefix(4)))
        ]), ready: true)
        engine.queue.clear()
        engine.queue.append(demoSongs()[3])
        engine.queue.append(demoSongs()[5])
        load(64)
        let browse = hosted(env(PlayerRoot(mode: .browse, browseQuery: "light")), CGSize(width: W, height: H))
        let player = hosted(env(PlayerRoot(mode: .player)), CGSize(width: W, height: H))
        // Glow tab with the colour wheels showing; the display list (real monitor names) is cropped off.
        let ps = PanelState()
        ps.tab = .glow
        settings.prefs.overrideAlbum = true
        settings.prefs.primaryH = 0.83; settings.prefs.primaryS = 0.75; settings.prefs.primaryB = 1
        settings.prefs.secondaryH = 0.55; settings.prefs.secondaryS = 0.85; settings.prefs.secondaryB = 1
        let panel = hosted(env(SettingsPanelView(state: ps, engine: engine, onQuit: {})
                                .frame(maxHeight: .infinity, alignment: .top).background(Color(white: 0.13))),
                           CGSize(width: 340, height: 1200))
        settings.prefs.overrideAlbum = false
        engine.queue.clear()
        let phoneShots = phones.compactMap { NSImage(contentsOfFile: $0) }
        let spotlight = SpotlightSim()

        func shotView(_ shot: Shot, _ l: Double, _ t: Double) -> AnyView {
            switch shot {
            case .title: return AnyView(TitleCard(local: l, big: true))
            case .player: return env(PlayerRoot(mode: .player))
            case .spotlight: return env(SpotlightStage(input: input(t), artwork: art, external: spotlight))
            case .stream: return env(ZStack { Color.black; StreamStage(input: input(t)) })
            case .lens: return env(ZStack { Color.black; FisheyeStage(input: input(t)) })
            case .stars: return env(ZStack { Color.black; GraphStage(input: input(t), kind: .constellation) })
            case .lockPlayer:
                settings.prefs.lockLook = .player
                return env(LockStage(glow: false, lyrics: true, notch: nil))
            case .lockLyrics:
                settings.prefs.lockLook = .style
                settings.prefs.lyricStyle = .spotlight
                return env(LockStage(glow: false, lyrics: true, notch: nil))
            case .search: return AnyView(Image(nsImage: browse).resizable().scaleEffect(1 + 0.03 * l / 4))
            case .phone: return AnyView(PhoneScene(local: l, shots: phoneShots, art: art))
            case .panel: return AnyView(PanelScene(local: l, player: player, panel: panel))
            case .end: return AnyView(TitleCard(local: l, big: false))
            }
        }
        let scenes = specs(phones: !phoneShots.isEmpty)

        // Write the picture to out-silent.mp4, then add the soundtrack.
        let final = URL(fileURLWithPath: out)
        let url = silentURL(final)
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { print("can't write \(out)"); return }
        let pxW = Int(W * scale), pxH = Int(H * scale)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: pxW, AVVideoHeightKey: pxH,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: pxW, kCVPixelBufferHeightKey as String: pxH
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        if let review { try? FileManager.default.createDirectory(atPath: review, withIntermediateDirectories: true) }

        var frame: Int64 = 0
        for (n, s) in scenes.enumerated() {
            let count = Int(s.duration * Double(fps))
            for i in 0..<count {
                let l = Double(i) / Double(fps)
                let t = s.song + l
                videoTime = Double(frame) / Double(fps)
                load(t)
                let fade = LyricTiming.smooth(min(l / 0.35, (s.duration - l) / 0.35, 1))
                var glowImage: CGImage?
                if s.glow {
                    let (pulse, count) = Self.pulse(videoTime, decay: 6)
                    let f = GlowDriver.Frame(rotation: t * 20 + Double(count) * 16,
                                             intensity: 0.55 + 0.4 * pulse, energy: 0.2 + 0.7 * pulse, phase: t * 0.9)
                    let u = LiquidGlow.uniforms(settings.prefs, colors: engine.glowColors(settings.prefs), frame: f,
                                                size: CGSize(width: pxW, height: pxH), scale: 1, notch: nil)
                    glowImage = LiquidRenderer.shared.image(u)
                }
                let view = ZStack {
                    Color.black
                    shotView(s.shot, l, t)
                    if let g = glowImage { Image(decorative: g, scale: 1).resizable() }
                    if let title = s.title { Caption(title: title, subtitle: s.subtitle, local: l) }
                }
                .frame(width: W, height: H)
                .clipped()
                .opacity(fade)
                .background(Color.black)
                let r = ImageRenderer(content: view)
                r.scale = scale
                guard let cg = r.cgImage, let pb = pixelBuffer(cg, pxW, pxH, adaptor.pixelBufferPool) else { continue }
                while !input.isReadyForMoreMediaData { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
                adaptor.append(pb, withPresentationTime: CMTime(value: frame, timescale: CMTimeScale(fps)))
                if let review, i == count / 2 {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?
                        .write(to: URL(fileURLWithPath: "\(review)/scene_\(n).jpg"))
                }
                frame += 1
            }
            print("scene \(n + 1)/\(scenes.count) done")
        }
        input.markAsFinished()
        var finished = false
        writer.finishWriting { finished = true }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard writer.status == .completed else { print("failed: \(String(describing: writer.error))"); return }
        print("picture: \(url.path) (\(frame) frames)")
        DemoSound.make(out: final, silent: url, cues: cues(phones: !phoneShots.isEmpty))
    }

    /// out.mp4 -> out-silent.mp4 (the picture without sound, kept for --demo-sound).
    static func silentURL(_ final: URL) -> URL {
        final.deletingLastPathComponent().appendingPathComponent(final.deletingPathExtension().lastPathComponent + "-silent.mp4")
    }

    // MARK: Pieces

    private static func pixelBuffer(_ cg: CGImage, _ w: Int, _ h: Int, _ pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        else { CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32ARGB, nil, &pb) }
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }

    /// A screen drawn in a real (off-screen) window, for views ImageRenderer can't draw.
    private static func hosted(_ view: AnyView, _ size: CGSize) -> NSImage {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.appearance = host.appearance
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let img = NSImage(size: size)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            img.addRepresentation(rep)
        }
        w.orderOut(nil)
        return img
    }

    /// Original cover art: lanterns over water at dusk.
    static func cover() -> NSImage {
        let r = ImageRenderer(content: DemoCover())
        r.scale = 1
        return r.nsImage ?? NSImage(size: NSSize(width: 600, height: 600))
    }

    /// Made-up lyrics.
    static func lyrics() -> [LyricLine] {
        let text = [
            "Paper lanterns over the river",
            "Carry every word I couldn't say",
            "City lights are dancing in your mirror",
            "Hold the night and never let it fade",
            "We were glowing like the morning after",
            "Every color turning into gold",
            "Turn it up and let the room get louder",
            "This is how the story should be told",
            "Paper lanterns over the river",
            "Carry every word I couldn't say"
        ]
        var out: [LyricLine] = []
        // On the 112 BPM grid: a word every dotted 8th, each line starting on an 8th note.
        let step = 0.75 * beat
        var t = (2.0 / eighth).rounded(.up) * eighth
        for s in text {
            let ws = s.split(separator: " ").map(String.init)
            var words: [LyricWord] = []
            for (i, w) in ws.enumerated() {
                let st = t + Double(i) * step
                words.append(LyricWord(text: w, start: st, end: st + step * 0.9))
            }
            let end = t + Double(ws.count) * step + 0.7
            out.append(LyricLine(start: t, end: end, words: words))
            t = (end / eighth).rounded(.up) * eighth
        }
        return out
    }

    static func demoSongs() -> [Song] {
        [("Paper Lanterns", "Sample Artist"), ("City Lights", "The Examples"), ("Lights Over Water", "Sample Artist"),
         ("Night Light", "Nova Lane"), ("Golden Hour Lights", "The Examples"), ("Northern Lights", "Paper Kites Club"),
         ("Lightning Bug", "Nova Lane")].enumerated().map { i, s in
            Song(title: s.0, artist: s.1, album: i % 2 == 0 ? "Night Lights" : "After Dark", duration: 180 + Double(i * 13),
                 source: .music(String(format: "%016X", i + 1)), playlist: "00000000000000B1")
        }
    }
}

// MARK: - Demo views

private struct DemoCover: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.99, green: 0.62, blue: 0.38), Color(red: 0.86, green: 0.30, blue: 0.52),
                                    Color(red: 0.24, green: 0.14, blue: 0.48)], startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.93, blue: 0.7), Color(red: 1, green: 0.6, blue: 0.35).opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 170))
                .frame(width: 340, height: 340).offset(y: -60)
            Rectangle().fill(LinearGradient(colors: [Color(red: 0.18, green: 0.1, blue: 0.38), Color(red: 0.08, green: 0.05, blue: 0.2)],
                                            startPoint: .top, endPoint: .bottom))
                .frame(height: 230).frame(maxHeight: .infinity, alignment: .bottom)
            VStack(spacing: 16) {
                ForEach(0..<6) { i in
                    Capsule().fill(Color(red: 1, green: 0.8, blue: 0.6).opacity(0.28 - Double(i) * 0.04))
                        .frame(width: 380 - CGFloat(i) * 50, height: 4)
                }
            }
            .offset(y: 170)
            ForEach(0..<7) { i in
                let xs: [CGFloat] = [-210, -130, -60, 10, 90, 160, 230], ys: [CGFloat] = [40, 0, 70, 20, 90, 10, 60]
                RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 0.78, blue: 0.42))
                    .frame(width: 18, height: 24)
                    .shadow(color: Color(red: 1, green: 0.6, blue: 0.2), radius: 12)
                    .offset(x: xs[i], y: ys[i])
            }
        }
        .frame(width: 600, height: 600)
    }
}

/// Title and end cards: the logo turning slowly, the name, a line under it.
private struct TitleCard: View {
    let local: Double
    let big: Bool

    var body: some View {
        let appear = LyricTiming.smooth(local / 1.2)
        ZStack {
            Color(red: 0.03, green: 0.02, blue: 0.06)
            RadialGradient(colors: [Brand.violet.color.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 520)
            VStack(spacing: 26) {
                AuraMark(rays: 144, bloom: true)
                    .frame(width: big ? 300 : 230, height: big ? 300 : 230)
                    .rotationEffect(.degrees(local * 9))
                    .scaleEffect(0.85 + 0.15 * appear)
                Text(AppInfo.name).font(.system(size: big ? 92 : 72, weight: .bold, design: .rounded)).foregroundColor(.white)
                Text(big ? "Synced lyrics and a glow that moves with your music."
                         : "Lyrics. Glow. Your music, on your Mac.")
                    .font(.system(size: 26, weight: .medium)).foregroundColor(.white.opacity(0.7))
                    .opacity(LyricTiming.smooth((local - 0.6) / 0.8))
            }
            .opacity(appear)
        }
    }
}

/// Lower-third caption.
private struct Caption: View {
    let title: String
    let subtitle: String?
    let local: Double

    var body: some View {
        let a = LyricTiming.smooth((local - 0.25) / 0.5)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 36, weight: .bold, design: .rounded)).foregroundColor(.white)
            if let subtitle {
                Text(subtitle).font(.system(size: 20, weight: .medium)).foregroundColor(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .opacity(a)
        .offset(y: 14 * (1 - a))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 56).padding(.bottom, 52)
    }
}

/// Two phone screens side by side, sliding up.
private struct PhoneScene: View {
    let local: Double
    let shots: [NSImage]
    let art: NSImage

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.03, blue: 0.08)
            RadialGradient(colors: [Color(red: 0.86, green: 0.3, blue: 0.52).opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: 600)
            HStack(spacing: 70) {
                ForEach(Array(shots.prefix(2).enumerated()), id: \.offset) { i, img in
                    let a = LyricTiming.smooth((local - 0.15 * Double(i)) / 0.7)
                    phone(img).offset(y: 60 * (1 - a) + (i == 1 ? 26 : 0)).opacity(a)
                }
            }
            .offset(x: 160, y: -20)
        }
    }

    private func phone(_ img: NSImage) -> some View {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            .frame(width: 280, height: 560)
            .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 50, style: .continuous).fill(Color(white: 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 50, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 20)
    }
}

/// The settings panel dropping in over the player.
private struct PanelScene: View {
    let local: Double
    let player: NSImage
    let panel: NSImage

    var body: some View {
        let a = LyricTiming.smooth((local - 0.2) / 0.6)
        ZStack(alignment: .topTrailing) {
            Image(nsImage: player).resizable().opacity(0.55)
            Image(nsImage: panel).resizable()
                .frame(width: 340 * 1.1, height: 1200 * 1.1)
                .frame(height: 700, alignment: .top)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                .padding(.top, 24).padding(.trailing, 120)
                .offset(y: -30 * (1 - a))
                .opacity(a)
        }
    }
}
#endif
