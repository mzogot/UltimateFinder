# Contributing

Thanks for helping improve UltimateFinder.

## Reporting bugs and ideas

Open an [issue](https://github.com/mzogot/UltimateFinder/issues/new/choose). For bugs, include the app version (menu-bar icon › About), your macOS version and the steps that trigger the problem.

## Code changes

1. Fork the repository and create a branch.
2. Build and run with `./build.sh run` (Command Line Tools are enough; see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)).
3. Keep to the style of the surrounding code: `final class`, `private` by default, `// MARK:` sections, and short `///` comments that explain *why*.
4. Behaviour should match Finder's (shortcuts, drag rules, selection, tabs, history) unless there's a good reason to differ. Say why in the pull request.
5. Add a user-facing line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md). Don't bump `VERSION`; that happens at release time.
6. Make sure `swift build` finishes without warnings, then open a pull request.

There are no automated tests yet, so describe how you checked the change.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
