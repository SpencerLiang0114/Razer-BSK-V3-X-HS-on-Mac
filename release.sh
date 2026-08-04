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
# Strip AppleDouble sidecars again before re-signing. build.sh already did
# this before *its* signature, but signing writes new files into the bundle
# and on a non-native volume (exFAT / NTFS / SMB) each one immediately gets
# a fresh `._<name>` twin. codesign then walks the bundle, finds
# `Contents/MacOS/._BSKV3XHS`, and aborts with "Operation not permitted" —
# which under `set -e` killed the release before any artifact was written.
strip_sidecars() {
    if command -v dot_clean >/dev/null 2>&1; then
        dot_clean -m "$1" 2>/dev/null || true
    fi
    find "$1" -name '._*' -delete 2>/dev/null || true
}
strip_sidecars "$BUILT_APP"
/usr/bin/codesign --remove-signature "$BUILT_APP" 2>/dev/null || true
strip_sidecars "$BUILT_APP"
/usr/bin/codesign --force --deep --sign - "$BUILT_APP"
# Verify the ad-hoc signature took. A release binary that fails Gatekeeper's
# basic integrity check reads to users as "app is damaged", so this must be
# fatal rather than something they discover after downloading.
if ! /usr/bin/codesign --verify --deep --strict "$BUILT_APP"; then
    echo "✗ Ad-hoc re-sign failed verification — refusing to package." >&2
    exit 1
fi
# Confirm the personal identity is actually gone: an Apple Development cert
# embeds the developer's email, and the whole point of this step is to keep
# that out of a public download.
if /usr/bin/codesign -dvv "$BUILT_APP" 2>&1 | /usr/bin/grep -q '^Authority='; then
    echo "✗ Release binary still carries a certificate chain — not shipping it." >&2
    /usr/bin/codesign -dvv "$BUILT_APP" 2>&1 | /usr/bin/grep '^Authority=' >&2
    exit 1
fi
echo "→ Ad-hoc signature verified, no personal identity embedded"

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
rm -f "$DMG_PATH"

# Stage and build the DMG on a native (APFS) temp volume rather than in
# dist/. When the repo lives on exFAT/NTFS/SMB, macOS writes an AppleDouble
# `._<name>` sidecar beside every file it creates — including one for the
# /Applications symlink — and `hdiutil create -srcfolder` refuses the whole
# folder with "Operation not permitted". Stripping them doesn't help,
# because each new write regenerates them; staging off-volume avoids the
# problem entirely instead of racing it.
STAGE=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/bskv3xhs-dmg.XXXXXX")
TMP_DMG="$STAGE.dmg"
cleanup_stage() { rm -rf "$STAGE" "$TMP_DMG"; }
trap cleanup_stage EXIT

# Layout: .app + Applications symlink (drag-to-install convention).
echo "→ Staging DMG contents"
/usr/bin/ditto "build/${APP_NAME}.app" "$STAGE/${APP_NAME}.app"
/bin/ln -s /Applications "$STAGE/Applications"

echo "→ Creating $DMG_PATH"
# UDZO = compressed read-only, standard for release DMGs.
/usr/bin/hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$TMP_DMG" >/dev/null

# Move the finished image onto the repo volume. ditto rather than mv so the
# copy survives a cross-filesystem move cleanly.
/usr/bin/ditto "$TMP_DMG" "$DMG_PATH"
cleanup_stage
trap - EXIT

# ─── Report ───────────────────────────────────────────────────────
echo
echo "✓ Release artifacts:"
ls -lh "$DIST_DIR" | /usr/bin/awk 'NR>1 {print "    " $9 "  (" $5 ")"}'
echo
echo "Upload $ZIP_PATH and $DMG_PATH to GitHub Releases."
