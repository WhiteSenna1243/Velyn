import SwiftUI
import AppKit

/// First-launch welcome: what Velyn is, the two permissions and why, and where things are.
/// Shown once (and from the app menu: "Welcome to Velyn…").
final class WelcomeWindow {
    static let shared = WelcomeWindow()
    private var window: NSWindow?
    private static let seenKey = "velyn.welcomed"

    func showIfFirstLaunch(settings: Settings) {
        guard !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        show(settings: settings)
    }

    func show(settings: Settings) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let root = WelcomeView(onDone: { [weak self] in self?.close() }).environmentObject(settings)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        window?.close()
        window = nil
    }
}

struct WelcomeView: View {
    @EnvironmentObject var settings: Settings
    let onDone: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: intro
                case 1: permissions
                default: tour
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(page)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle().fill(i == page ? Brand.accent : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }.controlSize(.large)
                }
                Button(page < 2 ? "Continue" : "Get Started") {
                    if page < 2 { withAnimation { page += 1 } } else { onDone() }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .tint(Brand.accent)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 560, height: 470)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(colors: [Brand.violet.color.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        )
    }

    private var intro: some View {
        VStack(spacing: 14) {
            AuraMark(rays: 120, bloom: true).frame(width: 150, height: 150)
            Text("Welcome to \(AppInfo.name)").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Synced lyrics, an animated player and a glow around your screen that moves with the music. For Apple Music and Spotify.")
                .font(.system(size: 14)).foregroundColor(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(.top, 30)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Two quick permissions").font(.system(size: 24, weight: .bold, design: .rounded))
            Text("macOS asks for these the first time a song plays. Click Allow on both.")
                .font(.system(size: 13)).foregroundColor(.secondary)
            item("music.note", "Control Music and Spotify",
                 "So \(AppInfo.name) can see what's playing, find its lyrics, and play, pause and skip for you.")
            item("waveform", "Listen to your Mac's sound",
                 "So the glow can pulse with the bass and beats. Nothing is recorded or sent anywhere.")
            Text("You can change either one later in System Settings > Privacy & Security.")
                .font(.system(size: 11.5)).foregroundColor(.secondary)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(.top, 40)
    }

    private var tour: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where things are").font(.system(size: 24, weight: .bold, design: .rounded))
            item("circle.dotted", "The menu bar icon", "Click it for settings (glow, lyrics, lock screen). Right-click for a quick menu.")
            item("music.note.list", "Search & Queue", "Press ⌘F in the player to search your songs and playlists and queue them.")
            item("lock.display", "Lock screen", "Your song and lyrics show when you lock your Mac. Pick the look in Settings > General.")
            HStack(alignment: .top, spacing: 14) {
                icon("iphone")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Phone remote").font(.system(size: 14, weight: .semibold))
                    Text("Control \(AppInfo.name) from your phone on the same Wi-Fi.").font(.system(size: 12.5)).foregroundColor(.secondary)
                    Button(settings.prefs.phoneRemote ? "Show QR Code" : "Set Up Phone Remote") {
                        settings.prefs.phoneRemote = true
                        onDone()
                        MenuBarPanel.shared.show(tab: .general)
                    }
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(.top, 34)
    }

    private func item(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 12.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundColor(Brand.accent)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.accent.opacity(0.14)))
    }
}
