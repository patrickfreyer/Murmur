#!/bin/zsh
# Builds Undersay.app. Usage: Scripts/build-app.sh [debug|release] [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
APP=build/Undersay.app

swift build -c "$CONFIG" --product Undersay
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Undersay" "$APP/Contents/MacOS/Undersay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundles (FluidAudio ships a few small ones)
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

# Icon (cached)
if [[ ! -f build/AppIcon.icns ]]; then
  mkdir -p build/AppIcon.iconset
  swift Scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity if one exists (keeps Accessibility permission across rebuilds),
# otherwise ad-hoc.
IDENTITY=${UNDERSAY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Undersay Dev/{print $2; exit}')}
codesign --force --options runtime --entitlements Resources/Undersay.entitlements -s "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"

if [[ "${2:-}" == "--install" ]]; then
  pkill -x Undersay || true
  rm -rf /Applications/Undersay.app
  cp -R "$APP" /Applications/Undersay.app
  echo "Installed to /Applications/Undersay.app"
fi
