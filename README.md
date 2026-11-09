# Fhenix Desk

A macOS menu bar app that tracks the Fhenix development cycle (Jira tickets, pull requests, reviews and Claude Code
sessions) and carries your own work from a ticket to its merge. How it works: [docs/GUIDE.md](docs/GUIDE.md).

## Install

1. Download `FhenixDesk-<version>.dmg` from [Releases](https://github.com/guya-fhenix/desk/releases) and drag
   **Fhenix Desk** onto Applications.
2. A notarized release opens normally. If macOS says it cannot check the app for malicious software, that release is
   an ad-hoc build: run `xattr -dr com.apple.quarantine "/Applications/Fhenix Desk.app"` once, then open it.
3. On first launch, Setup checks the tools Desk drives (git, `gh`, `acli`, Claude Code and the `fhenix-workflow`
   plugin), installs what is missing, signs you in and walks the settings it needs. Settings → General runs it again.

Needs macOS 15 on Apple Silicon.

## Develop

```sh
make run      # run from the build tree
make test
make doctor   # print every data source, setup checks included, as text
make install  # build the .app into ~/Applications and open it
```

To check a view without driving the window, a debug build draws a PR's page, or its review diff at its first thread,
with live data into a PNG: `.build/debug/FhenixDesk --snapshot <pr url> <out.png> [page|diff] [height] [dark|light]`.

## Release

The version is `CFBundleShortVersionString` in `Resources/Info.plist`; the build number is the commit count.

1. Raise the version in a PR and merge it.
2. On an up-to-date `main`, `make release` builds `build/FhenixDesk-<version>.dmg`, tags `v<version>` and publishes a
   GitHub release with the DMG attached. `make dmg` builds the DMG alone.

Signing and notarizing are opt-in, through three variables:

- `DEVELOPER_ID`: your signing identity, `Developer ID Application: <name> (<team id>)`, as
  `security find-identity -v -p codesigning` lists it. The app is signed with it, the hardened runtime and a
  timestamp. Without it the build is ad-hoc signed, and says so.
- `NOTARY_PROFILE`: a keychain profile for `notarytool`. The DMG is submitted to Apple, and the ticket is stapled to it
  once Apple accepts it. Needs `DEVELOPER_ID`. Save the profile once, with an app-specific password from
  [account.apple.com](https://account.apple.com):
  `xcrun notarytool store-credentials fhenix-desk --apple-id <you@example.com> --team-id <team id>`.
- `ALLOW_ADHOC=1`: lets `make release` publish an ad-hoc build. It refuses one otherwise, since Gatekeeper blocks it
  on every Mac that downloads it.

```sh
DEVELOPER_ID="Developer ID Application: …" NOTARY_PROFILE=fhenix-desk make release
```
