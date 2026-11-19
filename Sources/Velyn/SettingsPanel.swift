import SwiftUI
import AppKit

// MARK: - Menu bar icon and panel

enum PanelTab: String, CaseIterable, Identifiable {
    case glow = "Glow", lyrics = "Lyrics", general = "General"
    var id: String { rawValue }
}

final class PanelState: ObservableObject {
    @Published var tab = PanelTab.glow
}

/// Velyn's one menu bar icon. Click: the settings panel (Glow / Lyrics / General).
/// Right-click: the quick menu (`QuickMenu`).
final class MenuBarPanel: NSObject, NSWindowDelegate {
    static let shared = MenuBarPanel()

    private var panel: NSPanel?
    private var host: NSHostingView<PanelRoot>?
    private var statusItem: NSStatusItem?
    private var engine: Engine?
    private var settings: Settings?
    private let state = PanelState()
    private var anchorTop: CGFloat = 0
    private var lastClose = Date.distantPast

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    func configure(engine: Engine, settings: Settings) {
        self.engine = engine
        self.settings = settings
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Brand.menuBarImage()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            close()
            if let b = statusItem?.button { QuickMenu.shared.popUp(under: b) }
        } else {
            toggle()
        }
    }

    func toggle(tab: PanelTab? = nil) {
        if let p = panel, p.isVisible, tab == nil || tab == state.tab { close(); return }
        // A click on the menu bar icon closes the panel first (it loses focus); don't reopen it.
        if tab == nil, Date().timeIntervalSince(lastClose) < 0.25 { return }
        show(tab: tab)
    }

    func show(tab: PanelTab? = nil) {
        guard let engine, let settings else { return }
        if let tab { state.tab = tab }
        let p = panel ?? makePanel(engine: engine, settings: settings)
        panel = p
        host?.rootView = root(open: true)
        positionUnderStatusItem(p)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        lastClose = Date()
        // Drop the content once it's hidden (after the click that closed it has finished).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible != true else { return }
            self.host?.rootView = self.root(open: false)
        }
    }

    private func root(open: Bool) -> PanelRoot {
        PanelRoot(open: open, state: state, engine: engine!, settings: settings!, onQuit: { NSApp.terminate(nil) })
    }

    private func makePanel(engine: Engine, settings: Settings) -> NSPanel {
        let host = NSHostingView(rootView: root(open: false))
        host.sizingOptions = [.intrinsicContentSize]
        self.host = host

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 18
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.separatorColor.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor),
            host.bottomAnchor.constraint(equalTo: fx.bottomAnchor)
        ])

        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = fx
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        return p
    }

    private func positionUnderStatusItem(_ p: NSPanel) {
        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? p.frame.size
        var x: CGFloat, top: CGFloat
        if let b = statusItem?.button, let bw = b.window {
            let r = bw.convertToScreen(b.convert(b.bounds, to: nil))
            x = r.midX - size.width / 2
            top = r.minY - 6
            if let vf = bw.screen?.visibleFrame { x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8) }
        } else {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            x = vf.maxX - size.width - 12
            top = vf.maxY - 6
        }
        anchorTop = top
        p.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    // Keep the top edge pinned under the menu bar while the panel grows or shrinks.
    func windowDidResize(_ notification: Notification) {
        guard let p = panel, anchorTop > 0 else { return }
        let f = p.frame
        if abs(f.maxY - anchorTop) > 0.5 {
            p.setFrameOrigin(NSPoint(x: f.minX, y: anchorTop - f.height))
        }
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    #if DEBUG
    /// Dev aid (`--panel-check`): panel sizes when opened and closed, and how long one playback
    /// update takes while it's open, now and the old way (whole panel redrawn). Shows no window.
    func debugCheck(engine: Engine, settings: Settings) {
        self.engine = engine
        self.settings = settings
        let p = makePanel(engine: engine, settings: settings)
        panel = p
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        func size() -> CGSize { settle(); p.contentView?.layoutSubtreeIfNeeded(); return p.contentView?.fittingSize ?? .zero }
        print("closed:", size())
        host?.rootView = root(open: true)
        p.contentView?.layoutSubtreeIfNeeded()
        print("open (straight away):", p.contentView?.fittingSize ?? .zero)
        print("open:", size())
        func updates(_ name: String) {
            for tab in PanelTab.allCases {
                state.tab = tab
                settle(); p.contentView?.layoutSubtreeIfNeeded(); settle()
                var ms: [Double] = []
                for _ in 0..<20 {
                    let t0 = CACurrentMediaTime()
                    engine.objectWillChange.send()
                    RunLoop.main.run(until: Date())       // let SwiftUI pick up the change
                    p.contentView?.layoutSubtreeIfNeeded()
                    ms.append((CACurrentMediaTime() - t0) * 1000)
                    settle()
                }
                print(String(format: "%@ %@: avg %.2f ms, max %.2f ms", name, tab.rawValue, ms.reduce(0, +) / Double(ms.count), ms.max() ?? 0))
            }
        }
        updates("now")
        let old = NSHostingView(rootView: AnyView(OldPanel(state: state, engine: engine, settings: settings)))
        old.sizingOptions = [.intrinsicContentSize]
        host?.rootView = root(open: false)
        p.contentView = old
        updates("old")
        print("closed again:", { () -> CGSize in p.contentView = host; host?.rootView = root(open: false); return size() }())
    }

    private struct OldPanel: View {
        @ObservedObject var state: PanelState
        @ObservedObject var engine: Engine
        let settings: Settings
        var body: some View {
            let _ = engine.state
            SettingsPanelView(state: state, engine: engine, onQuit: {})
                .environmentObject(engine).environmentObject(settings).environmentObject(WindowManager.shared)
        }
    }
    #endif

    /// Display list: tap to add / remove a display. Never leaves the glow on no display.
    static func toggleGlowDisplay(_ id: UInt32, settings: Settings) {
        var on = GlowOverlays.shared.chosenIDs()
        if let i = on.firstIndex(of: id) {
            if on.count > 1 { on.remove(at: i) }
        } else {
            on.append(id)
        }
        settings.prefs.glowDisplays = on
        if !settings.prefs.glowEnabled { settings.prefs.glowEnabled = true }
    }

    /// Shows lyrics on that display, or hides them there if they're already showing.
    static func toggleLyricsDisplay(_ id: UInt32, settings: Settings) {
        let wm = WindowManager.shared
        if !settings.prefs.showStage {
            settings.prefs.showStage = true
            wm.closeAll()
            _ = wm.openWindow(on: id)
        } else {
            wm.toggle(id)
        }
    }
}

