import AppKit
import SwiftUI
import Combine

/// State of one Velyn window, read by the views inside it.
final class WindowContext: ObservableObject {
    weak var window: NSWindow?
    @Published var isFullScreen = false
    @Published var screenID: UInt32 = 0
    /// Fires on any mouse press / drag inside this window (used for click-to-reveal controls).
    let interaction = PassthroughSubject<Void, Never>()
    /// Fires when this window stops being the key window.
    let resigned = PassthroughSubject<Void, Never>()
    var mouseMonitor: Any?

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    /// The X button: leaves full screen, or closes the window if it's windowed.
    func exitOrClose() {
        guard let w = window else { return }
        if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) } else { w.close() }
    }
}

/// Opens and tracks the lyrics windows: one per display if you want, all
/// sharing one Engine so playback and lyrics stay in sync everywhere.
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    struct Info: Identifiable, Equatable {
        let id: UInt32
        let name: String
    }

    private struct Entry {
        let window: NSWindow
        let ctx: WindowContext
        var tokens: [NSObjectProtocol]
    }

    @Published private(set) var screens: [Info] = []
    @Published private(set) var openIDs: Set<UInt32> = []
    /// Number of open Velyn windows. More than one switches the controls to click-to-reveal.
    @Published private(set) var windowTotal = 0

    private var entries: [Entry] = []
    private var engine: Engine?
    private var settings: Settings?
    private var screenToken: NSObjectProtocol?
    private var closingAll = false
    private let savedKey = "velyn.open.displays"

    static func id(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func screen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { Self.id(of: $0) == id }
    }

    var windowCount: Int { entries.count }
    var stageWindows: [NSWindow] { entries.map(\.window) }

    func configure(engine: Engine, settings: Settings) {
        self.engine = engine
        self.settings = settings
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Reopens the displays used last time (or the main display on first launch).
    func restoreWindows() {
        let saved = (UserDefaults.standard.array(forKey: savedKey) as? [Int]) ?? []
        let ids = saved.compactMap { UInt32(exactly: $0) }.filter { screen(for: $0) != nil }
        if ids.isEmpty {
            openWindow(on: nil)
        } else {
            for id in ids { openWindow(on: id) }
        }
    }

    @discardableResult
    func openWindow(on screenID: UInt32?) -> NSWindow? {
        guard let engine, let settings else { return nil }
        let target = screenID.flatMap { screen(for: $0) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return nil }

        let ctx = WindowContext()
        let root = StageView()
            .tracksWindowVisibility()
            .environmentObject(engine)
            .environmentObject(settings)
            .environmentObject(self)
            .environmentObject(ctx)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []   // the window decides its size, not SwiftUI

        let vf = target.visibleFrame
        let size = NSSize(width: min(1180, vf.width * 0.9), height: min(740, vf.height * 0.9))
        let rect = NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                          width: size.width, height: size.height)
        let w = NSWindow(contentRect: rect,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentView = host
        w.title = "\(AppInfo.name) Lyrics"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 480)
        w.collectionBehavior.insert(.fullScreenPrimary)
        ctx.window = w

        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification
        ]
        var tokens: [NSObjectProtocol] = names.map { name in
            nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.refresh() }
        }
        tokens.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self, weak w] _ in
            guard let self, let w else { return }
            self.remove(w)
        })
        tokens.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak ctx] _ in
            ctx?.resigned.send()
        })
        ctx.mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .rightMouseDown]) { [weak w, weak ctx] event in
            if let w, let ctx, event.window === w { ctx.interaction.send() }
            return event
        }
        entries.append(Entry(window: w, ctx: ctx, tokens: tokens))

        w.makeKeyAndOrderFront(nil)
        refresh()
        return w
    }

    private func remove(_ w: NSWindow) {
        if let i = entries.firstIndex(where: { $0.window === w }) {
            entries[i].tokens.forEach { NotificationCenter.default.removeObserver($0) }
            if let m = entries[i].ctx.mouseMonitor { NSEvent.removeMonitor(m) }
            entries.remove(at: i)
        }
        // Closing the last lyrics window by hand turns "Non-lockscreen Visibility" off.
        if entries.isEmpty, !closingAll, settings?.prefs.showStage == true {
            settings?.prefs.showStage = false
        }
        refresh()
    }

    /// Closes every lyrics window without changing the setting or the saved layout.
    func closeAll() {
        closingAll = true
        let saved = UserDefaults.standard.array(forKey: savedKey)
        entries.map(\.window).forEach { $0.close() }
        if let saved { UserDefaults.standard.set(saved, forKey: savedKey) }
        closingAll = false
    }

    /// Opens Velyn on a display, or closes the window there (never the last one).
    func toggle(_ id: UInt32) {
        if let e = entries.first(where: { windowScreenID($0.window) == id }) {
            if entries.count > 1 { e.window.close() }
        } else {
            openWindow(on: id)
        }
    }

    func toggleFullScreen(on id: UInt32) {
        if let e = entries.first(where: { windowScreenID($0.window) == id }) {
            e.window.toggleFullScreen(nil)
        } else if let w = openWindow(on: id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { w.toggleFullScreen(nil) }
        }
    }

    func isFullScreen(on id: UInt32) -> Bool {
        entries.first(where: { windowScreenID($0.window) == id })?.window.styleMask.contains(.fullScreen) ?? false
    }

    private func windowScreenID(_ w: NSWindow) -> UInt32? {
        w.screen.flatMap { Self.id(of: $0) }
    }

    func refresh() {
        let list: [Info] = NSScreen.screens.compactMap { s in
            Self.id(of: s).map { Info(id: $0, name: s.localizedName) }
        }
        if list != screens { screens = list }

        var ids = Set<UInt32>()
        for e in entries {
            if let id = windowScreenID(e.window) {
                ids.insert(id)
                if e.ctx.screenID != id { e.ctx.screenID = id }
            }
            let fs = e.window.styleMask.contains(.fullScreen)
            if e.ctx.isFullScreen != fs { e.ctx.isFullScreen = fs }
        }
        if ids != openIDs { openIDs = ids }
        if windowTotal != entries.count { windowTotal = entries.count }
        // Remember the layout (but not the empty state while quitting).
        if !ids.isEmpty {
            UserDefaults.standard.set(ids.map { Int($0) }, forKey: savedKey)
        }
    }
}
