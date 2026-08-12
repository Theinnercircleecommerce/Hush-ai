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
# Default: the stable Apple Development identity, so macOS keeps the
# Accessibility/Screen Recording grants across rebuilds. Ad-hoc signing (-)
# changes the binary hash every build, which silently revokes them.
# release.sh overrides HUSH_SIGN_IDENTITY with the Developer ID cert and sets
# HUSH_RELEASE=1 to add the hardened runtime + entitlements + secure timestamp
# that notarization requires. Local builds are unchanged by that path.
SIGN_IDENTITY="${HUSH_SIGN_IDENTITY:-Apple Development: Joey Beeren (TXRHF667D4)}"

CODESIGN_OPTS=(--force --sign "$SIGN_IDENTITY")
if [ -n "$HUSH_RELEASE" ]; then
    CODESIGN_OPTS+=(--options runtime --timestamp)
fi

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    if [ -n "$HUSH_RELEASE" ]; then
        echo "ERROR: release build requires '$SIGN_IDENTITY' but it is not installed."
        exit 1
    fi
    echo "WARNING: '$SIGN_IDENTITY' not found (expired?). Falling back to ad-hoc;"
    echo "         Accessibility permission will need re-granting after this build."
    SIGN_IDENTITY="-"
    CODESIGN_OPTS=(--force --sign -)
fi

# Sign inside-out. --deep is deprecated by Apple and cannot apply the right
# entitlements to nested code; notarization rejects bundles signed that way.
SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    for nested in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app"
    do
        [ -e "$nested" ] && codesign "${CODESIGN_OPTS[@]}" "$nested"
    done
    codesign "${CODESIGN_OPTS[@]}" "$SPARKLE"
fi

# The app itself signs last, with the entitlements. Nested Sparkle code must
# NOT inherit them — it has no business holding a microphone entitlement.
if [ -n "$HUSH_RELEASE" ]; then
    codesign "${CODESIGN_OPTS[@]}" --entitlements Hush.entitlements "$APP_BUNDLE"
else
    codesign "${CODESIGN_OPTS[@]}" "$APP_BUNDLE"
fi

codesign --verify --strict --verbose=2 "$APP_BUNDLE"

echo "App bundle created successfully at $APP_BUNDLE!"

# /Applications/Hush.app is owned by Sparkle — the in-app update button is the
# only thing that should replace it. Opt in with HUSH_INSTALL=1 when you
# deliberately want to test a local build in place.
if [ "$HUSH_INSTALL" = "1" ] && [ -d "/Applications/Hush.app" ]; then
    echo "HUSH_INSTALL=1 — overwriting /Applications/Hush.app with this local build..."
    rm -rf /Applications/Hush.app
    ditto "$APP_BUNDLE" /Applications/Hush.app
fi
