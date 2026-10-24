# Development

UltimateFinder is a menu-bar agent (`LSUIElement`) written in Swift and AppKit. The whole UI is built in code; there is no Xcode project, storyboard or XIB.

## Build and run

```sh
./build.sh            # → build/UltimateFinder.app (release, signed)
./build.sh run        # build and (re)launch the build/ copy
./build.sh install    # build, copy to /Applications, launch
swift build           # compile only, fastest check
```

`swift run` also works for quick iteration. The app sets its accessory activation policy at runtime, so it behaves the same without the bundle. Launch at Login and the privacy prompts' purpose strings need the `.app` bundle.

Environment variables for `build.sh`:

| Variable | Effect |
|---|---|
| `SIGN_IDENTITY` | Signing identity. Default: the first *Developer ID Application* or *Apple Development* certificate in the keychain, else ad hoc (`-`). |
| `UNIVERSAL=1` | Build for `arm64` and `x86_64` (separate scratch paths under `.build/`) and merge them with `lipo`. |
| `TIMESTAMP=1` | Sign with Apple's secure timestamp, which notarization requires. Needs network access. |
| `CONFIG` | `release` (default) or `debug`. |

With a real certificate, macOS remembers the privacy grants (Desktop/Documents access, Accessibility) across rebuilds. With ad-hoc signing it asks again after every build. The first signing run may ask for keychain access to the certificate; choose *Always Allow*.

There are no automated tests. Verify with `swift build` (no warnings) and by exercising the change in the running app. Tabs, favorites, sort order and view mode persist in `com.ultimatefinder.visor`, so back up `defaults export com.ultimatefinder.visor backup.plist` before experiments and restore it afterwards.

## Versioning and releases

`VERSION` is the single source of truth; `build.sh` stamps it into `CFBundleShortVersionString` and `CFBundleVersion`.

1. Add user-facing entries under `## [Unreleased]` in [CHANGELOG.md](../CHANGELOG.md) (Added / Changed / Fixed / Removed / Security).
2. Run `scripts/bump-version.sh patch|minor|major`. It dates the Unreleased entries under the new version.
3. Commit (`release: x.y.z`).
4. Run `scripts/release.sh`. It:
   - builds a universal, timestamped app, notarizes it and staples its ticket, so it opens offline after being copied out of the DMG;
   - packs it into `build/UltimateFinder-x.y.z.dmg` with an Applications shortcut, and signs the DMG;
   - submits the DMG to Apple's notary service, waits, and staples the ticket;
   - tags `vx.y.z`, pushes, and creates the GitHub release with the changelog section as its notes. The DMG is attached twice: versioned, and as `UltimateFinder.dmg` for the README's permanent download link.

   `scripts/release.sh --no-publish` stops after the notarized DMG.

Notarization credentials live in the keychain, never on the command line, where any process could read them with `ps`. Store them once; it asks for an app-specific password from account.apple.com:

```sh
xcrun notarytool store-credentials ultimatefinder --apple-id you@example.com --team-id ABCDE12345
```

`release.sh` uses the profile `ultimatefinder`; set `NOTARY_PROFILE` to use another.

## App icon

`Resources/AppIcon.icns` is generated from `Resources/AppIcon.png` (1024×1024):

```sh
swift scripts/cutout-icon.swift generated.png Resources/AppIcon.png   # remove a fake checkerboard, centre, add shadow
scripts/make-icon.sh                                                  # AppIcon.png → AppIcon.icns
```

Finder and the Dock cache icons. If the old icon sticks, run `touch /Applications/UltimateFinder.app && killall Dock`.

## Project layout

```
Package.swift                    SwiftPM manifest (macOS 13+), libwebp dependency
VERSION                          app version (stamped into the bundle by build.sh)
CHANGELOG.md                     release history
AGENTS.md                        notes for coding agents (CLAUDE.md imports it)
Resources/Info.plist             LSUIElement, bundle id, privacy purpose strings
Resources/AppIcon.png / .icns    app icon (1024 master and the bundled icon set)
build.sh                         build → .app → stamp version → codesign → run/install
scripts/bump-version.sh          bump VERSION and date the changelog's Unreleased entries
scripts/release.sh               universal build → notarize app → DMG → notarize → staple → GitHub release
scripts/make-icon.sh             AppIcon.png → AppIcon.icns
scripts/cutout-icon.swift        cut a generated icon off its fake checkerboard, centre it on the icon grid
docs/images/                     README screenshots and the GitHub social preview
Sources/UltimateFinder/
  main.swift                     single-instance guard, accessory app bootstrap
  AppDelegate.swift              menu-bar item & settings menu, hotkey wiring, Quick Look fallback controller
  GlobalHotKey.swift             Carbon hotkey + Accessibility fallback and explanation
  VisorPanel.swift               borderless non-activating NSPanel, rounded-bottom vibrancy background
  VisorController.swift          active-screen placement, slide animation, focus, Esc/Space handling
  DualPaneController.swift       split view: one or two browser panes, key / Quick Look routing to the active one
  BrowserViewController.swift    one pane: path bar, tabs, sidebar split, NSBrowser (item API), DnD, context menu, shortcuts, Quick Look
  SidebarController.swift        editable Favorites + mounted volumes (drag & drop, context menu)
  Favorites.swift                favorites storage, defaults, Finder sidebar import
  LabelPickerView.swift          color-label dots in the context menu
  DestructiveMenuItemView.swift  red Move to Trash row in the context menu
  TabBarView.swift               Finder-style tab strip
  PreviewViewController.swift    preview column (thumbnail + Kind/Size/Dates)
  FileNode.swift                 cached directory model, icon previews, color labels, shared sort order
  FileListController.swift       list view (NSOutlineView, sortable columns)
  RenameField.swift              inline rename field laid over an item's name
  DirectoryWatcher.swift         kqueue watcher for the visible columns
  FileOperations.swift           Finder-style copy/move/unique names, new folder/text file, color-label tags
  ImageConverter.swift           Convert Image: JPEG/PNG via ImageIO, WebP via libwebp
  Settings.swift                 UserDefaults-backed settings, hotkey presets
```

## Implementation notes (macOS 27 SDK)

- NSBrowser draws its rows with `NSTextFieldCell` and ignores `cellClass`/`cellPrototype`. Each row's icon is therefore a text attachment in the title, and type-to-select uses the plain filename.
- NSBrowser sends Objective-C messages such as `-isEqualTo:` to its items, so `FileNode` subclasses `NSObject`.
- Finder keeps its sidebar favorites in `~/Library/Application Support/com.apple.sharedfilelist/…FavoriteItems.sfl4` (`.sfl3`/`.sfl2` on older macOS), which needs Full Disk Access to read. Without it, the import uses macOS's own `sfltool archive` to export a copy into a private temporary folder, reads it and deletes it.
- NSBrowser columns are table views internally (`NSBrowserTableView`). When `browser(_:canDragRowsWith:inColumn:with:)` returns false, a drag selects a range of rows, just as `NSTableView.canDragRows(with:at:)` returning false does in list view. Both views use this to drag only from the icon and name.
- A local key monitor must return `nil` for keys it handles. `self?.handle(event) ?? event` silently turns that `nil` back into the event, so every handled key also reached the browser.
- The panel is non-activating and sits above normal windows, so alerts use `NSAlert.runAboveVisor()`.
- The hotkey is registered with Carbon `RegisterEventHotKey`, which needs no permission. Only if another app owns the combination does the app fall back to a key monitor, which needs Accessibility access.
