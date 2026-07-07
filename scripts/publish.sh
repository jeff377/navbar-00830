#!/usr/bin/env bash
# Builds NAV830.app — a self-contained, double-clickable macOS menu-bar app.
# Self-use: ad-hoc signed only, no notarization. See README for Gatekeeper notes.
#
# Usage:
#   scripts/publish.sh            # build dist/NAV830.app
#   scripts/publish.sh --install  # also copy to /Applications (recommended for login item)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="NAV830"
BUNDLE_ID="com.jeff.navbar00830"
VERSION="0.4.0"
OUT="$ROOT/dist"
APP="$OUT/$APP_NAME.app"

echo "▸ Release build…"
swift build -c release --product NAV830App
BIN="$(swift build -c release --product NAV830App --show-bin-path)/NAV830App"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

echo "▸ App icon…"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$OUT/icon-1024.png" >/dev/null
for size in 16 32 128 256 512; do
  sips -z "$size" "$size"            "$OUT/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png"    >/dev/null
  sips -z $((size*2)) $((size*2))    "$OUT/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>NAV830 費半淨值</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc code signing…"
# Ad-hoc signing keeps SMAppService (login item) and window-server access happy on Apple Silicon.
codesign --force --deep --sign - "$APP"

rm -f "$OUT/icon-1024.png"; rm -rf "$ICONSET"
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/$APP_NAME.app"
  echo "▸ Installing to $DEST…"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "✓ Installed. Launch it from /Applications (login item needs this stable location)."
else
  echo "  Next: move $APP to /Applications, then double-click. (Login item works best from /Applications.)"
fi
