#!/bin/bash
# Shared by build_app.sh and tools/package.sh: builds the binary and assembles <out>/Velyn.app.
#   make_bundle <website|appstore> <universal: 0|1> <out dir>
source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"

make_bundle() {
    local flavor="$1" universal="$2" out="$3"
    local flags=()
    [ "$flavor" = "appstore" ] && flags=(-Xswiftc -DAPPSTORE)

    local bins=()
    local archs=("$(uname -m)")
    [ "$universal" = "1" ] && archs=(arm64 x86_64)
    for arch in "${archs[@]}"; do
        local scratch=".build/$flavor-$arch"
        swift build -c release --arch "$arch" --scratch-path "$scratch" ${flags[@]+"${flags[@]}"}
        bins+=("$scratch/release/$APP_NAME")
    done

    local app="$out/$APP_NAME.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    if [ "${#bins[@]}" -gt 1 ]; then
        lipo -create "${bins[@]}" -output "$app/Contents/MacOS/$APP_NAME"
    else
        cp "${bins[0]}" "$app/Contents/MacOS/$APP_NAME"
    fi

    # Icon (Resources/AppIcon.png, 1024 px -> AppIcon.icns) and Apple's privacy manifest.
    local iconset
    iconset="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$iconset"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
    cp Resources/PrivacyInfo.xcprivacy "$app/Contents/Resources/"

    local extra=""
    if [ "$flavor" = "appstore" ]; then
        extra='    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>NSAppleMusicUsageDescription</key>
    <string>Velyn looks up animated album covers in the Apple Music catalog.</string>'
    elif [ -n "$UPDATE_URL" ]; then
        extra="    <key>VelynUpdateURL</key><string>$UPDATE_URL</string>"
    fi

    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>$APP_NAME reads the song playing in Music or Spotify, and plays, pauses and skips for you, to show synced lyrics.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>The phone remote lets your phone, on the same Wi-Fi, search songs and control what plays on this Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>$APP_NAME listens to your Mac's sound (loudness, bass, beats) to move the edge glow with the music. Nothing is recorded or stored.</string>
$extra
</dict>
</plist>
PLIST
    plutil -lint "$app/Contents/Info.plist" >/dev/null
}
