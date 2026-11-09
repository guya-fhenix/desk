#!/usr/bin/env bash
# Publishes the version in Resources/Info.plist: tags main as v<version> and attaches the DMG to a GitHub release.
# Raise CFBundleShortVersionString in a PR first; this only ships what main already says.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
TAG="v${VERSION}"
fail() { echo "release: $*" >&2; exit 1; }

[[ "$(git branch --show-current)" == main ]] || fail "run it on main"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has changes"
git fetch --quiet --tags origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not at origin/main; pull or push first"
! git rev-parse --quiet --verify "refs/tags/${TAG}" >/dev/null || fail "${TAG} exists; raise CFBundleShortVersionString in Resources/Info.plist"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in; run gh auth login"
# Gatekeeper blocks an ad-hoc build on every Mac that downloads it, so publishing one takes asking for it.
[[ -n "${DEVELOPER_ID:-}" || "${ALLOW_ADHOC:-}" == 1 ]] ||
  fail "DEVELOPER_ID is not set, so the build would be ad-hoc signed; set it (and NOTARY_PROFILE), or ALLOW_ADHOC=1"
swift test || fail "the tests fail; fix them on main first"

scripts/dmg.sh
# gh makes the tag when it publishes the release, so a failed upload leaves no tag for the rerun to trip on.
gh release create "$TAG" "build/FhenixDesk-${VERSION}.dmg" --title "Fhenix Desk ${VERSION}" --generate-notes \
  --target "$(git rev-parse HEAD)"
