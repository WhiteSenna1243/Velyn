import SwiftUI
import AppKit
import CoreImage

// MARK: - Window

/// The player window: album art, transport, Lyrics button and the bottom toolbar.
final class PlayerWindow {
    static let shared = PlayerWindow()
    private(set) var window: NSWindow?

    /// Opens the player (optionally in a mode, e.g. Search & Queue).
    func show(engine: Engine, settings: Settings, mode: PlayerMode? = nil) {
        if let mode { PlayerNav.shared.request = mode }
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = PlayerRoot()
            .tracksWindowVisibility()
            .environmentObject(engine)
            .environmentObject(settings)
            .environmentObject(WindowManager.shared)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []

        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = NSSize(width: min(1060, vf.width * 0.9), height: min(744, vf.height * 0.9))
        let w = NSWindow(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                                             width: size.width, height: size.height),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentView = host
        w.title = AppInfo.name
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = Brand.background
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 600)
        w.setFrameAutosaveName("VelynPlayer")
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root

enum PlayerMode { case player, expanded, lyrics, browse }

/// Lets menus and shortcuts switch the player's mode.
final class PlayerNav: ObservableObject {
    static let shared = PlayerNav()
    @Published var request: PlayerMode?
}
enum ToolbarTool { case palette, waveform, bulb, display }

private let ink = Color.primary.opacity(0.88)
private let faint = Color.primary.opacity(0.48)
private let chipFill = Color.primary.opacity(0.055)
private let chipStroke = Color.primary.opacity(0.09)

struct PlayerRoot: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    @State private var mode: PlayerMode
    @Namespace private var ns

    private let browseQuery: String
    private let browsePlaylist: MusicLibrary.Playlist?

    init(mode: PlayerMode = .player, browseQuery: String = "", browsePlaylist: MusicLibrary.Playlist? = nil) {
        _mode = State(initialValue: mode)
        self.browseQuery = browseQuery
        self.browsePlaylist = browsePlaylist
    }

    private var spring: Animation { .spring(response: 0.5, dampingFraction: 0.86) }

