import Foundation

/// Name, version and which build this is.
enum AppInfo {
    static let name = "Velyn"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    /// The Mac App Store build: sandboxed, no private macOS calls (no lock screen lyrics),
    /// animated covers only through the official Apple Music API. Set by `tools/package.sh appstore`.
    #if APPSTORE
    static let appStore = true
    #else
    static let appStore = false
    #endif

    /// Website build: where to check for a newer version (Info.plist `VelynUpdateURL`, a small JSON
    /// file: {"version": "1.1", "url": "https://.../Velyn.dmg", "notes": "..."}). nil = no update checks.
    static var updateURL: URL? {
        guard !appStore, let s = Bundle.main.infoDictionary?["VelynUpdateURL"] as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }
}

/// Brings settings and saved lyrics over from Halo, the earlier personal build. Website build only:
/// the App Store sandbox can't read other apps' files, so there it starts fresh.
enum Migration {
    static let oldDomain = "local.halo.personal"

    static func oldPrefs() -> Data? {
        AppInfo.appStore ? nil : UserDefaults(suiteName: oldDomain)?.data(forKey: "halo.prefs.v3")
    }

    static func run() {
        guard !AppInfo.appStore else { return }
        let d = UserDefaults.standard
        if d.object(forKey: "velyn.open.displays") == nil,
           let old = UserDefaults(suiteName: oldDomain)?.object(forKey: "halo.open.displays") {
            d.set(old, forKey: "velyn.open.displays")
        }
        let fm = FileManager.default
        let old = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halo/Lyrics", isDirectory: true)
        let new = LyricsStore.folder
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: old, to: new)      // a copy: Halo keeps its own
        }
    }
}
