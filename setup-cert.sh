#!/usr/bin/env bash
# Create a one-time self-signed code-signing certificate in the login keychain.
# We use this to sign the app with a *stable* identity so macOS TCC keeps
# whatever permissions the user granted (Input Monitoring, Accessibility)
# across rebuilds. Ad-hoc signing (-) gives a new cdhash every build → TCC
# invalidates and you'd have to re-grant every time.
#
# Run this once. After that, build.sh will sign with "BSK V3 X HS Dev".
set -euo pipefail

CERT_NAME="BSK V3 X HS Dev"

if security find-identity -v -p codesigning | grep -qi "$CERT_NAME"; then
    echo "✓ Certificate '$CERT_NAME' already exists in your keychain."
    exit 0
fi

echo "→ Creating self-signed cert '$CERT_NAME' (personal use only)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Cert config: code-signing usage.
cat > "$TMP/cert.conf" <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = dn
x509_extensions = v3_ca
[ dn ]
CN = $CERT_NAME
[ v3_ca ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl genrsa -out "$TMP/key.pem" 2048
openssl req -new -x509 -sha256 -days 3650 -config "$TMP/cert.conf" -key "$TMP/key.pem" -out "$TMP/cert.pem"
# `-legacy` uses the older RC2/RC4 cipher combo that macOS `security import`
# understands out of the box. Modern openssl otherwise uses AES-256 which
# macOS's importer can't verify with an empty password.
PASS="basilisk-personal"
# Try legacy cipher first (modern openssl); fall back to default if the flag
# isn't recognized (LibreSSL / older builds).
if ! openssl pkcs12 -legacy -export \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/cert.p12" -password "pass:$PASS" -name "$CERT_NAME" 2>/dev/null; then
    openssl pkcs12 -export \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/cert.p12" -password "pass:$PASS" -name "$CERT_NAME"
fi

# Import into login keychain, allow codesign to use it without prompting.
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
# Also mark the cert itself as trusted for code signing.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true

echo "✓ Installed '$CERT_NAME' in login.keychain. Signature identity is stable across rebuilds."
echo "  Now rebuild the app: bash build.sh"
