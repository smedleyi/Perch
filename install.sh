#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building Perch (release)..."
swift build -c release

BUNDLE="/Applications/Perch.app"

# Kill running instance if any
pkill -x Perch 2>/dev/null || true
sleep 0.5

echo "Installing to $BUNDLE..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp .build/release/Perch "$BUNDLE/Contents/MacOS/Perch"
chmod +x "$BUNDLE/Contents/MacOS/Perch"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

echo "Signing..."
codesign --force --deep --sign - \
  --identifier "com.isaac.perch" \
  "$BUNDLE"

echo "Done. Opening Perch..."
open "$BUNDLE"
