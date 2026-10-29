#!/usr/bin/env bash
# Builds ATLAS.app from the Swift package so macOS treats it as a real app
# (needed for notifications and for stable permission grants).
#
#   ./scripts/build-app.sh                  # release build into ./build/ATLAS.app
#   ./scripts/build-app.sh debug            # debug build (adds the Debug menu)
#   ./scripts/build-app.sh --install        # release build, installed to /Applications/ATLAS.app
#   ./scripts/build-app.sh debug --install
#
# Signing: uses your "Apple Development" certificate if Xcode has made one
# (macOS then keeps Accessibility, Calendar and folder permissions across
# rebuilds); otherwise an ad-hoc signature. Override with SIGN_IDENTITY=...
set -euo pipefail

CONFIG="release"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --install) INSTALL=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done
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
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>ATLAS shows your calendar events on the Time Architect timeline and suggests the right Space before they start. It only changes a calendar if you allow writing to it.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>ATLAS shows your calendar events on the Time Architect timeline.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>ATLAS reads the Reminders list you choose for the Study Library's assignments, and marks a reminder complete when you check it off in the room. It never changes anything else.</string>
    <key>NSRemindersUsageDescription</key>
    <string>ATLAS reads the Reminders list you choose as assignments for the Study Library.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>ATLAS sends commands to apps you include in your automations, such as telling Terminal which folder to open, and reads the address of your browser's current tab when you save a video to a creative project.</string>
</dict>
</plist>
PLIST

# A stable signature lets macOS remember permissions between builds.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null
    echo "Signed with: $IDENTITY"
else
    codesign --force --deep --sign - "$APP" >/dev/null
    echo "Signed ad hoc (no Apple Development certificate found). If macOS forgets permissions after a rebuild,"
    echo "open Xcode → Settings → Accounts, add your Apple ID and create an Apple Development certificate."
fi

echo "Built $APP"
if [ "$INSTALL" = 1 ]; then
    TARGET="/Applications/ATLAS.app"
    if pgrep -f "$TARGET/Contents/MacOS/ATLAS" >/dev/null; then
        echo "Quitting the running ATLAS…"
        osascript -e "tell application id \"${BUNDLE_ID}\" to quit" || true
        for _ in $(seq 1 20); do pgrep -f "$TARGET/Contents/MacOS/ATLAS" >/dev/null || break; sleep 0.5; done
    fi
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    echo "Installed $TARGET"
    echo "Run it with: open \"$TARGET\"  (turn on Start ATLAS at Login from the menu bar)"
else
    echo "Run it with: open \"$APP\""
fi
