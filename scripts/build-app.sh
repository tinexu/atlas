#!/usr/bin/env bash
# Builds ATLAS.app from the Swift package so macOS treats it as a real app
# (needed for notifications and for stable permission grants).
#
#   ./scripts/build-app.sh            # release build into ./build/ATLAS.app
#   ./scripts/build-app.sh debug      # debug build
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ATLAS.app"
BUNDLE_ID="app.atlas.ATLAS"

cd "$ROOT"
swift build -c "$CONFIG" --product ATLAS
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ATLAS" "$APP/Contents/MacOS/ATLAS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>              <string>ATLAS</string>
    <key>CFBundleDisplayName</key>       <string>ATLAS</string>
    <key>CFBundleExecutable</key>        <string>ATLAS</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>ATLAS sends commands to apps you include in your automations, such as telling Terminal which folder to open.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS remembers permissions between launches.
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $APP"
echo "Run it with: open \"$APP\""
