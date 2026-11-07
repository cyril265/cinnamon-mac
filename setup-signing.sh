#!/bin/bash
# One-time: creates a self-signed code signing identity in its own keychain.
# A stable signature keeps the Accessibility permission across rebuilds.
set -euo pipefail

IDENTITY="WindowBar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/windowbar-signing.keychain-db"
PASSWORD_ITEM="windowbar-signing-keychain"

if [ -f "$KEYCHAIN" ]; then echo "Signing keychain already exists: $KEYCHAIN"; exit 0; fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
KEYCHAIN_PASSWORD=$(openssl rand -hex 24)
P12_PASSWORD=$(openssl rand -hex 24)
security add-generic-password -U -s "$PASSWORD_ITEM" -a "$USER" -l "WindowBar signing keychain" -w "$KEYCHAIN_PASSWORD"

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" -passout "pass:$P12_PASSWORD"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
echo "Created signing identity \"$IDENTITY\" in $KEYCHAIN"
