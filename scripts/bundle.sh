#!/usr/bin/env bash
# Builds a release binary and wraps it in a signed .app bundle: with your Developer ID when DEVELOPER_ID names it
# ("Developer ID Application: <name> (<team id>)"), ad-hoc otherwise.
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
# The build number is the commit count, so every build of a version is told apart without editing the source plist.
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# Notarization needs the hardened runtime and a secure timestamp. The runtime asks for no entitlements here: the app
# only starts processes (gh, git, acli, claude, zsh) and a pty for the terminal, and loads no code at run time.
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  echo "built: $APP (signed by $DEVELOPER_ID)"
else
  codesign --force --sign - "$APP"
  echo "built: $APP (ad-hoc signed: Gatekeeper blocks it on other Macs; set DEVELOPER_ID to sign it)"
fi
