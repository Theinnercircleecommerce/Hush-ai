#!/bin/bash
set -e

# Build the app using our existing script
echo "Step 1: Building App..."
./build.sh

# Get version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

echo "Step 2: Creating DMG..."
DMG_NAME="Hush-${VERSION}.dmg"
rm -f "$DMG_NAME"
npx -y create-dmg --overwrite --no-code-sign Hush.app
mv "Hush $VERSION.dmg" "$DMG_NAME"

echo "Step 3: Generating Appcast XML for Sparkle..."
mkdir -p release_files
cp "$DMG_NAME" release_files/
./tools/bin/generate_appcast release_files/

echo "-----------------------------------"
echo "RELEASE READY!"
echo "1. Upload the '$DMG_NAME' inside 'release_files' to your website."
echo "2. Upload the 'appcast.xml' inside 'release_files' to your website."
echo "-----------------------------------"
