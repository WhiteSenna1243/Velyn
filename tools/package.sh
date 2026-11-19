#!/bin/bash
# Release builds you can hand out. Universal (Apple silicon + Intel). See SELLING.md for the
# one-time Apple setup (certificates, notary profile, App Store record).
#
#   tools/package.sh website     signed with Developer ID, notarised, stapled -> dist/Velyn-<version>.dmg
#   tools/package.sh appstore    sandboxed, signed for the Mac App Store     -> dist/appstore/Velyn.pkg
#
# Needs (website):  DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#                   NOTARY_PROFILE=velyn   (made once with: xcrun notarytool store-credentials velyn ...)
# Needs (appstore): APPSTORE_ID="Apple Distribution: Your Name (TEAMID)"
#                   INSTALLER_ID="3rd Party Mac Developer Installer: Your Name (TEAMID)"
#                   PROFILE=path/to/Velyn_Mac_App_Store.provisionprofile
# Try the whole flow without an Apple account: LOCAL=1 tools/package.sh website|appstore
# (signs with your local certificate and skips notarising and the App Store signature).
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/bundle.sh
FLAVOR="${1:?usage: tools/package.sh website|appstore}"
LOCAL="${LOCAL:-0}"

local_id() {
    for name in "Velyn Dev" "Halo Dev"; do
        if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$name\""; then echo "$name"; return; fi
    done
    echo "-"
}

case "$FLAVOR" in
website)
    OUT=dist
    mkdir -p "$OUT"
    if [ "$LOCAL" = "1" ]; then ID="$(local_id)"; else ID="${DEVELOPER_ID:?Set DEVELOPER_ID (see SELLING.md)}"; fi
    make_bundle website 1 "$OUT"
    APP="$OUT/$APP_NAME.app"
    TS="--timestamp"
    [ "$LOCAL" = "1" ] && TS="--timestamp=none"
    codesign --force --options runtime "$TS" --entitlements Resources/Velyn.entitlements --sign "$ID" "$APP"
    codesign --verify --strict --verbose=1 "$APP"

    if [ "$LOCAL" != "1" ]; then
        echo "Notarising the app (a few minutes)…"
        ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
        xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "${NOTARY_PROFILE:-velyn}" --wait
        rm "$OUT/notarize.zip"
        xcrun stapler staple "$APP"
    fi

    DMG="$OUT/$APP_NAME-$VERSION.dmg"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    if [ "$LOCAL" != "1" ]; then
        codesign --sign "$ID" --timestamp "$DMG"
        echo "Notarising the disk image…"
        xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-velyn}" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    fi
    echo "Done: $DMG"
    ;;
appstore)
    OUT=dist/appstore
    mkdir -p "$OUT"
    make_bundle appstore 1 "$OUT"
    APP="$OUT/$APP_NAME.app"
    ENT="$OUT/entitlements.plist"
    cp Resources/Velyn-AppStore.entitlements "$ENT"
    if [ "$LOCAL" = "1" ]; then
        codesign --force --options runtime --entitlements "$ENT" --sign "$(local_id)" "$APP"
        codesign --verify --strict --verbose=1 "$APP"
        echo "Local App Store variant: $APP (not uploadable: needs your Apple signature and profile)"
        exit 0
    fi
    : "${APPSTORE_ID:?Set APPSTORE_ID (see SELLING.md)}"
    : "${INSTALLER_ID:?Set INSTALLER_ID (see SELLING.md)}"
    : "${PROFILE:?Set PROFILE to your Mac App Store provisioning profile}"
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    # The profile's team and app identifiers must be in the signature.
    security cms -D -i "$PROFILE" > "$OUT/profile.plist"
    TEAM="$(plutil -extract TeamIdentifier.0 raw "$OUT/profile.plist")"
    APPID="$(plutil -extract Entitlements.com\\.apple\\.application-identifier raw "$OUT/profile.plist")"
    plutil -insert com\\.apple\\.application-identifier -string "$APPID" "$ENT"
    plutil -insert com\\.apple\\.developer\\.team-identifier -string "$TEAM" "$ENT"
    rm "$OUT/profile.plist"
    codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$APPSTORE_ID" "$APP"
    codesign --verify --strict --verbose=1 "$APP"
    productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$OUT/$APP_NAME.pkg"
    echo "Done: $OUT/$APP_NAME.pkg  -> upload it with Apple's Transporter app (free on the Mac App Store)."
    ;;
*)
    echo "usage: tools/package.sh website|appstore" >&2
    exit 1
    ;;
esac
