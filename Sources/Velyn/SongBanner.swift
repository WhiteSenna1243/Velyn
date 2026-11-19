import AppKit
import UserNotifications

/// "Song banners": a notification with the cover and the song when a new one starts,
/// only while Velyn isn't the app in front. Each banner replaces the last one.
enum SongBanner {
    /// Asks macOS for permission (the first time); `done(true)` if banners may be shown.
    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    static func show(_ t: Track, art: NSImage?) {
        guard !NSApp.isActive else { return }
        let c = UNMutableNotificationContent()
        c.title = t.title
        c.body = t.album.isEmpty ? t.artist : "\(t.artist) · \(t.album)"
        if let art, let file = jpeg(art),
           let a = try? UNNotificationAttachment(identifier: "cover", url: file, options: nil) {
            c.attachments = [a]
        }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["velyn.song"])
        center.add(UNNotificationRequest(identifier: "velyn.song", content: c, trigger: nil))
    }

    /// The cover as a small JPEG file (macOS moves attachment files, so each banner gets a new one).
    private static func jpeg(_ img: NSImage) -> URL? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("velyn-cover-\(UUID().uuidString).jpg")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
