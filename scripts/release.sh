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

scripts/dmg.sh
git tag -a "$TAG" -m "Fhenix Desk ${VERSION}"
git push origin "$TAG"
gh release create "$TAG" "build/FhenixDesk-${VERSION}.dmg" --title "Fhenix Desk ${VERSION}" --generate-notes
