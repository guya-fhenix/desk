# Fhenix Desk

A macOS menu bar app that tracks the Fhenix development cycle (Jira tickets, pull requests, reviews and Claude Code
sessions) and carries your own work from a ticket to its merge. How it works: [docs/GUIDE.md](docs/GUIDE.md).

## Install

1. Download `FhenixDesk-<version>.dmg` from [Releases](https://github.com/guya-fhenix/desk/releases) and drag
   **Fhenix Desk** onto Applications.
2. The app is not notarized. The first time you open it, go to System Settings → Privacy & Security and press
   **Open Anyway**, or run `xattr -dr com.apple.quarantine "/Applications/Fhenix Desk.app"`.
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

## Release

The version is `CFBundleShortVersionString` in `Resources/Info.plist`; the build number is the commit count.

1. Raise the version in a PR and merge it.
2. On an up-to-date `main`, `make release` builds `build/FhenixDesk-<version>.dmg`, tags `v<version>` and publishes a
   GitHub release with the DMG attached. `make dmg` builds the DMG alone.
