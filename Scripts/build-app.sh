#!/bin/bash
# Builds build/Daikin.app from the DaikinApp SwiftPM target.
#
#   Scripts/build-app.sh            release build
#   Scripts/build-app.sh debug      debug build (includes the snapshot aid)
#
# Set CODESIGN_IDENTITY to sign with a real identity; the default is ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP="build/Daikin.app"

swift build -c "$CONFIGURATION" --product DaikinApp
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/DaikinApp"

if [ ! -f Packaging/AppIcon.icns ]; then
    swift Scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Packaging/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Daikin"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "$APP"