// MARK: - Panel content

/// The panel's content only exists while the panel is open. Hidden, it would still redraw and
/// re-measure itself on every playback update, which held up the lyrics and the glow.
struct PanelRoot: View {
    let open: Bool
    let state: PanelState
    let engine: Engine
    let settings: Settings
    let onQuit: () -> Void

    var body: some View {
        if open {
            SettingsPanelView(state: state, engine: engine, onQuit: onQuit)
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(WindowManager.shared)
        }
    }
}

/// Redraws just its content when playback changes (once a second), not the whole panel:
/// re-measuring the panel's segmented pickers is slow enough to make the lyrics stutter.
private struct WatchEngine<Content: View>: View {
    @EnvironmentObject var engine: Engine
    @ViewBuilder let content: (Engine) -> Content
    var body: some View { content(engine) }
}

private let label = Color.primary.opacity(0.9)
private let dim = Color.primary.opacity(0.5)

struct SettingsPanelView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var windows: WindowManager
    @ObservedObject var state: PanelState
    /// Not observed: only `WatchEngine` parts redraw when playback changes.
    let engine: Engine
    @ObservedObject private var remote = PhoneRemote.shared
    let onQuit: () -> Void
    @State private var launchAtLogin = LoginItem.isOn

    var body: some View {
        let p = settings.prefs
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs.padding(.top, 14)
            Group {
                switch state.tab {
                case .glow: glowTab(p)
                case .lyrics: lyricsTab(p)
                case .general: generalTab(p)
                }
            }
            .padding(.top, 14)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Brand.accent)
        .animation(.easeInOut(duration: 0.2), value: p.overrideAlbum)
        .animation(.easeInOut(duration: 0.2), value: p.autoSync)
        .animation(.easeInOut(duration: 0.2), value: p.glowMode)
        .animation(.easeInOut(duration: 0.2), value: p.hotKeys)
    }

    // MARK: Header and tabs

    private var header: some View {
        HStack(spacing: 10) {
            AuraMark(rays: 48, bloom: false).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(label)
                WatchEngine { engine in
                    Text(engine.state.track.map { "\($0.title) · \($0.artist)" } ?? "Nothing playing")
                        .font(.system(size: 11)).foregroundColor(dim).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                toggle($settings.prefs.glowEnabled)
                Text("Glow").font(.system(size: 9.5, weight: .medium)).foregroundColor(dim)
            }
            .help("Edge glow on / off")
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { t in
                let on = state.tab == t
                Button { state.tab = t } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12, weight: on ? .semibold : .medium))
                        .foregroundColor(on ? Color.primary : dim)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? Brand.accent.opacity(0.32) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    // MARK: Glow

    @ViewBuilder
    private func glowTab(_ p: Prefs) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            card("Look") {
                row("Style") { segmented($settings.prefs.glowStyle, GlowStyle.allCases) }
                row("Colors") {
                    Picker("", selection: $settings.prefs.gradientColors) {
                        Text("One").tag(1)
                        Text("Two").tag(2)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                row("Motion") {
                    Picker("", selection: $settings.prefs.glowMode) {
                        ForEach(GlowAnimation.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                if p.glowMode == .musicSync {
                    row("Beat style") { segmented($settings.prefs.syncStyle, SyncStyle.allCases) }
                    slider("Sensitivity", $settings.prefs.syncSensitivity, 0.5...2)
                }
                slider("Thickness", $settings.prefs.thickness)
                slider("Softness", $settings.prefs.glow)
                slider("Brightness", $settings.prefs.brightness)
                row("Follow the notch") { toggle($settings.prefs.notchCompat) }
                    .help("The glow bends around the notch on MacBooks that have one")
            }
            card("Colors") {
                row("Custom colors") { toggle($settings.prefs.overrideAlbum) }
                    .help("Off: the glow takes its colours from the album art")
                if p.overrideAlbum { wheels(p) }
            }
            card("Displays") {
                glowDisplays
                row("Only where \(AppInfo.name) is open") { toggle($settings.prefs.glowFollowsApp) }
                    .help("Glow only on displays that have a \(AppInfo.name) window (player or lyrics) showing")
            }
        }
    }

    // MARK: Lyrics

    @ViewBuilder
    private func lyricsTab(_ p: Prefs) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            card("Style") {
                styleGrid(p)
                row("Album art behind lyrics") { toggle($settings.prefs.lyricArt) }
                    .disabled(!p.lyricStyle.supportsArt)
                    .opacity(p.lyricStyle.supportsArt ? 1 : 0.4)
                    .help(p.lyricStyle.supportsArt ? "" : "Stream, Lens and Code can show the album art")
                row("Font") {
                    Picker("", selection: $settings.prefs.lyricFont) {
                        ForEach(LyricFont.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                slider("Text size", $settings.prefs.lyricSize, 0.6...1.4)
                slider("Drift", $settings.prefs.lyricMotion, 0...1.5)
            }
            card("Colors") {
                row("Match the album") {
                    toggle(Binding(get: { settings.prefs.autoSync }, set: setAutoSync))
                }
                if !p.autoSync {
                    colorRow("Words", \.lyricColor)
                    colorRow("Highlight", \.highlightColor)
                    colorRow("Words on highlight", \.secondaryColor)
                    smallButton("Reset colors") { settings.prefs.resetColors() }
                }
            }
            card("Windows") {
                row("Show lyrics window") { toggle($settings.prefs.showStage) }
                lyricDisplays(p)
                row("Keep screen awake") { toggle($settings.prefs.keepAwake) }
                    .help("While music plays and lyrics are showing")
            }
            card("Timing") {
                HStack(spacing: 6) {
                    Text("All songs").font(.system(size: 12)).foregroundColor(label)
                    Spacer()
                    stepButton("minus") { settings.prefs.lyricLead = max(-2, ((settings.prefs.lyricLead - 0.1) * 10).rounded() / 10) }
                    Text(String(format: "%.1f s %@", abs(p.lyricLead), p.lyricLead >= 0 ? "earlier" : "later"))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundColor(label).frame(width: 82)
                    stepButton("plus") { settings.prefs.lyricLead = min(3, ((settings.prefs.lyricLead + 0.1) * 10).rounded() / 10) }
                }
                .help("Shows lyrics this much earlier for every song (on top of each song's own Sync)")
            }
            card("This song") {
                WatchEngine { engine in
                    let off = engine.songLyricOffset(p)
                    row("Timing") {
                        HStack(spacing: 6) {
                            stepButton("minus") { engine.nudgeLyrics(-0.25) }
                            Text(abs(off) < 0.01 ? "In sync" : String(format: "%+.2f s", off))
                                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                .foregroundColor(label).frame(width: 56)
                            stepButton("plus") { engine.nudgeLyrics(0.25) }
                            if abs(off) >= 0.01 { stepButton("arrow.counterclockwise") { engine.setLyricOffset(0) } }
                        }
                    }
                    smallButton("Wrong lyrics? Pick another version…") { LyricChoicesMenu.shared.popUp() }
                        .disabled(engine.state.track == nil)
                }
            }
        }
    }

    private func styleGrid(_ p: Prefs) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(LyricStyle.allCases) { s in
                let on = p.lyricStyle == s
                Button { settings.prefs.lyricStyle = s } label: {
                    VStack(spacing: 4) {
                        Image(systemName: s.symbol).font(.system(size: 14, weight: .medium))
                        Text(s.title).font(.system(size: 10.5, weight: on ? .semibold : .regular))
                    }
                    .foregroundColor(on ? Color.primary : label.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(on ? Brand.accent.opacity(0.3) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(on ? Brand.accent : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Picking colours by hand starts from the album colours you were seeing, so nothing jumps.
    private func setAutoSync(_ on: Bool) {
        if !on {
            let c = engine.lyricColors(settings.prefs)
            settings.prefs.lyricColor = c.text
            settings.prefs.highlightColor = c.highlight
            settings.prefs.secondaryColor = c.secondary
        }
        settings.prefs.autoSync = on
    }

    private func colorRow(_ title: String, _ key: WritableKeyPath<Prefs, RGB>) -> some View {
        row(title) {
            ColorPicker("", selection: Binding(
                get: { settings.prefs[keyPath: key].color },
                set: { c in
                    guard let n = NSColor(c).usingColorSpace(.sRGB) else { return }
                    settings.prefs[keyPath: key] = RGB(r: Double(n.redComponent), g: Double(n.greenComponent),
                                                       b: Double(n.blueComponent))
                }), supportsOpacity: false)
            .labelsHidden()
        }
    }

    private func lyricDisplays(_ p: Prefs) -> some View {
        VStack(spacing: 5) {
            ForEach(windows.screens) { s in
                displayRow(s.name, on: p.showStage && windows.openIDs.contains(s.id)) {
                    MenuBarPanel.toggleLyricsDisplay(s.id, settings: settings)
                }
            }
        }
    }

    // MARK: General

    @ViewBuilder
    private func generalTab(_ p: Prefs) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            card("App") {
                if !AppInfo.appStore {
                    row("Show on the lock screen") { toggle($settings.prefs.lockScreen) }
                        .help(LockScreen.shared.supported ? "The song, lyrics and glow on the real lock screen"
                              : "Not available on this version of macOS")
                    if p.lockScreen {
                        ForEach(windows.screens) { s in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(windows.screens.count > 1 ? s.name : "Look").font(.system(size: 12)).foregroundColor(label)
                                    .lineLimit(1)
                                Picker("", selection: Binding(
                                    get: { settings.prefs.lockLook(for: s.id) },
                                    set: { settings.prefs.lockDisplayLooks[String(s.id)] = $0 })) {
                                    ForEach(LockLook.allCases) { Text($0.title).tag($0) }
                                }
                                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: .infinity)
                            }
                            .help("Player: big album art and progress. Lyrics: art and progress beside the lyrics. Lyric style: your lyrics style under the clock.")
                        }
                        row("Background") { segmented($settings.prefs.lockBackground, LockBackground.allCases) }
                            .help("Behind the Player and Lyrics looks. Lyric style always uses black.")
                    }
                }
                row("Show in Dock") { toggle($settings.prefs.showInDock) }
                row("Launch at login") {
                    toggle(Binding(get: { launchAtLogin }, set: { launchAtLogin = LoginItem.set($0) }))
                }
                .onAppear { launchAtLogin = LoginItem.isOn }
                row("Animated album covers") { toggle($settings.prefs.motionArt) }
                row("Song banners") {
                    toggle(Binding(get: { settings.prefs.songBanners }, set: { on in
                        guard on else { settings.prefs.songBanners = false; return }
                        SongBanner.requestPermission { ok in
                            settings.prefs.songBanners = ok
                            if !ok, let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }))
                }
                .help("A notification with the cover when a new song starts (while Velyn isn't in front)")
                row("Keyboard shortcuts") { toggle($settings.prefs.hotKeys) }
                if p.hotKeys { shortcutList }
            }
            card("Phone remote") {
                row("Control \(AppInfo.name) from your phone") { toggle($settings.prefs.phoneRemote) }
                if p.phoneRemote { remoteDetails }
            }
            card("About") {
                HStack {
                    Text("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
                        .font(.system(size: 11.5)).foregroundColor(dim)
                    Spacer()
                    if AppInfo.updateURL != nil {
                        smallButton("Check for Updates…") { Updates.check(userInitiated: true) }
                    }
                }
                if AppInfo.updateURL != nil {
                    row("Check automatically") { toggle($settings.prefs.checkUpdates) }
                }
            }
            HStack {
                smallButton("About \(AppInfo.name)") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Spacer()
                smallButton("Quit \(AppInfo.name)", action: onQuit)
            }
        }
    }

    @ViewBuilder
    private var remoteDetails: some View {
        if let link = remote.link ?? remote.addressLink {
            HStack(alignment: .top, spacing: 12) {
                if let qr = PhoneRemote.qrCode(link) {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: 112, height: 112)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan with your phone's camera. Your phone needs to be on the same Wi-Fi as this Mac.")
                        .font(.system(size: 11)).foregroundColor(label).fixedSize(horizontal: false, vertical: true)
                    Text("Then Share › Add to Home Screen to open it like an app.")
                        .font(.system(size: 11)).foregroundColor(dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let alt = remote.addressLink, alt != link {
                Text("If it doesn't open, try: \(alt.absoluteString.components(separatedBy: "?").first ?? "")")
                    .font(.system(size: 10.5)).foregroundColor(dim).textSelection(.enabled)
            }
            HStack {
                smallButton("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
                smallButton("New Link") { remote.newToken() }
                    .help("Makes a new secret link. Phones using the old one stop working.")
                Spacer()
            }
            Text("Music plays on this Mac, not your phone. The remote only works while the Mac is awake.")
                .font(.system(size: 10.5)).foregroundColor(dim).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(remote.port == nil ? "Starting…" : "This Mac isn't on a network.")
                .font(.system(size: 11)).foregroundColor(dim)
        }
    }

    private var shortcutList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(HotKeys.shared.shortcuts, id: \.key) { s in
                HStack(spacing: 8) {
                    Text(HotKeys.symbols + s.key)
                        .font(.system(size: 11, weight: .medium).monospaced())
                        .foregroundColor(label)
                        .frame(width: 52, alignment: .leading)
                    Text(s.title).font(.system(size: 11)).foregroundColor(dim)
                }
            }
        }
        .padding(.leading, 2)
        .transition(.opacity)
    }

    // MARK: Pieces

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                .foregroundColor(dim)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 11) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundColor(label)
            Spacer(minLength: 8)
            control()
        }
    }

    private func toggle(_ b: Binding<Bool>) -> some View {
        Toggle("", isOn: b).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Brand.accent)
    }

    private func segmented<T: SettingChoice>(_ b: Binding<T>, _ all: [T]) -> some View {
        Picker("", selection: b) {
            ForEach(all) { Text($0.title).tag($0) }
        }
        .labelsHidden().pickerStyle(.segmented).fixedSize()
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double> = 0...1) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundColor(label).frame(width: 78, alignment: .leading)
            Slider(value: v, in: range).controlSize(.small).tint(Brand.accent)
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5)).foregroundColor(label)
                .padding(.horizontal, 10).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.10)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundColor(label)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func displayRow(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "display").font(.system(size: 12)).foregroundColor(on ? Brand.accent : dim)
                Text(name).font(.system(size: 12)).foregroundColor(label).lineLimit(1)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13)).foregroundColor(on ? Brand.accent : dim)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(on ? 0.07 : 0.03)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var glowDisplays: some View {
        let on = Set(GlowOverlays.shared.chosenIDs())
        return VStack(spacing: 5) {
            ForEach(windows.screens) { s in
                displayRow(s.name, on: on.contains(s.id)) { MenuBarPanel.toggleGlowDisplay(s.id, settings: settings) }
            }
        }
    }

    private func wheels(_ p: Prefs) -> some View {
        let share = Int((p.primaryShare * 100).rounded())
        return HStack(alignment: .top, spacing: 18) {
            wheel(p.gradientColors == 2 ? "First \(share)%" : "Color",
                  h: $settings.prefs.primaryH, s: $settings.prefs.primaryS, b: $settings.prefs.primaryB)
            if p.gradientColors == 2 {
                wheel("Second \(100 - share)%",
                      h: $settings.prefs.secondaryH, s: $settings.prefs.secondaryS, b: $settings.prefs.secondaryB)
            }
        }
        .frame(maxWidth: .infinity)
        .help("Double-click a label to change how much of the edge each colour takes")
        .transition(.opacity)
    }

    private func cycleShare() {
        let steps = [0.4, 0.5, 0.6, 0.7]
        let i = steps.firstIndex { abs($0 - settings.prefs.primaryShare) < 0.01 } ?? 1
        settings.prefs.primaryShare = steps[(i + 1) % steps.count]
    }

    private func wheel(_ title: String, h: Binding<Double>, s: Binding<Double>, b: Binding<Double>) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(dim)
                .onTapGesture(count: 2) { cycleShare() }
            ColorWheel(h: h, s: s, v: b.wrappedValue).frame(width: 112, height: 112)
            HStack(spacing: 5) {
                Image(systemName: "sun.min").font(.system(size: 9)).foregroundColor(dim)
                Slider(value: b, in: 0...1).controlSize(.mini).tint(Brand.accent)
                Image(systemName: "sun.max").font(.system(size: 9)).foregroundColor(dim)
            }
            .frame(width: 116)
        }
    }
}

