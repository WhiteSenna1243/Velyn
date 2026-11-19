import AppKit
import SwiftUI
import Combine

/// Edge glow: one transparent, click-through window per chosen display,
/// sitting above everything (menu bar and full-screen apps included).
final class GlowOverlays {
    static let shared = GlowOverlays()

    private var windows: [UInt32: NSWindow] = [:]
    private var engine: Engine?
    private var settings: Settings?
    private var bag: Set<AnyCancellable> = []
    private var screenToken: NSObjectProtocol?

    func configure(engine: Engine, settings: Settings) {
        self.engine = engine
        self.settings = settings
        settings.$prefs
            .map { [$0.glowEnabled ? 1 : 0, $0.glowFollowsApp ? 1 : 0] + $0.glowDisplays.map { Int($0) } }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &bag)
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        // Velyn windows move, minimise, change Space or hide; check where they are twice a second.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.sync() }
        sync()
    }
    private var timer: Timer?

    /// Displays picked in Settings > Display. Empty selection means the main display.
    func chosenIDs() -> [UInt32] {
        guard let p = settings?.prefs else { return [] }
        let live = NSScreen.screens.compactMap { WindowManager.id(of: $0) }
        let chosen = p.glowDisplays.filter { live.contains($0) }
        if !chosen.isEmpty { return chosen }
        return (NSScreen.main ?? NSScreen.screens.first).flatMap { WindowManager.id(of: $0) }.map { [$0] } ?? []
    }

    /// Displays glowing right now: the chosen ones, and with "Only where Velyn is open",
    /// only those that have a Velyn window showing (the main display rule is dropped then,
    /// so the glow follows Velyn to whichever display it is on).
    func targetIDs() -> [UInt32] {
        guard let p = settings?.prefs, p.glowEnabled else { return [] }
        guard p.glowFollowsApp else { return chosenIDs() }
        let showing = Self.haloScreens()
        if p.glowDisplays.isEmpty { return Array(showing) }
        return chosenIDs().filter { showing.contains($0) }
    }

    /// Displays with a Velyn window that you can see: open, not minimised, on the current Space.
    static func haloScreens() -> Set<UInt32> {
        if NSApp.isHidden { return [] }
        var wins = WindowManager.shared.stageWindows
        if let w = PlayerWindow.shared.window { wins.append(w) }
        var out = Set<UInt32>()
        for w in wins where w.isVisible && !w.isMiniaturized && w.isOnActiveSpace {
            if let s = w.screen, let id = WindowManager.id(of: s) { out.insert(id) }
        }
        return out
    }

    private func rebuild() {
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        sync()
    }

    private func sync() {
        let want = Set(targetIDs())
        for (id, w) in windows where !want.contains(id) {
            w.orderOut(nil)
            windows[id] = nil
        }
        for id in want where windows[id] == nil {
            if let s = NSScreen.screens.first(where: { WindowManager.id(of: $0) == id }) {
                windows[id] = makeWindow(on: s)
            }
        }
    }

    /// The notch in screen-local points (origin top-left), if this display has one.
    static func notchRect(_ s: NSScreen) -> CGRect? {
        guard s.safeAreaInsets.top > 0,
              let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea else { return nil }
        let x0 = left.maxX - s.frame.minX
        let x1 = right.minX - s.frame.minX
        guard x1 > x0 else { return nil }
        return CGRect(x: x0, y: 0, width: x1 - x0, height: s.safeAreaInsets.top)
    }

    private func makeWindow(on s: NSScreen) -> NSWindow? {
        guard let engine, let settings else { return nil }
        let root = GlowLayer(notch: Self.notchRect(s))
            .environmentObject(engine)
            .environmentObject(settings)
            .ignoresSafeArea()
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []

        let w = NSWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.setFrame(s.frame, display: true)
        w.orderFrontRegardless()
        return w
    }
}
