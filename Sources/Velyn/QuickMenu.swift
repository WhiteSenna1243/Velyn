import AppKit

/// The quick menu: right-click the menu bar icon, or the settings button in a lyrics window.
/// Everything else lives in the settings panel (`MenuBarPanel`).
final class QuickMenu: NSObject, NSMenuDelegate {
    static let shared = QuickMenu()

    private let menu = NSMenu()
    private var engine: Engine?
    private var settings: Settings?

    func configure(engine: Engine, settings: Settings) {
        self.engine = engine
        self.settings = settings
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// At the mouse (lyrics window).
    func popUp() {
        rebuild()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Under the menu bar icon.
    func popUp(under button: NSView) {
        rebuild()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        guard let p = settings?.prefs else { return }
        menu.removeAllItems()
        let t = engine?.state.track
        let now = NSMenuItem(title: t.map { "\($0.title) — \($0.artist)" } ?? "Nothing playing", action: nil, keyEquivalent: "")
        now.isEnabled = false
        menu.addItem(now)
        menu.addItem(.separator())

        add("Show Lyrics Window", #selector(toggleStage), on: p.showStage)
        let styles = NSMenu()
        for (i, s) in LyricStyle.allCases.enumerated() {
            styles.addItem(item(s.title, #selector(pickStyle(_:)), on: p.lyricStyle == s, tag: i))
        }
        submenu("Lyrics Style", styles)
        add("Album Art Behind Lyrics", #selector(toggleArt), on: p.lyricArt).isEnabled = p.lyricStyle.supportsArt
        let choices = NSMenuItem(title: "Lyrics for This Song", action: nil, keyEquivalent: "")
        choices.submenu = LyricChoicesMenu.shared.makeMenu()
        choices.isEnabled = t != nil
        menu.addItem(choices)
        engine?.loadLyricChoices()      // head start, so the list is usually ready when you get there

        menu.addItem(.separator())
        add("Glow", #selector(toggleGlow), on: p.glowEnabled)
        let motion = NSMenu()
        for (i, m) in GlowAnimation.allCases.enumerated() {
            motion.addItem(item(m.title, #selector(pickMotion(_:)), on: p.glowMode == m, tag: i))
        }
        submenu("Glow Motion", motion)

        let sleep = NSMenu()
        let on = engine?.sleepAt != nil || engine?.sleepAtSongEnd == true
        sleep.addItem(item("Off", #selector(pickSleep(_:)), on: !on, tag: 0))
        for m in [15, 30, 45, 60] {
            sleep.addItem(item("\(m) Minutes", #selector(pickSleep(_:)), tag: m))
        }
        sleep.addItem(item("End of This Song", #selector(pickSleep(_:)), on: engine?.sleepAtSongEnd == true, tag: -1))
        var title = "Sleep Timer"
        if let left = engine?.sleepMinutesLeft { title += " (\(left) min left)" }
        else if engine?.sleepAtSongEnd == true { title += " (end of song)" }
        submenu(title, sleep)

        menu.addItem(.separator())
        add("Show Player", #selector(showPlayer))
        add("Search & Queue…", #selector(showBrowse))
        add("Settings…", #selector(showSettings))
        menu.addItem(.separator())
        let quit = add("Quit \(AppInfo.name)", #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false, tag: Int = 0) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.state = on ? .on : .off
        it.tag = tag
        return it
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let it = item(title, action, on: on)
        menu.addItem(it)
        return it
    }

    private func submenu(_ title: String, _ sub: NSMenu) {
        sub.autoenablesItems = false
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        menu.addItem(it)
    }

    @objc private func toggleStage() { settings?.prefs.showStage.toggle() }
    @objc private func pickStyle(_ s: NSMenuItem) { settings?.prefs.lyricStyle = LyricStyle.allCases[s.tag] }
    @objc private func toggleArt() { settings?.prefs.lyricArt.toggle() }
    @objc private func pickSleep(_ s: NSMenuItem) { engine?.setSleep(minutes: s.tag) }
    @objc private func toggleGlow() { settings?.prefs.glowEnabled.toggle() }
    @objc private func pickMotion(_ s: NSMenuItem) { settings?.prefs.glowMode = GlowAnimation.allCases[s.tag] }
    @objc private func showPlayer() {
        guard let engine, let settings else { return }
        PlayerWindow.shared.show(engine: engine, settings: settings)
    }
    @objc private func showBrowse() {
        guard let engine, let settings else { return }
        PlayerWindow.shared.show(engine: engine, settings: settings, mode: .browse)
    }
    @objc private func showSettings() { MenuBarPanel.shared.show(tab: .lyrics) }
    @objc private func quit() { NSApp.terminate(nil) }
}
