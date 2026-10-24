# AGENTS.md

Notes for coding agents working on UltimateFinder, a TotalFinder-style visor for macOS: a menu-bar agent (Swift + AppKit, UI built entirely in code) that slides a Finder-like browser down from the top of the screen on ⌥Space. See [README.md](README.md) for features and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the file layout and release process. The project is public on GitHub at [mzogot/UltimateFinder](https://github.com/mzogot/UltimateFinder) (MIT).

## Build, run, install

```sh
./build.sh            # build/UltimateFinder.app (release, signed)
./build.sh run        # build and (re)launch the build/ copy
./build.sh install    # build, copy to /Applications, launch
swift build           # compile only, fastest check
```

- SwiftPM only, no Xcode project. Command Line Tools are enough. Target macOS 13+, built against the macOS 27 SDK.
- One dependency: [libwebp-Xcode](https://github.com/SDWebImage/libwebp-Xcode) (pinned, statically linked) to write WebP, which ImageIO only reads. The first build after a clean needs network access to fetch it.
- The user runs the copy in **/Applications**, so finish a change with `./build.sh install` and say so.
- There are no automated tests. Verify with `swift build` (no warnings) and by exercising the change in the running app.

## Signing

`build.sh` signs with `$SIGN_IDENTITY`, else the first *Developer ID Application* / *Apple Development* identity in the keychain (currently `Developer ID Application: Michael Zogot (854T64H39D)`), else ad-hoc. It uses the hardened runtime; dev builds skip the secure timestamp. `TIMESTAMP=1` adds it and `UNIVERSAL=1` builds arm64 + x86_64. Keep the real identity: an ad-hoc build loses the user's privacy grants on every rebuild. Check with `codesign -dvv build/UltimateFinder.app`.

## Versioning and changelog (required for every change)

- `VERSION` is the single source of truth. `build.sh` stamps it into `CFBundleShortVersionString` and `CFBundleVersion`; don't edit those in `Resources/Info.plist` by hand.
- For every fix or feature, add a user-facing entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) (Added / Changed / Fixed / Removed), then run:
  - `scripts/bump-version.sh patch` for fixes,
  - `scripts/bump-version.sh minor` for new features,
  - `scripts/bump-version.sh major` for breaking changes,
  and rebuild. One bump per round of work, not per file edit.
- Update README.md when behaviour or shortcuts change, and docs/DEVELOPMENT.md when the file layout changes.
- Commit each round of work to git. Publish a version with `scripts/release.sh` (universal build → notarize + staple the app → DMG → notarize → staple → tag → push → GitHub release, notes taken from the changelog). Notarization credentials are in the keychain profile `ultimatefinder` (`xcrun notarytool store-credentials`), never on the command line. Only release when the user asks.
- README screenshots in `docs/images/` were captured from a demo folder (`/Users/Shared/Studio`) with the user's defaults backed up and restored; never capture the user's real files or sidebar.

## Code conventions

- Match the surrounding code: `final class`, `private` by default, `// MARK:` sections, short `///` doc comments that explain *why*. Comment density is low.
- Behaviour should match Finder's unless the user asks otherwise (shortcuts, drag rules, selection, tabs, history).
- Settings live in `Settings.swift` (UserDefaults). Tabs, favorites, sort order and view mode persist, so **don't leave test state behind**: an earlier test run overwrote the user's open tabs. Back up `defaults export com.ultimatefinder.visor` before experiments and restore it afterwards.
- `Resources/AppIcon.icns` is generated from `Resources/AppIcon.png` (1024×1024); see "App icon" below.

## AppKit gotchas (macOS 27 SDK)

- NSBrowser draws rows with `NSTextFieldCell` and ignores `cellClass` / `cellPrototype`; row icons are text attachments in the title.
- NSBrowser sends Objective-C messages like `-isEqualTo:` to items, so `FileNode` must subclass `NSObject`.
- Returning false from `browser(_:canDragRowsWith:inColumn:with:)` / `canDragRows(with:at:)` turns a drag into range selection; both views use this to drag only from the icon and name.
- A local key monitor must return `nil` for handled keys; `self?.handle(event) ?? event` silently turns that `nil` back into the event.
- Finder's favorites are in `…com.apple.sharedfilelist/…FavoriteItems.sfl4`, which needs Full Disk Access; the import falls back to `sfltool archive`.
- The panel is non-activating and sits above normal windows, so alerts use `NSAlert.runAboveVisor()`.

## App icon

The icon was generated with GPT Image 2.5 Sunburst through the ElevenLabs creative MCP (flow `6It5tPqs9s0Htz5HhbrQ`, node `h2QAwH9zPxvFReRA6WLE`, variation 4 of 4: the "UF" monogram; the earlier visor-panel icon is variation 1 of the first node). The model paints a fake checkerboard or a plain white background instead of real transparency, so the tile is cut out and re-centred on Apple's 1024/824 grid before use:

```sh
swift scripts/cutout-icon.swift generated.png Resources/AppIcon.png   # remove checkerboard, centre, add shadow
scripts/make-icon.sh                                                  # AppIcon.png → AppIcon.icns
./build.sh install
```

Finder and the Dock cache icons. If the old icon sticks, run `touch /Applications/UltimateFinder.app && killall Dock`.

## User context

- German keyboard layout (⌘[ / ⌘] are ⌘Ü / ⌘+), Logitech mouse with Logi Options+ (back/forward arrive as buttons 4 / 5).
