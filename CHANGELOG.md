# Changelog

All notable changes to UltimateFinder. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/): a **patch** bump for fixes, a **minor** bump for new features, a **major** bump for breaking changes.

Add entries under **Unreleased** as you work, then run `scripts/bump-version.sh patch|minor|major` to turn them into a release, and `scripts/release.sh` to publish it. Downloads for each version are on the [Releases](https://github.com/mzogot/UltimateFinder/releases) page, starting with 1.10.0. Versions 1.0.0–1.4.0 were assigned retroactively, one per round of work.

## [Unreleased]

## [1.10.0] — 2026-10-24

### Added
- UltimateFinder is now public on GitHub at [mzogot/UltimateFinder](https://github.com/mzogot/UltimateFinder), with a download page under [Releases](https://github.com/mzogot/UltimateFinder/releases).
- Releases ship as a disk image that's signed with a Developer ID and notarized by Apple, so the app opens on any Mac without a Gatekeeper warning.
- The app is universal: it runs natively on Apple silicon and Intel Macs.
- MIT license. The license and the third-party notices for libwebp are included in the app.

### Changed
- *About UltimateFinder* shows the copyright and license.
- New README with screenshots, a feature overview, download and install steps, and a privacy section. Developer notes moved to `docs/DEVELOPMENT.md`.

## [1.9.2] — 2026-10-24

### Changed
- New app icon: a Finder-style two-tone blue tile with a "UF" monogram, where the right stroke of the U turns into the F.

## [1.9.1] — 2026-10-24

### Fixed
- Split view: dragging the divider between the two sides no longer snaps the left side back to its narrowest width when you let go. The divider stays where you put it, and keeps its proportion when the visor opens on a display of another width.

## [1.9.0] — 2026-10-24

### Added
- Split view: press ⌘U, click the split button in the header, or choose *Split View* in the menu-bar menu to show two browsers side by side, 50/50, and drag files between them (Finder's rules: same volume moves, ⌥ copies, ⌘ moves). Each side has its own sidebar, tabs, back/forward history and list/column view, and both are remembered. Sort order, hidden files and favorites are shared. Clicking in a side makes it the active one for the keyboard.
- Cut and paste: *Cut* in the right-click menu, or ⌘X, then *Paste* (or ⌘V) moves the items instead of copying them. This works across the two sides of split view. Copying anything else in between cancels the cut. Holding ⌥ in the right-click menu turns *Paste* into *Move Items Here*, as in Finder.

## [1.8.0] — 2026-10-23

### Added
- *Copy Name* and *Copy Name Without Extension* in the right-click menu copy the file name as text, with or without its extension (`photo.jpg` or `photo`). With several items selected, each name goes on its own line.

## [1.7.1] — 2026-10-22

### Changed
- *Move to Trash* in the right-click menu stands out: it sits between dividers on a red background with a trash icon.

## [1.7.0] — 2026-10-22

### Added
- New Text File: right-click empty space or an item and choose *New Text File* to create a blank `untitled.rtf` in that folder and name it straight away, like *New Folder*.
- Convert Image: right-click one or more images and pick JPEG, PNG or WebP from *Convert Image* to save a converted copy beside each original. Photos keep their rotation and EXIF/GPS data, transparency becomes white in JPEG, and existing files are never overwritten.

## [1.6.0] — 2026-10-22

### Added
- Color labels: right-click files or folders and pick one of Finder's seven colors from the row of dots, and the whole row is tinted in list and column view. Click the current color again to remove it. Labels are Finder's own color tags, so they show in Finder too, keep the item's other tags, and follow the item when it's renamed or moved.
- Keep Folders on Top: the folder button in the header (or *Keep Folders on Top* in the sort menu) lists folders above files whatever the sort order, in both views.

## [1.5.0] — 2026-10-20

### Added
- App icon: a frosted-glass browser panel sliding down over a midnight-blue tile.
- Version tracking: `VERSION` is the single source of truth, and `build.sh` stamps it into the app, so the About panel shows it.
- This changelog, and `scripts/bump-version.sh` to cut a release from it.
- `AGENTS.md` with build, structure and workflow notes for coding agents.

### Changed
- README documents the menu-bar menu, the new-folder button and the `--show` launch argument.

## [1.4.0] — 2026-10-20

### Added
- Icon previews: images, PDFs, movies and documents show a Quick Look thumbnail as their icon, like Finder's *Show icon preview*.

### Fixed
- Drag-selecting several files with the mouse. Pressing beside a name and dragging now selects every row passed over, in list and column view; pressing on the icon or name still drags the file.

## [1.3.0] — 2026-10-19

### Added
- Per-tab back/forward history, restoring the selection on the way back.
- ‹ › buttons in the header, ⌘[ / ⌘] (⌘Ü / ⌘+ on a German keyboard), mouse buttons 4 / 5, and trackpad / Magic Mouse page swipes.

## [1.2.0] — 2026-10-19

### Added
- *Import Finder Favorites…* in the sidebar's context menu, which reads Finder's own sidebar without Full Disk Access.
- List view (⌘2) with sortable, reorderable Name, Date Modified, Size and Kind columns and expandable folders; column view (⌘3) shares its sort order through the header's sort button.

## [1.1.0] — 2026-10-19

### Added
- Editable Favorites sidebar: drag folders in, reorder, drop files onto favorites, remove, restore defaults; mounted volumes with eject.
- New-folder button in the header (⇧⌘N).
- Finder-style tabs (⌘T, ⌘W, ⌃Tab), restored across relaunches.

## [1.0.0] — 2026-10-19

### Added
- TotalFinder-style visor: ⌥Space slides a column browser down from under the menu bar on the display with the mouse, at full width and 60% height.
- Menu-bar agent with no Dock icon, hotkey presets, *Hide When Focus Is Lost*, *Show Hidden Files* and *Launch at Login*.
- Carbon global hotkey that needs no permission, with an Accessibility fallback and explanation when another app owns the shortcut.
- Column view with Quick Look (Space), context menu, drag and drop with Finder's copy/move rules, rename, duplicate, trash, copy path and live folder updates.
