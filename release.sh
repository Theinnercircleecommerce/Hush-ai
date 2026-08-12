#!/bin/bash
set -e

# Distribution build: Developer ID signed, hardened runtime, notarized, stapled.
# Local development still uses ./build.sh directly, which keeps the Apple
# Development identity so Accessibility/Screen Recording grants survive.

NOTARY_PROFILE="${HUSH_NOTARY_PROFILE:-hush-notary}"

echo "Step 0: Checking distribution prerequisites..."

DEV_ID=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" \
    | head -1 \
    | sed -E 's/.*"(.+)".*/\1/')

if [ -z "$DEV_ID" ]; then
    cat <<'EOF'
ERROR: No "Developer ID Application" certificate found.

An "Apple Development" cert is for local testing only — apps signed with it are
rejected by Gatekeeper on every Mac but this one.

To create one:
  Xcode -> Settings -> Accounts -> (your Apple ID) -> Manage Certificates...
  -> "+" -> Developer ID Application
EOF
    exit 1
fi
echo "  Signing identity: $DEV_ID"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat <<EOF
ERROR: notarytool keychain profile "$NOTARY_PROFILE" is not set up.

Create an app-specific password at appleid.apple.com (Sign-In and Security ->
App-Specific Passwords), then run once:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "theinnercircleecommerce@gmail.com" \\
      --team-id "VDKD8N3UM8" \\
      --password "<app-specific-password>"
EOF
    exit 1
fi
echo "  Notary profile:   $NOTARY_PROFILE"

echo "Step 1: Building App (hardened runtime + entitlements)..."
HUSH_RELEASE=1 HUSH_SIGN_IDENTITY="$DEV_ID" ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

echo "Step 2: Creating DMG..."
DMG_NAME="Hush-${VERSION}.dmg"
rm -f "$DMG_NAME"
npx -y create-dmg --overwrite --no-code-sign Hush.app
mv "Hush $VERSION.dmg" "$DMG_NAME"

echo "Step 3: Signing DMG..."
codesign --force --sign "$DEV_ID" --timestamp "$DMG_NAME"

echo "Step 4: Notarizing (this uploads to Apple and usually takes 1-5 min)..."
xcrun notarytool submit "$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait

echo "Step 5: Stapling the notarization ticket..."
xcrun stapler staple "$DMG_NAME"

echo "Step 6: Verifying Gatekeeper acceptance..."
# This is the check that actually predicts what a stranger's Mac will do.
spctl -a -vvv -t install "$DMG_NAME"

echo "Step 7: Generating Appcast XML for Sparkle..."
mkdir -p release_files
cp "$DMG_NAME" release_files/
./tools/bin/generate_appcast release_files/

echo "-----------------------------------"
echo "RELEASE READY (signed + notarized + stapled)"
echo "1. Upload '$DMG_NAME' from 'release_files' to your website."
echo "2. Upload 'appcast.xml' from 'release_files' to your website."
echo "-----------------------------------"
