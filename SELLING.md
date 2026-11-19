# Selling Velyn

Velyn ships in two builds from the same code:

| | Website build | Mac App Store build |
|---|---|---|
| How people get it | A `.dmg` download from your site | The Mac App Store |
| Lyrics on the lock screen | Yes | No (uses private macOS calls, which Apple doesn't allow there) |
| Animated covers | Read from Apple Music's web pages | Official Apple Music API |
| Updates | Your update file (`UPDATE_URL` in `config.sh`) | The App Store |
| Payments | A store you choose (see step 3) | Apple |
| Make it | `tools/package.sh website` | `tools/package.sh appstore` |

Everything else (player, glow, lyric styles, shortcuts) is the same in both.

The steps below need your accounts, money or signature, so only you can do them. I'm not a
lawyer: for anything in "Before you sell", ask one.

## 1. Before you sell

- **Name.** Search "Velyn" in the US trademark database (tmsearch.uspto.gov) and your country's,
  for software and music. Register a domain if you want a website.
- **Lyrics licence.** Lyrics come from LRCLIB, a free community site. Publishers own song lyrics,
  and paid apps usually license them (for example from LyricFind or Musixmatch). Selling an app
  that shows unlicensed lyrics is a legal risk. Options: license a provider, or sell Velyn for its
  glow and player and present lyrics as a free community feature. Ask a lawyer which fits.
- **Animated covers, website build.** That build reads the covers from Apple Music's public web
  pages, which Apple's terms may not allow for a paid product. The safer route is the official
  Apple Music API (what the App Store build uses), which needs a developer token from your
  account. You can also turn the feature off for the website build.
- **Design.** Velyn has its own name, icon, menu bar panel, player look and style names. The
  **Stream** lyric style still closely follows the word-stream style it was modelled on. Rework it
  (or drop it) before selling.
- **Privacy policy.** Both stores and many payment providers want one. What Velyn sends off the Mac:
  - the song title, artist and album, to LRCLIB (lyrics) and Apple (album and animated-cover lookups);
  - what you type in Search & Queue, to Apple's public search (Apple Music results);
  - pasted Spotify links, to Spotify's public link preview (for the song title).

  Your Music library is read on the Mac and never sent anywhere. The phone remote (off by default) is a
  web page served on your own Wi-Fi; it only talks to the Mac, behind a secret key in its link. Sound from the system audio tap is analysed on the Mac and never recorded or sent.
  There are no accounts, analytics or ads.
- **Brand names.** Saying "works with Apple Music and Spotify" is fine. Don't use their logos, or
  make Velyn look like an official Apple or Spotify product.

## 2. Join the Apple Developer Program

$99 a year at developer.apple.com/programs, as yourself or as a company (a company needs a D-U-N-S
number). You need it for both builds: without it, Macs warn that Velyn "can't be checked for
malicious software" and won't open it normally.

Then set your details in `config.sh`: `BUNDLE_ID` (for example `com.yourname.velyn`), `COPYRIGHT`
and `VERSION`.

## 3. Website build

1. **Certificate.** On developer.apple.com, go to Certificates and add a "Developer ID Application"
   certificate. To make the request file it asks for, open Keychain Access, then choose Certificate
   Assistant, then "Request a Certificate From a Certificate Authority". Download the certificate
   and double-click it.
2. **Notary password.** At account.apple.com, make an app-specific password. Then run this once:
   ```bash
   xcrun notarytool store-credentials velyn --apple-id you@example.com --team-id YOURTEAMID
   ```
3. **Build.** This makes a universal, signed, notarised `dist/Velyn-<version>.dmg`:
   ```bash
   DEVELOPER_ID="Developer ID Application: Your Name (YOURTEAMID)" tools/package.sh website
   ```
4. **Updates (optional).** Host a small file like
   `{"version": "1.1", "url": "https://yoursite/Velyn-1.1.dmg", "notes": "What's new"}`, and put its
   address in `UPDATE_URL` in `config.sh`. "Check for Updates" then appears in Settings, and Velyn
   checks once a day.
5. **Payments.** Use a store that handles payments, tax and refunds for you, such as Paddle,
   Gumroad or Lemon Squeezy. Velyn doesn't check licence keys yet. Once you pick a store, I can add
   that (a trial plus "Enter licence key").

You can try the whole flow without an account (signed with your local certificate, not notarised):
`LOCAL=1 tools/package.sh website`.

## 4. Mac App Store build

1. **App ID.** On developer.apple.com, go to Identifiers and add an App ID with your `BUNDLE_ID`.
   Under App Services, turn on **MusicKit** (for animated covers).
2. **Certificates.** Add an "Apple Distribution" certificate and a "Mac Installer Distribution"
   certificate.
3. **Profile.** Under Profiles, make a "Mac App Store" provisioning profile for the App ID, and
   download it.
4. **App Store Connect.** At appstoreconnect.apple.com, add a new macOS app with the same bundle ID.
   Fill in the description, screenshots, price, privacy policy link and privacy answers.
5. **Build and upload.**
   ```bash
   APPSTORE_ID="Apple Distribution: Your Name (YOURTEAMID)" \
   INSTALLER_ID="3rd Party Mac Developer Installer: Your Name (YOURTEAMID)" \
   PROFILE=~/Downloads/Velyn_Mac_App_Store.provisionprofile \
   tools/package.sh appstore
   ```
   Then upload `dist/appstore/Velyn.pkg` with Apple's free **Transporter** app.
6. **Review notes.** Apple will ask about these, so explain them up front:
   - *Controlling Spotify:* "Velyn reads the song playing and sends play, pause and skip commands,
     to show that song's synced lyrics. Spotify offers no scripting access groups, so we use the
     temporary Apple Events exception for com.spotify.client." (Music needs no exception: Velyn
     uses Music's own access groups for playback and reading the library.)
   - *System audio:* "Velyn analyses loudness and beats on the device to animate a glow around the
     screen. Nothing is recorded or sent."
   - *Glow window:* "A transparent, click-through window draws the glow. It never blocks input."

**Not tested yet:** the App Store build compiles, and it's sandboxed and signed locally, but I
haven't run it. In particular, check that the system-audio glow and Spotify control work inside
the sandbox. Try it with `FLAVOR=appstore ./build_app.sh && open Velyn.app` before you upload.

## 5. Every release

- Raise `VERSION` (and always `BUILD`) in `config.sh`.
- Run `./tools/test.sh`.
- Run `tools/package.sh website` and/or `tools/package.sh appstore`.
- Website: upload the DMG and update the update file. App Store: upload with Transporter, then
  submit for review.
