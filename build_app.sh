#!/bin/bash
# Everyday build for your own Mac: website flavour, this Mac's chip, signed with your local
# "Velyn Dev" certificate (tools/make_signing_cert.sh) so macOS keeps its permissions across rebuilds.
#   ./build_app.sh                 -> Velyn.app
#   FLAVOR=appstore ./build_app.sh -> the sandboxed App Store variant, to try locally
# For builds you hand out, use tools/package.sh instead.
set -euo pipefail
cd "$(dirname "$0")"
source tools/bundle.sh
FLAVOR="${FLAVOR:-website}"

pkill -x "$APP_NAME" 2>/dev/null || true
make_bundle "$FLAVOR" 0 .

if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID="-"
    for name in "Velyn Dev" "Halo Dev"; do
        if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$name\""; then SIGN_ID="$name"; break; fi
    done
fi
ENT=Resources/Velyn.entitlements
[ "$FLAVOR" = "appstore" ] && ENT=Resources/Velyn-AppStore.entitlements
# Hardened runtime, like the real release, so problems show up here first.
codesign --force --options runtime --entitlements "$ENT" --sign "$SIGN_ID" "$APP_NAME.app"
if [ "$SIGN_ID" = "-" ]; then
    echo "Note: ad-hoc signed, so macOS will re-ask for permissions after each rebuild."
    echo "Fix once with:  ./tools/make_signing_cert.sh   then run ./build_app.sh again."
fi
echo "Built $(pwd)/$APP_NAME.app ($FLAVOR, signed with $SIGN_ID)"
echo "Run it with:  open $APP_NAME.app"
