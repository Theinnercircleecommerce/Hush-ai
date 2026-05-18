#!/bin/bash
set -e

echo "Building Hush using Swift Package Manager..."
swift build -c release

echo "Creating Hush.app bundle..."
APP_BUNDLE="Hush.app"
rm -rf "$APP_BUNDLE"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp .build/release/Hush "$APP_BUNDLE/Contents/MacOS/"

if [ -d ".build/release/Sparkle.framework" ]; then
    cp -R ".build/release/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/"
fi

sed -e 's/$(EXECUTABLE_NAME)/Hush/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.hush.app/g' \
    -e 's/$(PRODUCT_NAME)/Hush/g' \
    Info.plist > "$APP_BUNDLE/Contents/Info.plist"

if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
fi

# Copy any generated resource bundles so custom assets load correctly
if ls .build/release/*.bundle 1> /dev/null 2>&1; then
    cp -R .build/release/*.bundle "$APP_BUNDLE/Contents/Resources/"
fi

# Fix rpath so it knows to look in the Frameworks directory!
install_name_tool -add_rpath @executable_path/../Frameworks "$APP_BUNDLE/Contents/MacOS/Hush"

echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "Signing the application..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "App bundle created successfully at $APP_BUNDLE!"
