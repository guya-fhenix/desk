#!/usr/bin/env bash
# Packs the .app into build/FhenixDesk-<version>.dmg, beside an Applications link to drag it onto. With NOTARY_PROFILE
# set to a keychain profile saved by `xcrun notarytool store-credentials`, it is notarized and the ticket stapled to it,
# so Gatekeeper opens it on any Mac, offline too.
set -euo pipefail
cd "$(dirname "$0")/.."

# Apple notarizes only a Developer ID build; said now rather than after the build and the upload.
if [[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID:-}" ]]; then
  echo "dmg: NOTARY_PROFILE needs DEVELOPER_ID; an ad-hoc build cannot be notarized" >&2
  exit 1
fi
scripts/bundle.sh
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
DMG="build/FhenixDesk-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "build/Fhenix Desk.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Fhenix Desk ${VERSION}" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "built: $DMG"
