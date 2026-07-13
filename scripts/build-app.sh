#!/bin/zsh
# Builds SnipKey.app into dist/ and optionally installs it to /Applications.
# Usage: scripts/build-app.sh [--install]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DIST="$ROOT/dist"
APP="$DIST/SnipKey.app"

echo "▸ Building release binary…"
swift build -c release

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/SnipKey" "$APP/Contents/MacOS/SnipKey"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"

if [[ ! -f "$DIST/AppIcon.icns" ]]; then
  echo "▸ Generating app icon…"
  swift "$ROOT/scripts/make-icon.swift" "$DIST"
fi
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Code signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "▸ Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installing to /Applications…"
  # Quit a running copy first so the binary can be replaced.
  osascript -e 'tell application "SnipKey" to quit' 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/SnipKey.app"
  cp -R "$APP" "/Applications/SnipKey.app"
  echo "▸ Installed: /Applications/SnipKey.app"
fi
