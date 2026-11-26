#!/bin/zsh
# Builds a release zip for GitHub: Scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
# Public builds are ad-hoc signed: a personal development certificate adds no trust for other
# Macs (they still need "Open Anyway" until the app is notarized) and would embed your identity.
UNDERSAY_SIGN_IDENTITY=- Scripts/build-app.sh release
mkdir -p dist
ZIP="dist/Undersay-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Undersay.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Release artifact: $ZIP"
