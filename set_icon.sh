#!/bin/bash
set -e

if [ ! -f "icon.png" ]; then
    echo "Error: icon.png not found. Please save the logo as icon.png in this folder."
    exit 1
fi

echo "Creating AppIcon.iconset..."
mkdir -p AppIcon.iconset

sips -z 16 16     icon_cropped.png --out AppIcon.iconset/icon_16x16.png
sips -z 32 32     icon_cropped.png --out AppIcon.iconset/icon_16x16@2x.png
sips -z 32 32     icon_cropped.png --out AppIcon.iconset/icon_32x32.png
sips -z 64 64     icon_cropped.png --out AppIcon.iconset/icon_32x32@2x.png
sips -z 128 128   icon_cropped.png --out AppIcon.iconset/icon_128x128.png
sips -z 256 256   icon_cropped.png --out AppIcon.iconset/icon_128x128@2x.png
sips -z 256 256   icon_cropped.png --out AppIcon.iconset/icon_256x256.png
sips -z 512 512   icon_cropped.png --out AppIcon.iconset/icon_256x256@2x.png
sips -z 512 512   icon_cropped.png --out AppIcon.iconset/icon_512x512.png
sips -z 1024 1024 icon_cropped.png --out AppIcon.iconset/icon_512x512@2x.png

echo "Generating AppIcon.icns..."
iconutil -c icns AppIcon.iconset

# Clean up
rm -rf AppIcon.iconset

echo "Updating Info.plist to use the icon..."
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" Info.plist || \
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" Info.plist

echo "Copying icon into the built app..."
cp AppIcon.icns Hush.app/Contents/Resources/

# Refresh macOS icon cache for this app
touch Hush.app
echo "Done! The logo has been applied to Hush.app."
