#!/bin/sh
# Builds build/Sluggish.app. macOS ties permissions such as Automation to the app bundle, so run the menu bar app from it.
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
mkdir -p build/Sluggish.app/Contents/MacOS
cp .build/release/Sluggish build/Sluggish.app/Contents/MacOS/Sluggish
cp Info.plist build/Sluggish.app/Contents/Info.plist
mkdir -p build/Sluggish.app/Contents/Resources
cp AppIcon.icns build/Sluggish.app/Contents/Resources/AppIcon.icns
# ponytail: ad-hoc signature works only on this Mac; shipping needs Developer ID signing and notarization
codesign --force --sign - build/Sluggish.app
