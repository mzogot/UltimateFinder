#!/usr/bin/env bash
# Builds, notarizes and publishes the current VERSION as a GitHub release.
#
#   scripts/release.sh               build → DMG → notarize → staple → tag → push → GitHub release
#   scripts/release.sh --no-publish  stop after the notarized DMG (build/UltimateFinder-x.y.z.dmg)
#
# Before running: add the changelog entries, run scripts/bump-version.sh, commit.
#
# Notarization credentials come from .env.release.local (gitignored):
#   APPLE_ID        the Apple ID of the developer account
#   APPLE_PASSWORD  an app-specific password from account.apple.com (not the login password)
#   APPLE_TEAM_ID   the 10-character team ID, as in the Developer ID certificate
# Alternatively set NOTARY_PROFILE to a profile saved with `xcrun notarytool store-credentials`.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="UltimateFinder"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v${VERSION}"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}-${VERSION}.dmg"
NOTES="build/release-notes-${VERSION}.md"
PUBLISH=1
[[ "${1:-}" == "--no-publish" ]] && PUBLISH=0

fail() { echo "✗ $*" >&2; exit 1; }

# MARK: Preflight

if (( PUBLISH )); then
    [[ -z "$(git status --porcelain)" ]] || fail "working tree not clean; commit first"
    ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || fail "tag ${TAG} already exists"
fi

# The changelog section for this version becomes the release notes.
mkdir -p build
awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    /^## \[/ || /^\[[^]]+\]: / { on = 0 }
    on' CHANGELOG.md | sed '/./,$!d' > "$NOTES"
[[ -s "$NOTES" ]] || fail "CHANGELOG.md has no entries under '## [${VERSION}]'; run scripts/bump-version.sh"

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)}"
[[ -n "$SIGN_IDENTITY" ]] || fail "no Developer ID Application certificate in the keychain"

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    [[ -f .env.release.local ]] || fail "missing .env.release.local (or set NOTARY_PROFILE)"
    set -a; . ./.env.release.local; set +a
    [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]] \
        || fail "fill APPLE_ID, APPLE_PASSWORD and APPLE_TEAM_ID in .env.release.local"
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi

# MARK: Build and package

SIGN_IDENTITY="$SIGN_IDENTITY" TIMESTAMP=1 UNIVERSAL=1 ./build.sh
[[ "$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")" == *x86_64*arm64* ]] || fail "not a universal binary"
codesign --verify --deep --strict "$APP"

echo "▸ Packaging ${DMG}"
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

# MARK: Notarize

echo "▸ Notarizing (usually a few minutes)"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "✓ Notarized ${DMG}"

(( PUBLISH )) || exit 0

# MARK: Publish

git tag -a "$TAG" -m "${APP_NAME} ${VERSION}"
git push origin HEAD "$TAG"
# An unversioned copy keeps the README's releases/latest/download link stable.
cp "$DMG" "build/${APP_NAME}.dmg"
gh release create "$TAG" "$DMG" "${DMG}.sha256" "build/${APP_NAME}.dmg" \
    --title "${APP_NAME} ${VERSION}" --notes-file "$NOTES" --latest
echo "✓ Released ${TAG}: $(gh release view "$TAG" --json url -q .url)"
