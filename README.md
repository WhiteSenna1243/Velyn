# Velyn

Synced lyrics and a music-reactive glow around the edges of your screen, for Apple Music and
Spotify on the Mac. A player window, lyrics windows in seven styles (on one or more displays, and on
the lock screen), and a menu bar panel for everything else.

Velyn is not affiliated with Apple or Spotify. To sell it, see **[SELLING.md](SELLING.md)**.

## Install (invited people)

1. Download **Velyn-1.0.dmg** from this repo's **Releases** page, open it, and drag Velyn to Applications.
2. The first time, macOS blocks it because it isn't notarised yet. Open **System Settings → Privacy & Security**,
   scroll down, and click **Open Anyway** next to Velyn.

Everything Velyn saves (settings, playlists, lyrics cache, the phone remote's key) stays in your own Mac
user account, so each person on a shared Mac has their own, and nothing is sent to anyone else.

## Build and run

You need macOS 14.2 or later and the Xcode command line tools (`xcode-select --install`).

```bash
./tools/make_signing_cert.sh     # once: a local certificate, so macOS remembers Velyn's permissions
./build_app.sh
open Velyn.app
```

- Release builds: `tools/package.sh website` or `tools/package.sh appstore` (see SELLING.md).
- Name, bundle ID and version: `config.sh`.
- App icon: `Resources/AppIcon.png`, drawn by `swift build && .build/debug/Velyn --make-icon Resources/AppIcon.png`.

## What you get

**Menu bar icon** (a ring of rays). Click it for the settings panel, which has three tabs:
- **Glow:**
  - Style (Liquid, Soft) and Colors (one or two).
  - Motion: Flow, Beat Sync, Breathe or Still. With Beat Sync you also get a beat style (Energy,
    Pulse) and Sensitivity.
  - Thickness, Softness, Brightness, and Follow the notch.
  - Custom colors, using two colour wheels.
  - Displays, and "Only where Velyn is open".
- **Lyrics:**
  - The style picker.
  - Album art behind lyrics (for Stream, Lens and Code), Font, Text size and Drift.
  - Colors: match the album, or pick your own.
  - Which displays show lyrics, and Keep screen awake.
  - This song: timing −/+ (remembered per song) and "Wrong lyrics? Pick another version…".
- **General:**
  - Lyrics on the lock screen (website build), Show in Dock, Launch at login.
  - Animated album covers, and Keyboard shortcuts.
  - Version and updates, About, Quit.

Right-click the icon for a quick menu: what's playing, Show Lyrics Window, Lyrics Style, Album Art
Behind Lyrics, Lyrics for This Song, Glow on/off, Glow Motion, Show Player, Settings, Quit.

**Player window:**
- Album art with a soft glow in the album's colours, title and artist.
- A progress bar you can drag to seek.
- −15 s / previous / a big play button / next / +15 s.
- Click the art to make it big.

The dock at the bottom has these buttons:
- Lyrics: the player becomes a card with a scrolling lyric list, Sync −/+, and "wrong lyrics".
- Search & Queue (⌘F): see below.
- Glow colour presets, beat sensitivity and glow brightness.
- Glow display.
- Lock screen lyrics, and the lyrics window.
- Settings.

**Search & Queue** (⌘F, the list button in the dock, or "Search & Queue…" in the quick menu):
- **Your playlists:** with the search box empty, your Music playlists are listed. Click one to see
  its songs, or **Play** to play it from the top.
- **Your songs:** type to search every song in your library *and* your playlists (title, artist or
  album, accents ignored). Hover a song for **Play**, **Play Next** and **Add to Queue**, or
  double-click to play. A song from a playlist plays inside that playlist, so the playlist carries on
  after it.
- **Apple Music:** under that, matching songs from the whole Apple Music catalogue. **Open in Music**
  takes you to the song in Music, where you press play. Music only lets other apps play songs that
  are in your library, so to queue one of these, add it to your library in Music first.
- **Spotify:** paste a song link (Share > Copy Song Link) to play or queue it. Spotify can't be
  searched without a Spotify developer login.
- **Up Next** (right): Velyn's own queue. Drag to reorder, × to remove. Velyn plays the next queued
  song when the current one ends, or when you press Next in Velyn. When the queue runs out, your
  player carries on as usual. The queue is kept when you quit.
- Your library and playlists are read when you open Search & Queue, and every 20 seconds while it (or the phone's Playlists tab) is open, so songs you add in Music show up.

**Phone remote** (Settings > General > Phone remote): control Velyn from your phone's browser,
with nothing to install. The music plays on the Mac; your phone only sends the commands.
- Turn it on, then scan the QR code with your phone's camera. Your phone must be on the same Wi-Fi.
- In Safari, choose Share > Add to Home Screen. It then opens like an app: Velyn's icon, full
  screen with no Safari bars, a dark launch screen, and it stays paired.
- It looks like the Mac app and follows it: the page takes the same colours as the glow (your custom
  colours, or the album's), with the same cards, labels, logo and dock-style tab bar.
- At the top: the song playing. Tap it for the full **Now Playing** screen (big artwork, drag to
  seek, play/pause, previous, next, volume); swipe down to close.
- Under the song, on every tab: a **volume** bar, with − / + buttons for 10% steps. It sets your **Mac's
  volume** (the same as the volume keys), and so does the slider in Now Playing. If your speakers have no
  volume control (some HDMI or USB outputs), it sets Music or Spotify's volume instead.
- Tabs: **Search** your songs and playlists (or paste a Spotify link); **Playlists** to browse and play
  them; **Up Next** to see and edit the queue; **Glow** to change the glow (on/off, colours, motion,
  brightness) and lyrics (window on/off, style, album art). Changes on the phone show on the Mac, and
  changes on the Mac show on the phone.
- The link has a secret key, so other people on your Wi-Fi can't use it. **New Link** makes a new
  key (old links and Home Screen icons stop working).
- It works only while the Mac is awake, and only on your local network.

**Animated covers**: when an album has an animated cover on Apple Music, Velyn plays it wherever
the art shows, for songs in Apple Music *or* Spotify. It only plays while music is playing and a
cover is on screen.

**Edge glow**: a band of light around the screen, above every window and in full screen. With
Beat Sync it surges with the bass and steps around the edge on every beat. It listens to your
Mac's sound through a system-audio tap, so it works at any volume. Nothing is recorded.

**Lyrics window** styles:
- **Stream**: each new word lands boxed at the bottom and moves up.
- **Lens**: lines wrap around a lens.
- **Code**: lyrics as source code.
- **Vine**: words grow along a branch.
- **Weave**: words on a web of threads.
- **Stars**: words become stars joined by lines.
- **Spotlight**: big bold lines that fill in as they're sung, other lines blurred, blurred album
  art turning behind. On the lock screen it's centred under the clock.

Hover a lyrics window for its controls (full screen, display, volume, player bar). With several
lyrics windows open, click a screen to show its controls.

**Lock screen** (website build): with Settings > General > "Show on the lock screen" on, locking
your Mac shows the song under the macOS clock, plus the glow. Pick the **Look** there:
- **Player**: the player's big album art with its glow, the song, and how much has played.
- **Lyrics**: album art, the song and progress on the left, the synced lyrics on the right (the
  player's lyrics page without its buttons).
- **Lyric style**: your lyrics style under the clock, with a small now-playing line.

Player and Lyrics hide your wallpaper: they sit on black with soft clouds of the album's colours,
with Velyn's own date and time at the top (the black covers the macOS clock).
Each display has its own Look, and Player and Lyrics can use a Black or White **Background**
(Lyric style always uses black). After 5 minutes without music, Velyn draws nothing on the lock
screen, so your own wallpaper shows until a song plays again.
It's all click-through, so Touch ID and the password field work as normal. It uses private macOS calls, so a future macOS update could stop it. Velyn then just
skips it.

**Lyrics** come from LRCLIB:
- Velyn picks the version closest in length to your song (within 8 s), ignoring accents and
  "Remastered" / "feat." in titles.
- Instrumentals say "Instrumental".
- Lyrics are saved on your Mac (`~/Library/Application Support/Velyn/Lyrics`, about 3 KB a song,
  the 3000 most recent kept), so songs you've played show at once, even offline.
- If the internet is down, the window says "Waiting for internet…" and loads the lyrics when you're
  back online.
- In Apple Music with shuffle off, the next song's lyrics and cover load early.

**Keys** (while Velyn is in front):

| Key | Does |
|---|---|
| Space or ⌘P | Play / pause |
| ⌘→ / ⌘← | Next / previous |
| ⌘S | Shuffle |
| ⌘R | Repeat |
| ⌘↑ / ⌘↓ | Volume |
| ⌃⌘F | Full screen |
| ⌘1 | Player |
| ⌘2 | Lyrics |
| ⌘F | Search & Queue |
| ⌘, | Settings |

**Global shortcuts** (from any app; turn them off in General):

| Key | Does |
|---|---|
| ⌃⌥⌘G | Glow on / off |
| ⌃⌥⌘L | Show / hide lyrics |
| ⌃⌥⌘P | Show / hide player |
| ⌃⌥⌘[ / ⌃⌥⌘] | Lyric timing −/+ 0.25 s |

**Battery:**
- Full speed only while music plays; slower when paused.
- Everything stops while the screens sleep. Covered or minimised windows stop drawing.
- Low Power Mode halves the frame rate.
- The audio listener switches off after 30 s of silence.

**Reduce Motion** (System Settings > Accessibility > Display): the glow drifts slowly and doesn't
jump on beats, and the lyrics stop drifting and pulsing.

**Coming from Halo** (the earlier personal build): the website build brings over your settings,
your open lyrics windows and your saved lyrics the first time it runs.

**Also:**
- **Smooth song changes**: the cover, colours and lyrics fade into the next song (on the Mac and the phone).
- **Sleep timer**: right-click the menu bar icon > Sleep Timer (15 / 30 / 45 / 60 minutes or end of this
  song), or on the phone's Now Playing screen.
- **Song banners** (General): a notification with the cover when a new song starts, while Velyn isn't in front.
- **Phone lyrics**: a Lyrics tab on the phone remote that follows the song.
- **Welcome screen** on first launch (and in the app menu: Welcome to Velyn…).
- **Light mode**: the player, settings panel and welcome screen follow your Mac's light/dark setting.
  The lyrics windows stay dark.

## Permissions (first launch)

- **Automation**: lets Velyn read and control Music / Spotify.
- **System Audio Recording**: lets Velyn hear loudness, bass and beats for the glow.

## Known limits

- Lock screen lyrics rely on private macOS calls (website build only).
- Word timing is estimated: LRCLIB only times whole lines.
- Songs from the Apple Music catalogue that aren't in your library open in Music rather than
  playing from Velyn. Pressing Next in Music itself (not Velyn) skips the queue.
- Launch at login opens Velyn.app from where it is now. If you move the app, turn it off and on again.
- The App Store build hasn't been run yet (see SELLING.md).

## Working on it with Claude Code

See `CLAUDE.md`.
- Tests: `./tools/test.sh`.
- Debug builds can render the main screens: `.build/debug/Velyn --snapshot out/ [art.png]`.
- Other checks: `--find-motion "<artist>" "<title>" "<album>"`, `--lyrics-check "<artist>" "<title>" <seconds>`,
  `--lock-check`, `--hotkey-check`, `--library-check <out.txt>` (run it as the app with `open -n -W`), and
  `--remote-check [preview]` (the phone remote on this Mac only, with made-up songs).
