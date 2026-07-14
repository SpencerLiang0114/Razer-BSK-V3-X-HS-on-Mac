#!/usr/bin/env bash
# Produce release artifacts for GitHub:
#   dist/Razer-BSK-V3-X-HS-<ver>.app.zip   — plain zipped .app
#   dist/Razer-BSK-V3-X-HS-<ver>.dmg       — drag-to-Applications installer
#
# build.sh runs first so the shipping .app reflects the current source.
# The .app is then re-signed ad-hoc so no personal Apple Dev identity
# leaks into the public binary. The DMG itself is unsigned — end users
# can trust whatever's inside based on the .app's signature.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BSK V3 X HS"
# Release filename base — matches the GitHub repo name so users can eyeball
# the download and know which project it belongs to. The app bundle name
# itself stays "BSK V3 X HS.app" (what shows up on their Mac).
RELEASE_NAME="Razer-BSK-V3-X-HS"

# Pull the version straight from Info.plist so release.sh and Info.plist
# never drift.
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
echo "→ Version: $VERSION"

# Build the app first (delegates to build.sh so signing / entitlements
# stay in one place).
bash build.sh

# ─── Strip personal signing identity ──────────────────────────────
# build.sh signs with whichever cert is first available on the machine
# (Apple Dev → self-signed → ad-hoc). For a public release we want to
# strip anything with personal contact info (Apple Dev certs embed the
# developer's email) and drop back to ad-hoc so the binary is safe to
# hand out. Users who want stable TCC across re-signs run setup-cert.sh
# then codesign the .app themselves — see README.
BUILT_APP="build/${APP_NAME}.app"
echo "→ Re-signing release binary with ad-hoc identity (no personal info)"
/usr/bin/codesign --remove-signature "$BUILT_APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$BUILT_APP"

DIST_DIR="dist"
mkdir -p "$DIST_DIR"

# ─── ZIP the .app ─────────────────────────────────────────────────
ZIP_NAME="${RELEASE_NAME}-${VERSION}.app.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
rm -f "$ZIP_PATH"
echo "→ Zipping .app → $ZIP_PATH"
# Use ditto so extended attributes + resource forks + code-signing
# metadata are preserved. Regular zip strips them and macOS rejects the
# extracted bundle as "damaged".
/usr/bin/ditto -c -k --keepParent "build/${APP_NAME}.app" "$ZIP_PATH"

# ─── Build the .dmg ───────────────────────────────────────────────
DMG_NAME="${RELEASE_NAME}-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
STAGE="$DIST_DIR/dmg-stage"
rm -rf "$STAGE" "$DMG_PATH"
mkdir -p "$STAGE"

# Layout: .app + Applications symlink (drag-to-install convention).
echo "→ Staging DMG contents"
/usr/bin/ditto "build/${APP_NAME}.app" "$STAGE/${APP_NAME}.app"
/bin/ln -s /Applications "$STAGE/Applications"

echo "→ Creating $DMG_PATH"
# UDZO = compressed read-only, standard for release DMGs.
# `hdiutil create` doesn't like an existing target — we removed it above.
/usr/bin/hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGE"

# ─── Report ───────────────────────────────────────────────────────
echo
echo "✓ Release artifacts:"
ls -lh "$DIST_DIR" | /usr/bin/awk 'NR>1 {print "    " $9 "  (" $5 ")"}'
echo
echo "Upload $ZIP_PATH and $DMG_PATH to GitHub Releases."
