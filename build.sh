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
# Sign with the stable Apple Development identity so macOS keeps the
# Accessibility/Screen Recording grants across rebuilds. Ad-hoc signing (-)
# changes the binary hash every build, which silently revokes them.
SIGN_IDENTITY="Apple Development: Joey Beeren (TXRHF667D4)"
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "WARNING: '$SIGN_IDENTITY' not found (expired?). Falling back to ad-hoc;"
    echo "         Accessibility permission will need re-granting after this build."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "App bundle created successfully at $APP_BUNDLE!"

# Keep the installed copy in sync — the Dock/Launchpad icon points at
# /Applications/Hush.app, and a stale copy there means testing old code.
if [ -d "/Applications/Hush.app" ]; then
    echo "Updating /Applications/Hush.app..."
    rm -rf /Applications/Hush.app
    ditto "$APP_BUNDLE" /Applications/Hush.app
fi
