import SwiftUI
import AppKit
import Combine

// MARK: - Stage

/// One Velyn window: black background, big lyrics, edge glow. Everything else
/// (pills, player bar) only shows while the mouse is over the window.
struct StageView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var ctx: WindowContext
    @EnvironmentObject var windows: WindowManager

    @State private var hovering = false
    @State private var clickShown = false
    @State private var hideWork: DispatchWorkItem?

    var body: some View {
        // One window: controls follow the mouse. Several windows: hover is ignored,
        // you click a screen to bring its controls up and they fade after a few seconds.
        let multi = windows.windowTotal > 1
        let chrome = multi ? clickShown : hovering

        ZStack {
            Color.black.ignoresSafeArea()

            LyricsPane()

            AudioDebugHUD()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(16)
                .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top) {
                    TopLeftPill(onSettings: { QuickMenu.shared.popUp() })
                    Spacer()
                    TopRightPill()
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .opacity(chrome ? 1 : 0)
                .allowsHitTesting(chrome)

                Spacer()

                PlayerBar()
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                    .opacity(chrome ? 1 : 0)
                    .allowsHitTesting(chrome)
            }
            .animation(.easeInOut(duration: 0.4), value: chrome)
        }
        .background(Color.black)
        .onHover { hovering = $0 }
        .onReceive(ctx.interaction) { _ in
            if windows.windowTotal > 1 { reveal() }
        }
        .onReceive(ctx.resigned) { _ in
            hideNow()
        }
        .onChange(of: windows.windowTotal) { _, count in
            if count <= 1 { hideNow() }
        }
    }

    /// Multi-window mode: show the controls, then fade them out after a few quiet seconds.
    private func reveal() {
        withAnimation(.easeInOut(duration: 0.25)) { clickShown = true }
        hideWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.6)) { clickShown = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func hideNow() {
        hideWork?.cancel()
        withAnimation(.easeInOut(duration: 0.4)) { clickShown = false }
    }
}

// MARK: - Chrome (pills)

private let pillFill = Color.white.opacity(0.14)
private let pillStroke = Color.white.opacity(0.14)

struct PillButton: View {
    let system: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundColor(Color.white.opacity(0.9))
    }
}

struct TopLeftPill: View {
    @EnvironmentObject var ctx: WindowContext
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if ctx.isFullScreen {
                PillButton(system: "xmark") { ctx.exitOrClose() }
            } else {
                PillButton(system: "arrow.up.left.and.arrow.down.right") { ctx.toggleFullScreen() }
            }
            PillButton(system: "slider.horizontal.3", action: onSettings)
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 6)
        .background(Capsule().fill(pillFill))
        .overlay(Capsule().strokeBorder(pillStroke, lineWidth: 1))
    }
}

struct TopRightPill: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var windows: WindowManager

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(windows.screens) { s in
                    Button {
                        windows.toggle(s.id)
                    } label: {
                        if windows.openIDs.contains(s.id) {
                            Label("Lyrics on \(s.name)", systemImage: "checkmark")
                        } else {
                            Text("Lyrics on \(s.name)")
                        }
                    }
                }
                Divider()
                ForEach(windows.screens) { s in
                    Button("Full Screen on \(s.name)") { windows.toggleFullScreen(on: s.id) }
                }
            } label: {
                Image(systemName: windows.screens.count > 1 ? "display.2" : "display")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.9))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 18)

            Slider(value: Binding(get: { engine.volume }, set: { engine.setVolume($0) }), in: 0...1)
                .controlSize(.small)
                .tint(.white)
                .frame(width: 130)

            Image(systemName: speaker(engine.volume))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.9))
                .frame(width: 22)
        }
        .padding(.horizontal, 10)
        .background(Capsule().fill(pillFill))
        .overlay(Capsule().strokeBorder(pillStroke, lineWidth: 1))
    }

    private func speaker(_ v: Double) -> String {
        if v < 0.01 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.wave.1.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Lyrics pane

struct LyricsPane: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    @ObservedObject private var power = Power.shared
    @Environment(\.windowVisible) private var windowVisible
    @Environment(\.onLockScreen) private var onLockScreen

    var body: some View {
        let p = settings.prefs
        Group {
            if engine.state.track == nil {
                message("Nothing playing", "Play a song in Apple Music or Spotify.")
            } else if engine.lines.isEmpty {
                let m = engine.lyricsStatus.message
                message(m.title.isEmpty ? "Lyrics not available" : m.title, m.detail)
            } else {
                let colors = engine.lyricColors(p)
                let palette = engine.kineticPalette(p)
                // Stream with art: the art is the picture, words over it. Lens / Code: faint, behind.
                let art = p.lyricArt && p.lyricStyle.supportsArt
                let bold = art && p.lyricStyle == .stream
                ZStack {
                    if art, let image = engine.artwork {
                        GeometryReader { geo in
                            let side = min(geo.size.width, geo.size.height) * (bold ? 0.52 : 0.62)
                            ArtVisual(image: image, color: colors.highlight, opacity: bold ? 0.95 : 0.32)
                                .frame(width: side, height: side)
                                .position(x: geo.size.width / 2, y: geo.size.height * (bold ? 0.42 : 0.5))
                        }
                        .allowsHitTesting(false)
                    }
                    let fps = power.lyricsFPS(playing: engine.isPlaying, visible: windowVisible,
                                              lockScreen: onLockScreen)
                    let offset = engine.lyricOffset(p)
                    TimelineView(Power.schedule(fps)) { tl in
                        let t = engine.time(at: tl.date, offset: offset)
                        // Reduce Motion: almost no idle drift and no beat pulses.
                        let snap = calmed(engine.audio.snapshot())
                        let input = LyricInput(lines: engine.lines, t: t,
                                               clock: tl.date.timeIntervalSinceReferenceDate,
                                               size: p.lyricSize,
                                               motion: power.reduceMotion ? min(p.lyricMotion, 0.1) : p.lyricMotion,
                                               palette: palette, colors: colors, font: p.lyricFont,
                                               snap: snap)
                        switch p.lyricStyle {
                        case .stream: StreamStage(input: input, compact: bold)
                        case .lens: FisheyeStage(input: input)
                        case .code: CodeStage(input: input)
                        case .vine: GraphStage(input: input, kind: .branches)
                        case .weave: GraphStage(input: input, kind: .web)
                        case .stars: GraphStage(input: input, kind: .constellation)
                        case .spotlight: SpotlightStage(input: input, artwork: engine.artwork, lockScreen: onLockScreen)
                        }
                    }
                    .id(engine.lyricsID ?? engine.lines.count)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.5), value: engine.lyricsID)
                }
            }
        }
    }

    private func calmed(_ s: AudioSnapshot) -> AudioSnapshot {
        guard power.reduceMotion else { return s }
        var q = s
        q.beatPulse = 0
        return q
    }

    private func message(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(Color.white.opacity(0.6))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundColor(Color.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
