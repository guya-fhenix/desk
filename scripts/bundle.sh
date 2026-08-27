#!/usr/bin/env bash
# Builds a release binary and wraps it in an ad-hoc signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Fhenix Desk"
APP="build/${APP_NAME}.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FhenixDesk"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FhenixDesk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
echo "built: $APP"
