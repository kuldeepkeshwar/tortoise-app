#!/usr/bin/env bash
#
# Build Tortoise.app — a self-contained macOS menu-bar front-end for the tortoise CLI.
# Embeds a copy of ../tortoise.sh and ../README.md so the .app is portable on its own.
#
#   ./build.sh            # build ./Tortoise.app
#   ./build.sh /Applications   # build and install into /Applications
#
set -euo pipefail
cd "$(dirname "$0")"

APP="Tortoise.app"
EXEC="Tortoise"
BUNDLE_ID="io.github.kuldeepkeshwar.tortoise"
CLI="../tortoise.sh"
README="../README.md"

[ "$(uname -s)" = "Darwin" ] || { echo "✗ macOS only." >&2; exit 1; }
command -v swiftc >/dev/null || { echo "✗ swiftc not found (install Xcode Command Line Tools)." >&2; exit 1; }
[ -f "$CLI" ] || { echo "✗ can't find $CLI" >&2; exit 1; }

echo "→ compiling TortoiseBar.swift (universal: arm64 + x86_64)…"
rm -rf "$APP" "$EXEC" "$EXEC.arm64" "$EXEC.x86_64"
slices=()
if swiftc -O -target arm64-apple-macosx12.0  -framework AppKit -o "$EXEC.arm64"  TortoiseBar.swift 2>/dev/null; then
  slices+=("$EXEC.arm64")
fi
if swiftc -O -target x86_64-apple-macosx12.0 -framework AppKit -o "$EXEC.x86_64" TortoiseBar.swift 2>/dev/null; then
  slices+=("$EXEC.x86_64")
fi
[ "${#slices[@]}" -ge 1 ] || { echo "✗ compile failed for all architectures." >&2; exit 1; }
lipo -create "${slices[@]}" -output "$EXEC"
rm -f "$EXEC.arm64" "$EXEC.x86_64"
echo "  built: $(lipo -archs "$EXEC")"

echo "→ assembling $APP…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$EXEC" "$APP/Contents/MacOS/$EXEC"
install -m 0755 "$CLI" "$APP/Contents/Resources/tortoise.sh"
cp "$README" "$APP/Contents/Resources/README.md"

# app icon matching the menu-bar glyph (best-effort)
ICON_KEY=""
if swiftc -O -framework AppKit -o make-icon make-icon.swift 2>/dev/null; then
  rm -rf AppIcon.iconset && mkdir -p AppIcon.iconset
  if ./make-icon AppIcon.iconset 2>/dev/null && iconutil -c icns AppIcon.iconset -o AppIcon.icns 2>/dev/null; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
    echo "  app icon: generated"
  else
    echo "  (app icon generation skipped)"
  fi
  rm -rf make-icon AppIcon.iconset AppIcon.icns
else
  echo "  (app icon generation skipped)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tortoise</string>
  <key>CFBundleDisplayName</key><string>Tortoise</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
$ICON_KEY
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST

# ad-hoc sign so Gatekeeper lets a locally-built app run without "damaged" warnings
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc codesign skipped)"

echo "✓ built $(pwd)/$APP"

if [ "${1:-}" = "/Applications" ]; then
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "✓ installed /Applications/$APP — open it from Spotlight or: open /Applications/$APP"
else
  echo "  run it with:  open ./$APP      (or move it to /Applications)"
fi
