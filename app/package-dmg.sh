#!/usr/bin/env bash
#
# Package Tortoise.app into a distributable Tortoise.dmg (drag-to-Applications).
# Builds the app first (universal arm64 + x86_64), then wraps it in a compressed DMG.
#
#   ./package-dmg.sh
#
set -euo pipefail
cd "$(dirname "$0")"

APP="Tortoise.app"
DMG="Tortoise.dmg"
VOL="Tortoise"

[ "$(uname -s)" = "Darwin" ] || { echo "✗ macOS only." >&2; exit 1; }

echo "→ building the app…"
./build.sh >/dev/null
[ -d "$APP" ] || { echo "✗ build did not produce $APP" >&2; exit 1; }

echo "→ staging…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"      # drag-to-install target

echo "→ creating $DMG…"
rm -f "$DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 \
  -ov "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | cut -f1 | xargs)"
echo "✓ $(pwd)/$DMG  ($SIZE, universal: $(lipo -archs "$APP"/Contents/MacOS/*))"
echo
echo "  Share the .dmg. To install: open it → drag Tortoise into Applications."
echo "  It's ad-hoc signed (not notarized), so on another Mac the first open needs:"
echo "    right-click Tortoise → Open,  or  System Settings → Privacy & Security → Open Anyway."
