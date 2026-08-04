#!/usr/bin/env bash
# Build BSK V3 X HS.app — Swift menu bar app with IOKit HID.
# No Apple Developer account needed; ad-hoc code sign for personal use.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BSK V3 X HS"
BIN_NAME="BSKV3XHS"
BUNDLE_ID="local.bskv3xhs"
OUT_DIR="build"
APP_DIR="$OUT_DIR/$APP_NAME.app"

echo "→ Cleaning previous build"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "→ Compiling Swift sources"
# NOTE: the `-not -name '._*'` filter below is load-bearing when the repo
# lives on a non-HFS/APFS volume (exFAT, NTFS, SMB share). macOS stores
# extended attributes for each file in a sidecar AppleDouble file named
# `._<original>`, so `find Sources -name '*.swift'` returns 80 paths for a
# 40-file tree and swiftc tries to compile 40 binary blobs — several hundred
# bogus "cannot find 'T' in scope" errors that bury any real diagnostic.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx14.0 \
    -O \
    -whole-module-optimization \
    -parse-as-library \
    -framework AppKit -framework SwiftUI -framework IOKit -framework Combine -framework CoreBluetooth -framework UserNotifications \
    $(find Sources -name '*.swift' -not -name '._*') \
    -o "$APP_DIR/Contents/MacOS/$BIN_NAME"

echo "→ Copying Info.plist and resources"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
# Copy every non-plist resource into Contents/Resources. Directories (like
# .lproj folders holding Localizable.strings) get copied recursively so the
# bundle keeps its localized-resources shape.
for f in Resources/*; do
    name=$(basename "$f")
    if [ "$name" = "Info.plist" ]; then continue; fi
    if [ -d "$f" ]; then
        cp -R "$f" "$APP_DIR/Contents/Resources/$name"
    else
        cp "$f" "$APP_DIR/Contents/Resources/$name"
    fi
done

# Pick a stable code-signing identity so macOS TCC keeps permissions
# (Input Monitoring, Accessibility) across rebuilds. Preference order:
#   1) An Apple Development / Apple Distribution cert (from Xcode)
#   2) The self-signed "BSK V3 X HS Dev" cert (from setup-cert.sh)
#   3) Ad-hoc (falls back — requires re-granting permissions per rebuild)
IDENTITIES=$(/usr/bin/security find-identity -v -p codesigning)
# awk to pull the first quoted-identity string matching a preferred name,
# avoiding `head` which on this system is aliased to a Perl HTTP helper.
first_match() {
    /usr/bin/awk -v pat="$1" '{
        if (match($0, pat)) {
            print substr($0, RSTART+1, RLENGTH-2); exit
        }
    }' <<<"$IDENTITIES"
}

if IDENTITY=$(first_match '"Apple Development: [^"]+"') && [ -n "$IDENTITY" ]; then
    echo "→ Code signing with Apple Development identity"
elif IDENTITY=$(first_match '"BSK V3 X HS Dev"') && [ -n "$IDENTITY" ]; then
    echo "→ Code signing with self-signed 'BSK V3 X HS Dev'"
elif IDENTITY=$(first_match '"Basilisk Mac Dev"') && [ -n "$IDENTITY" ]; then
    # Backwards-compat: existing users who already ran the old setup-cert.sh
    # keep working without a re-grant. New installs get the new name.
    echo "→ Code signing with legacy self-signed 'Basilisk Mac Dev'"
else
    IDENTITY="-"
    echo "→ Ad-hoc code signing (run setup-cert.sh once to make permissions stick)"
fi
# Strip AppleDouble sidecars from the bundle before signing. On a non-native
# volume every file we copied in has a `._<name>` twin holding its xattrs;
# codesign walks the bundle, finds `Contents/MacOS/._BSKV3XHS`, and fails the
# whole signature with "Operation not permitted". dot_clean folds those
# sidecars back into the real files and removes them.
if command -v dot_clean >/dev/null 2>&1; then
    dot_clean -m "$APP_DIR" 2>/dev/null || true
fi
find "$APP_DIR" -name '._*' -delete 2>/dev/null || true

# Signature failures must be fatal. This used to end in `|| true`, which meant
# a failed sign still printed "✓ Built" and handed the user an unsigned app —
# macOS then treats it as a different binary and silently drops its
# Accessibility / Input Monitoring grants, so remapped buttons stop working
# with nothing in the log to explain why.
set -o pipefail
if ! codesign --force --deep --sign "$IDENTITY" "$APP_DIR" 2>&1 | grep -v "replacing existing signature"; then
    # grep exits 1 when it filtered every line (the normal quiet success
    # case), so re-verify rather than trusting the pipeline's status.
    if ! codesign --verify --deep "$APP_DIR" 2>/dev/null; then
        echo "✗ Code signing FAILED — not writing a build you can't run." >&2
        echo "  The app would launch but lose its TCC permissions (buttons would stop working)." >&2
        exit 1
    fi
fi
set +o pipefail
echo "→ Signature verified"

echo
echo "✓ Built: $APP_DIR"
echo "Run: open \"$APP_DIR\""