extension LyricStyle {
    /// Icon in the style picker.
    var symbol: String {
        switch self {
        case .stream: return "text.word.spacing"
        case .lens: return "circle.circle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .vine: return "leaf"
        case .weave: return "circle.hexagongrid"
        case .stars: return "sparkles"
        case .spotlight: return "text.alignleft"
        }
    }
}

// MARK: - Colour wheel

/// Hue around the circle (red at 3 o'clock, going clockwise), saturation from the centre out.
/// Brightness comes from the slider under it and darkens the whole wheel.
struct ColorWheel: View {
    @Binding var h: Double
    @Binding var s: Double
    let v: Double

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side / 2
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let a = h * 2 * Double.pi
            let knob = CGPoint(x: c.x + CGFloat(cos(a) * s) * r, y: c.y + CGFloat(sin(a) * s) * r)
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(colors: (0...12).map {
                    RGB(h: Double($0) / 12, s: 1, v: 1).color
                }), center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: r))
                Circle().fill(Color.black.opacity(1 - v))
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().fill(RGB(h: h, s: s, v: v).color))
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(knob)
            }
            .frame(width: side, height: side)
            .position(c)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let dx = Double(g.location.x - c.x), dy = Double(g.location.y - c.y)
                var ang = atan2(dy, dx) / (2 * Double.pi)
                if ang < 0 { ang += 1 }
                h = ang
                s = min(1, (dx * dx + dy * dy).squareRoot() / Double(r))
            })
        }
    }
}
