import SwiftUI
import AppKit

private let ink = Color.primary.opacity(0.9)
private let faint = Color.primary.opacity(0.5)

/// Search & Queue: find songs in your Music library (or paste a Spotify song link) on the left,
/// Velyn's up-next list on the right.
struct BrowseCard: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var library = MusicLibrary.shared
    @State private var query = ""
    @State private var results: [Song] = []
    @State private var spotify: Song?
    @State private var catalog: [CatalogSong] = []
    @State private var openPlaylist: MusicLibrary.Playlist?
    @State private var flash: String?               // song id that was just queued (shows a tick)
    @FocusState private var searchFocused: Bool

    init(query: String = "", playlist: MusicLibrary.Playlist? = nil) {
        _query = State(initialValue: query)
        _openPlaylist = State(initialValue: playlist)
        _results = State(initialValue: MusicLibrary.shared.search(query))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                searchField
                resultsArea
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 26)
            .padding(.vertical, 26)

            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
                .padding(.vertical, 30)
                .padding(.horizontal, 22)

            QueueColumn(queue: engine.queue)
                .frame(width: 270)
                .padding(.trailing, 24)
                .padding(.vertical, 26)
        }
        .frame(maxWidth: 880, maxHeight: 500)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 40)
        .onAppear {
            library.refreshIfNeeded()
            DispatchQueue.main.async { searchFocused = true }
        }
        .task(id: query) {
            // A short pause while typing, then search (the library is searched on this Mac, so it's instant).
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            if let uri = SpotifyLink.uri(from: query) {
                results = []
                var s = Song(title: "Spotify song", artist: "Spotify", album: "", duration: 0, source: .spotify(uri))
                spotify = s
                if let t = await SpotifyLink.title(of: uri), !Task.isCancelled {
                    s.title = t
                    spotify = s
                }
            } else {
                spotify = nil
                results = library.search(query)
                // Then the whole Apple Music catalogue (online), minus songs already in your library.
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let found = await CatalogSong.search(query)
                guard !Task.isCancelled else { return }
                let mine = Set(results.map { MusicLibrary.fold($0.title + "|" + $0.artist) })
                catalog = found.filter { !mine.contains(MusicLibrary.fold($0.title + "|" + $0.artist)) }
            }
        }
        // New songs added in Music show up: read the library again every 20 s while this is open,
        // and swap the open playlist for its fresh copy.
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in library.refreshIfNeeded() }
        .onChange(of: library.playlists) { _, lists in
            if let open = openPlaylist { openPlaylist = lists.first { $0.id == open.id } ?? open }
        }
        .onChange(of: library.count) { _, _ in
            if spotify == nil { results = library.search(query) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundColor(faint)
            TextField("Search your songs and Apple Music, or paste a Spotify song link", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(ink)
                .focused($searchFocused)
                .onSubmit { if let first = spotify ?? results.first { engine.play(first) } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundColor(faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(searchFocused ? Brand.accent.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: 1))
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let s = spotify {
            VStack(alignment: .leading, spacing: 6) {
                SongRow(song: s, flash: flash == s.id, onPlay: { engine.play(s) },
                        onNext: { queued(s) { engine.playNext(s) } }, onQueue: { queued(s) { engine.addToQueue(s) } })
                note(NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
                     ? "Spotify isn't open: Play opens the song in Spotify." : "Plays in Spotify.")
            }
            Spacer(minLength: 0)
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty, !results.isEmpty || !catalog.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !results.isEmpty { section("YOUR LIBRARY") }
                    ForEach(results) { s in
                        SongRow(song: s, flash: flash == s.id, onPlay: { engine.play(s) },
                                onNext: { queued(s) { engine.playNext(s) } }, onQueue: { queued(s) { engine.addToQueue(s) } })
                    }
                    if !catalog.isEmpty {
                        section("APPLE MUSIC")
                        note("Opens in Music. To queue a song from here, add it to your library in Music first.")
                            .padding(.horizontal, 8).padding(.bottom, 4)
                        ForEach(catalog) { c in CatalogRow(song: c) }
                    }
                }
            }
            .scrollIndicators(.never)
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty, library.status == .ready, !library.playlists.isEmpty {
            if let pl = openPlaylist { playlistSongs(pl) } else { playlistList }
        } else {
            placeholder
        }
    }

    /// Your playlists (shown while the search box is empty).
    private var playlistList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                section("YOUR PLAYLISTS")
                ForEach(library.playlists) { pl in
                    Button { openPlaylist = pl } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "music.note.list").font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Brand.accent)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.accent.opacity(0.15)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pl.name).font(.system(size: 13, weight: .semibold)).foregroundColor(ink).lineLimit(1)
                                Text("\(pl.songs.count) song\(pl.songs.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundColor(faint)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(faint)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                }
                note("Type to search \(library.count.formatted()) songs from your library and playlists, and Apple Music.")
                    .padding(.horizontal, 8).padding(.top, 8)
            }
        }
        .scrollIndicators(.never)
    }

    /// One playlist's songs: Play plays it from the top; each song can be played, played next or queued.
    private func playlistSongs(_ pl: MusicLibrary.Playlist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { openPlaylist = nil } label: {
                    Label("Playlists", systemImage: "chevron.left").font(.system(size: 12, weight: .medium)).foregroundColor(faint)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { engine.playPlaylist(pl.id) } label: {
                    Label("Play", systemImage: "play.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(Brand.accent.opacity(0.8)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Play this playlist from the start")
            }
            Text(pl.name).font(.system(size: 18, weight: .bold)).foregroundColor(ink).lineLimit(1)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(pl.songs) { s in
                        SongRow(song: s, flash: flash == s.id, onPlay: { engine.play(s) },
                                onNext: { queued(s) { engine.playNext(s) } }, onQueue: { queued(s) { engine.addToQueue(s) } })
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            switch library.status {
            case .notRunning:
                message("music.note", "Open Music to search your library.")
                smallButton("Open Music") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicLibrary.musicID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MusicLibrary.shared.refreshIfNeeded(force: true) }
                        }
                    }
                }
            case .loading, .idle:
                ProgressView().controlSize(.small)
                message(nil, "Reading your Music library…")
            case .failed:
                message("exclamationmark.triangle", "Couldn't read your Music library.")
                smallButton("Try Again") { library.refreshIfNeeded(force: true) }
            case .ready:
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    message("magnifyingglass", "Search \(library.count.formatted()) songs in your library and playlists.")
                    note("Or paste a Spotify song link (Share > Copy Song Link).")
                } else {
                    message("questionmark", "No songs match “\(query)”.")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Runs the action and shows a tick on the row for a moment.
    private func queued(_ s: Song, _ action: () -> Void) {
        action()
        withAnimation(.easeOut(duration: 0.15)) { flash = s.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.3)) { if flash == s.id { flash = nil } }
        }
    }

    private func message(_ icon: String?, _ text: String) -> some View {
        VStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundColor(faint) }
            Text(text).font(.system(size: 13)).foregroundColor(faint).multilineTextAlignment(.center)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundColor(faint)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(faint.opacity(0.8))
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(ink)
                .padding(.horizontal, 12).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row that lights up under the mouse.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : (hover ? 0.06 : 0))))
                .onHover { hover = $0 }
        }
    }
}

