#!/bin/bash
set -e

REPO_URL="https://github.com/smedleyi/Swoop.git"

# Running from a local checkout (e.g. `bash install.sh`) vs. piped via curl.
# BASH_SOURCE[0] is a real file path in the former case and empty or not a file in
# the latter, so the -f check naturally distinguishes them.
if [ -f "${BASH_SOURCE[0]}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/Package.swift" ]; then
    cd "$(dirname "${BASH_SOURCE[0]}")"
else
    echo "Cloning Swoop..."
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT
    git clone --depth 1 "$REPO_URL" "$WORKDIR/Swoop"
    cd "$WORKDIR/Swoop"
fi

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
