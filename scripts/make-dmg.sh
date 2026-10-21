#!/bin/zsh
# Packages build/Wheel.app into build/Wheel-<version>.dmg with a drag-to-Applications layout.
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
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg-readme.txt "$STAGE/If Wheel won't open.txt"
# Strip extended attributes (Finder tags, quarantine, "where from") so nothing about this Mac ships.
xattr -cr "$STAGE"

rm -f "$DMG"
hdiutil create -volname "Wheel $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Created $DMG"
