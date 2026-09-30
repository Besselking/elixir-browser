#!/usr/bin/env bash
# Builds "Elixir Browser.app" in ./dist (macOS). Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Elixir Browser"
APP="dist/$NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

MIX_ENV=prod mix release browser --overwrite --path "dist/release" >/dev/null

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
mv dist/release "$RES/release"

# icon
ICONSET="$(mktemp -d)/icon.iconset"; mkdir -p "$ICONSET"
swift scripts/make_icon.swift "$ICONSET/base.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>dev.local.elixir-browser</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict></plist>
PLIST

# exec (no fork) so the Dock/menu bar attribute the BEAM process to this bundle
cat > "$MACOS/launcher" <<'LAUNCH'
#!/bin/bash
DIR="$(cd "$(dirname "$0")/../Resources/release" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export RELEASE_DISTRIBUTION=none
exec "$DIR/bin/browser" start
LAUNCH
chmod +x "$MACOS/launcher"

echo "Built $APP"
