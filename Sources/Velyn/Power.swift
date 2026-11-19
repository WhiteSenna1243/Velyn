import AppKit
import SwiftUI
import Combine

/// Battery saver: tells the glow, the lyrics and the animated cover how fast to draw.
/// Full speed while music plays, slow while paused, stopped while the screens are off,
/// another user is logged in, or (for windows behind it) the Mac is locked.
/// Low Power Mode halves the frame rate. Also tracks Reduce Motion (Accessibility > Display).
final class Power: ObservableObject {
    static let shared = Power()

    @Published private(set) var screensAsleep = false
    @Published private(set) var sessionInactive = false
    @Published private(set) var locked = false
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// System Settings > Accessibility > Display > Reduce motion: calmer glow and lyrics.
    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var tokens: [NSObjectProtocol] = []

    private init() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ c: NotificationCenter, _ name: Notification.Name, _ f: @escaping (Power) -> Void) {
            tokens.append(c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self { f(self) }
            })
        }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        on(ws, NSWorkspace.willSleepNotification) { $0.screensAsleep = true }
        on(ws, NSWorkspace.didWakeNotification) { $0.screensAsleep = false }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        on(.default, .NSProcessInfoPowerStateDidChange) { $0.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        on(ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        let dnc = DistributedNotificationCenter.default()
        on(dnc, .init("com.apple.screenIsLocked")) { $0.locked = true }
        on(dnc, .init("com.apple.screenIsUnlocked")) { $0.locked = false }
        locked = LockScreen.screenIsLocked()
    }

    /// Nothing on screen can be seen at all.
    var dark: Bool { screensAsleep || sessionInactive }

    /// Glow frames per second; 0 = stop drawing.
    /// `lockScreen` is true for the glow drawn on the lock screen itself.
    func glowFPS(playing: Bool, mode: GlowAnimation, lockScreen: Bool) -> Int {
        if dark || (locked && !lockScreen) { return 0 }
        let full = lowPower ? 30 : 60
        switch mode {
        case .none: return 10                                  // nothing moves
        case .musicSync: return playing ? full : (lowPower ? 12 : 24)   // slow breathing while paused
        case .standard, .idle: return full
        }
    }

    /// Lyrics frames per second; 0 = stop. `visible` is false when the window is covered,
    /// minimised or on another Space.
    func lyricsFPS(playing: Bool, visible: Bool, lockScreen: Bool, full: Int = 60) -> Int {
        if dark || !visible || (locked && !lockScreen) { return 0 }
        if !playing { return 12 }
        return lowPower ? min(full, 30) : full
    }

    static func schedule(_ fps: Int) -> AnimationTimelineSchedule {
        .animation(minimumInterval: 1.0 / Double(max(fps, 1)), paused: fps == 0)
    }
}

// MARK: - Where a view is being drawn

private struct OnLockScreenKey: EnvironmentKey { static let defaultValue = false }
private struct WindowVisibleKey: EnvironmentKey { static let defaultValue = true }
private struct InkKey: EnvironmentKey { static let defaultValue = Color.primary }

extension EnvironmentValues {
    /// True inside the lock-screen windows (they keep drawing while locked).
    var onLockScreen: Bool {
        get { self[OnLockScreenKey.self] }
        set { self[OnLockScreenKey.self] = newValue }
    }
    /// Text colour for player pieces: white, or black on a white lock screen.
    var ink: Color {
        get { self[InkKey.self] }
        set { self[InkKey.self] = newValue }
    }
    /// False when the window this view is in can't be seen (covered, minimised, another Space).
    var windowVisible: Bool {
        get { self[WindowVisibleKey.self] }
        set { self[WindowVisibleKey.self] = newValue }
    }
}

extension View {
    /// Tracks whether the hosting window can be seen and passes it down as `windowVisible`.
    func tracksWindowVisibility() -> some View { modifier(WindowVisibilityModifier()) }
}

private struct WindowVisibilityModifier: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .environment(\.windowVisible, visible)
            .background(WindowVisibilityReader { v in if v != visible { visible = v } })
    }
}

/// Reports the window's occlusion state (macOS tells us when a window is fully covered).
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: Probe, context: Context) { v.onChange = onChange }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let w = window else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                           object: w, queue: .main) { [weak self] _ in self?.report() }
            report()
        }

        private func report() {
            let v = window.map { $0.occlusionState.contains(.visible) } ?? false
            DispatchQueue.main.async { [weak self] in self?.onChange?(v) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
