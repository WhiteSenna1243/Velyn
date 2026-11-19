import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    let settings = Settings()
    private var keyMonitor: Any?
    private let displayMenu = NSMenu(title: "Display")
    private var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.run()
        buildMenus()
        let wm = WindowManager.shared
        wm.configure(engine: engine, settings: settings)
        engine.start(settings: settings)

        // Edge glow on the chosen displays, the menu bar icon and its panel, the player window.
        GlowOverlays.shared.configure(engine: engine, settings: settings)
        MenuBarPanel.shared.configure(engine: engine, settings: settings)
        LockScreen.shared.configure(engine: engine, settings: settings)
        // The quick menu, and the lyrics window(s).
        QuickMenu.shared.configure(engine: engine, settings: settings)
        HotKeys.shared.configure(engine: engine, settings: settings)
        LyricChoicesMenu.shared.configure(engine: engine)
        PhoneRemote.shared.configure(engine: engine, settings: settings)
        if settings.prefs.showStage { wm.restoreWindows() }
        PlayerWindow.shared.show(engine: engine, settings: settings)
        Updates.checkOnLaunch(settings: settings)
        WelcomeWindow.shared.showIfFirstLaunch(settings: settings)

        settings.$prefs.map(\.showStage).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { show in
                if show { if wm.windowCount == 0 { wm.restoreWindows() } } else { wm.closeAll() }
            }
            .store(in: &bag)
        settings.$prefs.map(\.motionArt).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.engine.refreshMotion() }
            .store(in: &bag)
        settings.$prefs.map(\.showInDock).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { dock in
                NSApp.setActivationPolicy(dock ? .regular : .accessory)
                if dock { NSApp.activate(ignoringOtherApps: true) }
            }
            .store(in: &bag)
        NSApp.activate(ignoringOtherApps: true)

        // Space = play/pause, like Apple Music (unless you're typing in a field).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            self.engine.togglePlay()
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.audio.stop()
    }

    // Velyn lives in the menu bar too, so closing windows doesn't quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PlayerWindow.shared.show(engine: engine, settings: settings) }
        return true
    }

    // MARK: - Menus

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        return it
    }

    private func buildMenus() {
        let main = NSMenu()

        // App
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AppInfo.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(item("Welcome to \(AppInfo.name)…", #selector(showWelcome), "", []))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Playback
        let playItem = NSMenuItem()
        let play = NSMenu(title: "Playback")
        play.addItem(item("Play / Pause", #selector(togglePlay), "p"))
        play.addItem(item("Next", #selector(nextTrack), String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        play.addItem(item("Previous", #selector(previousTrack), String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        play.addItem(.separator())
        play.addItem(item("Shuffle", #selector(toggleShuffle), "s"))
        play.addItem(item("Repeat", #selector(cycleRepeat), "r"))
        play.addItem(.separator())
        play.addItem(item("Volume Up", #selector(volumeUp), String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        play.addItem(item("Volume Down", #selector(volumeDown), String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        playItem.submenu = play
        main.addItem(playItem)

        // View
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let fs = NSMenuItem(title: "Enter Full Screen",
                            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fs)
        viewItem.submenu = view
        main.addItem(viewItem)

        // Display (rebuilt each time it opens)
        let dispItem = NSMenuItem()
        displayMenu.delegate = self
        dispItem.submenu = displayMenu
        main.addItem(dispItem)

        // Window
        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        win.addItem(item("Player", #selector(showPlayer), "1"))
        win.addItem(item("Lyrics", #selector(showLyrics), "2"))
        win.addItem(item("Search & Queue", #selector(showBrowse), "f"))
        win.addItem(item("Settings…", #selector(showGlowPanel), ","))
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === displayMenu else { return }
        menu.removeAllItems()
        let wm = WindowManager.shared
        wm.refresh()
        for s in wm.screens {
            let it = NSMenuItem(title: "Lyrics on \(s.name)", action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: s.id)
            it.state = wm.openIDs.contains(s.id) ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        for s in wm.screens {
            let it = NSMenuItem(title: "Full Screen on \(s.name)", action: #selector(fullScreenDisplay(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: s.id)
            it.state = wm.isFullScreen(on: s.id) ? .on : .off
            menu.addItem(it)
        }
    }

    // MARK: - Actions

    @objc private func showWelcome() { WelcomeWindow.shared.show(settings: settings) }
    @objc private func showPlayer() { PlayerWindow.shared.show(engine: engine, settings: settings) }
    @objc private func showBrowse() { PlayerWindow.shared.show(engine: engine, settings: settings, mode: .browse) }
    @objc private func showGlowPanel() { MenuBarPanel.shared.toggle(tab: .glow) }
    @objc private func showLyrics() {
        if settings.prefs.showStage, WindowManager.shared.windowCount == 0 { WindowManager.shared.restoreWindows() }
        settings.prefs.showStage = true
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePlay() { engine.togglePlay() }
    @objc private func nextTrack() { engine.next() }
    @objc private func previousTrack() { engine.previous() }
    @objc private func toggleShuffle() { engine.toggleShuffle() }
    @objc private func cycleRepeat() { engine.cycleRepeat() }
    @objc private func volumeUp() { engine.nudgeVolume(0.06) }
    @objc private func volumeDown() { engine.nudgeVolume(-0.06) }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber { WindowManager.shared.toggle(n.uint32Value) }
    }

    @objc private func fullScreenDisplay(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber { WindowManager.shared.toggleFullScreen(on: n.uint32Value) }
    }
}
