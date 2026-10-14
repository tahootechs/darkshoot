#!/bin/sh
# Builds build/Screenshoot.app (ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Screenshoot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Screenshoot "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
# Sign with a real certificate so macOS keeps Screen Recording/Keychain access across rebuilds.
# Ad-hoc ("-") ties permissions to the binary hash, which changes on every build.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  echo "warning: no signing certificate found, using ad-hoc; permissions reset on every build" >&2
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
