#!/usr/bin/env bash
# Builds Resources/AppIcon.icns from Resources/AppIcon.png (square, ideally 1024×1024).
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="Resources/AppIcon.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "✓ Resources/AppIcon.icns"
