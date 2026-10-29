#!/bin/sh
# Builds build/whyslow.app. macOS ties permissions such as Automation to the app bundle, so run the menu bar app from it.
set -e
cd "$(dirname "$0")"
swift build -c release
mkdir -p build/whyslow.app/Contents/MacOS
cp .build/release/whyslow build/whyslow.app/Contents/MacOS/whyslow
cp Info.plist build/whyslow.app/Contents/Info.plist
mkdir -p build/whyslow.app/Contents/Resources
cp AppIcon.icns build/whyslow.app/Contents/Resources/AppIcon.icns
# ponytail: ad-hoc signature works only on this Mac; shipping needs Developer ID signing and notarization
codesign --force --sign - build/whyslow.app