    var body: some View {
        GeometryReader { geo in
            // Expanded art takes whatever height is left over the title, controls and toolbar.
            let big = max(262, min(420, geo.size.height - 330, geo.size.width - 120))
            ZStack {
                background
                VStack(spacing: 0) {
                    Spacer(minLength: mode == .expanded ? 30 : 34)
                    Group {
                        switch mode {
                        case .player: playerCenter(art: 262)
                        case .expanded: playerCenter(art: big)
                        case .lyrics: LyricsCard(ns: ns, onArt: { setMode(.expanded) })
                        case .browse: BrowseCard(query: browseQuery, playlist: browsePlaylist)
                        }
                    }
                    Spacer(minLength: mode == .expanded ? 22 : 24)
                    PlayerToolbar(mode: mode) { m in setMode(mode == m ? .player : m) }
                        .padding(.bottom, mode == .expanded ? 26 : 34)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusEffectDisabled()
        .onReceive(PlayerNav.shared.$request.compactMap { $0 }) { m in
            setMode(m)
            PlayerNav.shared.request = nil
        }
    }

    private func setMode(_ m: PlayerMode) { withAnimation(spring) { mode = m } }

    // Dark, with the album's two colours as soft clouds. Expanded: blurred art fills it.
    private var background: some View {
        ZStack {
            Color(nsColor: Brand.background)
            RadialGradient(colors: [engine.accent.color.opacity(0.22), .clear],
                           center: UnitPoint(x: 0.3, y: 0.28), startRadius: 0, endRadius: 440)
            RadialGradient(colors: [engine.accent2.color.opacity(0.15), .clear],
                           center: UnitPoint(x: 0.72, y: 0.66), startRadius: 0, endRadius: 480)
            if mode == .expanded, let art = engine.artwork, let soft = ArtBlur.image(art) {
                // Inside an overlay so the oversized image can't stretch the layout.
                Color.clear
                    .overlay(Image(decorative: soft, scale: 1).resizable().scaledToFill())
                    .clipped()
                    .opacity(0.6)
                    .overlay(Color.black.opacity(0.32))
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .clipped()
    }

    private func playerCenter(art: CGFloat) -> some View {
        let track = engine.state.track
        let expanded = mode == .expanded
        return VStack(spacing: 0) {
            ArtCard(side: art, framed: !expanded)
                .matchedGeometryEffect(id: "art", in: ns)
                .onTapGesture { setMode(expanded ? .player : .expanded) }
                .help(expanded ? "Smaller artwork" : "Bigger artwork")
            Text(track?.title ?? "Not Playing")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(ink)
                .lineLimit(1)
                .padding(.top, expanded ? 28 : 30)
            Text(track?.artist ?? " ")
                .font(.system(size: 16))
                .foregroundColor(faint)
                .lineLimit(1)
                .padding(.top, 4)
            ProgressRow()
                .frame(width: min(art + 120, 460))
                .padding(.top, expanded ? 26 : 24)
            TransportBar()
                .padding(.top, 14)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Artwork

/// The art blurred once (not per frame) for the expanded background.
enum ArtBlur {
    private static var key: ObjectIdentifier?
    private static var cached: CGImage?
    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    static func image(_ img: NSImage) -> CGImage? {
        if key == ObjectIdentifier(img) { return cached }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var ci = CIImage(cgImage: cg)
        let s = 160 / max(ci.extent.width, ci.extent.height)
        ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let rect = ci.extent
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: rect)
        cached = ctx.createCGImage(out, from: rect)
        key = ObjectIdentifier(img)
        return cached
    }
}

struct ArtCard: View {
    @EnvironmentObject var engine: Engine
    let side: CGFloat
    var framed = true

    var body: some View {
        let inner = framed ? side - 24 : side
        ZStack {
            if framed {
                // Aura: the album's colours glowing out from behind the art.
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [engine.accent.color, engine.accent2.color],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: inner, height: inner)
                    .blur(radius: 26)
                    .opacity(0.55)
            }
            ZStack {
                if let img = engine.artwork {
                    Image(nsImage: img).resizable().scaledToFill()
                        .id(ObjectIdentifier(img))
                        .transition(.opacity)
                } else {
                    ZStack {
                        Color.primary.opacity(0.07)
                        Image(systemName: "music.note")
                            .font(.system(size: inner * 0.25))
                            .foregroundColor(Color.primary.opacity(0.3))
                    }
                }
            }
            .frame(width: inner, height: inner)
            .overlay(MotionOverlay(motion: engine.motion, cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
    }
}

/// The animated cover over the still image, when the album has one.
struct MotionOverlay: View {
    @ObservedObject var motion: MotionPlayer
    var cornerRadius: CGFloat = 0

    var body: some View {
        if motion.url != nil {
            MotionArtView(motion: motion, cornerRadius: cornerRadius)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Transport

/// −15 s, previous, play/pause, next, +15 s: plain icons around a big glowing play button.
struct TransportBar: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack(spacing: 24) {
            glyph("gobackward.15", 17, "Back 15 seconds") { engine.skip(by: -15) }
            glyph("backward.fill", 22, "Previous") { engine.previous() }
            Button { engine.togglePlay() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .offset(x: engine.isPlaying ? 0 : 2)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(LinearGradient(colors: [engine.accent.mixed(with: .white, 0.1).color,
                                                                      engine.accent2.color],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                    .shadow(color: engine.accent.color.opacity(0.45), radius: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help("Play / Pause")
            glyph("forward.fill", 22, "Next") { engine.next() }
            glyph("goforward.15", 17, "Forward 15 seconds") { engine.skip(by: 15) }
        }
    }

    private func glyph(_ name: String, _ size: CGFloat, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(ink)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

/// Song position: drag to seek. Redraws a few times a second, and not at all when hidden.
struct ProgressRow: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var power = Power.shared
    @Environment(\.windowVisible) private var windowVisible
    @Environment(\.onLockScreen) private var onLockScreen
    @Environment(\.ink) private var ink
    @State private var drag: Double?        // 0...1 while dragging

    var body: some View {
        let dur = engine.state.track?.duration ?? 0
        let fps = min(4, power.lyricsFPS(playing: engine.isPlaying, visible: windowVisible, lockScreen: onLockScreen))
        TimelineView(Power.schedule(fps)) { tl in
            let pos = drag.map { $0 * dur } ?? min(dur, max(0, engine.time(at: tl.date, offset: 0)))
            let f = dur > 0 ? pos / dur : 0
            VStack(spacing: 5) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(ink.opacity(0.14)).frame(height: 4)
                        Capsule()
                            .fill(LinearGradient(colors: [engine.accent.color, engine.accent2.color],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, w * f), height: 4)
                        Circle().fill(ink)
                            .frame(width: drag == nil ? 9 : 13, height: drag == nil ? 9 : 13)
                            .offset(x: max(0, min(w - 9, w * f - 4.5)))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in drag = max(0, min(1, g.location.x / max(1, w))) }
                        .onEnded { _ in
                            if let d = drag { engine.seek(to: d * dur) }
                            drag = nil
                        })
                }
                .frame(height: 14)
                HStack {
                    Text(Self.clock(pos))
                    Spacer()
                    Text("−" + Self.clock(max(0, dur - pos)))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(ink.opacity(0.5))
            }
        }
        .opacity(dur > 0 ? 1 : 0.35)
        .allowsHitTesting(dur > 0)
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The same five controls as plain icons (inside the lyrics card).
struct TransportPlain: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack(spacing: 0) {
            plain("gobackward.15", 15) { engine.skip(by: -15) }
            Spacer()
            plain("backward.fill", 19) { engine.previous() }
            Spacer()
            plain(engine.isPlaying ? "pause.fill" : "play.fill", 24) { engine.togglePlay() }
            Spacer()
            plain("forward.fill", 19) { engine.next() }
            Spacer()
            plain("goforward.15", 15) { engine.skip(by: 15) }
        }
    }

    private func plain(_ name: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(ink)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct RoundButton: View {
    let system: String
    let size: CGFloat
    var help: String = ""
    var on = false
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.33, weight: .semibold))
                .foregroundColor(tint ?? ink)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(on ? 0.14 : (hover ? 0.09 : 0.055))))
                .overlay(Circle().strokeBorder(chipStroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Lyrics card

struct LyricsCard: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    let ns: Namespace.ID
    let onArt: () -> Void

    var body: some View {
        let track = engine.state.track
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ArtCard(side: 232, framed: false)
                    .matchedGeometryEffect(id: "art", in: ns)
                    .onTapGesture(perform: onArt)
                Text(track?.title ?? "Not Playing")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(ink)
                    .lineLimit(1)
                    .padding(.top, 22)
                Text(track?.artist ?? " ")
                    .font(.system(size: 15))
                    .foregroundColor(faint)
                    .lineLimit(1)
                    .padding(.top, 3)
                TransportPlain()
                    .frame(width: 270)
                    .padding(.top, 30)
                HStack(spacing: 8) {
                    SyncChip()
                    RoundButton(system: "text.badge.checkmark", size: 40,
                                help: "Wrong lyrics? Pick another version") { LyricChoicesMenu.shared.popUp() }
                }
                .padding(.top, 22)
            }
            .frame(width: 300)
            .padding(.vertical, 32)
            .padding(.leading, 28)

            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
                .padding(.vertical, 40)
                .padding(.horizontal, 28)

            CardLyrics()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, 28)
        }
        .frame(maxWidth: 800, maxHeight: 470)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 40)
    }
}

/// "− Sync +": nudges lyric timing; tapping Sync puts it back to zero.
struct SyncChip: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings

    var body: some View {
        let off = engine.songLyricOffset(settings.prefs)
        HStack(spacing: 6) {
            step("minus") { engine.nudgeLyrics(-0.25) }
            Button { engine.setLyricOffset(0) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold))
                    Text(abs(off) < 0.01 ? "Sync" : String(format: "%+.2fs", off))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(PressStyle())
            .help("Lyric timing for this song (remembered per song). Click to reset.")
            step("plus") { engine.nudgeLyrics(0.25) }
        }
        .foregroundColor(faint)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Capsule().fill(Color.primary.opacity(0.03)))
    }

    private func step(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).frame(width: 18, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// The lyric list: the current line bold and white (filling in word by word),
/// the others smaller, dimmer and softer the further away they are.
struct CardLyrics: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    @ObservedObject private var power = Power.shared
    @Environment(\.windowVisible) private var windowVisible
    @Environment(\.onLockScreen) private var onLockScreen
    @Environment(\.ink) private var ink

    var body: some View {
        let p = settings.prefs
        if engine.lines.isEmpty {
            let m = engine.lyricsStatus.message.title
            Text(engine.state.track == nil ? "Nothing playing" : (m.isEmpty ? "Lyrics not available" : m))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(ink.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            let offset = engine.lyricOffset(p)
            let fps = power.lyricsFPS(playing: engine.isPlaying, visible: windowVisible, lockScreen: onLockScreen, full: 30)
            TimelineView(Power.schedule(fps)) { tl in
                let t = engine.time(at: tl.date, offset: offset)
                CardLyricList(lines: engine.lines, t: t, onTap: { engine.seek(to: $0 - offset) })
            }
            .id(engine.lyricsID ?? engine.lines.count)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.5), value: engine.lyricsID)
        }
    }
}

struct CardLyricList: View {
    let lines: [LyricLine]
    let t: Double
    let onTap: (Double) -> Void
    @Environment(\.ink) private var ink

    var body: some View {
        let cur = LyricTiming.currentIndex(lines, t)
        let focus = max(cur, 0)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        CardLyricRow(line: line, offset: i - cur, time: i == cur ? t : 0, ink: ink)
                            .equatable()
                            .id(i)
                            .onTapGesture { onTap(line.start) }
                    }
                }
                .padding(.vertical, 200)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(true)
            .onChange(of: focus) { _, new in
                withAnimation(.easeInOut(duration: 0.55)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(focus, anchor: .center) }
        }
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0.02),
            .init(color: .black, location: 0.2),
            .init(color: .black, location: 0.8),
            .init(color: .clear, location: 0.98)
        ], startPoint: .top, endPoint: .bottom))
    }
}

