#!/bin/sh
# Builds build/Sluggish.app. macOS ties permissions such as Automation to the app bundle, so run the menu bar app from it.
# With SIGN_ID set to a "Developer ID Application" identity, it also notarizes and staples build/Sluggish.zip.
# notarytool reads a keychain profile that you make once: xcrun notarytool store-credentials sluggish
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
mkdir -p build/Sluggish.app/Contents/MacOS build/Sluggish.app/Contents/Resources
cp .build/release/Sluggish build/Sluggish.app/Contents/MacOS/Sluggish
cp Info.plist build/Sluggish.app/Contents/Info.plist
cp AppIcon.icns build/Sluggish.app/Contents/Resources/AppIcon.icns
if [ -z "$SIGN_ID" ]; then
    codesign --force --sign - build/Sluggish.app
    exit 0
fi
codesign --force --options runtime --timestamp --entitlements Sluggish.entitlements --sign "$SIGN_ID" build/Sluggish.app
ditto -c -k --keepParent build/Sluggish.app build/Sluggish.zip
xcrun notarytool submit build/Sluggish.zip --keychain-profile sluggish --wait
xcrun stapler staple build/Sluggish.app
ditto -c -k --keepParent build/Sluggish.app build/Sluggish.zip
