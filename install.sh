#!/bin/bash
set -e

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Building Swoop (release)..."
swift build -c release

BUNDLE="/Applications/Swoop.app"

# Kill running instance if any
pkill -x Swoop 2>/dev/null || true
sleep 0.5

echo "Installing to $BUNDLE..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp .build/release/Swoop "$BUNDLE/Contents/MacOS/Swoop"
chmod +x "$BUNDLE/Contents/MacOS/Swoop"
cp .build/release/SwoopWatchdog "$BUNDLE/Contents/MacOS/SwoopWatchdog"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

# A stable local certificate keeps macOS permissions across rebuilds. Macs without
# it, such as anyone else installing this, fall back to ad-hoc signing.
SIGN_AS="-"
if security find-identity -p codesigning | grep -q "Isaac Local Signing"; then
    SIGN_AS="Isaac Local Signing"
fi
echo "Signing..."
codesign --force --deep --sign "$SIGN_AS" \
  --identifier "com.isaac.swoop" \
  "$BUNDLE"

echo "Done. Opening Swoop..."
open "$BUNDLE"
