import AppKit

/// Update checks for the website build. It reads a small JSON file you host
/// (Info.plist `VelynUpdateURL`): {"version": "1.1", "url": "https://.../Velyn.dmg", "notes": "What's new"}.
/// The App Store build has none (the App Store updates it).
enum Updates {
    struct Info: Decodable {
        let version: String
        let url: String
        let notes: String?
    }

    private static let lastKey = "velyn.updates.last"

    /// At launch, at most once a day, when "Check automatically" is on.
    static func checkOnLaunch(settings: Settings) {
        guard settings.prefs.checkUpdates, AppInfo.updateURL != nil else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(userInitiated: false)
    }

    static func check(userInitiated: Bool) {
        guard let url = AppInfo.updateURL else { return }
        Task {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 15
            let info = (try? await URLSession.shared.data(for: req)).flatMap { try? JSONDecoder().decode(Info.self, from: $0.0) }
            await MainActor.run { present(info, userInitiated: userInitiated) }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    private static func present(_ info: Info?, userInitiated: Bool) {
        if info != nil { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey) }
        let a = NSAlert()
        if let info, isNewer(info.version, than: AppInfo.version), let link = URL(string: info.url) {
            a.messageText = "\(AppInfo.name) \(info.version) is available"
            a.informativeText = (info.notes.map { $0 + "\n\n" } ?? "") + "You have \(AppInfo.version)."
            a.addButton(withTitle: "Download")
            a.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(link) }
        } else if userInitiated {
            a.messageText = info == nil ? "Couldn't check for updates" : "\(AppInfo.name) is up to date"
            a.informativeText = info == nil ? "Check your internet connection and try again." : "You have the latest version, \(AppInfo.version)."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }
}