struct CardLyricRow: View, Equatable {
    let line: LyricLine
    let offset: Int
    let time: Double
    var ink = Color.white

    var body: some View {
        let current = offset == 0
        let d = abs(offset)
        Group {
            if line.words.isEmpty {
                Text("♪")
            } else if current {
                filled
            } else {
                Text(line.text)
            }
        }
        .font(.system(size: current ? 25 : 19, weight: current ? .bold : .semibold))
        .foregroundColor(ink.opacity(current ? 1 : 0.5))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(current ? 1 : max(0.25, 0.85 - 0.16 * Double(d)))
        .blur(radius: current ? 0 : min(3.2, 0.6 * Double(max(0, d - 1))))
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.45), value: offset)
    }

    private var filled: Text {
        var out = Text("")
        let n = line.words.count
        for (i, w) in line.words.enumerated() {
            let prog = max(0, min(1, (time - w.start) / max(0.12, w.end - w.start)))
            out = out + Text(w.text + (i < n - 1 ? " " : ""))
                .foregroundColor(ink.opacity(0.42 + 0.58 * prog))
        }
        return out
    }
}

// MARK: - Toolbar

/// The dock: one bar of icons. Lyrics · glow colours · beat sensitivity · brightness · glow display ·
/// lock screen · lyrics window · settings. Colours, sensitivity, brightness and display open in place.
struct PlayerToolbar: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var windows: WindowManager
    let mode: PlayerMode
    let onMode: (PlayerMode) -> Void
    @State private var open: ToolbarTool?

    private var spring: Animation { .spring(response: 0.38, dampingFraction: 0.85) }

    var body: some View {
        let p = settings.prefs
        HStack(spacing: 2) {
            DockButton(system: "quote.bubble.fill", help: "Lyrics", on: mode == .lyrics, tint: engine.accent) { onMode(.lyrics) }
            DockButton(system: "music.note.list", help: "Search & queue (⌘F)", on: mode == .browse, tint: engine.accent) {
                onMode(.browse)
            }
            divider
            tool(.palette, icon: "paintpalette.fill", help: "Glow colours") { PaletteStrip() }
            tool(.waveform, icon: "waveform", help: "Beat sync sensitivity") {
                MiniSlider(value: $settings.prefs.syncSensitivity, range: 0.5...2, tint: engine.accent)
            }
            tool(.bulb, icon: "lightbulb.fill", help: "Glow brightness") {
                MiniSlider(value: $settings.prefs.brightness, range: 0...1, tint: engine.accent)
            }
            tool(.display, icon: "display", help: "Glow display") { DisplayStrip() }
            divider
            if !AppInfo.appStore {
                DockButton(system: "lock.display", help: "Lyrics and glow on the lock screen",
                           on: p.lockScreen, tint: engine.accent) { settings.prefs.lockScreen.toggle() }
            }
            DockButton(system: "macwindow", help: "Lyrics window", on: p.showStage, tint: engine.accent) {
                settings.prefs.showStage.toggle()
            }
            DockButton(system: "gearshape.fill", help: "Settings", on: false, tint: engine.accent) {
                MenuBarPanel.shared.toggle(tab: .glow)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 50)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(chipStroke, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    @ViewBuilder
    private func tool<C: View>(_ which: ToolbarTool, icon: String, help: String,
                               @ViewBuilder content: () -> C) -> some View {
        let isOpen = open == which
        HStack(spacing: 8) {
            DockButton(system: icon, help: help, on: isOpen, tint: engine.accent) {
                withAnimation(spring) { open = isOpen ? nil : which }
            }
            if isOpen {
                content()
                    .padding(.trailing, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
    }
}

/// One icon in the dock; `on` lights it in the album colour.
struct DockButton: View {
    let system: String
    let help: String
    let on: Bool
    let tint: RGB
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(on ? tint.mixed(with: .white, 0.25).color : ink)
                .frame(width: 40, height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(on ? 0.12 : (hover ? 0.07 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help)
    }
}

/// − slider + with an accent-tinted fill.
struct MiniSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: RGB

    var body: some View {
        let step = (range.upperBound - range.lowerBound) / 10
        HStack(spacing: 10) {
            Button { value = max(range.lowerBound, value - step) } label: {
                Image(systemName: "minus").font(.system(size: 11, weight: .bold)).foregroundColor(faint)
            }.buttonStyle(PressStyle())
            GeometryReader { geo in
                let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
                    Capsule().fill(tint.mixed(with: .black, 0.3).color.opacity(0.9))
                        .frame(width: max(6, w * f), height: 6)
                    Circle().fill(Color.primary.opacity(0.22))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .offset(x: max(0, min(w - 18, w * f - 9)))
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let k = max(0, min(1, g.location.x / max(1, w)))
                    value = range.lowerBound + k * (range.upperBound - range.lowerBound)
                })
            }
            .frame(width: 150, height: 24)
            Button { value = min(range.upperBound, value + step) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundColor(faint)
            }.buttonStyle(PressStyle())
        }
    }
}

/// Quick glow colours: album colours, or a few two-colour presets.
/// Two-colour glow presets, shared by the dock's palette and the phone remote.
enum GlowPresets {
    static let all: [(h1: Double, s1: Double, h2: Double, s2: Double)] = [
        (0.0, 0.0, 0.60, 0.85),   // black + blue
        (0.97, 0.80, 0.33, 0.85), // pink + green
        (0.83, 0.75, 0.55, 0.85), // purple + cyan
        (0.02, 0.85, 0.10, 0.85), // red + orange
    ]

    static func colors(_ i: Int) -> (RGB, RGB) {
        let p = all[i]
        return (RGB(h: p.h1, s: p.s1, v: p.s1 == 0 ? 0 : 1), RGB(h: p.h2, s: p.s2, v: 1))
    }

    /// Which preset is on, if any (nil: album colours, or colours picked on the wheels).
    static func current(_ p: Prefs) -> Int? {
        guard p.overrideAlbum else { return nil }
        return all.firstIndex { abs(p.primaryH - $0.h1) < 0.01 && abs(p.secondaryH - $0.h2) < 0.01 && abs(p.primaryS - $0.s1) < 0.01 }
    }

    static func apply(_ i: Int, to s: Settings) {
        let p = all[i]
        s.prefs.overrideAlbum = true
        s.prefs.primaryH = p.h1; s.prefs.primaryS = p.s1; s.prefs.primaryB = p.s1 == 0 ? 0 : 1
        s.prefs.secondaryH = p.h2; s.prefs.secondaryS = p.s2; s.prefs.secondaryB = 1
    }
}

struct PaletteStrip: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        let p = settings.prefs
        HStack(spacing: 8) {
            swatch(selected: !p.overrideAlbum, colors: [.white.opacity(0.9)], label: "A") {
                settings.prefs.overrideAlbum = false
            }
            ForEach(0..<GlowPresets.all.count, id: \.self) { i in
                let (a, b) = GlowPresets.colors(i)
                swatch(selected: GlowPresets.current(p) == i, colors: [a.color, b.color], label: nil) {
                    GlowPresets.apply(i, to: settings)
                }
            }
        }
    }

    private func swatch(selected: Bool, colors: [Color], label: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: colors.count > 1 ? colors : colors + colors,
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                if let label {
                    Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(.black.opacity(0.7))
                }
            }
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(PressStyle())
        .help(label != nil ? "Album colours" : "Preset")
    }
}

/// The glow's display, shown by name; click to pick displays.
struct DisplayStrip: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var windows: WindowManager

    var body: some View {
        let on = Set(GlowOverlays.shared.chosenIDs())
        let names = windows.screens.filter { on.contains($0.id) }.map(\.name)
        Menu {
            ForEach(windows.screens) { s in
                Button { MenuBarPanel.toggleGlowDisplay(s.id, settings: settings) } label: {
                    if on.contains(s.id) { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
        } label: {
            Text(names.isEmpty ? "No display" : names.joined(separator: ", "))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(ink)
                .lineLimit(1)
                .frame(maxWidth: 190)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
