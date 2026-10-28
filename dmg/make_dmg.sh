#!/bin/bash
# Builds the installer disk image: ./dmg/make_dmg.sh <Tack.app> <output.dmg> <app name> [footer note]
# A window with a background picture, the app on the left and the Applications folder on the right.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"; DMG="$2"; NAME="$3"; NOTE="${4:-}"
WORK="$(mktemp -d)"
RW="$WORK/rw.dmg"
MOUNT="/Volumes/$NAME"

# A leftover disk with this name would make the new one mount as "$NAME 1" and break the layout.
[ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true

swift dmg/background.swift "$WORK/background.png" "$NAME" "$NOTE"

hdiutil create -size 60m -fs HFS+ -volname "$NAME" -ov "$RW" >/dev/null
hdiutil attach "$RW" -noautoopen -mountpoint "$MOUNT" >/dev/null
trap 'hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

cp -R "$APP" "$MOUNT/"
ln -s /Applications "$MOUNT/Applications"
mkdir "$MOUNT/.background"
cp "$WORK/background.png" "$MOUNT/.background/background.png"
if [ -f "$APP/Contents/Resources/Tack.icns" ] && command -v SetFile >/dev/null; then
    cp "$APP/Contents/Resources/Tack.icns" "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT"
fi

# Lay the window out with Finder (it stores the layout in the disk's .DS_Store).
osascript <<OSA
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.png"
        set position of item "$(basename "$APP")" of container window to {180, 200}
        set position of item "Applications" of container window to {480, 200}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
OSA

sync
hdiutil detach "$MOUNT" >/dev/null
trap 'rm -rf "$WORK"' EXIT
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "Made $DMG"
