#!/bin/zsh
# Packages build/Wheel.app into build/Wheel-<version>.dmg: a styled drag-to-Applications window
# (background from scripts/make-dmg-background.swift) with Wheel's icon on the disk.
#   scripts/make-dmg.sh
# Optional notarization (needs a Developer ID build, see build-app.sh):
#   xcrun notarytool store-credentials wheel-notary   # once; saves credentials in your keychain
#   NOTARY_PROFILE=wheel-notary DEVELOPER_ID="Developer ID Application: …" scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
scripts/privacy-check.sh

APP=build/Wheel.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Wheel-$VERSION.dmg"
VOLNAME="Wheel"
STAGE="$(mktemp -d)"
RW="$(mktemp -d)/Wheel-rw.dmg"
# Mount at the standard /Volumes/Wheel: Finder records this path in the layout, so it must be
# the same path downloaders get, and never a folder inside your home directory.
MOUNT="/Volumes/$VOLNAME"
cleanup() {
  hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
  rm -rf "$STAGE" "$(dirname "$RW")"
}
trap cleanup EXIT

# Contents: the app, a shortcut to Applications, the background art and the disk icon.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
# Strip extended attributes (Finder tags, quarantine, "where from") so nothing about this Mac ships.
xattr -cr "$STAGE"

# A writable image first, so Finder can store the window layout in it.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
if [[ -e "$MOUNT" ]]; then
  echo "error: $MOUNT is already in use. Eject the other Wheel disk and try again." >&2
  exit 1
fi
hdiutil attach "$RW" -noautoopen -quiet
[[ -d "$MOUNT" ]] || { echo "error: image didn't mount at $MOUNT" >&2; exit 1; }

# Window layout (must match scripts/make-dmg-background.swift): 660×440, icons 112 pt.
if osascript <<OSA
tell application "Finder"
  set dmg to (POSIX file "$MOUNT" as alias)
  open dmg
  set w to container window of dmg
  set current view of w to icon view
  set toolbar visible of w to false
  set statusbar visible of w to false
  set pathbar visible of w to false
  set bounds of w to {200, 120, 860, 560}
  set opts to icon view options of w
  set arrangement of opts to not arranged
  set icon size of opts to 112
  set text size of opts to 13
  set background picture of opts to file ".background:background.tiff" of dmg
  set position of item "Wheel.app" of dmg to {170, 205}
  set position of item "Applications" of dmg to {490, 205}
  -- Support files sit outside the window, for people who show hidden files.
  set position of item ".background" of dmg to {900, 120}
  set position of item ".VolumeIcon.icns" of dmg to {900, 300}
  close w
  open dmg
  delay 1
  close container window of dmg
end tell
OSA
then
  echo "Installer window styled."
else
  echo "warning: Finder couldn't be scripted (allow your terminal under Privacy & Security → Automation). Using the plain layout." >&2
fi

# Custom disk icon, hide the support files, and make sure Finder's layout is written out.
SETFILE="$(xcrun -f SetFile 2>/dev/null || true)"
if [[ -n "$SETFILE" ]]; then
  "$SETFILE" -a C "$MOUNT"
  "$SETFILE" -a V "$MOUNT/.background" "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
fi
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true
sync
# The layout file must not mention this Mac's user or home folder.
if [[ -f "$MOUNT/.DS_Store" ]] && grep -a -q -e "$HOME" -e "/Users/$(id -un)" "$MOUNT/.DS_Store"; then
  echo "error: the installer layout recorded a path from your home folder; refusing to ship it." >&2
  exit 1
fi
hdiutil detach "$MOUNT" -quiet

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Created $DMG"
