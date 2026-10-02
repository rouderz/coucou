#!/usr/bin/env bash
# Builds Coucou (Release) and packages it as a drag-to-Applications DMG.
#
# Usage: bash scripts/make-dmg.sh [version]        e.g. bash scripts/make-dmg.sh 0.2.0
#
# Signing:
#   - With a "Developer ID Application" certificate in the keychain: signed with it, and notarized
#     too if NOTARY_PROFILE is set (xcrun notarytool store-credentials <profile>). Opens anywhere.
#   - Without one: ad-hoc signed. Runs on this Mac; on other Macs the first launch needs
#     right-click → Open (or System Settings → Privacy & Security → Open Anyway).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/NotchBuddy"
VERSION="${1:-$(awk -F'"' '/CFBundleShortVersionString/ {print $2; exit}' project.yml)}"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
OUT="$ROOT/dist"
WORK="$(mktemp -d /tmp/coucou-dmg.XXXXXX)"
APP="$WORK/build/Coucou.app"
DMG="$OUT/Coucou-$VERSION.dmg"

if [ -n "$(git -C "$ROOT" status --porcelain -- NotchBuddy)" ]; then
  echo "⚠️  Uncommitted changes in NotchBuddy/ will be included in this build."
fi
echo "▸ Coucou $VERSION (build $BUILD, $COMMIT)"

# ── 1. Release build, unsigned (signed below, after the version is stamped) ──
xcodegen generate >/dev/null
xcodebuild -project NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Release \
  CONFIGURATION_BUILD_DIR="$WORK/build" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[ -d "$APP" ] || { echo "✗ Build failed"; exit 1; }

# ── 2. Version ──
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# ── 3. Sign ──
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 \
           | sed 's/.*"\(Developer ID Application[^"]*\)".*/\1/' || true)
if [ -n "$IDENTITY" ]; then
  echo "▸ Signing with $IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Coucou.entitlements --sign "$IDENTITY" "$APP"
else
  echo "▸ No Developer ID certificate: ad-hoc signature"
  codesign --force --options runtime \
    --entitlements Resources/Coucou.entitlements --sign - "$APP"
fi
codesign --verify --strict "$APP"

# ── 4. DMG: Coucou.app + a shortcut to /Applications ──
mkdir -p "$WORK/dmg" "$OUT"
cp -R "$APP" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
rm -f "$DMG"
hdiutil create -volname "Coucou $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ -n "$IDENTITY" ]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▸ Notarizing (a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

# The app as a zip too: what the self-update downloads (signed by the release workflow).
ZIP="$OUT/Coucou-$VERSION.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

rm -rf "$WORK"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
echo "✓ $ZIP (self-update)"
