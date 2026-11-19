import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

// MARK: - Keyboard shortcuts

/// Global keyboard shortcuts: they work from any app. Carbon hot keys need no Accessibility
/// permission. All use ⌃⌥⌘ so they don't clash with window managers that use ⌃⌥.
final class HotKeys {
    static let shared = HotKeys()

    struct Shortcut {
        let keyCode: Int
        let key: String
        let title: String
        let action: (HotKeys) -> Void
    }

    static let symbols = "⌃⌥⌘"
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let signature: OSType = 0x564C594E   // 'VLYN'

    let shortcuts: [Shortcut] = [
        Shortcut(keyCode: kVK_ANSI_G, key: "G", title: "Glow on / off") { $0.settings?.prefs.glowEnabled.toggle() },
        Shortcut(keyCode: kVK_ANSI_L, key: "L", title: "Show / hide lyrics") { $0.settings?.prefs.showStage.toggle() },
        Shortcut(keyCode: kVK_ANSI_P, key: "P", title: "Show / hide player") { $0.togglePlayer() },
        Shortcut(keyCode: kVK_ANSI_LeftBracket, key: "[", title: "Lyric timing −0.25 s") { $0.engine?.nudgeLyrics(-0.25) },
        Shortcut(keyCode: kVK_ANSI_RightBracket, key: "]", title: "Lyric timing +0.25 s") { $0.engine?.nudgeLyrics(0.25) },
    ]

    private var engine: Engine?
    private var settings: Settings?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var bag: Set<AnyCancellable> = []

    func configure(engine: Engine, settings: Settings) {
        self.engine = engine
        self.settings = settings
        settings.$prefs.map(\.hotKeys).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in if on { self?.register() } else { self?.unregister() } }
            .store(in: &bag)
    }

    private func register() {
        guard refs.isEmpty else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID), nil,
                                            MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard err == noErr, id.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { HotKeys.shared.fire(Int(id.id)) }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        for (i, s) in shortcuts.enumerated() {
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(UInt32(s.keyCode), Self.modifiers,
                                          EventHotKeyID(signature: Self.signature, id: UInt32(i)),
                                          GetApplicationEventTarget(), 0, &ref)
            if err == noErr, let ref { refs.append(ref) }
            else { NSLog("Velyn: shortcut \(Self.symbols)\(s.key) is already used by another app (\(err))") }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func fire(_ i: Int) {
        guard shortcuts.indices.contains(i) else { return }
        #if DEBUG
        fired.append(i)
        #endif
        shortcuts[i].action(self)
    }

    #if DEBUG
    private var fired: [Int] = []

    /// Dev aid: registers the shortcuts, then sends one hot-key event to Velyn itself
    /// (a real key press would need Accessibility for the sender) and checks it arrives.
    func selfTest() -> String {
        register()
        var out = "registered \(refs.count) of \(shortcuts.count), handler \(handler != nil ? "installed" : "missing")"
        var ev: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                    EventAttributes(kEventAttributeNone), &ev)
        guard let ev else { return out + ", could not make a test event" }
        var id = EventHotKeyID(signature: Self.signature, id: 2)
        SetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &id)
        let err = SendEventToEventTarget(ev, GetApplicationEventTarget())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        out += ", test event -> \(err == noErr ? "handled" : "error \(err)"), fired \(fired)"
        unregister()
        return out
    }
    #endif

    private func togglePlayer() {
        guard let engine, let settings else { return }
        if let w = PlayerWindow.shared.window, w.isVisible, w.isKeyWindow, NSApp.isActive {
            w.orderOut(nil)
        } else {
            PlayerWindow.shared.show(engine: engine, settings: settings)
        }
    }
}

// MARK: - Launch at login

/// "Launch at login" through macOS's own login items (System Settings > General > Login Items).
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns it on or off and returns the state afterwards. macOS may ask for approval first.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        let app = SMAppService.mainApp
        do {
            if on { try app.register() } else { try app.unregister() }
        } catch {
            NSLog("Velyn: login item: \(error)")
        }
        if on && app.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return isOn
    }
}
