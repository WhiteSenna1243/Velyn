import AppKit
import Combine

/// "Lyrics for This Song": the other versions LRCLIB has for the song playing, to fix wrong or
/// badly timed lyrics. Your pick is remembered for that song. Shown as a submenu of the lyrics
/// menu and popped up from the player's lyrics card.
final class LyricChoicesMenu: NSObject, NSMenuDelegate {
    static let shared = LyricChoicesMenu()

    private var engine: Engine?
    private var bag: Set<AnyCancellable> = []
    private let openMenus = NSHashTable<NSMenu>.weakObjects()

    func configure(engine: Engine) {
        self.engine = engine
        // Results arrive while the menu is open: refill it in place.
        // (Main-queue work still runs while a menu is being tracked.)
        engine.$lyricChoices.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshOpen() } }
            .store(in: &bag)
    }

    /// A fresh menu (as a submenu, it fills itself when it opens).
    func makeMenu() -> NSMenu {
        let m = NSMenu(title: "Lyrics for This Song")
        m.delegate = self
        m.autoenablesItems = false
        return m
    }

    /// Pops the menu up at the mouse.
    func popUp() {
        let m = makeMenu()
        engine?.loadLyricChoices()
        fill(m)
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        openMenus.add(menu)
        engine?.loadLyricChoices()
        fill(menu)
    }

    func menuDidClose(_ menu: NSMenu) { openMenus.remove(menu) }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    private func refreshOpen() { openMenus.allObjects.forEach(fill) }

    // MARK: Contents

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let engine, let track = engine.state.track else {
            menu.addItem(note("Nothing playing"))
            return
        }
        menu.addItem(.sectionHeader(title: "This song is \(Self.time(track.duration)). Pick a version:"))
        if let list = engine.lyricChoices {
            if list.isEmpty { menu.addItem(note("No versions with synced lyrics")) }
            for c in list {
                let it = NSMenuItem(title: "\(c.artist) — \(c.title)", action: #selector(pick(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = NSNumber(value: c.id)
                it.state = c.id == engine.lyricsID ? .on : .off
                var bits = [Self.time(c.duration)]
                if c.synced == nil { bits.append("Instrumental") }
                if !c.album.isEmpty { bits.append(c.album) }
                let details = bits.joined(separator: " · ")
                if #available(macOS 14.4, *) { it.subtitle = details } else { it.title += "  (\(details))" }
                menu.addItem(it)
            }
        } else if engine.lyricChoicesFailed {
            menu.addItem(note("Couldn't reach LRCLIB. Try again in a moment."))
        } else {
            menu.addItem(note("Searching…"))
        }
        menu.addItem(.separator())
        let again = NSMenuItem(title: engine.lyricsPicked ? "Forget My Pick" : "Find Lyrics Again",
                               action: #selector(findAgain), keyEquivalent: "")
        again.target = self
        menu.addItem(again)
    }

    private func note(_ s: String) -> NSMenuItem {
        let it = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Actions

    @objc private func pick(_ item: NSMenuItem) {
        guard let engine, let id = (item.representedObject as? NSNumber)?.intValue,
              let c = engine.lyricChoices?.first(where: { $0.id == id }) else { return }
        engine.pickLyrics(c)
    }

    @objc private func findAgain() { engine?.findLyricsAgain() }
}
