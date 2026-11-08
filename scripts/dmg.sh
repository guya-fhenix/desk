#!/usr/bin/env bash
# Packs the .app into build/FhenixDesk-<version>.dmg, beside an Applications link to drag it onto.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
DMG="build/FhenixDesk-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "build/Fhenix Desk.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Fhenix Desk ${VERSION}" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
echo "built: $DMG"
