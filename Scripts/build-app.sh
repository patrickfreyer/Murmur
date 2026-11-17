#!/bin/zsh
# Builds Murmur.app. Usage: Scripts/build-app.sh [debug|release] [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
APP=build/Murmur.app

swift build -c "$CONFIG" --product Murmur
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Murmur" "$APP/Contents/MacOS/Murmur"
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
IDENTITY=${MURMUR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Murmur Dev/{print $2; exit}')}
codesign --force --options runtime --entitlements Resources/Murmur.entitlements -s "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"

if [[ "${2:-}" == "--install" ]]; then
  pkill -x Murmur || true
  rm -rf /Applications/Murmur.app
  cp -R "$APP" /Applications/Murmur.app
  echo "Installed to /Applications/Murmur.app"
fi
