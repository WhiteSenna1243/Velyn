# Velyn: notes for Claude

macOS 14.2+ SwiftUI app (SwiftPM, no Xcode project), sold as a product (see SELLING.md).
Synced lyrics + music-reactive edge glow for Apple Music / Spotify.

## Build, test and look
- Build: `./build_app.sh` then `open Velyn.app`. First time only: `./tools/make_signing_cert.sh`.
- Tests: `./tools/test.sh`.
- Release: `tools/package.sh website|appstore`. Try it without Apple accounts: `LOCAL=1 tools/package.sh ...`.
- Name, bundle ID and version live in `config.sh`.
- You cannot see the app run. Debug builds render screens: `swift build && .build/debug/Velyn --snapshot /tmp/snap art.png`.
  - The off-screen capture draws switches as inactive.
  - Lyric shots use ImageRenderer.
- After changing visuals, say what to look for and ask the user to check.

## Two builds (`AppInfo.appStore`, compile flag `APPSTORE`)
- **Website** (Developer ID, hardened runtime, `Resources/Velyn.entitlements`): everything.
- **App Store** (`-DAPPSTORE`, sandbox, `Resources/Velyn-AppStore.entitlements`):
  - `LockScreen` is compiled out: private SkyLight calls, whose names mustn't appear in the binary.
  - Animated covers come from the Apple Music API (`MusicDataRequest`) instead of music.apple.com pages.
  - No update checks.
  - No Halo migration.
- Anything private or scraped goes inside `#if !APPSTORE`. Check with
  `strings .build/appstore-arm64/release/Velyn | grep SLS` (expect nothing).

## File map
Surfaces: the player window, edge-glow overlays, lyrics windows, ONE menu bar icon (panel + quick menu).
- `AppInfo.swift`       name, version, `appStore`, `updateURL`; `Migration` (settings and lyrics from Halo, the earlier build).
- `Brand.swift`         colours, the logo (`AuraMark`: ring of dotted rays), `AppIconView` (`--make-icon`), menu bar template image.
- `SettingsPanel.swift` `MenuBarPanel` (status item: click = panel, right-click = `QuickMenu`), `PanelRoot` (content
  only while open), `SettingsPanelView` (tabs Glow / Lyrics / General, `card` / `row` helpers; `engine` is NOT observed,
  `WatchEngine` wraps the bits that show playback), `ColorWheel`.
- `QuickMenu.swift`     right-click menu, also popped up from a lyrics window's settings button.
- `Updates.swift`       website-build update check (JSON at `VelynUpdateURL`).
- `PlayerWindow.swift`  `PlayerRoot` (modes player / expanded / lyrics), `ArtCard` (aura), `ProgressRow`, `TransportBar`,
  `LyricsCard`, `PlayerToolbar` (the dock) + `DockButton`.
- `MotionArt.swift`     animated covers: `MotionArtwork.find` (iTunes Search -> album -> square HLS stream), `MotionPlayer`
  (shared muted looping AVPlayer), `MotionArtView` (AVPlayerLayer; clip with its cornerRadius, not SwiftUI clipShape).
- `GlowOverlay.swift`   one click-through window per glow display, above everything; notch rect per screen.
  `chosenIDs` = Display setting, `targetIDs` = what glows now ("Only where Velyn is open" polls visible windows every 0.5 s).
- `Glow.swift`          `GlowLayer` picks Liquid or Soft (`GlowStyle.classic`), `GlowDriver` (intensity, rotation, energy, phase),
  `GlowMaskCache`, debug HUD.
- `LiquidGlow.swift`    Liquid glow: Metal shader compiled at runtime, `LiquidGlowView` (MTKView). Compile errors are
  logged and fall back to Soft.
- `LockScreen.swift`    lock-screen lyrics (website build): private SkyLight space at level 400, shown on
  `com.apple.screenIsLocked`. `LockStage` picks `prefs.lockLook`: `LockPlayer` (ArtCard + title + ProgressRow),
  `LockLyrics` (art column + `CardLyrics`), or the lyric style (`LyricsPane` + `LockNowPlaying`); `LockBackdrop` is opaque
  black + album-colour clouds (the user asked to hide the wallpaper). It hides the macOS clock, so `LockClock` draws date + time. Keep content between ~29% and ~75% height.
  Player pieces read `\.onLockScreen` so they keep drawing while locked.
  Per-display looks: `prefs.lockLook(for:)` / `lockDisplayLooks`; `lockBackground` black/white sets `\.ink`.
  `engine.idle` (5 min without music) hides everything, glow included.
