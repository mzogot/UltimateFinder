#!/usr/bin/env bash
# Bumps the version in VERSION and turns CHANGELOG.md's "Unreleased" section into a dated release.
#
#   scripts/bump-version.sh patch     1.4.0 → 1.4.1   (bug fixes)
#   scripts/bump-version.sh minor     1.4.0 → 1.5.0   (new features)
#   scripts/bump-version.sh major     1.4.0 → 2.0.0   (breaking changes)
#
# Write the entries under "## [Unreleased]" first; this moves them under the new version heading.
set -euo pipefail

cd "$(dirname "$0")/.."
part="${1:-}"
IFS=. read -r major minor patch < VERSION

case "$part" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) echo "usage: $0 major|minor|patch" >&2; exit 1 ;;
esac

new="${major}.${minor}.${patch}"
today="$(date +%Y-%m-%d)"

if ! grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    echo "CHANGELOG.md has no '## [Unreleased]' section" >&2
    exit 1
fi
# Keep an empty Unreleased section on top and date the entries that were under it.
sed -i '' "s/^## \[Unreleased\]\$/## [Unreleased]\\
\\
## [${new}] — ${today}/" CHANGELOG.md
echo "$new" > VERSION

echo "✓ Version ${new} (${today}). Rebuild with ./build.sh to stamp it into the app."
