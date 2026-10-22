#!/bin/zsh
# Builds build/Wheel.app.
#   scripts/build-app.sh            release, universal (Apple Silicon + Intel)
#   scripts/build-app.sh debug      debug, this Mac's architecture only
#
# Signing: ad-hoc by default (free, anonymous). To sign for distribution set
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
# The identity lives in your keychain; nothing secret is stored in this repo.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG="${1:-release}"
if [[ -d /Applications/Xcode.app && "$(xcode-select -p)" == *CommandLineTools* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Strip this machine's folder paths from the binary (they would reveal your username).
FLAGS=(-c "$CONFIG" --product Wheel -Xswiftc -file-prefix-map -Xswiftc "$ROOT=.")
if [[ "$CONFIG" == release ]]; then
  FLAGS+=(--arch arm64 --arch x86_64)
fi

swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/Wheel"

APP=build/Wheel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wheel"
if [[ "$CONFIG" == release ]]; then
  # Drop debug symbols: they list the absolute paths of every source and object file.
  strip -S -x "$APP/Contents/MacOS/Wheel"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Version from a git tag on this exact commit (v1.2.3), else Info.plist's value.
if VERSION="$(git describe --tags --exact-match 2>/dev/null)"; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP/Contents/Info.plist"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Wheel"))"