- `Power.swift`         battery saver and Reduce Motion: `Power.shared` gives frame rates (`glowFPS`, `lyricsFPS`,
  `Power.schedule`). `tracksWindowVisibility()` / `\.windowVisible` pause covered windows; `\.onLockScreen`.
- `HotKeys.swift`       global ⌃⌥⌘ shortcuts (Carbon `RegisterEventHotKey`) and `LoginItem` (SMAppService).
- `AudioReactor.swift`  system audio -> `AudioSnapshot` (level, bands, beatPulse, beatCount). Core Audio tap + FFT.
- Lyric styles (`LyricStyle` in Prefs.swift, switch in `LyricsPane`, StageView.swift):
  - Stream = `StreamStage` (StreamLyrics.swift; `ArtVisual` = album art for "Album art behind lyrics").
  - Lens = `FisheyeStage` and Code = `CodeStage` (ListLyrics.swift).
  - Vine / Weave / Stars = `GraphStage` kinds branches / web / constellation (GraphLyrics.swift). Word labels are
    Canvas symbols (laid out once per line, scaled while they grow), not text resolved every frame.
  - Spotlight = `SpotlightStage` (SpotlightLyrics.swift: `SpotlightSim` per-line springs + dots, `SpotlightBackdrop`).
- `KineticLyrics.swift` shared `KPalette`, seeded random, word -> icon map.
- `LyricFonts.swift`    `LyricFont`, `LyricFonts` (one font factory for measuring AND drawing), `LyricTiming`, `LyricInput`.
- `StageView.swift`     lyrics window content and its hover chrome. `PlayerViews.swift` player bar used there.
- `NowPlaying.swift`    AppleScript polling of Spotify / Music, commands, `upNext()`. Every script runs on one background
  queue (`scripts`); results come back on the main thread; a poll older than the last command is dropped.
- `Lyrics.swift`        LRC parsing. `LyricsSource.swift`: `LyricsClient` (LRCLIB `/get`, then `/search` + `best`/`score`),
  `LyricsStore` (one JSON per song in Application Support/Velyn/Lyrics; hand picks win), `NetworkWatch`.
- `LyricChoicesMenu.swift` "Lyrics for This Song" (other LRCLIB versions).
- `Library.swift`       `Song` (Music persistent ID or Spotify URI), `SpotifyLink`, `PlayQueue` (Velyn's own up-next,
  saved in defaults), `MusicLibrary` (library + every user playlist, special kind kNon, read with Scripting Bridge on a
  background queue, one event per property per list, then searched locally; `Song.playlist` = where a
  playlist-only song lives, and `NowPlayingMonitor.play` plays it inside that playlist), `CatalogSong` (Apple Music catalogue via iTunes Search; opens in Music).
- `BrowseView.swift`    Search & Queue (`PlayerMode.browse`): `BrowseCard`, `SongRow`, `CatalogRow`, `QueueColumn`.
- `RemoteServer.swift`  tiny HTTP server (NWListener, one request per connection, 64 KB cap): `HTTPRequest`, `HTTPResponse`.
- `PhoneRemote.swift`   phone remote (pref `phoneRemote`, port 47820): secret key (`velyn.remote.token`), pairing link
  (`<LocalHostName>.local`, IP fallback), QR code, and the JSON API (`/api/state`, `art`, `search`, `playlists`,
  `playlist`, `play`, `queue`, `queue/remove`, `queue/clear`, `playlist/play`, `control` incl. seek/volume/macvolume (Mac output volume via `SystemVolume.swift`, CoreAudio; state `macVolume`), `look` GET/POST
  = glow + lyric settings shared with the Mac). `RemotePage.swift` = the page (tabs, Now Playing sheet, Glow tab),
  Home Screen icon (`AppIconView(fullBleed:)`), launch screens (`LaunchScreenView`, `launch.png?w=&h=`) and a manifest
  whose `start_url` carries the key (Home Screen apps get their own storage). Page colours = `engine.glowColors(prefs)`.
  `GlowPresets` (PlayerWindow.swift) is shared by the dock palette and the phone. Preview it with
  `--remote-check preview` (5 minutes on 127.0.0.1); in the browser pane use a 375x667 viewport, taller ones miss taps.
