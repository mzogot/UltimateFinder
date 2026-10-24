#!/usr/bin/env bash
# Builds UltimateFinder.app with SwiftPM — no Xcode required, Command Line Tools are enough.
#
#   ./build.sh            build build/UltimateFinder.app (release)
#   ./build.sh run        build, then (re)launch it
#   ./build.sh install    build, then copy it to /Applications and launch it
#
# Signing: uses $SIGN_IDENTITY if set, otherwise the first "Developer ID Application" or
# "Apple Development" certificate in your keychain, otherwise ad-hoc ("-").
# A real certificate keeps privacy grants (Accessibility, Desktop/Documents access) across
# rebuilds; with ad-hoc signing macOS asks again after every build.
# TIMESTAMP=1 adds Apple's secure timestamp, which notarization requires (scripts/release.sh
# sets it). Dev builds skip it because it needs the network.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="UltimateFinder"
CONFIG="${CONFIG:-release}"
APP="build/${APP_NAME}.app"

# UNIVERSAL=1 builds for Apple silicon and Intel and merges them (scripts/release.sh sets it).
# Each architecture gets its own scratch path, because both would land in the same bin folder.
BINARIES=()
if [[ "${UNIVERSAL:-}" == 1 ]]; then
    for arch in arm64 x86_64; do
        echo "▸ Compiling (${CONFIG}, ${arch})"
        args=(-c "$CONFIG" --scratch-path ".build/${arch}" --triple "${arch}-apple-macosx13.0")
        swift build "${args[@]}" --product "$APP_NAME"
        BINARIES+=("$(swift build "${args[@]}" --show-bin-path)/$APP_NAME")
    done
else
    echo "▸ Compiling (${CONFIG})"
    swift build -c "$CONFIG" --product "$APP_NAME"
    BINARIES+=("$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME")
fi

echo "▸ Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "${BINARIES[@]}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# libwebp's BSD license asks that its notice travel with the binary.
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# VERSION is the single source of truth; see CHANGELOG.md and scripts/bump-version.sh.
VERSION="$(tr -d '[:space:]' < VERSION)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/.*"((Developer ID Application|Apple Development): [^"]+)".*/\1/p' | head -1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
TIMESTAMP_FLAG="--timestamp=none"
[[ "${TIMESTAMP:-}" == 1 ]] && TIMESTAMP_FLAG="--timestamp"
echo "▸ Signing with: ${SIGN_IDENTITY}"
xattr -cr "$APP"
codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "✓ Built $(pwd)/$APP (version ${VERSION})"

launch() {
    pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
    open "$1"
    echo "✓ Launched — press ⌥Space (or use the menu bar icon)"
}

case "${1:-}" in
    run)
        launch "$APP"
        ;;
    install)
        pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
        rm -rf "/Applications/${APP_NAME}.app"
        cp -R "$APP" /Applications/
        echo "✓ Installed /Applications/${APP_NAME}.app"
        launch "/Applications/${APP_NAME}.app"
        ;;
    "") ;;
    *)
        echo "usage: $0 [run|install]" >&2
        exit 1
        ;;
esac
