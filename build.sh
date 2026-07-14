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
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx14.0 \
    -O \
    -whole-module-optimization \
    -parse-as-library \
    -framework AppKit -framework SwiftUI -framework IOKit -framework Combine -framework CoreBluetooth -framework UserNotifications \
    $(find Sources -name '*.swift') \
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
codesign --force --deep --sign "$IDENTITY" "$APP_DIR" 2>&1 | grep -v "replacing existing signature" || true

echo
echo "✓ Built: $APP_DIR"
echo "Run: open \"$APP_DIR\""