- `Prefs.swift`         all settings. Enums are `SettingChoice`: `rawValue` = stable id on disk, `title` = UI name,
  `legacy` = older saved names.
- `WindowManager.swift` lyrics windows per display; `Engine.swift` playback, lyrics, colours.
- `Snapshot.swift`      debug only. `--snapshot <dir> [art.png]` renders screens. Other checks:
  - `--find-motion "<artist>" "<title>" "<album>"` tests an animated-cover lookup and playback.
  - `--lock-check` tests the lock-screen calls.
  - `--hotkey-check` sends one shortcut to the app itself.
  - `--lyrics-check "<artist>" "<title>" <seconds>` runs a real LRCLIB lookup.
  - `--lyrics-bench [frames]` (LyricsBench.swift) times every lyric style per frame, plus a live-window old/new
    comparison for Vine / Weave / Stars. `BENCH_OUT=<dir>` saves one frame of each.
  - `--panel-check` (`MenuBarPanel.debugCheck`) prints the panel's open/closed sizes and what one playback update costs
    while it's open, now vs the old whole-panel redraw. Shows no window.
  - `--make-icon <png>` (main.swift) draws the app icon.
  - `--demo-video out.mp4 [phone1.png phone2.png] [--review dir]` (DemoVideo.swift) renders a ~55 s 1080p demo from the real
    views with made-up lyrics and original cover art (`DemoVideo.cover()`). Phone shots come from `--remote-check preview`.
    It also writes `out-silent.mp4` (picture only), then adds the soundtrack from DemoSound.swift: an original 112 BPM
    synth track made in code. The glow pulse, the kick and the lyric words share one beat grid (`DemoVideo.gridOrigin`,
    `specs()` nudges each lyric scene's song start onto it), and the lead plays one note per word (`DemoVideo.cues`).
    - `--demo-sound out.m4a` renders the audio only; `--demo-sound out.mp4 out-silent.mp4` redoes the music on a
      rendered picture (seconds, not minutes). It prints each stem's level, so the mix can be balanced without ears.
    - `--demo-check out.mp4` reads a finished video back: track lengths, loudness per second, kick vs beat timing.
  - `--library-check <out.txt>` (main.swift) reads the real Music library. Run it inside a copy of the app with
    `open -n -W Copy.app --args --library-check /tmp/x.txt`, so it uses the app's Automation permission
    (a bare binary would trigger a new prompt). Never test play or queue on the user's Mac without asking.

## Hard rules
1. Never use ScreenCaptureKit or `CGRequestScreenCaptureAccess` (it causes the "record your screen" prompt).
   Audio comes only from the Core Audio tap.
2. No live `.blur()` on full-screen layers in the glow. Soft = cached bitmap mask + rotating gradient; Liquid = one shader pass.
   Check shader changes with `--snapshot` (liquid_N.png); if the PNGs don't update, the shader failed to compile.
3. With more than one lyrics window open, hover is ignored: controls appear on click and fade after ~4 s (`StageView.reveal`).
4. Keep per-frame work small: the lyric/glow `TimelineView`s run at 45-60 fps.
5. Glow overlay windows stay click-through (`ignoresMouseEvents`) at `.screenSaver` level. Lock-screen windows stay
   click-through, and are only ordered in while the screen is locked.
6. Snapshot mode must not configure `GlowOverlays` or `LockScreen` (they would put real windows on the user's screen).
7. Anything that animates takes its frame rate from `Power` (TimelineView: `Power.schedule(fps)`; MTKView:
   `preferredFramesPerSecond` / `isPaused`). No fixed 60 fps loops. Motion honours `Power.reduceMotion`.
   The animated cover only plays while music plays and a cover view is seen. Leave
   `automaticallyWaitsToMinimizeStalling` at its default (turning it off stopped the HLS covers at 0 s).
8. Scripts that run repeatedly go through `NowPlayingMonitor.run(_:keep: true)` (compiled once). Compiling an
   AppleScript triggers an XProtect scan; doing it every second was ~10% CPU at idle.
9. Lyric timing is per song (`engine.lyricOffset(p)` / `setLyricOffset` / `nudgeLyrics`, keyed by `Track.key`).
   Don't change `Track.key` or `MotionArtwork.norm`: saved offsets and saved lyrics are keyed by them.
10. Lyrics go through `Engine.apply(LyricsResult)`. `.offline` is never saved and retries; `.missing` is saved for 3 days.
    New statuses need a `LyricsStatus.message`.
11. Never change a `SettingChoice` rawValue (it's what's saved). To rename something, change `title`; to replace
    a case, add the old value to `legacy`.
12. It's a product: no references to the apps that inspired it (in UI, code, comments or docs that ship). UI text
    comes from `AppInfo.name`, not a literal "Velyn".
13. Run `./tools/test.sh` after touching lyrics parsing/matching, `LyricsStore`, `Prefs`, `Updates`, search or the queue.
    The Prefs test fails until a new field is added to it.
14. Queue: Music and Spotify have no "add to up next" for other apps, so `Engine` plays the next queued song itself
    (`scheduleQueueAdvance` ~0.3 s before the end; `handle` catches a song that ended on its own; `next()` takes the queue
    first). Anything put into a script (`NowPlayingMonitor.play`) must be validated first: hex IDs, `SpotifyLink.uri`.
15. Phone remote: off by default; every `/api/` call checks the key (`sameKey`); songs from the page go through
    `PhoneRemote.song` and are validated again in `NowPlayingMonitor.play`. Test with `--remote-check` (127.0.0.1 only);
    it skips play/control because those would start music for real.
16. Keep the main thread free: the lyrics, the glow and the windows all draw there. Never run AppleScript on it
    (`NowPlayingMonitor.scripts`), keep views that redraw often small, and don't let big views (the settings panel)
    observe `Engine`: it publishes on every poll. Check a running Velyn with `sample <pid> 5` if something stutters.

## Music sync. How it should feel
Beat Sync is not "brightness = volume". It combines:
1. **Auto-gain**: levels are relative to the song's own recent peak (3 s half-life), so it works at any system volume.
2. **Bands, not one number**: bass drives brightness/punch, treble adds sparkle. See `AudioSnapshot`.
3. **Beat events**: spectral flux on 40-250 Hz vs a rolling mean + 1.3 sd, min 200 ms apart. On each beat the colours
   step around the edge (`GlowDriver.rotationTarget += ...`).
4. **Fast attack, slow release**: lights snap on, ease off (~100-160 ms half-life).
5. **Styles**: Energy (loudness + bass + beat) and Pulse (dark between beats, flash on beats).

Tuning: `defaults write com.velyn.app velyn.debug.audio -bool true` shows live meters. Typical fixes:
- Beats missed: lower the `max(0.30, mean + 1.3*sd)` threshold in `analyze()`.
- Too twitchy: raise that threshold, or raise the min gap (0.20 s).
- Glow too flat: raise the `powf(x, 1.4)` contrast.
- Too dark in quiet parts: raise the base in `GlowDriver.step`.

## Adding a lyric style
1. Add a case to `LyricStyle` (Prefs.swift) with a stable rawValue, a `title`, and a `symbol` (SettingsPanel.swift).
2. Build a view that takes `LyricInput` (see `FisheyeStage` for a list style, `GraphStage` for Canvas drawing).
3. Add it to the `switch p.lyricStyle` in `LyricsPane` (StageView.swift); the panel and quick menu list it automatically.
4. Always get fonts from `LyricFonts`. Colours come from `input.palette` / `input.colors`.
5. Design it fresh: don't copy another app's look (rule 12).

## Style
Short, direct code comments. No new dependencies. Keep README and SELLING.md in sync with user-visible changes.
