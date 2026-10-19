#!/usr/bin/env bash
# Builds ShiftDrop.app into ./build.
#
#   ./scripts/build-app.sh            build for this Mac
#   ./scripts/build-app.sh --install  build, copy to /Applications and launch
#   UNIVERSAL=1 ./scripts/build-app.sh  Apple silicon + Intel (needs full Xcode)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
APP="build/ShiftDrop.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "› Compiling (release)…"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "› Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ShiftDrop" "$APP/Contents/MacOS/ShiftDrop"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "› Drawing the icon…"
rm -rf build/AppIcon.iconset
if swift scripts/make-icon.swift build/AppIcon.iconset >/dev/null \
  && iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"; then
  echo "  icon ok"
else
  echo "  (icon skipped)"
fi

echo "› Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP"

rm -f build/ShiftDrop.zip
(cd build && ditto -c -k --keepParent ShiftDrop.app ShiftDrop.zip)
echo "✓ Built ${ROOT}/${APP}"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ShiftDrop 2>/dev/null || true
  rm -rf /Applications/ShiftDrop.app
  cp -R "$APP" /Applications/
  open /Applications/ShiftDrop.app
  echo "✓ Installed to /Applications and launched — look for the wheel icon in the menu bar."
fi
