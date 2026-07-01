#!/bin/bash
set -e

REPO_URL="https://github.com/smedleyi/Perch.git"

# Running from a local checkout (e.g. `bash install.sh`) vs. piped via curl.
# BASH_SOURCE[0] is a real file path in the former case and something like
# "bash" (not a file) in the latter, so the -f check naturally distinguishes them.
if [ -f "${BASH_SOURCE[0]}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/Package.swift" ]; then
    cd "$(dirname "${BASH_SOURCE[0]}")"
else
    echo "Cloning Perch..."
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT
    git clone --depth 1 "$REPO_URL" "$WORKDIR/Perch"
    cd "$WORKDIR/Perch"
fi

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
