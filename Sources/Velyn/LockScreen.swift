import AppKit
import SwiftUI
import Combine

/// Lyrics and glow on the real macOS lock screen .
///
/// macOS has no public way to draw over the lock screen. This uses private SkyLight calls (the same
/// approach as the open-source SkyLightWindow project): make a window-server "space" at the level
/// the lock screen uses for notifications, show it, and move our windows into it. The windows are
/// click-through, so the password field and Touch ID work as normal. If a macOS update removes the
/// calls, `supported` is false and the feature quietly does nothing.
final class LockScreen {
    static let shared = LockScreen()

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let mainConnection: MainConnection?
    private let spaceCreate: SpaceCreate?
    private let spaceSetLevel: SpaceSetLevel?
    private let showSpaces: ShowSpaces?
    private let addWindows: AddWindows?

    /// Notification Center's level on the lock screen: above the lock screen, below security prompts.
    private let lockLevel: Int32 = 400

    let supported: Bool
    private(set) var isLocked = false

    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var windows: [NSWindow] = []
    private var engine: Engine?
    private var settings: Settings?
    private var bag: Set<AnyCancellable> = []
    private var tokens: [NSObjectProtocol] = []
    private var pendingRebuild: DispatchWorkItem?

    private init() {
        #if APPSTORE
        // Not in the App Store build: private calls aren't allowed there (and the names mustn't
        // even appear in the binary), so lock-screen lyrics are a website-build feature.
        mainConnection = nil
        spaceCreate = nil
        spaceSetLevel = nil
        showSpaces = nil
        addWindows = nil
        supported = false
        #else
        let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let h, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        mainConnection = sym("SLSMainConnectionID", MainConnection.self)
        spaceCreate = sym("SLSSpaceCreate", SpaceCreate.self)
        spaceSetLevel = sym("SLSSpaceSetAbsoluteLevel", SpaceSetLevel.self)
        showSpaces = sym("SLSShowSpaces", ShowSpaces.self)
        addWindows = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self)
        supported = mainConnection != nil && spaceCreate != nil && spaceSetLevel != nil
            && showSpaces != nil && addWindows != nil
        #endif
    }

    func configure(engine: Engine, settings: Settings) {
        self.engine = engine
        self.settings = settings
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setLocked(true)
        })
        tokens.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setLocked(false)
        })
        // Displays plugged in, unplugged or rearranged while locked: rebuild for the new layout.
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildSoon() })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildSoon() })
        settings.$prefs.map { [$0.lockScreen ? 1 : 0, $0.glowEnabled ? 1 : 0] + $0.glowDisplays.map { Int($0) } }
            .removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        setLocked(Self.screenIsLocked())
    }

    /// Display changes arrive in bursts; rebuild once they settle.
    private func rebuildSoon() {
        guard isLocked else { return }
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isLocked else { return }
            self.refresh()
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    static func screenIsLocked() -> Bool {
        let d = CGSessionCopyCurrentDictionary() as? [String: Any]
        return d?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func setLocked(_ yes: Bool) {
        isLocked = yes
        if !yes { pendingRebuild?.cancel() }
        refresh()
    }

    private func refresh() {
        hide()
        guard isLocked, supported, let settings, settings.prefs.lockScreen else { return }
        show(settings.prefs)
    }

    private func ensureSpace() -> Bool {
        if space != 0 { return true }
        guard let mainConnection, let spaceCreate, let spaceSetLevel, let showSpaces else { return false }
        connection = mainConnection()
        space = spaceCreate(connection, 1, 0)
        guard space != 0 else { return false }
        _ = spaceSetLevel(connection, space, lockLevel)
        _ = showSpaces(connection, [space] as CFArray)
        return true
    }

    /// The song on every display (each with its own look), glow on the chosen glow displays.
    private func show(_ p: Prefs) {
        guard let engine, let settings, ensureSpace(), let addWindows else { return }
        let glowIDs = Set(GlowOverlays.shared.chosenIDs())
        for screen in NSScreen.screens {
            guard let id = WindowManager.id(of: screen) else { continue }
            let glow = p.glowEnabled && glowIDs.contains(id)

            let root = LockStage(glow: glow, lyrics: true, notch: GlowOverlays.notchRect(screen), display: id)
                .environmentObject(engine)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.canBecomeVisibleWithoutLogin = true
            w.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
            w.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
            w.setFrame(screen.frame, display: true)
            _ = addWindows(connection, space, [w.windowNumber] as CFArray, 7)
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    private func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    #if DEBUG
    /// Dev aid: checks the private calls exist and work, with an invisible 1-point window.
    func selfTest() -> String {
        guard supported else { return "SkyLight calls not found" }
        guard ensureSpace(), let addWindows else { return "could not create the lock-screen space" }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.alphaValue = 0
        let r = addWindows(connection, space, [w.windowNumber] as CFArray, 7)
        return "connection \(connection), space \(space), move window -> \(r) (0 = ok)"
    }
    #endif
}

// MARK: - What shows on the lock screen

/// Transparent: the macOS clock and wallpaper stay visible. Lyrics sit under the clock,
/// a small now-playing line under them, and the glow runs around the edge.
/// What Velyn draws on the lock screen (no buttons: it's click-through, so the password field works).
/// Everything sits between the macOS clock (top ~29%) and the password field (bottom ~25%).
struct LockStage: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    let glow: Bool
    let lyrics: Bool
    let notch: CGRect?
    var display: UInt32 = 0

    var body: some View {
        let look = settings.prefs.lockLook(for: display)
        // After 5 minutes without music nothing is drawn, so your own wallpaper shows until a song plays.
        let away = engine.idle
        let song = lyrics && engine.state.track != nil && !away
        // White only behind Player and Lyrics: the lyric styles are drawn for a dark background.
        let light = settings.prefs.lockBackground == .white && look != .style
        let ink: Color = light ? Color(white: 0.08) : .white
        ZStack {
            if song {
                LockBackdrop(light: light)
                LockClock()     // the backdrop hides the macOS clock, so draw our own
            }
            if glow && !away { GlowLayer(notch: notch) }
            if song {
                GeometryReader { geo in
                    switch look {
                    case .player: LockPlayer(size: geo.size)
                    case .lyrics: LockLyrics(size: geo.size)
                    case .style:
                        VStack(spacing: 0) {
                            Spacer().frame(height: geo.size.height * 0.30)     // the macOS clock is up here
                            LyricsPane()
                                .frame(height: geo.size.height * 0.42)
                                .compositingGroup()
                                .shadow(color: .black.opacity(0.45), radius: 8)
                            LockNowPlaying()
                                .padding(.top, 10)
                            Spacer()
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .environment(\.onLockScreen, true)
        .environment(\.ink, ink)
    }
}

/// The lock screen background: solid black or white (it hides the wallpaper) with the album's two
/// colours as soft clouds.
struct LockBackdrop: View {
    @EnvironmentObject var engine: Engine
    var light = false

    var body: some View {
        ZStack {
            light ? Color.white : Color.black
            RadialGradient(colors: [engine.accent.color.opacity(light ? 0.22 : 0.30), .clear],
                           center: UnitPoint(x: 0.3, y: 0.38), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [engine.accent2.color.opacity(light ? 0.16 : 0.22), .clear],
                           center: UnitPoint(x: 0.72, y: 0.68), startRadius: 0, endRadius: 600)
        }
        .animation(.easeInOut(duration: 1.2), value: engine.accent)
    }
}

/// Date and time like the macOS lock screen's (updates every minute).
struct LockClock: View {
    @Environment(\.ink) private var ink

    var body: some View {
        TimelineView(.everyMinute) { tl in
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Text(tl.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: min(26, geo.size.height * 0.026), weight: .semibold))
                        .foregroundColor(ink.opacity(0.85))
                    Text(Self.time(tl.date))
                        .font(.system(size: min(120, geo.size.height * 0.12), weight: .bold, design: .rounded))
                        .foregroundColor(ink.opacity(0.92))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, geo.size.height * 0.06)
            }
        }
    }
}

extension LockClock {
    /// "4:18" (12-hour Macs, no AM/PM, like the lock screen) or "16:18" (24-hour).
    static func time(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let twelve = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
        var h = c.hour ?? 0
        if twelve { h = h % 12 == 0 ? 12 : h % 12 }
        return String(format: "%d:%02d", h, c.minute ?? 0)
    }
}

/// Player look: big album art with its glow, the song, and how much has played.
struct LockPlayer: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.ink) private var ink
    let size: CGSize

    var body: some View {
        let t = engine.state.track
        let art = max(150, min(size.height * 0.26, 320))
        VStack(spacing: 0) {
            Spacer().frame(height: size.height * 0.29)
            ArtCard(side: art + 24, framed: true)
            Text(t?.title ?? "").font(.system(size: 24, weight: .semibold)).foregroundColor(ink.opacity(0.92))
                .lineLimit(1).padding(.top, 24)
            Text(t?.artist ?? "").font(.system(size: 16)).foregroundColor(ink.opacity(0.55))
                .lineLimit(1).padding(.top, 4)
            ProgressRow().frame(width: min(art + 170, 500)).padding(.top, 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .frame(width: size.width, height: size.height)
    }
}

/// Lyrics look: album art, the song and progress on the left, the synced lyric list on the right
/// (the player's lyrics page without its buttons).
struct LockLyrics: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.ink) private var ink
    let size: CGSize

    var body: some View {
        let t = engine.state.track
        let box = CGSize(width: min(size.width * 0.74, 1000), height: max(300, min(size.height * 0.44, 480)))
        let art = min(box.height * 0.56, 260)
        VStack(spacing: 0) {
            Spacer().frame(height: size.height * 0.29)
            HStack(spacing: 44) {
                VStack(spacing: 0) {
                    ArtCard(side: art, framed: false)
                    Text(t?.title ?? "").font(.system(size: 20, weight: .semibold)).foregroundColor(ink.opacity(0.92))
                        .lineLimit(1).padding(.top, 18)
                    Text(t?.artist ?? "").font(.system(size: 15)).foregroundColor(ink.opacity(0.55))
                        .lineLimit(1).padding(.top, 3)
                    ProgressRow().frame(width: art).padding(.top, 16)
                }
                .frame(width: art + 20)
                Rectangle().fill(ink.opacity(0.12)).frame(width: 1).padding(.vertical, 20)
                CardLyrics()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: box.width, height: box.height)
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height)
    }
}

struct LockNowPlaying: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let t = engine.state.track
        HStack(spacing: 10) {
            ZStack {
                if let img = engine.artwork {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.12)
                }
                MotionOverlay(motion: engine.motion, cornerRadius: 7)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(t?.title ?? "").font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.92))
                Text(t?.artist ?? "").font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
            }
            .lineLimit(1)
            Image(systemName: engine.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .padding(.leading, 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: 420)
    }
}
