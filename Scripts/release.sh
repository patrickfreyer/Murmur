#!/bin/zsh
# Builds a release zip for GitHub: Scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
Scripts/build-app.sh release
mkdir -p dist
ZIP="dist/Murmur-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Murmur.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Release artifact: $ZIP"