/// One search result: title, artist · album, length. Play / Play Next / Add to Queue on the right.
struct SongRow: View {
    let song: Song
    let flash: Bool
    let onPlay: () -> Void
    let onNext: () -> Void
    let onQueue: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: song.isSpotify ? "link" : "music.note")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(faint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.system(size: 13, weight: .semibold)).foregroundColor(ink).lineLimit(1)
                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(faint).lineLimit(1)
            }
            Spacer(minLength: 8)
            if flash {
                Label("Queued", systemImage: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Brand.accent).transition(.opacity)
            } else if hover {
                icon("play.fill", "Play now", onPlay)
                icon("text.line.first.and.arrowtriangle.forward", "Play next", onNext)
                icon("text.badge.plus", "Add to queue", onQueue)
            } else if song.duration > 0 {
                Text(ProgressRow.clock(song.duration)).font(.system(size: 11).monospacedDigit()).foregroundColor(faint)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .help("Double-click to play")
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundColor(ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A song from the Apple Music catalogue: artwork, title, artist · album, and Open in Music.
struct CatalogRow: View {
    let song: CatalogSong
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: song.artwork) { img in img.resizable().scaledToFill() } placeholder: { Color.primary.opacity(0.06) }
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.system(size: 13, weight: .semibold)).foregroundColor(ink).lineLimit(1)
                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(faint).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hover {
                Button { NSWorkspace.shared.open(song.link) } label: {
                    Label("Open in Music", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(ink)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else if song.duration > 0 {
                Text(ProgressRow.clock(song.duration)).font(.system(size: 11).monospacedDigit()).foregroundColor(faint)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(song.link) }
        .help("Double-click to open in Music")
    }
}

/// Up Next: drag to reorder, × to remove.
struct QueueColumn: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var queue: PlayQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = engine.state.track {
                Text("NOW PLAYING").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundColor(faint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 13, weight: .semibold)).foregroundColor(ink).lineLimit(1)
                    Text(t.artist).font(.system(size: 11)).foregroundColor(faint).lineLimit(1)
                }
                .padding(.bottom, 6)
            }
            HStack {
                Text("UP NEXT").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundColor(faint)
                if !queue.isEmpty {
                    Text("\(queue.entries.count)").font(.system(size: 10, weight: .bold)).foregroundColor(Brand.accent)
                }
                Spacer()
                if !queue.isEmpty {
                    Button("Clear") { queue.clear() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(faint)
                }
            }
            if queue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing queued.").font(.system(size: 12)).foregroundColor(faint)
                    Text("Songs you add play after this one, then your player carries on as usual.")
                        .font(.system(size: 11)).foregroundColor(faint.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            } else {
                List {
                    ForEach(queue.entries) { e in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.song.title).font(.system(size: 12, weight: .medium)).foregroundColor(ink).lineLimit(1)
                                Text(e.song.artist).font(.system(size: 10.5)).foregroundColor(faint).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button { queue.remove(e.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(faint)
                                    .frame(width: 20, height: 20).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove from queue")
                        }
                        .padding(.vertical, 3)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .onMove { queue.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 38)
            }
        }
    }
}
