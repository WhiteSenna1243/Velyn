#!/bin/bash
# One-time: creates a local code-signing certificate called "Velyn Dev".
# Why: an ad-hoc signed app gets a new identity every build, so macOS forgets its
# permissions and shows the lock prompt again. A stable certificate fixes that.
set -euo pipefail
NAME="Velyn Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/velyn.p12" \
    -passout pass:velyn -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import "$TMP/velyn.p12" -k "$KEYCHAIN" -P velyn -T /usr/bin/codesign
# Trust it for code signing (macOS may ask for your login password once).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" || true
echo "Done. Run ./build_app.sh, open Velyn.app, and allow the audio prompt once."
echo "Later builds keep the permission."
