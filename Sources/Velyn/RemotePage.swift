import SwiftUI
import AppKit

/// The phone remote's page: one self-contained file (no outside scripts or fonts).
enum RemotePage {
    private static var cache: [String: Data] = [:]

    private static func png<V: View>(_ key: String, _ view: V, scale: CGFloat) -> Data? {
        if let d = cache[key] { return d }
        let data: Data? = MainActor.assumeIsolated {
            let r = ImageRenderer(content: view)
            r.scale = scale
            return r.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        if cache.count > 40 { cache.removeAll() }
        if let data { cache[key] = data }
        return data
    }

    /// Home Screen icon: the app icon, full square (the phone rounds the corners).
    static func icon(_ px: Int) -> Data {
        png("icon\(px)", AppIconView(fullBleed: true), scale: CGFloat(px) / 1024) ?? Data()
    }

    /// The logo for the page's header (transparent).
    static var mark: Data {
        png("mark", AuraMark(rays: 72, bloom: true).frame(width: 96, height: 96), scale: 1) ?? Data()
    }

    /// Launch screen for one phone size (in pixels).
    static func launchImage(width: Int, height: Int) -> Data? {
        png("launch\(width)x\(height)", LaunchScreenView(width: CGFloat(width), height: CGFloat(height)), scale: 1)
    }

    /// Lets the phone install the page as an app. `key` keeps it paired when opened from the Home Screen.
    static func manifest(key: String?) -> Data {
        let start = key.map { "/?k=\($0)" } ?? "/"
        let m: [String: Any] = [
            "name": "Velyn", "short_name": "Velyn", "start_url": start, "scope": "/", "id": "/",
            "display": "standalone", "orientation": "portrait",
            "background_color": "#0b0716", "theme_color": "#0b0716",
            "icons": [["src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"],
                      ["src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"]]
        ]
        return (try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// iPhone screen sizes (points, pixel ratio) that get a matching launch screen.
    static let phones: [(w: Int, h: Int, r: Int)] = [
        (440, 956, 3), (402, 874, 3), (430, 932, 3), (420, 912, 3), (393, 852, 3), (390, 844, 3),
        (428, 926, 3), (375, 812, 3), (414, 896, 3), (414, 896, 2), (375, 667, 2)
    ]

    static var launchLinks: String {
        phones.map { p in
            "<link rel=\"apple-touch-startup-image\" media=\"(device-width: \(p.w)px) and (device-height: \(p.h)px) and " +
            "(-webkit-device-pixel-ratio: \(p.r)) and (orientation: portrait)\" href=\"/launch.png?w=\(p.w * p.r)&h=\(p.h * p.r)\">"
        }.joined(separator: "\n")
    }

    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Velyn">
<meta name="theme-color" content="#0b0716">
<meta name="format-detection" content="telephone=no">
<link rel="manifest" href="{{MANIFEST}}">
<link rel="apple-touch-icon" href="/icon.png">
{{LAUNCH}}
<title>Velyn</title>
<style>
@property --c1 { syntax:'<color>'; inherits:true; initial-value:#9e61ff; }
@property --c2 { syntax:'<color>'; inherits:true; initial-value:#e52ec7; }
:root { transition:--c1 .8s, --c2 .8s; }
.art img { transition:opacity .5s; }
:root { --bg:#0b0716; --card:rgba(255,255,255,.07); --line:rgba(255,255,255,.08); --ink:rgba(255,255,255,.94);
        --dim:rgba(255,255,255,.52); --c1:#9e61ff; --c2:#e52ec7; --accent:#9e61ff; --tab:64px; }
* { box-sizing:border-box; -webkit-tap-highlight-color:transparent; -webkit-touch-callout:none; }
html, body { margin:0; height:100%; background:var(--bg); color:var(--ink); overflow:hidden;
             font:16px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,sans-serif;
             -webkit-font-smoothing:antialiased; overscroll-behavior:none; }
button, input { font:inherit; color:inherit; }
button { background:none; border:0; padding:0; cursor:pointer; touch-action:manipulation; -webkit-user-select:none; user-select:none; }
#glow { position:fixed; inset:0; z-index:0; pointer-events:none; transition:background 1s;
        background:radial-gradient(110% 55% at 15% 0%, color-mix(in srgb, var(--c1) 30%, transparent), transparent 65%),
                   radial-gradient(90% 50% at 100% 35%, color-mix(in srgb, var(--c2) 16%, transparent), transparent 65%); }
#app { position:relative; z-index:1; height:100%; display:flex; flex-direction:column; }

/* Header, like the Mac panel's: logo, name */
.brand { display:flex; align-items:center; gap:8px; margin:calc(env(safe-area-inset-top) + 4px) 16px 0; height:34px; }
.brand img { width:28px; height:28px; border-radius:7px; box-shadow:0 0 0 1px rgba(255,255,255,.08); }
.brand b { font:700 19px ui-rounded,"SF Pro Rounded",-apple-system,sans-serif; letter-spacing:.2px; }

/* Mini player */
#mini { margin:8px 12px 0; display:flex; align-items:center; gap:12px; padding:10px;
        border-radius:18px; background:var(--card); border:1px solid var(--line); -webkit-backdrop-filter:blur(20px); backdrop-filter:blur(20px); }
#mini .meta { flex:1; min-width:0; }
.art { border-radius:12px; overflow:hidden; display:grid; place-items:center; flex:none; color:rgba(255,255,255,.6);
       background:linear-gradient(135deg, color-mix(in srgb, var(--c1) 45%, transparent), color-mix(in srgb, var(--c2) 25%, transparent)); }
.art img { width:100%; height:100%; object-fit:cover; grid-area:1/1; }
.art span { grid-area:1/1; }
#mini .art { width:52px; height:52px; font-size:22px; }
.t1 { font-weight:650; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.t2 { color:var(--dim); font-size:14px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
#mini .bar { height:3px; border-radius:2px; background:rgba(255,255,255,.12); margin-top:7px; overflow:hidden; }
.fill { height:100%; width:0; background:linear-gradient(90deg,var(--c1),var(--c2)); }
.round { width:44px; height:44px; border-radius:50%; display:grid; place-items:center; flex:none; transition:transform .12s; }
.round:active, .ic:active, .tabbar button:active, .pill:active { transform:scale(.9); }
.round svg { width:22px; height:22px; fill:var(--ink); }
#mini .pp { background:linear-gradient(135deg,var(--c1),var(--c2)); }
#mini .pp svg { fill:#fff; }
/* Volume, always under the mini player */
#mvol { margin:6px 12px 0; display:flex; align-items:center; gap:6px; padding:2px 12px 2px 4px; height:44px;
        border-radius:16px; background:var(--card); border:1px solid var(--line); }
#mvol .step { width:40px; height:40px; display:grid; place-items:center; flex:none; border-radius:12px; transition:transform .12s; }
#mvol .step:active { transform:scale(.88); background:rgba(255,255,255,.08); }
#mvol .step svg { width:20px; height:20px; fill:var(--dim); }
#mvol input { flex:1; }
#volPct { width:40px; text-align:right; font-size:13px; color:var(--dim); font-variant-numeric:tabular-nums; flex:none; }
#status { margin:6px 16px 0; font-size:13px; color:#ff8a8a; display:none; }
#status.show { display:block; }

/* Content */
#content { position:relative; flex:1; overflow-y:auto; -webkit-overflow-scrolling:touch; padding:8px 12px calc(var(--tab) + env(safe-area-inset-bottom) + 24px); }
.view[hidden] { display:none; }
h1 { font-size:30px; margin:6px 4px 10px; letter-spacing:.2px; }
/* Sections like the Mac settings panel: small capital label, then a card */
.sec { font-size:11px; font-weight:600; letter-spacing:.7px; text-transform:uppercase; color:var(--dim); margin:16px 8px 7px; }
.card { background:rgba(255,255,255,.05); border:1px solid rgba(255,255,255,.06); border-radius:14px; padding:2px 12px; }
.card .row:last-child { border-bottom:0; }
.line { display:flex; align-items:center; justify-content:space-between; gap:12px; min-height:52px; border-bottom:1px solid var(--line); }
.line:last-child { border-bottom:0; }
.line.col { flex-direction:column; align-items:stretch; justify-content:center; gap:10px; padding:12px 0; }
.switch { -webkit-appearance:none; appearance:none; width:51px; height:31px; border-radius:16px; background:rgba(255,255,255,.18);
          position:relative; transition:background .2s; flex:none; margin:0; }
.switch::after { content:""; position:absolute; top:2px; left:2px; width:27px; height:27px; border-radius:50%; background:#fff;
                 box-shadow:0 2px 4px rgba(0,0,0,.3); transition:transform .2s; }
.switch:checked { background:var(--accent); }
.switch:checked::after { transform:translateX(20px); }
.switch:disabled { opacity:.4; }
.swatches { display:flex; gap:12px; }
.sw { width:36px; height:36px; border-radius:50%; border:2px solid rgba(255,255,255,.15); display:grid; place-items:center;
      font-size:12px; font-weight:700; color:rgba(0,0,0,.7); }
.sw.on { border-color:#fff; box-shadow:0 0 0 2px rgba(255,255,255,.25); }
.chips { display:grid; grid-template-columns:repeat(4,1fr); gap:7px; }
.chips.two { grid-template-columns:repeat(2,1fr); }
.chip { height:40px; border-radius:10px; background:rgba(255,255,255,.06); color:rgba(255,255,255,.8); font-size:13px; font-weight:500;
        border:1px solid transparent; transition:transform .12s; }
.chip.on { background:color-mix(in srgb, var(--accent) 30%, transparent); border-color:var(--accent); color:#fff; font-weight:650; }
.chip:active, .sw:active { transform:scale(.94); }
.search { position:sticky; top:-8px; z-index:2; margin:-4px -12px 0; padding:8px 12px; }
.search.stuck { background:rgba(11,7,22,.6); -webkit-backdrop-filter:blur(16px); backdrop-filter:blur(16px); }
input[type=search] { width:100%; height:44px; border-radius:12px; border:1px solid var(--line); background:rgba(255,255,255,.09);
       color:var(--ink); padding:0 14px; outline:none; -webkit-appearance:none; font-size:17px; }
input[type=search]::placeholder { color:var(--dim); }
input[type=search]:focus { border-color:color-mix(in srgb, var(--c1) 80%, white 0%); }
.row { width:100%; display:flex; align-items:center; gap:10px; min-height:60px; padding:6px 4px; border-bottom:1px solid var(--line); text-align:left; }
.row .info { flex:1; min-width:0; }
.ic { width:38px; height:38px; border-radius:50%; display:grid; place-items:center; background:rgba(255,255,255,.08); flex:none; transition:transform .12s; }
.ic svg { width:17px; height:17px; fill:var(--ink); }
.ic.go { background:color-mix(in srgb, var(--c1) 40%, transparent); }
.chev { color:var(--dim); font-size:24px; padding:0 4px; }
.plicon { width:44px; height:44px; border-radius:10px; display:grid; place-items:center; flex:none;
          background:color-mix(in srgb, var(--c1) 22%, transparent); }
.plicon svg { width:20px; height:20px; fill:var(--c1); }
.msg { color:var(--dim); text-align:center; padding:36px 16px; }
.head { display:flex; align-items:center; justify-content:space-between; gap:10px; margin:2px 4px 8px; }
.back { color:var(--c1); font-size:17px; padding:6px 0; }
.pill { height:34px; padding:0 16px; border-radius:17px; background:linear-gradient(135deg,var(--c1),var(--c2)); color:#fff; font-weight:600; transition:transform .12s; }
.link { color:var(--dim); font-size:15px; }

/* Tab bar: a floating capsule, like the Mac player's dock */
.tabbar { position:fixed; left:14px; right:14px; bottom:calc(env(safe-area-inset-bottom) + 8px); z-index:5; display:flex; gap:2px;
          padding:5px; border-radius:30px; background:rgba(28,20,44,.72); border:1px solid rgba(255,255,255,.09);
          -webkit-backdrop-filter:blur(24px) saturate(1.4); backdrop-filter:blur(24px) saturate(1.4); box-shadow:0 10px 30px rgba(0,0,0,.35); }
.tabbar button { position:relative; flex:1; height:calc(var(--tab) - 10px); border-radius:24px; display:flex; flex-direction:column;
                 align-items:center; justify-content:center; gap:2px; color:var(--dim); font-size:10.5px; font-weight:600;
                 transition:transform .12s, color .2s, background .2s; }
.tabbar svg { width:23px; height:23px; fill:currentColor; }
.tabbar button.on { color:var(--ink); background:rgba(255,255,255,.12); }
.tabbar button.on svg { fill:var(--c1); }
#lyr { padding:30vh 6px 40vh; }
.ly { font-size:24px; font-weight:700; line-height:1.25; color:var(--ink); opacity:.32; margin:0 0 18px;
      transition:opacity .35s, transform .35s; transform-origin:left center; }
.ly.now { opacity:1; transform:scale(1.03); }
.ly.past { opacity:.22; }
.badge { position:absolute; top:4px; left:calc(50% + 6px); min-width:17px; height:17px; padding:0 5px; border-radius:9px; font-size:11px;
         line-height:17px; background:var(--c2); color:#fff; }

/* Now Playing sheet */
#sheet { position:fixed; inset:0; z-index:10; display:flex; flex-direction:column; align-items:center;
         padding:calc(env(safe-area-inset-top) + 8px) 26px calc(env(safe-area-inset-bottom) + 24px);
         background:linear-gradient(180deg, color-mix(in srgb, var(--c1) 38%, #0b0716), #0b0716 75%);
         transform:translateY(100%); transition:transform .35s cubic-bezier(.2,.9,.25,1); }
#sheet.open { transform:translateY(0); }
#sheet .grab { width:40px; height:5px; border-radius:3px; background:rgba(255,255,255,.35); margin:4px 0 18px; }
#sheet .down { position:absolute; left:16px; top:calc(env(safe-area-inset-top) + 8px); width:44px; height:44px; }
#sheet .down svg { width:24px; height:24px; fill:var(--ink); }
#sheet .art { width:min(78vw, 46vh, 380px); height:min(78vw, 46vh, 380px); border-radius:18px; font-size:64px;
              box-shadow:0 20px 60px rgba(0,0,0,.5); margin-top:14px; }
#sheet .meta { width:100%; max-width:420px; margin-top:26px; }
#sheet .t1 { font-size:22px; } #sheet .t2 { font-size:17px; margin-top:2px; }
.scrub { width:100%; max-width:420px; margin-top:18px; }
.times { display:flex; justify-content:space-between; font-size:12px; color:var(--dim); margin-top:4px; font-variant-numeric:tabular-nums; }
input[type=range] { -webkit-appearance:none; appearance:none; width:100%; height:24px; background:transparent; margin:0; }
input[type=range]::-webkit-slider-runnable-track { height:5px; border-radius:3px;
       background:linear-gradient(90deg, var(--c1), var(--c2)) 0 0 / var(--p,0%) 100% no-repeat, rgba(255,255,255,.2); }
input[type=range]::-webkit-slider-thumb { -webkit-appearance:none; width:18px; height:18px; border-radius:50%; background:#fff; margin-top:-6.5px;
       box-shadow:0 2px 6px rgba(0,0,0,.4); }
.big { display:flex; align-items:center; justify-content:center; gap:44px; margin-top:18px; }
.big .round { width:64px; height:64px; } .big .round svg { width:34px; height:34px; }
.big .pp { width:84px; height:84px; background:linear-gradient(135deg, color-mix(in srgb, var(--c1) 90%, white), var(--c2));
           border:1px solid rgba(255,255,255,.18); box-shadow:0 0 28px color-mix(in srgb, var(--c1) 55%, transparent); }
.big .pp svg { width:36px; height:36px; fill:#fff; }
.vol { width:100%; max-width:420px; display:flex; align-items:center; gap:12px; margin-top:24px; }
.vol svg { width:18px; height:18px; fill:var(--dim); flex:none; }
.sleep { width:100%; max-width:420px; margin-top:20px; }
.sleep span { font-size:13px; color:var(--dim); display:block; margin:0 0 6px 2px; }
.chips.sl { grid-template-columns:repeat(5,1fr); } .chips.sl .chip { height:34px; font-size:12.5px; }
.upnext { margin-top:auto; color:var(--dim); font-size:15px; padding:10px; }

/* Add to Home Screen tip, toast */
#tip { position:fixed; left:12px; right:12px; bottom:calc(var(--tab) + env(safe-area-inset-bottom) + 20px); z-index:6; display:none;
       padding:14px 44px 14px 14px; border-radius:16px; background:rgba(40,28,66,.97); border:1px solid var(--line); font-size:15px; }
#tip.show { display:block; }
#tip b { display:block; margin-bottom:3px; }
#tip button { position:absolute; right:8px; top:8px; width:32px; height:32px; color:var(--dim); font-size:20px; }
#toast { position:fixed; left:50%; bottom:calc(var(--tab) + env(safe-area-inset-bottom) + 18px); z-index:20;
         transform:translate(-50%,16px); opacity:0; background:rgba(30,22,48,.97); border:1px solid var(--line);
         padding:10px 18px; border-radius:22px; font-size:15px; transition:all .25s; pointer-events:none; white-space:nowrap; }
#toast.show { opacity:1; transform:translate(-50%,0); }
</style>
</head>
<body>
<div id="glow"></div>
<div id="app">
  <div class="brand"><img src="/icon.png" alt=""><b>Velyn</b></div>
  <div id="mini">
    <div class="art"><span>♪</span><img hidden alt=""></div>
    <div class="meta">
      <div class="t1" id="mTitle">Nothing playing</div>
      <div class="t2" id="mArtist">Open Music or Spotify on your Mac</div>
      <div class="bar"><div class="fill" id="mFill"></div></div>
    </div>
    <button class="round pp" data-a="playpause" aria-label="Play or pause"></button>
    <button class="round" data-a="next" aria-label="Next"><svg viewBox="0 0 24 24"><path d="M16 5h2v14h-2zM4 5v14l11-7z"/></svg></button>
  </div>
  <div id="mvol">
    <button class="step" data-step="-0.1" aria-label="Quieter"><svg viewBox="0 0 24 24"><path d="M4 9h4l5-4v14l-5-4H4z"/></svg></button>
    <input type="range" class="volr" min="0" max="100" value="100" aria-label="Volume">
    <button class="step" data-step="0.1" aria-label="Louder"><svg viewBox="0 0 24 24"><path d="M4 9h4l5-4v14l-5-4H4zm12.5-1.5a6 6 0 0 1 0 9l-1.4-1.4a4 4 0 0 0 0-6.2zm2.8-2.8a10 10 0 0 1 0 14.6l-1.4-1.4a8 8 0 0 0 0-11.8z"/></svg></button>
    <span id="volPct">100%</span>
  </div>
  <div id="status"></div>

  <div id="content">
    <section class="view" id="v-search">
      <h1>Search</h1>
      <div class="search"><input id="q" type="search" placeholder="Songs, artists, or a Spotify link" autocomplete="off" autocorrect="off" autocapitalize="off" enterkeyhint="search"></div>
      <div id="results"></div>
    </section>
    <section class="view" id="v-playlists" hidden><div id="pls"></div></section>
    <section class="view" id="v-lyrics" hidden><div id="lyr"></div></section>
    <section class="view" id="v-queue" hidden>
      <div class="head"><h1 style="margin:6px 0 4px">Up Next</h1><button id="clear" class="link">Clear</button></div>
      <div id="queue"></div>
    </section>
    <section class="view" id="v-look" hidden>
      <h1>Glow</h1>
      <div class="sec">Edge glow</div>
      <div class="card">
        <div class="line"><span>Glow</span><input type="checkbox" class="switch" id="lkGlow"></div>
        <div class="line col"><span>Colors</span><div class="swatches" id="lkColors"></div></div>
        <div class="line col"><span>Motion</span><div class="chips two" id="lkMode"></div></div>
        <div class="line col"><span>Brightness</span><input type="range" id="lkBright" min="0" max="100"></div>
      </div>
      <div class="sec">Lyrics</div>
      <div class="card">
        <div class="line"><span>Lyrics window</span><input type="checkbox" class="switch" id="lkWindow"></div>
        <div class="line col"><span>Style</span><div class="chips" id="lkStyle"></div></div>
        <div class="line"><span>Album art behind lyrics</span><input type="checkbox" class="switch" id="lkArt"></div>
      </div>
      <div class="msg" style="padding:16px 8px">Changes here show up on your Mac at once, and changes on the Mac show up here.</div>
    </section>
  </div>

  <nav class="tabbar">
    <button data-tab="search" class="on"><svg viewBox="0 0 24 24"><path d="M10 3a7 7 0 0 1 5.6 11.2l5 5-1.4 1.4-5-5A7 7 0 1 1 10 3zm0 2a5 5 0 1 0 0 10 5 5 0 0 0 0-10z"/></svg>Search</button>
    <button data-tab="playlists"><svg viewBox="0 0 24 24"><path d="M3 5h12v2H3zm0 4h12v2H3zm0 4h8v2H3zm14-8h4v2h-2v9.5a3 3 0 1 1-2-2.8z"/></svg>Playlists</button>
    <button data-tab="lyrics"><svg viewBox="0 0 24 24"><path d="M4 4h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-5 4v-4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2zm3 5v3h2l-1 2h2l1-2V9zm6 0v3h2l-1 2h2l1-2V9z"/></svg>Lyrics</button>
    <button data-tab="queue"><svg viewBox="0 0 24 24"><path d="M3 6h14v2H3zm0 5h14v2H3zm0 5h9v2H3zm16-2.5V9l4 3z"/></svg>Up Next<span class="badge" id="badge" hidden></span></button>
    <button data-tab="look"><svg viewBox="0 0 24 24"><path d="M12 2l1.8 4.6L18 4l-1.6 4.4L21 10l-4.6 1.6L18 16l-4.2-2.6L12 18l-1.8-4.6L6 16l1.6-4.4L3 10l4.6-1.6L6 4l4.2 2.6zM12 9.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5zM11 19h2v3h-2z"/></svg>Glow</button>
  </nav>
</div>

<div id="sheet" aria-hidden="true">
  <button class="down" aria-label="Close"><svg viewBox="0 0 24 24"><path d="M5.6 8.6 12 15l6.4-6.4L19.8 10 12 17.8 4.2 10z"/></svg></button>
  <div class="grab"></div>
  <div class="art"><span>♪</span><img hidden alt=""></div>
  <div class="meta"><div class="t1" id="sTitle">Nothing playing</div><div class="t2" id="sArtist"></div></div>
  <div class="scrub">
    <input type="range" id="seek" min="0" max="1000" value="0" aria-label="Position">
    <div class="times"><span id="pos">0:00</span><span id="dur"></span></div>
  </div>
  <div class="big">
    <button class="round" data-a="previous" aria-label="Previous"><svg viewBox="0 0 24 24"><path d="M6 5h2v14H6zM20 5v14L9 12z"/></svg></button>
    <button class="round pp" data-a="playpause" aria-label="Play or pause"></button>
    <button class="round" data-a="next" aria-label="Next"><svg viewBox="0 0 24 24"><path d="M16 5h2v14h-2zM4 5v14l11-7z"/></svg></button>
  </div>
  <div class="vol">
    <svg viewBox="0 0 24 24"><path d="M4 9h4l5-4v14l-5-4H4z"/></svg>
    <input type="range" id="vol" class="volr" min="0" max="100" value="100" aria-label="Volume">
    <svg viewBox="0 0 24 24"><path d="M4 9h4l5-4v14l-5-4H4zm12.5-1.5a6 6 0 0 1 0 9l-1.4-1.4a4 4 0 0 0 0-6.2zm2.8-2.8a10 10 0 0 1 0 14.6l-1.4-1.4a8 8 0 0 0 0-11.8z"/></svg>
  </div>
  <div class="sleep"><span id="sleepLbl">Sleep timer</span><div class="chips sl" id="sleep"></div></div>
  <button class="upnext" id="sUp"></button>
</div>

<div id="tip"><b>Make Velyn an app</b>Tap Share <svg viewBox="0 0 24 24" style="width:16px;height:16px;fill:currentColor;vertical-align:-2px"><path d="M12 2l4 4-1.4 1.4L13 5.8V15h-2V5.8L9.4 7.4 8 6zM5 10h3v2H6v8h12v-8h-2v-2h3v12H5z"/></svg>, then <b style="display:inline">Add to Home Screen</b>.<button id="tipX" aria-label="Close">×</button></div>
<div id="toast"></div>

<script>
const SVG = {
  play: '<svg viewBox="0 0 24 24"><path d="M7 4v16l13-8z"/></svg>',
  pause: '<svg viewBox="0 0 24 24"><path d="M6 4h4v16H6zM14 4h4v16h-4z"/></svg>',
  next: '<svg viewBox="0 0 24 24"><path d="M3 6h11v2H3zm0 5h11v2H3zm0 5h7v2H3zm14-6v-4l6 6-6 6v-4h-2v-4z"/></svg>',
  add: '<svg viewBox="0 0 24 24"><path d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6z"/></svg>',
  x: '<svg viewBox="0 0 24 24"><path d="M6.4 5 12 10.6 17.6 5 19 6.4 13.4 12 19 17.6 17.6 19 12 13.4 6.4 19 5 17.6 10.6 12 5 6.4z"/></svg>',
  list: '<svg viewBox="0 0 24 24"><path d="M3 5h12v2H3zm0 4h12v2H3zm0 4h8v2H3zm14-8h4v2h-2v9.5a3 3 0 1 1-2-2.8z"/></svg>'
};
const $ = id => document.getElementById(id);
const K = new URLSearchParams(location.search).get('k') || localStorage.getItem('velynKey') || '';
if (K) localStorage.setItem('velynKey', K);
const standalone = window.navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;

async function api(path, body) {
  const url = path + (path.includes('?') ? '&' : '?') + 'k=' + encodeURIComponent(K);
  const r = await fetch(url, body ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } : {});
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || 'Something went wrong');
  return j;
}
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function fmt(s) { s = Math.max(0, Math.floor(s || 0)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); }
let toastTimer;
function toast(t) { const e = $('toast'); e.textContent = t; e.classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => e.classList.remove('show'), 1600); }
async function act(fn, ok) { try { await fn(); if (ok) toast(ok); setTimeout(poll, 350); } catch (e) { toast(e.message); } }

// ---- Now playing
let st = null, stAt = 0, artKey = '', seeking = false, volTimer, volDrag = false;
function setStatus(text) { const s = $('status'); s.textContent = text || ''; s.classList.toggle('show', !!text); }
async function poll() {
  try { st = await api('/api/state'); stAt = Date.now(); setStatus(''); render(); }
  catch (e) {
    setStatus(e.message === 'Failed to fetch' || e.message === 'Load failed' || e.name === 'TypeError'
      ? 'Can’t reach your Mac. Make sure it’s awake and on the same Wi-Fi.' : e.message);
  }
}
function render() {
  const t = st.track;
  for (const [a, b] of [['mTitle', 'sTitle'], ['mArtist', 'sArtist']]) {
    const v = a === 'mTitle' ? (t ? t.title : 'Nothing playing') : (t ? t.artist : 'Open Music or Spotify on your Mac');
    $(a).textContent = v; $(b).textContent = v;
  }
  document.querySelectorAll('.pp').forEach(b => b.innerHTML = st.playing ? SVG.pause : SVG.play);
  const key = t && t.art ? t.title + '|' + t.artist : '';
  if (key !== artKey) {
    artKey = key;
    document.querySelectorAll('.art img').forEach(img => {
      if (key) { img.style.opacity = 0; img.hidden = false; img.onerror = () => img.hidden = true; img.onload = () => img.style.opacity = 1; img.src = '/api/art?k=' + encodeURIComponent(K) + '&v=' + encodeURIComponent(key); }
      else { img.hidden = true; img.removeAttribute('src'); }
    });
  }
  if (st.colors) applyColors(st.colors[0], st.colors[1]);
  if (st.look) renderLook(st.look);
  if (!volTimer && !volDrag) showVol(Math.round((st.macVolume ?? st.volume ?? 1) * 100));
  const n = st.queue.length;
  $('badge').hidden = !n; $('badge').textContent = n;
  $('sUp').textContent = n ? 'Up Next · ' + n + (n === 1 ? ' song' : ' songs') : '';
  renderQueue();
  renderSleep();
  if (st.lyricsKey !== lyrKey) loadLyrics();
  tick();
}
// ---- Lyrics: follow the song, current line lit and kept in the middle
let lyr = [], lyrOffset = 0, lyrKey = null, lyrNow = -2;
async function loadLyrics() {
  if (!st) return;
  lyrKey = st.lyricsKey;
  try {
    const j = await api('/api/lyrics');
    lyr = j.lines; lyrOffset = j.offset || 0; lyrNow = -2;
    const box = $('lyr');
    if (!lyr.length) { box.replaceChildren(el('div', 'msg', j.message || 'Lyrics not available')); return; }
    box.replaceChildren(...lyr.map(l => el('p', 'ly', l.s)));
  } catch (e) {}
}
function lyricsTick() {
  if ($('v-lyrics').hidden || !lyr.length) return;
  const t = position() + lyrOffset;
  let i = -1;
  for (let k = 0; k < lyr.length; k++) { if (lyr[k].t <= t) i = k; else break; }
  if (i === lyrNow) return;
  lyrNow = i;
  [...$('lyr').children].forEach((p, k) => { p.classList.toggle('now', k === i); p.classList.toggle('past', k < i); });
  const cur = $('lyr').children[Math.max(0, i)];
  if (cur) $('content').scrollTo({ top: cur.offsetTop - $('content').clientHeight * 0.35, behavior: 'smooth' });
}
setInterval(lyricsTick, 250);
const SLEEP = [[0, 'Off'], [15, '15m'], [30, '30m'], [60, '1h'], [-1, 'Song end']];
$('sleep').replaceChildren(...SLEEP.map(([m, t]) => { const b = el('button', 'chip', t); b.dataset.m = m;
  b.onclick = () => act(() => api('/api/sleep', { minutes: m }), m === 0 ? 'Sleep timer off' : 'Sleep timer set'); return b; }));
function renderSleep() {
  const s = st.sleep || 0;
  document.querySelectorAll('#sleep .chip').forEach(b => {
    const m = +b.dataset.m;
    b.classList.toggle('on', m === 0 ? s === 0 : (m === -1 ? s === -1 : (s > 0 && m === SLEEP.filter(x => x[0] > 0).map(x => x[0]).find(v => v >= s))));
  });
  $('sleepLbl').textContent = s > 0 ? 'Sleep timer · ' + s + ' min left' : s === -1 ? 'Sleep timer · end of this song' : 'Sleep timer';
}
// The Mac's glow colours, kept readable on the dark page (a black custom colour gives way to the other one).
function lum(h) { const n = parseInt(h.slice(1), 16); return (0.2126 * (n >> 16 & 255) + 0.7152 * (n >> 8 & 255) + 0.0722 * (n & 255)) / 255; }
function lift(h, amt) { const n = parseInt(h.slice(1), 16); const m = c => Math.round(c + (255 - c) * amt);
  return '#' + [n >> 16 & 255, n >> 8 & 255, n & 255].map(m).map(v => v.toString(16).padStart(2, '0')).join(''); }
function applyColors(a, b) {
  const ok = h => /^#[0-9a-f]{6}$/i.test(h);
  if (!ok(a) || !ok(b)) return;
  if (lum(a) < 0.12 && lum(b) >= 0.12) a = b;
  if (lum(b) < 0.12 && lum(a) >= 0.12) b = a;
  if (lum(a) < 0.12) { a = '#9e61ff'; b = '#e52ec7'; }
  if (lum(a) < 0.3) a = lift(a, 0.25);
  const r = document.documentElement.style;
  r.setProperty('--c1', a); r.setProperty('--c2', b); r.setProperty('--accent', a);
}
function position() {
  if (!st || !st.track) return 0;
  let p = st.position + (st.playing ? (Date.now() - stAt) / 1000 : 0);
  return st.track.duration ? Math.min(p, st.track.duration) : p;
}
function paint(r) { r.style.setProperty('--p', (100 * (r.value - r.min) / (r.max - r.min)) + '%'); }
function tick() {
  const d = st && st.track ? st.track.duration : 0, p = position();
  $('mFill').style.width = d ? (100 * p / d) + '%' : '0';
  if (!seeking) { $('seek').value = d ? Math.round(1000 * p / d) : 0; paint($('seek')); $('pos').textContent = fmt(p); }
  $('dur').textContent = d ? '-' + fmt(d - (seeking ? d * $('seek').value / 1000 : p)) : '';
}
document.querySelectorAll('[data-a]').forEach(b => b.onclick = e => { e.stopPropagation(); act(() => api('/api/control', { action: b.dataset.a })); });
$('seek').addEventListener('input', () => { seeking = true; paint($('seek')); const d = st && st.track ? st.track.duration : 0; $('pos').textContent = fmt(d * $('seek').value / 1000); tick(); });
$('seek').addEventListener('change', () => {
  const d = st && st.track ? st.track.duration : 0;
  if (d) act(() => api('/api/control', { action: 'seek', position: d * $('seek').value / 1000 }));
  setTimeout(() => seeking = false, 800);
});
// Volume: the bar under the mini player and the Now Playing slider are kept in step.
const vols = document.querySelectorAll('.volr');
function showVol(v) {
  vols.forEach(r => { r.value = v; paint(r); });
  $('volPct').textContent = v + '%';
}
function sendVol(v) {
  v = Math.max(0, Math.min(100, Math.round(v)));
  showVol(v);
  clearTimeout(volTimer);
  volTimer = setTimeout(() => { volTimer = null; api('/api/control', { action: st && st.macVolume == null ? 'volume' : 'macvolume', value: v / 100 }).catch(() => {}); }, 120);
}
vols.forEach(r => {
  r.addEventListener('input', () => sendVol(+r.value));
  r.addEventListener('pointerdown', () => volDrag = true);
  r.addEventListener('touchstart', () => volDrag = true, { passive: true });
  ['pointerup', 'touchend', 'change'].forEach(e => r.addEventListener(e, () => setTimeout(() => volDrag = false, 600)));
});
document.querySelectorAll('#mvol .step').forEach(b => b.onclick = () => sendVol(+vols[0].value + 100 * +b.dataset.step));
setInterval(() => { if (document.visibilityState === 'visible') poll(); }, 2000);
setInterval(tick, 500);
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') poll(); });

// ---- Now Playing sheet: tap the mini player; close with the chevron or a swipe down
const sheet = $('sheet');
function openSheet(on) { sheet.classList.toggle('open', on); sheet.setAttribute('aria-hidden', on ? 'false' : 'true'); }
$('mini').onclick = () => openSheet(true);
sheet.querySelector('.down').onclick = () => openSheet(false);
$('sUp').onclick = () => { openSheet(false); show('queue'); };
let y0 = null;
sheet.addEventListener('touchstart', e => { if (!e.target.closest('input')) y0 = e.touches[0].clientY; }, { passive: true });
sheet.addEventListener('touchmove', e => {
  if (y0 == null) return;
  const dy = Math.max(0, e.touches[0].clientY - y0);
  sheet.style.transition = 'none'; sheet.style.transform = 'translateY(' + dy + 'px)';
}, { passive: true });
sheet.addEventListener('touchend', e => {
  if (y0 == null) return;
  const dy = e.changedTouches[0].clientY - y0; y0 = null;
  sheet.style.transition = ''; sheet.style.transform = '';
  if (dy > 110) openSheet(false);
});

// The search box only gets a backdrop once results scroll under it.
$('content').addEventListener('scroll', () => document.querySelector('.search').classList.toggle('stuck', $('content').scrollTop > 60), { passive: true });

// ---- Songs
function songRow(r) {
  const row = el('div', 'row');
  const info = el('div', 'info');
  info.append(el('div', 't1', r.title), el('div', 't2', [r.artist, r.album].filter(Boolean).join(' · ')));
  const play = el('button', 'ic go'); play.innerHTML = SVG.play; play.setAttribute('aria-label', 'Play now');
  const next = el('button', 'ic'); next.innerHTML = SVG.next; next.setAttribute('aria-label', 'Play next');
  const add = el('button', 'ic'); add.innerHTML = SVG.add; add.setAttribute('aria-label', 'Add to Up Next');
  play.onclick = () => act(() => api('/api/play', { song: r.song }), 'Playing on your Mac');
  next.onclick = () => act(() => api('/api/queue', { song: r.song, next: true }), 'Plays next');
  add.onclick = () => act(() => api('/api/queue', { song: r.song }), 'Added to Up Next');
  row.append(info, play, next, add);
  return row;
}
function message(box, text) { box.replaceChildren(el('div', 'msg', text)); }
function statusText(s) {
  return s === 'notRunning' ? 'Open Music on your Mac to search your songs.'
       : s === 'failed' ? 'Couldn’t read your Music library.' : 'Reading your Music library…';
}
let searchTimer, searchSeq = 0;
$('q').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(search, 250); });
$('q').addEventListener('search', () => { search(); $('q').blur(); });
async function search() {
  const q = $('q').value.trim(), box = $('results'), seq = ++searchSeq;
  if (!q) { message(box, 'Search the songs in your library and playlists, or paste a Spotify song link.'); return; }
  try {
    const j = await api('/api/search?q=' + encodeURIComponent(q));
    if (seq !== searchSeq) return;
    if (j.status !== 'ready' && !j.songs.length) { message(box, statusText(j.status)); if (j.status === 'loading') setTimeout(search, 1500); return; }
    if (!j.songs.length) { message(box, 'No songs match “' + q + '”.'); return; }
    const card = el('div', 'card'); card.append(...j.songs.map(songRow));
    box.replaceChildren(el('div', 'sec', j.songs.length + (j.songs.length === 1 ? ' song' : ' songs')), card);
  } catch (e) { message(box, e.message); }
}

// ---- Playlists
let playlistsLoaded = false;
async function loadPlaylists() {
  const box = $('pls');
  try {
    const j = await api('/api/playlists');
    if (j.status !== 'ready' && !j.playlists.length) { box.replaceChildren(el('h1', null, 'Playlists'), el('div', 'msg', statusText(j.status))); if (j.status === 'loading') setTimeout(loadPlaylists, 1500); return; }
    playlistsLoaded = true;
    if (!j.playlists.length) { box.replaceChildren(el('h1', null, 'Playlists'), el('div', 'msg', 'No playlists in Music yet.')); return; }
    const card = el('div', 'card');
    card.append(...j.playlists.map(p => {
      const row = el('button', 'row');
      const icon = el('div', 'plicon'); icon.innerHTML = SVG.list;
      const info = el('div', 'info'); info.append(el('div', 't1', p.name), el('div', 't2', p.count + (p.count === 1 ? ' song' : ' songs')));
      row.append(icon, info, el('span', 'chev', '›'));
      row.onclick = () => openPlaylist(p.id);
      return row;
    }));
    box.replaceChildren(el('h1', null, 'Playlists'), el('div', 'sec', 'Your playlists'), card);
  } catch (e) { message(box, e.message); }
}
async function openPlaylist(id) {
  const box = $('pls');
  try {
    const j = await api('/api/playlist?id=' + encodeURIComponent(id));
    const head = el('div', 'head');
    const back = el('button', 'back', '‹ Playlists'); back.onclick = loadPlaylists;
    const play = el('button', 'pill', 'Play'); play.onclick = () => act(() => api('/api/playlist/play', { id }), 'Playing on your Mac');
    head.append(back, play);
    const card = el('div', 'card'); card.append(...j.songs.map(songRow));
    box.replaceChildren(head, el('h1', null, j.name), el('div', 'sec', j.songs.length + ' songs'), card);
    $('content').scrollTo({ top: 0 });
  } catch (e) { toast(e.message); }
}

// ---- Up Next
function renderQueue() {
  const box = $('queue');
  if (!st.queue.length) { message(box, 'Nothing queued. Songs you add play after the current one, then your Mac carries on as usual.'); return; }
  const card = el('div', 'card');
  card.append(...st.queue.map(e => {
    const row = el('div', 'row');
    const info = el('div', 'info'); info.append(el('div', 't1', e.title), el('div', 't2', e.artist));
    const x = el('button', 'ic'); x.innerHTML = SVG.x; x.setAttribute('aria-label', 'Remove');
    x.onclick = () => act(() => api('/api/queue/remove', { id: e.id }));
    row.append(info, x);
    return row;
  }));
  box.replaceChildren(el('div', 'sec', 'Plays after the current song'), card);
}
$('clear').onclick = () => act(() => api('/api/queue/clear'), 'Up Next cleared');

// ---- Glow & lyrics settings, linked with the Mac's
let lookInfo = null, lookBusy = 0;
async function loadLook() {
  try {
    lookInfo = await api('/api/look');
    $('lkColors').replaceChildren(...[-1, ...lookInfo.presets.keys()].map(i => {
      const b = el('button', 'sw');
      b.dataset.preset = i;
      if (i === -1) { b.textContent = 'A'; b.style.background = 'rgba(255,255,255,.9)'; b.setAttribute('aria-label', 'Album colors'); }
      else { const [x, y] = lookInfo.presets[i]; b.style.background = 'linear-gradient(135deg,' + x + ',' + y + ')'; b.setAttribute('aria-label', 'Preset ' + (i + 1)); }
      b.onclick = () => setLook({ preset: i });
      return b;
    }));
    $('lkMode').replaceChildren(...lookInfo.modes.map(m => { const b = el('button', 'chip', m.title); b.dataset.id = m.id; b.onclick = () => setLook({ mode: m.id }); return b; }));
    $('lkStyle').replaceChildren(...lookInfo.styles.map(m => { const b = el('button', 'chip', m.title); b.dataset.id = m.id; b.onclick = () => setLook({ style: m.id }); return b; }));
    renderLook(lookInfo);
  } catch (e) { toast(e.message); }
}
function renderLook(l) {
  if (!lookInfo || lookBusy) return;
  $('lkGlow').checked = l.glow; $('lkWindow').checked = l.lyricsWindow;
  $('lkArt').checked = l.art; $('lkArt').disabled = !l.artOK;
  if (document.activeElement !== $('lkBright')) { $('lkBright').value = Math.round(l.brightness * 100); paint($('lkBright')); }
  document.querySelectorAll('#lkColors .sw').forEach(b => b.classList.toggle('on', +b.dataset.preset === l.preset));
  document.querySelectorAll('#lkMode .chip').forEach(b => b.classList.toggle('on', b.dataset.id === l.mode));
  document.querySelectorAll('#lkStyle .chip').forEach(b => b.classList.toggle('on', b.dataset.id === l.style));
}
async function setLook(change) {
  lookBusy++;
  try { const l = await api('/api/look', change); lookBusy--; renderLook(l); setTimeout(poll, 250); }
  catch (e) { lookBusy--; toast(e.message); }
}
$('lkGlow').onchange = () => setLook({ glow: $('lkGlow').checked });
$('lkWindow').onchange = () => setLook({ lyricsWindow: $('lkWindow').checked });
$('lkArt').onchange = () => setLook({ art: $('lkArt').checked });
let brightTimer;
$('lkBright').addEventListener('input', () => {
  paint($('lkBright'));
  clearTimeout(brightTimer);
  brightTimer = setTimeout(() => setLook({ brightness: $('lkBright').value / 100 }), 120);
});

// ---- Tabs
function show(tab) {
  document.querySelectorAll('.tabbar button').forEach(x => x.classList.toggle('on', x.dataset.tab === tab));
  ['search', 'playlists', 'lyrics', 'queue', 'look'].forEach(t => $('v-' + t).hidden = t !== tab);
  if (tab === 'lyrics') { lyrNow = -2; loadLyrics(); }
  $('content').scrollTo({ top: 0 });
  if (tab === 'playlists') loadPlaylists();     // fresh every time (songs added in Music show up)
  if (tab === 'look' && !lookInfo) loadLook();
}
document.querySelectorAll('.tabbar button').forEach(b => b.onclick = () => show(b.dataset.tab));

// ---- First run
if (!standalone && !localStorage.getItem('velynTipDone')) $('tip').classList.add('show');
$('tipX').onclick = () => { $('tip').classList.remove('show'); localStorage.setItem('velynTipDone', '1'); };
if (!K) setStatus('Open the link from Velyn’s settings on your Mac.');
search();
poll();
</script>
</body>
</html>
"""#
}
