#!/usr/bin/env bash
# Builds, notarizes and publishes the current VERSION as a GitHub release.
#
#   scripts/release.sh               build → notarize app → DMG → notarize → staple → tag → push → GitHub release
#   scripts/release.sh --no-publish  stop after the notarized DMG (build/UltimateFinder-x.y.z.dmg)
#
# Before running: add the changelog entries, run scripts/bump-version.sh, commit.
#
# Notarization credentials live in the keychain, never on the command line, where any process
# could read them with `ps`. Store them once (it asks for an app-specific password from
# account.apple.com):
#   xcrun notarytool store-credentials ultimatefinder --apple-id you@example.com --team-id 854T64H39D
# NOTARY_PROFILE picks another profile name.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="UltimateFinder"
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ VERSION is not x.y.z: ${VERSION}" >&2; exit 1; }
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

NOTARY_PROFILE="${NOTARY_PROFILE:-ultimatefinder}"
NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 \
    || fail "no working notarytool keychain profile '${NOTARY_PROFILE}'; run: xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <Apple ID> --team-id <team ID>"

# MARK: Build and package

SIGN_IDENTITY="$SIGN_IDENTITY" TIMESTAMP=1 UNIVERSAL=1 ./build.sh
[[ "$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")" == *x86_64*arm64* ]] || fail "not a universal binary"
codesign --verify --deep --strict "$APP"

# The app gets its own ticket too, so it still opens offline after being copied out of the DMG.
echo "▸ Notarizing ${APP} (usually a few minutes)"
ZIP="build/${APP_NAME}-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
rm -f "$ZIP"
xcrun stapler staple "$APP"

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

echo "▸ Notarizing ${DMG}"
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
